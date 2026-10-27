// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title PairPadLauncherToken
 * @notice Fixed-supply ERC-20 deployed by PairPadLaunchFactory for a launch.
 * The entire supply is minted in the launch transaction and, in that same
 * transaction, placed into the launch's Uniswap V4 pool as one permanently
 * locked position. Anyone, the deployer included, may buy any amount from
 * the pool at any time; price impact is the only limit on a large buy.
 * `deployer` is carried here as immutable reference data for off-chain
 * attribution only, and confers no privileges over the token.
 * `ERC20Burnable` lets any holder voluntarily burn their own balance; the
 * protocol itself never burns anything.
 */
contract PairPadLauncherToken is ERC20, ERC20Burnable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    error ZeroAddress();
    /// @dev A transfer to a non-permitted address while the launch guard is open.
    error LaunchGuardActive(address to, uint64 endsAt);
    /// @dev The guard window exceeded what this contract will accept.
    error GuardWindowTooLong(uint64 asked, uint64 max);
    /// @dev Only the contract that deployed this token may name the guard list.
    error NotCreator();
    /// @dev The guard list is written once and cannot change.
    error GuardListAlreadySet();

    /**
     * The longest a launch may be gated. Long enough for a coordinated opening
     * buy to land in the next block, short enough that it cannot be used to
     * hold a market closed. There is no owner and no way to extend it.
     */
    uint64 public constant MAX_GUARD_SECONDS = 60;


    address public immutable deployer;
    address public immutable launchFactory;
    /// @dev Whoever ran CREATE2 for this token: the launch deployer contract.
    address public immutable creator;

    /**
     * When the launch guard expires, as a unix timestamp. Zero means the token
     * was never gated and every transfer has always been open.
     *
     * While it is in the future, tokens may only move TO an address on
     * `guardAllowed`. That is the whole restriction: one-way, unextendable,
     * no owner, and once the timestamp passes this is an ordinary ERC-20
     * forever.
     *
     * It exists because a launch is public in the mempool before its pool can
     * be traded, so without it the opening block belongs to whoever watches
     * hardest rather than to whoever launched. Anyone can read exactly who was
     * permitted and for how long.
     */
    uint64 public immutable guardEndsAt;

    /// @notice Addresses that may receive tokens while the guard is closed.
    mapping(address account => bool allowed) public guardAllowed;

    /// @dev Write-once, so nobody can add to the list afterwards.
    bool public guardListSet;



    string public logo;
    string public description;

    Socials private _socials;

    /**
     * @notice Creates a launch token and mints its entire supply to
     * `supplyRecipient`, the factory helper that seeds the pool position.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        string memory logo_,
        string memory description_,
        Socials memory socials_,
        address deployer_,
        address launchFactory_,
        address supplyRecipient_,
        uint256 supply_,
        uint64 guardSeconds_
    ) ERC20(name_, symbol_) {
        if (deployer_ == address(0) || supplyRecipient_ == address(0) || launchFactory_ == address(0)) {
            revert ZeroAddress();
        }
        if (guardSeconds_ > MAX_GUARD_SECONDS) revert GuardWindowTooLong(guardSeconds_, MAX_GUARD_SECONDS);
        creator = msg.sender;
        if (guardSeconds_ > 0) {
            guardEndsAt = uint64(block.timestamp) + guardSeconds_;
            // The pool plumbing must be able to hold the token or the launch
            // cannot complete: the supply is minted here and moved into the
            // position in this same transaction.
            guardAllowed[supplyRecipient_] = true;
        }

        deployer = deployer_;
        // Passed explicitly rather than read from msg.sender: PairPadLaunchFactory
        // deploys this token indirectly through PairPadLaunchDeployer to keep its
        // own bytecode under EIP-170's size limit, so msg.sender at construction
        // time would otherwise resolve to that deployer helper, not the factory.
        launchFactory = launchFactory_;
        logo = logo_;
        description = description_;
        _socials = socials_;

        _mint(supplyRecipient_, supply_);
    }


    /**
     * @notice Names the accounts that may receive the token while the guard is
     * closed. Callable once, by the contract that deployed this token, in the
     * launch transaction.
     *
     * The list lives here rather than in the constructor so the token's CREATE2
     * address does not depend on who is on it: an address can be mined before
     * the wallets are chosen, and the list cannot be read off the address.
     */
    function initGuardList(address[] calldata list) external {
        if (msg.sender != creator) revert NotCreator();
        if (guardListSet) revert GuardListAlreadySet();
        guardListSet = true;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] != address(0)) guardAllowed[list[i]] = true;
        }
    }

    /// @notice Whether the guard is still closed to the public.
    function guardActive() external view returns (bool) {
        return guardEndsAt != 0 && block.timestamp < guardEndsAt;
    }

    /**
     * @dev The guard, and the only behaviour this adds to a plain ERC-20.
     *
     * Gates the recipient rather than the sender, because what is being
     * prevented is an outsider ending up holding the token in the opening
     * block. Gating senders would mean permitting the pool, and permitting the
     * pool would let it pay anybody.
     *
     * Minting is always allowed, or the supply could never reach the position.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (guardEndsAt != 0 && block.timestamp < guardEndsAt && from != address(0) && !guardAllowed[to]) {
            revert LaunchGuardActive(to, guardEndsAt);
        }
        super._update(from, to, value);
    }

    /**
     * @notice Returns the launch token's five social metadata fields.
     */
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        Socials memory values = _socials;
        return (values.twitter, values.telegram, values.discord, values.website, values.farcaster);
    }

    /**
     * @notice Returns creator and metadata in the launcher-compatible tuple.
     */
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        return (deployer, logo, description, _socials);
    }

    /**
     * @notice Contract-level metadata per ERC-7572, assembled on the fly from
     * the fields stored at launch and returned as an inline JSON data URI.
     * Terminals that know nothing about this launchpad read the token's
     * image and links from here, so the JSON carries the keys they look for:
     * `image`, `description`, `external_url`, and each social under its own
     * name, repeated under `extensions` for readers that expect it there.
     * Every launch field is immutable, so the URI never changes and no
     * `ContractURIUpdated` is ever emitted.
     */
    function contractURI() external view returns (string memory) {
        return _metadata();
    }

    /**
     * @notice Same document as `contractURI`, under the name some readers try
     * first (Zora-style coins expose their metadata as `tokenURI`).
     */
    function tokenURI() external view returns (string memory) {
        return _metadata();
    }

    /**
     * @notice Nothing controls this token: no owner, no mint, no pause. The
     * function exists so scanners that test for a renounced owner find one.
     */
    function owner() external pure returns (address) {
        return address(0);
    }

    function _metadata() private view returns (string memory) {
        string memory links = _links();
        return string.concat(
            "data:application/json;utf8,",
            '{"name":"',
            _jsonEscape(name()),
            '","symbol":"',
            _jsonEscape(symbol()),
            '","description":"',
            _jsonEscape(description),
            '","image":"',
            _jsonEscape(logo),
            '"',
            _field("external_url", _socials.website),
            _field("external_link", _socials.website),
            links,
            ',"extensions":{',
            bytes(links).length == 0 ? "" : _stripLeadingComma(links),
            "}}"
        );
    }

    function _links() private view returns (string memory) {
        return string.concat(
            _field("website", _socials.website),
            _field("twitter", _socials.twitter),
            _field("telegram", _socials.telegram),
            _field("discord", _socials.discord),
            _field("farcaster", _socials.farcaster)
        );
    }

    /// @dev `,"key":"value"`, or nothing when the value is empty.
    function _field(string memory key, string memory value) private pure returns (string memory) {
        if (bytes(value).length == 0) return "";
        return string.concat(',"', key, '":"', _jsonEscape(value), '"');
    }

    function _stripLeadingComma(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length - 1);
        for (uint256 i = 1; i < b.length; ++i) {
            out[i - 1] = b[i];
        }
        return string(out);
    }

    /**
     * @dev Escapes `s` for use inside a JSON string literal: quotes,
     * backslashes and control characters. Metadata is bounded by the
     * deployer, so the byte-by-byte pass stays cheap even for a full
     * description.
     */
    function _jsonEscape(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\" || c == "\n" || c == "\r" || c == "\t") extra += 1;
            else if (uint8(c) < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        bytes16 hexChars = "0123456789abcdef";
        uint256 j;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (c == "\n") {
                out[j++] = "\\";
                out[j++] = "n";
            } else if (c == "\r") {
                out[j++] = "\\";
                out[j++] = "r";
            } else if (c == "\t") {
                out[j++] = "\\";
                out[j++] = "t";
            } else if (uint8(c) < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(c) >> 4];
                out[j++] = hexChars[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }
}
