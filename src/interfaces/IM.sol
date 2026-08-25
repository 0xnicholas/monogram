// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IM is IERC20, IERC20Permit, IERC20Metadata {
    function mint(address _to, uint256 _amount) external;

    function burn(uint256 _amount) external;

    function burnFrom(address account, uint256 amount) external;

    function setMinter(address newMinter) external;
}
