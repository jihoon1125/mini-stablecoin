// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OZ ReentrancyGuard
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableCoin} from "./StableCoin.sol";

contract Engine is ReentrancyGuard {
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    error Engine__NeedsMoreThanZero();
    error Engine__TokenNotAllowed();
    error Engine__TransferFailed();
    error Engine__BreaksHealthFactor(uint256 healthFactorValue);
    error Engine__MintFailed();

    mapping(address user => mapping(address token => uint256 amount)) private s_collateral;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    address[] private s_collateralTokens;
    StableCoin private immutable i_dsc;

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert Engine__NeedsMoreThanZero();
        }
        _;
    }
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert Engine__TokenNotAllowed();
        }
        _;
    }

    constructor(address[] memory tokens, address[] memory feeds, address stableCoin) {
        if (tokens.length != feeds.length) {
            revert Engine__NeedsMoreThanZero();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            s_priceFeeds[tokens[i]] = feeds[i];
            s_collateralTokens.push(tokens[i]);
        }

        i_dsc = StableCoin(stableCoin);
    }

    function depositCollateral(address token, uint256 amount)
        external
        moreThanZero(amount)
        isAllowedToken(token)
        nonReentrant
    {
        s_collateral[msg.sender][token] += amount;
        emit CollateralDeposited(msg.sender, token, amount);

        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert Engine__TransferFailed();
        }
    }

    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert Engine__MintFailed();
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) return type(uint256).max; // 부채 없음 = HF 무한대 (design.md §3)
        uint256 adjustedCollateral = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (adjustedCollateral * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorBroken(address user) internal view {
        uint256 hf = _healthFactor(user);
        if (hf < MIN_HEALTH_FACTOR) revert Engine__BreaksHealthFactor(hf);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user); // 임시: 하드코딩 2000 USD/ETH
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        // 화요일 전까지: WETH 잔고 * 2000e18 (오라클 없이 임시)
        // Week 3부터 getUsdValue(token, amount)로 교체
    }

    function getCollateralBalance(address user, address token) external view returns (uint256) {
        return s_collateral[user][token];
    }

    function getPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }
}
