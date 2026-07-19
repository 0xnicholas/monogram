// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IStakedM is IERC4626 {
    event RewardsReceived(uint256 amount);
    event RedemptionRequested(address indexed user, uint256 shares, uint256 assets, uint256 timestamp);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);
    event CooldownDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event LockedAmountRedistributed(address indexed from, address indexed to, uint256 shares);

    error RestrictedAddress();
    error SoftRestrictedAddress();
    error NotRestricted();
    error AlreadyClaimed();
    error CooldownNotElapsed();
    error MaxCooldownExceeded();

    function transferInRewards(uint256 amount) external;
    function requestRedeem(uint256 shares) external;
    function claimRedemption() external;
    function setCooldownDuration(uint256 duration) external;
    function redistributeLockedAmount(address from, address to) external;
}
