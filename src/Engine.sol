// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OZ ReentrancyGuard
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableCoin} from "./StableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract Engine is ReentrancyGuard {
    using OracleLib for AggregatorV3Interface;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_BONUS = 10;

    error Engine__NeedsMoreThanZero();
    error Engine__TokenNotAllowed();
    error Engine__TransferFailed();
    error Engine__BreaksHealthFactor(uint256 healthFactorValue);
    error Engine__MintFailed();
    error Engine__HealthFactorOk();
    error Engine__HealthFactorNotImproved();

    mapping(address user => mapping(address token => uint256 amount)) private s_collateral;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 amount);

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

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function burnDsc(uint256 amount) external moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorBroken(msg.sender); // 이론상 항상 개선되지만 방어적으로 체크
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorBroken(msg.sender); // CEI: 상태변경 먼저, 출금 후 불변식 재확인
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

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
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

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateral[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) revert Engine__HealthFactorOk();

        // 1) 상환할 부채(USD) → 그만큼의 담보 토큰 수량으로 환산
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // 2) 청산 보너스(10%) 추가 지급
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // 3) Effects: user 담보 차감, 청산자(msg.sender)에게 지급
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        // 4) Interactions: 청산자가 DSC로 부채 상환 (청산자가 debtToCover만큼 DSC 보유해야 함)
        _burnDsc(debtToCover, user, msg.sender);

        // 5) 청산 후에도 상태 개선 확인 (design.md 불변식과 연결)
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) revert Engine__HealthFactorNotImproved();
        _revertIfHealthFactorBroken(msg.sender); // 청산자 자신도 안전해야 함
    }

    function _redeemCollateral(address collateral, uint256 amount, address from, address to) internal {
        s_collateral[from][collateral] -= amount;
        emit CollateralRedeemed(from, collateral, amount);
        bool success = IERC20(collateral).transfer(to, amount);
        if (!success) revert Engine__TransferFailed();
    }

    function _burnDsc(uint256 amount, address from, address to) internal {
        s_dscMinted[from] -= amount;
        bool success = i_dsc.transferFrom(to, address(this), amount);
        if (!success) revert Engine__TransferFailed();
        i_dsc.burn(amount);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
}
