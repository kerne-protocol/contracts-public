# Audit scope reference

For security firms scoping a review of Kerne Protocol. Generated 2026-06-12 from the verified source mirror in [`contracts/`](../contracts/README.md); every file below is bytecode-matched to its deployed address on Base mainnet (chain 8453).

## Tier 1 — core risk-bearing contracts (deployed), ~960 nSLOC

| Contract | File | Address | nSLOC |
|---|---|---|---|
| kUSD | `contracts/kUSD/src/kUSD.sol` | `0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3` | 17 |
| skUSD | `contracts/skUSD/src/skUSD.sol` | `0xdEd74F7E06efc76455C07418b8b74Cc2bc009DB4` | 57 |
| KUSDPSM | `contracts/KUSDPSM/src/KUSDPSM.sol` | `0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc` | 309 |
| KerneVault | `contracts/KerneVault/src/KerneVault.sol` | `0x8005bc7A86AD904C20fd62788ABED7546c1cF2AC` | 577 |

Note on "the minter": earlier RFP materials listed a `kUSDMinter` contract in the core scope. `kUSDMinter` is **not deployed** (it is Phase 2/3 leverage infrastructure). All live minting runs through `KUSDPSM` and `KerneVault`, both in Tier 1, so the deployed core scope is these 4 contracts.

## Tier 2 — full deployed verified surface, ~1,683 nSLOC

Tier 1 plus:

| Contract | File | Address | nSLOC |
|---|---|---|---|
| KERNE (v2) | `contracts/KERNE/src/KerneTokenV2.sol` | `0x230f3a63E8413D42bEe9103b98a204030206186c` | 95 |
| esKERNE | `contracts/esKERNE/src/esKERNE.sol` | `0x29c1d396A35aB75a8Bb8dC3949f98edFa5f25b34` | 148 |
| KerneTreasury | `contracts/KerneTreasury/src/KerneTreasury.sol` | `0x7c07517ABcc4BD674CC74B76D2Ab0d95A41560d5` | 191 |
| KerneInsuranceFund | `contracts/KerneInsuranceFund/src/KerneInsuranceFund.sol` | `0xE8799FCF327C6D2f78103a3c9308C93592A30403` | 108 |
| KerneReferral | `contracts/KerneReferral/src/KerneReferral.sol` | `0x1A04AF62baFc84b08b19d2aF7285eD5f8dAe4D9f` | 29 |
| KerneYieldDistributor | `contracts/KerneYieldDistributor/src/KerneYieldDistributor.sol` | `0x096e38a04B632D28E017f86836225E0956CaD878` | 50 |
| KerneYieldOracle | `contracts/KerneYieldOracle/src/KerneYieldOracle.sol` | `0x8DE2d5ac5aBc7331a6E1d450a5c021db18599CdB` | 102 |

## nSLOC method

Non-blank, non-comment lines of the primary contract file per bundle. OpenZeppelin dependencies, project interfaces, and the deploy-time dependency copies inside each bundle are excluded from the counts (they are present in `contracts/` for compilation completeness).

## Deployed vs source

Where deployed bytecode differs from the current source (three standing divergences, each with a mitigation and an operating rule), see [`DEPLOYED_VS_SOURCE.md`](DEPLOYED_VS_SOURCE.md). Read it before triaging any finding marked FIXED in Kerne's internal documents: FIXED means fixed in source, and that file is the canonical record of what is and is not live on chain.

## Out of scope

- The off-chain hedging engine, risk engine, and operational tooling (Python, not smart contracts).
- Frontends (kerne.fi, app.kerne.fi).
- Undeployed in-development contracts (including `kUSDMinter`).
- `KerneStaking` and `KerneFlashArbBot`: deployed but not source-verified (disclosed in the [root README](../README.md)); both are queued for redeploy-and-verify and can be added to scope at that point.
