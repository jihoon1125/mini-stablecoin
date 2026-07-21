// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Engine} from "../src/Engine.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {StableCoin} from "../src/StableCoin.sol";

contract Demo is Script {
    // anvil 고정 테스트 키 (0번, 1번)
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant LIQUIDATOR_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    function run() external {
        address user = vm.addr(DEPLOYER_KEY); // 키에서 주소 뽑기
        address liquidator = vm.addr(LIQUIDATOR_KEY);

        // ========== 1. 배포 (setUp을 broadcast로) ==========
        vm.startBroadcast(DEPLOYER_KEY);

        ERC20Mock weth = new ERC20Mock();
        MockV3Aggregator wethFeed = new MockV3Aggregator(8, 2000e8);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        address[] memory feeds = new address[](1);
        feeds[0] = address(wethFeed);

        StableCoin dsc = new StableCoin();
        Engine engine = new Engine(tokens, feeds, address(dsc));
        dsc.transferOwnership(address(engine));

        // 두 사람한테 담보용 WETH 지급
        weth.mint(user, 10e18);
        weth.mint(liquidator, 10e18);
        vm.stopBroadcast();

        console.log("***Deploy completed***");
        console.log("Engine:", address(engine));
        console.log("DSC   :", address(dsc));

        // ========== 2. USER 예치 + 발행 ==========
        vm.startBroadcast(DEPLOYER_KEY);
        weth.approve(address(engine), 0.1 ether);
        engine.depositCollateral(address(weth), 0.1 ether); // $200
        engine.mintDsc(70 ether); // $70
        vm.stopBroadcast();

        console.log("\n=== Collateral+Mint ===");
        console.log("USER COLLATERAL(WETH):", engine.getCollateralBalance(user, address(weth)));
        console.log("USER HF        :", engine.getHealthFactor(user));

        // ========== 3. 가격 폭락 ==========
        vm.startBroadcast(DEPLOYER_KEY);
        wethFeed.updateAnswer(1000e8); // $2000 -> $1000
        vm.stopBroadcast();

        console.log("\n=== $2000 -> $1000 ===");
        console.log("USER HF:", engine.getHealthFactor(user)); // 1 밑으로 떨어짐

        // ========== 4. LIQUIDATOR 청산 ==========
        vm.startBroadcast(LIQUIDATOR_KEY);
        weth.approve(address(engine), 0.2 ether);
        engine.depositCollateral(address(weth), 0.2 ether);
        engine.mintDsc(70 ether);
        dsc.approve(address(engine), 70 ether);
        engine.liquidate(address(weth), user, 70 ether);
        vm.stopBroadcast();

        (uint256 userDebt,) = engine.getAccountInformation(user);
        console.log("\n=== After Liquidation ===");
        console.log("USER debt:", userDebt); // 0
        console.log("USER HF  :", engine.getHealthFactor(user));
    }
}
