// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract aWETH is ERC20 {
    
    uint8 constant _decimals = 18;
    uint256 constant _totalSupply = 1 * (10**6) * 10**_decimals;  // 1m tokens for distribution 

    constructor() ERC20("Mocked Aave interest bearing WETH", "aWETH") {        
        _mint(msg.sender, _totalSupply);
    }
}
