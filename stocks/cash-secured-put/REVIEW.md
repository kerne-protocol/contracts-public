# Review record: KerneCashSecuredPutVault

This is not an audit and it was not done by an outside firm. It is the record of three in-house
review rounds run on 2026-11-12 by reviewers that did not write the contract (separate AI reviewer
passes, each reading the code cold), what each found, and how each finding was closed. Every fix
that changes behaviour has a regression test named below, and each of those tests was checked to
fail when its fix is removed.

## Round 1 (two reviewers, first version)

Reviewer A did a line-by-line security pass with proof-of-concept tests. Reviewer B reviewed the
mechanism: who can profit at whose expense.

| # | Severity | Finding | Fix | Regression test |
|---|---|---|---|---|
| 1 | High (A: H-1, B: H-2) | Every assignment moves USDC out of `totalAssets` while shares stay, so later deposits mint far more shares per USDC. Once supply outgrew the accumulator scale (1e27) the stock credit truncated to zero and delivered stock was stranded. A sole depositor could force this in seven self-dealt epochs for a fraction of a cent. | Accumulator scale raised to 1e60 and the division remainder is carried forward, so the credit is exact at any supply. An epoch sells nothing with next to no shares outstanding. Deposits are refused once supply would pass 1e55. (Refined in rounds 2 and 3.) | `test_selfDealtRatchetCannotStrandStock`, `test_ratchetEndsInRefusedDepositsNotLostStock`, `test_belowMinSupplySellsNothing`, `testFuzz_stockCreditsMatchDelivered` |
| 2 | High (B: H-1), Medium (A: M-1) | A put could be bought against a feed print up to 4 hours old at the premium fixed at open. With the reference market closed or halted and the token still trading, a buyer could buy a put that was already in the money and lock in a riskless profit of several percent of the vault. | Sales only on weekdays 14:35 to 19:55 UTC, inside the US cash session in both daylight-saving regimes. At most 10% of an epoch's capacity can be sold against one oracle round. The keeper can end a sale early (`closeSale`) and raise, never lower, the premium (`raisePremium`). The 4 hour staleness bound and the out-of-the-money re-check stay. | `test_afterCloseSaleBlocked`, `test_weekendSaleBlocked`, `test_perRoundSaleCap`, `test_keeperCanEndSaleEarly`, `test_keeperCanOnlyRaisePremium` |
| 3 | Medium (B: M-2), Low (A: L-1, L-6) | The exit window was read at the next open, so the owner could cut it after settlement, and owner parameter changes took effect at once. Hard bounds allowed a 0.01% OTM floor, a 0.01% premium floor, 90 day epochs, a 7 day exercise window and a 1 hour exit window. | The exit window is frozen per epoch at open. No epoch can open for a full exit window (12 hours minimum) after a settlement or after any parameter or keeper change. Hard bounds tightened: OTM floor at least 1%, premium floor at least 10 bps, epochs at most 45 days, exercise window 6 hours to 3 days, exit window at least 12 hours. | `test_idleWindowFrozenAtOpen`, `test_paramOrKeeperChangeGivesNotice`, `test_paramBounds` |
| 4 | Medium (B: M-4), Low (A: L-2) | A one-unit purchase (a millionth of a dollar of premium) blocked early settlement and kept the vault locked to the end of the exercise window. | A purchase must pay at least 1/100,000 of the epoch's capacity in premium. | `test_dustPurchaseRefused` |
| 5 | Medium (B: M-3) | The buyer holds a free timing option from expiry to the end of the exercise window. | Not a code defect; the right is disclosed as lasting until `exerciseEnd`. The window is capped at 3 days and cannot be shorter than 6 hours. | `test_exerciseOnlyInsideWindow`, `test_paramBounds` |
| 6 | Medium (B: M-1) | The premium floor is flat and far below fair value for long epochs; a fixed price for the whole sale lets a buyer pick the moment. | Partly closed: the keeper can raise the premium and end the sale. The floor remains a flat backstop; pricing stays a stated trust assumption in the keeper. | `test_keeperCanOnlyRaisePremium` |
| 7 | Low (B: L-2, A: L-4) | Shares could move while an epoch was live: a holder could leave ahead of an assignment, and borrowed shares could capture delivered stock. | Share transfers revert while an epoch is live. | `test_shareTransfersFrozenWhileLive`, `test_flowsFrozenDuringEpoch` |
| 8 | Low (B: L-1) | A buyer who became blocked on the stock token lost the option. | `transferPut` moves a put to another address. | `test_blockedBuyerCanMoveThePut` |
| 9 | Low (B: L-1) | Exercise reverted if the token delivered less than asked. | The vault pays for and credits exactly what arrived; the rest of the put stays with the buyer. | `test_exercisePaysOnWhatArrived` |
| 10 | Low (A: L-5) | A purchase carried no epoch id, so a late transaction could land on a later epoch's strike. | `buyPut` takes the epoch id and reverts on a mismatch. | `test_buyMustNameTheLiveEpoch` |
| 11 | Low (A: L-3) | `maxMint` reverted at very large deposit caps. | The cap is bounded and the max views are supply-aware. | `test_maxViewsNeverRevertAtLargestCap` |
| 12 | Low (A: L-7) | `claimStock` to the vault itself would strand the stock. | Refused. | `test_stockCreditedProRata` |

Reviewer A also read the live token and feed on Base: TSLAc balances are raw and do not rebase,
`transfer` returns true, the issuer policy is a blocklist, and the feed prints around the clock on
weekdays on moves of about 0.5% and is silent on weekends. The contract's comments were corrected
to match.

## Round 2 (one reviewer, re-review of the changed contract)

Reviewer C confirmed the round-1 fixes item by item (collateral, sale-hours arithmetic, the
per-round cap, the frozen exit window, the transfer freeze, short delivery, epoch id, max views)
and found problems introduced by the fix for item 1.

| # | Severity | Finding | Fix | Regression test |
|---|---|---|---|---|
| C-1 | Medium | The supply floor added for item 1 was a fixed share count (1e12). A plain USDC transfer into the empty vault raises the share price, so a $1 donation kept a $1,000,000 vault under the floor and stopped every sale for good. | The floor is now the shares one unit of USDC mints at par (1e6). Any deposit larger than the donation clears it, so the attack costs at least what it blocks. | `test_donationToClosedVaultCannotStopSales`, `test_oneDollarDonationCannotStopAMillionDollarVault`, `test_donationAfterTheVaultEmptiesCannotStopSales`, `test_depositSmallerThanDonationSellsNothing` |
| C-2 | Medium | The ratchet from item 1 now ended in refused deposits instead of lost stock, but one address acting as dominant depositor and only buyer could force that end in about 14 self-dealt epochs for a few dollars, and the vault stayed shut for as long as that address left anything in. | A wind-down valve: once the share price has fallen 1e24 times below par, the owner may redeem a holder into a pull escrow at exactly the redeem price. Escrowed cash is outside `totalAssets` and outside every epoch's capacity. (Hardened in round 3.) | `test_forcedRetirementIsNotPermanent`, `test_windDownGuards` |
| C-3 | Low on TSLAc, critical with a callback token | `exercise` wrote back a cached balance after the stock transfer and the new `transferPut` had no reentrancy guard, so a stock token with a sender hook let one put be exercised repeatedly. Not reachable with a B20 precompile. | `transferPut` is `nonReentrant` and `exercise` re-reads storage after the transfer. | `test_hookTokenCannotReenter` |
| C-4 | Low | The notice after a parameter change used the new exit window, so a 7 day window could be replaced by 12 hours with only 12 hours' notice. | The notice is the longer of the old and the new window. | `test_shorteningTheWindowStillWaitsTheOldOne` |
| C-5 | Low | "Inside the US cash session" is not true on market holidays and half-days, which the contract cannot know. | Stated in the contract header and README; the per-round cap and staleness bound still apply, and the keeper should end the sale ahead of those dates. | none (documentation) |

## Round 3 (one reviewer, the round-2 changes only)

Reviewer D's verdict was that the contract could be deployed closed. It confirmed the lower supply
floor with numeric overflow bounds, that a wind-down pays exactly the redeem price and leaves other
holders and all put collateral whole, the notice ordering, and the reentrancy coverage.

| # | Severity | Finding | Fix | Regression test |
|---|---|---|---|---|
| D-1 | Low | A holder could dodge `windDown` by moving shares to a fresh address before each owner call, keeping the vault shut. | While the vault is winding down, shares do not move between holders and deposits are refused, so the owner's call always lands. Leaving by redeeming is always possible. | `test_windDownCannotBeDodged` |
| D-2 | Info | Four sentences in the contract header claimed more than the code delivers (cash leaving only through exercise, every entry point guarded, pinning, when the valve closes). | Reworded to what the code does. | none (comments) |
| D-3 | Info | The random-sequence suite did not cover the wind-down code. | Added a fuzz test that mixes forced wind-downs, redemptions and escrow claims in any order and checks cash conservation, plus pinned-bound tests for the supply floor. | `testFuzz_windDownAnyOrderConservesCash`, `test_windDownIsExactlyARedeemAndEscrowIsOutsideCapacity`, `testFuzz_valveShutInOrdinaryStates`, `test_fullAssignmentAtTheSupplyFloor`, `test_overflowBoundIsWhereTheMathSaysItIs` |
| D-4 | Info | `renounceOwnership` would remove the valve and freeze the parameters for good. | Disabled; ownership can still be handed over in two steps. | `test_ownershipCannotBeRenounced` |

The round-3 fixes (D-1, D-4) are a few lines and were not sent for a fourth pass. They follow the
fix reviewer D proposed, and their tests fail when the lines are removed.

## Left as stated limits, not fixed in code

- The keeper prices the premium; the floor is a flat backstop.
- A halt, an early close, a market holiday or an outage inside sale hours can still be sold
  against, up to 10% of an epoch per oracle round.
- Depositors are a standing bid for the token at the strike.
- The vault depends on both token issuers. Stray tokens sent to the vault cannot be recovered.
- After about 8 full assignments at a 0.1% premium (12 at 1%) the vault enters wind-down and needs
  the owner to redeem holders before it takes deposits again.
- The B20 precompile cannot be executed in the local test suite (the stock there is a mock). The
  deploy script simulates the real constructor against the live token; a small end-to-end epoch on
  mainnet should be run before any cap is raised.
