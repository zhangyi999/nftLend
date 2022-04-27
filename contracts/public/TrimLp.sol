// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

import '../utils/SafeToken.sol';

import '../interface/IPair.sol';

import "hardhat/console.sol";

import "./Assets.sol";

// 不需要 router 合约，直接 操作 pair

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract TrimLP is ReentrancyGuard {

    using SafeToken for address;

    uint256 MAX = (1 << 256) - 1;

    // 0.01%
    uint256 public constant EPX = 10000; 
    bytes emptyData = bytes("");

    AssetCustody public assetCustody;
    
    // 工厂
    address public factory;
    // 多余 一半多余的余额 防止影响下一次 组lp
    address public back;

    // 
    address public mik;
    // TrimLP
    constructor(address _factory, address _mik) {
        factory = _factory;
        back = msg.sender;
        assetCustody = new AssetCustody(address(this));
        mik = _mik;
    }

    function getReserves(address _lp) external view returns(uint256 reserves0, uint256 reserves1) {
        (reserves0,reserves1,) = IPair(_lp).getReserves();
    }

    function getPair(address token0, address token1) external view returns (address pair) {
        pair = IFactory(factory).getPair(token0, token1);
    }

    // /// @dev Compute optimal deposit amount
    // /// @param amtA amount of token A desired to deposit
    // /// @param amtB amonut of token B desired to deposit
    // /// @param resA amount of token A in reserve
    // /// @param resB amount of token B in reserve
    // function optimalDeposit(
    //     uint256 amtA,
    //     uint256 amtB,
    //     uint256 resA,
    //     uint256 resB
    // ) internal pure returns (uint256 token0Amount, uint256 token1Amount) {
    //     token0Amount = amtA;
    //     token1Amount = amtB;
    //     if (amtA * resB < amtB * resA) {
    //         token1Amount = amtA * resB / resA;
    //     } else {
    //         token0Amount = amtB * resA / resB;
    //     }
    // }

    /// @dev Compute optimal deposit amount helper
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amonut of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    function _optimalDepositA(
        uint256 amtA,
        uint256 amtB,
        uint256 resA,
        uint256 resB,
        uint256 feeEPX
    ) internal pure returns (uint256) {
        require(amtA * resB >= amtB * resA, "Reversed");
        uint256 a = feeEPX;
        uint256 b = (EPX + feeEPX) * resA;
        uint256 _c = amtA * resB - amtB * resA;
        uint256 c = _c * EPX  * resA / (amtB + resB);

        uint256 d = 4 * a * c;
        uint256 e = sqrt(b ** 2 + d);
        uint256 numerator = e - b;
        uint256 denominator = 2*a;
        return numerator / denominator;
    }

    /// @dev Compute optimal deposit amount
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amonut of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    function optimalDeposit(
        uint256 amtA,
        uint256 amtB,
        uint256 resA,
        uint256 resB,
        uint256 feeEPX
    ) internal pure returns (uint256 swapAmt, bool isReversed) {
        if (amtA * resB >= amtB * resA) {
            swapAmt = _optimalDepositA(amtA, amtB, resA, resB, feeEPX);
            isReversed = false;
        } else {
            swapAmt = _optimalDepositA(amtB, amtA, resB, resA, feeEPX);
            isReversed = true;
        }
    }

    function tokens(address lp) public view returns(address t0, address t1) {
        t0 = IPair(lp).token0();
        t1 = IPair(lp).token1();
    }

    function skim(address token, address to) public {
        uint balance = token.myBalance();
        if ( balance > 0 ) token.safeTransfer(to, balance);
    }

    // 配平 lp
    /// @dev Execute worker strategy. Take LP tokens + debtToken. Return LP tokens.
    /// feeEPX 不一致 在某些情况下 不会报错, feeEPX 9975
    function _mint(address token0, address token1, address lp, address to) internal returns(uint256 moreLPAmount) {
        token0.safeTransfer(lp, token0.myBalance());
        token1.safeTransfer(lp, token1.myBalance());
        // 这里没有退币
        // 只有价格变动
        moreLPAmount = IPair(lp).mint(to);

        // 多余退币 
        // if(token0.myBalance() > 0){
        //     token0.safeTransfer(back, token0.myBalance());
        // }
        // if(token1.myBalance() > 0){
        //     token1.safeTransfer(back, token1.myBalance());
        // }
    }

    // tokenOrigin swap token0
    // token0 half swap token1
    // addLiquidity token0 and token1
    function getLP(
        address tokenOrigin , 
        address token0,
        address token1,
        uint token0Amount,
        uint token1Amount,
        uint minLPAmount,
        uint256 feeEPX,
        address to
    ) external nonReentrant returns(uint moreLPAmount) {
        require(token0 != mik,'token0 can not be mik');
        
        // 清空
        skim(token0, back);
        skim(token1, back);

        // 购买 meer
        address lp = IFactory(factory).getPair(tokenOrigin, token0);
        tokenOrigin.safeTransferFrom(msg.sender, lp, token0Amount);
        _swap(lp,tokenOrigin, token0Amount, address(this), feeEPX);
        token0Amount = token0.balanceOf(address(this));
        
        // 配平
        lp = IFactory(factory).getPair(token0, token1);
        (uint _token0Amount, uint _token1Amount) = token0 < token1 ? (token0Amount, token1Amount) : (token1Amount, token0Amount);
        calcAndTransfer(lp, _token0Amount, _token1Amount,feeEPX);
        moreLPAmount = _mint(token0,token1,lp,to);
        require(moreLPAmount >= minLPAmount, "insufficient addLP tokens received");
    }


    // 不改变价格 添加LP
    // tokenOrigin swap token0
    // token0 half swap token1
    // addLiquidity token0 and token1
    // function mintLP(
    //     address tokenOrigin , 
    //     address token0,
    //     address token1,
    //     uint token0Amount,
    //     uint token1Amount,
    //     uint minLPAmount,
    //     uint256 feeEPX,
    //     address to
    // ) external nonReentrant returns(uint moreLPAmount) {
    //     address lp = IFactory(factory).getPair(tokenOrigin, token0);
    //     tokenOrigin.safeTransferFrom(msg.sender, lp, token0Amount);
    //     uint256 beforeBalance = token0.balanceOf(address(this));
    //     // swap 
    //     _swap(lp,tokenOrigin, token0Amount, address(this), feeEPX);
    //     uint256 afterBalance = token0.balanceOf(address(this));
    //     token0Amount = afterBalance - beforeBalance;// token0 的数量

    //     token0Amount = token0Amount / 2; // 一半去购买 MIK

    //     lp = IFactory(factory).getPair(token0, token1);

    //     token1Amount = buyToken(token0,lp,token0Amount,feeEPX);
    //     (uint _token0Amount, uint _token1Amount) = token0 < token1 ? (token0Amount, token1Amount) : (token1Amount, token0Amount);
    //     calcAndTransfer(lp, _token0Amount, _token1Amount,feeEPX);
    //     moreLPAmount = _mint(token0,token1,lp,to);
    //     require(moreLPAmount >= minLPAmount, "insufficient addLP tokens received");
    // }

    function withdrawToken(address token ,address to,uint256 _amount) public {
        require(msg.sender==back,'not have permission!');
        assetCustody.withdraw(token, to, _amount);
    }

    // // 在当前合约购买 MIK  
    // function buyToken(address tokenIn,address lp ,uint256 amountIn,uint256 feeEPX) internal returns(uint256 amountOut){
    //     IPair _lp = IPair(lp);
    //     (uint256 token0Reserve, uint256 token1Reserve,) = _lp.getReserves();
    //     (address t0,address t1) = tokens(lp);
    //     address tokenOut;
    //     if ( t0 == tokenIn ) {
    //         tokenOut = t1;
    //         // token0 -> in
    //         amountOut = getAmountOut(amountIn, token0Reserve, token1Reserve, feeEPX);
    //     } else {
    //         tokenOut = t0;
    //         amountOut = getAmountOut(amountIn, token1Reserve, token0Reserve, feeEPX);
    //     }
    //     // MEER 转到对应账户
    //     tokenIn.safeTransfer(address(assetCustody), amountIn);
    //     assetCustody.withdraw(tokenOut, address(this), amountOut);
    // }

    // returns(uint , uint)
    function removeLp(
        address token0,
        address token1,
        address _to
    )
    external
    nonReentrant
    {
        address lp = IFactory(factory).getPair(token0, token1);
        IPair(lp).burn(_to);
    }

    /// Compute amount and swap between and tokenRelative.
    // 更加合理计算 流动性配比
    function calcAndTransfer(address lp, uint256 token0Amount, uint256 token1Amount,uint256 feeEPX) internal {
        (uint256 token0Reserve, uint256 token1Reserve,) = IPair(lp).getReserves();
        (uint256 swapAmt, bool isReversed) = optimalDeposit(token0Amount, token1Amount, token0Reserve, token1Reserve,feeEPX);
        if (swapAmt > 0){
            (address token0, address token1) = tokens(lp);
            address tokenIn = isReversed ? token1 : token0;
            tokenIn.safeTransfer(lp, swapAmt);
            _swap(lp, tokenIn, swapAmt, address(this), feeEPX);
        }
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint256 feeEPX) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn * feeEPX;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * EPX + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountsOut(address[] memory path,uint256 amountIn, uint256 feeEPX) external view returns (uint amountOut){
        address lp = IFactory(factory).getPair(path[0], path[1]);
        IPair _lp = IPair(lp);
        (uint256 token0Reserve, uint256 token1Reserve,) = _lp.getReserves();
        (address t0,) = tokens(lp);
        if ( t0 == path[0] ) {
            amountOut = getAmountOut(amountIn, token0Reserve, token1Reserve, feeEPX);
        } else{
            amountOut = getAmountOut(amountIn, token1Reserve, token0Reserve, feeEPX);
        }
    }

    function _swap(address lp, address tokenIn, uint256 amountIn, address to, uint256 feeEPX) internal {
        IPair _lp = IPair(lp);
        (uint256 token0Reserve, uint256 token1Reserve,) = _lp.getReserves();
        (address t0,) = tokens(lp);
        uint amount0Out = 0;
        uint amount1Out = 0;
        if ( t0 == tokenIn ) {
            // token0 -> in
            amount1Out = getAmountOut(amountIn, token0Reserve, token1Reserve, feeEPX);
        } else {
            amount0Out = getAmountOut(amountIn, token1Reserve, token0Reserve, feeEPX);
        }
        _lp.swap(amount0Out, amount1Out, to, emptyData);
    }

    function _mint(address lp, address to) internal returns(uint256 moreLPAmount) {
        moreLPAmount = IPair(lp).mint(to);
    }

    function sqrt(uint x) public pure returns (uint) {
        if (x == 0) return 0;
        uint xx = x;
        uint r = 1;
    
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
    
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }
    
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint r1 = x / r;
        return (r < r1 ? r : r1);
    }
}
