// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Mintable ERC-20 for testnet deployments and tests. Do not deploy to mainnet.
contract MockERC20 is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_, address owner)
        ERC20(name, symbol)
        Ownable(owner)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
