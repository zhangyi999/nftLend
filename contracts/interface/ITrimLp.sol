// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITrimLp {
    function getReserves(address _lp) external view returns(uint, uint);
    function tokens(address lp) external view returns(address t0, address t1);
    function skim(address token, address to) external;
    function removeLp(address token0, address token1, address _to) external;
    function getAmountsOut(address[] memory path,uint256 amountIn, uint256 feeEPX) external view returns (uint amountOut);
    function getLP(
        address tokenOrigin,
        address token0,
        address token1,
        uint token0Amount,
        uint token1Amount,
        uint minLPAmount,
        uint256 feeEPX,
        address to
    ) external returns(uint);
    function mintLP(
        address tokenOrigin,
        address token0,
        address token1,
        uint token0Amount,
        uint token1Amount,
        uint minLPAmount,
        uint256 feeEPX,
        address to
    ) external returns(uint);
    function getPair(address token0, address token1) external view returns (address);
}
