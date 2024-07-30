// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "src/core/interfaces/IVaultUtils.sol";

// This interface has many new methods out of src/core/interfaces/IVault.sol
interface IVaultExtended {
    function setMaxGlobalShortSize(address _token, uint256 _amount) external;

    function setVaultUtils(IVaultUtils _vaultUtils) external;
}