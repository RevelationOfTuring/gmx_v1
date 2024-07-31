// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "src/tokens/YieldToken.sol";
import "src/tokens/interfaces/IUSDG.sol";

// https://arbiscan.io/address/0x45096e7aA921f27590f8F19e457794EB09678141
contract USDG is YieldToken, IUSDG {
    // gov是Timelock合约，地址为0xF3Cf3D73E00D3149BA25c55951617151C67b2350

    // 具有vault权限的名单
    // 该权限为可mint和burn其他地址的USDG
    // 注：目前具有vault权限的地址有：Vault、GlpManager
    mapping(address => bool) public vaults;

    // 修饰只有具有mint和burn其他地址USDG权限地址可以调用的函数
    modifier onlyVault() {
        require(vaults[msg.sender], "USDG: forbidden");
        _;
    }

    // name: "USD Gambit"
    // symbol："USDG"
    // 初始初始发行量：0
    constructor(address _vault) public YieldToken("USD Gambit", "USDG", 0) {
        // _vault具有vault权限
        vaults[_vault] = true;
    }

    // gov添加vault权限给地址_vault
    function addVault(address _vault) external override onlyGov {
        vaults[_vault] = true;
    }

    // gov移除_vault地址的vault权限
    function removeVault(address _vault) external override onlyGov {
        vaults[_vault] = false;
    }

    // 具有vault权限的地址为_account地址增发数量为_amount的USDG
    function mint(address _account, uint256 _amount) external override onlyVault {
        _mint(_account, _amount);
    }

    // 具有vault权限的地址为_account地址销毁数量为_amount的USDG
    function burn(address _account, uint256 _amount) external override onlyVault {
        _burn(_account, _amount);
    }
}