# ValariRouter audit and remediation

The 2026-09-14 audit found one Medium issue: a rejected commission recipient
could block users from collecting or exiting. The 2026-09-15 revision replaces
mandatory treasury transfers with independently withdrawable credits and raises
the commission to **10% of realized LP fees**, as requested. Principal and
deposits remain commission-free. **M-01 is fixed and regression-verified** in this source revision.

## Original finding M-01

**Original severity:** Medium. The audited source SHA-256 was
`692454ba757057aa1a9579116ac87792507ba4b79b0d892c865b89cd028895c5`.

The original `_distribute` immediately transferred its 1% commission to the
configured treasury. If either token rejected that address, the transfer
reverted the whole collection or exit. The user's NFT and principal remained
invested; an owner recipient change was required for router-level recovery.
This was an availability defect, not a demonstrated theft of principal.

The original issue was reproduced locally and on Robinhood block **63,094,275**
using the deployed GOOGL implementation. Only the registry reply for
`isBlocked(treasury)` was set to true. Both user operations reverted with the
actual token error; changing the recipient restored withdrawal. This simulated
a possible restriction and did not assert that the real treasury was blocked.
Original fork evidence is retained in `cache/audit-recipient-fork.log`.

No Critical or High findings were confirmed in the original scope. The original
42 local integration tests and an additional 256-seed accounting property passed.
The earlier four lifecycle fork cases passed at block 62,874,875. These are
historical results for the old implementation, not verification of this revision.

## Remediation

The current source SHA-256 is `7195877547776d89f84b4dab60396962074898fef1d8706cb5131b4f434be4f5`.

- `COMMISSION_BPS` is 1,000 out of 10,000. The user receives 90% of realized LP
  fees plus all withdrawn principal. Per-position/per-token rounding carry
  charges `floor(cumulative realized fees / 10)`.
- Collection and exit credit `claimableCommission[recipient][token]` and
  `totalClaimableCommission[token]`. They transfer only the user's payout.
  Commission reserves remain in the router and are excluded from later
  deposits, refunds, and position payouts by operation-local balance baselines.
- `withdrawCommission(token, to, amount)` spends only the caller's own credited
  balance. It supports partial withdrawals and an alternate valid destination.
  The owner cannot withdraw a different recipient's credits. Zero amount,
  zero token/destination and the router as destination are rejected.
- Credits and aggregate liabilities are reduced before transfer under the
  reentrancy guard. A failed transfer rolls back both. Balance checks prevent
  unexpected sender debits from consuming other reserves or dust.
- `setFeeRecipient` remains owner-only and affects future accrual. Old credits
  stay with the original recipient, including after ownership transfers.
- Cumulative position fields are named `commissionAccrued0/1`, replacing
  `commissionPaid0/1`; they represent charges credited, not treasury withdrawals.
  The ABI exposes the credit getters and separate withdrawal API.

This separates user withdrawal availability from the treasury's ability to
receive a token. A blocked treasury can retry its own withdrawal to a different
eligible destination without owner intervention. Its failed claim does not
reverse a completed user exit or consume another recipient's credit.

## Regression coverage

The updated [local suite](test/ValariRouter.t.sol) contains 50 tests, including
256 funding/range fuzz cases. New cases cover partial/full withdrawals in both
tokens, unauthorized claims, invalid destinations/amounts, recipient rotation,
blocked treasury transfers, failed-transfer rollback, callback reentrancy and
isolation of commission reserves from later LP deposits/exits.

[The access regression](test/ValariRouterAccessAudit.t.sol) rejects treasury
transfers while requiring user collection and full exit to succeed. It verifies
that a failed treasury claim preserves credit and that an alternate destination
works. [The accounting property](test/ValariRouterAccountingAudit.t.sol) uses
256 seeds, two beneficiaries, overlapping ranges, forced crossing/reentry,
12 randomized swap/donation rounds, interleaved collection, partial treasury
withdrawals and recipient rotation. It checks that outstanding liabilities plus
treasury receipts equal cumulative charges and that the final drain leaves dust.

[The four fork lifecycle cases](test/ValariRouterFork.t.sol) check actual swaps,
range crossings, custody, 10% accrual and separate treasury withdrawals against
deployed GOOGL/USDG and USDG/NVDA contracts. Construction validates all 100 pool
configurations; it does not execute a lifecycle on the other 98 pools.
[The deployed-token regression](test/ValariRouterIntegrationAudit.t.sol) mocks
only the GOOGL registry's block status for the treasury, then requires successful
collection and exit, failed-claim rollback, and withdrawal to another destination.

Run the focused suites from this directory:

```sh
forge test --offline --match-contract '^ValariRouterTest$' -vv
forge test --offline --match-contract '^ValariRouter(Access|Accounting)AuditTest$' --match-test '^test(Audit|FuzzAudit)' -vv
RUN_ROBINHOOD_FORK=true forge test --match-contract '^ValariRouter(ForkTest|IntegrationAuditTest)$' -vvv
```

The last command runs four lifecycle tests and the blocked-recipient regression
once each, using two concrete suites with shared abstract setup. Historical block pins depend on RPC retention;
older snapshots can return `metadata is not found`.

## Remediation verification — 2026-09-15

- **50 local tests passed**, including 256 funding/range fuzz cases.
- **2 focused audit tests passed**, including 256 randomized accounting sequences
  with partial withdrawals, recipient rotation and multiple beneficiaries.
- **5 Robinhood fork tests passed at block 63,116,190**, with no failures or
  skips. The blocked-treasury regression confirmed successful user collection
  and full exit, failed treasury-claim rollback and an alternate withdrawal
  destination, using the deployed GOOGL implementation.
- Full project compilation and formatting passed. Runtime is **17,302 bytes**,
  below the EIP-170 size limit. The exported ABI matches the final artifact.

The fork output is saved in `cache/commission-remediation-fork.log`. The RPC
was `https://rpc.mainnet.chain.robinhood.com`. Source review found no blocker in
credit ownership, liability accounting, withdrawal authorization or reentrancy
protection. Test fixture refactoring resolved a compiler stack-allocation limit
without changing production compiler settings or reducing assertions.

## Scope and assumptions

The review covers the router, deployment script, exact 100-pool configuration,
exported ABI and relevant pinned v4/Permit2/OpenZeppelin/Solmate behavior. It is
not formal verification, a complete upstream/issuer audit, or an independent
external audit certification. The calculator's historical fee model is outside
this contract remediation.

Configured managers and StateView are trusted. Issuer eligibility comes from
the deployment catalog. Tokens must retain supported ERC20 behavior. Token
restrictions on the router or user, global issuer pauses, or incompatible token
upgrades remain external dependencies; the treasury-only restriction is the
condition addressed by M-01. Users choose meaningful slippage and deadlines.
Directly transferred positions are not imported by this API.

No production deployment was performed during the audit itself. On 2026-09-15
(Europe/Istanbul), the user subsequently authorized mainnet deployment of the
same audited source. The router was deployed at
`0x7DD01E8Da0cE263368f06BE8c7114731cA0DB04d` in Robinhood block **63,151,100**.
Read-only checks matched the compiled runtime bytecode, all 100 pool IDs and
keys, manager addresses, initial owner/fee recipient, and 10% commission.
The deployment receipt and verification details are in
[`deployments/robinhood-mainnet.json`](deployments/robinhood-mainnet.json).
