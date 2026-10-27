// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPairPadFeeEscrow, IPairPadLaunchFactory} from "../v2/interfaces/ILaunchpadV2.sol";
import {IPairPadMultiLaunchFactory} from "../v3/interfaces/ILaunchpadV3.sol";

/**
 * @notice The single-market factory as a burn vault reads it: a launch's
 * record plus the key of its pool. Same shape the locker uses.
 */
interface IBurnVaultLaunchFactory is IPairPadLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
}

/**
 * @notice The one call the deployed vaults make on their own factory: which
 * launch a vault address belongs to. Written once, when the vault is
 * deployed, and never again.
 */
interface IBurnVaultRegistry {
    function tokenOf(address vault) external view returns (address token);
}

/**
 * @notice The one call this vault makes on PairPadRouter. A launch pool is a
 * plain hookless V4 pool, so the router's single-pool exact-input swap is all
 * the plumbing a buyback needs; multi-market pools are the same shape and go
 * through the same call.
 */
interface ISwapper {
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable returns (uint256 amountOut);
}

/**
 * @notice Reads shared by a vault and by the factory that deploys them, so
 * the factory can answer for a launch whose vault has not been deployed yet
 * without a second copy of the logic.
 */
library PairPadBurnVaultLib {
    /// @dev Neither factory has a record of this token.
    error UnknownLaunch(address token);

    /**
     * @dev A launch's pools and their quote assets, in market order. Single
     * market first, since that is the common case; a token belongs to exactly
     * one of the two factories.
     */
    function marketsOf(IBurnVaultLaunchFactory factory, IPairPadMultiLaunchFactory multiFactory, address token)
        internal
        view
        returns (PoolKey[] memory keys, address[] memory quotes)
    {
        IPairPadLaunchFactory.LaunchedToken memory single = factory.getLaunchedToken(token);
        if (single.exists) {
            keys = new PoolKey[](1);
            quotes = new address[](1);
            keys[0] = factory.poolKeyFor(token);
            quotes[0] = single.pairToken;
            return (keys, quotes);
        }
        IPairPadMultiLaunchFactory.LaunchedToken memory multi = multiFactory.getLaunchedToken(token);
        if (!multi.exists) revert UnknownLaunch(token);
        IPairPadMultiLaunchFactory.Market[] memory markets = multiFactory.getMarkets(token);
        keys = multiFactory.poolKeysFor(token);
        quotes = new address[](markets.length);
        for (uint256 i = 0; i < markets.length; i++) {
            quotes[i] = markets[i].pairToken;
        }
    }

    /**
     * @dev What `who` holds plus what the escrow owes it in `asset`. The
     * escrow's half is always readable; the asset's own `balanceOf` is a call
     * into code nobody has vouched for and can revert, so it is wrapped and
     * counted as zero when it does. A keeper reading a launch with one frozen
     * quote still gets an answer for the rest of it.
     */
    function pending(IPairPadFeeEscrow escrow, address who, address asset) internal view returns (uint256) {
        if (asset == address(0)) return who.balance + escrow.balanceOf(who);
        uint256 held;
        try IERC20(asset).balanceOf(who) returns (uint256 b) {
            held = b;
        } catch {}
        return held + escrow.balanceOfToken(who, asset);
    }
}

/**
 * @title PairPadBurnVault
 * @notice The creator fee recipient of one launch whose creator chose, at
 * creation, to burn the creator's share of trading fees instead of keeping it
 * ("buyback and burn"). A creator names this address as `creatorFeeRecipient`
 * in the launch params, exactly as any other recipient, so nothing about the
 * factories or the launch transaction changes.
 *
 * ## One vault per launch
 *
 * This contract is the implementation behind an EIP-1167 minimal proxy that
 * PairPadBurnVaultFactory deploys with CREATE2 at an address derived from the
 * launch token, one clone per launch. That is not a detail: PairPadFeeEscrow
 * keys claimable balances by recipient address alone, so a vault shared by
 * several launches would pool every launch's quote-side fees into one balance
 * per asset, and whoever called `burn` first would spend the pooled balance,
 * including the part other launches' traders paid, on buying back their own
 * token. One address per launch makes the escrow's per-recipient accounting
 * per-launch accounting, exactly, for free.
 *
 * The address is known before the launch transaction is sent
 * (`PairPadBurnVaultFactory.vaultFor`), so the launch form can name it in the
 * params, and the clone itself can be deployed by anyone at any time, before
 * or after the launch: fees credited to an address with no code yet sit in
 * the escrow until the clone that claims them exists.
 *
 * ## Naming it is irreversible, and that is the whole point
 *
 * By inspection:
 *
 * - There is no owner, no `Ownable`, no admin role and no initializer.
 * - Every stored address is `immutable`, set once when the implementation is
 *   constructed and shared by every clone. A clone stores no addresses of its
 *   own: it asks its factory which launch it belongs to, and the factory
 *   writes that answer once, when it deploys the clone.
 * - There is no setter, no `transferCreatorFeeRecipient` forwarder, no
 *   `withdraw`, no `rescue`, no `sweep`, no arbitrary-call path and no
 *   upgrade hook, so nothing that arrives here can leave except as a swap
 *   into the launch token followed by that token being burned.
 * - `burn` is open to anyone and always ends at `ERC20Burnable.burn`.
 *
 * A minimal proxy does of course delegatecall, to one address hard-coded in
 * its own runtime code by the factory that deployed it and readable in the 45
 * bytes at the clone's address. There is no admin slot, no beacon and no
 * function that can change where the clone delegates, so the code that runs
 * behind a vault address is as fixed as the code at a plain deployment.
 *
 * The factories let only a launch's current recipient hand the recipient role
 * on, and this contract has no code that can make that call, so once a launch
 * names its vault the choice cannot be taken back. (The factory owner retains
 * the timelocked `setCreatorFeeRecipient` path every launch is subject to;
 * that is a property of the factory, not of this vault.)
 *
 * ## What `burn` does
 *
 * The lockers credit the creator share of every collection to the fee escrow
 * under this address, in the pool's two currencies: the launch token for
 * sells, the quote asset for buys. `burn()`:
 *
 *   1. claims this vault's escrow balance in the launch token,
 *   2. claims its escrow balance in each of the launch's quote assets and
 *      swaps it into the launch token through that market's own pool
 *      (one pool for a single-market launch, up to five for a multi-market
 *      one), through PairPadRouter,
 *   3. burns everything the vault then holds of the launch token.
 *
 * Both sides are exactly this launch's: nothing else is ever paid in this
 * token, and no other launch's fees are ever credited to this address.
 *
 * Burning means `ERC20Burnable.burn`, not a transfer to 0x..dEaD: every
 * launch token is a PairPadLauncherToken, which is ERC20Burnable, so
 * `totalSupply` really falls. That is the same path the locker already uses
 * for the protocol's token-side share (`ProtocolShareBurned`), so a burn
 * total read off `totalSupply` stays honest.
 *
 * ## What the buyback pays
 *
 * Every swap carries a floor: at least what the pool's own pre-swap price
 * says the input is worth, less the pool's fee and `SWAP_TOLERANCE_BPS`. On
 * top of that, no single call may move the pool's price by more than
 * `MAX_SQRT_MOVE_BPS` of the square root of the price, about 1% of the price;
 * a quote balance larger than that buys in slices, one per call, and the rest
 * waits. The cap is what makes the buyback not worth sandwiching, since a
 * sandwich's whole profit is the price impact of the trade it wraps and both
 * of its legs pay the pool's fee, which is 1.1% at the least and up to 11.1%
 * on a launch with the full creator tax. The floor is what catches everything
 * else: a broken pool, a router that misbehaves, an input that would be
 * filled at a price the pool's own state does not support.
 *
 * ## The awkward cases, all of them non-reverting except the last
 *
 * - Nothing to claim: `burn` reverts with `NothingToBurn` and no state moves,
 *   so a keeper's wasted call costs gas and nothing else.
 * - A market with no usable pool (never initialized, or no liquidity in
 *   range): the swap is not attempted at all, and that market's quote stays
 *   here for a later call.
 * - A quote asset that refuses this address, or reverts on `balanceOf`, at
 *   any of the three points where this contract touches it: the escrow claim,
 *   the balance read and the swap are each wrapped in `try`, so that market is
 *   skipped and every other market, and the launch-token side, complete
 *   normally. Whatever could not be claimed stays claimable in the escrow and
 *   whatever is already held here stays here, for a call that can move it.
 *   `burnMarket(index)` runs a single market for the same reason the multi
 *   locker has `collectMarketFees`: a healthy market never has to wait on a
 *   sick one.
 * - A swap that reverts, including on its own slippage floor (an empty or
 *   broken pool): the quote stays in this contract and the next `burn` picks
 *   it up along with whatever has accrued since. The vault's own balance is
 *   swept on every call, not just what the escrow paid out.
 *
 * What is honestly NOT promised, since an earlier version of this comment
 * promised it: value is not unstrandable. A quote asset that refuses this
 * address for good leaves its own balance stuck for good, in the escrow or
 * here, because this contract has no withdrawal path and never will. What is
 * promised is that the failure stays inside the market that caused it.
 * - A swap that consumes less than it was offered (the price cap above, or a
 *   pool that ran out of range): the router returns the remainder here and it
 *   waits for the next call.
 * - Dust: an amount under `MIN_QUOTE_SWAP` raw units is left to accumulate
 *   rather than swapped, since the swap would cost more gas than the value
 *   it moves.
 * - A launch neither factory knows: `UnknownLaunch`. An address that is not a
 *   vault this factory deployed, the implementation included: `NotAVault`.
 */
contract PairPadBurnVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Raw quote units below which the quote side is left to
     * accumulate instead of being swapped. 1000 units is 1000 wei of ETH and
     * 0.001 of a six-decimal dollar: negligible either way, and far below the
     * gas a swap costs.
     */
    uint256 public constant MIN_QUOTE_SWAP = 1000;

    /**
     * @notice The most one call may move the square root of a pool's price,
     * in basis points: 50 bps of the square root is about 100 bps (1%) of the
     * price itself. A larger quote balance is spent in slices, one per call,
     * and what a slice leaves behind waits for the next one.
     *
     * This is the number that makes sandwiching a buyback unprofitable. A
     * sandwich earns the price impact of the trade it wraps and pays the
     * pool's fee on both of its own legs; a launch pool charges 1.1% at the
     * least (the base fee with no creator tax) and up to 11.1%, so a 2.2%
     * round trip against at most 1% of impact to capture is a loss before the
     * attacker's gas. It also bounds what any one call can pay away when the
     * price is somewhere strange for reasons of its own, since `burn` is open
     * to anyone and its caller chooses the moment.
     */
    uint256 public constant MAX_SQRT_MOVE_BPS = 50;

    /**
     * @notice How far below the pool's own pre-swap valuation of the input a
     * swap may land before it is refused, in basis points.
     *
     * The floor is the input, less the pool's fee, valued at the pool's
     * current price, less this. A swap that moves the square root of the
     * price by the full `MAX_SQRT_MOVE_BPS` fills exactly 50 bps under that
     * valuation (the average price along the curve against the price at the
     * start of it), so 100 bps is the cap plus 50 bps of headroom for
     * rounding and for the tick crossings of any liquidity somebody else has
     * added to the pool. Tighter and honest burns would start being refused;
     * looser and the headroom would be worth more than the swap it protects.
     */
    uint256 public constant SWAP_TOLERANCE_BPS = 100;

    uint256 private constant BASIS_POINTS = 10_000;
    /// @dev Uniswap fees are hundredths of a bip: 1% is 10_000 of 1_000_000.
    uint256 private constant PIPS = 1_000_000;

    /// @notice The factory that deployed this vault and knows which launch it is.
    IBurnVaultRegistry public immutable vaults;
    /// @notice Ledger the lockers credit this vault's share of fees to.
    IPairPadFeeEscrow public immutable escrow;
    /// @notice PairPadRouter, used only for exact-input swaps into launch pools.
    ISwapper public immutable router;
    /// @notice The single-market factory: launch records and pool keys.
    IBurnVaultLaunchFactory public immutable factory;
    /// @notice The multi-market factory: the same, per market.
    IPairPadMultiLaunchFactory public immutable multiFactory;
    /// @notice Uniswap's PoolManager, read for the price a swap must beat.
    IPoolManager public immutable poolManager;

    /// @notice Running total this vault has burned of its launch token.
    uint256 public burnedTotal;

    /**
     * @notice One `burn` call. `quotes` are the launch's quote assets in
     * market order (address zero for native ETH) and `quoteSpent` what each
     * swap actually consumed, so a market that was skipped or whose swap
     * reverted shows zero. `amount` is what was burned now, `totalBurned` the
     * running total for this token, which is what a token page shows.
     */
    event Burned(address indexed token, address[] quotes, uint256[] quoteSpent, uint256 amount, uint256 totalBurned);

    error ZeroAddress();
    /// @dev This address is not a vault: the implementation, or an impostor.
    error NotAVault();
    /// @dev Nothing was claimable and nothing was held: the call is a no-op.
    error NothingToBurn(address token);
    /// @dev `burnMarket` was given an index this launch does not have.
    error MarketOutOfRange(address token, uint256 index, uint256 markets);

    constructor(
        IBurnVaultRegistry vaults_,
        IPairPadFeeEscrow escrow_,
        ISwapper router_,
        IBurnVaultLaunchFactory factory_,
        IPairPadMultiLaunchFactory multiFactory_,
        IPoolManager poolManager_
    ) {
        if (
            address(vaults_) == address(0) || address(escrow_) == address(0) || address(router_) == address(0)
                || address(factory_) == address(0) || address(multiFactory_) == address(0)
                || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        vaults = vaults_;
        escrow = escrow_;
        router = router_;
        factory = factory_;
        multiFactory = multiFactory_;
        poolManager = poolManager_;
    }

    /// @dev The escrow pays claimed ETH here, and the router returns whatever
    /// a swap could not consume.
    receive() external payable {}

    /**
     * @notice The launch this vault burns, and the only one it can: the
     * factory recorded it when it deployed this clone and has no way to
     * change it. Reverts on the implementation itself, which is nobody's
     * vault and can therefore never burn or spend anything.
     */
    function token() public view returns (address launchToken) {
        launchToken = vaults.tokenOf(address(this));
        if (launchToken == address(0)) revert NotAVault();
    }

    /**
     * @notice Buys this launch's token back with everything this vault holds
     * and can claim for it, and burns the lot. Open to anyone: there is no
     * recipient to choose and no parameter to tune, so a stranger calling it
     * only ever pays the gas for a burn that was going to happen anyway.
     * @return amount Tokens burned by this call.
     */
    function burn() external nonReentrant returns (uint256 amount) {
        return _burn(_everyMarket());
    }

    /**
     * @notice `burn()` restricted to one of the launch's markets, for routing
     * around a market whose quote asset has stopped working. The launch-token
     * side is claimed and burned exactly as in a full round; the other markets
     * are simply not touched, so nothing they hold is spent or put at risk.
     * @param index The market's position in `pendingBurn`'s `quotes`.
     */
    function burnMarket(uint256 index) external nonReentrant returns (uint256 amount) {
        uint256[] memory only = new uint256[](1);
        only[0] = index;
        return _burn(only);
    }

    /// @notice `burnMarket` over a chosen set of markets, in the order given.
    function burnMarkets(uint256[] calldata indexes) external nonReentrant returns (uint256 amount) {
        return _burn(indexes);
    }

    /**
     * @dev The body of every burn. Nothing outside this contract is trusted
     * to behave: the escrow claim, the balance read and the swap are each
     * wrapped, so one quote asset that reverts on a transfer to this address
     * or on `balanceOf` costs its own market its turn and costs the other
     * markets, and the launch-token side, nothing at all.
     */
    function _burn(uint256[] memory indexes) private returns (uint256 amount) {
        address launchToken = token();
        (PoolKey[] memory keys, address[] memory quotes) =
            PairPadBurnVaultLib.marketsOf(factory, multiFactory, launchToken);
        uint256 n = quotes.length;
        uint256[] memory spent = new uint256[](n);

        _tryClaim(launchToken);

        for (uint256 j = 0; j < indexes.length; j++) {
            uint256 i = indexes[j];
            if (i >= n) revert MarketOutOfRange(launchToken, i, n);
            address quote = quotes[i];
            _tryClaim(quote);
            (uint256 available, bool readable) = _tryBalanceOf(quote);
            if (!readable || available < MIN_QUOTE_SWAP) continue;
            spent[i] = _swap(keys[i], quote, available);
        }

        amount = IERC20(launchToken).balanceOf(address(this));
        if (amount == 0) revert NothingToBurn(launchToken);

        ERC20Burnable(launchToken).burn(amount);
        uint256 total = burnedTotal + amount;
        burnedTotal = total;
        emit Burned(launchToken, quotes, spent, amount, total);
    }

    /// @dev Every market index, in market order.
    function _everyMarket() private view returns (uint256[] memory indexes) {
        (, address[] memory quotes) = PairPadBurnVaultLib.marketsOf(factory, multiFactory, token());
        indexes = new uint256[](quotes.length);
        for (uint256 i = 0; i < quotes.length; i++) {
            indexes[i] = i;
        }
    }

    /**
     * @notice What the next `burn()` would work with: the launch token
     * already claimable or held, and the same per quote asset in market
     * order. A quote side under `MIN_QUOTE_SWAP` will be left alone, and one
     * over the price cap will be spent over several calls.
     */
    function pendingBurn()
        external
        view
        returns (uint256 tokenSide, address[] memory quotes, uint256[] memory quoteSides)
    {
        address launchToken = token();
        (, quotes) = PairPadBurnVaultLib.marketsOf(factory, multiFactory, launchToken);
        tokenSide = _pending(launchToken);
        quoteSides = new uint256[](quotes.length);
        for (uint256 i = 0; i < quotes.length; i++) {
            quoteSides[i] = _pending(quotes[i]);
        }
    }

    /// @notice What this vault holds plus what the escrow owes it in `asset`.
    function pending(address asset) public view returns (uint256) {
        return _pending(asset);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /**
     * @dev Pulls this vault's escrow balance in `asset` out, if any, and
     * shrugs when it cannot. The escrow's own ledger is sound, but the claim
     * ends in a transfer of `asset` to this address, and a quote asset may
     * refuse that: USDC and USDT can blacklist an address, an upgradeable
     * token can start refusing at any time, and a frozen token refuses
     * everyone. Left unwrapped, any of those took the whole burn down with
     * it, including the launch-token side, which has nothing to do with the
     * asset that failed. What is not claimed stays claimable.
     */
    function _tryClaim(address asset) private {
        if (asset == address(0)) {
            if (escrow.balanceOf(address(this)) > 0) {
                try escrow.claim() {} catch {}
            }
        } else if (escrow.balanceOfToken(address(this), asset) > 0) {
            try escrow.claimToken(asset) {} catch {}
        }
    }

    /**
     * @dev One quote-side buyback through the launch pool, output kept here
     * for the burn. The input is capped so the swap cannot move the pool
     * more than `MAX_SQRT_MOVE_BPS` and carries a floor derived from the
     * pool's pre-swap price; a failure of either kind leaves the quote where
     * it is for the next call rather than taking the whole burn down with it.
     * @return consumed The quote the swap actually took.
     */
    function _swap(PoolKey memory key, address quote, uint256 available) private returns (uint256 consumed) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        // No pool, no liquidity in range, or a fee that is not a plain static
        // one: nothing to price the swap against, so nothing is attempted and
        // the quote waits for a call that can.
        if (sqrtPriceX96 == 0 || liquidity == 0 || key.fee >= PIPS) return 0;

        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        uint256 amountIn = _cappedInput(sqrtPriceX96, liquidity, key.fee, zeroForOne, available);
        if (amountIn < MIN_QUOTE_SWAP) return 0;
        (uint256 minOut, bool ok) = _floor(sqrtPriceX96, key.fee, zeroForOne, amountIn);
        if (!ok) return 0;

        (uint256 before, bool readable) = _tryBalanceOf(quote);
        if (!readable) return 0;
        if (quote == address(0)) {
            try router.swapExactIn{value: amountIn}(key, zeroForOne, amountIn, minOut, address(this)) returns (
                uint256
            ) {}
            catch {
                return 0;
            }
        } else {
            IERC20(quote).forceApprove(address(router), amountIn);
            try router.swapExactIn(key, zeroForOne, amountIn, minOut, address(this)) returns (uint256) {}
            catch {
                IERC20(quote).forceApprove(address(router), 0);
                return 0;
            }
            IERC20(quote).forceApprove(address(router), 0);
        }
        (uint256 remaining, bool stillReadable) = _tryBalanceOf(quote);
        if (!stillReadable) return 0;
        return before > remaining ? before - remaining : 0;
    }

    /**
     * @dev `available`, or as much of it as moves the square root of the
     * pool's price by at most `MAX_SQRT_MOVE_BPS`, whichever is smaller. The
     * band is priced with the pool's own math at the liquidity in range, then
     * grossed up by the pool's fee, since the fee is taken off the input
     * before any of it reaches the curve.
     */
    function _cappedInput(uint160 sqrtPriceX96, uint128 liquidity, uint24 fee, bool zeroForOne, uint256 available)
        private
        pure
        returns (uint256)
    {
        uint256 move = (uint256(sqrtPriceX96) * MAX_SQRT_MOVE_BPS) / BASIS_POINTS;
        if (move == 0) return 0;
        uint256 net;
        if (zeroForOne) {
            // Selling currency0 into the pool takes the price down.
            uint160 target = uint160(uint256(sqrtPriceX96) - move);
            if (target < TickMath.MIN_SQRT_PRICE) target = TickMath.MIN_SQRT_PRICE;
            net = SqrtPriceMath.getAmount0Delta(target, sqrtPriceX96, liquidity, true);
        } else {
            uint256 raised = uint256(sqrtPriceX96) + move;
            uint160 target = raised > TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE : uint160(raised);
            net = SqrtPriceMath.getAmount1Delta(sqrtPriceX96, target, liquidity, true);
        }
        if (net == 0) return 0;
        uint256 cap = FullMath.mulDiv(net, PIPS, PIPS - fee);
        return available < cap ? available : cap;
    }

    /**
     * @dev The least a swap of `amountIn` may return: the input less the
     * pool's fee, valued at the pool's current price, less
     * `SWAP_TOLERANCE_BPS`. `ok` is false when the figure cannot be computed
     * at all, in which case the swap is skipped rather than sent without a
     * floor.
     */
    function _floor(uint160 sqrtPriceX96, uint24 fee, bool zeroForOne, uint256 amountIn)
        private
        pure
        returns (uint256 minOut, bool ok)
    {
        uint256 net = amountIn - FullMath.mulDivRoundingUp(amountIn, fee, PIPS);
        if (net == 0 || net > type(uint128).max) return (0, false);
        uint256 valued = _valueAtSqrtPrice(sqrtPriceX96, uint128(net), zeroForOne);
        if (valued == 0) return (0, false);
        return ((valued * (BASIS_POINTS - SWAP_TOLERANCE_BPS)) / BASIS_POINTS, true);
    }

    /**
     * @dev What `amount` of the pool's input side is worth in its output side
     * at `sqrtRatioX96`, ignoring the curve. Port of Uniswap V3
     * OracleLibrary.getQuoteAtTick taking the square root price directly, the
     * same one PairPadQuotePricer uses; `zeroForOne` says which side the
     * amount is on, so no address ordering is needed here.
     */
    function _valueAtSqrtPrice(uint160 sqrtRatioX96, uint128 amount, bool zeroForOne) private pure returns (uint256) {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return
                zeroForOne ? FullMath.mulDiv(ratioX192, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return zeroForOne ? FullMath.mulDiv(ratioX128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratioX128);
    }

    /**
     * @dev What this vault holds of `asset`. `balanceOf` is a call into the
     * asset's own code and a frozen or hostile token can revert from it,
     * which is one step earlier than a refused transfer and used to take the
     * whole burn down the same way. `ok` false means the market is skipped.
     */
    function _tryBalanceOf(address asset) private view returns (uint256 balance, bool ok) {
        if (asset == address(0)) return (address(this).balance, true);
        try IERC20(asset).balanceOf(address(this)) returns (uint256 b) {
            return (b, true);
        } catch {
            return (0, false);
        }
    }

    function _pending(address asset) private view returns (uint256) {
        return PairPadBurnVaultLib.pending(escrow, address(this), asset);
    }
}

/**
 * @title PairPadBurnVaultFactory
 * @notice Deploys and addresses the burn vaults: one per launch, at an
 * address derived from the launch token, so the fee escrow's per-recipient
 * accounting is per-launch accounting.
 *
 * A vault is an EIP-1167 minimal proxy over one shared implementation, which
 * this contract deploys in its own constructor and can never replace. The
 * salt is the launch token address, so `vaultFor(token)` is the vault's
 * address whether or not it has been deployed yet: a launch form can compute
 * it before the launch transaction and name it as `creatorFeeRecipient`, and
 * the clone itself can be deployed by anyone, before or after that launch.
 * Nothing is lost by deploying late, because fees credited to an address with
 * no code sit in the escrow until the code that claims them exists.
 *
 * This contract has no owner and nothing to configure. `deploy` is open and
 * idempotent, `tokenOf` is written once per vault and never again, and the
 * only thing it can do besides deploy is forward `burn` to a vault, which is
 * open to anyone there as well.
 */
contract PairPadBurnVaultFactory is IBurnVaultRegistry {
    /// @notice The implementation every vault delegates to, deployed here.
    address public immutable implementation;
    /// @notice keccak256 of a vault's creation code, for off-chain derivation.
    bytes32 public immutable proxyInitCodeHash;

    /// @notice Ledger the lockers credit vaults' fees to.
    IPairPadFeeEscrow public immutable escrow;
    /// @notice PairPadRouter, the vaults' only swap venue.
    ISwapper public immutable router;
    /// @notice The single-market factory: launch records and pool keys.
    IBurnVaultLaunchFactory public immutable factory;
    /// @notice The multi-market factory: the same, per market.
    IPairPadMultiLaunchFactory public immutable multiFactory;
    /// @notice Uniswap's PoolManager, read for the price a buyback must beat.
    IPoolManager public immutable poolManager;

    /// @notice The launch a deployed vault belongs to. Written once, at deploy.
    mapping(address vault => address token) public tokenOf;

    event VaultDeployed(address indexed token, address indexed vault);

    error ZeroAddress();
    error DeployFailed(address token);

    constructor(
        IPairPadFeeEscrow escrow_,
        ISwapper router_,
        IBurnVaultLaunchFactory factory_,
        IPairPadMultiLaunchFactory multiFactory_,
        IPoolManager poolManager_
    ) {
        if (
            address(escrow_) == address(0) || address(router_) == address(0) || address(factory_) == address(0)
                || address(multiFactory_) == address(0) || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        escrow = escrow_;
        router = router_;
        factory = factory_;
        multiFactory = multiFactory_;
        poolManager = poolManager_;
        // The implementation is deployed here, so a vault's code is fixed by
        // this contract's own construction and there is no address to hand in
        // and nothing to point anywhere else afterwards.
        address impl = address(new PairPadBurnVault(this, escrow_, router_, factory_, multiFactory_, poolManager_));
        implementation = impl;
        proxyInitCodeHash = keccak256(_proxyInitCode(impl));
    }

    /**
     * @notice The vault address for `token`, deployed or not. CREATE2 with
     * the token address as the salt, so this is also derivable off chain from
     * this contract's address and `proxyInitCodeHash` alone.
     */
    function vaultFor(address token) public view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(token))), proxyInitCodeHash)
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice Whether `token`'s vault has been deployed yet.
    function isDeployed(address token) public view returns (bool) {
        return vaultFor(token).code.length != 0;
    }

    /**
     * @notice Deploys `token`'s vault if it does not exist yet and returns
     * it either way. Open to anyone and safe to call twice; the launch itself
     * does not need it to have happened.
     */
    function deploy(address token) public returns (address vault) {
        vault = vaultFor(token);
        if (vault.code.length != 0) return vault;
        if (token == address(0)) revert ZeroAddress();

        bytes memory initCode = _proxyInitCode(implementation);
        bytes32 salt = bytes32(uint256(uint160(token)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (deployed != vault) revert DeployFailed(token);
        tokenOf[deployed] = token;
        emit VaultDeployed(token, deployed);
    }

    /**
     * @notice One buyback-and-burn round for `token`, deploying its vault
     * first if this is the first one. The keeper's whole job in one call.
     * @return amount Tokens burned by this call.
     */
    function burn(address token) external returns (uint256 amount) {
        return PairPadBurnVault(payable(deploy(token))).burn();
    }

    /**
     * @notice One buyback-and-burn round for `token` over a single market,
     * mirroring PairPadMultiLaunchLocker's `collectMarketFees`. The way round
     * a market whose quote asset has stopped accepting transfers to the
     * vault: the rest of the launch, and the launch-token side, carry on.
     * @param index The market's position in `pendingBurn`'s `quotes`.
     */
    function burnMarket(address token, uint256 index) external returns (uint256 amount) {
        return PairPadBurnVault(payable(deploy(token))).burnMarket(index);
    }

    /// @notice `burnMarket` over a chosen set of markets, in the order given.
    function burnMarkets(address token, uint256[] calldata indexes) external returns (uint256 amount) {
        return PairPadBurnVault(payable(deploy(token))).burnMarkets(indexes);
    }

    /**
     * @notice What the next `burn(token)` would work with: the launch token
     * already claimable or held by the vault, and the same per quote asset in
     * market order. Answers for a vault that has not been deployed yet too,
     * since the escrow credits the address, not the code.
     */
    function pendingBurn(address token)
        external
        view
        returns (uint256 tokenSide, address[] memory quotes, uint256[] memory quoteSides)
    {
        address vault = vaultFor(token);
        (, quotes) = PairPadBurnVaultLib.marketsOf(factory, multiFactory, token);
        tokenSide = PairPadBurnVaultLib.pending(escrow, vault, token);
        quoteSides = new uint256[](quotes.length);
        for (uint256 i = 0; i < quotes.length; i++) {
            quoteSides[i] = PairPadBurnVaultLib.pending(escrow, vault, quotes[i]);
        }
    }

    /// @notice What `token`'s vault has burned in total; zero before it exists.
    function burnedTotal(address token) external view returns (uint256) {
        address vault = vaultFor(token);
        if (vault.code.length == 0) return 0;
        return PairPadBurnVault(payable(vault)).burnedTotal();
    }

    /**
     * @dev The 55 bytes of EIP-1167: 10 bytes that return the 45-byte runtime,
     * then the runtime itself with the implementation address in the middle.
     */
    function _proxyInitCode(address impl) private pure returns (bytes memory) {
        return
            abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
