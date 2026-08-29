// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IStakedM is IERC4626 {
    struct UserCooldown {
        uint104 cooldownEnd;
        uint256 underlyingAmount;
    }

    event RewardsReceived(uint256 amount);
    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);
    event LockedAmountRedistributed(address indexed from, address indexed to, uint256 shares);

    error InvalidAmount();
    error InvalidCooldown();
    error InvalidToken();
    error InvalidZeroAddress();
    error CantBlacklistOwner();
    error OperationNotAllowed();
    error ExcessiveWithdrawAmount();
    error ExcessiveRedeemAmount();
    error MinSharesViolation();

    function transferInRewards(uint256 amount) external;
    function cooldownAssets(uint256 assets, address owner) external returns (uint256);
    function cooldownShares(uint256 shares, address owner) external returns (uint256);
    function unstake(address receiver) external;
    function setCooldownDuration(uint24 duration) external;
    function addToBlacklist(address target, bool isFullBlacklisting) external;
    function removeFromBlacklist(address target, bool isFullBlacklisting) external;
    function rescueTokens(address token, uint256 amount, address to) external;
    function redistributeLockedAmount(address from, address to) external;
}
