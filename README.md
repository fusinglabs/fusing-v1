# fusi.ng V1

The first fusi.ng release (September 2026): single-pool and multi-pool launches on Uniswap V4.

Solidity smart contracts of [fusi.ng](https://fusi.ng), a token launchpad on Ethereum built on Uniswap V4. Ethereum mainnet only.

- Website: https://fusi.ng
- Docs and ABIs: https://fusi.ng/docs#tech
- X: https://x.com/fusi_ng
- Telegram: https://t.me/fusi_ng

## Deployed contracts (Ethereum mainnet)

| Role | Address | Contract | Source status |
| --- | --- | --- | --- |
| factory | [`0x1550e8ac48eb9edaeaefcc9e84ba3a445141db64`](https://etherscan.io/address/0x1550e8ac48eb9edaeaefcc9e84ba3a445141db64) | PairPadLaunchFactory | verified on Etherscan |
| router | [`0x505d4494669fb32b61cf81bff52b2d4a6a24d32f`](https://etherscan.io/address/0x505d4494669fb32b61cf81bff52b2d4a6a24d32f) | PairPadRouter | verified on Etherscan |
| locker | [`0x7dc54744ba6037dd7b5220326dc7a4488a6524c6`](https://etherscan.io/address/0x7dc54744ba6037dd7b5220326dc7a4488a6524c6) | PairPadLaunchLocker | verified on Etherscan |
| feeEscrow | [`0xb04b1e2d2782738287c21ab7accb3eced9546d0f`](https://etherscan.io/address/0xb04b1e2d2782738287c21ab7accb3eced9546d0f) | PairPadFeeEscrow | verified on Etherscan |
| multiFactory | [`0x5366386ade8ba4a2b67b6a8065196b07fea2d08d`](https://etherscan.io/address/0x5366386ade8ba4a2b67b6a8065196b07fea2d08d) | PairPadMultiLaunchFactory | verified on Etherscan |
| multiRouter | [`0x382b2093f5c0a4fdb5c7a5ec6e665945834136cb`](https://etherscan.io/address/0x382b2093f5c0a4fdb5c7a5ec6e665945834136cb) | PairPadMultiRouter | verified on Etherscan |
| multiLocker | [`0xd711136c067f88f2c952c4e0ee068253f139abb4`](https://etherscan.io/address/0xd711136c067f88f2c952c4e0ee068253f139abb4) | PairPadMultiLaunchLocker | verified on Etherscan |
| burnVaultFactory | [`0x44f20a9b4d0e27d84cbb52e69705c84d65383674`](https://etherscan.io/address/0x44f20a9b4d0e27d84cbb52e69705c84d65383674) | PairPadBurnVaultFactory | verified on Etherscan |

## Source note

Every file here is exactly the source verified on Etherscan for the contracts above. Where two contracts in this stack were compiled from different revisions of the same file, the second revision is kept under `variants/<role>/`. Third-party libraries (Uniswap V4, OpenZeppelin and others) are not included; their exact versions are part of each contract's verified bundle on Etherscan.

Compiler: solc 0.8.26. Exact compiler settings are in each verified contract on Etherscan.

## License

MIT, as declared in each file's SPDX header.
