// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExtrasFixture, DareTrophy, TrophyCatalog} from "./ExtrasFixture.sol";
import {ProtocolDirectory} from "src/ProtocolDirectory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// forge-config: default.fuzz.runs = 256
contract ExtrasMetadataTest is ExtrasFixture {
    function test_FailedMintPaymentRollsBackTokenRecordAndBurnThenCanRetry() public {
        _open(1);
        _complete(1, false, 0);
        vm.startPrank(doer);
        token.approve(address(trophy), 7_777e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(trophy), 7_777e18 - 1, 7_777e18
            )
        );
        trophy.mint(1, "First attempt");
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        trophy.ownerOf(1);
        assertEq(trophy.mintedOf(1).time, 0);
        assertEq(trophy.mintedOf(1).title, "");
        assertEq(trophy.totalBurned(), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(doer), FUNDING);
        vm.startPrank(doer);
        token.approve(address(trophy), 7_777e18);
        trophy.mint(1, "Paid retry");
        vm.stopPrank();
        assertEq(trophy.ownerOf(1), doer);
        assertEq(trophy.mintedOf(1).title, "Paid retry");
        assertEq(token.balanceOf(DEAD), 7_777e18);
        assertEq(token.balanceOf(address(trophy)), 0);
        assertEq(token.totalSupply(), 6 * FUNDING);
    }

    function test_DuplicateMintAfterTransferCannotRewriteMetadataOrBurnAgain() public {
        _open(1);
        _complete(1, false, 0);
        vm.startPrank(doer);
        trophy.mint(1, "Original");
        trophy.transferFrom(doer, people[0], 1);
        vm.stopPrank();
        bytes32 beforeUri = keccak256(bytes(trophy.tokenURI(1)));
        vm.startPrank(PROJECT);
        uint256 design = catalog.addDesign("Replacement", bytes("<svg></svg>"));
        catalog.setDefaultDesign(design);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(doer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        trophy.mint(1, "Changed");
        vm.prank(people[0]);
        vm.expectRevert(DareTrophy.NotTheDoer.selector);
        trophy.mint(1, "Buyer cannot mint");
        assertEq(trophy.ownerOf(1), people[0]);
        assertEq(keccak256(bytes(trophy.tokenURI(1))), beforeUri);
        assertEq(trophy.mintedOf(1).design, 0);
        assertEq(trophy.totalBurned(), 7_777e18);
        assertEq(token.balanceOf(DEAD), 7_777e18);
    }

    function test_CatalogTwoStepTransferPendingOwnerHasNoPowers() public {
        address next = people[0];
        vm.prank(PROJECT);
        catalog.transferOwnership(next);
        assertEq(catalog.owner(), PROJECT);
        assertEq(catalog.pendingOwner(), next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        catalog.addDesign("Too early", bytes("<svg></svg>"));
        vm.prank(people[1]);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, people[1]));
        catalog.acceptOwnership();
        vm.prank(next);
        catalog.acceptOwnership();
        vm.prank(PROJECT);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, PROJECT));
        catalog.setDefaultDesign(0);
        vm.prank(next);
        uint256 id = catalog.addDesign("New custodian", bytes("<svg></svg>"));
        assertEq(id, 1);
        assertEq(catalog.owner(), next);
        assertEq(catalog.pendingOwner(), address(0));
    }

    function _svg(uint256 length) private pure returns (bytes memory svg) {
        svg = new bytes(length);
        for (uint256 i; i < length; ++i) {
            svg[i] = " ";
        }
        bytes memory start = bytes("<svg>");
        bytes memory end = bytes("</svg>");
        for (uint256 i; i < start.length; ++i) {
            svg[i] = start[i];
        }
        for (uint256 i; i < end.length; ++i) {
            svg[length - end.length + i] = end[i];
        }
    }

    function test_CatalogExactByteLimitsAndFullMetadataEnvelope() public {
        string memory name = "12345678901234567890123456789012";
        string memory title = "1234567890123456789012345678901234567890123456789012345678901234";
        bytes memory svg = _svg(8192);
        vm.startPrank(PROJECT);
        uint256 design = catalog.addDesign(name, svg);
        catalog.setCategoryDesign(3, design);
        vm.expectRevert(TrophyCatalog.BadName.selector);
        catalog.addDesign(string.concat(name, "x"), svg);
        vm.expectRevert(TrophyCatalog.BadImage.selector);
        catalog.addDesign(name, _svg(8193));
        vm.stopPrank();
        assertEq(catalog.designCount(), 1);
        _open(1);
        _complete(1, false, 0);
        vm.prank(doer);
        trophy.mint(1, title);
        string memory json = string.concat(
            '{"name":"Dare #1 trophy","description":"',
            title,
            ' (accepted on moneycanbuy.fun)","image":"data:image/svg+xml;base64,',
            vm.toBase64(svg),
            '","attributes":[{"trait_type":"Task","value":1},{"trait_type":"Submission","value":1}',
            ',{"trait_type":"Category","value":"Sport"},{"trait_type":"Reward","value":"123.4567 USDC"}',
            ',{"trait_type":"Proof","value":"https://x.com/doer/status/123"}',
            ',{"display_type":"date","trait_type":"Minted","value":',
            vm.toString(block.timestamp),
            '},{"trait_type":"Design","value":"',
            name,
            '"}]}'
        );
        assertEq(trophy.tokenURI(1), string.concat("data:application/json;base64,", vm.toBase64(json)));
        vm.prank(PROJECT);
        catalog.setDesignEnabled(design, false);
        assertEq(trophy.tokenURI(1), string.concat("data:application/json;base64,", vm.toBase64(json)));
        assertEq(catalog.designFor(3), 0);
        assertEq(catalog.design(design).image, svg);
    }

    function testFuzz_TitleRejectsEveryForbiddenByteIncludingWordBoundary(uint8 raw, uint8 position) public {
        _open(1);
        _complete(1, false, 0);
        uint256 index = bound(uint256(raw), 0, 162);
        uint8 bad = index < 32 ? uint8(index) : index == 32 ? 34 : index == 33 ? 92 : uint8(index + 93);
        bytes memory title = bytes("1234567890123456789012345678901234567890123456789012345678901234");
        title[uint256(position) % 64] = bytes1(bad);
        vm.prank(doer);
        vm.expectRevert(DareTrophy.BadTitle.selector);
        trophy.mint(1, string(title));
        assertEq(trophy.totalBurned(), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_CatalogDisabledCategoryFallsBackToDefaultThenBuiltin() public {
        vm.startPrank(PROJECT);
        uint256 first = catalog.addDesign("Category", bytes("<svg></svg>"));
        uint256 second = catalog.addDesign("Default", bytes("<svg>\n\t</svg>"));
        catalog.setCategoryDesign(8, first);
        catalog.setDefaultDesign(second);
        catalog.setDesignEnabled(first, false);
        assertEq(catalog.designFor(8), second);
        vm.expectRevert(abi.encodeWithSelector(TrophyCatalog.DesignOff.selector, first));
        catalog.setCategoryDesign(0, first);
        vm.expectRevert(abi.encodeWithSelector(TrophyCatalog.DesignOff.selector, first));
        catalog.setDefaultDesign(first);
        catalog.setDesignEnabled(second, false);
        assertEq(catalog.designFor(8), 0);
        catalog.setDesignEnabled(first, true);
        assertEq(catalog.designFor(8), first);
        vm.stopPrank();
        assertEq(catalog.design(first).name, "Category");
        assertEq(catalog.design(first).image, bytes("<svg></svg>"));
    }
}

contract DirectoryAnchor {}

/// forge-config: default.fuzz.runs = 256
contract ExtrasDirectoryTest is Test {
    address private constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address private constant VAULT = 0x88c3B0B64e6869C424DAF25ad8eD635180832493;
    ProtocolDirectory private directory;
    address private nextVault;

    function setUp() public {
        vm.warp(1_800_000_000);
        directory = ProtocolDirectory(
            deployCode(
                "src/ProtocolDirectory.sol:ProtocolDirectory",
                abi.encode(PROJECT, VAULT, address(0), address(0), uint64(26_241_860))
            )
        );
        nextVault = address(new DirectoryAnchor());
    }

    function _proposal(string memory label) private view returns (ProtocolDirectory.Version memory) {
        return ProtocolDirectory.Version(nextVault, address(0), address(0), 123, 777, label);
    }

    function testFuzz_ReplacingProposalRestartsFullDelayAndNeverMutatesOldVersion(uint32 delay) public {
        bytes32 original = keccak256(abi.encode(directory.version(1)));
        vm.prank(PROJECT);
        directory.proposeVersion(_proposal("superseded"));
        uint64 firstEta = directory.pendingVersionEta();
        vm.warp(block.timestamp + bound(uint256(delay), 1, 48 hours - 1));
        vm.prank(PROJECT);
        directory.proposeVersion(_proposal("replacement"));
        uint64 newEta = directory.pendingVersionEta();
        assertGt(newEta, firstEta);
        vm.warp(firstEta);
        vm.expectRevert(ProtocolDirectory.TimelockNotPassed.selector);
        directory.addVersion();
        vm.warp(newEta - 1);
        vm.expectRevert(ProtocolDirectory.TimelockNotPassed.selector);
        directory.addVersion();
        vm.warp(newEta);
        vm.prank(makeAddr("permissionless executor"));
        directory.addVersion();
        assertEq(directory.version(2).label, "replacement");
        assertEq(directory.version(2).addedAt, newEta, "caller-supplied addedAt must be ignored");
        assertEq(directory.current(), 1);
        assertEq(keccak256(abi.encode(directory.version(1))), original);
        assertEq(directory.pendingVersion().vault, address(0));
        vm.expectRevert(ProtocolDirectory.NothingPending.selector);
        directory.addVersion();
    }

    function test_CodeCheckAtExecutionPreservesProposalOnFailure() public {
        bytes memory runtime = nextVault.code;
        vm.prank(PROJECT);
        directory.proposeVersion(_proposal("v2"));
        uint64 eta = directory.pendingVersionEta();
        vm.warp(eta);
        vm.etch(nextVault, hex"");
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.NoCode.selector, nextVault));
        directory.addVersion();
        assertEq(directory.pendingVersionEta(), eta);
        assertEq(directory.pendingVersion().vault, nextVault);
        assertEq(directory.versionCount(), 1);
        vm.etch(nextVault, runtime);
        directory.addVersion();
        assertEq(directory.versionCount(), 2);
    }

    function test_CurrentReplacementHasIndependentDelayAndFailedExecuteRemainsPending() public {
        vm.startPrank(PROJECT);
        directory.proposeVersion(_proposal("v2"));
        directory.proposeCurrent(2);
        vm.stopPrank();
        uint64 eta = directory.pendingCurrentEta();
        vm.warp(eta);
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.UnknownVersion.selector, 2));
        directory.setCurrent();
        assertEq(directory.pendingCurrentEta(), eta);
        assertEq(directory.current(), 1);
        directory.addVersion();
        directory.setCurrent();
        vm.prank(PROJECT);
        directory.proposeCurrent(1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(PROJECT);
        directory.proposeCurrent(2);
        vm.warp(eta + 48 hours);
        vm.expectRevert(ProtocolDirectory.TimelockNotPassed.selector);
        directory.setCurrent();
        vm.prank(PROJECT);
        directory.cancelCurrent();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(ProtocolDirectory.NothingPending.selector);
        directory.setCurrent();
        assertEq(directory.current(), 2);
        assertEq(directory.versions().length, 2);
    }
}
