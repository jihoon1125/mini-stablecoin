// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StableCoin is ERC20Burnable, Ownable {
    error StableCoin__MustBeMoreThanZero();
    error StableCoin__MintToZeroAddress();

    // OZ v5: Ownable(initialOwner) 생성자 인자 주의
    constructor() ERC20("MiniUSD", "mUSD") Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        if (to == address(0)) {
            revert StableCoin__MintToZeroAddress();
        }
        if (amount == 0) {
            revert StableCoin__MustBeMoreThanZero();
        }

        _mint(to, amount);
        return true;
    }

    function burn(uint256 amount) public override {
        if (amount == 0) {
            revert StableCoin__MustBeMoreThanZero();
        }
        super.burn(amount);
    }
}
