// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Keep the desks' transient wiring flags alive until the vault constructor consumes them. Creation
/// bytecode comes from compiled artifacts, so every Base-derived test need not embed and optimize the core.
contract BaseVaultDeployer {
    function deploy(bytes memory caseCode, bytes memory disputeCode, bytes memory vaultCode, address[7] memory cfg)
        external
        returns (address caseDesk, address disputeDesk, address vault)
    {
        caseDesk = _create(caseCode);
        disputeDesk = _create(disputeCode);
        vault = _create(
            abi.encodePacked(
                vaultCode, abi.encode(cfg[0], cfg[1], cfg[2], cfg[3], cfg[4], cfg[5], caseDesk, disputeDesk, cfg[6])
            )
        );
    }

    function _create(bytes memory code) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
            if iszero(deployed) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }
}
