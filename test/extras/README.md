# Extras launch regression tests

These tests supplement the existing real-vault, bare-chain and factory/fork suites. They change no production contracts, launch arguments, configuration, fees or owners, and introduce no dependencies.

## Coverage

| Suite | Additional checks |
| --- | --- |
| `ExtrasFailurePaths.t.sol` | Allowance/balance failure atomicity; launch minimum; one wei bonus; full YOLO supply deposit/refund; unbound sweetener; review and exact deadline boundaries; unknown task isolation; donor-only refunds; voter claims, dust and double claims; cancellation of positions on both sides; rational time-weight oracle; no-winner recipients; empty-chain modules remain inert even when vault code later appears. |
| `ExtrasAccounting.invariant.t.sol` | Random actions across up to 24 tasks and four funded actors. Deposits, both prediction sides, reviews, time advancement, all three final outcomes, settlement, bonus payouts, donor refunds, voter claims and locked-withdrawal attempts. Exact token balances versus outstanding liabilities, ghost principal/deposit totals, per-recipient splits, proportional claims and supply conservation. Every sequence ends by collecting all claims/refunds and requiring both escrows to be empty. |
| `ExtrasMetadataAndDirectory.t.sol` | Failed mint payment rolls back NFT/metadata/burn; duplicate mint after transfer cannot rewrite metadata; catalog ownership handover; maximum title/name/SVG byte lengths; forbidden title bytes across word boundaries; complete base64 metadata envelope; disabled-design fallback; replacement proposals restart the full 48-hour delay; failed executions preserve pending proposals; listed history stays unchanged. |
| `HiddenListSequence.invariant.t.sol` | Independent per-round NFT/caller/owner ledger, transfers, delegate creation/revocation, wallet overrides, retries and time advancement across four `(vault, kind, id)` keys. Includes token IDs 0, 255, 256 and `uint256.max`, repeated and nonexistent IDs, failed delegate reads and ERC-721 approval versus delegate.xyz authority. |
| `TrophySequence.invariant.t.sol` | Random mints, duplicate mints, transfers, unauthorized actions, design changes and time advancement. Exact fixed burn, no token custody, unchanged minted design/metadata and conserved NFT ownership. |

The three invariant campaigns use explicit selector lists and `fail-on-revert = true`. Expected failures have explicit revert expectations; successful-path calls and final collection are not wrapped in catch-and-ignore blocks. Setup seeds real deposits, positions, votes and a trophy so the conservation checks do not start from an empty system. Inline settings keep campaign sizes independent of configuration edits.

## Fixture boundary

`ExtrasVaultViews` supplies the narrow views read by the modules, the production `TextRules`, a plain ERC-20, and a fixed 10%/5% launch fee snapshot. It allows only one transition from Open to a terminal task status, fixes vote totals before acceptance, and expires idle tasks through `poke`. It is a test fixture, not an alternative vault implementation. Authorization for cancelling real tasks, actual submission/dispute timers, one-time vault binding, bond calculations, swarm execution and stake eligibility remain covered by the existing integration tests. The new tests cannot establish those integration properties on their own.

Accounting identities assume deposits through the module APIs, without unsolicited token donations. Prediction amounts are bounded below the real YOLO supply in random campaigns; the separate full-supply boundary test exercises the stated absence of deposit caps. The documented zero-point behavior is retained, not treated as a defect. Catalog-owner control of future designs and project-wallet moderation are intentional privileges.

The source review focused on the six extras contracts, their external view assumptions, accounting, access checks and inherited ERC-721/ownership behavior. This is not an independent audit of all core desks, token launch infrastructure, external NFT/delegate implementations or mainnet state. No production adaptation was made, so the existing root `ADAPTATION.md` is unchanged.

## Reproduce

Use the assignment's deterministic seed:

```sh
FOUNDRY_FUZZ_SEED=0x243324f3f1562527ce9f880b86c53fa0c936c0bad808e50042a25bacac1cd6d7 forge test --match-path 'test/extras/*.t.sol'
forge build
FOUNDRY_FUZZ_SEED=0x243324f3f1562527ce9f880b86c53fa0c936c0bad808e50042a25bacac1cd6d7 forge test
```

For local work, `FOUNDRY_OUT`, `FOUNDRY_CACHE_PATH` and `FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR` can point under `test/scratch/` to keep generated artifacts separate from delivered tests. No test reads artifacts from that directory explicitly, writes environment variables, uses FFI or requires a network. The existing optional fork suites still require a valid `FORK_URL` to exercise the live ProjectFactory.
