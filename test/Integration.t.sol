// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/M.sol";
import "../src/MonogramMinting.sol";
import "../src/StakedM.sol";
import "../src/StakingRewardsDistributor.sol";
import "../src/MonogramPriceFeed.sol";
import "../src/interfaces/IMonogramMinting.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Test Collateral", "TC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPriceFeed is IMonogramPriceFeed {
    function getPrice(address) external view returns (uint256 price, uint256 updatedAt) {
        return (1e18, block.timestamp);
    }

    function getPriceAndTimestamp(address asset) external view returns (uint256, uint256) {
        return this.getPrice(asset);
    }
    function setOracleConfig(address, bytes32, address, uint128, uint128) external {}
    function removeOracleConfig(address) external {}
}

contract IntegrationTest is Test {
    M public m;
    MonogramMinting public minting;
    StakedM public stakedM;
    StakingRewardsDistributor public distributor;
    MockAsset public collateral;
    MockPriceFeed public mockPriceFeed;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public redeemer = makeAddr("redeemer");
    address public rewarder = makeAddr("rewarder");
    address public operator = makeAddr("operator");
    address public beneficiary = makeAddr("beneficiary");
    address public staker;
    address public custodian = makeAddr("custodian");

    uint256 public stakerPrivateKey = 0xA11CE;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 public constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");

    bytes32 public constant ORDER_TYPE = keccak256(
        "Order(string order_id,uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant NAME_HASH = keccak256("MonogramMinting");
    bytes32 public constant VERSION_HASH = keccak256("1");

    function setUp() public {
        staker = vm.addr(stakerPrivateKey);

        vm.startPrank(admin);

        m = new M(admin);
        collateral = new MockAsset();
        mockPriceFeed = new MockPriceFeed();

        address[] memory assets = new address[](1);
        assets[0] = address(collateral);

        address[] memory custodians = new address[](1);
        custodians[0] = custodian;

        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](1);
        tokenConfigs[0] = IMonogramMinting.TokenConfig({
            isActive: true, maxMintPerBlock: 1_000_000 ether, maxRedeemPerBlock: 1_000_000 ether
        });
        IMonogramMinting.GlobalConfig memory globalConfig = IMonogramMinting.GlobalConfig({
            globalMaxMintPerBlock: 1_000_000 ether, globalMaxRedeemPerBlock: 1_000_000 ether
        });

        minting = new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(0))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            tokenConfigs,
            globalConfig,
            custodians,
            admin
        );

        m.setMinter(address(minting));

        stakedM = new StakedM(IERC20(address(m)), admin, "Staked Monogram", "sM");
        distributor = new StakingRewardsDistributor(IStakedM(address(stakedM)), IM(address(m)), admin);

        // Grant roles
        minting.grantRole(MINTER_ROLE, minter);
        minting.grantRole(REDEEMER_ROLE, redeemer);
        minting.grantRole(GATEKEEPER_ROLE, makeAddr("gatekeeper"));
        minting.grantRole(COLLATERAL_MANAGER_ROLE, makeAddr("collateralManager"));

        stakedM.grantRole(REWARDER_ROLE, address(distributor));
        distributor.grantRole(OPERATOR_ROLE, operator);

        vm.stopPrank();

        // Fund staker with collateral
        collateral.mint(staker, 10_000 ether);
        vm.prank(staker);
        collateral.approve(address(minting), type(uint256).max);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(minting)));
    }

    function _signOrder(IMonogramMinting.Order memory order) internal view returns (IMonogramMinting.Signature memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE,
                keccak256(bytes(order.order_id)),
                order.order_type,
                order.expiry,
                order.nonce,
                order.benefactor,
                order.beneficiary,
                order.collateral_asset,
                order.collateral_amount,
                order.m_amount
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stakerPrivateKey, digest);
        bytes memory sigBytes = abi.encodePacked(r, s, v);
        return
            IMonogramMinting.Signature({
                signature_type: IMonogramMinting.SignatureType.EIP712, signature_bytes: sigBytes
            });
    }

    function _singleRoute() internal view returns (IMonogramMinting.Route memory) {
        address[] memory addrs = new address[](1);
        addrs[0] = custodian;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;
        return IMonogramMinting.Route({addresses: addrs, ratios: ratios});
    }

    // ----------- Full Integration: Mint → Stake → Rewards → Unstake -----------

    function test_FullFlow_MintStakeRewardsUnstake() public {
        // 1. Mint M
        IMonogramMinting.Order memory mintOrder = IMonogramMinting.Order({
            order_id: "itx-mint-1",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: staker,
            beneficiary: staker,
            collateral_asset: address(collateral),
            collateral_amount: 100 ether,
            m_amount: 100 ether
        });

        vm.prank(minter);
        minting.mint(mintOrder, _singleRoute(), _signOrder(mintOrder));

        assertEq(m.balanceOf(staker), 100 ether);

        // 2. Stake M → sM
        vm.prank(staker);
        m.approve(address(stakedM), type(uint256).max);

        vm.prank(staker);
        stakedM.deposit(100 ether, staker);

        assertEq(stakedM.balanceOf(staker), 100 ether);
        assertEq(stakedM.totalAssets(), 100 ether);

        // 3. Distribute rewards via distributor
        // Fund operator with M and approve distributor
        vm.prank(address(minting));
        m.mint(operator, 10 ether);
        vm.prank(operator);
        m.approve(address(distributor), type(uint256).max);

        vm.prank(operator);
        distributor.distribute(10 ether);

        // 4. Wait for vesting
        vm.warp(block.timestamp + 9 hours);

        // 5. sM:M ratio increased
        uint256 assetsPerShare = stakedM.convertToAssets(1 ether);
        assertGt(assetsPerShare, 1 ether, "sM:M ratio should increase");

        // 6. Unstake
        uint256 sMBalance = stakedM.balanceOf(staker);
        vm.prank(staker);
        uint256 assets = stakedM.redeem(sMBalance, staker, staker);

        assertGt(assets, 100 ether, "should get back more than deposited");
        assertApproxEqAbs(assets, 110 ether, 1 ether);
    }

    // ----------- Distributor Interval Enforcement -----------

    function test_Distributor_TooFrequent() public {
        vm.prank(address(minting));
        m.mint(operator, 20 ether);
        vm.prank(operator);
        m.approve(address(distributor), type(uint256).max);

        vm.prank(operator);
        distributor.distribute(5 ether);

        vm.expectRevert(StakingRewardsDistributor.TooFrequent.selector);
        vm.prank(operator);
        distributor.distribute(5 ether);
    }

    function test_Distributor_AfterInterval() public {
        vm.prank(address(minting));
        m.mint(operator, 20 ether);
        vm.prank(operator);
        m.approve(address(distributor), type(uint256).max);

        vm.startPrank(operator);
        distributor.distribute(5 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.prank(operator);
        distributor.distribute(5 ether);
    }

    // ----------- Staking Rewards Integration -----------

    function test_StakingRewards_Vesting() public {
        // Stake
        vm.prank(address(minting));
        m.mint(staker, 100 ether);

        vm.startPrank(staker);
        m.approve(address(stakedM), type(uint256).max);
        stakedM.deposit(100 ether, staker);
        vm.stopPrank();

        // Distribute rewards
        vm.prank(address(minting));
        m.mint(operator, 50 ether);

        vm.startPrank(operator);
        m.approve(address(distributor), type(uint256).max);
        distributor.distribute(50 ether);
        vm.stopPrank();

        // Check vesting
        uint256 immediatelyAfter = stakedM.totalAssets();
        assertApproxEqAbs(immediatelyAfter, 100 ether, 1, "should not include unvested rewards");

        vm.warp(block.timestamp + 4 hours);
        uint256 halfVested = stakedM.totalAssets();
        assertGt(halfVested, 120 ether);
        assertLt(halfVested, 130 ether);

        vm.warp(block.timestamp + 5 hours); // total 9h past
        assertApproxEqAbs(stakedM.totalAssets(), 150 ether, 1, "should be fully vested");
    }

    // ----------- Complete Redeem Flow -----------

    function test_CompleteRedeemFlow_MintStakeRedeem() public {
        // Mint
        IMonogramMinting.Order memory mintOrder = IMonogramMinting.Order({
            order_id: "itx-mint-2",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: staker,
            beneficiary: staker,
            collateral_asset: address(collateral),
            collateral_amount: 200 ether,
            m_amount: 200 ether
        });

        vm.prank(minter);
        minting.mint(mintOrder, _singleRoute(), _signOrder(mintOrder));

        uint256 mBalance = m.balanceOf(staker);
        assertEq(mBalance, 200 ether);

        // Redeem M back to collateral
        IMonogramMinting.Order memory redeemOrder = IMonogramMinting.Order({
            order_id: "itx-redeem-1",
            order_type: IMonogramMinting.OrderType.REDEEM,
            expiry: block.timestamp + 1 hours,
            nonce: 2,
            benefactor: staker,
            beneficiary: staker,
            collateral_asset: address(collateral),
            collateral_amount: 100 ether,
            m_amount: 100 ether
        });

        // Fund contract with collateral for redemption
        collateral.mint(address(minting), 100 ether);

        vm.prank(staker);
        m.approve(address(minting), type(uint256).max);

        uint256 collateralBefore = collateral.balanceOf(staker);

        vm.prank(redeemer);
        minting.redeem(redeemOrder, _signOrder(redeemOrder));

        assertEq(collateral.balanceOf(staker), collateralBefore + 100 ether);
        assertEq(m.balanceOf(staker), mBalance - 100 ether);
    }
}
