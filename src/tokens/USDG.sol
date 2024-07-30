// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "src/tokens/YieldToken.sol";
import "src/tokens/interfaces/IUSDG.sol";

// https://arbiscan.io/address/0x45096e7aA921f27590f8F19e457794EB09678141
contract USDG is YieldToken, IUSDG {

    mapping(address => bool) public vaults;

    modifier onlyVault() {
        require(vaults[msg.sender], "USDG: forbidden");
        _;
    }

    constructor(address _vault) public YieldToken("USD Gambit", "USDG", 0) {
        vaults[_vault] = true;
    }

    function addVault(address _vault) external override onlyGov {
        vaults[_vault] = true;
    }

    function removeVault(address _vault) external override onlyGov {
        vaults[_vault] = false;
    }

    function mint(address _account, uint256 _amount) external override onlyVault {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external override onlyVault {
        _burn(_account, _amount);
    }
}