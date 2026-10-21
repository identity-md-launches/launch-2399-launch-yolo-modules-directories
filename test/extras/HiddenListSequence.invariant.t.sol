// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HiddenList} from "src/HiddenList.sol";
import {MockNFT} from "../mocks/MockNFT.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";

/// @dev Independent ledger of which NFT, owner and caller contributed to each round. It deliberately keeps
/// owner-at-vote-time separate from caller and current owner; transfers/delegations must not create more votes.
contract HiddenListSequenceHandler is Test {
    HiddenList public hidden;
    MockNFT public nft;
    MockDelegateRegistry public delegates;
    address public project;
    address[8] public actors;
    uint256[24] public ids;
    address[2] public vaults;
    uint256[4] public generation;
    uint32[4] public hideCount;
    uint32[4] public keepCount;
    uint16[4] public hideCallers;
    uint16[4] public hideOwners;
    uint8[4] public walletState;
    mapping(bytes32 => bool) private used;
    mapping(bytes32 => bool) private ownerSeen;
    mapping(bytes32 => uint8) private side;
    uint256 public countedCalls;

    constructor(HiddenList h, MockNFT n, MockDelegateRegistry d, address p, address[8] memory a, address[2] memory v) {
        hidden = h;
        nft = n;
        delegates = d;
        project = p;
        actors = a;
        vaults = v;
        for (uint256 i; i < 24; ++i) {
            ids[i] = i < 6 ? i : i < 18 ? 250 + i - 6 : type(uint256).max - (23 - i);
        }
    }

    function _key(uint256 item, uint256 value) private view returns (bytes32) {
        return keccak256(abi.encode(item, generation[item], value));
    }

    function _status(uint256 item) private view returns (uint8, uint32, uint32, uint16, uint64) {
        return hidden.status(vaults[item / 2], uint8(1 + item % 2), 7);
    }

    function _clear(uint256 item) private {
        ++generation[item];
        hideCount[item] = 0;
        keepCount[item] = 0;
        hideCallers[item] = 0;
        hideOwners[item] = 0;
    }

    function _ownerIndex(address who) private view returns (uint256) {
        for (uint256 i; i < 4; ++i) {
            if (actors[i] == who) return i;
        }
        revert("owner outside actor set");
    }

    function _expectVotes(uint256 item, uint256 caller, bool hide, uint256[] memory tokens) private {
        bytes32 callerKey = _key(item, caller);
        uint8 chosen = hide ? 1 : 2;
        uint8 oldSide = side[callerKey];
        if (oldSide != 0 && oldSide != chosen) return;
        uint256 added;
        for (uint256 j; j < tokens.length; ++j) {
            uint256 index = 24;
            for (uint256 k; k < 24; ++k) {
                if (ids[k] == tokens[j]) {
                    index = k;
                    break;
                }
            }
            if (index == 24 || used[_key(item, index)]) continue;
            address owner = nft.ownerOf(tokens[j]);
            if (owner != actors[caller] && !delegates.delegated(owner, actors[caller])) continue;
            used[_key(item, index)] = true;
            ++added;
            if (hide && !ownerSeen[_key(item, _ownerIndex(owner))]) {
                ownerSeen[_key(item, _ownerIndex(owner))] = true;
                ++hideOwners[item];
            }
        }
        if (added == 0) return;
        if (hide) {
            hideCount[item] += uint32(added);
            if (oldSide == 0) ++hideCallers[item];
        } else {
            keepCount[item] += uint32(added);
        }
        side[callerKey] = chosen;
        ++countedCalls;
    }

    function vote(uint256 itemSeed, uint256 callerSeed, bool hide, uint256 tokenSeed, uint8 length) external {
        uint256 item = itemSeed % 4;
        uint256 caller = callerSeed % 8;
        (uint8 state,,,, uint64 end) = _status(item);
        // Ended-round retry policy is exercised by retry() and the deterministic cooldown tests.
        if (state != 0 || (end != 0 && block.timestamp >= end)) return;
        uint256[] memory tokens = new uint256[](uint256(length) % 10);
        for (uint256 j; j < tokens.length; ++j) {
            uint256 k = (tokenSeed % 25 + j / 2) % 25; // duplicates plus a nonexistent ID
            tokens[j] = k == 24 ? type(uint256).max - 100 : ids[k];
        }
        if (end != 0 || hide) _expectVotes(item, caller, hide, tokens);
        vm.prank(actors[caller]);
        hidden.vote(vaults[item / 2], uint8(1 + item % 2), 7, hide, tokens);
        assertAllItems();
    }

    function transfer(uint256 tokenSeed, uint256 receiverSeed) external {
        uint256 id = ids[tokenSeed % 24];
        address owner = nft.ownerOf(id);
        vm.prank(owner);
        nft.transferFrom(owner, actors[receiverSeed % 4], id);
    }

    function delegate(uint256 ownerSeed, uint256 callerSeed, bool on) external {
        vm.prank(actors[ownerSeed % 4]);
        delegates.delegateAll(actors[callerSeed % 8], on);
    }

    function setState(uint256 itemSeed, uint8 stateSeed, bool authorized) external {
        uint256 item = itemSeed % 4;
        uint8 state = stateSeed % 3;
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(vaults[item / 2], uint8(1 + item % 2), 7);
        vm.prank(authorized ? project : actors[0]);
        if (!authorized) vm.expectRevert(HiddenList.NotOwner.selector);
        hidden.setState(items, state);
        if (authorized) {
            _clear(item);
            walletState[item] = state;
        }
        assertAllItems();
    }

    function warp(uint256 amount) external {
        vm.warp(block.timestamp + bound(amount, 1, 2 days));
    }

    function retry(uint256 itemSeed, uint256 tokenSeed) external {
        uint256 item = itemSeed % 4;
        (uint8 state,,,, uint64 end) = _status(item);
        if (state != 0 || end == 0 || block.timestamp < end) return;
        if (block.timestamp < uint256(end) + 7 days) vm.warp(uint256(end) + 7 days);
        _clear(item);
        uint256[] memory one = new uint256[](1);
        one[0] = ids[tokenSeed % 24];
        address owner = nft.ownerOf(one[0]);
        _expectVotes(item, _ownerIndex(owner), true, one);
        vm.prank(owner);
        hidden.vote(vaults[item / 2], uint8(1 + item % 2), 7, true, one);
        assertAllItems();
    }

    function assertAllItems() public view {
        for (uint256 item; item < 4; ++item) {
            (uint8 state, uint32 h, uint32 k, uint16 callers, uint64 end) = _status(item);
            assertEq(h, hideCount[item], "NFT reused, unauthorized, or lost hide vote");
            assertEq(k, keepCount[item], "NFT reused, unauthorized, or lost keep vote");
            assertEq(callers, hideCallers[item], "one caller counted twice");
            assertLe(uint256(h) + k, 24, "more votes than distinct NFTs");
            uint8 expected = walletState[item];
            if (expected == 0 && end != 0 && block.timestamp >= end && h >= 10 && h > k && hideOwners[item] >= 3) {
                expected = 3;
            }
            assertEq(state, expected, "owner state or distinct-owner quorum violated");
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HiddenListSequenceInvariantTest is Test {
    address private constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    HiddenList private hidden;
    MockNFT private nft;
    MockDelegateRegistry private delegates;
    HiddenListSequenceHandler private handler;
    address[8] private actors;
    address[2] private vaults;

    function setUp() public {
        vm.warp(1_800_000_000);
        for (uint256 i; i < 8; ++i) {
            actors[i] = makeAddr(string.concat("hide actor ", vm.toString(i)));
        }
        vaults = [makeAddr("hide vault 1"), makeAddr("hide vault 2")];
        nft = new MockNFT();
        delegates = new MockDelegateRegistry();
        hidden = HiddenList(deployCode("src/HiddenList.sol:HiddenList", abi.encode(PROJECT, nft, delegates)));
        handler = new HiddenListSequenceHandler(hidden, nft, delegates, PROJECT, actors, vaults);
        for (uint256 i; i < 24; ++i) {
            nft.mint(actors[i % 4], handler.ids(i));
        }
        for (uint256 i; i < 4; ++i) {
            handler.vote(i, i, true, i, 2);
        }
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.vote.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.delegate.selector;
        selectors[3] = handler.setState.selector;
        selectors[4] = handler.warp.selector;
        selectors[5] = handler.retry.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_OneNftOneVoteAndOwnerStateHoldsAcrossTransfers() public view {
        handler.assertAllItems();
        assertEq(address(hidden).balance, 0);
        assertEq(hidden.owner(), PROJECT);
    }

    function test_DelegationRevocationAndTransferCannotRecycleTokenInRound() public {
        // Token 0 already voted on item 0 in setup. A new owner and a new delegate still cannot reuse it.
        handler.transfer(0, 1);
        handler.delegate(1, 4, true);
        handler.vote(0, 4, true, 0, 2);
        assertEq(handler.hideCount(0), 1);
        handler.delegate(1, 4, false);
        handler.vote(0, 4, true, 1, 2);
        assertEq(handler.hideCount(0), 1);
        handler.vote(0, 1, false, 1, 2);
        assertEq(handler.keepCount(0), 1);
        assertGt(handler.countedCalls(), 0);
    }

    function test_DelegationFailureSkipsTokenAndDoesNotOpenRound() public {
        vm.etch(address(delegates), hex"60006000fd"); // dependency reverts without consuming all forwarded gas
        uint256[] memory ids = new uint256[](1);
        ids[0] = handler.ids(7);
        vm.prank(actors[7]);
        hidden.vote(vaults[0], 1, 999, true, ids);
        (uint8 state, uint32 h, uint32 k, uint16 callers, uint64 end) = hidden.status(vaults[0], 1, 999);
        assertEq(uint256(state) + h + k + callers + end, 0);
    }

    function test_ERC721ApprovalIsNotDelegateXyzPermission() public {
        uint256 id = handler.ids(7);
        vm.prank(nft.ownerOf(id));
        nft.approve(actors[7], id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(actors[7]);
        hidden.vote(vaults[0], 1, 999, true, ids);
        (,,,, uint64 end) = hidden.status(vaults[0], 1, 999);
        assertEq(end, 0);
    }
}
