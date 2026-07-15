// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Engine} from "../src/Engine.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

contract EngineTest is Test {
    uint8 constant FEED_DECIMALS = 8;
    int256 constant WETH_USD_PRICE = 2000e8;

    Engine engine;
    ERC20Mock weth;
    MockV3Aggregator wethFeed;
    address USER = makeAddr("user");

    function setUp() public {
        weth = new ERC20Mock();
        wethFeed = new MockV3Aggregator(FEED_DECIMALS, WETH_USD_PRICE);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        address[] memory feeds = new address[](1);
        feeds[0] = address(wethFeed);
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

    function test_constructor_setsPriceFeedsAndTokens() public view {
        assertEq(engine.getPriceFeed(address(weth)), address(wethFeed));

        address[] memory tokens = engine.getCollateralTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(weth));
    }

    function test_priceFeed_returnsInitialAnswer() public view {
        (, int256 price,,,) = wethFeed.latestRoundData();
        assertEq(price, WETH_USD_PRICE);
        assertEq(wethFeed.decimals(), FEED_DECIMALS);
    }

    function test_priceFeed_updateAnswer() public {
        wethFeed.updateAnswer(1500e8);

        (uint80 roundId, int256 price,,, uint80 answeredInRound) = wethFeed.latestRoundData();
        assertEq(price, 1500e8);
        // updateAnswer 는 라운드를 1 증가시킨다 (생성자에서 1라운드 -> 2)
        assertEq(roundId, 2);
        assertEq(answeredInRound, 2);
    }
}
