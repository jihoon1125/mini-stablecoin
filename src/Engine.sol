// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OZ ReentrancyGuard
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Engine is ReentrancyGuard {
    error Engine__NeedsMoreThanZero();
    error Engine__TokenNotAllowed();
    error Engine__TransferFailed();

    mapping(address user => mapping(address token => uint256 amount)) private s_collateral;
    mapping(address token => address priceFeed) private s_priceFeeds;
    address[] private s_collateralTokens;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

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

    constructor(
        address[] memory tokens,
        address[] memory feeds /*, address stableCoin */
    ) {
        if (tokens.length != feeds.length) {
            revert Engine__NeedsMoreThanZero();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            s_priceFeeds[tokens[i]] = feeds[i];
            s_collateralTokens.push(tokens[i]);
        }
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
}
