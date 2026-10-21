// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {LaunchPlan} from "../../script/LaunchPlan.sol";
import {IProjectFactory, LaunchGasMeter} from "./LaunchRehearsal.fork.t.sol";
import {TaskVault} from "../../src/TaskVault.sol";
import {ParamsRegistry} from "../../src/ParamsRegistry.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {TrophyCatalog} from "../../src/TrophyCatalog.sol";
import {DareTrophy} from "../../src/DareTrophy.sol";
import {ProtocolDirectory} from "../../src/ProtocolDirectory.sol";
import {HiddenList} from "../../src/HiddenList.sol";
import {YoloPredict} from "../../src/YoloPredict.sol";
import {UnknownFunction} from "../../src/VaultTypes.sol";

/// @dev Launch 3 (extras) through the live ProjectFactory against the live TaskVault of the core launch: every
///      address the modules read in their constructors comes from that vault, and every vault function they call
///      exists there. Skipped unless FORK_URL is set:
///        FORK_URL=<mainnet RPC> forge test --match-contract ExtrasOnLiveCore -vv
contract ExtrasOnLiveCoreForkTest is Test {
    IProjectFactory constant FACTORY = IProjectFactory(0xfF03410d0Fe5fa8f7F59F743de35E333D9857120);
    TaskVault constant VAULT = TaskVault(payable(0x88c3B0B64e6869C424DAF25ad8eD635180832493));
    address constant SAFE = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant DELEGATE = 0x00000000000000447e69651d841bD8D104Bed493;
    uint64 constant CORE_BLOCK = 26_241_860;
    uint64 constant N = 4_000_000_903;
    uint256 constant CAP = 16_777_216;

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        assertGt(block.number, CORE_BLOCK, "the fork is after the core launch");
        assertGt(address(VAULT).code.length, 0, "the core vault is live");
        vm.etch(FACTORY.deployer(), type(LaunchGasMeter).runtimeCode);
    }

    function _launch() internal returns (address[] memory a, uint256 used) {
        (bytes[] memory codes, bytes32[] memory names, address[] memory addrs) =
            LaunchPlan.extras(FACTORY, N, address(VAULT), SAFE, CORE_BLOCK);
        IProjectFactory.ContractsParams memory p;
        p.launchNumber = N;
        p.contractCreationCodes = codes;
        p.contractNames = names;
        p.expectedContracts = addrs;
        p.record.kind = "evm_contracts";
        p.record.launchNumber = N;
        p.record.sourceRepoUrl = "https://github.com/example/moneycanbuy";
        bool ok;
        bytes memory ret;
        (ok, used, ret) = LaunchGasMeter(FACTORY.deployer())
            .run(address(FACTORY), abi.encodeCall(IProjectFactory.launchContracts, (p)));
        assertTrue(ok, "the launch transaction");
        a = abi.decode(ret, (address[]));
        assertEq(a.length, 6);
        for (uint256 i; i < 6; ++i) {
            assertEq(a[i], addrs[i], "the predicted address");
        }
    }

    function test_Fork_ExtrasReadTheLiveVault() public {
        (address[] memory a, uint256 used) = _launch();
        emit log_named_uint("extras launch execution gas", used);
        assertLt(used, CAP);

        YoloSweetener sw = YoloSweetener(a[0]);
        assertEq(address(sw.vault()), address(VAULT));
        assertEq(address(sw.registry()), VAULT.registry());
        assertEq(address(sw.yolo()), address(VAULT.yolo()));

        TrophyCatalog tc = TrophyCatalog(a[1]);
        assertEq(tc.owner(), SAFE);

        DareTrophy dt = DareTrophy(a[2]);
        assertEq(address(dt.vault()), address(VAULT));
        assertEq(address(dt.catalog()), a[1]);
        assertEq(address(dt.caseDesk()), VAULT.caseDesk());
        assertEq(address(dt.textRules()), address(VAULT.textRules()));
        assertEq(address(dt.yolo()), address(VAULT.yolo()));

        ProtocolDirectory pd = ProtocolDirectory(a[3]);
        assertEq(pd.safe(), SAFE);
        assertEq(pd.versionCount(), 1);
        assertEq(pd.current(), 1);
        ProtocolDirectory.Version memory v = pd.version(1);
        assertEq(v.vault, address(VAULT));
        assertEq(v.sweetener, a[0]);
        assertEq(v.trophy, a[2]);
        assertEq(v.fromBlock, CORE_BLOCK);
        assertEq(v.label, "v1");

        HiddenList hl = HiddenList(a[4]);
        assertEq(hl.owner(), SAFE);
        assertEq(hl.nft(), NFT);
        assertEq(hl.delegateRegistry(), DELEGATE);

        YoloPredict yp = YoloPredict(a[5]);
        assertEq(address(yp.vault()), address(VAULT));
        assertEq(address(yp.yolo()), address(VAULT.yolo()));
        assertEq(yp.minPosition(), LaunchPlan.PREDICT_MIN_POSITION);

        // none of these is zero on the live vault
        assertTrue(VAULT.registry() != address(0) && address(VAULT.yolo()) != address(0));
        assertTrue(VAULT.caseDesk() != address(0) && address(VAULT.textRules()) != address(0));
        assertTrue(address(VAULT.imd()) != address(0) && address(VAULT.usdc()) != address(0));

        // the registry owner binds the sweetener once
        assertEq(VAULT.sweetener(), address(0), "not bound yet");
        vm.prank(ParamsRegistry(VAULT.registry()).owner());
        VAULT.bindSweetener(a[0]);
        assertEq(VAULT.sweetener(), a[0]);
    }

    /// Every vault function the modules call is answered by the live vault (directly or forwarded to a desk), not
    /// refused as an unknown function.
    function test_Fork_LiveVaultAnswersTheModuleInterface() public {
        bytes[] memory calls = new bytes[](15);
        calls[0] = abi.encodeWithSignature("submitTerms(uint256,address)", 1, address(1));
        calls[1] = abi.encodeWithSignature("getTask(uint256)", 1);
        calls[2] = abi.encodeWithSignature("getSubmission(uint256)", 1);
        calls[3] = abi.encodeWithSignature("getSettlement(uint256)", 1);
        calls[4] = abi.encodeWithSignature("getDispute(uint256)", 1);
        calls[5] = abi.encodeWithSignature("votesOf(uint256,address)", 1, address(1));
        calls[6] = abi.encodeWithSignature("registry()");
        calls[7] = abi.encodeWithSignature("yolo()");
        calls[8] = abi.encodeWithSignature("sweetener()");
        calls[9] = abi.encodeWithSignature("burner()");
        calls[10] = abi.encodeWithSignature("caseDesk()");
        calls[11] = abi.encodeWithSignature("textRules()");
        calls[12] = abi.encodeWithSignature("imd()");
        calls[13] = abi.encodeWithSignature("usdc()");
        calls[14] = abi.encodeWithSignature("poke(uint256)", 1);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(VAULT).call(calls[i]);
            emit log_named_bytes("call", calls[i]);
            emit log_named_string("answer", ok ? "returned" : "reverted");
            if (ok) {
                if (i != 14) assertGt(ret.length, 0, "returned data"); // poke returns nothing
            } else {
                assertGe(ret.length, 4, "a named revert, not an empty one");
                assertTrue(bytes4(ret) != UnknownFunction.selector, "a known function");
                emit log_named_bytes("revert", ret);
            }
        }
    }
}
