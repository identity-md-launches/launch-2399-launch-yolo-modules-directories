# Test-only adaptations

Production contracts, configuration, launch arguments and the root `ADAPTATION.md` are unchanged. This record lives under the permitted `test/` path.

1. Added the extras regression and invariant suites described in `README.md`. The fixtures supply the modules' external view dependencies; the modules themselves are deployed from their production artifacts.
2. Changed `test/Base.t.sol` to load the large production creation bytecodes from artifacts instead of embedding them in every derived test. The previous assignment failed its 600-second local build limit, and the initial clean-checkout `forge build` in this attempt also continued compiling beyond ten minutes. The existing sweetener integration test passed separately before this change, so this is a build-cost adjustment, not a contract defect or an assertion change.
3. Added `test/mocks/BaseVaultDeployer.sol` to create CaseDesk, DisputeDesk and TaskVault inside a single external call when loading artifact bytecodes. This preserves the desks' transient constructor flags until the vault wires them. Constructor arguments, ownership and the registry-owner binding call are unchanged. The deployment helper has no production role. Existing tests and their assertions are retained; the full suite checks the shared fixture's compatibility.

No fees, bonus/market splits, trophy price, burns, recipients, owners, timelocks, moderation rules or production permissions were changed. No external dependency was installed.

## Validation

- Fresh `forge build`: passed with the repository's compiler settings. Solc reported 1,429.59 seconds, so a cold build still exceeds the earlier 600-second local-check limit; artifact-based fixture deployment does not resolve that limit on this runner.
- Full `forge test` with the assignment's seed `0x243324f3f1562527ce9f880b86c53fa0c936c0bad808e50042a25bacac1cd6d7`: 723 passed, 0 failed, 4 skipped across 96 suites.
- The new suites contribute 30 passing Forge test entries, including three invariant campaigns with 32,768 randomized handler calls in total. The accounting campaign checks three named invariants together.
- The four existing fork checks skipped without `FORK_URL`. Live-mainnet deployment gas was not independently measured in this run.
- Only `test/` files changed. Build artifacts and logs were directed under `test/scratch/`; delivered tests do not depend on those artifacts surviving cleanup.
