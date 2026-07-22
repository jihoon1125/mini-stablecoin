pragma solidity ^0.8.20;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Engine} from "../../src/Engine.sol";

contract ReentrantWethMock is ERC20Mock {
    address public engineAddress;
    uint256 public attackAmount;

    function setEngine(address _engine, uint256 _amount) external {
        engineAddress = _engine;
        attackAmount = _amount;
    }

    // transferFrom 도중 콜백처럼 동작하게 오버라이드해서 재진입 시도
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (engineAddress != address(0)) {
            Engine(engineAddress).depositCollateral(address(this), attackAmount); // 재진입 시도
        }
        return super.transferFrom(from, to, amount);
    }
}
