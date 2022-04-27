// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IMicky {
    function getParent(address _user) external view returns (address);
    function getChildren(address _user) external view returns (address[] memory);
    function bindReferer(address to) external;
}
