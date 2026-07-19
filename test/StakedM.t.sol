// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/StakedM.sol";
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
    MockAsset public asset;

    address public admin = makeAddr("admin");
    address public rewarder = makeAddr("rewarder");
    address public blacklister = makeAddr("blacklister");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public restrictedUser = makeAddr("restrictedUser");
    address public softRestrictedUser = makeAddr("softRestrictedUser");

    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant SOFT_RESTRICTED_STAKER_ROLE = keccak256("SOFT_RESTRICTED_STAKER_ROLE");
    bytes32 public constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");

    function setUp() public {
        asset = new MockAsset();
        stakedM = new StakedM(IERC20(address(asset)), admin, "Staked Monogram", "sM");

        vm.startPrank(admin);
        stakedM.grantRole(REWARDER_ROLE, rewarder);
        stakedM.grantRole(BLACKLISTER_ROLE, blacklister);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, restrictedUser);
        stakedM.grantRole(SOFT_RESTRICTED_STAKER_ROLE, softRestrictedUser);
        stakedM.setCooldownDuration(7 days);
        vm.stopPrank();

        // Fund users
        asset.mint(user1, 100_000 ether);
        asset.mint(user2, 100_000 ether);
        asset.mint(rewarder, 10_000 ether);

        // Approve stakedM for all users
        vm.prank(user1);
        asset.approve(address(stakedM), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(stakedM), type(uint256).max);
        vm.prank(rewarder);
        asset.approve(address(stakedM), type(uint256).max);
    }

    // ----------- Deployment -----------

    function test_Deployment() public view {
        assertEq(stakedM.name(), "Staked Monogram");
        assertEq(stakedM.symbol(), "sM");
        assertEq(stakedM.cooldownDuration(), 7 days);
        assertEq(address(stakedM.asset()), address(asset));
    }

    // ----------- Deposit -----------

    function test_Deposit() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        assertEq(stakedM.balanceOf(user1), 1000 ether);
        assertEq(asset.balanceOf(address(stakedM)), 1000 ether);
        assertEq(stakedM.totalAssets(), 1000 ether);
    }

    function test_Deposit_Zero() public {
        // ERC4626 handles zero deposit differently (no revert, just returns 0)
        // This is acceptable behavior
        vm.prank(user1);
        uint256 shares = stakedM.deposit(0, user1);
        assertEq(shares, 0);
    }

    function test_Deposit_RestrictedUser() public {
        asset.mint(restrictedUser, 1000 ether);
        vm.prank(restrictedUser);
        asset.approve(address(stakedM), 1000 ether);

        vm.prank(restrictedUser);
        vm.expectRevert(IStakedM.RestrictedAddress.selector);
        stakedM.deposit(100 ether, restrictedUser);
    }

    function test_Deposit_SoftRestrictedUser() public {
        asset.mint(softRestrictedUser, 1000 ether);
        vm.prank(softRestrictedUser);
        asset.approve(address(stakedM), 1000 ether);

        vm.prank(softRestrictedUser);
        vm.expectRevert(IStakedM.SoftRestrictedAddress.selector);
        stakedM.deposit(100 ether, softRestrictedUser);
    }

    // ----------- Withdraw -----------

    function test_Withdraw() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        uint256 balanceBefore = asset.balanceOf(user1);
        vm.prank(user1);
        stakedM.withdraw(500 ether, user1, user1);

        assertEq(asset.balanceOf(user1), balanceBefore + 500 ether);
        assertApproxEqAbs(stakedM.balanceOf(user1), 500 ether, 1);
        assertApproxEqAbs(stakedM.totalAssets(), 500 ether, 1);
    }

    function test_Redeem() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        uint256 balanceBefore = asset.balanceOf(user1);
        vm.prank(user1);
        stakedM.redeem(500 ether, user1, user1);

        assertApproxEqAbs(asset.balanceOf(user1), balanceBefore + 500 ether, 1);
        assertApproxEqAbs(stakedM.balanceOf(user1), 500 ether, 1);
    }

    // ----------- sM:M Ratio -----------

    function test_RatioOneToOne_NoRewards() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        assertEq(stakedM.convertToAssets(1 ether), 1 ether);
        assertEq(stakedM.convertToShares(1 ether), 1 ether);
    }

    function test_RatioIncreases_WithRewards() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        // Fast forward past vesting so rewards are fully vested
        vm.warp(block.timestamp + 9 hours);

        // Add rewards
        vm.prank(rewarder);
        stakedM.transferInRewards(100 ether);

        // Fast forward again past new vesting
        vm.warp(block.timestamp + 9 hours);

        // sM:M ratio should have increased
        uint256 assetsPerShare = stakedM.convertToAssets(1 ether);
        assertGe(assetsPerShare, 1 ether);
    }

    // ----------- Rewards Vesting -----------

    function test_TransferInRewards() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        vm.prank(rewarder);
        stakedM.transferInRewards(100 ether);

        assertEq(asset.balanceOf(address(stakedM)), 1100 ether);
        // Total assets should be less than actual balance during vesting
        assertLt(stakedM.totalAssets(), 1100 ether);
    }

    function test_TransferInRewards_NotRewarder() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedM.transferInRewards(100 ether);
    }

    function test_TransferInRewards_ZeroAmount() public {
        vm.prank(rewarder);
        vm.expectRevert();
        stakedM.transferInRewards(0);
    }

    function test_Vesting_LinearIncrease() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        vm.prank(rewarder);
        stakedM.transferInRewards(800 ether);

        uint256 startTime = block.timestamp;

        // After 0 hours: totalAssets ~= 1000 (800 unvested)
        assertApproxEqAbs(stakedM.totalAssets(), 1000 ether, 1);

        // After 4 hours: totalAssets ~= 1000 + 400 = 1400
        vm.warp(startTime + 4 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1400 ether, 2);

        // After 8 hours: totalAssets = 1800 (all vested)
        vm.warp(startTime + 8 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1800 ether, 2);
    }

    function test_Vesting_MultipleRewards() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        // First reward: 100
        vm.prank(rewarder);
        stakedM.transferInRewards(100 ether);

        // Half vested: 1/2 of 100 = 50 vested
        vm.warp(block.timestamp + 4 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1050 ether, 1);

        // Second reward: 200, merges remaining 50 unvested + 200 = 250
        vm.prank(rewarder);
        stakedM.transferInRewards(200 ether);

        // Right after: totalAssets = 1000 + 50 (prev vested) + 0 (newly vested) = 1050
        assertApproxEqAbs(stakedM.totalAssets(), 1050 ether, 1);

        // After 8 hours: all 250 vested + 50 previous = 1300 total vested
        vm.warp(block.timestamp + 8 hours);
        assertApproxEqAbs(stakedM.totalAssets(), 1300 ether, 5);
    }

    // ----------- Cooldown Redemption -----------

    function test_RequestRedeem_Cooldown() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        vm.prank(user1);
        stakedM.requestRedeem(300 ether);

        assertEq(stakedM.balanceOf(user1), 700 ether);
    }

    function test_RequestRedeem_CooldownNotElapsed() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        vm.prank(user1);
        stakedM.requestRedeem(300 ether);

        vm.prank(user1);
        vm.expectRevert(IStakedM.CooldownNotElapsed.selector);
        stakedM.claimRedemption();
    }

    function test_RequestRedeem_ClaimAfterCooldown() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        vm.prank(user1);
        uint256 shares = stakedM.balanceOf(user1);

        vm.prank(user1);
        stakedM.requestRedeem(shares);

        // Fast forward past cooldown
        vm.warp(block.timestamp + 8 days);

        uint256 balanceBefore = asset.balanceOf(user1);

        vm.prank(user1);
        stakedM.claimRedemption();

        assertApproxEqAbs(asset.balanceOf(user1), balanceBefore + 1000 ether, 1);
        assertEq(stakedM.balanceOf(user1), 0);
    }

    function test_RequestRedeem_AlreadyClaimed() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        vm.prank(user1);
        uint256 shares = stakedM.balanceOf(user1);

        vm.prank(user1);
        stakedM.requestRedeem(shares);

        vm.warp(block.timestamp + 8 days);

        vm.startPrank(user1);
        stakedM.claimRedemption();

        // After claim, request is deleted. Second claim fails with empty revert (shares == 0)
        vm.expectRevert();
        stakedM.claimRedemption();
        vm.stopPrank();
    }

    // ----------- Cooldown Duration -----------

    function test_SetCooldownDuration() public {
        vm.prank(admin);
        stakedM.setCooldownDuration(30 days);
        assertEq(stakedM.cooldownDuration(), 30 days);
    }

    function test_SetCooldownDuration_MaxExceeded() public {
        vm.prank(admin);
        vm.expectRevert(IStakedM.MaxCooldownExceeded.selector);
        stakedM.setCooldownDuration(91 days);
    }

    function test_SetCooldownDuration_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedM.setCooldownDuration(30 days);
    }

    // ----------- Compliance -----------

    function test_RedistributeLockedAmount() public {
        address toRestrict = makeAddr("toRestrict");

        // Fund admin and approve
        asset.mint(admin, 1000 ether);
        vm.prank(admin);
        asset.approve(address(stakedM), type(uint256).max);

        // Mint sM directly to user before restricting
        vm.prank(admin);
        stakedM.mint(1000 ether, toRestrict);

        // Now restrict
        vm.prank(admin);
        stakedM.grantRole(FULL_RESTRICTED_STAKER_ROLE, toRestrict);

        // Blacklister redistributes
        vm.prank(blacklister);
        stakedM.redistributeLockedAmount(toRestrict, user1);

        assertEq(stakedM.balanceOf(toRestrict), 0);
        assertEq(stakedM.balanceOf(user1), 1000 ether);
    }

    function test_RedistributeLockedAmount_NotRestricted() public {
        vm.prank(blacklister);
        vm.expectRevert(IStakedM.NotRestricted.selector);
        stakedM.redistributeLockedAmount(user1, user2);
    }

    // ----------- Integration: Full Flow -----------

    function test_FullFlow_DepositRewardsWithdraw() public {
        // 1. User deposits
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        // 2. Rewards come in
        vm.prank(rewarder);
        stakedM.transferInRewards(200 ether);

        // 3. Wait for vesting
        vm.warp(block.timestamp + 9 hours);

        // 4. sM:M ratio increased
        uint256 assetsPerShare = stakedM.convertToAssets(1 ether);
        assertGe(assetsPerShare, 1 ether);

        // 5. User withdraws
        uint256 userShares = stakedM.balanceOf(user1);
        vm.prank(user1);
        uint256 assets = stakedM.redeem(userShares, user1, user1);

        // Should have more than deposited due to rewards
        assertGt(assets, 1000 ether);
    }

    // ----------- ERC4626 Views -----------

    function test_PreviewDeposit() public {
        uint256 shares = stakedM.previewDeposit(1000 ether);
        assertEq(shares, 1000 ether);
    }

    function test_MaxDeposit() public {
        assertEq(stakedM.maxDeposit(user1), type(uint256).max);
    }

    function test_MaxRedeem() public {
        vm.prank(user1);
        stakedM.deposit(1000 ether, user1);

        assertEq(stakedM.maxRedeem(user1), stakedM.balanceOf(user1));
    }
}
