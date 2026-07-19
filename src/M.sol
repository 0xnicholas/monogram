// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract M is Ownable2Step, ERC20Burnable, ERC20Permit {

    /// @notice This event is fired when the minter changes
    event MinterUpdated(address indexed newMinter, address indexed oldMinter);

    /// @notice Zero address not allowed
    error ZeroAddressException();
    /// @notice It's not possible to renounce the ownership
    error CantRenounceOwnership();
    /// @notice Only the minter role can perform an action
    error OnlyMinter();

    address public minter;

    constructor(address admin) Ownable(admin) ERC20("M", "M") ERC20Permit("M") {
        if (admin == address(0)) revert ZeroAddressException();
        _transferOwnership(admin);
    }

    function setMinter(address newMinter) external onlyOwner {
        emit MinterUpdated(newMinter, minter);
        minter = newMinter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert CantRenounceOwnership();
    }
}