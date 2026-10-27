// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PairPadLauncherToken} from "./PairPadLauncherToken.sol";

/**
 * @notice Every input PairPadLaunchFactory hands the deployer to stand up one
 * launch token.
 */
struct LaunchDeployment {
    address originalDeployer;
    address supplyRecipient;
    uint256 supply;
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    PairPadLauncherToken.Socials socials;
}

/**
 * @title PairPadLaunchDeployer
 * @notice Deploys the launch token for one PairPad launch on the factory's
 * behalf. Split out into its own contract purely so PairPadLaunchFactory's
 * own bytecode stays under EIP-170's 24576-byte deployed-code limit:
 * embedding the token's creation code via `new` inside the factory itself
 * is the single largest contributor to its size. The token still records
 * the real factory's address (never this deployer's).
 */
/**
 * @dev The slice of the factory this contract reads: the guard a launcher
 * staged for their next launch.
 *
 * Read from here rather than carried through the launch call because adding
 * it to the launch path pushed the factory past what the compiler can keep on
 * the stack. This keeps the launch path byte-identical to what it was.
 */
interface IGuardConfig {
    function guardSecondsOf(address launcher) external view returns (uint64);
    function guardListOf(address launcher) external view returns (address[] memory);
}

contract PairPadLaunchDeployer {
    // Metadata is stored on the token and read back by unbounded-return view
    // functions, so an unbounded write here becomes a permanently unreadable
    // token: `socials()` returns all five strings at once and would run out
    // of gas or time out an RPC node. Bounding the write is the only place
    // the limit can be enforced, since the strings are immutable afterwards.
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;
    uint256 private constant MAX_LOGO_LENGTH = 512;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 private constant MAX_SOCIAL_LENGTH = 256;

    error NotFactory();
    error MetadataTooLong();

    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert NotFactory();
        factory = factory_;
    }

    /**
     * @notice Deploys a fresh launch token and returns its address.
     */
    function deployToken(LaunchDeployment calldata params) external onlyFactory returns (address token) {
        _requireMetadataWithinLimits(params);

        // CREATE2, namespaced per initiating account, so a caller's chosen
        // salt only has to be unique among their own launches and the
        // resulting address can be predicted (or vanity-mined) off chain.
        // Reusing a salt on identical terms reverts on the address collision.
        bytes32 tokenSalt = keccak256(abi.encode(params.originalDeployer, params.salt));
        token = address(
            new PairPadLauncherToken{salt: tokenSalt}(
                params.name,
                params.symbol,
                params.logo,
                params.description,
                params.socials,
                params.originalDeployer,
                factory,
                params.supplyRecipient,
                params.supply,
                IGuardConfig(factory).guardSecondsOf(params.originalDeployer)
            )
        );

        // Name the permitted addresses while the token still accepts them.
        address[] memory list = IGuardConfig(factory).guardListOf(params.originalDeployer);
        if (list.length > 0 && IGuardConfig(factory).guardSecondsOf(params.originalDeployer) > 0) {
            PairPadLauncherToken(token).initGuardList(list);
        }
    }

    /**
     * @notice The address `deployToken` would return for these inputs, so a
     * launch's token address can be known before the transaction is sent.
     */
    function predictTokenAddress(LaunchDeployment calldata params) external view returns (address) {
        bytes32 tokenSalt = keccak256(abi.encode(params.originalDeployer, params.salt));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), tokenSalt, _initCodeHash(params)))))
        );
    }

    /**
     * @dev Split out, and taking its argument in memory, because encoding
     * eleven constructor arguments straight off calldata runs the Yul
     * optimizer out of stack slots. Copying to memory first costs a little
     * gas on a view function and keeps the encoding in one place, which
     * matters more: this hash and the one CREATE2 uses in `deployToken` have
     * to agree exactly or a mined address lands somewhere else.
     */
    function _initCodeHash(LaunchDeployment memory params) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(PairPadLauncherToken).creationCode,
                abi.encode(
                    params.name,
                    params.symbol,
                    params.logo,
                    params.description,
                    params.socials,
                    params.originalDeployer,
                    factory,
                    params.supplyRecipient,
                    params.supply,
                    IGuardConfig(factory).guardSecondsOf(params.originalDeployer)
                )
            )
        );
    }

    function _requireMetadataWithinLimits(LaunchDeployment calldata params) private pure {
        if (
            bytes(params.name).length > MAX_NAME_LENGTH || bytes(params.symbol).length > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (
            bytes(params.socials.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.website).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}
