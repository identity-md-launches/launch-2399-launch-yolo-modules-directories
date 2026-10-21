// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchPlan, LocalFactory} from "../script/LaunchPlan.sol";
import {YoloSweetener} from "../src/YoloSweetener.sol";
import {TrophyCatalog} from "../src/TrophyCatalog.sol";
import {DareTrophy} from "../src/DareTrophy.sol";
import {ProtocolDirectory} from "../src/ProtocolDirectory.sol";
import {HiddenList} from "../src/HiddenList.sol";
import {YoloPredict} from "../src/YoloPredict.sol";

/// @dev Launch 3 (extras) with no code at the vault address, like an evm_contracts check on a bare chain: one
///      factory call deploys the six contracts with CREATE2, in order, with the launch's constructor arguments.
///      Standalone on purpose: no setUp and no code anywhere but what the test deploys.
contract ExtrasBareChainTest is Test {
    address constant SAFE = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant DELEGATE = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant VAULT = 0x88c3B0B64e6869C424DAF25ad8eD635180832493; // no code on a bare chain
    uint64 constant CORE_BLOCK = 26_241_860;
    uint64 constant N = 4_000_000_903;

    function _launch() internal returns (address[] memory out) {
        LocalFactory f = new LocalFactory();
        (bytes[] memory codes,, address[] memory addrs) = LaunchPlan.extras(f, N, VAULT, SAFE, CORE_BLOCK);
        out = f.launchContracts(N, codes);
        assertEq(out.length, 6);
        for (uint256 i; i < 6; ++i) {
            assertEq(out[i], addrs[i], "the predicted address");
            assertGt(out[i].code.length, 0, "deployed");
        }
    }

    /// All six deploy in one transaction; the vault reads are skipped and the three modules hold zero addresses.
    function test_BareChain_NoVaultCode_AllSixDeploy() public {
        assertEq(VAULT.code.length, 0, "bare chain");
        address[] memory a = _launch();

        YoloSweetener sw = YoloSweetener(a[0]);
        assertEq(address(sw.vault()), VAULT);
        assertEq(address(sw.registry()), address(0));
        assertEq(address(sw.yolo()), address(0));

        assertEq(TrophyCatalog(a[1]).owner(), SAFE);

        DareTrophy dt = DareTrophy(a[2]);
        assertEq(address(dt.vault()), VAULT);
        assertEq(address(dt.catalog()), a[1]);
        assertEq(address(dt.caseDesk()), address(0));
        assertEq(address(dt.textRules()), address(0));
        assertEq(address(dt.yolo()), address(0));

        ProtocolDirectory pd = ProtocolDirectory(a[3]);
        assertEq(pd.safe(), SAFE);
        assertEq(pd.versionCount(), 1);
        assertEq(pd.current(), 1);
        ProtocolDirectory.Version memory v = pd.version(1);
        assertEq(v.vault, VAULT);
        assertEq(v.sweetener, a[0]);
        assertEq(v.trophy, a[2]);
        assertEq(v.fromBlock, CORE_BLOCK);
        assertEq(v.label, "v1");

        HiddenList hl = HiddenList(a[4]);
        assertEq(hl.owner(), SAFE);
        assertEq(hl.nft(), NFT);
        assertEq(hl.delegateRegistry(), DELEGATE);

        YoloPredict yp = YoloPredict(a[5]);
        assertEq(address(yp.vault()), VAULT);
        assertEq(address(yp.yolo()), address(0));
        assertEq(yp.minPosition(), LaunchPlan.PREDICT_MIN_POSITION);
    }

    /// Without the vault's code the modules take no deposit, mint or position, and later versions keep the code check.
    function test_BareChain_NoVaultCode_ModulesInert() public {
        address[] memory a = _launch();
        vm.expectRevert();
        YoloSweetener(a[0]).sweeten(1, 1e18);
        vm.expectRevert();
        DareTrophy(a[2]).mint(1, "x");
        vm.expectRevert();
        YoloPredict(a[5]).predict(1, true, 1e18);

        ProtocolDirectory pd = ProtocolDirectory(a[3]);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.NoCode.selector, address(0xC0FFEE)));
        pd.proposeVersion(ProtocolDirectory.Version(address(0xC0FFEE), address(0), address(0), 1, 0, "v2"));
    }
}
