// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Engine} from "../src/Engine.sol";

contract EngineTest is Test {
    Engine engine;
    ERC20Mock weth;
    address USER = makeAddr("user");

    function setUp() public {
        weth = new ERC20Mock();

        // priceFeed 목업 주소 + engine 배포
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        address[] memory feeds = new address[](1);
        feeds[0] = makeAddr("wethPriceFeed");
        engine = new Engine(tokens, feeds);

        weth.mint(USER, 10e18);
    }

    function test_depositCollateral_updatesBalance() public {
        vm.startPrank(USER);
        weth.approve(address(engine), 1e18);
        engine.depositCollateral(address(weth), 1e18);
        vm.stopPrank();

        // 내부 장부에 기록됐는지
        assertEq(engine.getCollateralBalance(USER, address(weth)), 1e18);
        // 토큰이 실제로 engine으로 옮겨졌는지
        assertEq(weth.balanceOf(address(engine)), 1e18);
        assertEq(weth.balanceOf(USER), 9e18);
    }

    function test_depositCollateral_emitsEvent() public {
        vm.startPrank(USER);
        weth.approve(address(engine), 1e18);

        vm.expectEmit(true, true, false, true, address(engine));
        emit Engine.CollateralDeposited(USER, address(weth), 1e18);
        engine.depositCollateral(address(weth), 1e18);

        vm.stopPrank();
    }

    function test_depositCollateral_accumulates() public {
        vm.startPrank(USER);
        weth.approve(address(engine), 3e18);
        engine.depositCollateral(address(weth), 1e18);
        engine.depositCollateral(address(weth), 2e18);
        vm.stopPrank();

        assertEq(engine.getCollateralBalance(USER, address(weth)), 3e18);
    }

    function test_deposit_revertsIfZero() public {
        vm.prank(USER);
        vm.expectRevert(Engine.Engine__NeedsMoreThanZero.selector);
        engine.depositCollateral(address(weth), 0);
    }

    function test_deposit_revertsIfTokenNotAllowed() public {
        // priceFeed가 등록되지 않은 토큰
        ERC20Mock randomToken = new ERC20Mock();
        randomToken.mint(USER, 10e18);

        vm.startPrank(USER);
        randomToken.approve(address(engine), 1e18);
        vm.expectRevert(Engine.Engine__TokenNotAllowed.selector);
        engine.depositCollateral(address(randomToken), 1e18);
        vm.stopPrank();

        assertEq(engine.getCollateralBalance(USER, address(randomToken)), 0);
    }

    function test_deposit_revertsIfNotApproved() public {
        // approve 없이 예치 시도 → transferFrom 실패
        vm.prank(USER);
        vm.expectRevert();
        engine.depositCollateral(address(weth), 1e18);
    }

    function test_constructor_setsPriceFeedsAndTokens() public {
        assertEq(engine.getPriceFeed(address(weth)), makeAddr("wethPriceFeed"));

        address[] memory tokens = engine.getCollateralTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(weth));
    }
}
