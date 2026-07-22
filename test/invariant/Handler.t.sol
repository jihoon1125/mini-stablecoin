pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Engine} from "../../src/Engine.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// test/invariant/Handler.t.sol — 랜덤 시퀀스로 부를 함수들을 감싼 핸들러
contract Handler is Test {
    Engine engine;
    StableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;

    constructor(Engine _engine, StableCoin _dsc, ERC20Mock _weth, ERC20Mock _wbtc) {
        engine = _engine;
        dsc = _dsc;
        weth = _weth;
        wbtc = _wbtc;
    }

    function _pickCollateralToken(uint256 seed) internal view returns (ERC20Mock) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountSeed) public {
        // seed로 담보 종류·수량을 랜덤화해서 engine.depositCollateral 호출
        ERC20Mock token = _pickCollateralToken(collateralSeed);
        uint256 amount = bound(amountSeed, 1, type(uint96).max); // 1~255 사이 랜덤 수량

        vm.startPrank(msg.sender);
        token.mint(msg.sender, amount);
        token.approve(address(engine), amount);
        engine.depositCollateral(address(token), amount);
        vm.stopPrank();
    }

    function mintDsc(uint256 amountSeed) public {
        // HF를 안 깨는 범위 내에서 랜덤 발행 시도
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        int256 maxDscToMint = int256(collateralValueInUsd / 2) - int256(totalDscMinted); // HF 2.0 기준
        if (maxDscToMint <= 0) return; // 발행 불가
        uint256 amountToMint = uint256(bound(amountSeed, 1, uint256(maxDscToMint)));

        vm.prank(msg.sender);
        engine.mintDsc(amountToMint);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountSeed) public {
        // HF를 안 깨는 범위 내에서 랜덤 출금 시도
        ERC20Mock token = _pickCollateralToken(collateralSeed);
        uint256 tokenBalance = engine.getCollateralBalance(msg.sender, address(token));
        if (tokenBalance == 0) return;

        (uint256 dscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);

        // HF >= 1 유지하려면 담보 USD >= 부채 * 2 여야 함 (청산임계값 50% → 100/50 = 2)
        uint256 minCollateralUsd = dscMinted * 2;
        if (collateralValueInUsd <= minCollateralUsd) return; // 뺄 여유 자체가 없음

        // 뺄 수 있는 USD 버퍼 → 이 토큰 수량으로 환산
        uint256 redeemableUsd = collateralValueInUsd - minCollateralUsd;
        uint256 maxRedeemInToken = engine.getTokenAmountFromUsd(address(token), redeemableUsd);

        // "HF 버퍼"와 "이 토큰 실제 잔고" 중 작은 값이 진짜 상한
        uint256 maxRedeem = maxRedeemInToken < tokenBalance ? maxRedeemInToken : tokenBalance;
        uint256 amount = bound(amountSeed, 0, maxRedeem);
        if (amount == 0) return;

        vm.prank(msg.sender);
        engine.redeemCollateral(address(token), amount);
    }
}
