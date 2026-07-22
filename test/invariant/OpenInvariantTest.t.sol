pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Engine} from "../../src/Engine.sol";
import {Handler} from "./Handler.t.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

// test/invariant/OpenInvariantTest.t.sol
contract InvariantTest is StdInvariant, Test {
    uint8 constant FEED_DECIMALS = 8;
    int256 constant WETH_USD_PRICE = 2000e8;
    int256 constant WBTC_USD_PRICE = 30000e8;

    Engine engine;
    Handler handler;
    StableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator wethFeed;
    MockV3Aggregator wbtcFeed;

    function setUp() public {
        wethFeed = new MockV3Aggregator(FEED_DECIMALS, WETH_USD_PRICE);
        wbtcFeed = new MockV3Aggregator(FEED_DECIMALS, WBTC_USD_PRICE);
        weth = new ERC20Mock();
        wbtc = new ERC20Mock();
        // 배포 후
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(wbtc);
        address[] memory feeds = new address[](2);
        feeds[0] = address(wethFeed);
        feeds[1] = address(wbtcFeed);

        dsc = new StableCoin();
        engine = new Engine(tokens, feeds, address(dsc));
        handler = new Handler(engine, dsc, weth, wbtc);
        targetContract(address(handler));
    }

    // design.md 맨 위 핵심 불변식을 그대로 코드로
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalDscSupply = dsc.totalSupply();
        uint256 totalWethDeposited = weth.balanceOf(address(engine));
        uint256 totalWbtcDeposited = wbtc.balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(address(weth), totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(address(wbtc), totalWbtcDeposited);

        assert(wethValue + wbtcValue >= totalDscSupply);
    }
}
