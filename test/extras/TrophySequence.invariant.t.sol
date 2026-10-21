// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExtrasFixture, DareTrophy, TrophyCatalog, MockERC20} from "./ExtrasFixture.sol";
import {TaskStatus} from "src/VaultTypes.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TrophySequenceHandler is Test {
    DareTrophy public trophy;
    TrophyCatalog public catalog;
    address public project;
    address public doer;
    address[4] public receivers;
    mapping(uint256 => bool) public minted;
    mapping(uint256 => bytes32) public uriHash;
    mapping(uint256 => uint256) public designAtMint;
    uint256 public mintCount;

    constructor(DareTrophy t, TrophyCatalog c, address p, address d, address[4] memory r) {
        trophy = t;
        catalog = c;
        project = p;
        doer = d;
        receivers = r;
    }

    function mint(uint256 seed) public {
        uint256 id = 1 + seed % 8;
        vm.prank(doer);
        if (minted[id]) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        }
        trophy.mint(id, "Earned trophy");
        if (!minted[id]) {
            minted[id] = true;
            uriHash[id] = keccak256(bytes(trophy.tokenURI(id)));
            designAtMint[id] = trophy.mintedOf(id).design;
            ++mintCount;
        }
    }

    function transfer(uint256 seed, uint256 receiver) external {
        uint256 id = 1 + seed % 8;
        if (!minted[id]) return;
        address owner = trophy.ownerOf(id);
        vm.prank(owner);
        trophy.safeTransferFrom(owner, receivers[receiver % 4], id);
    }

    function unauthorized(uint256 seed) external {
        uint256 id = 1 + seed % 8;
        address stranger = receivers[seed % 4];
        vm.prank(stranger);
        vm.expectRevert(DareTrophy.NotTheDoer.selector);
        trophy.mint(id, "Not earned");
        if (minted[id]) {
            address owner = trophy.ownerOf(id);
            if (stranger == owner) stranger = receivers[(seed % 4 + 1) % 4];
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, id));
            trophy.transferFrom(owner, stranger, id);
        }
    }

    function changeDesign(uint8 category, uint8 design, bool enabled) external {
        uint256 id = 1 + uint256(design) % 2;
        vm.startPrank(project);
        catalog.setDesignEnabled(id, enabled);
        catalog.setDefaultDesign(enabled ? id : 0);
        catalog.setCategoryDesign(category % 9, enabled ? id : 0);
        vm.stopPrank();
    }

    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(uint256(delta), 1, 30 days));
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TrophySequenceInvariantTest is ExtrasFixture {
    TrophySequenceHandler private handler;

    function setUp() public override {
        super.setUp();
        vm.startPrank(PROJECT);
        catalog.addDesign("First", bytes("<svg viewBox='0 0 24 24'></svg>"));
        catalog.addDesign("Second", bytes("<svg viewBox='0 0 24 24'><rect width='24' height='24'/></svg>"));
        vm.stopPrank();
        for (uint256 id = 1; id <= 8; ++id) {
            views.open(id, author, 30 days, uint8(id), views.usdc());
            views.finish(id, TaskStatus.Completed, doer, false, 0);
        }
        handler = new TrophySequenceHandler(trophy, catalog, PROJECT, doer, people);
        handler.mint(0); // seed a real immutable trophy before any catalogue mutations
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.unauthorized.selector;
        selectors[3] = handler.changeDesign.selector;
        selectors[4] = handler.warp.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EachTrophyBurnsExactlyOnceAndKeepsItsDesignAndMetadata() public view {
        uint256 minted;
        for (uint256 id = 1; id <= 8; ++id) {
            if (!handler.minted(id)) continue;
            ++minted;
            assertEq(keccak256(bytes(trophy.tokenURI(id))), handler.uriHash(id), "metadata changed after mint");
            assertEq(trophy.mintedOf(id).design, handler.designAtMint(id));
            assertEq(trophy.mintedOf(id).yoloBurned, 7_777e18);
        }
        assertEq(minted, handler.mintCount());
        assertEq(trophy.totalBurned(), minted * 7_777e18);
        assertEq(token.balanceOf(DEAD), minted * 7_777e18);
        assertEq(token.balanceOf(doer), FUNDING - minted * 7_777e18);
        assertEq(token.balanceOf(address(trophy)), 0);
        uint256 owned = trophy.balanceOf(doer);
        for (uint256 i; i < 4; ++i) {
            owned += trophy.balanceOf(people[i]);
        }
        assertEq(owned, minted, "NFT supply changed during transfers");
    }
}
