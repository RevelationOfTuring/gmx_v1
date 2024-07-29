// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "src/core/interfaces/IVault.sol";
import "src/access/Governable.sol";

// https://arbiscan.io/address/0xE56D2e4C685e67C866c292b583bE732068afd93a
contract VaultErrorController is Governable {
    function setErrors(IVault _vault, string[] calldata _errors) external onlyGov {
        for (uint256 i = 0; i < _errors.length; i++) {
            _vault.setError(i, _errors[i]);
        }
    }
}