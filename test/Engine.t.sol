// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Engine} from "../src/Engine.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {StableCoin} from "../src/StableCoin.sol";

contract EngineTest is Test {
    uint8 constant FEED_DECIMALS = 8;
    int256 constant WETH_USD_PRICE = 2000e8;
    uint256 public constant COLLATERAL_AMOUNT = 0.1 ether; // $200 (design.md 경계 예시)
    uint256 public constant TOO_MUCH_DSC = 150 ether; // $150 (HF 0.9)
    uint256 public constant SAFE_DSC_AMOUNT = 50 ether; // $50 (HF 2.0)
    uint256 public constant CLIQ_COLLATERAL = COLLATERAL_AMOUNT * 2;

    Engine engine;
    ERC20Mock weth;
    MockV3Aggregator wethFeed;
    StableCoin dsc;
    address USER = makeAddr("user");
    address LIQUIDATOR = makeAddr("liquidator");

    function setUp() public {
        weth = new ERC20Mock();
        wethFeed = new MockV3Aggregator(FEED_DECIMALS, WETH_USD_PRICE);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        address[] memory feeds = new address[](1);
        feeds[0] = address(wethFeed);
        dsc = new StableCoin();
        engine = new Engine(tokens, feeds, address(dsc));
        dsc.transferOwnership(address(engine));

        weth.mint(USER, 10e18);
        weth.mint(LIQUIDATOR, 10e18);
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

    function test_mint_revertsIfHealthFactorBroken() public {
        vm.startPrank(USER);
        weth.approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(address(weth), COLLATERAL_AMOUNT);
        // HF = adjusted담보($100) * 1e18 / 부채($150) = 2/3 * 1e18 (정수나눗셈 내림)
        uint256 expectedHf = uint256(100e18) * 1e18 / 150e18; // = 666666666666666666
        vm.expectRevert(abi.encodeWithSelector(Engine.Engine__BreaksHealthFactor.selector, expectedHf));

        engine.mintDsc(TOO_MUCH_DSC);
        vm.stopPrank();
    }

    function test_mint_succeedsAtExactBoundary() public {
        // 담보 $200, 부채 $100 → HF 정확히 1.0 → 통과해야 함 (design.md 표 "경계" 케이스)
        vm.startPrank(USER);
        weth.approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(address(weth), COLLATERAL_AMOUNT);

        engine.mintDsc(100 ether); // $100
        vm.stopPrank();
    }

    function test_mint_succeedsWithSafeMargin() public {
        // 담보 $200, 부채 $50 → HF 2.0 → 안전
        vm.startPrank(USER);
        weth.approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(address(weth), COLLATERAL_AMOUNT);

        engine.mintDsc(50 ether); // $50
        vm.stopPrank();
    }

    function test_fullLifecycle() public {
        vm.startPrank(USER);
        weth.approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(address(weth), COLLATERAL_AMOUNT);
        engine.mintDsc(SAFE_DSC_AMOUNT);

        // 불변식 체크: 담보 USD 가치 > 발행된 DSC USD 가치
        (uint256 minted, uint256 collateralUsd) = engine.getAccountInformation(USER);
        assertGt(collateralUsd, minted);

        dsc.approve(address(engine), SAFE_DSC_AMOUNT);
        engine.burnDsc(SAFE_DSC_AMOUNT);
        engine.redeemCollateral(address(weth), COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertEq(engine.getCollateralBalance(USER, address(weth)), 0);
    }

    function test_healthFactor_dropsWhenPriceDrops() public {
        vm.startPrank(USER);
        weth.approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(address(weth), COLLATERAL_AMOUNT); // $200
        engine.mintDsc(SAFE_DSC_AMOUNT); // $50, HF=2.0
        vm.stopPrank();

        int256 crashedPrice = 1000e8; // $2000 → $1000, ETH 반토막
        wethFeed.updateAnswer(crashedPrice);

        // 담보 가치 $200 → $100, HF = (100*0.5)/50 = 1.0 → 경계
        uint256 hf = engine.getHealthFactor(USER); // Engine에 public getter 하나 필요(아래 참고)
        assertEq(hf, 1e18);
    }

    function test_liquidate_improvesHealthFactor() public {
        // 1) USER: 담보 $200 예치, $100 발행 (HF=1.0, 경계)
        vm.startPrank(USER);
        weth.approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(address(weth), COLLATERAL_AMOUNT);
        engine.mintDsc(70 ether);
        vm.stopPrank();

        // 2) 가격 폭락 → HF < 1.0
        wethFeed.updateAnswer(1000e8); // $2000 → $1000

        // 3) LIQUIDATOR가 청산 실행
        vm.startPrank(LIQUIDATOR);
        weth.approve(address(engine), CLIQ_COLLATERAL);
        engine.depositCollateral(address(weth), CLIQ_COLLATERAL);
        engine.mintDsc(70 ether);
        dsc.approve(address(engine), 70 ether); // 청산 시 대납할 DSC
        engine.liquidate(address(weth), USER, 70 ether);
        vm.stopPrank();

        // 4) 검증: USER 부채 감소, LIQUIDATOR 담보 증가(보너스 포함)
        (uint256 userDebt,) = engine.getAccountInformation(USER);
        assertEq(userDebt, 0);
    }

    function test_liquidate_revertsIfHealthFactorOk() public {
        // 건강한 유저(HF≥1.0)를 청산 시도 → Engine__HealthFactorOk revert
        vm.startPrank(USER);
        weth.approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(address(weth), COLLATERAL_AMOUNT);
        engine.mintDsc(100 ether);
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        weth.approve(address(engine), CLIQ_COLLATERAL);
        engine.depositCollateral(address(weth), CLIQ_COLLATERAL);
        engine.mintDsc(100 ether);
        dsc.approve(address(engine), 100 ether); // 청산 시 대납할 DSC
        vm.expectRevert(Engine.Engine__HealthFactorOk.selector);
        engine.liquidate(address(weth), USER, 100 ether);
        vm.stopPrank();
    }
}
