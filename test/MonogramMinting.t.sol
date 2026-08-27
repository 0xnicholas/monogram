// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/M.sol";
import "../src/MonogramMinting.sol";
import "../src/WETH9.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC20WithDecimals is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPriceFeed is IMonogramPriceFeed {
    uint256 public price = 1e18;
    uint256 public updatedAt; // 0 表示使用 block.timestamp

    function setPrice(uint256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
    }

    function getPrice(address) external view returns (uint256, uint256) {
        return (price, updatedAt == 0 ? block.timestamp : updatedAt);
    }

    function getPriceAndTimestamp(address asset) external view returns (uint256, uint256) {
        return this.getPrice(asset);
    }

    function setOracleConfig(address, bytes32, address, uint128, uint128) external {}
    function removeOracleConfig(address) external {}
}

/// @notice 模拟合约钱包：持有 ECDSA signer，签名可恢复出 signer 时返回 EIP-1271 magic value
contract MockEIP1271Wallet {
    bytes4 internal constant EIP1271_MAGICVALUE = 0x1626ba7e;
    bytes4 internal constant EIP1271_INVALID_VALUE = 0xffffffff;

    address public signer;

    constructor(address _signer) {
        signer = _signer;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        address recovered = ECDSA.recover(hash, signature);
        return recovered == signer ? EIP1271_MAGICVALUE : EIP1271_INVALID_VALUE;
    }

    function approveToken(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

/// @notice 拒收原生 ETH 的合约：任何带 value 的调用都失败，用于触发 TransferFailed
contract RejectsETH {
    fallback() external payable {
        revert("RejectsETH: no ETH accepted");
    }
}

contract MonogramMintingTest is Test {
    M public m;
    WETH9 public weth;
    MockERC20 public collateral;
    MockPriceFeed public mockPriceFeed;
    MonogramMinting public minting;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public redeemer = makeAddr("redeemer");
    address public gatekeeper = makeAddr("gatekeeper");
    address public collateralManager = makeAddr("collateralManager");
    address public benefactor;
    address public beneficiary = makeAddr("beneficiary");
    address public custodian1 = makeAddr("custodian1");
    address public custodian2 = makeAddr("custodian2");
    address public user = makeAddr("user");
    address public delegate;

    uint256 public benefactorPrivateKey = 0xA11CE;
    uint256 public delegatePrivateKey = 0xB0B;
    uint256 public walletSignerPrivateKey = 0xC0FFEE;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");

    uint256 public constant MAX_MINT_PER_BLOCK = 1_000_000 ether;
    uint256 public constant MAX_REDEEM_PER_BLOCK = 1_000_000 ether;
    uint256 public constant ROUTE_REQUIRED_RATIO = 10_000;

    event Mint(
        string indexed order_id,
        address indexed benefactor,
        address indexed beneficiary,
        address minter,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

    event Redeem(
        string indexed order_id,
        address indexed benefactor,
        address indexed beneficiary,
        address redeemer,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

    event MaxMintPerBlockChanged(uint256 oldMaxMintPerBlock, uint256 newMaxMintPerBlock, address indexed asset);

    event MaxRedeemPerBlockChanged(uint256 oldMaxRedeemPerBlock, uint256 newMaxRedeemPerBlock, address indexed asset);

    function setUp() public {
        benefactor = vm.addr(benefactorPrivateKey);
        delegate = vm.addr(delegatePrivateKey);

        vm.startPrank(admin);

        m = new M(admin);
        weth = new WETH9();
        collateral = new MockERC20("Test Collateral", "TC");
        mockPriceFeed = new MockPriceFeed();

        address[] memory assets = new address[](1);
        assets[0] = address(collateral);

        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](1);
        tokenConfigs[0] = _defaultTokenConfig();

        IMonogramMinting.GlobalConfig memory globalConfig = _defaultGlobalConfig();

        address[] memory custodians = new address[](2);
        custodians[0] = custodian1;
        custodians[1] = custodian2;

        minting = new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            tokenConfigs,
            globalConfig,
            custodians,
            admin
        );

        m.setMinter(address(minting));

        minting.grantRole(MINTER_ROLE, minter);
        minting.grantRole(REDEEMER_ROLE, redeemer);
        minting.grantRole(GATEKEEPER_ROLE, gatekeeper);
        minting.grantRole(COLLATERAL_MANAGER_ROLE, collateralManager);

        vm.stopPrank();

        // Give benefactor some collateral
        collateral.mint(benefactor, 10_000 ether);
        vm.prank(benefactor);
        collateral.approve(address(minting), type(uint256).max);
    }

    function _defaultTokenConfig() internal pure returns (IMonogramMinting.TokenConfig memory) {
        return IMonogramMinting.TokenConfig({
            isActive: true, maxMintPerBlock: MAX_MINT_PER_BLOCK, maxRedeemPerBlock: MAX_REDEEM_PER_BLOCK
        });
    }

    function _defaultGlobalConfig() internal pure returns (IMonogramMinting.GlobalConfig memory) {
        return IMonogramMinting.GlobalConfig({
            globalMaxMintPerBlock: MAX_MINT_PER_BLOCK, globalMaxRedeemPerBlock: MAX_REDEEM_PER_BLOCK
        });
    }

    function _computeDomainSeparator() internal view returns (bytes32) {
        bytes32 DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 NAME_HASH = keccak256("MonogramMinting");
        bytes32 VERSION_HASH = keccak256("1");
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(minting)));
    }

    function _hashOrder(IMonogramMinting.Order memory order) internal view returns (bytes32) {
        bytes32 ORDER_TYPE = keccak256(
            "Order(string order_id,uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
        );
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
        bytes32 domainSeparator = _computeDomainSeparator();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signOrder(IMonogramMinting.Order memory order, uint256 privateKey)
        internal
        view
        returns (IMonogramMinting.Signature memory)
    {
        bytes32 digest = _hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        return
            IMonogramMinting.Signature({
                signature_type: IMonogramMinting.SignatureType.EIP712, signature_bytes: signature
            });
    }

    function _createMintOrder(uint256 nonce, uint256 collateralAmount, uint256 mAmount)
        internal
        view
        returns (IMonogramMinting.Order memory)
    {
        return IMonogramMinting.Order({
            order_id: "order-1",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: nonce,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: address(collateral),
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });
    }

    function _createRoute() internal view returns (IMonogramMinting.Route memory) {
        address[] memory addresses = new address[](2);
        addresses[0] = custodian1;
        addresses[1] = custodian2;
        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 5000;
        ratios[1] = 5000;
        return IMonogramMinting.Route({addresses: addresses, ratios: ratios});
    }

    function _createRedeemOrder(uint256 nonce, uint256 collateralAmount, uint256 mAmount)
        internal
        view
        returns (IMonogramMinting.Order memory)
    {
        return IMonogramMinting.Order({
            order_id: "order-1",
            order_type: IMonogramMinting.OrderType.REDEEM,
            expiry: block.timestamp + 1 hours,
            nonce: nonce,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: address(collateral),
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });
    }

    function _createMintWETHOrder(uint256 nonce, uint256 collateralAmount, uint256 mAmount)
        internal
        view
        returns (IMonogramMinting.Order memory)
    {
        return IMonogramMinting.Order({
            order_id: "order-weth-1",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: nonce,
            benefactor: benefactor,
            beneficiary: beneficiary,
            collateral_asset: address(weth),
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });
    }

    /// @notice 注册 WETH 为支持资产并给 benefactor 注入 WETH 余额与授权
    function _setUpWETHAsset() internal {
        vm.prank(admin);
        minting.addSupportedAsset(address(weth), _defaultTokenConfig());

        vm.deal(benefactor, 1_000 ether);
        vm.prank(benefactor);
        weth.deposit{value: 500 ether}();
        vm.prank(benefactor);
        weth.approve(address(minting), type(uint256).max);
    }

    // ----------- Deployment Tests -----------

    function test_Deployment() public view {
        assertEq(address(minting.m()), address(m));
        assertTrue(minting.isSupportedAsset(address(collateral)));
        (bool isActive, uint256 maxMintPerBlock, uint256 maxRedeemPerBlock) = minting.tokenConfig(address(collateral));
        assertTrue(isActive);
        assertEq(maxMintPerBlock, MAX_MINT_PER_BLOCK);
        assertEq(maxRedeemPerBlock, MAX_REDEEM_PER_BLOCK);
        (uint256 globalMaxMintPerBlock, uint256 globalMaxRedeemPerBlock) = minting.globalConfig();
        assertEq(globalMaxMintPerBlock, MAX_MINT_PER_BLOCK);
        assertEq(globalMaxRedeemPerBlock, MAX_REDEEM_PER_BLOCK);
        assertTrue(minting.hasRole(MINTER_ROLE, minter));
        assertTrue(minting.hasRole(REDEEMER_ROLE, redeemer));
        assertTrue(minting.hasRole(GATEKEEPER_ROLE, gatekeeper));
    }

    function test_Deployment_ZeroMAddress() public {
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](1);
        tokenConfigs[0] = _defaultTokenConfig();
        address[] memory custodians = new address[](0);

        vm.expectRevert(IMonogramMinting.InvalidMAddress.selector);
        new MonogramMinting(
            IM(address(0)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            tokenConfigs,
            _defaultGlobalConfig(),
            custodians,
            admin
        );
    }

    function test_Deployment_NoAssets() public {
        address[] memory assets = new address[](0);
        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](0);
        address[] memory custodians = new address[](0);

        vm.expectRevert(IMonogramMinting.NoAssetsProvided.selector);
        new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            tokenConfigs,
            _defaultGlobalConfig(),
            custodians,
            admin
        );
    }

    function test_Deployment_MismatchedConfigLengths() public {
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](0);
        address[] memory custodians = new address[](0);

        vm.expectRevert(IMonogramMinting.InvalidAssetAddress.selector);
        new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            tokenConfigs,
            _defaultGlobalConfig(),
            custodians,
            admin
        );
    }

    function test_Deployment_ZeroTokenConfigLimit() public {
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](1);
        tokenConfigs[0] =
            IMonogramMinting.TokenConfig({isActive: true, maxMintPerBlock: 0, maxRedeemPerBlock: MAX_REDEEM_PER_BLOCK});
        address[] memory custodians = new address[](0);

        vm.expectRevert(IMonogramMinting.InvalidAmount.selector);
        new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            tokenConfigs,
            _defaultGlobalConfig(),
            custodians,
            admin
        );
    }

    // ----------- Role Management -----------

    function test_GrantRole() public {
        vm.prank(admin);
        minting.grantRole(MINTER_ROLE, user);
        assertTrue(minting.hasRole(MINTER_ROLE, user));
    }

    function test_GrantRole_NotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        minting.grantRole(MINTER_ROLE, user);
    }

    function test_RevokeRole() public {
        vm.startPrank(admin);
        minting.revokeRole(MINTER_ROLE, minter);
        vm.stopPrank();
        assertFalse(minting.hasRole(MINTER_ROLE, minter));
    }

    // ----------- Asset Management -----------

    function test_AddSupportedAsset() public {
        address newAsset = makeAddr("newAsset");
        vm.prank(admin);
        minting.addSupportedAsset(newAsset, _defaultTokenConfig());
        assertTrue(minting.isSupportedAsset(newAsset));
    }

    function test_AddSupportedAsset_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.InvalidAssetAddress.selector);
        minting.addSupportedAsset(address(0), _defaultTokenConfig());
    }

    function test_AddSupportedAsset_Duplicate() public {
        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.InvalidAssetAddress.selector);
        minting.addSupportedAsset(address(collateral), _defaultTokenConfig());
    }

    function test_RemoveSupportedAsset() public {
        vm.prank(admin);
        minting.removeSupportedAsset(address(collateral));
        assertFalse(minting.isSupportedAsset(address(collateral)));
    }

    function test_RemoveSupportedAsset_NotExists() public {
        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.InvalidAssetAddress.selector);
        minting.removeSupportedAsset(makeAddr("nonexistent"));
    }

    // ----------- Custodian Management -----------

    function test_AddCustodianAddress() public {
        address newCustodian = makeAddr("newCustodian");
        vm.prank(admin);
        minting.addCustodianAddress(newCustodian);
    }

    function test_RemoveCustodianAddress() public {
        vm.prank(admin);
        minting.removeCustodianAddress(custodian1);
    }

    // ----------- Mint -----------

    function test_Mint() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        uint256 benefactorCollateralBefore = collateral.balanceOf(benefactor);
        uint256 benefactorMBalanceBefore = m.balanceOf(benefactor);

        vm.prank(minter);
        minting.mint(order, route, sig);

        assertEq(collateral.balanceOf(benefactor), benefactorCollateralBefore - 100 ether);
        assertEq(m.balanceOf(benefactor), benefactorMBalanceBefore + 100 ether);
        (uint256 mintedPerBlock,) = minting.totalPerBlock(block.number);
        assertEq(mintedPerBlock, 100 ether);
    }

    function test_Mint_InvalidOrderType() public {
        IMonogramMinting.Order memory order = _createRedeemOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidOrder.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_NotMinter() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(user);
        vm.expectRevert();
        minting.mint(order, route, sig);
    }

    function test_Mint_ExpiredSignature() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        order.expiry = block.timestamp - 1;
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.SignatureExpired.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_InvalidSignature() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, delegatePrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidEIP712Signature.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_SingleCustodianFullRoute() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        // 单 custodian + ratio 10000 是合法路由：全额路由给单一托管地址
        assertTrue(minting.verifyRoute(_singleCustodianRoute()));

        uint256 custodian1CollateralBefore = collateral.balanceOf(custodian1);
        uint256 custodian2CollateralBefore = collateral.balanceOf(custodian2);
        uint256 benefactorMBalanceBefore = m.balanceOf(benefactor);

        vm.prank(minter);
        minting.mint(order, _singleCustodianRoute(), sig);

        assertEq(collateral.balanceOf(custodian1), custodian1CollateralBefore + 100 ether);
        assertEq(collateral.balanceOf(custodian2), custodian2CollateralBefore);
        assertEq(m.balanceOf(benefactor), benefactorMBalanceBefore + 100 ether);
    }

    function _singleCustodianRoute() internal view returns (IMonogramMinting.Route memory) {
        address[] memory addresses = new address[](1);
        addresses[0] = custodian1;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;
        return IMonogramMinting.Route({addresses: addresses, ratios: ratios});
    }

    function test_Mint_InvalidRoute_BadRatio() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        address[] memory addresses = new address[](2);
        addresses[0] = custodian1;
        addresses[1] = custodian2;
        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 3000;
        ratios[1] = 3000; // total 6000 != 10000
        IMonogramMinting.Route memory route = IMonogramMinting.Route({addresses: addresses, ratios: ratios});

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidRoute.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_InvalidRoute_ZeroRatio() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        address[] memory addresses = new address[](2);
        addresses[0] = custodian1;
        addresses[1] = custodian2;
        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 10_000;
        ratios[1] = 0; // 单项 ratio 为 0 视为非法路由
        IMonogramMinting.Route memory route = IMonogramMinting.Route({addresses: addresses, ratios: ratios});

        assertFalse(minting.verifyRoute(route));

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidRoute.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_ReplayAttack() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.startPrank(minter);
        minting.mint(order, route, sig);

        vm.expectRevert(IMonogramMinting.InvalidNonce.selector);
        minting.mint(order, route, sig);
        vm.stopPrank();
    }

    function test_Mint_MultipleNonces() public {
        IMonogramMinting.Route memory route = _createRoute();

        for (uint256 i = 1; i <= 5; i++) {
            IMonogramMinting.Order memory order = _createMintOrder(i, 10 ether, 10 ether);
            IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

            vm.prank(minter);
            minting.mint(order, route, sig);
        }

        assertEq(m.balanceOf(benefactor), 50 ether);
        (uint256 mintedPerBlock,) = minting.totalPerBlock(block.number);
        assertEq(mintedPerBlock, 50 ether);
    }

    // ----------- Price Validation -----------

    function test_Mint_SixDecimalsCollateral() public {
        // 6 位小数抵押品（类 USDC），价格 $1：100e6 = $100，应铸出 100 M
        MockERC20WithDecimals usdc = new MockERC20WithDecimals("USD Coin", "USDC", 6);
        vm.prank(admin);
        minting.addSupportedAsset(address(usdc), _defaultTokenConfig());
        usdc.mint(benefactor, 10_000e6);
        vm.prank(benefactor);
        usdc.approve(address(minting), type(uint256).max);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_id: "order-1",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: address(usdc),
            collateral_amount: 100e6,
            m_amount: 100 ether
        });
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        minting.mint(order, route, sig);

        assertEq(m.balanceOf(benefactor), 100 ether);
        assertEq(usdc.balanceOf(custodian1), 50e6);
        assertEq(usdc.balanceOf(custodian2), 50e6);
    }

    function test_Mint_StalePrice() public {
        vm.warp(10_000);
        mockPriceFeed.setPrice(1e18, block.timestamp - 3601);

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.StalePrice.selector);
        minting.mint(order, route, sig);
    }

    // ----------- Order Validation -----------

    function test_Mint_ZeroBeneficiary() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        order.beneficiary = address(0);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidAddress.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_ZeroCollateralAmount() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 0, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidAmount.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_ZeroMAmount() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 0);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidAmount.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_ZeroNonce() public {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidNonce.selector);
        minting.mint(order, route, sig);
    }

    // ----------- Per-Block Limits -----------

    function test_Mint_MaxMintPerBlockExceeded() public {
        // 调低单资产限额，global 限额保持高位
        vm.prank(admin);
        minting.setMaxMintPerBlock(50 ether, address(collateral));

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.MaxMintPerBlockExceeded.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_GlobalMaxMintPerBlockExceeded() public {
        vm.prank(admin);
        minting.setGlobalMaxMintPerBlock(50 ether);

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.GlobalMaxMintPerBlockExceeded.selector);
        minting.mint(order, route, sig);
    }

    // ----------- MintWETH Tests -----------

    function test_MintWETH() public {
        _setUpWETHAsset();

        IMonogramMinting.Order memory order = _createMintWETHOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        uint256 benefactorWETHBefore = weth.balanceOf(benefactor);
        uint256 custodian1ETHBefore = custodian1.balance;
        uint256 custodian2ETHBefore = custodian2.balance;

        vm.prank(minter);
        minting.mintWETH(order, route, sig);

        // benefactor 失去 WETH，beneficiary 收到 M
        assertEq(weth.balanceOf(benefactor), benefactorWETHBefore - 100 ether);
        assertEq(m.balanceOf(beneficiary), 100 ether);
        // custodian 收到原生 ETH（50/50），Minting 合约不残留 ETH
        assertEq(custodian1.balance, custodian1ETHBefore + 50 ether);
        assertEq(custodian2.balance, custodian2ETHBefore + 50 ether);
        assertEq(address(minting).balance, 0);
        // per-block 记账：单资产 + 全局
        (uint256 mintedPerAsset,) = minting.totalPerBlockPerAsset(block.number, address(weth));
        assertEq(mintedPerAsset, 100 ether);
        (uint256 mintedPerBlock,) = minting.totalPerBlock(block.number);
        assertEq(mintedPerBlock, 100 ether);
    }

    function test_MintWETH_UnsupportedAsset() public {
        _setUpWETHAsset();

        // collateral 已注册但不是 WETH：路径校验失败
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.UnsupportedAsset.selector);
        minting.mintWETH(order, route, sig);
    }

    function test_MintWETH_UnregisteredWETH() public {
        // WETH 未注册为支持资产：限额修饰符先行 revert UnsupportedAsset
        IMonogramMinting.Order memory order = _createMintWETHOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.UnsupportedAsset.selector);
        minting.mintWETH(order, route, sig);
    }

    function test_MintWETH_PerBlockLimitAccounting() public {
        _setUpWETHAsset();

        // 调低 WETH 单资产限额
        vm.prank(admin);
        minting.setMaxMintPerBlock(10 ether, address(weth));

        IMonogramMinting.Order memory order1 = _createMintWETHOrder(1, 6 ether, 6 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig1 = _signOrder(order1, benefactorPrivateKey);

        vm.prank(minter);
        minting.mintWETH(order1, route, sig1);

        // 第一笔入账 6 ether，第二笔 6 ether 累计 12 > 10 触发限额
        (uint256 mintedPerAsset,) = minting.totalPerBlockPerAsset(block.number, address(weth));
        assertEq(mintedPerAsset, 6 ether);

        IMonogramMinting.Order memory order2 = _createMintWETHOrder(2, 6 ether, 6 ether);
        IMonogramMinting.Signature memory sig2 = _signOrder(order2, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.MaxMintPerBlockExceeded.selector);
        minting.mintWETH(order2, route, sig2);
    }

    function test_MintWETH_RouteProportionalDistribution() public {
        _setUpWETHAsset();

        // 30/70 分发
        IMonogramMinting.Order memory order = _createMintWETHOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        route.ratios[0] = 3000;
        route.ratios[1] = 7000;
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        uint256 custodian1ETHBefore = custodian1.balance;
        uint256 custodian2ETHBefore = custodian2.balance;

        vm.prank(minter);
        minting.mintWETH(order, route, sig);

        assertEq(custodian1.balance, custodian1ETHBefore + 30 ether);
        assertEq(custodian2.balance, custodian2ETHBefore + 70 ether);
    }

    function test_MintWETH_RouteRemainderToLastCustodian() public {
        _setUpWETHAsset();

        // 3 wei 按比例 50/50 各得 1 wei，余 1 wei 归最后一个 custodian
        IMonogramMinting.Order memory order = _createMintWETHOrder(1, 3, 3);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        uint256 custodian1ETHBefore = custodian1.balance;
        uint256 custodian2ETHBefore = custodian2.balance;

        vm.prank(minter);
        minting.mintWETH(order, route, sig);

        assertEq(custodian1.balance, custodian1ETHBefore + 1);
        assertEq(custodian2.balance, custodian2ETHBefore + 2);
        assertEq(address(minting).balance, 0);
    }

    function test_MintWETH_TransferFailed() public {
        _setUpWETHAsset();

        // 注册拒收 ETH 的 custodian 并路由给它
        RejectsETH rejector = new RejectsETH();
        vm.prank(admin);
        minting.addCustodianAddress(address(rejector));

        IMonogramMinting.Order memory order = _createMintWETHOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        route.addresses[0] = address(rejector);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        uint256 benefactorWETHBefore = weth.balanceOf(benefactor);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.TransferFailed.selector);
        minting.mintWETH(order, route, sig);

        // revert 后状态完全回滚
        assertEq(weth.balanceOf(benefactor), benefactorWETHBefore);
        assertEq(m.balanceOf(beneficiary), 0);
    }

    function test_Redeem_MaxRedeemPerBlockExceeded() public {
        vm.prank(admin);
        minting.setMaxRedeemPerBlock(50 ether, address(collateral));

        IMonogramMinting.Order memory order = _createRedeemOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(redeemer);
        vm.expectRevert(IMonogramMinting.MaxRedeemPerBlockExceeded.selector);
        minting.redeem(order, sig);
    }

    function test_Redeem_GlobalMaxRedeemPerBlockExceeded() public {
        vm.prank(admin);
        minting.setGlobalMaxRedeemPerBlock(50 ether);

        IMonogramMinting.Order memory order = _createRedeemOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(redeemer);
        vm.expectRevert(IMonogramMinting.GlobalMaxRedeemPerBlockExceeded.selector);
        minting.redeem(order, sig);
    }

    // ----------- Redeem -----------

    function test_Redeem() public {
        // First mint to have M to redeem
        IMonogramMinting.Order memory mintOrder = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory mintSig = _signOrder(mintOrder, benefactorPrivateKey);
        vm.prank(minter);
        minting.mint(mintOrder, route, mintSig);

        // Approve M burning
        vm.prank(benefactor);
        m.approve(address(minting), type(uint256).max);

        // Send collateral to contract for redeem
        collateral.mint(address(minting), 100 ether);

        IMonogramMinting.Order memory redeemOrder = _createRedeemOrder(2, 100 ether, 100 ether);
        IMonogramMinting.Signature memory redeemSig = _signOrder(redeemOrder, benefactorPrivateKey);

        uint256 benefactorCollateralBefore = collateral.balanceOf(benefactor);
        uint256 benefactorMBalanceBefore = m.balanceOf(benefactor);

        vm.prank(redeemer);
        minting.redeem(redeemOrder, redeemSig);

        assertEq(collateral.balanceOf(benefactor), benefactorCollateralBefore + 100 ether);
        assertEq(m.balanceOf(benefactor), benefactorMBalanceBefore - 100 ether);
        (, uint256 redeemedPerBlock) = minting.totalPerBlock(block.number);
        assertEq(redeemedPerBlock, 100 ether);
    }

    function test_Redeem_NotRedeemer() public {
        IMonogramMinting.Order memory order = _createRedeemOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(user);
        vm.expectRevert();
        minting.redeem(order, sig);
    }

    // ----------- Gatekeeper -----------

    function test_DisableMintRedeem() public {
        vm.prank(gatekeeper);
        minting.disableMintRedeem();

        // 只清零 global 限额，单资产限额保持不变
        (uint256 globalMaxMintPerBlock, uint256 globalMaxRedeemPerBlock) = minting.globalConfig();
        assertEq(globalMaxMintPerBlock, 0);
        assertEq(globalMaxRedeemPerBlock, 0);
        (bool isActive, uint256 maxMintPerBlock, uint256 maxRedeemPerBlock) = minting.tokenConfig(address(collateral));
        assertTrue(isActive);
        assertEq(maxMintPerBlock, MAX_MINT_PER_BLOCK);
        assertEq(maxRedeemPerBlock, MAX_REDEEM_PER_BLOCK);
    }

    function test_GatekeeperRemoveMinterRole() public {
        vm.prank(gatekeeper);
        minting.removeMinterRole(minter);
        assertFalse(minting.hasRole(MINTER_ROLE, minter));
    }

    function test_GatekeeperRemoveRedeemerRole() public {
        vm.prank(gatekeeper);
        minting.removeRedeemerRole(redeemer);
        assertFalse(minting.hasRole(REDEEMER_ROLE, redeemer));
    }

    function test_GatekeeperRemoveCollateralManagerRole() public {
        vm.prank(gatekeeper);
        minting.removeCollateralManagerRole(collateralManager);
        assertFalse(minting.hasRole(COLLATERAL_MANAGER_ROLE, collateralManager));
    }

    // ----------- Delegated Signer -----------

    function test_SetDelegatedSigner() public {
        vm.prank(benefactor);
        minting.setDelegatedSigner(delegate);
    }

    function test_ConfirmDelegatedSigner() public {
        vm.prank(benefactor);
        minting.setDelegatedSigner(delegate);

        vm.prank(delegate);
        minting.confirmDelegatedSigner(benefactor);
    }

    function test_ConfirmDelegatedSigner_NotPending() public {
        vm.prank(delegate);
        vm.expectRevert(IMonogramMinting.DelegationNotInitiated.selector);
        minting.confirmDelegatedSigner(benefactor);
    }

    function test_RemoveDelegatedSigner() public {
        vm.prank(benefactor);
        minting.setDelegatedSigner(delegate);

        vm.prank(benefactor);
        minting.removeDelegatedSigner(delegate);
    }

    // ----------- EIP-1271 -----------

    function test_VerifyOrder_EIP1271() public {
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(vm.addr(walletSignerPrivateKey));

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        order.benefactor = address(wallet);
        order.beneficiary = address(wallet);
        IMonogramMinting.Signature memory sig = _signOrder(order, walletSignerPrivateKey);
        sig.signature_type = IMonogramMinting.SignatureType.EIP1271;

        bytes32 hash = minting.verifyOrder(order, sig);
        assertEq(hash, minting.hashOrder(order));
    }

    function test_VerifyOrder_EIP1271_Invalid() public {
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(vm.addr(walletSignerPrivateKey));

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        order.benefactor = address(wallet);
        order.beneficiary = address(wallet);
        // 用错误的私钥签名，钱包恢复出的 signer 不匹配
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);
        sig.signature_type = IMonogramMinting.SignatureType.EIP1271;

        vm.expectRevert(IMonogramMinting.InvalidEIP1271Signature.selector);
        minting.verifyOrder(order, sig);
    }

    function test_Mint_EIP1271() public {
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(vm.addr(walletSignerPrivateKey));
        collateral.mint(address(wallet), 1000 ether);
        wallet.approveToken(IERC20(address(collateral)), address(minting), type(uint256).max);

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        order.benefactor = address(wallet);
        order.beneficiary = address(wallet);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, walletSignerPrivateKey);
        sig.signature_type = IMonogramMinting.SignatureType.EIP1271;

        vm.prank(minter);
        minting.mint(order, route, sig);

        assertEq(m.balanceOf(address(wallet)), 100 ether);
        assertEq(collateral.balanceOf(custodian1), 50 ether);
        assertEq(collateral.balanceOf(custodian2), 50 ether);
    }

    // ----------- Whitelist -----------

    function test_Whitelist_DefaultOff() public {
        assertFalse(minting.whitelistEnabled());

        // 默认关闭：未白名单的 benefactor 也可正常 mint
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        minting.mint(order, route, sig);

        assertEq(m.balanceOf(benefactor), 100 ether);
    }

    function test_Whitelist_Enabled_BenefactorNotWhitelisted() public {
        vm.prank(admin);
        minting.setWhitelistEnabled(true);

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.BenefactorNotWhitelisted.selector);
        minting.mint(order, route, sig);
    }

    function test_Whitelist_WhitelistedBenefactor_MintToSelf() public {
        vm.startPrank(admin);
        minting.setWhitelistEnabled(true);
        minting.addWhitelistedBenefactor(benefactor);
        vm.stopPrank();

        assertTrue(minting.isWhitelistedBenefactor(benefactor));

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        minting.mint(order, route, sig);

        assertEq(m.balanceOf(benefactor), 100 ether);
    }

    function test_Whitelist_BeneficiaryNotApproved() public {
        vm.startPrank(admin);
        minting.setWhitelistEnabled(true);
        minting.addWhitelistedBenefactor(benefactor);
        vm.stopPrank();

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        order.beneficiary = beneficiary;
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.BeneficiaryNotApproved.selector);
        minting.mint(order, route, sig);

        // benefactor 批准 beneficiary 后可 mint（换 nonce 避免重放）
        vm.prank(benefactor);
        minting.setApprovedBeneficiary(beneficiary, true);
        assertTrue(minting.isApprovedBeneficiary(benefactor, beneficiary));

        IMonogramMinting.Order memory order2 = _createMintOrder(2, 100 ether, 100 ether);
        order2.beneficiary = beneficiary;
        IMonogramMinting.Signature memory sig2 = _signOrder(order2, benefactorPrivateKey);

        vm.prank(minter);
        minting.mint(order2, route, sig2);

        assertEq(m.balanceOf(beneficiary), 100 ether);
    }

    function test_Whitelist_RemoveBenefactor() public {
        vm.startPrank(admin);
        minting.setWhitelistEnabled(true);
        minting.addWhitelistedBenefactor(benefactor);
        minting.removeWhitelistedBenefactor(benefactor);
        vm.stopPrank();

        assertFalse(minting.isWhitelistedBenefactor(benefactor));

        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.BenefactorNotWhitelisted.selector);
        minting.mint(order, route, sig);
    }

    function test_Whitelist_Enable_AlreadyEnabled() public {
        vm.prank(admin);
        minting.setWhitelistEnabled(true);

        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.WhitelistAlreadyEnabled.selector);
        minting.setWhitelistEnabled(true);
    }

    function test_Whitelist_Disable_Reverts() public {
        // 部署态即为 false，传 false 无场景且被拒绝
        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.WhitelistDisableNotSupported.selector);
        minting.setWhitelistEnabled(false);

        // 启用后同样无法关闭（单向棘轮，#11 决议）
        vm.prank(admin);
        minting.setWhitelistEnabled(true);

        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.WhitelistDisableNotSupported.selector);
        minting.setWhitelistEnabled(false);

        assertTrue(minting.whitelistEnabled());
    }

    function test_Whitelist_Enable_OnlyAdmin() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, bytes32(0))
        );
        minting.setWhitelistEnabled(true);
    }

    function test_SetApprovedBeneficiary_RemoveApproval() public {
        vm.startPrank(benefactor);
        minting.setApprovedBeneficiary(beneficiary, true);
        assertTrue(minting.isApprovedBeneficiary(benefactor, beneficiary));

        minting.setApprovedBeneficiary(beneficiary, false);
        assertFalse(minting.isApprovedBeneficiary(benefactor, beneficiary));
        vm.stopPrank();
    }

    function test_SetApprovedBeneficiary_AddTwice() public {
        vm.startPrank(benefactor);
        minting.setApprovedBeneficiary(beneficiary, true);
        vm.expectRevert(IMonogramMinting.InvalidBeneficiaryAddress.selector);
        minting.setApprovedBeneficiary(beneficiary, true);
        vm.stopPrank();
    }

    function test_SetApprovedBeneficiary_RemoveNotApproved() public {
        vm.prank(benefactor);
        vm.expectRevert(IMonogramMinting.InvalidBeneficiaryAddress.selector);
        minting.setApprovedBeneficiary(beneficiary, false);
    }

    // ----------- Transfer to Custody -----------

    function test_TransferToCustody() public {
        collateral.mint(address(minting), 100 ether);

        uint256 custodianBalanceBefore = collateral.balanceOf(custodian1);

        vm.prank(collateralManager);
        minting.transferToCustody(custodian1, address(collateral), 100 ether);

        assertEq(collateral.balanceOf(custodian1), custodianBalanceBefore + 100 ether);
    }

    function test_TransferToCustody_NotManager() public {
        vm.prank(user);
        vm.expectRevert();
        minting.transferToCustody(custodian1, address(collateral), 100 ether);
    }

    function test_TransferToCustody_InvalidCustodian() public {
        vm.prank(collateralManager);
        vm.expectRevert(IMonogramMinting.InvalidAddress.selector);
        minting.transferToCustody(user, address(collateral), 100 ether);
    }

    // ----------- Route Verification -----------

    function test_VerifyRoute_EmptyAddresses() public view {
        address[] memory addresses = new address[](0);
        uint256[] memory ratios = new uint256[](0);
        IMonogramMinting.Route memory route = IMonogramMinting.Route({addresses: addresses, ratios: ratios});
        assertFalse(minting.verifyRoute(route));
    }

    function test_VerifyRoute_MismatchedLengths() public view {
        address[] memory addresses = new address[](2);
        addresses[0] = custodian1;
        addresses[1] = custodian2;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;
        IMonogramMinting.Route memory route = IMonogramMinting.Route({addresses: addresses, ratios: ratios});
        assertFalse(minting.verifyRoute(route));
    }

    function test_VerifyRoute_NonCustodian() public view {
        address[] memory addresses = new address[](1);
        addresses[0] = user;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;
        IMonogramMinting.Route memory route = IMonogramMinting.Route({addresses: addresses, ratios: ratios});
        assertFalse(minting.verifyRoute(route));
    }

    // ----------- Nonce Verification -----------

    function test_VerifyNonce() public view {
        (uint256 slot, uint256 invalidator, uint256 invalidatorBit) = minting.verifyNonce(benefactor, 5);
        assertEq(slot, 0); // 5 >> 8 = 0
        assertEq(invalidator, 0); // not yet used
        assertEq(invalidatorBit, 1 << 5); // 32
    }

    function test_VerifyNonce_ZeroNonce() public {
        vm.expectRevert(IMonogramMinting.InvalidNonce.selector);
        minting.verifyNonce(benefactor, 0);
    }

    function test_VerifyNonce_LargeNonce() public view {
        (uint256 slot, uint256 invalidator, uint256 invalidatorBit) = minting.verifyNonce(benefactor, 300);
        assertEq(slot, 1); // 300 >> 8 = 1
        assertEq(invalidator, 0);
        assertEq(invalidatorBit, 1 << (300 & 0xFF)); // 1 << 44
    }

    // ----------- Set Limits -----------

    function test_SetMaxMintPerBlock() public {
        vm.expectEmit(true, true, true, true, address(minting));
        emit MaxMintPerBlockChanged(MAX_MINT_PER_BLOCK, 5000 ether, address(collateral));

        vm.prank(admin);
        minting.setMaxMintPerBlock(5000 ether, address(collateral));

        (, uint256 maxMintPerBlock,) = minting.tokenConfig(address(collateral));
        assertEq(maxMintPerBlock, 5000 ether);
    }

    function test_SetMaxRedeemPerBlock() public {
        vm.expectEmit(true, true, true, true, address(minting));
        emit MaxRedeemPerBlockChanged(MAX_REDEEM_PER_BLOCK, 5000 ether, address(collateral));

        vm.prank(admin);
        minting.setMaxRedeemPerBlock(5000 ether, address(collateral));

        (,, uint256 maxRedeemPerBlock) = minting.tokenConfig(address(collateral));
        assertEq(maxRedeemPerBlock, 5000 ether);
    }

    function test_SetGlobalMaxMintPerBlock() public {
        vm.prank(admin);
        minting.setGlobalMaxMintPerBlock(5000 ether);

        (uint256 globalMaxMintPerBlock,) = minting.globalConfig();
        assertEq(globalMaxMintPerBlock, 5000 ether);
    }

    function test_SetGlobalMaxRedeemPerBlock() public {
        vm.prank(admin);
        minting.setGlobalMaxRedeemPerBlock(5000 ether);

        (, uint256 globalMaxRedeemPerBlock) = minting.globalConfig();
        assertEq(globalMaxRedeemPerBlock, 5000 ether);
    }

    function test_SetMaxMintPerBlock_NotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        minting.setMaxMintPerBlock(5000 ether, address(collateral));
    }

    // ----------- Hash / Encode Order -----------

    function test_HashOrder() public view {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        bytes32 hash = minting.hashOrder(order);
        assertTrue(hash != bytes32(0));
        assertEq(hash, _hashOrder(order));
    }

    function test_HashOrder_DifferentOrderId() public view {
        IMonogramMinting.Order memory order1 = _createMintOrder(1, 100 ether, 100 ether);
        order1.order_id = "order-1";
        IMonogramMinting.Order memory order2 = _createMintOrder(1, 100 ether, 100 ether);
        order2.order_id = "order-2";

        assertTrue(minting.hashOrder(order1) != minting.hashOrder(order2));
    }

    function test_Mint_EmitsOrderId() public {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        order.order_id = "order-42";
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.expectEmit(true, true, true, true, address(minting));
        emit Mint("order-42", benefactor, benefactor, minter, address(collateral), 100 ether, 100 ether);

        vm.prank(minter);
        minting.mint(order, route, sig);
    }

    function test_EncodeOrder() public view {
        IMonogramMinting.Order memory order = _createMintOrder(1, 100 ether, 100 ether);
        bytes memory encoded = minting.encodeOrder(order);
        assertTrue(encoded.length > 0);
    }
}
