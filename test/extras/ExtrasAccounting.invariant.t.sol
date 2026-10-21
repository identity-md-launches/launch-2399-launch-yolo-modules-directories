// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExtrasFixture, ExtrasVaultViews, MockERC20, YoloPredict, YoloSweetener} from "./ExtrasFixture.sol";
import {Task, TaskStatus, Verdict} from "src/VaultTypes.sol";

/// @dev All selectors are enumerated below. Expected failures are asserted, never swallowed by catch.
/// Task outcomes are an external input to these modules; only the fixture drives that input.
contract ExtrasAccountingHandler is Test {
    ExtrasVaultViews public views;
    MockERC20 public token;
    YoloPredict public market;
    YoloSweetener public bonus;
    address[4] public actors;
    address public author;
    address public doer;
    uint256 public count;
    uint256 public marketIn;
    uint256 public marketOut;
    uint256 public bonusIn;
    uint256 public bonusOut;
    uint256 public successfulPositions;
    uint256 public successfulClaims;
    uint256 public successfulVoterClaims;
    mapping(uint256 => uint256) public bonusDebt;
    mapping(uint256 => bool) public paidBonus;
    mapping(uint256 => mapping(address => uint256)) public principal;

    constructor(
        ExtrasVaultViews v,
        MockERC20 tk,
        YoloPredict m,
        YoloSweetener b,
        address[4] memory a,
        address au,
        address d
    ) {
        views = v;
        token = tk;
        market = m;
        bonus = b;
        actors = a;
        author = au;
        doer = d;
    }

    function open(uint256 duration) public {
        if (count == 24) return;
        uint256 id = ++count;
        views.open(id, author, uint64(bound(duration, 1 days, 90 days)), uint8(id % 9), views.usdc());
        for (uint256 i; i < actors.length; ++i) {
            views.setVotes(id, actors[i], uint32(i + 1));
        }
    }

    function _id(uint256 seed) private view returns (uint256) {
        return 1 + seed % count;
    }

    function predict(uint256 taskSeed, uint256 actorSeed, bool side, uint256 amount) public {
        uint256 id = _id(taskSeed);
        Task memory t = views.getTask(id);
        if (t.status != TaskStatus.Open || block.timestamp >= t.deadline || t.activeSub != 0) return;
        address who = actors[actorSeed % 4];
        amount = bound(amount, 1e18, 1e25);
        uint256 beforeBalance = token.balanceOf(who);
        vm.prank(who);
        market.predict(id, side, amount);
        assertEq(beforeBalance - token.balanceOf(who), amount, "position debit");
        principal[id][who] += amount;
        marketIn += amount;
        ++successfulPositions;
    }

    function sweeten(uint256 taskSeed, uint256 actorSeed, uint256 amount) public {
        uint256 id = _id(taskSeed);
        Task memory t = views.getTask(id);
        if (t.status != TaskStatus.Open || block.timestamp >= t.deadline) return;
        address who = actors[actorSeed % 4];
        amount = bound(amount, 1, 1e25);
        vm.prank(who);
        bonus.sweeten(id, amount);
        bonusDebt[id] += amount;
        bonusIn += amount;
    }

    function review(uint256 taskSeed, bool busy) external {
        uint256 id = _id(taskSeed);
        if (views.getTask(id).status == TaskStatus.Open) views.review(id, busy);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }

    function finish(uint256 taskSeed, uint8 outcome, bool nftRight, uint16 stakeBps) public {
        uint256 id = _id(taskSeed);
        Task memory t = views.getTask(id);
        if (t.status != TaskStatus.Open) return;
        TaskStatus end = TaskStatus(uint8(TaskStatus.Completed) + outcome % 3);
        if (end == TaskStatus.Expired) {
            if (block.timestamp < t.deadline) vm.warp(t.deadline);
            views.review(id, false);
        }
        views.finish(id, end, doer, nftRight, uint16(bound(stakeBps, 0, 400)));
    }

    function settle(uint256 taskSeed) public {
        uint256 id = _id(taskSeed);
        views.poke(id);
        (uint64 opened,,,,,,) = market.markets(id);
        if (opened == 0 || views.getTask(id).status == TaskStatus.Open) return;
        uint256 beforeBalance = token.balanceOf(address(market));
        market.settle(id);
        marketOut += beforeBalance - token.balanceOf(address(market));
        // Repetition must be inert, including transfers of the no-winner pool.
        beforeBalance = token.balanceOf(address(market));
        market.settle(id);
        assertEq(token.balanceOf(address(market)), beforeBalance, "second settlement paid twice");
    }

    function claim(uint256 taskSeed, uint256 actorSeed) public {
        uint256 id = _id(taskSeed);
        views.poke(id);
        if (views.getTask(id).status == TaskStatus.Open) return;
        address who = actors[actorSeed % 4];
        if (principal[id][who] == 0) {
            vm.prank(who);
            vm.expectRevert(YoloPredict.NothingToClaim.selector);
            market.claim(id);
            return;
        }
        settle(taskSeed);
        uint256 beforeBalance = token.balanceOf(who);
        (uint256 yes, uint256 yesPoints, uint256 no, uint256 noPoints) = market.positionsOf(id, who);
        TaskStatus status = views.getTask(id).status;
        (,, uint256 yesPool, uint256 noPool, uint256 totalYesPoints, uint256 totalNoPoints,) = market.markets(id);
        (bool started, uint256 poolLeft, uint256 pointsLeft) = market.splits(id);
        bool willDoWon = status == TaskStatus.Completed;
        uint256 totalPoints = willDoWon ? totalYesPoints : totalNoPoints;
        uint256 winnerPrincipal = willDoWon ? yes : no;
        uint256 weight = totalPoints == 0 ? winnerPrincipal : willDoWon ? yesPoints : noPoints;
        if (!started) {
            poolLeft = willDoWon ? noPool : yesPool;
            pointsLeft = totalPoints == 0 ? (willDoWon ? yesPool : noPool) : totalPoints;
        }
        vm.prank(who);
        market.claim(id);
        uint256 received = token.balanceOf(who) - beforeBalance;
        if (status == TaskStatus.Unwound) {
            assertEq(received, principal[id][who], "void must refund 100%");
        } else {
            if (winnerPrincipal == 0) {
                assertEq(received, 0, "loser was refunded");
            } else {
                assertGe(received, winnerPrincipal, "winner lost its effective principal");
                uint256 share = received - winnerPrincipal;
                if (weight == 0) {
                    assertEq(share, 0, "zero weight claimed a nonzero split");
                } else {
                    // Cross-multiplied bounds check the rational share without copying mulDiv.
                    assertGt(pointsLeft, 0);
                    assertLe(share * pointsLeft, poolLeft * weight, "winner overpaid by points");
                    assertLt(poolLeft * weight, (share + 1) * pointsLeft, "winner underpaid by points");
                }
            }
        }
        marketOut += received;
        principal[id][who] = 0;
        ++successfulClaims;
        vm.prank(who);
        vm.expectRevert(YoloPredict.NothingToClaim.selector);
        market.claim(id);
    }

    function payout(uint256 taskSeed) public {
        uint256 id = _id(taskSeed);
        if (views.getTask(id).status != TaskStatus.Completed || bonusDebt[id] == 0) return;
        uint256 amount = bonusDebt[id];
        uint256 doerBefore = token.balanceOf(doer);
        uint256 burnerBefore = token.balanceOf(views.burner());
        uint256 fee = amount / 10;
        uint256 voters = views.getSubmission(id).nftDecision == Verdict.Accept ? amount / 20 : 0;
        uint256 stake = amount * views.getSettlement(id).stakeBps / 10_000;
        uint256 beforeBalance = token.balanceOf(address(bonus));
        bonus.payout(id);
        assertEq(token.balanceOf(doer) - doerBefore, amount - fee + stake, "wrong doer bonus");
        assertEq(token.balanceOf(views.burner()) - burnerBefore, fee - voters - stake, "wrong burn recipient/share");
        assertEq(bonus.voterPool(id), voters, "wrong NFT fee");
        bonusOut += beforeBalance - token.balanceOf(address(bonus));
        bonusDebt[id] = 0;
        paidBonus[id] = true;
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        bonus.payout(id);
    }

    function withdraw(uint256 taskSeed, uint256 actorSeed) public {
        uint256 id = _id(taskSeed);
        views.poke(id);
        TaskStatus status = views.getTask(id).status;
        if (status != TaskStatus.Expired && status != TaskStatus.Unwound) return;
        address who = actors[actorSeed % 4];
        uint256 due = bonus.givenBy(id, who);
        if (due == 0) return;
        uint256 beforeBalance = token.balanceOf(who);
        vm.prank(who);
        bonus.withdraw(id);
        assertEq(token.balanceOf(who) - beforeBalance, due, "refund changed donor's share");
        bonusOut += due;
        bonusDebt[id] -= due;
        vm.prank(who);
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        bonus.withdraw(id);
    }

    function claimVoter(uint256 taskSeed, uint256 actorSeed) public {
        uint256 id = _id(taskSeed);
        address who = actors[actorSeed % 4];
        if (bonus.voterVotesLeft(id) == 0 || bonus.voterClaimed(id, who)) return;
        uint256 pool = bonus.voterPool(id);
        uint256 votesLeft = bonus.voterVotesLeft(id);
        uint256 votes = 1 + actorSeed % 4;
        uint256 beforeBalance = token.balanceOf(who);
        // Anyone may trigger it, but the caller cannot redirect the receiver's share.
        bonus.claimVoter(id, who);
        uint256 share = token.balanceOf(who) - beforeBalance;
        assertLe(share * votesLeft, pool * votes);
        assertLt(pool * votes, (share + 1) * votesLeft);
        bonusOut += share;
        ++successfulVoterClaims;
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        bonus.claimVoter(id, who);
    }

    function probeLocked(uint256 taskSeed, uint256 actorSeed) external {
        uint256 id = _id(taskSeed);
        Task memory t = views.getTask(id);
        if (t.status != TaskStatus.Open || block.timestamp >= t.deadline) return;
        address who = actors[actorSeed % 4];
        vm.prank(who);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        bonus.withdraw(id);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        market.settle(id);
        if (principal[id][who] != 0) {
            vm.prank(who);
            vm.expectRevert(YoloPredict.NotFinal.selector);
            market.claim(id);
        }
    }

    /// @dev Liveness: finish every open task, then drain every refund and winning/voter share without catch.
    function drain() external {
        for (uint256 id = 1; id <= count; ++id) {
            if (views.getTask(id).status == TaskStatus.Open) finish(id - 1, uint8(id % 3), true, 400);
            settle(id - 1);
            payout(id - 1);
            for (uint256 a; a < 4; ++a) {
                claim(id - 1, a);
                withdraw(id - 1, a);
                claimVoter(id - 1, a);
            }
        }
        assertEq(token.balanceOf(address(market)), 0, "market stranded funds after all claims");
        assertEq(token.balanceOf(address(bonus)), 0, "sweetener stranded funds after all claims");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract ExtrasAccountingInvariantTest is ExtrasFixture {
    ExtrasAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ExtrasAccountingHandler(views, token, market, bonus, people, author, doer);
        for (uint256 i; i < 6; ++i) {
            handler.open(30 days);
            handler.predict(i, i, i % 2 == 0, 10e18 + i * 21);
            if (i < 4) handler.predict(i, i + 1, i % 2 != 0, 17e18 + i);
            handler.sweeten(i, i, 100e18 + i * 39);
        }
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.predict.selector;
        selectors[2] = handler.sweeten.selector;
        selectors[3] = handler.review.selector;
        selectors[4] = handler.warp.selector;
        selectors[5] = handler.finish.selector;
        selectors[6] = handler.settle.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.payout.selector;
        selectors[9] = handler.withdraw.selector;
        selectors[10] = handler.claimVoter.selector;
        selectors[11] = handler.probeLocked.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_BonusBalanceEqualsBonusesAndUnclaimedVotes() public view {
        uint256 owed;
        for (uint256 id = 1; id <= handler.count(); ++id) {
            assertEq(bonus.bonusOf(id), handler.bonusDebt(id), "bonus debt differs from deposits/refunds");
            uint256 votesLeft;
            if (handler.paidBonus(id) && views.getSubmission(id).nftDecision == Verdict.Accept) {
                for (uint256 a; a < 4; ++a) {
                    if (!bonus.voterClaimed(id, people[a])) votesLeft += a + 1;
                }
            }
            assertEq(bonus.voterVotesLeft(id), votesLeft, "vote claims lost or duplicated");
            owed += bonus.bonusOf(id) + bonus.voterPool(id);
        }
        assertEq(token.balanceOf(address(bonus)), owed);
        assertEq(owed, handler.bonusIn() - handler.bonusOut());
    }

    function invariant_MarketBalanceEqualsOutstandingLiabilities() public view {
        uint256 owed;
        for (uint256 id = 1; id <= handler.count(); ++id) {
            (, bool settled, uint256 yesPool, uint256 noPool,,, uint256 deferred) = market.markets(id);
            TaskStatus status = views.getTask(id).status;
            uint256 paid;
            uint256 winnerPrincipal;
            for (uint256 a; a < 4; ++a) {
                address who = people[a];
                assertEq(market.paidIn(id, who), handler.principal(id, who), "principal tracking");
                paid += market.paidIn(id, who);
                (uint256 yes,, uint256 no,) = market.positionsOf(id, who);
                winnerPrincipal += status == TaskStatus.Completed ? yes : no;
            }
            if (!settled) {
                assertEq(paid, yesPool + noPool + deferred + market.burnHeld(id), "entry conservation");
                owed += paid;
            } else if (status == TaskStatus.Unwound) {
                owed += paid;
            } else {
                (bool started, uint256 losingLeft,) = market.splits(id);
                if (!started) losingLeft = status == TaskStatus.Completed ? noPool : yesPool;
                owed += winnerPrincipal + losingLeft;
            }
            if (settled) {
                assertEq(market.burnHeld(id), 0);
                assertEq(deferred, 0);
                assertTrue(status != TaskStatus.Open, "settled market reopened");
            }
        }
        assertEq(token.balanceOf(address(market)), owed, "market cannot meet exact outstanding claims");
        assertEq(owed, handler.marketIn() - handler.marketOut(), "market cashflow conservation");
    }

    function invariant_TokensStayWithParticipantsRecipientsOrEscrows() public view {
        uint256 held = token.balanceOf(address(market)) + token.balanceOf(address(bonus));
        for (uint256 i; i < 4; ++i) {
            held += token.balanceOf(people[i]);
        }
        held += token.balanceOf(author) + token.balanceOf(doer) + token.balanceOf(burnRecipient) + token.balanceOf(DEAD);
        assertEq(held, token.totalSupply());
        assertEq(token.totalSupply(), 6 * FUNDING, "transfers to DEAD do not mint or destroy supply");
    }

    function afterInvariant() public {
        handler.drain();
        invariant_BonusBalanceEqualsBonusesAndUnclaimedVotes();
        invariant_MarketBalanceEqualsOutstandingLiabilities();
        invariant_TokensStayWithParticipantsRecipientsOrEscrows();
    }

    /// Ensures the important handler paths execute even before the random campaign starts.
    function test_HandlerExercisesEveryOutcomeAndVoterDust() public {
        handler.finish(0, 0, true, 400);
        handler.payout(0);
        handler.claimVoter(0, 3);
        handler.finish(1, 2, false, 0);
        handler.claim(1, 1);
        handler.drain();
        assertGt(handler.successfulPositions(), 0);
        assertGt(handler.successfulClaims(), 0);
        assertGt(handler.successfulVoterClaims(), 0);
    }
}
