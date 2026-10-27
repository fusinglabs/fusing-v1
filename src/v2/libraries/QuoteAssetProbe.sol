// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title QuoteAssetProbe
 * @notice Proves a candidate quote asset moves exact amounts before a launch
 * opens a pool against it.
 *
 * The quote pricer cannot answer this. It measures a hop's depth as the
 * balance of the side NEARER ETH, so for a direct pool against WETH the only
 * balance it ever reads is WETH's; nothing in the route walk touches the
 * candidate's own transfer code. A token that takes a cut on transfer, or one
 * whose balance is derived from shares and rounds down, therefore clears the
 * depth floor exactly as a well behaved token does.
 *
 * What that costs if it is not caught here: the launch itself succeeds,
 * because the opening position holds only the launched token and no quote
 * asset moves at creation. The damage lands afterwards. A buy denominated in
 * the quote asset settles an exact amount into the Uniswap V4 PoolManager, so
 * less arrives than the swap owes and the whole call reverts with
 * CurrencyNotSettled; and fee collection moves exact amounts into the escrow,
 * so it reverts with PairPadLaunchLocker.InexactTransfer. The launch is left
 * open, its whole supply locked in a position, and its market broken.
 *
 * The probe is a round trip: `amount` is pulled from the payer and sent
 * straight back, and both legs must arrive to the wei. Two directions because
 * a token may tax only one of them, and the same check catches share-rounding
 * rebasers because their transfers arrive one or two wei short in either
 * direction.
 *
 * It is run once per asset, not once per launch, through
 * PairPadQuotePricer.proveExactTransfers, which anyone may call and which
 * funds itself from the caller. That keeps the protocol's design property
 * intact: a creator launching against an ERC-20 quote still needs to hold
 * nothing but ETH.
 *
 * What it does NOT catch, stated plainly because a check that looks total and
 * is not is worse than one that is honestly partial:
 *
 * - a token that taxes only above a threshold larger than the probe;
 * - a token that exempts particular addresses, where the payer and the caller
 *   both happen to be exempt (a taxed token that whitelists its own pool and
 *   router is the common shape, and this probe does catch that one, because it
 *   moves tokens between two addresses that are on no such list);
 * - a token that is upgradeable or has an owner switch and turns its tax on
 *   after the launch;
 * - a fee small enough to round to zero at the probe size;
 * - a rebasing token whose transfers are exact and whose balances only move on
 *   a separate rebase call. Such a token passes here and still breaks the
 *   locker's accounting later.
 *
 * None of those are reachable by the honest creator who picks a popular taxed
 * token, which is the case this exists to stop.
 */
library QuoteAssetProbe {
    using SafeERC20 for IERC20;

    /// @dev A probe leg arrived short (or long).
    error QuoteAssetInexact(address asset, uint256 sent, uint256 received);
    /// @dev The probe amount rounded to zero, so nothing could be proven.
    error QuoteAssetProbeTooSmall(address asset);

    /// @dev The probe has to be worth this fraction of the pricer's depth
    /// floor. A percentage fee on a large enough amount cannot round to zero,
    /// and the whole amount comes straight back, so the only real cost is gas.
    uint256 internal constant PROBE_DIVISOR = 1_000;

    /**
     * @notice Moves `amount` of `asset` from `payer` to this contract and back,
     * reverting unless both legs arrive exactly. Leaves no balance behind and
     * needs the payer's allowance for `amount` only.
     */
    function requireExactTransfers(address asset, address payer, uint256 amount) internal {
        if (amount == 0) revert QuoteAssetProbeTooSmall(asset);

        IERC20 token = IERC20(asset);
        uint256 payerBefore = token.balanceOf(payer);
        uint256 selfBefore = token.balanceOf(address(this));

        // Inbound leg.
        token.safeTransferFrom(payer, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - selfBefore;
        if (received != amount) revert QuoteAssetInexact(asset, amount, received);

        // Outbound leg. The payer must end exactly where it started.
        token.safeTransfer(payer, amount);
        uint256 payerAfter = token.balanceOf(payer);
        if (payerAfter != payerBefore) {
            revert QuoteAssetInexact(asset, amount, amount - (payerBefore - payerAfter));
        }
        // And nothing may be left here, which a token that credits the sender
        // rather than the recipient would otherwise leave behind.
        uint256 selfAfter = token.balanceOf(address(this));
        if (selfAfter != selfBefore) revert QuoteAssetInexact(asset, amount, selfAfter - selfBefore);
    }
}
