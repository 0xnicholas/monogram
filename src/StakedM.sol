// SPDX-License-Identifier: GPL-3.0
// Derived from Ethena's StakedUSDe / StakedUSDeV2 (GPL-3.0), see
// https://github.com/code-423n4/2023-10-ethena/blob/main/contracts/StakedUSDe.sol
// Modifications for Monogram:
// - transferInRewards merges unvested rewards instead of reverting (ADR-0007 deviation, kept from prior design)
// - constructor-initialized (non-upgradeable), token metadata passed in; no V2 upgrade initializer
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./SingleAdminAccessControl.sol";
import "./UnstakingSilo.sol";
import "./interfaces/IStakedM.sol";

/**
 * @title StakedM
 * @notice sM 质押金库。用户存入 M 获得 sM，REWARDER 定期注入 M 奖励，sM:M 汇率单调递增。
 * @dev 若 cooldownDuration > 0，ERC-4626 的 withdraw/redeem 被禁用（偏离 ERC-4626 标准），
 *      解质押必须走 cooldownShares/cooldownAssets → 冷却到期后 unstake。冷却资产转入
 *      UnstakingSilo 隔离，即时退出 totalAssets。若 cooldownDuration == 0，恢复标准
 *      ERC-4626 行为（unstake 仍可领取 Silo 中已到期的资产）。
 */
contract StakedM is SingleAdminAccessControl, ReentrancyGuard, ERC20Permit, ERC4626, IStakedM {
    using SafeERC20 for IERC20;

    /* --------------- CONSTANTS --------------- */

    /// @notice 允许向本合约分发奖励的角色
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    /// @notice 允许将地址加入/移出受限名单的角色
    bytes32 public constant BLACKLIST_MANAGER_ROLE = keccak256("BLACKLIST_MANAGER_ROLE");
    /// @notice 阻止地址质押（可入不可出语义：只挡 deposit/mint）
    bytes32 public constant SOFT_RESTRICTED_STAKER_ROLE = keccak256("SOFT_RESTRICTED_STAKER_ROLE");
    /// @notice 阻止地址转账、质押、解质押；admin 可重分配其余额
    bytes32 public constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");

    /// @notice 奖励线性 vesting 时长
    uint256 public constant VESTING_DURATION = 8 hours;

    /// @notice 最小非零份额，防捐赠攻击
    uint256 private constant MIN_SHARES = 1 ether;

    /// @notice 冷却期上限
    uint24 public constant MAX_COOLDOWN_DURATION = 90 days;

    /* --------------- STATE --------------- */

    uint24 public cooldownDuration;

    mapping(address => UserCooldown) public cooldowns;

    UnstakingSilo public silo;

    uint256 private _vestingStart;
    uint256 private _vestingEnd;
    uint256 private _totalRewards;

    /* --------------- MODIFIERS --------------- */

    /// @notice 冷却期必须关闭（cooldownDuration == 0）
    modifier ensureCooldownOff() {
        if (cooldownDuration != 0) revert OperationNotAllowed();
        _;
    }

    /// @notice 冷却期必须开启（cooldownDuration > 0）
    modifier ensureCooldownOn() {
        if (cooldownDuration == 0) revert OperationNotAllowed();
        _;
    }

    /// @notice 输入金额非零
    modifier notZero(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    /// @notice 黑名单目标不能是 admin
    modifier notOwner(address target) {
        if (target == owner()) revert CantBlacklistOwner();
        _;
    }

    /* --------------- CONSTRUCTOR --------------- */

    constructor(IERC20 _asset, address _initialRewarder, address _admin, string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
        ERC4626(_asset)
        ERC20Permit(_name)
    {
        if (_admin == address(0) || _initialRewarder == address(0) || address(_asset) == address(0)) {
            revert InvalidZeroAddress();
        }

        _grantRole(REWARDER_ROLE, _initialRewarder);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        silo = new UnstakingSilo(address(this), address(_asset));
        cooldownDuration = MAX_COOLDOWN_DURATION;
    }

    /* --------------- ERC4626 OVERRIDES --------------- */

    /**
     * @dev 冷却期开启时禁用（ensureCooldownOff），强制走 cooldownShares 路径。
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override(ERC4626, IERC4626)
        ensureCooldownOff
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @dev 冷却期开启时禁用（ensureCooldownOff），强制走 cooldownAssets 路径。
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override(ERC4626, IERC4626)
        ensureCooldownOff
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - getUnvestedAmount();
    }

    /// @dev sM 与 M 均为 18 位小数
    function decimals() public pure override(ERC4626, ERC20, IERC20Metadata) returns (uint8) {
        return 18;
    }

    /* --------------- UNSTAKING WITH COOLDOWN --------------- */

    /// @notice 冷却到期后领取 Silo 中隔离的全部资产
    /// @param receiver 接收资产的地址
    function unstake(address receiver) external override {
        UserCooldown storage userCooldown = cooldowns[msg.sender];
        uint256 assets = userCooldown.underlyingAmount;

        if (block.timestamp >= userCooldown.cooldownEnd) {
            userCooldown.cooldownEnd = 0;
            userCooldown.underlyingAmount = 0;

            silo.withdraw(receiver, assets);
        } else {
            revert InvalidCooldown();
        }
    }

    /// @notice 按资产数量发起解质押冷却，资产转入 Silo
    /// @param assets 解质押的资产数量
    /// @param owner 份额持有人，调用者需有 owner 的授权
    function cooldownAssets(uint256 assets, address owner) external override ensureCooldownOn returns (uint256) {
        if (assets > maxWithdraw(owner)) revert ExcessiveWithdrawAmount();

        uint256 shares = previewWithdraw(assets);

        cooldowns[owner].cooldownEnd = uint104(block.timestamp) + cooldownDuration;
        cooldowns[owner].underlyingAmount += assets;

        _withdraw(_msgSender(), address(silo), owner, assets, shares);

        return shares;
    }

    /// @notice 按份额数量发起解质押冷却，资产转入 Silo
    /// @param shares 解质押的份额数量
    /// @param owner 份额持有人，调用者需有 owner 的授权
    function cooldownShares(uint256 shares, address owner) external override ensureCooldownOn returns (uint256) {
        if (shares > maxRedeem(owner)) revert ExcessiveRedeemAmount();

        uint256 assets = previewRedeem(shares);

        cooldowns[owner].cooldownEnd = uint104(block.timestamp) + cooldownDuration;
        cooldowns[owner].underlyingAmount += assets;

        _withdraw(_msgSender(), address(silo), owner, assets, shares);

        return assets;
    }

    /// @notice 设置冷却期时长。设为 0 恢复标准 ERC-4626 即时提款；
    ///         已在冷却中的资产仍可通过 unstake 在到期后领取。
    function setCooldownDuration(uint24 duration) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration > MAX_COOLDOWN_DURATION) revert InvalidCooldown();

        uint24 previousDuration = cooldownDuration;
        cooldownDuration = duration;
        emit CooldownDurationUpdated(previousDuration, duration);
    }

    /* --------------- REWARDS --------------- */

    /**
     * @notice REWARDER 注入 M 奖励，8 小时线性 vesting。
     * @dev 与 Ethena 的偏离点：未 vest 完时允许再次注入，剩余未 vest 金额与新奖励合并
     *      重新计算 vesting（分发器无需等待 8 小时窗口，见 ADR-0007）。
     */
    function transferInRewards(uint256 amount) external override nonReentrant onlyRole(REWARDER_ROLE) notZero(amount) {
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

    /// @notice 当前未 vest 的奖励金额
    function getUnvestedAmount() public view returns (uint256) {
        if (_totalRewards == 0 || block.timestamp >= _vestingEnd) return 0;
        uint256 elapsed = block.timestamp - _vestingStart;
        return _totalRewards * (VESTING_DURATION - elapsed) / VESTING_DURATION;
    }

    /* --------------- ADMIN --------------- */

    /// @notice 将地址加入受限名单（软/全受限）
    function addToBlacklist(address target, bool isFullBlacklisting)
        external
        override
        onlyRole(BLACKLIST_MANAGER_ROLE)
        notOwner(target)
    {
        bytes32 role = isFullBlacklisting ? FULL_RESTRICTED_STAKER_ROLE : SOFT_RESTRICTED_STAKER_ROLE;
        _grantRole(role, target);
    }

    /// @notice 将地址移出受限名单（软/全受限）
    function removeFromBlacklist(address target, bool isFullBlacklisting)
        external
        override
        onlyRole(BLACKLIST_MANAGER_ROLE)
        notOwner(target)
    {
        bytes32 role = isFullBlacklisting ? FULL_RESTRICTED_STAKER_ROLE : SOFT_RESTRICTED_STAKER_ROLE;
        _revokeRole(role, target);
    }

    /// @notice 营救误转入本合约的代币。M 归质押人所有不可营救；sM 可营救（不应停留在此合约）。
    function rescueTokens(address token, uint256 amount, address to) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == asset()) revert InvalidToken();
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice 重分配 FULL_RESTRICTED 地址的全部 sM 余额。
     * @param from 被全额受限的地址
     * @param to   接收地址；to == address(0) 表示直接销毁（burn-to-vest 分支）
     */
    function redistributeLockedAmount(address from, address to) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, from) && !hasRole(FULL_RESTRICTED_STAKER_ROLE, to)) {
            uint256 amountToDistribute = balanceOf(from);
            _burn(from, amountToDistribute);
            if (to != address(0)) _mint(to, amountToDistribute);

            emit LockedAmountRedistributed(from, to, amountToDistribute);
        } else {
            revert OperationNotAllowed();
        }
    }

    /// @dev 禁用 renounceRole，防止用户自行弃权受限角色
    function renounceRole(bytes32, address) public virtual override {
        revert OperationNotAllowed();
    }

    /* --------------- INTERNAL --------------- */

    /// @notice 确保剩余总份额不低于 MIN_SHARES，防捐赠攻击
    function _checkMinShares() internal view {
        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ > 0 && totalSupply_ < MIN_SHARES) revert MinSharesViolation();
    }

    /// @dev 质押通用流程：软受限的 caller 或 receiver 均禁止
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        if (hasRole(SOFT_RESTRICTED_STAKER_ROLE, caller) || hasRole(SOFT_RESTRICTED_STAKER_ROLE, receiver)) {
            revert OperationNotAllowed();
        }
        super._deposit(caller, receiver, assets, shares);
        _checkMinShares();
    }

    /// @dev 解质押通用流程：全受限的 caller 或 receiver 均禁止
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, caller) || hasRole(FULL_RESTRICTED_STAKER_ROLE, receiver)) {
            revert OperationNotAllowed();
        }
        super._withdraw(caller, receiver, owner, assets, shares);
        _checkMinShares();
    }

    /// @dev 转账钩子（含铸造/销毁）：全受限地址禁止转入/转出；转出至 address(0)（销毁）豁免，
    ///      供 redistributeLockedAmount 的 burn 分支使用
    function _update(address from, address to, uint256 value) internal virtual override {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, from) && to != address(0)) {
            revert OperationNotAllowed();
        }
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, to)) {
            revert OperationNotAllowed();
        }
        super._update(from, to, value);
    }
}
