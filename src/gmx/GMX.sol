// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "src/tokens/MintableBaseToken.sol";

// https://arbiscan.io/address/0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a
contract GMX is MintableBaseToken {
    constructor() public MintableBaseToken("GMX", "GMX", 0) {
    }

    function id() external pure returns (string memory _name) {
        return "GMX";
    }
}