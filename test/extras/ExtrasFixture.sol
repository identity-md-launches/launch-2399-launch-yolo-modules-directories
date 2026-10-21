// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {YoloPredict} from "src/YoloPredict.sol";
import {YoloSweetener} from "src/YoloSweetener.sol";
import {DareTrophy} from "src/DareTrophy.sol";
import {TrophyCatalog} from "src/TrophyCatalog.sol";
import {TextRules} from "src/helpers/TextRules.sol";
import {ParamsCore} from "src/VaultParams.sol";
import {SubmitTerms} from "src/desks/DeskApi.sol";
import {Task, Submission, Dispute, Settlement, TaskStatus, Outcome, Verdict, Phase} from "src/VaultTypes.sol";

/// @dev Only the immutable launch fee snapshot read by the sweetener. No oracle exists in this fixture.
contract ExtrasFeeSnapshot {
    function core(uint32) external pure returns (ParamsCore memory p) {
        p.feeBps = 1000;
        p.nftFeeBps = 500;
    }
}

/// @dev View fixture, NOT a replacement implementation of TaskVault. Tests drive terminal states explicitly;
/// the existing integration suite covers how the real desks reach them. No terminal task can reopen here.
contract ExtrasVaultViews {
    IERC20 public immutable yolo;
    address public immutable registry;
    TextRules public immutable textRules;
    address public immutable burner;
    address public immutable imd;
    address public immutable usdc;
    address public sweetener;
    mapping(uint256 => Task) private tasks;
    mapping(uint256 => Submission) private submissions;
    mapping(uint256 => Settlement) private settlements;
    mapping(uint256 => Dispute) private disputes;
    mapping(uint256 => mapping(address => uint256)) private votes;

    constructor(IERC20 token, address fees, TextRules rules, address burnRecipient, address imd_, address usdc_) {
        yolo = token;
        registry = fees;
        textRules = rules;
        burner = burnRecipient;
        imd = imd_;
        usdc = usdc_;
    }

    function caseDesk() external view returns (address) {
        return address(this);
    }

    function bind(address module) external {
        require(sweetener == address(0));
        sweetener = module;
    }

    function open(uint256 id, address author, uint64 duration, uint8 category, address currency) external {
        require(tasks[id].status == TaskStatus.None && duration > 0);
        Task storage t = tasks[id];
        t.author = author;
        t.createdAt = uint64(block.timestamp);
        t.deadline = uint64(block.timestamp + duration);
        t.status = TaskStatus.Open;
        t.paramsVersion = 1;
        t.category = category;
        t.currency = currency;
    }

    function review(uint256 id, bool busy) external {
        require(tasks[id].status == TaskStatus.Open);
        tasks[id].activeSub = busy ? uint64(id) : 0;
    }

    function finish(uint256 id, TaskStatus status, address doer, bool nftRight, uint16 stakeBps) external {
        Task storage t = tasks[id];
        require(t.status == TaskStatus.Open && stakeBps <= 400);
        require(status == TaskStatus.Completed || status == TaskStatus.Expired || status == TaskStatus.Unwound);
        t.status = status;
        if (status == TaskStatus.Completed) {
            t.activeSub = uint64(id);
            Submission storage s = submissions[id];
            s.taskId = uint64(id);
            s.doer = doer;
            s.phase = Phase.Final;
            s.outcome = Outcome.Accepted;
            s.nftDecision = nftRight ? Verdict.Accept : Verdict.None;
            s.reward = 123_456_789;
            s.proofUri = "https://x.com/doer/status/123";
            settlements[id].stakeBps = stakeBps;
        } else {
            t.activeSub = 0;
        }
    }

    function setVotes(uint256 id, address who, uint32 n) external {
        require(submissions[id].outcome == Outcome.None, "votes fixed before acceptance");
        disputes[id].votesAccept -= uint32(votes[id][who]);
        votes[id][who] = n;
        disputes[id].votesAccept += n;
    }

    function poke(uint256 id) external {
        Task storage t = tasks[id];
        if (t.status == TaskStatus.Open && t.activeSub == 0 && block.timestamp >= t.deadline) {
            t.status = TaskStatus.Expired;
        }
    }

    function getTask(uint256 id) external view returns (Task memory) {
        return tasks[id];
    }

    function getSubmission(uint256 id) external view returns (Submission memory) {
        return submissions[id];
    }

    function getSettlement(uint256 id) external view returns (Settlement memory) {
        return settlements[id];
    }

    function getDispute(uint256 id) external view returns (Dispute memory) {
        return disputes[id];
    }

    function votesOf(uint256 id, address who) external view returns (uint256, uint256) {
        return (votes[id][who], 0);
    }

    function submitTerms(uint256 id, address) external view returns (SubmitTerms memory t) {
        Task memory task = tasks[id];
        t.status = task.status;
        t.deadline = task.deadline;
        t.busy = task.activeSub != 0;
    }
}

abstract contract ExtrasFixture is Test {
    address internal constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant FUNDING = 1e30;
    MockERC20 internal token;
    ExtrasVaultViews internal views;
    YoloPredict internal market;
    YoloSweetener internal bonus;
    TrophyCatalog internal catalog;
    DareTrophy internal trophy;
    address[4] internal people;
    address internal author;
    address internal doer;
    address internal burnRecipient;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        for (uint256 i; i < people.length; ++i) {
            people[i] = makeAddr(string.concat("extras actor ", vm.toString(i)));
        }
        author = makeAddr("extras author");
        doer = makeAddr("extras doer");
        burnRecipient = makeAddr("extras burner");
        token = new MockERC20("YOLO test asset", "YOLO", 18);
        TextRules rules = TextRules(deployCode("src/helpers/TextRules.sol:TextRules"));
        views = new ExtrasVaultViews(
            token, address(new ExtrasFeeSnapshot()), rules, burnRecipient, makeAddr("IMD"), makeAddr("USDC")
        );
        market = YoloPredict(deployCode("src/YoloPredict.sol:YoloPredict", abi.encode(address(views), 1e18)));
        bonus = YoloSweetener(deployCode("src/YoloSweetener.sol:YoloSweetener", abi.encode(address(views))));
        views.bind(address(bonus));
        catalog = TrophyCatalog(deployCode("src/TrophyCatalog.sol:TrophyCatalog", abi.encode(PROJECT)));
        trophy = DareTrophy(deployCode("src/DareTrophy.sol:DareTrophy", abi.encode(address(views), address(catalog))));
        for (uint256 i; i < people.length; ++i) {
            _fund(people[i]);
        }
        _fund(author);
        _fund(doer);
    }

    function _fund(address who) internal {
        token.mint(who, FUNDING);
        vm.startPrank(who);
        token.approve(address(market), type(uint256).max);
        token.approve(address(bonus), type(uint256).max);
        token.approve(address(trophy), type(uint256).max);
        vm.stopPrank();
    }

    function _open(uint256 id) internal {
        views.open(id, author, 30 days, 3, views.usdc());
    }

    function _complete(uint256 id, bool nftRight, uint16 stakeBps) internal {
        views.finish(id, TaskStatus.Completed, doer, nftRight, stakeBps);
    }

    function _predict(uint256 id, address who, bool side, uint256 amount) internal {
        vm.prank(who);
        market.predict(id, side, amount);
    }

    function _sweeten(uint256 id, address who, uint256 amount) internal {
        vm.prank(who);
        bonus.sweeten(id, amount);
    }
}
