// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ExtrasFixture, ExtrasVaultViews, YoloSweetener, YoloPredict, DareTrophy} from "./ExtrasFixture.sol";
import {TaskStatus} from "src/VaultTypes.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// forge-config: default.fuzz.runs = 512
contract ExtrasFailurePathsTest is ExtrasFixture {
    function test_WholeYoloSupplyHasNoDepositCapAndUnwindsWithoutLoss() public {
        uint256 supply = 1_000_000_000e18; // YoloToken.TOTAL_SUPPLY
        _open(1);
        _sweeten(1, people[0], supply);
        assertEq(bonus.bonusOf(1), supply);
        views.finish(1, TaskStatus.Unwound, doer, false, 0);
        vm.prank(people[0]);
        bonus.withdraw(1);
        assertEq(token.balanceOf(people[0]), FUNDING);
        _open(2);
        _predict(2, people[0], true, supply);
        assertEq(market.paidIn(2, people[0]), supply);
        views.finish(2, TaskStatus.Unwound, doer, false, 0);
        vm.prank(people[0]);
        market.claim(2);
        assertEq(token.balanceOf(people[0]), FUNDING);
        assertEq(token.balanceOf(address(market)) + token.balanceOf(address(bonus)), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_EmptyChainModulesStayInertEvenIfVaultCodeAppearsLater() public {
        address launchVault = 0x88c3B0B64e6869C424DAF25ad8eD635180832493;
        assertEq(launchVault.code.length, 0);
        YoloSweetener inertBonus =
            YoloSweetener(deployCode("src/YoloSweetener.sol:YoloSweetener", abi.encode(launchVault)));
        YoloPredict inertMarket =
            YoloPredict(deployCode("src/YoloPredict.sol:YoloPredict", abi.encode(launchVault, 1e18)));
        DareTrophy inertTrophy =
            DareTrophy(deployCode("src/DareTrophy.sol:DareTrophy", abi.encode(launchVault, catalog)));
        // Simulate code becoming available after the floor deployment. Cached dependencies must stay zero.
        vm.etch(launchVault, address(views).code);
        ExtrasVaultViews late = ExtrasVaultViews(launchVault);
        late.bind(address(inertBonus));
        late.open(1, author, 30 days, 0, views.usdc());
        vm.startPrank(people[0]);
        token.approve(address(inertBonus), type(uint256).max);
        token.approve(address(inertMarket), type(uint256).max);
        vm.expectRevert(); // SafeERC20 rejects the cached zero token, even with a now-functional vault.
        inertBonus.sweeten(1, 1e18);
        vm.expectRevert();
        inertMarket.predict(1, true, 1e18);
        vm.stopPrank();
        late.finish(1, TaskStatus.Completed, doer, false, 0);
        vm.prank(doer);
        vm.expectRevert(); // the cached case desk is still zero
        inertTrophy.mint(1, "Cannot revive");
        assertEq(address(inertBonus.registry()), address(0));
        assertEq(address(inertBonus.yolo()), address(0));
        assertEq(address(inertMarket.yolo()), address(0));
        assertEq(address(inertTrophy.caseDesk()), address(0));
        assertEq(address(inertTrophy.yolo()), address(0));
        assertEq(inertBonus.bonusOf(1), 0);
        assertEq(inertMarket.paidIn(1, people[0]), 0);
        assertEq(inertTrophy.totalBurned(), 0);
        assertEq(token.balanceOf(people[0]), FUNDING);
    }

    function test_FailedAllowanceLeavesNoPositionOrBonusAccounting() public {
        _open(1);
        address who = people[0];
        vm.startPrank(who);
        token.approve(address(market), 1e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(market), 1e18 - 1, 1e18)
        );
        market.predict(1, true, 1e18);
        token.approve(address(bonus), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(bonus), 0, 1));
        bonus.sweeten(1, 1);
        vm.stopPrank();
        (uint64 opened,, uint256 yes, uint256 no, uint256 yesPts, uint256 noPts, uint256 deferred) = market.markets(1);
        assertEq(uint256(opened) + yes + no + yesPts + noPts + deferred + market.burnHeld(1), 0);
        assertEq(market.paidIn(1, who), 0);
        (uint256 a, uint256 b, uint256 c, uint256 d) = market.positionsOf(1, who);
        assertEq(a + b + c + d, 0);
        assertEq(bonus.bonusOf(1), 0);
        assertEq(bonus.givenBy(1, who), 0);
        assertFalse(bonus.gave(1, who));
        assertEq(token.balanceOf(who), FUNDING);
        assertEq(token.balanceOf(address(market)) + token.balanceOf(address(bonus)), 0);
    }

    function test_InsufficientBalanceRollsBackBothDeposits() public {
        _open(1);
        address who = people[0];
        vm.startPrank(who);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, who, FUNDING, FUNDING + 1)
        );
        market.predict(1, false, FUNDING + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, who, FUNDING, FUNDING + 1)
        );
        bonus.sweeten(1, FUNDING + 1);
        vm.stopPrank();
        assertEq(market.paidIn(1, who), 0);
        assertEq(bonus.bonusOf(1), 0);
        assertFalse(bonus.gave(1, who));
    }

    function test_LaunchMinimumAndZeroBonusBoundaries() public {
        _open(1);
        uint256[3] memory bad = [uint256(0), 1, 1e18 - 1];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(people[0]);
            vm.expectRevert(YoloPredict.BelowMinPosition.selector);
            market.predict(1, true, bad[i]);
        }
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        bonus.sweeten(1, 0);
        _predict(1, people[0], true, 1e18);
        _sweeten(1, people[0], 1);
        assertEq(market.paidIn(1, people[0]), 1e18);
        assertEq(bonus.bonusOf(1), 1);
    }

    function test_UnboundSweetenerCannotTakeMoney() public {
        _open(1);
        YoloSweetener other =
            YoloSweetener(deployCode("src/YoloSweetener.sol:YoloSweetener", abi.encode(address(views))));
        vm.startPrank(people[0]);
        token.approve(address(other), type(uint256).max);
        vm.expectRevert(YoloSweetener.NotBound.selector);
        other.sweeten(1, 10e18);
        vm.stopPrank();
        assertEq(token.balanceOf(address(other)), 0);
        assertEq(other.bonusOf(1), 0);
    }

    function test_UnderReviewBonusCanGrowButPositionCannot_ExactDeadlineLocksBoth() public {
        _open(1);
        views.review(1, true);
        _sweeten(1, people[0], 19);
        vm.prank(people[0]);
        vm.expectRevert(YoloPredict.SubmissionActive.selector);
        market.predict(1, true, 1e18);
        vm.warp(views.getTask(1).deadline);
        vm.prank(people[0]);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        bonus.sweeten(1, 1);
        vm.prank(people[0]);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        bonus.withdraw(1);
        vm.prank(people[0]);
        vm.expectRevert(YoloPredict.WindowClosed.selector);
        market.predict(1, true, 1e18);
        assertEq(bonus.bonusOf(1), 19);
        assertEq(token.balanceOf(address(bonus)), 19);
        // An in-flight proof may be accepted after the deadline and still earns the held bonus.
        _complete(1, false, 0);
        bonus.payout(1);
        assertEq(token.balanceOf(doer), FUNDING + 18);
        assertEq(token.balanceOf(burnRecipient), 1);
    }

    function test_UnknownTasksAndUnpaidVotersCannotTakeOtherTasksMoney() public {
        _open(1);
        _sweeten(1, people[0], 100e18);
        _predict(1, people[0], true, 100e18);
        vm.prank(people[1]);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        bonus.sweeten(999, 1e18);
        vm.prank(people[1]);
        vm.expectRevert(YoloPredict.TaskNotOpen.selector);
        market.predict(999, false, 1e18);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        bonus.claimVoter(1, people[1]);
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        bonus.payout(999);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        market.settle(999);
        assertEq(token.balanceOf(address(bonus)), 100e18);
        assertEq(token.balanceOf(address(market)), 100e18);
    }

    function test_RefundBelongsToDepositorAndCannotCrossTaskOrRepeat() public {
        _open(1);
        _open(2);
        _sweeten(1, people[0], 17);
        _sweeten(1, people[1], 23);
        _sweeten(2, people[0], 100);
        views.finish(1, TaskStatus.Unwound, doer, false, 0);
        vm.prank(people[2]);
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        bonus.withdraw(1);
        vm.prank(people[0]);
        bonus.withdraw(1);
        vm.prank(people[0]);
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        bonus.withdraw(1);
        assertEq(bonus.bonusOf(1), 23);
        assertEq(bonus.bonusOf(2), 100);
        assertEq(token.balanceOf(address(bonus)), 123);
        assertEq(token.balanceOf(people[0]), FUNDING - 100);
        assertTrue(bonus.gave(1, people[0]), "historical donation marker survives refund");
    }

    function test_VoterClaimCannotRedirectOrRepeatAndLastTakesDust() public {
        _open(1);
        views.setVotes(1, people[0], 1);
        views.setVotes(1, people[1], 2);
        _sweeten(1, people[2], 101);
        _complete(1, true, 400);
        bonus.payout(1);
        assertEq(token.balanceOf(doer), FUNDING + 95);
        assertEq(token.balanceOf(burnRecipient), 1);
        assertEq(bonus.voterPool(1), 5);
        vm.prank(people[3]);
        bonus.claimVoter(1, people[0]);
        assertEq(token.balanceOf(people[0]), FUNDING + 1);
        assertEq(token.balanceOf(people[3]), FUNDING);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        bonus.claimVoter(1, people[0]);
        bonus.claimVoter(1, people[1]);
        assertEq(token.balanceOf(people[1]), FUNDING + 4);
        assertEq(bonus.voterVotesLeft(1), 0);
        assertEq(token.balanceOf(address(bonus)), 0);
        vm.prank(people[2]);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        bonus.withdraw(1);
    }

    function test_ZeroWeiVoterShareStillConsumesVotesAndCannotClaimAgain() public {
        _open(1);
        views.setVotes(1, people[0], 1);
        views.setVotes(1, people[1], 100);
        _sweeten(1, people[2], 20);
        _complete(1, true, 0);
        bonus.payout(1);
        bonus.claimVoter(1, people[0]);
        assertTrue(bonus.voterClaimed(1, people[0]));
        assertEq(token.balanceOf(people[0]), FUNDING);
        assertEq(bonus.voterVotesLeft(1), 100);
        bonus.claimVoter(1, people[1]);
        assertEq(token.balanceOf(people[1]), FUNDING + 1);
        assertEq(token.balanceOf(address(bonus)), 0);
    }

    function testFuzz_CancellationRefundsBothSidesExactly(uint96 raw, uint8 rotation) public {
        _open(1);
        uint256 amount = bound(uint256(raw), 1e18, 1e25);
        for (uint256 i; i < 4; ++i) {
            _predict(1, people[i], true, amount + i);
            _predict(1, people[i], false, amount + 20 + i);
        }
        views.finish(1, TaskStatus.Unwound, doer, false, 0);
        for (uint256 i; i < 4; ++i) {
            address who = people[(i + uint256(rotation)) % 4];
            vm.prank(who);
            market.claim(1); // first claim also settles
            assertEq(token.balanceOf(who), FUNDING, "100% refund independent of side and order");
            assertEq(market.paidIn(1, who), 0);
        }
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(author), FUNDING);
        assertEq(token.balanceOf(doer), FUNDING);
        assertEq(token.balanceOf(address(market)), 0);
    }

    function testFuzz_WeightMatchesRationalSquareWithinOneWei(uint96 raw, uint32 durationRaw, uint32 elapsedRaw)
        public
    {
        uint256 amount = bound(uint256(raw), 1e18, 1e25);
        uint256 duration = bound(uint256(durationRaw), 1, type(uint32).max);
        uint256 elapsed = bound(uint256(elapsedRaw), 0, duration - 1);
        views.open(1, author, uint64(duration), 0, views.usdc());
        vm.warp(block.timestamp + elapsed);
        _predict(1, people[0], true, amount);
        (uint256 principal, uint256 points,,) = market.positionsOf(1, people[0]);
        uint256 remaining = duration - elapsed;
        // Independent rational oracle: a single division, not the implementation's pair of mulDiv calls.
        uint256 rational = principal * remaining * remaining / (duration * duration);
        assertLe(points, rational);
        assertLe(rational - points, 1);
        assertLe(points, principal);
        assertEq(principal + market.burnHeld(1) * 2, amount);
    }

    function testFuzz_NoWinnerCompletedSendsPoolsAndOddWeiToRightRecipients(uint96 raw) public {
        _open(1);
        uint256 amount = bound(uint256(raw), 1e18, 1e25);
        _predict(1, people[0], false, amount);
        _complete(1, false, 0);
        (,,, uint256 losingPool,,, uint256 waiting) = market.markets(1);
        uint256 held = market.burnHeld(1);
        market.settle(1);
        assertEq(token.balanceOf(author) - FUNDING, losingPool / 2 + waiting / 2);
        assertEq(token.balanceOf(doer) - FUNDING, losingPool - losingPool / 2 + waiting - waiting / 2);
        assertEq(token.balanceOf(DEAD), held);
        vm.prank(people[0]);
        market.claim(1);
        assertEq(token.balanceOf(people[0]), FUNDING - amount);
        assertEq(token.balanceOf(address(market)), 0);
        market.settle(1);
        assertEq(token.balanceOf(DEAD), held);
    }
}
