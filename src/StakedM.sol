// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IStakedM.sol";

contract StakedM is IStakedM, ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant SOFT_RESTRICTED_STAKER_ROLE = keccak256("SOFT_RESTRICTED_STAKER_ROLE");
    bytes32 public constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");

    uint256 public constant VESTING_DURATION = 8 hours;
    uint256 public constant MAX_COOLDOWN_DURATION = 90 days;

    uint256 private _vestingStart;
    uint256 private _vestingEnd;
    uint256 private _totalRewards;

    uint256 public cooldownDuration;

    struct RedemptionRequest {
        uint256 shares;
        uint256 assets;
        uint256 requestTime;
        bool claimed;
    }
    mapping(address => RedemptionRequest) public redemptionRequests;

    constructor(IERC20 _asset, address _admin, string memory _name, string memory _symbol)
        ERC4626(_asset)
        ERC20(_name, _symbol)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /* --------------- ERC4626 OVERRIDES --------------- */

    function deposit(uint256 assets, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        _checkNotRestricted(receiver);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        _checkNotRestricted(receiver);
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        _checkNotRestricted(owner);
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        returns (uint256)
    {
        _checkNotRestricted(owner);
        return super.redeem(shares, receiver, owner);
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 unvested = _unvestedAmount();
        return balance - unvested;
    }

    /* --------------- REWARDS --------------- */

    function transferInRewards(uint256 amount) external nonReentrant onlyRole(REWARDER_ROLE) {
        if (amount == 0) revert();

        // Merge remaining unvested rewards with new amount
        if (_totalRewards > 0 && block.timestamp < _vestingEnd) {
            uint256 elapsed = block.timestamp - _vestingStart;
            uint256 remaining = _totalRewards * (VESTING_DURATION - elapsed) / VESTING_DURATION;
            _totalRewards = remaining + amount;
        } else {
            _totalRewards = amount;
        }
        _vestingStart = block.timestamp;
        _vestingEnd = block.timestamp + VESTING_DURATION;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsReceived(amount);
    }

    /* --------------- REDEMPTION WITH COOLDOWN --------------- */

    function requestRedeem(uint256 shares) external override nonReentrant {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, msg.sender)) revert RestrictedAddress();

        RedemptionRequest storage req = redemptionRequests[msg.sender];
        if (req.shares > 0 && !req.claimed) revert();

        uint256 assets = previewRedeem(shares);
        _burn(msg.sender, shares);

        req.shares = shares;
        req.assets = assets;
        req.requestTime = block.timestamp;
        req.claimed = false;

        emit RedemptionRequested(msg.sender, shares, assets, block.timestamp);
    }

    function claimRedemption() external nonReentrant {
        RedemptionRequest storage req = redemptionRequests[msg.sender];
        if (req.shares == 0) revert();
        if (req.claimed) revert AlreadyClaimed();
        if (block.timestamp < req.requestTime + cooldownDuration) revert CooldownNotElapsed();

        uint256 assets = req.assets;
        req.claimed = true;

        IERC20(asset()).safeTransfer(msg.sender, assets);
        delete redemptionRequests[msg.sender];
        emit WithdrawalCompleted(msg.sender, req.shares, assets);
    }

    /* --------------- ADMIN --------------- */

    function setCooldownDuration(uint256 duration) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration > MAX_COOLDOWN_DURATION) revert MaxCooldownExceeded();
        uint256 oldDuration = cooldownDuration;
        cooldownDuration = duration;
        emit CooldownDurationUpdated(oldDuration, duration);
    }

    /* --------------- COMPLIANCE --------------- */

    function redistributeLockedAmount(address from, address to) external override onlyRole(BLACKLISTER_ROLE) {
        if (!hasRole(FULL_RESTRICTED_STAKER_ROLE, from)) revert NotRestricted();
        uint256 shares = balanceOf(from);
        _burn(from, shares);
        _mint(to, shares);
        emit LockedAmountRedistributed(from, to, shares);
    }

    /* --------------- INTERNAL --------------- */

    function _unvestedAmount() internal view returns (uint256) {
        if (_totalRewards == 0 || block.timestamp >= _vestingEnd) return 0;
        uint256 elapsed = block.timestamp - _vestingStart;
        return _totalRewards * (VESTING_DURATION - elapsed) / VESTING_DURATION;
    }

    function _checkNotRestricted(address account) internal view {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, account)) revert RestrictedAddress();
        if (hasRole(SOFT_RESTRICTED_STAKER_ROLE, account)) revert SoftRestrictedAddress();
    }
}
