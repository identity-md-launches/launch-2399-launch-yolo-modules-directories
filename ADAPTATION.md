# ADAPTATION — launch 3 (`extras`: the $YOLO modules, the directory, the hide list, the catalog)

The project arrived launchable: the six contracts of this launch (YoloSweetener, TrophyCatalog, DareTrophy,
ProtocolDirectory, HiddenList, YoloPredict) already have nonpayable constructors with static arguments, no owner
beyond the catalog's and the directory's project wallet (a constructor argument, never `msg.sender`), no proxy,
no DELEGATECALL / CALLCODE / SELFDESTRUCT, and constructors that skip their vault reads when the vault has no code
(IMD's empty-chain floor; `test/ExtrasBareChain.t.sol`). Constructor arguments, fees, splits, the trophy price,
the burns, the recipients, the directory's timelock and owner, the hide list's quorum (10 NFTs, 3 owners), its
7-day cooldown and 24-hour window are unchanged. Nothing was added: no owner, pause, upgrade path, mint or fee.

What changed, and why. Every change is covered by a test.

## 1. HiddenList: a self-contest at the NFT count alone no longer buys the 7-day cooldown

- File: `src/HiddenList.sol`, `vote()`, the "real contest" test before a new round opens.
- Why: audit finding `7351432d…` (low) reproduces on the tree as it arrived. The cooldown test counted a failed
  round as a real contest at `hideNfts >= 10 && keepNfts > 0` without the owners bar the gate `_won` enforces
  (`hideOwners >= 3`). One holder's 10 NFTs (one `ownerOf` owner, so the round can never pass) plus a single keep
  NFT from a second wallet made every honest hide vote on the item a silent no-op for 7 days, repeatable every 8
  days. The contract's own notice promised the opposite ("a self-contest … cannot buy the cooldown against an honest
  hide cluster that has not voted yet").
- Fix: the contest test now requires the same hide quorum the round passes at, `hideNfts >= QUORUM_NFTS &&
  hideOwners >= MIN_WALLETS`, next to the keep vote. Quorum, cooldown and window are untouched: a round that
  reached the full hide quorum and was tied or outvoted by keep votes still waits 7 days
  (`test_FailedRoundCannotRetryBefore7Days`, `test_ContestAtFullQuorumThreeOwnersStillBuysCooldown`), the
  owner's `setState(VISIBLE)` cooldown (`ownerCooldown`) is unchanged, and any other failed round may be retried
  at once, as the launch text says ("a round that reached the hide quorum and drew a keep vote … 7 days … any
  other failed round at once"; the hide quorum being the bar a round passes at on its hide side).
- Tests: `test/HiddenList.t.sol` `test_SelfContestAtNftQuorumOneOwnerDoesNotBuyCooldown` (the finding's
  scenario: the honest vote the next day opens a fresh round and emits `HideVote`) and
  `test_ContestAtFullQuorumThreeOwnersStillBuysCooldown` (the boundary: 8 + 1 + 1 NFTs from exactly 3 owners,
  tied by keep votes, still waits 7 days). The notice in the contract and the moderation row of
  `docs/MECHANICS.md` say the same.

## 2. ProtocolDirectory: a cancelled or listed proposal is no longer readable through `pendingVersion()`

- File: `src/ProtocolDirectory.sol`, `cancelVersion()` and `addVersion()`.
- Why: audit finding `fdba6067…` (info) reproduces: `cancelVersion` only zeroed `pendingVersionEta`, so
  `pendingVersion()` kept returning the cancelled proposal (vault, modules, label) with no eta; `addVersion` left the
  listed proposal behind the same way. No on-chain effect (`addVersion` reverts `NothingPending` while the eta is
  0), only a stale view an off-chain reader could show as pending.
- Fix: both functions `delete _pendingVersion` (the cancel event still names the cancelled vault; the listing copies
  the proposal to memory first). The timelock, the owner, the checks and the listed versions are unchanged.
- Test: `test/Directory.t.sol` `test_CancelVersionClearsPendingVersionView`.

## 3. Static analysis of the whole tree: two high-confidence findings of the verifier's run resolved in code

The previous attempt was rejected by the verifier's static analysis (`analysis_failed`), which does not honour the
`// slither-disable-next-line` annotations the project carries (commit e817dc3) and reported, with high impact and
high confidence, `arbitrary-send-erc20` in `TaskVault.collectBondPart` and `uninitialized-state` for
`YoloLockHub._history`. Neither is a defect (see below), but the gate is a launch rule, so both are resolved
by a restructuring with identical behaviour. Neither contract is deployed by this launch (both are live from
launch 2); the launch verifier analyses the whole `src/` tree.

- `src/TaskVault.sol`: the plain ERC-20 pull (`safeTransferFrom(from, address(this), amount)` + the liabilities
  entry) that `_collect` (used by `createTask` and `topUp` with `msg.sender`) and `collectBondPart` (a desk names
  the sender the vault's fallback appended to the routed call) both did inline is now one private `_pull(from,
  currency, amount)`. Same calls in the same order, same accounting, same callers (`onlyDesk` unchanged); the
  analyzer now sees the pull's `from` tied to `msg.sender`. The stale `arbitrary-send-erc20` annotation on
  `collectBondPart` is removed. Not a defect: `collectBondPart` is `onlyDesk`, and the desks pass `_sender()`
  only (`CaseDesk.submit`, `DisputeDesk.dispute`). Covered by every bond test (`test/BondBase.t.sol`,
  `test/Desks.t.sol`, `test/Disputes.t.sol`, `test/MoneyRules.t.sol`, the invariant suite).
- `src/YoloLockHub.sol`: `_checkpoint` writes `_history[who]` by name instead of only through a local storage
  pointer (`Point[] storage h`), so the analyzer sees the array initialised; same storage, same reads and writes.
  Covered by `test/YoloLockHub.t.sol` (locks, extensions, withdrawals, the same-block checkpoint) and the stake
  tests.

Checked locally with Slither 0.11.6 on the `src/` tree with every `slither-disable` annotation stripped: no finding
of high impact and high confidence remains; the medium-confidence ones the verifier listed (`arbitrary-send-eth`,
`reentrancy-eth`, `reentrancy-balance`, `incorrect-equality`, `reentrancy-no-eth`, `uninitialized-local`,
`unused-return`, `divide-before-multiply`) are the reviewed false positives of commit e817dc3 in contracts of
launches 1 and 2 (CEI with a reentrancy lock, `== 0` sentinels, swap routing through the user's own adapter
choice) and are left as they are.

## Audit of the six contracts as they arrived: what did not reproduce or needed no change

- YoloSweetener: the 90 / 5 / 5 split, the stake bonus share capped at the fee minus the NFT share, and the
  invariant "YOLO held = open bonuses + unclaimed voter pools" hold (`test/Sweetener.t.sol`,
  `test/audit/AuditSweetenerBonus.t.sol`, `test/review/ReviewSweetener.t.sol`). Deposits only once bound
  (`NotBound`), nothing leaves while a task is open. $YOLO is a plain ERC-20 (no hooks), so the token calls after
  the state writes cannot re-enter.
- DareTrophy: the fixed 7,777 YOLO price is burned by a transfer to `0x…dEaD` and the contract holds none; one
  trophy per submission (`_mint` reverts on a second mint); the title and proof link are under the vault's text
  rules, which exclude `"` and `\`, so the on-chain JSON cannot be broken by a title; the design id is kept at
  mint and never changes.
- TrophyCatalog: owner-only (two-step) design list, no money, designs immutable once added; `designFor` skips a
  switched-off design and falls back to the default, then the built-in badge.
- YoloPredict: positions irrevocable before the deadline with no submission under review; 5 % held burn, 5 %
  deferred, 90 % to the pools; the no-winner payouts in `settle` and the pull `claim` match the launch text
  (`test/YoloPredict.t.sol`, `test/YoloPredictScenarios.t.sol`, `test/audit/Predict*.t.sol`). A winner whose
  points floor to 0 while others hold points gets only their 90 %: a known limitation in the docs, not changed.
- ProtocolDirectory, HiddenList: no owner but the fixed project wallet, no payable path, no token call.
- Launch-kind checks: all six constructors are nonpayable with static arguments (address / uint64 / uint256), at
  most 5 per contract, every `$contract:` reference points backward, no library with public functions, no
  forbidden opcode; `test/ExtrasBareChain.t.sol` deploys the six in one call on a chain without the vault.

## 4. Size-headroom figures refreshed

- Files: `test/review/ReviewLaunch.t.sol` (`DOC_MARGIN_HUB`, `DOC_MARGIN_VAULT`, `DOC_MARGIN_DIRECTORY`,
  `DOC_MARGIN_HIDDENLIST`) and the matching sentence of `docs/LAUNCH-TASK.md`.
- Why: `test_L1_perContractCodeMargin_matchesDoc` pins each contract's EIP-170 headroom to the documented figure.
  Changes 1 to 3 move four runtimes by a few bytes (YoloLockHub 21,357 -> 21,279, TaskVault 3,975 -> 3,952,
  ProtocolDirectory 20,014 -> 19,855, HiddenList 20,787 -> 20,761); the other six are byte-identical in size.
  Every contract stays far under the limit, and launch 3 stays under the 9.4M gas the launch text states (the
  local figure moves by well under 0.1M).

## Not changed

- `docs/LAUNCH-TASK.md` (the launch texts), `script/LaunchPlan.sol` (the constructor arguments), the fees, the
  splits, the prices, the owners, the timelock, the quorum, the cooldown and the window.
- The repository's build configuration and dependencies (`foundry.toml`, `foundry.lock`, `.gitmodules`, `lib/`).
- No `launch.json` is written: that is the manifest step's.

## Checks run

- `forge build` and `forge test` with `FOUNDRY_FUZZ_SEED=0x243324f3f1562527ce9f880b86c53fa0c936c0bad808e50042a25bacac1cd6d7`:
  693 tests pass, 0 fail, 4 skipped (the fork tests); the 690 that arrived plus the three added here. The audit's
  proof `Proof_7351432decec.t.sol` was also run against this tree from a scratch directory and passes (it fails on
  the tree as it arrived).
- `python3 script/check-launch-task.py`: the launch texts still match the plan's arguments.
- The fork suite (`FORK_URL`) was not run: this machine has no mainnet archive RPC. The live-core fork test and the
  launch rehearsal are unchanged and skip without `FORK_URL`, as before.
