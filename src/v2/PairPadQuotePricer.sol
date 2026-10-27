// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hop} from "./libraries/Hop.sol";
import {QuoteAssetProbe} from "./libraries/QuoteAssetProbe.sol";

/// @dev The slice of the Uniswap V3 pool surface the pricer consults.
interface IUniswapV3PoolMinimal {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/**
 * @dev A source of Uniswap V4 pool keys for tokens that were launched by
 * some launchpad. The pricer asks each registered registry for `token` and
 * treats a returned pool like one registered by hand, so a token that only
 * trades in its launchpad's V4 pool can be used as a quote without anyone
 * doing anything first. One adapter per launchpad, see
 * PairPadReferenceRegistries.sol.
 */
interface IQuoteReferenceRegistry {
    function referencePool(address token) external view returns (bool found, PoolKey memory key);
}

/**
 * @title PairPadQuotePricer
 * @notice Converts the launch config's ETH-denominated terms (the opening
 * market cap) into an ERC-20 quote asset's own units at the current price
 * along a route of pools from that asset to ETH.
 *
 * A route is a list of hops, each a Uniswap V3 or V4 pool, that starts at
 * the asset and ends at ETH (native or WETH). Two routes are found without
 * anyone doing anything: a direct pool against ETH, and two hops through
 * USDG, each leg being the deepest pool for its pair. Anything longer is
 * registered by whoever wants to launch against the asset: the interface
 * searches the chain's pools for a route, and `registerPath` checks and
 * stores it. Once stored a route serves every later launch in that asset.
 * Routes have up to `MAX_HOPS` hops, which covers an asset paired to a
 * token paired to a stock paired to USDG paired to ETH.
 *
 * Every hop has to be deep. Walking from the ETH end, a hop qualifies when
 * the pool holds at least `minReferenceEth` worth of the side nearer ETH,
 * that floor converted along the hops already walked. For V3 that is the
 * balance the pool physically holds. For V4 the PoolManager holds every
 * pool's tokens in one balance, so there is nothing to read; see
 * `_v4Depth` for what is measured instead and what it costs to fake.
 * A route qualifies when all its hops do; its strength is its weakest hop's
 * depth over that hop's floor. When both a registered route and an automatic
 * one qualify, the stronger prices the asset.
 *
 * V4 hops must carry a hook on the allow-list (no hook is allowed from
 * deployment). V4 pools for the automatic routes come from hand
 * registration and from launchpad registries; V3 pools from the V3 factory
 * at the standard fee tiers.
 *
 * The price is the spot price. There is no averaging and no waiting: an
 * asset becomes usable as a quote the moment a deep enough route exists.
 * The cost of that choice is spelled out in the docs: whoever launches can
 * push a route's price inside their own transaction and pull it back after,
 * paying only the pools' swap fees, and thereby open their own token at a
 * market cap other than the advertised one. That distorts nothing but that
 * one launch and the interface shows the live market cap anyway.
 *
 * What the depth floor does about that, stated exactly, because it used to
 * be overstated here: it does not set a minimum size for the shove and it
 * does not stop one. It sets a minimum for the capital that has to be in the
 * pool for the pool to be looked at in the first place, and therefore a
 * minimum for what a shove of a given size pays in pool fees and gives up to
 * arbitrage. That capital may be borrowed for the length of one transaction,
 * on a V3 hop and on a V4 hop alike, so the floor is a cost, not a barrier.
 * A depth measure that can be met with a hundredth of the capital it claims
 * is a different thing altogether, and that is what `_v4Depth` fixes.
 */
contract PairPadQuotePricer is Ownable2Step, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error QuoteAssetNotPriceable(address quoteToken);
    error ZeroAddress();
    error ConversionOverflow();
    error HookNotAllowed(address hook);
    error NotAnAnchorPool();
    error PoolNotInitialized();
    error PoolAlreadyRegistered(bytes32 poolId);
    error PoolNotRegistered(bytes32 poolId);
    error TooManyPools(address token);
    error TooManyRegistries();
    error RegistryAlreadyAdded(address registry);
    error UnknownRegistry(address registry);
    error NotAContract(address registry);
    /// @dev The route is malformed; `hopIndex` is the hop at fault.
    error InvalidPath(PathFault fault, uint256 hopIndex);
    /// @dev Every hop is well formed but one is under its depth floor.
    error PathNotQualifying(uint256 hopIndex);
    /// @dev A qualifying route is already stored and is at least as strong.
    error PathNotStronger(uint256 storedStrengthX18, uint256 offeredStrengthX18);
    error NoPathStored(address token);
    /// @dev The probe offered was too small to prove anything.
    error ProbeTooSmall(address asset, uint256 required, uint256 offered);

    event MinReferenceDepthUpdated(uint256 minReferenceEth);
    event V4HookAllowed(address indexed hook, bool allowed);
    event V4PoolRegistered(bytes32 indexed poolId, address indexed token, address indexed anchor, PoolKey key);
    event V4PoolUnregistered(bytes32 indexed poolId, address indexed token);
    event ProbeAmountOverridden(address indexed asset, uint256 amount);
    event RegistryAdded(address indexed registry);
    event RegistryRemoved(address indexed registry);
    event PathRegistered(address indexed token, address indexed by, Hop[] hops, uint256 strengthX18);
    event PathCleared(address indexed token);
    event ExactTransfersProven(address indexed asset, address indexed by, uint256 amount);

    struct V4Pool {
        PoolKey key;
        /// @dev The asset being priced by this pool (the non-anchor side).
        address token;
        /// @dev Native ETH (address zero), WETH or USDG.
        address anchor;
        bool registered;
    }

    /// @notice Why a route is malformed.
    enum PathFault {
        None,
        Empty,
        TooLong,
        /// @dev The hop does not contain the asset the previous hop produced.
        Disconnected,
        /// @dev The route passes through the same asset twice.
        Revisits,
        /// @dev A V3 hop names native ETH; V3 pools hold WETH.
        NativeOnV3,
        /// @dev The V3 factory has no pool for the hop's pair and fee.
        NoV3Pool,
        /// @dev A V3 hop's tickSpacing or hooks are not zero.
        V3KeyNotBare,
        HookNotAllowed,
        NotInitialized,
        /// @dev The last hop does not reach ETH or WETH.
        NotToEth,
        /// @dev ETH or WETH appears before the last hop.
        EthMidRoute
    }

    /// @notice One hop of a route as the pricer sees it, for interfaces.
    struct HopReport {
        Hop hop;
        /// @dev The asset entering the hop, on the way from the quote to ETH.
        address tokenIn;
        /// @dev The asset leaving the hop, one step nearer ETH.
        address tokenOut;
        /// @dev How much of `tokenOut` the pool holds (V3) or has in range (V4).
        uint256 depth;
        /// @dev What `depth` has to reach: `minReferenceEth` in `tokenOut` units.
        uint256 floor;
        bool qualifies;
    }

    /// @notice A route and how it measures up, for interfaces.
    struct PathReport {
        HopReport[] hops;
        /// @dev All hops well formed and at or above their floor.
        bool qualifies;
        /// @dev Came from `registerPath` rather than the automatic search.
        bool registered;
        /// @dev Weakest hop's depth over its floor, scaled by 1e18.
        uint256 strengthX18;
        PathFault fault;
        uint256 faultHop;
    }

    /// @dev Every Uniswap V3 fee tier enabled on Ethereum mainnet, scanned for
    /// an automatic route. The 0.01% tier matters more than its size suggests:
    /// correlated pairs keep nearly all their depth there, so leaving it out
    /// made wstETH and USDe unpriceable while their 0.01% pools held 1,032 WETH
    /// and 1.1M USDC respectively.
    uint24 private constant FEE_LOWEST = 100;
    uint24 private constant FEE_LOW = 500;
    uint24 private constant FEE_MEDIUM = 3_000;
    uint24 private constant FEE_HIGH = 10_000;

    uint8 public constant MAX_HOPS = 4;
    uint8 public constant MAX_V4_POOLS_PER_TOKEN = 8;
    uint8 public constant MAX_REGISTRIES = 8;

    /**
     * @notice The price band a V4 hop's depth is measured over, in basis
     * points of the square root of the price: 500 bps of the square root is
     * about 10.25% of the price. See `_v4Depth`.
     */
    uint256 public constant DEPTH_SQRT_WINDOW_BPS = 500;
    uint256 private constant BASIS_POINTS = 10_000;
    /// @dev Tick bitmap words read per direction when looking for the edge of
    /// the liquidity that is in range. Five words cover at least 1025 ticks
    /// at tick spacing 1, and the widest band the window can ask about is
    /// 977 ticks, so the scan never stops short of the window it measures.
    uint256 private constant MAX_BITMAP_WORDS = 5;

    IUniswapV3FactoryMinimal public immutable v3Factory;
    IPoolManager public immutable poolManager;
    address public immutable weth;
    address public immutable usdg;

    /// @notice How much ETH worth of the side nearer ETH every hop of a
    /// route must hold (V3) or have in range (V4).
    uint256 public minReferenceEth = 5 ether;

    /// @notice Hooks a V4 hop may carry. Address zero (no hook) is allowed
    /// from deployment.
    mapping(address hook => bool) public allowedV4Hooks;
    mapping(bytes32 poolId => V4Pool) private _v4Pools;
    mapping(address token => bytes32[]) private _v4PoolsOf;
    /// @notice Every hand-registered V4 pool.
    bytes32[] public allV4Pools;
    /// @notice Launchpad registries consulted for V4 pool keys.
    IQuoteReferenceRegistry[] public registries;
    /// @dev Routes stored through `registerPath`, from the asset to ETH.
    mapping(address token => Hop[]) private _paths;
    /**
     * @notice Assets shown to move exact amounts, through
     * `proveExactTransfers`. A launch factory requires this of every ERC-20
     * quote: the route walk cannot see a transfer fee, because the depth it
     * measures is always the side nearer ETH, so a fee-taking or
     * share-rounding token clears the depth floor exactly as a well behaved
     * one does and only breaks once the pool is open and unrecoverable.
     */
    mapping(address asset => bool) public exactTransferProven;
    /**
     * @notice A probe size the owner has set by hand for an asset, in that
     * asset's own units, overriding the route-derived figure. This is what
     * makes the factories' curated `setPairTokenEconomics` path usable: an
     * asset the owner prices by hand has no qualifying route, so the pricer
     * cannot say what a probe of it should be worth, and without a figure
     * `proveExactTransfers` could never be called and the asset could never
     * be launched against. Zero means no override.
     */
    mapping(address asset => uint256) public probeAmountOverride;

    constructor(
        address initialOwner,
        IUniswapV3FactoryMinimal v3Factory_,
        address weth_,
        address usdg_,
        IPoolManager poolManager_
    ) Ownable(initialOwner) {
        if (
            address(v3Factory_) == address(0) || weth_ == address(0) || usdg_ == address(0)
                || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        v3Factory = v3Factory_;
        weth = weth_;
        usdg = usdg_;
        poolManager = poolManager_;
        allowedV4Hooks[address(0)] = true;
        emit V4HookAllowed(address(0), true);
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    /// @notice Sets the ETH depth every hop of a route must have.
    function setMinReferenceEth(uint256 minEth) external onlyOwner {
        minReferenceEth = minEth;
        emit MinReferenceDepthUpdated(minEth);
    }

    /**
     * @notice Allows or forbids a hook for V4 hops. Forbidding a hook does
     * not unregister its pools or routes but stops them from being priced,
     * including pools a registry hands back.
     */
    function setV4HookAllowed(address hook, bool allowed) external onlyOwner {
        allowedV4Hooks[hook] = allowed;
        emit V4HookAllowed(hook, allowed);
    }

    /// @notice Adds a launchpad registry.
    function addRegistry(IQuoteReferenceRegistry registry) external onlyOwner {
        if (address(registry) == address(0)) revert ZeroAddress();
        if (address(registry).code.length == 0) revert NotAContract(address(registry));
        if (registries.length >= MAX_REGISTRIES) revert TooManyRegistries();
        for (uint256 i = 0; i < registries.length; ++i) {
            if (registries[i] == registry) revert RegistryAlreadyAdded(address(registry));
        }
        registries.push(registry);
        emit RegistryAdded(address(registry));
    }

    /// @notice Removes a launchpad registry.
    function removeRegistry(IQuoteReferenceRegistry registry) external onlyOwner {
        uint256 n = registries.length;
        for (uint256 i = 0; i < n; ++i) {
            if (registries[i] != registry) continue;
            registries[i] = registries[n - 1];
            registries.pop();
            emit RegistryRemoved(address(registry));
            return;
        }
        revert UnknownRegistry(address(registry));
    }

    function registriesLength() external view returns (uint256) {
        return registries.length;
    }

    /**
     * @notice Sets the probe size `proveExactTransfers` demands for `asset`,
     * in the asset's own units; zero clears it and hands the question back to
     * the route price. Pair it with the factory's `setPairTokenEconomics`
     * when curating an asset the pricer cannot price on its own, and size it
     * the way the automatic figure is sized: about a thousandth of the depth
     * floor's worth, large enough that a percentage transfer fee cannot round
     * away to nothing. Every wei of a probe goes back to whoever funds it, so
     * an over-large figure costs gas and nothing else.
     */
    function setProbeAmount(address asset, uint256 amount) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        probeAmountOverride[asset] = amount;
        emit ProbeAmountOverridden(asset, amount);
    }

    /// @notice Drops a stored route. The automatic search still applies.
    function clearPath(address token) external onlyOwner {
        if (_paths[token].length == 0) revert NoPathStored(token);
        delete _paths[token];
        emit PathCleared(token);
    }

    // ---------------------------------------------------------------------
    // V4 reference pools for the automatic routes
    // ---------------------------------------------------------------------

    /**
     * @notice Registers an initialized V4 pool for the automatic search. One
     * side must be an anchor: native ETH, WETH or USDG. A pool of USDG
     * against ETH is registered as pricing USDG in ETH, which is the second
     * leg of the two-hop route. Tokens a registry knows about do not need
     * this, and neither does anything reached through `registerPath`.
     */
    function registerV4Pool(PoolKey calldata key) external returns (bytes32 poolId) {
        if (!allowedV4Hooks[address(key.hooks)]) revert HookNotAllowed(address(key.hooks));
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        (address anchor, address token, bool ok) = _splitAnchor(c0, c1);
        if (!ok) revert NotAnAnchorPool();

        poolId = PoolId.unwrap(key.toId());
        if (_v4Pools[poolId].registered) revert PoolAlreadyRegistered(poolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(poolId));
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        if (_v4PoolsOf[token].length >= MAX_V4_POOLS_PER_TOKEN) revert TooManyPools(token);

        _v4Pools[poolId] = V4Pool({key: key, token: token, anchor: anchor, registered: true});
        _v4PoolsOf[token].push(poolId);
        allV4Pools.push(poolId);
        emit V4PoolRegistered(poolId, token, anchor, key);
    }

    /**
     * @notice Drops a hand-registered V4 pool, freeing its slot. Registration
     * is open to anyone and capped at `MAX_V4_POOLS_PER_TOKEN`, so without
     * this a stranger could fill a token's slots with initialized pools
     * holding a wei each and deny it its real V4 reference for good. Owner
     * only, since removing a pool can only ever narrow what the pricer looks
     * at: a pool the owner drops can be registered again by anyone.
     */
    function unregisterV4Pool(bytes32 poolId) external onlyOwner {
        V4Pool storage p = _v4Pools[poolId];
        if (!p.registered) revert PoolNotRegistered(poolId);
        address token = p.token;

        bytes32[] storage ids = _v4PoolsOf[token];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] != poolId) continue;
            ids[i] = ids[ids.length - 1];
            ids.pop();
            break;
        }
        for (uint256 i = 0; i < allV4Pools.length; ++i) {
            if (allV4Pools[i] != poolId) continue;
            allV4Pools[i] = allV4Pools[allV4Pools.length - 1];
            allV4Pools.pop();
            break;
        }
        delete _v4Pools[poolId];
        emit V4PoolUnregistered(poolId, token);
    }

    function allV4PoolsLength() external view returns (uint256) {
        return allV4Pools.length;
    }

    function v4PoolsOf(address token) external view returns (bytes32[] memory) {
        return _v4PoolsOf[token];
    }

    function v4PoolIdFor(PoolKey calldata key) external pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    // ---------------------------------------------------------------------
    // Registered routes
    // ---------------------------------------------------------------------

    /**
     * @notice Stores a route from `token` to ETH for anyone to price against.
     * The route must be well formed and every hop at or above its floor
     * right now. It replaces a stored route only when that one no longer
     * qualifies or this one is stronger, so a route cannot be swapped for
     * a worse one. Open to anyone: the checks are the same whoever calls.
     */
    function registerPath(address token, Hop[] calldata hops) external returns (uint256 strengthX18) {
        if (token == address(0) || token == weth) revert ZeroAddress();
        Hop[] memory offered = hops;
        (PathReport memory rep,) = _walk(token, offered, 0);
        if (rep.fault != PathFault.None) revert InvalidPath(rep.fault, rep.faultHop);
        if (!rep.qualifies) revert PathNotQualifying(_firstFailing(rep));

        Hop[] memory current = _paths[token];
        if (current.length != 0) {
            (PathReport memory cur,) = _walk(token, current, 0);
            if (cur.qualifies && cur.strengthX18 >= rep.strengthX18) {
                revert PathNotStronger(cur.strengthX18, rep.strengthX18);
            }
            delete _paths[token];
        }
        for (uint256 i = 0; i < offered.length; ++i) {
            _paths[token].push(offered[i]);
        }
        emit PathRegistered(token, msg.sender, offered, rep.strengthX18);
        return rep.strengthX18;
    }

    /// @notice The route stored for `token`, empty when none.
    function pathOf(address token) external view returns (Hop[] memory) {
        return _paths[token];
    }

    /**
     * @notice Measures a route without storing it. Never reverts for a
     * malformed route: the report says what is wrong and where.
     */
    function evaluatePath(address token, Hop[] calldata hops) external view returns (PathReport memory rep) {
        (rep,) = _walk(token, hops, 0);
    }

    // ---------------------------------------------------------------------
    // Exact-transfer proof
    // ---------------------------------------------------------------------

    /**
     * @notice How much of `asset` `proveExactTransfers` demands: the owner's
     * override when one is set, otherwise a thousandth of the depth floor
     * converted into the asset's own units at its route price.
     *
     * Reverts for an asset that has neither an override nor a qualifying
     * route, and reverts with `ProbeTooSmall(asset, 0, 0)` when the route
     * price rounds the probe to zero, which a very expensive asset with few
     * decimals can do. A probe of zero proves nothing at all: every leg of a
     * zero transfer arrives exactly, whatever the token does, so without this
     * the gate would pass an asset it had never really moved.
     */
    function probeAmountRequired(address asset) public view returns (uint256 required) {
        required = probeAmountOverride[asset];
        if (required != 0) return required;
        required = priceEthAmountInQuote(asset, minReferenceEth / QuoteAssetProbe.PROBE_DIVISOR);
        if (required == 0) revert ProbeTooSmall(asset, 0, 0);
    }

    /**
     * @notice Proves `asset` moves exact amounts, once and for all, by moving
     * `amount` of it out of the caller and straight back. Open to anyone and
     * funded by whoever calls, so a creator launching against this asset later
     * still needs to hold nothing but ETH. Reverts unless both legs of the
     * round trip arrive to the wei.
     *
     * `amount` must be at least `probeAmountRequired(asset)`, which stops a
     * proof at a size where a percentage fee rounds away to nothing. Anything
     * larger is accepted and returned in full.
     *
     * `nonReentrant` because the probe hands control to the asset twice, and
     * the asset is by definition one nobody has vouched for yet.
     */
    function proveExactTransfers(address asset, uint256 amount) external nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        uint256 required = probeAmountRequired(asset);
        if (amount < required) revert ProbeTooSmall(asset, required, amount);
        QuoteAssetProbe.requireExactTransfers(asset, msg.sender, amount);
        exactTransferProven[asset] = true;
        emit ExactTransfersProven(asset, msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------

    /**
     * @notice Converts a launch's ETH-denominated phantom reserve into
     * `quoteToken` units at the route price. Reverts when the asset has no
     * qualifying route or the figure rounds to zero.
     */
    function quoteEconomics(address quoteToken, uint256 phantomQuoteEth) external view returns (uint256 phantomQuote) {
        phantomQuote = priceEthAmountInQuote(quoteToken, phantomQuoteEth);
        if (phantomQuote == 0) revert QuoteAssetNotPriceable(quoteToken);
    }

    /**
     * @notice Returns how much of `quoteToken` is worth `ethAmount` of ETH
     * along the asset's route (WETH is treated as ETH one-to-one).
     */
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) public view returns (uint256) {
        if (quoteToken == weth) return ethAmount;
        (, PathReport memory rep, uint256 amount) = _route(quoteToken, ethAmount);
        if (!rep.qualifies) revert QuoteAssetNotPriceable(quoteToken);
        return amount;
    }

    /**
     * @notice True when `quoteToken` currently has a qualifying route, for
     * frontends to check before offering it in a create flow.
     */
    function isPriceable(address quoteToken) external view returns (bool) {
        if (quoteToken == weth) return true;
        (, PathReport memory rep,) = _route(quoteToken, 0);
        return rep.qualifies;
    }

    /**
     * @notice The route that prices `quoteToken`, in trade order from the
     * asset to ETH, and whether it qualifies. When nothing qualifies the
     * closest route is returned anyway so a frontend can still trade along
     * it; empty when no pool is known at all.
     */
    function route(address quoteToken) external view returns (Hop[] memory hops, bool qualifies) {
        if (quoteToken == weth) return (hops, true);
        PathReport memory rep;
        (hops, rep,) = _route(quoteToken, 0);
        qualifies = rep.qualifies;
    }

    /**
     * @notice The route that prices `quoteToken` with every hop's depth and
     * floor, so an interface can say what is missing. Same selection as
     * `route`.
     */
    function describe(address quoteToken) external view returns (PathReport memory rep) {
        if (quoteToken == weth) {
            rep.qualifies = true;
            rep.strengthX18 = type(uint256).max;
            return rep;
        }
        (, rep,) = _route(quoteToken, 0);
    }

    // ---------------------------------------------------------------------
    // Route selection
    // ---------------------------------------------------------------------

    /**
     * @dev Picks between the stored route and the automatic one: a
     * qualifying route beats a failing one, and between two qualifying
     * routes the stronger wins. When neither qualifies the closer one is
     * reported so the interface can explain. `amount` is `ethAmount`
     * converted along the chosen route.
     */
    function _route(address token, uint256 ethAmount)
        private
        view
        returns (Hop[] memory hops, PathReport memory rep, uint256 amount)
    {
        (Hop[] memory autoHops, PathReport memory autoRep, uint256 autoAmount) = _auto(token, ethAmount);

        Hop[] memory stored = _paths[token];
        if (stored.length == 0) return (autoHops, autoRep, autoAmount);

        (PathReport memory storedRep, uint256 storedAmount) = _walk(token, stored, ethAmount);
        storedRep.registered = true;
        if (_prefer(storedRep, autoRep)) return (stored, storedRep, storedAmount);
        return (autoHops, autoRep, autoAmount);
    }

    function _prefer(PathReport memory a, PathReport memory b) private pure returns (bool) {
        if (a.qualifies != b.qualifies) return a.qualifies;
        if (b.hops.length == 0) return true;
        if (a.hops.length == 0) return false;
        return a.strengthX18 >= b.strengthX18;
    }

    /**
     * @dev The automatic routes: the deepest direct pool against ETH, else
     * the deepest pool against USDG followed by the deepest USDG pool
     * against ETH. The direct route is taken when it qualifies; otherwise
     * whichever of the two is closer is reported.
     */
    function _auto(address token, uint256 ethAmount)
        private
        view
        returns (Hop[] memory hops, PathReport memory rep, uint256 amount)
    {
        (Hop memory direct, bool hasDirect) = _bestPool(token, true);
        if (hasDirect) {
            hops = new Hop[](1);
            hops[0] = direct;
            (rep, amount) = _walk(token, hops, ethAmount);
            if (rep.qualifies) return (hops, rep, amount);
        }

        (Hop memory viaUsdg, bool hasViaUsdg) = _bestPool(token, false);
        (Hop memory usdgLeg, bool hasUsdgLeg) = _bestPool(usdg, true);
        if (hasViaUsdg && (hasUsdgLeg || !hasDirect)) {
            Hop[] memory two = new Hop[](hasUsdgLeg ? 2 : 1);
            two[0] = viaUsdg;
            if (hasUsdgLeg) two[1] = usdgLeg;
            (PathReport memory twoRep, uint256 twoAmount) = _walk(token, two, ethAmount);
            if (!hasDirect || _prefer(twoRep, rep)) return (two, twoRep, twoAmount);
        }
        // Nothing at all: an empty report with the fault set, so `describe`
        // is honest about it.
        if (!hasDirect) {
            rep.fault = PathFault.Empty;
        }
    }

    // ---------------------------------------------------------------------
    // Route walking
    // ---------------------------------------------------------------------

    /**
     * @dev Checks a route's shape and measures every hop. Walks from the
     * quote to ETH to check the hops connect, then back from ETH to the
     * quote converting the floor and `ethAmount` hop by hop at spot. A
     * malformed route yields a report with `fault` set and never reverts,
     * except for an amount that overflows the conversion.
     */
    function _walk(address token, Hop[] memory hops, uint256 ethAmount)
        private
        view
        returns (PathReport memory rep, uint256 amount)
    {
        uint256 n = hops.length;
        if (n == 0) return (_faulted(rep, PathFault.Empty, 0), 0);
        if (n > MAX_HOPS) return (_faulted(rep, PathFault.TooLong, MAX_HOPS), 0);

        address[] memory chain = new address[](n + 1);
        chain[0] = token;
        for (uint256 i = 0; i < n; ++i) {
            (address next, PathFault fault) = _step(hops[i], chain[i]);
            if (fault != PathFault.None) return (_faulted(rep, fault, i), 0);
            for (uint256 j = 0; j <= i; ++j) {
                if (chain[j] == next) return (_faulted(rep, PathFault.Revisits, i), 0);
            }
            if (_isEth(next) && i + 1 < n) return (_faulted(rep, PathFault.EthMidRoute, i), 0);
            chain[i + 1] = next;
        }
        if (!_isEth(chain[n])) return (_faulted(rep, PathFault.NotToEth, n - 1), 0);

        rep.hops = new HopReport[](n);
        rep.qualifies = true;
        rep.strengthX18 = type(uint256).max;
        uint256 floor = minReferenceEth;
        amount = ethAmount;
        for (uint256 k = n; k > 0; --k) {
            uint256 i = k - 1;
            (uint160 sqrtPriceX96, uint256 depth) = _hopState(hops[i], chain[i + 1]);
            HopReport memory h = rep.hops[i];
            h.hop = hops[i];
            h.tokenIn = chain[i];
            h.tokenOut = chain[i + 1];
            h.depth = depth;
            h.floor = floor;
            h.qualifies = depth >= floor;
            if (!h.qualifies) rep.qualifies = false;
            uint256 strength = floor == 0 ? type(uint256).max : FullMath.mulDiv(depth, 1e18, floor);
            if (strength < rep.strengthX18) rep.strengthX18 = strength;

            if (i > 0) floor = _convertOrCap(sqrtPriceX96, floor, chain[i + 1], chain[i]);
            if (amount != 0) {
                if (amount > type(uint128).max) revert ConversionOverflow();
                amount = _quoteAtSqrtPrice(sqrtPriceX96, uint128(amount), chain[i + 1], chain[i]);
            }
        }
    }

    function _faulted(PathReport memory rep, PathFault fault, uint256 hopIndex)
        private
        pure
        returns (PathReport memory)
    {
        rep.fault = fault;
        rep.faultHop = hopIndex;
        rep.qualifies = false;
        return rep;
    }

    function _firstFailing(PathReport memory rep) private pure returns (uint256) {
        for (uint256 i = 0; i < rep.hops.length; ++i) {
            if (!rep.hops[i].qualifies) return i;
        }
        return 0;
    }

    /**
     * @dev Checks one hop is well formed and contains `tokenIn`, returning
     * the asset on the other side. For V3 the pool must exist at the factory
     * for the stated pair and fee; for V4 the hook must be allowed. Either
     * way the pool must be initialized.
     */
    function _step(Hop memory hop, address tokenIn) private view returns (address tokenOut, PathFault fault) {
        address c0 = Currency.unwrap(hop.key.currency0);
        address c1 = Currency.unwrap(hop.key.currency1);
        if (tokenIn == c0) tokenOut = c1;
        else if (tokenIn == c1) tokenOut = c0;
        else return (address(0), PathFault.Disconnected);

        if (hop.v3) {
            if (c0 == address(0)) return (tokenOut, PathFault.NativeOnV3);
            if (hop.key.tickSpacing != 0 || address(hop.key.hooks) != address(0)) {
                return (tokenOut, PathFault.V3KeyNotBare);
            }
            address pool = v3Factory.getPool(c0, c1, hop.key.fee);
            if (pool == address(0)) return (tokenOut, PathFault.NoV3Pool);
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            if (sqrtPriceX96 == 0) return (tokenOut, PathFault.NotInitialized);
        } else {
            if (!allowedV4Hooks[address(hop.key.hooks)]) return (tokenOut, PathFault.HookNotAllowed);
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(hop.key.toId());
            if (sqrtPriceX96 == 0) return (tokenOut, PathFault.NotInitialized);
        }
        return (tokenOut, PathFault.None);
    }

    /**
     * @dev A hop's spot price and how much of `side` it holds: the balance a
     * V3 pool physically holds, or `_v4Depth` for a V4 pool. Ranking V3
     * pools by the balance held rather than the `liquidity()` figure is
     * deliberate: that figure is nearly free to inflate with a narrow
     * position at an attacker-chosen tick, while tokens sent to a V3 pool
     * beyond its accounted reserves are simply lost, so displacing an honest
     * pool costs more than everything it holds.
     */
    function _hopState(Hop memory hop, address side) private view returns (uint160 sqrtPriceX96, uint256 depth) {
        if (hop.v3) {
            address pool = v3Factory.getPool(
                Currency.unwrap(hop.key.currency0), Currency.unwrap(hop.key.currency1), hop.key.fee
            );
            (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            depth = IERC20(side).balanceOf(pool);
        } else {
            PoolId id = hop.key.toId();
            int24 tick;
            (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
            uint128 liquidity = poolManager.getLiquidity(id);
            if (sqrtPriceX96 == 0 || liquidity == 0) return (sqrtPriceX96, 0);
            depth = _v4Depth(id, hop.key, side, sqrtPriceX96, tick, liquidity);
        }
    }

    /**
     * @dev How much of `side` a V4 pool holds, measured honestly.
     *
     * The V4 PoolManager keeps every pool's tokens in one balance, so there
     * is no `balanceOf` to read the way there is for V3. What this used to do
     * instead was report the constant-product VIRTUAL reserve implied by the
     * active liquidity, `L / sqrtP` for currency0 and `L * sqrtP` for
     * currency1. Only a full-range position actually holds those amounts. A
     * one-tick-wide position reports the same `L` while physically holding
     * about `L * 5e-5` of each token, so the 5 ETH floor could be cleared,
     * and a genuinely deep pool outranked, for about 0.0005 ETH. That is the
     * exact thing this contract's own comment on the V3 branch warns against.
     *
     * What is measured now, precisely: take the price band that reaches
     * `DEPTH_SQRT_WINDOW_BPS` of the square root of the price away from spot,
     * in the direction that pulls `side` out of the pool (up for currency0,
     * down for currency1), which is 500 bps of the square root, about 10.25%
     * of the price. Cut that band short at the nearest initialized tick in
     * that direction, because past that tick the active liquidity is a
     * different number and this one no longer describes the pool. Ask
     * Uniswap's own `getAmount0Delta` / `getAmount1Delta` how much of `side`
     * the active liquidity really holds across what is left of the band. That
     * amount is real: it is `side` sitting in the pool, in range, that
     * anybody may buy out of it right now.
     *
     * That figure is then scaled up by the reciprocal of the window, so the
     * number this function returns stays in the same units as the V3 branch's
     * `balanceOf` and the same 5 ETH floor keeps meaning what it meant. The
     * scaling is capped at the virtual reserve, so no pool is ever credited
     * with more than the constant-product figure it used to get: a full-range
     * position measures exactly as it did before this change, and every
     * narrower position measures less.
     *
     * What it costs to fake, which is the whole point: to be credited with a
     * depth of D, a pool must really hold at least `D * DEPTH_SQRT_WINDOW_BPS
     * / 10000` of the anchor within a 10% band of spot, so 0.25 ETH for the 5
     * ETH floor rather than 0.00025 ETH, a thousandfold. The residual gap to
     * the V3 branch, which demands the whole D, is that factor of twenty, and
     * it is the price of not being able to read a V4 pool's real balance
     * without walking every tick it has. Note that neither branch resists
     * capital borrowed for the length of one transaction; that limit is
     * documented at the top of this contract and is not what this measure is
     * for.
     */
    function _v4Depth(
        PoolId id,
        PoolKey memory key,
        address side,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity
    ) private view returns (uint256 depth) {
        int24 spacing = key.tickSpacing;
        if (spacing <= 0) return 0;

        bool sideIsCurrency0 = side == Currency.unwrap(key.currency0);
        uint256 move = (uint256(sqrtPriceX96) * DEPTH_SQRT_WINDOW_BPS) / BASIS_POINTS;
        if (move == 0) return 0;

        uint256 virtualReserve = sideIsCurrency0
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96)
            : FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96);

        uint256 inRange;
        if (sideIsCurrency0) {
            // Currency0 leaves the pool as the price rises.
            uint256 raised = uint256(sqrtPriceX96) + move;
            uint160 window = raised > TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE : uint160(raised);
            uint160 edge = _liquidityEdge(id, tick, spacing, true);
            // The active liquidity covers the whole band: nothing is cut
            // short, so the scaled figure is the constant-product one exactly
            // and is returned as such, without a rounding step to argue about.
            if (edge >= window) return virtualReserve;
            if (edge <= sqrtPriceX96) return 0;
            inRange = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, edge, liquidity, false);
        } else {
            // Currency1 leaves the pool as the price falls. `move` is a
            // fraction of the price itself, so the subtraction cannot wrap.
            uint160 window = uint160(uint256(sqrtPriceX96) - move);
            if (window < TickMath.MIN_SQRT_PRICE) window = TickMath.MIN_SQRT_PRICE;
            uint160 edge = _liquidityEdge(id, tick, spacing, false);
            if (edge <= window) return virtualReserve;
            if (edge >= sqrtPriceX96) return 0;
            inRange = SqrtPriceMath.getAmount1Delta(edge, sqrtPriceX96, liquidity, false);
        }

        // Scale the band back up to the units the V3 branch reports in, so
        // the same floor keeps its meaning. The currency0 amount goes as
        // 1/sqrtP rather than sqrtP, so its band is a factor (1 + w) smaller
        // for the same w; the numerator carries that.
        uint256 scaleNumerator = sideIsCurrency0 ? BASIS_POINTS + DEPTH_SQRT_WINDOW_BPS : BASIS_POINTS;
        depth = FullMath.mulDiv(inRange, scaleNumerator, DEPTH_SQRT_WINDOW_BPS);
        if (depth > virtualReserve) depth = virtualReserve;
    }

    /**
     * @dev The square root price at which the active liquidity stops being
     * the active liquidity, looking `up` or down from `tick`: the nearest
     * initialized tick found in `MAX_BITMAP_WORDS` words of the pool's tick
     * bitmap, or the end of the price range when there is none, which is the
     * honest answer for a position whose edge is out past the band being
     * measured.
     */
    function _liquidityEdge(PoolId id, int24 tick, int24 spacing, bool up) private view returns (uint160) {
        (bool found, int24 edgeTick) = _nextInitializedTick(id, tick, spacing, up);
        if (!found) return up ? TickMath.MAX_SQRT_PRICE : TickMath.MIN_SQRT_PRICE;
        return TickMath.getSqrtPriceAtTick(edgeTick);
    }

    /**
     * @dev The nearest initialized tick strictly above `tick`, or the nearest
     * at or below it, read out of the pool's tick bitmap the way a swap does.
     * Bounded: a pool nobody has put a position near is not worth more reads.
     */
    function _nextInitializedTick(PoolId id, int24 tick, int24 spacing, bool up)
        private
        view
        returns (bool found, int24 result)
    {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;

        if (up) {
            int24 cursor = compressed + 1;
            for (uint256 i = 0; i < MAX_BITMAP_WORDS; ++i) {
                (int16 wordPos, uint8 bitPos) = _bitmapPosition(cursor);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & (type(uint256).max << bitPos);
                if (masked != 0) {
                    int24 offset = int24(uint24(BitMath.leastSignificantBit(masked))) - int24(uint24(bitPos));
                    return (true, (cursor + offset) * spacing);
                }
                cursor += int24(256 - int256(uint256(bitPos)));
            }
        } else {
            int24 cursor = compressed;
            for (uint256 i = 0; i < MAX_BITMAP_WORDS; ++i) {
                (int16 wordPos, uint8 bitPos) = _bitmapPosition(cursor);
                uint256 mask = bitPos == 255 ? type(uint256).max : (uint256(1) << (bitPos + 1)) - 1;
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & mask;
                if (masked != 0) {
                    int24 offset = int24(uint24(BitMath.mostSignificantBit(masked))) - int24(uint24(bitPos));
                    return (true, (cursor + offset) * spacing);
                }
                cursor -= int24(int256(uint256(bitPos))) + 1;
            }
        }
    }

    /// @dev Uniswap's TickBitmap.position, on a compressed tick.
    function _bitmapPosition(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8);
        bitPos = uint8(uint24(compressed) & 0xff);
    }

    function _isEth(address token) private view returns (bool) {
        return token == address(0) || token == weth;
    }

    // ---------------------------------------------------------------------
    // Automatic pool selection
    // ---------------------------------------------------------------------

    /**
     * @dev The deepest pool pairing `token` with ETH (V3 WETH pool, V4
     * native or WETH pool) or with USDG, as a hop.
     */
    function _bestPool(address token, bool ethAnchor) private view returns (Hop memory hop, bool found) {
        address v3Anchor = ethAnchor ? weth : usdg;
        (address v3Pool, uint24 v3Fee, uint256 v3Depth) = _bestV3Pool(token, v3Anchor);
        (PoolKey memory v4Key, uint256 v4Depth, bool v4Found) = _bestV4Pool(token, ethAnchor);

        if (v3Pool == address(0) && !v4Found) return (hop, false);
        if (v3Pool != address(0) && (!v4Found || v3Depth >= v4Depth)) {
            (address c0, address c1) = token < v3Anchor ? (token, v3Anchor) : (v3Anchor, token);
            hop.key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: v3Fee,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            });
            hop.v3 = true;
        } else {
            hop.key = v4Key;
        }
        found = true;
    }

    /// @dev The standard-tier V3 pool for the pair holding the most of the anchor.
    function _bestV3Pool(address token, address anchor)
        private
        view
        returns (address best, uint24 bestFee, uint256 bestBalance)
    {
        uint24[4] memory tiers = [FEE_LOWEST, FEE_LOW, FEE_MEDIUM, FEE_HIGH];
        for (uint256 i = 0; i < tiers.length; ++i) {
            address pool = v3Factory.getPool(token, anchor, tiers[i]);
            if (pool == address(0)) continue;
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            if (sqrtPriceX96 == 0) continue;
            uint256 anchorBalance = IERC20(anchor).balanceOf(pool);
            if (anchorBalance > bestBalance) {
                bestBalance = anchorBalance;
                bestFee = tiers[i];
                best = pool;
            }
        }
    }

    /**
     * @dev The V4 pool pairing `token` with ETH (native or WETH) or USDG
     * with the deepest in-range anchor reserve, among hand-registered pools
     * and pools the registries know, whose hook is allowed.
     */
    function _bestV4Pool(address token, bool ethAnchor)
        private
        view
        returns (PoolKey memory bestKey, uint256 bestDepth, bool found)
    {
        bytes32[] storage ids = _v4PoolsOf[token];
        for (uint256 i = 0; i < ids.length; ++i) {
            V4Pool storage p = _v4Pools[ids[i]];
            (uint256 depth, bool ok) = _v4Candidate(p.key, p.anchor, ethAnchor);
            if (ok && (!found || depth > bestDepth)) (bestKey, bestDepth, found) = (p.key, depth, true);
        }
        for (uint256 i = 0; i < registries.length; ++i) {
            (bool has, PoolKey memory key) = _registryPool(registries[i], token);
            if (!has) continue;
            (address anchor, address priced, bool split) =
                _splitAnchor(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
            if (!split || priced != token) continue;
            (uint256 depth, bool ok) = _v4Candidate(key, anchor, ethAnchor);
            if (ok && (!found || depth > bestDepth)) (bestKey, bestDepth, found) = (key, depth, true);
        }
    }

    /**
     * @dev A registry that reverts is skipped, not fatal. The code check
     * matters: a high-level call to an address without code reverts in the
     * caller, outside the try, and would take every launch down with it.
     */
    function _registryPool(IQuoteReferenceRegistry registry, address token)
        private
        view
        returns (bool found, PoolKey memory key)
    {
        if (address(registry).code.length == 0) return (false, key);
        try registry.referencePool(token) returns (bool f, PoolKey memory k) {
            return (f, k);
        } catch {
            return (false, key);
        }
    }

    function _v4Candidate(PoolKey memory key, address anchor, bool ethAnchor)
        private
        view
        returns (uint256 depth, bool ok)
    {
        if (_isEth(anchor) != ethAnchor) return (0, false);
        if (!allowedV4Hooks[address(key.hooks)]) return (0, false);
        Hop memory hop;
        hop.key = key;
        (, depth) = _hopState(hop, anchor);
        ok = depth > 0;
    }

    function _splitAnchor(address c0, address c1) private view returns (address anchor, address token, bool ok) {
        if (_isEth(c0) || _isEth(c1)) {
            // An ETH side always anchors, so an ETH/USDG pool prices USDG.
            return _isEth(c0) ? (c0, c1, true) : (c1, c0, true);
        }
        if (c0 == usdg) return (c0, c1, true);
        if (c1 == usdg) return (c1, c0, true);
        return (address(0), address(0), false);
    }

    // ---------------------------------------------------------------------
    // Conversion
    // ---------------------------------------------------------------------

    /// @dev Like `_quoteAtSqrtPrice` but saturates instead of reverting, for floors.
    function _convertOrCap(uint160 sqrtPriceX96, uint256 amount, address base, address quote)
        private
        pure
        returns (uint256)
    {
        if (amount > type(uint128).max) return type(uint256).max;
        return _quoteAtSqrtPrice(sqrtPriceX96, uint128(amount), base, quote);
    }

    /**
     * @dev Port of Uniswap V3 OracleLibrary.getQuoteAtTick, taking the sqrt
     * price directly. `baseToken` and `quoteToken` are the pool's currency
     * addresses (address zero for native ETH), so their ordering is the
     * pool's own.
     */
    function _quoteAtSqrtPrice(uint160 sqrtRatioX96, uint128 baseAmount, address baseToken, address quoteToken)
        private
        pure
        returns (uint256 quoteAmount)
    {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
