// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/M.sol";
import "../src/MonogramMinting.sol";
import "../src/WETH9.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");

    uint256 public constant MAX_MINT_PER_BLOCK = 1_000_000 ether;
    uint256 public constant MAX_REDEEM_PER_BLOCK = 1_000_000 ether;
    uint256 public constant ROUTE_REQUIRED_RATIO = 10_000;

    event Mint(
        address indexed minter,
        address indexed benefactor,
        address indexed beneficiary,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

    event Redeem(
        address indexed redeemer,
        address indexed benefactor,
        address indexed beneficiary,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

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

        address[] memory custodians = new address[](2);
        custodians[0] = custodian1;
        custodians[1] = custodian2;

        minting = new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            custodians,
            admin,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
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

    function _computeDomainSeparator() internal view returns (bytes32) {
        bytes32 DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 NAME_HASH = keccak256("MonogramMinting");
        bytes32 VERSION_HASH = keccak256("1");
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(minting)));
    }

    function _hashOrder(IMonogramMinting.Order memory order) internal view returns (bytes32) {
        bytes32 ORDER_TYPE = keccak256(
            "Order(uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE,
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
        return IMonogramMinting.Signature({
            signature_type: IMonogramMinting.SignatureType.EIP712,
            signature_bytes: signature
        });
    }

    function _createMintOrder(uint256 nonce, uint256 collateralAmount, uint256 mAmount)
        internal
        view
        returns (IMonogramMinting.Order memory)
    {
        return IMonogramMinting.Order({
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

    // ----------- Deployment Tests -----------

    function test_Deployment() public view {
        assertEq(address(minting.m()), address(m));
        assertTrue(minting.isSupportedAsset(address(collateral)));
        assertEq(minting.maxMintPerBlock(), MAX_MINT_PER_BLOCK);
        assertEq(minting.maxRedeemPerBlock(), MAX_REDEEM_PER_BLOCK);
        assertTrue(minting.hasRole(MINTER_ROLE, minter));
        assertTrue(minting.hasRole(REDEEMER_ROLE, redeemer));
        assertTrue(minting.hasRole(GATEKEEPER_ROLE, gatekeeper));
    }

    function test_Deployment_ZeroMAddress() public {
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        address[] memory custodians = new address[](0);

        vm.expectRevert(IMonogramMinting.InvalidMAddress.selector);
        new MonogramMinting(
            IM(address(0)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            custodians,
            admin,
            1000,
            1000
        );
    }

    function test_Deployment_NoAssets() public {
        address[] memory assets = new address[](0);
        address[] memory custodians = new address[](0);

        vm.expectRevert(IMonogramMinting.NoAssetsProvided.selector);
        new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(weth))),
            IMonogramPriceFeed(address(mockPriceFeed)),
            assets,
            custodians,
            admin,
            1000,
            1000
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
        minting.addSupportedAsset(newAsset);
        assertTrue(minting.isSupportedAsset(newAsset));
    }

    function test_AddSupportedAsset_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.InvalidZeroAddress.selector);
        minting.addSupportedAsset(address(0));
    }

    function test_AddSupportedAsset_Duplicate() public {
        vm.prank(admin);
        vm.expectRevert(IMonogramMinting.InvalidAssetAddress.selector);
        minting.addSupportedAsset(address(collateral));
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
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        uint256 benefactorCollateralBefore = collateral.balanceOf(benefactor);
        uint256 benefactorMBalanceBefore = m.balanceOf(benefactor);

        vm.prank(minter);
        minting.mint(order, route, sig);

        assertEq(collateral.balanceOf(benefactor), benefactorCollateralBefore - 100 ether);
        assertEq(m.balanceOf(benefactor), benefactorMBalanceBefore + 100 ether);
        assertEq(minting.mintedPerBlock(block.number), 100 ether);
    }

    function test_Mint_InvalidOrderType() public {
        IMonogramMinting.Order memory order = _createRedeemOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidOrder.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_NotMinter() public {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(user);
        vm.expectRevert();
        minting.mint(order, route, sig);
    }

    function test_Mint_ExpiredSignature() public {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        order.expiry = block.timestamp - 1;
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.SignatureExpired.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_InvalidSignature() public {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, delegatePrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidSignature.selector);
        minting.mint(order, route, sig);
    }

    function test_Mint_InvalidRoute() public {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        // Route with only one custodian but ratio 10000
        address[] memory addresses = new address[](1);
        addresses[0] = custodian1;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;
        IMonogramMinting.Route memory route = IMonogramMinting.Route({addresses: addresses, ratios: ratios});

        vm.prank(minter);
        minting.mint(order, route, sig);
    }

    function test_Mint_InvalidRoute_BadRatio() public {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
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

    function test_Mint_ReplayAttack() public {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
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

        for (uint256 i = 0; i < 5; i++) {
            IMonogramMinting.Order memory order = _createMintOrder(i, 10 ether, 10 ether);
            IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

            vm.prank(minter);
            minting.mint(order, route, sig);
        }

        assertEq(m.balanceOf(benefactor), 50 ether);
        assertEq(minting.mintedPerBlock(block.number), 50 ether);
    }

    // ----------- Price Validation -----------

    function test_Mint_SixDecimalsCollateral() public {
        // 6 位小数抵押品（类 USDC），价格 $1：100e6 = $100，应铸出 100 M
        MockERC20WithDecimals usdc = new MockERC20WithDecimals("USD Coin", "USDC", 6);
        vm.prank(admin);
        minting.addSupportedAsset(address(usdc));
        usdc.mint(benefactor, 10_000e6);
        vm.prank(benefactor);
        usdc.approve(address(minting), type(uint256).max);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 0,
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

        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.StalePrice.selector);
        minting.mint(order, route, sig);
    }

    // ----------- Per-Block Limits -----------

    function test_Mint_MaxPerBlockExceeded() public {
        // Set a small limit
        vm.prank(admin);
        minting.setMaxMintPerBlock(50 ether);

        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.MaxMintPerBlockExceeded.selector);
        minting.mint(order, route, sig);
    }

    // ----------- Redeem -----------

    function test_Redeem() public {
        // First mint to have M to redeem
        IMonogramMinting.Order memory mintOrder = _createMintOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Route memory route = _createRoute();
        IMonogramMinting.Signature memory mintSig = _signOrder(mintOrder, benefactorPrivateKey);
        vm.prank(minter);
        minting.mint(mintOrder, route, mintSig);

        // Approve M burning
        vm.prank(benefactor);
        m.approve(address(minting), type(uint256).max);

        // Send collateral to contract for redeem
        collateral.mint(address(minting), 100 ether);

        IMonogramMinting.Order memory redeemOrder = _createRedeemOrder(1, 100 ether, 100 ether);
        IMonogramMinting.Signature memory redeemSig = _signOrder(redeemOrder, benefactorPrivateKey);

        uint256 benefactorCollateralBefore = collateral.balanceOf(benefactor);
        uint256 benefactorMBalanceBefore = m.balanceOf(benefactor);

        vm.prank(redeemer);
        minting.redeem(redeemOrder, redeemSig);

        assertEq(collateral.balanceOf(benefactor), benefactorCollateralBefore + 100 ether);
        assertEq(m.balanceOf(benefactor), benefactorMBalanceBefore - 100 ether);
        assertEq(minting.redeemedPerBlock(block.number), 100 ether);
    }

    function test_Redeem_NotRedeemer() public {
        IMonogramMinting.Order memory order = _createRedeemOrder(0, 100 ether, 100 ether);
        IMonogramMinting.Signature memory sig = _signOrder(order, benefactorPrivateKey);

        vm.prank(user);
        vm.expectRevert();
        minting.redeem(order, sig);
    }

    // ----------- Gatekeeper -----------

    function test_DisableMintRedeem() public {
        vm.prank(gatekeeper);
        minting.disableMintRedeem();

        assertEq(minting.maxMintPerBlock(), 0);
        assertEq(minting.maxRedeemPerBlock(), 0);
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

    function test_VerifyNonce_LargeNonce() public view {
        (uint256 slot, uint256 invalidator, uint256 invalidatorBit) = minting.verifyNonce(benefactor, 300);
        assertEq(slot, 1); // 300 >> 8 = 1
        assertEq(invalidator, 0);
        assertEq(invalidatorBit, 1 << (300 & 0xFF)); // 1 << 44
    }

    // ----------- Set Limits -----------

    function test_SetMaxMintPerBlock() public {
        vm.prank(admin);
        minting.setMaxMintPerBlock(5000 ether);
        assertEq(minting.maxMintPerBlock(), 5000 ether);
    }

    function test_SetMaxRedeemPerBlock() public {
        vm.prank(admin);
        minting.setMaxRedeemPerBlock(5000 ether);
        assertEq(minting.maxRedeemPerBlock(), 5000 ether);
    }

    function test_SetMaxMintPerBlock_NotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        minting.setMaxMintPerBlock(5000 ether);
    }

    // ----------- Hash / Encode Order -----------

    function test_HashOrder() public view {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        bytes32 hash = minting.hashOrder(order);
        assertTrue(hash != bytes32(0));
    }

    function test_EncodeOrder() public view {
        IMonogramMinting.Order memory order = _createMintOrder(0, 100 ether, 100 ether);
        bytes memory encoded = minting.encodeOrder(order);
        assertTrue(encoded.length > 0);
    }
}
