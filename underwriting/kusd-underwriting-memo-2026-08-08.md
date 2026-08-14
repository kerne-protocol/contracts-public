# kUSD underwriting memo

**For a lending curator or risk reviewer. Dated 2026-08-08.**

Every number below was read from Base mainnet (chain 8453) on 2026-08-08 between blocks 49,722,336
and 49,725,387, on at least two independent RPC endpoints that agreed exactly. Where a figure moves,
the memo says so and names the endpoint to re-read rather than freezing a stale number. Every claim
comes with the call that produces it. Nothing here has to be taken on our word, and section 10 is a
script that reproduces the whole memo from chain in under a minute.

This document exists because a reviewer named Oleg_Aleksandrov spent thirty-five days trying to break
Kerne in public on the Euler forum, and because his verifications are worth more than our assertions.
Section 7 is his words, not ours.

---

## 0. Read this first. The five facts that argue against us.

A memo that opens with the good news is asking you to find the bad news yourself. Here it is.

**1. We have paid almost nothing.** Realized yield on skUSD is **0.0022% annualized** over the
trailing 30 days, measured as on-chain share price growth. Our advertised forward rate is **4.7%**.
That is **0.05% of what we advertise**. On our own public comparison board, which ranks fifteen
synthetic dollars including ours, every other protocol with a comparable window pays between 91% and
102% of its advertised rate. We are last, by three orders of magnitude, on a board we built and
publish ourselves. The single realized distribution the live staking vault has ever received was a
0.10 kUSD plumbing test on 2026-07-09.

**2. The book is tiny and it is ours.** 1,109.71 kUSD outstanding against 1,110.89 USDC of reserves.
It is founder-seeded genesis capital. External holders are under one percent of supply. There is no
organic demand in these numbers and we are not going to imply there is.

**3. The insurance fund holds zero while the APY model deducts 10% for it.** `insurance_fund_usd` is
`0.0` in the signed attestation. The published yield model applies a 10% insurance allocation
haircut. The haircut is real in the arithmetic and the fund is empty in fact.

**4. The audited commit is not the deployed commit.** All ten Hexens findings are live on the vault
bytecode running today. The live mint PSM is the exception and it matters: its deployed bytecode is
compiled from exactly the source Hexens reviewed, byte for byte. The vault is not.

**5. The binding constraint, stated plainly: a 48-hour governance action can mint unlimited kUSD.**
`DEFAULT_ADMIN_ROLE` on kUSD sits with a `TimelockController` at a 172,800 second delay. That admin
can grant `MINTER_ROLE` to any address. Any lending market that prices kUSD at par can then be drained
by minting collateral from nothing and borrowing against it. **This is true of every kUSD market that
exists, including the one this memo proposes, and it is the reason a curator's cap is the real
control rather than anything we can put in a contract.** The delay is 48 hours of public notice, and
nothing currently monitors the timelock queue. We say more about that in section 4.

If any of those five is disqualifying for you, stop here. That is a legitimate answer and we would
rather you reach it in ten minutes than in three weeks.

---

## 1. What kUSD is

kUSD is a synthetic dollar on Base. Today its backing is **entirely USDC held in on-chain Peg
Stability Modules**, not the delta-neutral basis position the design describes. The basis position
exists, it is small, and **it does not back a single kUSD today**. Oleg established that
independently and we agreed with him on the record.

| | |
|---|---|
| kUSD | `0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3`, 18 decimals |
| skUSD, ERC-4626 staked wrapper | `0x96F5102C15b839757f811A98CEc3725Ac21DfA14`, **24 decimals** |
| USDC, loan asset | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, 6 decimals |
| Governance Safe, 2 of 3 | `0x52d3E450bA6c299B1B07298F1E87DD74732D4877` |
| TimelockController, 48h | `0x36A14976980B7Dd33136f6613545EB0A2C0a0D72` |
| Pause Guardian | `0xC47adaf51907bB1871D07E18eA21dc75Ae93Cc8E` |

Match on the address, not the ticker. Other projects use the string "kUSD" on other chains.

**skUSD is 24 decimals.** That is unusual and it breaks naive integrations. Any oracle or vault
wrapper touching skUSD must be fork-tested before it goes near capital.

---

## 2. Reserves and the backing ratio, with the calls

Reserves sit across three PSM modules, not one. A reviewer who reads only the live mint module will
understate backing by 97%.

| module | address | role | USDC held |
|---|---|---|---|
| live mint PSM | `0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803` | holds `MINTER_ROLE`, receives every mint since the 2026-07-10 cutover | 30.000000 |
| retired mint PSM | `0x07eBb486e11BD217e6085eb5ab663e4517595993` | `MINTER_ROLE` revoked, still custodies reserve for pre-cutover kUSD | 995.003000 |
| redeem reserve PSM | `0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc` | redemption reserve | 85.885006 |
| **total** | | | **1,110.888006** |

The denominator is **outstanding** kUSD, not raw `totalSupply`. The PSM contracts keep the kUSD a
redeemer hands over rather than burning it, so `totalSupply` counts kUSD the protocol itself holds
and nobody can present as a claim.

```
totalSupply          1,144.707154 kUSD
less PSM inventory      35.000000 kUSD   (3.0 at 0x07eBb486, 32.0 at 0xFf3025ec, 0 at 0xaBDE1138)
outstanding          1,109.707154 kUSD

backing ratio = 1,110.888006 / 1,109.707154 = 1.00106411   ->  100.1064%
```

Dividing by `totalSupply` instead produces a shortfall that does not exist. We publish the inventory
as `kusdPsmInventory` at `/api/stats` precisely so the correction is not something you have to know
to make.

**Hourly signed attestation.** `kerne.fi/api/por/signed` carries an EIP-191 signature over a
canonical payload. Signer `0x09a2780ac8Be6D5d2d1F85A8D92b09D40C9CA37e`. At 2026-08-08T23:43:59Z it
reported `psm_solvency_ratio 1.001064`, `psm_solvent true`, `status WARNING_DELTA`, schema 9.

**`WARNING_DELTA` is a hedge-tracking flag, not a backing shortfall.** It fires because the measured
hedge book deviates from its declared base. Solvency fields in the same signed statement read
`psm_solvent: true`. Do not read the status string as an insolvency signal, and do not let us get
credit for a green light either.

**The attestation signer is the hedging venue account.** `signer` equals the Hyperliquid venue
address. That makes address attribution a signature from the account itself rather than an assertion,
and it also means the attestation key is a live venue key. We disclose both halves.

---

## 3. The fee ladder, measured rather than quoted

Redemption and mint fees are tiered by size. The tiers are on chain and we measured every boundary
today rather than restating a spec.

| swap size (USDC) | fee |
|---|---|
| below 50,000 | 10.00 bps |
| 50,000 to 249,999 | 8.00 bps |
| 250,000 to 999,999 | 7.00 bps |
| 1,000,000 and above | 5.00 bps |

Boundaries confirmed exactly: 49,999 charges 10 bps and 50,000 charges 8 bps; 999,999 charges 7 bps
and 1,000,000 charges 5 bps. Reproduce with `getFee(address,uint256)` on the live mint PSM. A mint of
500 USDC on a fork of live state returned 499.500000 kUSD, which is the 10 bps tier applied exactly.

**Never quote a flat 10 bps.** At size the ladder is the number that matters.

---

## 4. Custody after the 2026-08-06 handover, including what it does not cover

| contract | `DEFAULT_ADMIN_ROLE` holder |
|---|---|
| kUSD | **timelock** `0x36A14976`, 172,800s (48h) |
| live mint PSM `0xaBDE1138` | **timelock** |
| retired mint PSM, redeem reserve PSM | **timelock** |
| **skUSD staking vault** | **the 2-of-3 Safe. Not the timelock.** |

**skUSD sits outside the handover, and skUSD holds 88.37% of kUSD supply**
(1,011.582169 of 1,144.707154). That is the largest single gap in the custody story and we published
it before any counterparty asked.

Timelock roles, replayed from the deploy transaction: `PROPOSER`, `EXECUTOR` and `CANCELLER` all sit
with the Safe. `DEFAULT_ADMIN` on the timelock is the timelock itself. **The Pause Guardian holds no
timelock role at all.** Four role events over the contract's entire life, all inside the deploy
transaction, zero `RoleRevoked` ever.

**`MINTER_ROLE` on kUSD nets to exactly one holder**, the live mint PSM, by full event replay from the
token's creation block. Not by reading a counter: kUSD is plain `AccessControl`, not the enumerable
variant.

Three things a reviewer should weigh against the handover rather than for it:

1. **It cost us the surgical lever.** `setStableCap` is `MANAGER`, and `MANAGER` moved to the
   timelock. Closing entry while leaving the exit open now takes 48 hours. The only instant lever left
   is `pause`, and `pause` is blunt: `whenNotPaused` gates all four swap functions, so it closes the
   exit with the entry.
2. **Nothing monitors the queue.** No subscriber, no alerting, no public page watches `CallScheduled`
   on the timelock. The queue is empty today (13 scheduled, 13 executed, 0 cancelled, 0 pending) and
   the only reason anyone can say so is that we ran the replay. A log replay is not monitoring.
3. **There was a two day seventeen hour window.** Between 2026-08-03T23:24:07Z and 2026-08-06T17:00:07Z
   the Safe and the timelock both held `DEFAULT_ADMIN` on kUSD, so the delay did not bind. Oleg derived
   this from the event ordering. We had described the grants as a single atomic batch, which was wrong,
   and his version is the correct one.

---

## 5. The audit

Hexens, final report 2026-07-31, `hexens-kerne-protocol-final-2026-07-31.pdf`, 29 pages,
SHA-256 `655e7126030c750e9d58f2ab30b58215ce604942f06997d5c01532d6f687a4ca`. Reviewed commit
`0912c870a89f1fa707f69c60fc05c05ea85e2fa8`, frozen before fieldwork. Remediation commit `98f29e55`.
Hexens publishes the report on their own domain, which is the copy to read if you would rather not
take a protocol's word for a report about itself. Kerne paid for the engagement, which is true of
essentially every audit in this industry and is rarely said out loud.

**0 critical, 2 high, 2 medium, 4 low, 2 informational. Ten total, eight fixed, two acknowledged.**

| ID | title | severity | disposition |
|---|---|---|---|
| KERNE1-4 | Transferable kLP shares can separate withdrawal and esKERNE forfeiture identities | High | Acknowledged |
| KERNE1-5 | esKERNE forfeiture can be bypassed by gas-starving the best-effort forfeit call | High | Fixed |
| KERNE1-7 | `totalAssets` silently under-reports NAV when the verification node call fails | Medium | Fixed |
| KERNE1-9 | `_checkCRCircuitBreaker` should be applied to `captureFounderWealth` | Medium | Fixed |
| KERNE1-2 | Unable to update `offChainAssets` when it is 0 and bootstrapped is true | Low | Fixed |
| KERNE1-3 | `maxTotalAssets` check overestimates deposited assets | Low | Fixed |
| KERNE1-10 | `_checkCRCircuitBreaker` should pause when collateral ratio exceeds `SAFE_CR_THRESHOLD` | Low | Acknowledged |
| KERNE1-11 | Withdrawal requests are not bound to the share price at request time | Low | Fixed |
| KERNE1-6 | Redundant `_checkSolvency()` in KerneVault | Informational | Fixed |
| KERNE1-8 | Redundant extracted variable in `captureFounderWealth` | Informational | Fixed |

**"Fixed" means fixed in source. Whether the fix is live is section 6, and for the vault it is not.**

All ten sit in `KerneVault`. kUSD, skUSD, the PSM and esKERNE drew none between them. A review finding
nothing in a contract is evidence, not proof. And zero findings against esKERNE is not the same as the
escrow design going unexamined: both High findings concern esKERNE forfeiture and are filed against
the vault because that is where the code sits.

**Scope link caveat.** The report's own five scope links and its remediation link point at a private
repository and return 404 for any reader. That is our problem, not the auditor's. The five reviewed
files are republished verbatim with per-file SHA-256 at `contracts-public/audits/scope`, alongside the
same five at the remediation commit, so diffing the two directories reproduces the dispositions from
code rather than from our description of them.

---

## 6. Deployed versus source

Three standing divergences. Each is live today.

**KerneVault v2 `0x8ccc56B5624e2FDB592F6609d81F4c3798e3292B`.** The deployed bytecode matches commit
`ecc95cf7`, roughly three weeks earlier than the audited commit. All ten findings are live on it, plus
three defects we found ourselves after deploy. **Exposure is bounded to zero by fact, not by promise:**
`totalSupply()` is 0 and has been for the contract's whole life, `maxDeposit()` returns 0 for every
address, `whitelistEnabled` is true since 2026-07-30, `MINTER_ROLE` was revoked 2026-08-03, and
`esKERNE.totalSupply()` is 0 so the mechanism behind both High findings has never emitted anything.
Withdrawals are deliberately left open. Standing rule: remediated bytecode before capital.

**kUSD `0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3`.** Deployed is standard OpenZeppelin
`ERC20Burnable`, so **`burnFrom` is callable by anyone holding an allowance, with no role gate**.
Current source puts it behind `BURNER_ROLE`. An attacker needs an allowance first, so the practical
surface is ordinary approval hygiene, but it is a permanent disclosure item: no kUSD redeploy is
planned, because a token migration would cost holders more than the role gate is worth at this scale.

**KerneYieldDistributor `0x096e38a04B632D28E017f86836225E0956CaD878`.** Deployed lets
`ROOT_UPDATER_ROLE`, held by the operational hot wallet, set a Merkle root with immediate effect.
Current source puts it behind a 24 hour timelock. Exposure is zero in practice because the contract is
deliberately unfunded. Standing rule: never fund the deployed distributor.

**The one place deployed and reviewed agree is the one that matters most.** The live mint PSM
`0xaBDE1138` is Sourcify `exact_match` on both creation and runtime, and the `KUSDPSM.sol` in that
verified bundle is byte-identical to the audited file, both hashing to
`013bd7e6fc2bcb5e780aaa5f924a905f3f63e88bee49d1bf3d832d7c963b99f9`.

---

## 7. The independent review record

Euler forum topic 1849, opened 2026-07-03, twenty posts, still open. An independent reviewer,
Oleg_Aleksandrov, tested the design in public for thirty-five days. He is not Euler staff, not a
curator, and not paid by us. No Euler staff member has posted in the thread.

This is the section we think is worth your time, because it is the only part of this memo where the
verification is not ours. **His words, quoted, with what each one settles.**

*Transcription note: quotes are verbatim from the thread, including his lowercase sentence starts and
his punctuation. The only changes are character-level: Unicode minus, en dash and ellipsis are
rendered as ASCII `-`, `-` and `...` because this document is ASCII only. No word is altered and no
elision is unmarked. Diff any quote against `forum.euler.finance/t/1849.json` if that matters to you,
and it should.*

**On the Safe and the role graph:**
> "I verified your Safe claims directly. guard slot zero, no modules, 2 of 3, all owners EOA,
> DEFAULT_ADMIN on kUSD at Safe, getRoleAdmin(MINTER_ROLE) = 0x00. All matched."

**On the reserve arithmetic, rebuilt from chain rather than read off our endpoint:**
> "I rebuilt that from chain: 1,113.885006 USDC against 1,112.707154 kUSD outstanding, 1.001059,
> consistent with your payload."

**On address attribution, which he checked by recovering our signatures himself:**
> "Both membership signatures verify: the message recovers to 0x09a2...CA37e and 0x14f0...3946
> respectively, matching the two enumerated EOAs."

**On the custody handover, replayed call by call:**
> "I verified everything as stated. The deploy tx carries exactly four RoleGranted events: proposer,
> executor, and canceller on Safe, DEFAULT_ADMIN on the timelock itself, and minDelay set to 172800
> upon creation. [...] 13 calls match. Guardian receives MANAGER at indexes 1, 3, and 5, before Safe
> revokes at indexes 6-11. never a block without an emergency stop, confirmed by event ordering within
> the transaction"

**On the Pause Guardian, disassembled:**
> "Guardian: runtime 1012 bytes, as stated. pause(address) to three hardcoded addresses via raw call
> 0x8456cb59, NotSafe error decoded to 0x9dc4246e. There's no execute in any signature, no unpause, no
> grantRole, no privileged PSM selectors. The timelock address appears nowhere in the runtime."

**On the staking vault gap, which he confirmed rather than took from us:**
> "On skUSD: hasRole(0x00, timelock) = false. The staking vault remains outside the handover, as
> specified."

**On our funding threshold, which he tested against 180 days of settlement data and found useless:**
> "I checked it: 4,320 hourly funding settlements over 180 days, worst hour -0.0000728383, and zero
> hours at or beyond -0.0001. So the threshold is unreachable, as you said."

He also found things we had wrong, and this is the part a curator should weigh most:

- He caught that our loss breakers set a **$50,000 daily limit against a book of about $1,140**.
- He caught that we had described the admin grants as one atomic batch when the `DEFAULT_ADMIN`
  grants had actually landed three days earlier, leaving a **two day seventeen hour window** in which
  the Safe and the timelock both held admin and the delay did not bind. **His reconstruction was
  tighter than ours and we published the correction.**
- He caught, on 2026-07-25, that a schema change had quietly started counting the founder wallet in
  the hedge base: *"That looks like exactly the change you said you wouldn't make. What am I missing?"*
  He was right. The founder wallet backs no kUSD. It was corrected in schema 8 and we refused the easy
  fix of widening the hedge base to clear the warning.
- His two open items as of 2026-08-07 are **not closed**: nothing monitors the timelock queue, and
  *"48 hours is a notification only if someone receives it."* His stronger point, which we would
  rather state than leave implicit, is that a monitor still hands a holder nothing to do at hour 47,
  because `CANCELLER_ROLE` is the Safe and nobody else. There is no seat outside the operator set.

The full record is at `forum.euler.finance/t/1849`. We have not edited or deleted a post in it. Two
post numbers, 13 and 14, are absent from the public thread; post 15 opens by apologising for one of
them as a draft from another thread pasted by mistake. We cannot remove a post there and have not
asked anyone to.

### Addendum, 2026-08-11. He closed the thread, and here is what he closed it with.

This section was written on 2026-08-08. Three days later it is out of date in one direction that
matters and one that does not, so rather than rewrite it we are appending the difference.

**He posted once more, on 2026-08-09, and stood down.** In his words, verbatim:

> "stepping back, since this thread has reached a natural boundary. what it established: the
> canonical solvency read is the PSM ratio, excluding off-chain assets; the hyperliquid balance is
> publicly readable and signed by the account itself, but completeness of the account set is not
> provable on-chain. negative funding is absorbed by venue margin with no insurance fund and no
> automatic close; the minter set was narrowed to one. mint and psm admin moved behind a 48h timelock
> with an instant scoped pause guardian. what remains open is documented in the thread: the canceller
> seat, queue monitoring, the exposure floor, the pending-ops check on the mint path, exit-open as a
> property. those are build items now, not open questions. [...] nothing further from me until there
> is new on-chain state to verify"

He also re-read the live mint PSM source on BaseScan the same day and got an exact match: `KUSDPSM`,
`v0.8.24+commit.e11b9ed9`, optimizer 1000 runs, cancun, both read and write tabs present. That closes
a separate item he had raised on 2026-08-07, that the live mint PSM was unverified on the default
Base explorer so a reviewer opening it would see only raw bytecode.

**Read the open list as five items, not two.** The version above says two, because on 2026-08-07
those were the two he had named. His closing post names five: the canceller seat, queue monitoring,
the exposure floor, the pending-operations check on the mint path, and exit-open as a property. Only
one of the five has moved since:

- **Queue monitoring is half closed.** `kerne.fi/timelock` and `kerne.fi/api/timelock` shipped
  2026-08-10. They recompute the queue from Base on request and the API answers 503 rather than an
  empty queue when the read fails. That closes the observation half only. It creates no canceller
  outside the operator set and it pages Kerne, not you.
- **The other four are not built.** No date is offered for any of them, which is the same position
  this memo takes everywhere else.

The complete record of every check on Kerne performed by somebody who is not Kerne, this thread
included, with each reviewer's open items published at the same weight as their conclusions, is at
`kerne.fi/security/independent`.

---

## 8. The market

A permissionless Euler v2 Edge market. Kerne deploys it and holds no governance over it afterwards.

**Deployed 2026-08-09, Base block 49,726,126.** Verified after the fact on two independent RPCs.

| | address |
|---|---|
| USDC vault, borrowable, `eUSDC-116` | `0xe87c294E1139C31770727193e3Be0ccEd73d6AA3` |
| kUSD vault, escrow collateral, `ekUSD-1` | `0xD3800ceb6bBeB90101ed5d5A46017fE846c9509e` |
| EulerRouter | `0xB95407727d33fB2E444966fd0B7D0E7767Ce019E` |
| Oracle, `FixedRateOracle(kUSD, USDC, 1000000)` | `0x8f27228f02E798c17B7d6b270F32F8EC6afDD2D3` |
| EdgeFactory that built it | `0x4B930F0222349c2092b8531A42295262cc4F0e4A` |

Two transactions, both from the founder hardware wallet `0x14f04cE02f35B29Af564A98544dD7e2393993946`,
the same address that deployed the timelock and that we publish as ours:

- oracle, block 49,726,114, `0xbacaf5445effce5d32b57ee512ab54123306e24de437ab93dac36e3ca024c9ad`
- market, block 49,726,126, `0xcda40c26a970869efef971912a39b2ac7acae68b647ed2d54d72453f6380bef7`

The kUSD escrow vault is now the registered singleton in Euler's `EscrowedCollateralPerspective`, so
any future Edge market using kUSD as collateral reuses this exact vault rather than creating a second
one. All three relevant Euler perspectives return `isVerified` true for it, `edgeFactoryPerspective`,
`escrowedCollateralPerspective` and `evkFactoryPerspective`, which means Euler's own tooling
recognises it as an Edge market rather than an unaffiliated contract that happens to use their code.

Total cost of both transactions was 0.000024064 ETH, about five cents. That is worth saying out loud:
**the deployment was free, and a free thing that anyone can do is worth nothing by itself.** The
market is a precondition for a credit decision, not evidence of one.

| parameter | value | enforced by |
|---|---|---|
| collateral | kUSD, escrow vault (non-borrowable) | contract |
| borrowable | USDC | contract |
| unit of account | USDC | contract |
| oracle | `FixedRateOracle(kUSD, USDC, 1_000_000)`, Euler's own audited adapter | contract, immutable |
| borrow LTV | 60.00% | contract |
| liquidation LTV | 65.00% | contract |
| max liquidation discount | 15% | contract, fixed by EdgeFactory |
| liquidation cool-off | 1 second | contract, fixed by EdgeFactory |
| interest rate model | `IRMLinearKink` `0xC6dCfFE18cd9f532628aF15da2541c01499E3bcE`, kink 90%, 0% base, ~6.00% APR at kink, ~39.97% at 100% | contract |
| vault governor | `address(0)` | contract, renounced atomically by the factory |
| router governor | `address(0)` | contract, renounced atomically by the factory |
| **supply cap / borrow cap** | **none. Uncapped by construction.** | **not enforceable** |

**On caps, because this is where a spec and reality diverge.** Euler Edge markets are ungoverned by
design: the factory renounces governance in the same transaction that creates the vaults, which is
what makes the parameters above permanent and what stops Kerne from changing the oracle or the LTV
later. The price of that property is that **no supply or borrow cap can ever be set.** This is the
same shape as Morpho Blue, where markets are uncapped and caps live in the curator's vault. So the
numbers we would otherwise have proposed as market parameters are a **recommendation to you**, not a
control we hold:

> Recommended initial allocation ceiling: **50,000 USDC supplied, sized down from there on anything
> that gives you pause.** Ramp rather than open at the ceiling. There is no mechanism on our side that
> enforces this and we are not going to pretend there is.

**Verified on a fork of live Base state before deployment:** collateral valuation at 499.5 kUSD posted
returned exactly 299.700000 USDC at borrow LTV and 324.675000 at liquidation LTV, borrowing 299 USDC
succeeded, borrowing 5 USDC more reverted, and the router priced 1 kUSD escrow share at exactly
1.000000 USDC.

### The three things wrong with this market, in order

**1. The oracle is depeg-blind.** A fixed rate of 1.000000 does not mark kUSD down if backing is ever
impaired, so the market will not liquidate into a depeg. We chose it anyway, over the backing-ratio
oracle we specified earlier, for one reason: a bespoke unaudited oracle authored by the asset issuer
inside a live lending market is a worse risk than a conservative LTV. Euler's `FixedRateOracle` is
their own audited adapter and the code is trivially reviewable. The protection here is the LTV and
your cap, not the price feed. Kerne's own published underwriting framework refuses self-attested NAV
oracles, and we are not going to make an exception for ourselves.

**2. There is effectively no secondary market.** The only DEX venue for kUSD is one Aerodrome stable
pool holding **5.978637 kUSD and 7.088931 USDC**, about thirteen dollars of total depth. A liquidator
cannot sell seized kUSD on a market. **The only real exit is redemption through the PSM at
100.1064% backing, minus the fee ladder in section 3.** That is a genuinely different liquidation
model from every other collateral you underwrite, and it means liquidator participation depends on
someone being willing to hold kUSD to redemption rather than flip it. We have no evidence anyone will.

**3. The mint path is the drain path.** Restating section 0 item 5 because it belongs here: a
48 hour timelocked `grantRole` can create an unbounded kUSD minter. At par pricing, that mints
collateral from nothing. Nothing in this market prevents it. The 48 hours are public and unmonitored.

### The comparable, which is not encouraging

A permissionless Morpho Blue market with kUSD collateral and USDC loan already exists, id
`0xdc6a28b2941b3d32affc71cdeeb10e9779ff2a8ba1dcabc258e7b61f9a11beb3`, created 2026-06-16. Read today:
`totalSupplyAssets 0`, `totalSupplyShares 0`, `totalBorrowAssets 0`, `totalBorrowShares 0`, and
`lastUpdate` still equal to its creation timestamp fifty-three days later. **It has never been touched
once.** We are telling you this because it is the honest base rate for a permissionless listing with
no curator behind it, and because you would find it in five minutes.

The market existing is not the ask. A credit decision is the ask.

### Addendum, 2026-08-14. We seeded it ourselves, and that is not the same as somebody wanting it.

This section was written on 2026-08-08, when the market held nothing. It now holds something, all of
it ours, so rather than rewrite the section we are appending the difference.

On 2026-08-14 Kerne supplied the market from the same disclosed founder hardware wallet that deployed
it, `0x14f04cE02f35B29Af564A98544dD7e2393993946`. Read at Base block **49,970,398** on two independent
RPCs with no disagreement:

| | |
|---|---|
| USDC supplied | 50.000002 |
| USDC borrowed | 20.000002 |
| USDC available | 30.000000 |
| kUSD escrow collateral | 80.000000 |
| utilization | 40.0000% |
| borrow APR / APY | 2.5880% / 2.6218% |
| third-party supply | 0.000000 |

Seven transactions, all status 1, blocks 49,969,919 through 49,970,338:
`0x1aee973daf29c954c3d0b32e35c15f23a0be57addaad3917cb10d415d9d49377`,
`0x656cfb9b0bb793736b0d7de9c88817ec54107fb36153563ff26024f8fd907f47`,
`0xbc1c950f4494bfb30816aa2da9958a23b2c41d20d34136e3342a5f3e6bb10445`,
`0x746e7a69d05ad4cfbff3881e3663b074df457c258026cfabcb5cb6ca546c959a`,
`0xe4f4e86b463350370a1eff0367d769974d5973e9f669e0544ee68dc39b7679b8`,
`0x20df2a171ca21a8e7118bd4cc5acceee20cb9018dc63ac5366d0d52899de163e`,
`0xca98abfe227c1a17d7a473128a6f8e533ddb13f9d82cac39e792d7c9883748b8`.

**This is a seed and it is not demand.** Every dollar in that market is ours. Nobody paid to be there,
nobody was solicited, and no counterparty supplied anything. We did it so the venue could be shown
working rather than described: before this the interest rate model had never priced a real
utilization, the oracle had never been consulted in anger, and there was no borrow rate to read. Now
there is. What has not changed is the only thing that would matter to you, which is whether anyone
other than Kerne wants to lend against kUSD. That number is still zero and we are not going to dress
it up.

**Do not take the attribution from this document.** `kerne.fi/api/euler` measures our own position on
chain on every request and publishes the total minus it, so a third party shows up on its own line
the moment one exists, and this paragraph cannot go stale in our favour. Reproduce it yourself:

```
cast call 0xe87c294E1139C31770727193e3Be0ccEd73d6AA3 "totalAssets()(uint256)" --rpc-url https://mainnet.base.org
cast call 0xe87c294E1139C31770727193e3Be0ccEd73d6AA3 "balanceOf(address)(uint256)" 0x14f04cE02f35B29Af564A98544dD7e2393993946 --rpc-url https://mainnet.base.org
```

Put the second through `convertToAssets(uint256)` and subtract. Repeat on the collateral vault
`0xD3800ceb6bBeB90101ed5d5A46017fE846c9509e`. The remainder is everybody who is not us.

**On our own rule, because we would rather you heard it here.** Kerne publishes a signed enumeration
of every account it controls at `kerne.fi/api/por/accounts`, and its `violation_predicate`, written to
a reviewer's specification, says that sending funds to a venue account not on that list is a
violation. These two vault contracts are venue accounts and they are not on it, because an entry
asserts control and we hold no key and no governance over either. So before any of the transactions
above, we amended the registry to name both addresses under `disclosed_venue_deposits`, published it
as version 5, and made the predicate require that the disclosure PRECEDE the transfer rather than
excuse it afterwards. The signature on version 5 is dated ahead of every transaction hash listed here
and both are public, so that ordering is checkable rather than asserted. The money came from the
founder wallet and no PSM reserve was touched; the 100.1064% backing behind kUSD is unchanged and is
still verifiable in the same seven read calls as before.

The comparable below still stands, and the Morpho market has still never been touched by anyone.


---

## 9. What you would have to believe

Not a pitch. The actual list.

1. That 100.1064% USDC backing, verifiable in seven read calls, is worth more than the size of the
   book is worth against it.
2. That a 60% borrow LTV against an asset redeemable at par through a contract, with a 15% maximum
   liquidation discount, leaves enough margin that a depeg-blind oracle does not cost you.
3. That Kerne will not use the 48 hour mint path, or that 48 hours of public notice is enough time for
   you to withdraw. Note the second half is only true if someone is watching, and nobody is.
4. That a protocol which has paid 0.05% of its advertised rate is worth a credit line at all. The
   argument for yes is that the yield is irrelevant to you: you are lending USDC against collateral,
   not buying the yield. The argument for no is that a protocol that cannot pay what it advertises may
   have other things it cannot do.
5. That an issuer publishing its own worst numbers first is a signal rather than a technique.

---

## 10. Reproduce this memo

```bash
RPC=https://mainnet.base.org
KUSD=0x5C2EfdF0D8D286959b42308966bc2B97f5680AA3
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
MINT=0xaBDE1138aa1Ce88d1dF06422C0c3b05D70569803
OLD=0x07eBb486e11BD217e6085eb5ab663e4517595993
RED=0xFf3025ec18e301855aB0f36Ec6ECa115a29A5Fbc
TL=0x36A14976980B7Dd33136f6613545EB0A2C0a0D72
SAFE=0x52d3E450bA6c299B1B07298F1E87DD74732D4877
SKUSD=0x96F5102C15b839757f811A98CEc3725Ac21DfA14
ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000

# backing: sum three modules, subtract PSM-held kUSD from supply
cast call $USDC "balanceOf(address)(uint256)" $MINT --rpc-url $RPC
cast call $USDC "balanceOf(address)(uint256)" $OLD  --rpc-url $RPC
cast call $USDC "balanceOf(address)(uint256)" $RED  --rpc-url $RPC
cast call $KUSD "totalSupply()(uint256)"            --rpc-url $RPC
cast call $KUSD "balanceOf(address)(uint256)" $OLD  --rpc-url $RPC
cast call $KUSD "balanceOf(address)(uint256)" $RED  --rpc-url $RPC

# the fee ladder, all four tiers
for A in 1000000 100000000 250000000000 1000000000000; do
  cast call $MINT "getFee(address,uint256)(uint256)" $USDC $A --rpc-url $RPC
done

# custody: kUSD behind the timelock, skUSD is not
cast call $KUSD  "hasRole(bytes32,address)(bool)" $ADMIN $TL   --rpc-url $RPC  # true
cast call $KUSD  "hasRole(bytes32,address)(bool)" $ADMIN $SAFE --rpc-url $RPC  # false
cast call $SKUSD "hasRole(bytes32,address)(bool)" $ADMIN $SAFE --rpc-url $RPC  # true  <- the gap
cast call $TL    "getMinDelay()(uint256)"                      --rpc-url $RPC  # 172800

# the 88.37%: how much of supply sits in the staking vault
cast call $KUSD "balanceOf(address)(uint256)" $SKUSD --rpc-url $RPC

# realized versus advertised, both from our own endpoints
curl -s https://kerne.fi/api/apy           | jq '{advertised: .expectedAPY, realized: .realized.annualized}'
curl -s https://kerne.fi/api/honesty-index | jq '.delivery.rows["kerne-skusd"]'

# the signed attestation
curl -s https://kerne.fi/api/por/signed | jq '{status, psm_solvency_ratio, psm_solvent, signer, generated_at}'
```

`realized.annualized` is a **fraction**, on the same scale as `expectedAPY`. It was published as a
number of percent until 2026-08-07, which made it read one hundred times too high, in our favour, on
the one endpoint whose purpose is to show that we underdeliver. That is fixed. We mention it because a
reviewer working from a cached copy will get it wrong in the flattering direction.

---

## Contact and standing

`liam@kerne.fi`. There is no catch-all, so other addresses at the domain do not exist.

Kerne is three people with no legal entity. We cannot sign a SAFE, take equity investment, or receive
a grant wire. We can be paid for services and we can be a counterparty to an on-chain market. If a
credit decision here would require a legal wrapper on our side, that is a real blocker and it is
better raised now than after diligence.

*Prepared 2026-08-08. Supersedes nothing; this is the first consolidated version. If a number here
disagrees with a live endpoint, the live endpoint is right and this document is stale.*
