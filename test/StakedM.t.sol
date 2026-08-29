// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/StakedM.sol";
import "../src/UnstakingSilo.sol";
import "../src/interfaces/IStakedM.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "MA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StakedMTest is Test {
    StakedM public stakedM;
    UnstakingSilo public silo;
    MockAsset public asset;

    address public admin = makeAddr("admin");
    address public rewarder = makeAddr("rewarder");
    address public blacklistManager = makeAddr("blacklistManager");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public spender = makeAddr("spender");
    address public fullRestrictedUser = makeAddr("fullRestrictedUser");
    address public softRestrictedUser = makeAddr("softRestrictedUser");

    uint256 public constant ALICE_KEY = 0xA11CE;
    address public alice;

    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 public constant BLACKLIST_MANAGER_ROLE = keccak256("BLACKLIST_MANAGER_ROLE");
    bytes32 public constant SOFT_RESTRICTED_STAKER_ROLE = keccak256("SOFT_RESTRICTED_STAKER_ROLE");
    bytes32 public constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");

    function setUp() public {
        alice = vm.addr(ALICE_KEY);
        asset = new MockAsset();
        stakedM = new StakedM(IERC20(address(asset)), rewarder, admin, "Staked Monogram", "sM");
        silo = UnstakingSilo(address(stakedM.silo()));

        vm.startPrank(admin);
        stakedM.grantRole(BLACKLIST_MANAGER_ROLE, blacklistManager);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);
        stakedM.grantRole(SOFT_RESTRICTED_STAKER_ROLE, softRestrictedUser);
        stakedM.setCooldownDuration(7 days);
        vm.stopPrank();

        // Fund users
        asset.mint(user1, 100_000 ether);
        asset.mint(user2, 100_000 ether);
        asset.mint(alice, 100_000 ether);
        asset.mint(softRestrictedUser, 100_000 ether);
        asset.mint(fullRestrictedUser, 100_000 ether);
        asset.mint(rewarder, 10_000 ether);

        // Approve stakedM for all users
        address[5] memory users = [user1, user2, alice, softRestrictedUser, fullRestrictedUser];
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            asset.approve(address(stakedM), type(uint256).max);
        }
        vm.prank(rewarder);
        asset.approve(address(stakedM), type(uint256).max);
    }

    function _stake(address user, uint256 amount) internal {
        vm.prank(user);
        stakedM.deposit(amount, user);
    }

    // ----------- Deployment -----------

    function test_Deployment() public view {
        assertEq(stakedM.name(), "Staked Monogram");
        assertEq(stakedM.symbol(), "sM");
        assertEq(stakedM.decimals(), 18);
        assertEq(address(stakedM.asset()), address(asset));
        // V2 默认开启冷却期，取上限值
        assertEq(stakedM.cooldownDuration(), 7 days);
        assertEq(stakedM.MAX_COOLDOWN_DURATION(), 90 days);

        // Silo 接线
        assertTrue(address(silo) != address(0));
        assertEq(silo.STAKING_VAULT(), address(stakedM));
        assertEq(address(silo.M_TOKEN()), address(asset));

        // 角色授予
        assertTrue(stakedM.hasRole(REWARDER_ROLE, rewarder));
        assertTrue(stakedM.hasRole(BLACKLIST_MANAGER_ROLE, blacklistManager));
        assertTrue(stakedM.hasRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser));
        assertTrue(stakedM.hasRole(SOFT_RESTRICTED_STAKER_ROLE, softRestrictedUser));
    }

    function test_Deployment_DefaultCooldownIsMax() public {
        // 构造即开冷却（默认 90 天），防部署窗口绕过
        StakedM fresh = new StakedM(IERC20(address(asset)), rewarder, admin, "Fresh", "FRESH");
        assertEq(fresh.cooldownDuration(), 90 days);
        assertEq(address(fresh.silo()) != address(0), true);
    }

    // ----------- Deposit / Mint -----------

    function test_Deposit() public {
        _stake(user1, 1000 ether);

        assertEq(stakedM.balanceOf(user1), 1000 ether);
        assertEq(asset.balanceOf(address(stakedM)), 1000 ether);
        assertEq(stakedM.totalAssets(), 1000 ether);
    }

    function test_Mint() public {
        vm.prank(user1);
        uint256 assets = stakedM.mint(500 ether, user1);

        assertEq(assets, 500 ether);
        assertEq(stakedM.balanceOf(user1), 500 ether);
    }

    function test_Deposit_Zero_Reverts() public {
        vm.prank(user1);
        vm.expectRevert(IStakedM.InvalidAmount.selector);
        stakedM.deposit(0, user1);
    }

    function test_Deposit_SoftRestrictedCaller() public {
        vm.prank(softRestrictedUser);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.deposit(100 ether, softRestrictedUser);
    }

    function test_Deposit_SoftRestrictedReceiver() public {
        vm.prank(user1);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.deposit(100 ether, softRestrictedUser);
    }

    function test_Deposit_FullRestrictedCaller_Allowed() public {
        // V2 语义：_deposit 只挡 SOFT；FULL 仍可质押给他人（其 sM 转账由 _update 拦截）
        vm.prank(fullRestrictedUser);
        stakedM.deposit(100 ether, user1);

        assertEq(stakedM.balanceOf(user1), 100 ether);
    }

    function test_Deposit_FullRestrictedReceiver_Blocked() public {
        // 铸造走 _update：FULL 地址不能接收 sM
        vm.prank(user1);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.deposit(100 ether, fullRestrictedUser);
    }

    // ----------- 冷却期互斥：ERC4626 原生路径封死（#20 核心修复） -----------

    function test_Withdraw_BlockedWhenCooldownOn() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.withdraw(500 ether, user1, user1);
    }

    function test_Redeem_BlockedWhenCooldownOn() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.redeem(500 ether, user1, user1);
    }

    function test_Withdraw_AllowedWhenCooldownOff() public {
        _stake(user1, 1000 ether);

        vm.prank(admin);
        stakedM.setCooldownDuration(0);

        vm.prank(user1);
        uint256 assets = stakedM.withdraw(500 ether, user1, user1);

        assertEq(assets, 500 ether);
        assertEq(asset.balanceOf(user1), 100_000 ether - 500 ether);
    }

    function test_Redeem_AllowedWhenCooldownOff() public {
        _stake(user1, 1000 ether);

        vm.prank(admin);
        stakedM.setCooldownDuration(0);

        vm.prank(user1);
        uint256 assets = stakedM.redeem(500 ether, user1, user1);

        assertEq(assets, 500 ether);
        assertEq(stakedM.balanceOf(user1), 500 ether);
    }

    // ----------- Cooldown → Silo → Unstake -----------

    function test_CooldownShares() public {
        _stake(user1, 1000 ether);
        uint256 totalAssetsBefore = stakedM.totalAssets();

        vm.prank(user1);
        uint256 assets = stakedM.cooldownShares(400 ether, user1);

        assertEq(assets, 400 ether);
        assertEq(stakedM.balanceOf(user1), 600 ether);
        // 份额已烧、资产已隔离进 Silo
        assertEq(asset.balanceOf(address(silo)), 400 ether);
        assertEq(asset.balanceOf(address(stakedM)), 600 ether);
        // Silo 资产退出 totalAssets（稀释修复）
        assertEq(stakedM.totalAssets(), 600 ether);
        assertEq(totalAssetsBefore, 1000 ether);

        (uint104 cooldownEnd, uint256 underlyingAmount) = stakedM.cooldowns(user1);
        assertEq(uint256(cooldownEnd), block.timestamp + 7 days);
        assertEq(underlyingAmount, 400 ether);
    }

    function test_CooldownAssets() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        uint256 shares = stakedM.cooldownAssets(300 ether, user1);

        assertEq(shares, 300 ether);
        assertEq(stakedM.balanceOf(user1), 700 ether);
        assertEq(asset.balanceOf(address(silo)), 300 ether);

        (, uint256 underlyingAmount) = stakedM.cooldowns(user1);
        assertEq(underlyingAmount, 300 ether);
    }

    function test_CooldownShares_Excessive() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        vm.expectRevert(IStakedM.ExcessiveRedeemAmount.selector);
        stakedM.cooldownShares(1001 ether, user1);
    }

    function test_CooldownAssets_Excessive() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        vm.expectRevert(IStakedM.ExcessiveWithdrawAmount.selector);
        stakedM.cooldownAssets(1001 ether, user1);
    }

    function test_Cooldown_BlockedWhenCooldownOff() public {
        _stake(user1, 1000 ether);

        vm.prank(admin);
        stakedM.setCooldownDuration(0);

        vm.prank(user1);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.cooldownShares(400 ether, user1);
    }

    function test_Cooldown_ZeroShares_Reverts() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        vm.expectRevert(IStakedM.InvalidAmount.selector);
        stakedM.cooldownShares(0, user1);
    }

    function test_Cooldown_WithAllowance() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        stakedM.approve(spender, 400 ether);

        vm.prank(spender);
        stakedM.cooldownShares(400 ether, user1);

        assertEq(stakedM.balanceOf(user1), 600 ether);
        assertEq(asset.balanceOf(address(silo)), 400 ether);
    }

    function test_Cooldown_SecondResetsAndAccumulates() public {
        _stake(user1, 1000 ether);

        vm.startPrank(user1);
        stakedM.cooldownShares(400 ether, user1);
        vm.warp(block.timestamp + 3 days);
        stakedM.cooldownShares(300 ether, user1);
        vm.stopPrank();

        (uint104 cooldownEnd, uint256 underlyingAmount) = stakedM.cooldowns(user1);
        // 冷却期重置为第二次操作时刻起算
        assertEq(uint256(cooldownEnd), block.timestamp + 7 days);
        assertEq(underlyingAmount, 700 ether);
        assertEq(asset.balanceOf(address(silo)), 700 ether);
    }

    function test_Unstake_BeforeCooldownEnd() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        stakedM.cooldownShares(400 ether, user1);

        vm.warp(block.timestamp + 6 days);
        vm.prank(user1);
        vm.expectRevert(IStakedM.InvalidCooldown.selector);
        stakedM.unstake(user1);
    }

    function test_Unstake_AfterCooldownEnd() public {
        _stake(user1, 1000 ether);
        uint256 assetBalanceBefore = asset.balanceOf(user1);

        vm.prank(user1);
        stakedM.cooldownShares(400 ether, user1);

        vm.warp(block.timestamp + 8 days);

        // 可领取到任意 receiver
        vm.prank(user1);
        stakedM.unstake(user2);

        assertEq(asset.balanceOf(user2), 100_000 ether + 400 ether);
        assertEq(asset.balanceOf(user1), assetBalanceBefore);
        assertEq(asset.balanceOf(address(silo)), 0);

        (uint104 cooldownEnd, uint256 underlyingAmount) = stakedM.cooldowns(user1);
        assertEq(uint256(cooldownEnd), 0);
        assertEq(underlyingAmount, 0);
    }

    function test_Unstake_AfterDurationSetToZero() public {
        // 冷却期改 0 恢复即时模式后，Silo 中已到期的资产仍可领取（审计边界）
        _stake(user1, 1000 ether);

        vm.prank(user1);
        stakedM.cooldownShares(400 ether, user1);

        vm.startPrank(admin);
        stakedM.setCooldownDuration(0);
        vm.stopPrank();

        vm.warp(block.timestamp + 8 days);

        vm.prank(user1);
        stakedM.unstake(user1);

        // 本金 1000 中 400 走了冷却路径领回
        assertEq(asset.balanceOf(user1), 100_000 ether - 600 ether);
    }

    function test_Cooldown_ExcludesFromTotalAssets() public {
        // 稀释修复验证：user1 冷却后，user2 的份额不再被 Silo 资产稀释
        _stake(user1, 1000 ether);
        _stake(user2, 1000 ether);

        vm.prank(user1);
        stakedM.cooldownShares(1000 ether, user1);

        assertEq(stakedM.totalAssets(), 1000 ether);
        assertEq(stakedM.convertToAssets(stakedM.balanceOf(user2)), 1000 ether);
    }

    // ----------- FULL_RESTRICTED 语义 -----------

    function test_FullRestricted_CannotCooldown() public {
        // FULL 用户先持有份额（受限前由 user1 转入不可行——用 deposit 前置）：
        // 场景：user1 存入、转给 fullRestrictedUser 前先解除限制拿份额，再上限制
        vm.startPrank(admin);
        stakedM.revokeRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);
        vm.stopPrank();

        _stake(fullRestrictedUser, 1000 ether);

        vm.prank(admin);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);

        vm.prank(fullRestrictedUser);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.cooldownShares(400 ether, fullRestrictedUser);
    }

    function test_FullRestricted_CannotWithdrawOrRedeem() public {
        vm.startPrank(admin);
        stakedM.revokeRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);
        vm.stopPrank();

        _stake(fullRestrictedUser, 1000 ether);

        vm.startPrank(admin);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);
        stakedM.setCooldownDuration(0);
        vm.stopPrank();

        vm.startPrank(fullRestrictedUser);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.withdraw(100 ether, fullRestrictedUser, fullRestrictedUser);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.redeem(100 ether, fullRestrictedUser, fullRestrictedUser);
        vm.stopPrank();
    }

    function test_FullRestricted_TransferBlocked() public {
        // FULL 地址的 sM 不可转出（_update 拦截）
        vm.startPrank(admin);
        stakedM.revokeRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);
        vm.stopPrank();

        _stake(fullRestrictedUser, 1000 ether);

        vm.prank(admin);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);

        vm.prank(fullRestrictedUser);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.transfer(user2, 100 ether);
    }

    function test_FullRestricted_CannotReceiveTransfer() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.transfer(fullRestrictedUser, 100 ether);
    }

    function test_SoftRestricted_CanHoldAndUnstake() public {
        // V2 语义：SOFT 可入（持份）不可新存；已持有的份额可解质押退出
        vm.startPrank(admin);
        stakedM.revokeRole(SOFT_RESTRICTED_STAKER_ROLE, softRestrictedUser);
        vm.stopPrank();

        _stake(softRestrictedUser, 1000 ether);

        vm.prank(admin);
        stakedM.grantRole(SOFT_RESTRICTED_STAKER_ROLE, softRestrictedUser);

        // SOFT 仍可转 sM、可发起冷却与领取
        vm.startPrank(softRestrictedUser);
        stakedM.transfer(user2, 100 ether);
        stakedM.cooldownShares(900 ether, softRestrictedUser);
        vm.stopPrank();

        vm.warp(block.timestamp + 8 days);

        vm.prank(softRestrictedUser);
        stakedM.unstake(softRestrictedUser);

        // 本金 1000 − 转给 user2 的 100（以 sM 形式）后解质押 900
        assertEq(asset.balanceOf(softRestrictedUser), 100_000 ether - 100 ether);
        assertEq(stakedM.balanceOf(user2), 100 ether);
    }

    // ----------- Rewards & Vesting -----------

    function test_TransferInRewards() public {
        _stake(user1, 1000 ether);

        vm.prank(rewarder);
        stakedM.transferInRewards(100 ether);

        assertEq(asset.balanceOf(address(stakedM)), 1100 ether);
        // vesting 中 totalAssets 排除未 vest 部分
        assertLt(stakedM.totalAssets(), 1100 ether);
        assertGt(stakedM.getUnvestedAmount(), 0);
    }

    function test_TransferInRewards_NotRewarder() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedM.transferInRewards(100 ether);
    }

    function test_TransferInRewards_ZeroAmount() public {
        vm.prank(rewarder);
        vm.expectRevert(IStakedM.InvalidAmount.selector);
        stakedM.transferInRewards(0);
    }

    function test_Vesting_LinearIncrease() public {
        _stake(user1, 1000 ether);

        vm.prank(rewarder);
        stakedM.transferInRewards(800 ether);

        uint256 startTime = block.timestamp;

        assertApproxEqAbs(stakedM.totalAssets(), 1000 ether, 1);

        vm.warp(startTime + 4 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1400 ether, 2);

        vm.warp(startTime + 8 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1800 ether, 2);
    }

    function test_Vesting_MultipleRewards_Merge() public {
        // 与 Ethena 的已记录偏离：未 vest 完可再注入，剩余部分与新奖励合并
        _stake(user1, 1000 ether);

        vm.prank(rewarder);
        stakedM.transferInRewards(100 ether);

        vm.warp(block.timestamp + 4 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1050 ether, 1);

        vm.prank(rewarder);
        stakedM.transferInRewards(200 ether);

        assertApproxEqAbs(stakedM.totalAssets(), 1050 ether, 1);

        vm.warp(block.timestamp + 8 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1300 ether, 5);
    }

    function test_Ratio_MonotonicIncrease() public {
        _stake(user1, 1000 ether);

        vm.warp(block.timestamp + 9 hours);
        vm.prank(rewarder);
        stakedM.transferInRewards(100 ether);
        vm.warp(block.timestamp + 9 hours);

        uint256 assetsPerShare = stakedM.convertToAssets(1 ether);
        assertGe(assetsPerShare, 1 ether);

        // 解质押走冷却路径后汇率不受影响
        vm.prank(user1);
        stakedM.cooldownShares(500 ether, user1);
        assertGe(stakedM.convertToAssets(1 ether), 1 ether);
    }

    // ----------- Blacklist 管理 -----------

    function test_AddToBlacklist_Soft() public {
        vm.prank(blacklistManager);
        stakedM.addToBlacklist(user2, false);

        assertTrue(stakedM.hasRole(SOFT_RESTRICTED_STAKER_ROLE, user2));
    }

    function test_AddToBlacklist_Full() public {
        vm.prank(blacklistManager);
        stakedM.addToBlacklist(user2, true);

        assertTrue(stakedM.hasRole(FULL_RESTRICTED_STAKER_ROLE, user2));
    }

    function test_AddToBlacklist_NotManager() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedM.addToBlacklist(user2, true);
    }

    function test_AddToBlacklist_Admin_Blocked() public {
        vm.prank(blacklistManager);
        vm.expectRevert(IStakedM.CantBlacklistOwner.selector);
        stakedM.addToBlacklist(admin, true);
    }

    function test_RemoveFromBlacklist() public {
        vm.startPrank(blacklistManager);
        stakedM.addToBlacklist(user2, true);
        stakedM.removeFromBlacklist(user2, true);
        vm.stopPrank();

        assertFalse(stakedM.hasRole(FULL_RESTRICTED_STAKER_ROLE, user2));
    }

    function test_RemoveFromBlacklist_Admin_Blocked() public {
        vm.prank(blacklistManager);
        vm.expectRevert(IStakedM.CantBlacklistOwner.selector);
        stakedM.removeFromBlacklist(admin, false);
    }

    // ----------- redistributeLockedAmount -----------

    function test_RedistributeLockedAmount() public {
        vm.startPrank(admin);
        stakedM.revokeRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);
        vm.stopPrank();

        _stake(fullRestrictedUser, 1000 ether);

        vm.prank(admin);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);

        vm.prank(admin); // V2：admin 专属操作
        stakedM.redistributeLockedAmount(fullRestrictedUser, user1);

        assertEq(stakedM.balanceOf(fullRestrictedUser), 0);
        assertEq(stakedM.balanceOf(user1), 1000 ether);
    }

    function test_RedistributeLockedAmount_BurnBranch() public {
        vm.startPrank(admin);
        stakedM.revokeRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);
        vm.stopPrank();

        _stake(fullRestrictedUser, 1000 ether);
        uint256 totalSupplyBefore = stakedM.totalSupply();

        vm.prank(admin);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, fullRestrictedUser);

        vm.prank(admin);
        stakedM.redistributeLockedAmount(fullRestrictedUser, address(0));

        assertEq(stakedM.balanceOf(fullRestrictedUser), 0);
        assertEq(stakedM.totalSupply(), totalSupplyBefore - 1000 ether);
    }

    function test_RedistributeLockedAmount_FromNotFull() public {
        vm.prank(admin);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.redistributeLockedAmount(user1, user2);
    }

    function test_RedistributeLockedAmount_ToFull() public {
        vm.prank(admin);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.redistributeLockedAmount(fullRestrictedUser, fullRestrictedUser);
    }

    function test_RedistributeLockedAmount_NotAdmin() public {
        vm.prank(blacklistManager);
        vm.expectRevert();
        stakedM.redistributeLockedAmount(fullRestrictedUser, user1);
    }

    // ----------- MIN_SHARES 防捐赠 -----------

    function test_MinShares_ViolationOnWithdraw() public {
        _stake(user1, 2 ether);

        // 剩余总份额将低于 MIN_SHARES(1 ether) → 拒绝
        vm.prank(user1);
        vm.expectRevert(IStakedM.MinSharesViolation.selector);
        stakedM.cooldownShares(1.5 ether, user1);
    }

    function test_MinShares_BoundaryOk() public {
        _stake(user1, 2 ether);

        // 恰好剩 1 ether，允许
        vm.prank(user1);
        stakedM.cooldownShares(1 ether, user1);

        assertEq(stakedM.totalSupply(), 1 ether);
    }

    // ----------- renounceRole / rescueTokens -----------

    function test_RenounceRole_Disabled() public {
        vm.prank(user1);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.renounceRole(SOFT_RESTRICTED_STAKER_ROLE, softRestrictedUser);

        // 受限地址也无法自行弃权
        vm.prank(softRestrictedUser);
        vm.expectRevert(IStakedM.OperationNotAllowed.selector);
        stakedM.renounceRole(SOFT_RESTRICTED_STAKER_ROLE, softRestrictedUser);
    }

    function test_RescueTokens_AssetBlocked() public {
        vm.prank(admin);
        vm.expectRevert(IStakedM.InvalidToken.selector);
        stakedM.rescueTokens(address(asset), 1 ether, admin);
    }

    function test_RescueTokens_sM() public {
        // sM 误转入金库可营救
        _stake(user1, 1000 ether);

        vm.prank(user1);
        stakedM.transfer(address(stakedM), 100 ether);

        vm.prank(admin);
        stakedM.rescueTokens(address(stakedM), 100 ether, admin);

        assertEq(stakedM.balanceOf(admin), 100 ether);
    }

    function test_RescueTokens_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedM.rescueTokens(address(stakedM), 1 ether, user1);
    }

    // ----------- ERC20Permit -----------

    function test_Permit() public {
        _stake(alice, 1000 ether);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                stakedM.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        alice,
                        spender,
                        100 ether,
                        stakedM.nonces(alice),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_KEY, digest);

        vm.prank(alice);
        stakedM.permit(alice, spender, 100 ether, deadline, v, r, s);

        assertEq(stakedM.allowance(alice, spender), 100 ether);

        // spender 可代持有人发起解质押冷却
        vm.prank(spender);
        stakedM.cooldownShares(100 ether, alice);

        assertEq(stakedM.balanceOf(alice), 900 ether);
    }

    // ----------- setCooldownDuration -----------

    function test_SetCooldownDuration() public {
        vm.prank(admin);
        vm.expectEmit();
        emit IStakedM.CooldownDurationUpdated(7 days, 30 days);
        stakedM.setCooldownDuration(30 days);

        assertEq(stakedM.cooldownDuration(), 30 days);
    }

    function test_SetCooldownDuration_MaxExceeded() public {
        vm.prank(admin);
        vm.expectRevert(IStakedM.InvalidCooldown.selector);
        stakedM.setCooldownDuration(91 days);
    }

    function test_SetCooldownDuration_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedM.setCooldownDuration(30 days);
    }

    // ----------- Silo 权限 -----------

    function test_Silo_OnlyStakingVault() public {
        _stake(user1, 1000 ether);

        vm.prank(user1);
        stakedM.cooldownShares(400 ether, user1);

        vm.prank(user1);
        vm.expectRevert(IUnstakingSilo.OnlyStakingVault.selector);
        silo.withdraw(user1, 400 ether);
    }

    // ----------- Integration: Full Flow -----------

    function test_FullFlow_DepositRewardsCooldownUnstake() public {
        // 1. 两个用户质押
        _stake(user1, 1000 ether);
        _stake(user2, 1000 ether);

        // 2. 奖励注入并完全 vest
        vm.prank(rewarder);
        stakedM.transferInRewards(200 ether);
        vm.warp(block.timestamp + 9 hours);

        // 3. user1 发起冷却
        uint256 shares = stakedM.balanceOf(user1);
        vm.prank(user1);
        uint256 assetsQueued = stakedM.cooldownShares(shares, user1);

        // 4. user2 的份额价值不被稀释（Silo 隔离生效）
        // OZ v5 virtual-share 舍入：totalAssets = supply×ratio 可差 1 wei（偏向金库）
        assertApproxEqAbs(stakedM.totalAssets(), 1100 ether, 1);
        assertApproxEqAbs(stakedM.convertToAssets(stakedM.balanceOf(user2)), 1100 ether, 1);

        // 5. 到期领取
        vm.warp(block.timestamp + 8 days);
        uint256 balanceBefore = asset.balanceOf(user1);

        vm.prank(user1);
        stakedM.unstake(user1);

        // user1 分得一半奖励：1000 本金 + 100 奖励（含 1 wei 舍入）
        assertApproxEqAbs(asset.balanceOf(user1) - balanceBefore, 1100 ether, 1);
        assertGt(assetsQueued, 1000 ether);
    }

    // ----------- ERC4626 Views -----------

    function test_PreviewDeposit() public view {
        uint256 shares = stakedM.previewDeposit(1000 ether);
        assertEq(shares, 1000 ether);
    }

    function test_MaxDeposit() public view {
        assertEq(stakedM.maxDeposit(user1), type(uint256).max);
    }

    function test_MaxRedeem() public {
        _stake(user1, 1000 ether);
        assertEq(stakedM.maxRedeem(user1), stakedM.balanceOf(user1));
    }

    function test_GetUnvestedAmount_ZeroWhenNoRewards() public view {
        assertEq(stakedM.getUnvestedAmount(), 0);
        assertEq(stakedM.totalAssets(), 0);
    }
}
