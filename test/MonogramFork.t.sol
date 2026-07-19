// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/M.sol";
import "../src/MonogramMinting.sol";
import "../src/MonogramPriceFeed.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";
import "../src/interfaces/IPyth.sol";
import "../src/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MonogramForkTest is Test {
    M public m;
    MonogramMinting public minting;
    MonogramPriceFeed public priceFeed;

    address public admin;
    address public minter;
    address public redeemer;
    address public gatekeeper;
    address public benefactor;
    address public custodian;

    uint256 public benefactorPrivateKey = 0xA11CE;

    IWETH9 public weth;

    // Sepolia addresses
    address public constant SEPOLIA_PYTH = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;
    address public constant SEPOLIA_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address public constant SEPOLIA_CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    bytes32 public constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    bytes32 public constant ORDER_TYPE = keccak256(
        "Order(uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 public constant NAME_HASH = keccak256("MonogramMinting");
    bytes32 public constant VERSION_HASH = keccak256("1");

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork("sepolia");
        }

        benefactor = vm.addr(benefactorPrivateKey);
        admin = makeAddr("admin");
        minter = makeAddr("minter");
        redeemer = makeAddr("redeemer");
        gatekeeper = makeAddr("gatekeeper");
        custodian = makeAddr("custodian");

        vm.startPrank(admin);

        m = new M(admin);
        weth = IWETH9(payable(SEPOLIA_WETH));
        priceFeed = new MonogramPriceFeed(admin, SEPOLIA_PYTH);

        address[] memory assets = new address[](1);
        assets[0] = SEPOLIA_WETH;

        address[] memory custodians = new address[](1);
        custodians[0] = custodian;

        minting = new MonogramMinting(
            IM(address(m)),
            weth,
            IMonogramPriceFeed(address(priceFeed)),
            assets,
            custodians,
            admin,
            1_000_000 ether,
            1_000_000 ether
        );

        m.setMinter(address(minting));

        minting.grantRole(keccak256("MINTER_ROLE"), minter);
        minting.grantRole(keccak256("REDEEMER_ROLE"), redeemer);
        minting.grantRole(keccak256("GATEKEEPER_ROLE"), gatekeeper);

        priceFeed.setOracleConfig(SEPOLIA_WETH, ETH_USD_FEED_ID, SEPOLIA_CHAINLINK_ETH_USD, 3600, 50);

        vm.stopPrank();

        deal(SEPOLIA_WETH, benefactor, 10 ether);
        vm.prank(benefactor);
        IERC20(SEPOLIA_WETH).approve(address(minting), type(uint256).max);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(minting)));
    }

    function _signOrder(
        IMonogramMinting.Order memory order
    ) internal view returns (IMonogramMinting.Signature memory) {
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPE, order.order_type, order.expiry, order.nonce,
            order.benefactor, order.beneficiary, order.collateral_asset,
            order.collateral_amount, order.m_amount
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(benefactorPrivateKey, digest);
        bytes memory sigBytes = abi.encodePacked(r, s, v);
        return IMonogramMinting.Signature({
            signature_type: IMonogramMinting.SignatureType.EIP712,
            signature_bytes: sigBytes
        });
    }

    function _singleRoute() internal view returns (IMonogramMinting.Route memory) {
        address[] memory addrs = new address[](1);
        addrs[0] = custodian;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;
        return IMonogramMinting.Route({addresses: addrs, ratios: ratios});
    }

    function test_PriceFeed_ReadsFromLiveOracle() public view {
        (uint256 price, uint256 updatedAt) = priceFeed.getPrice(SEPOLIA_WETH);
        assertTrue(price > 0, "price should be > 0");
        assertTrue(updatedAt > 0, "updatedAt should be > 0");
        assertTrue(block.timestamp - updatedAt < 3600, "price should be fresh");
    }

    function test_ForkMint() public {
        (uint256 price,) = priceFeed.getPrice(SEPOLIA_WETH);
        uint256 mAmount = 1 ether;
        uint256 collateralAmount = (1 ether * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 0,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: SEPOLIA_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        IMonogramMinting.Signature memory sig = _signOrder(order);
        IMonogramMinting.Route memory route = _singleRoute();

        vm.prank(minter);
        minting.mint(order, route, sig);

        assertGt(m.balanceOf(benefactor), 0, "should have minted M tokens");
    }

    function test_ForkMint_PriceDeviationExceeded() public {
        (uint256 price,) = priceFeed.getPrice(SEPOLIA_WETH);
        uint256 mAmount = 1 ether;
        uint256 collateralAmount = (1 ether * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(0);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 0,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: SEPOLIA_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        IMonogramMinting.Signature memory sig = _signOrder(order);
        IMonogramMinting.Route memory route = _singleRoute();

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.PriceDeviationExceeded.selector);
        minting.mint(order, route, sig);
    }

    function test_ForkRedeem() public {
        (uint256 price,) = priceFeed.getPrice(SEPOLIA_WETH);
        uint256 mAmount = 1 ether;
        uint256 collateralAmount = (1 ether * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory mintOrder = IMonogramMinting.Order({
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 0,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: SEPOLIA_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        vm.prank(minter);
        minting.mint(mintOrder, _singleRoute(), _signOrder(mintOrder));

        // Approve M for burning
        vm.prank(benefactor);
        m.approve(address(minting), type(uint256).max);

        // Fund contract with WETH for redemption
        deal(SEPOLIA_WETH, address(minting), collateralAmount);

        IMonogramMinting.Order memory redeemOrder = IMonogramMinting.Order({
            order_type: IMonogramMinting.OrderType.REDEEM,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: SEPOLIA_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        uint256 mBefore = m.balanceOf(benefactor);
        uint256 wethBefore = IERC20(SEPOLIA_WETH).balanceOf(benefactor);

        vm.prank(redeemer);
        minting.redeem(redeemOrder, _signOrder(redeemOrder));

        assertEq(m.balanceOf(benefactor), mBefore - mAmount, "M should be burned");
        assertEq(IERC20(SEPOLIA_WETH).balanceOf(benefactor), wethBefore + collateralAmount, "WETH should be returned");
    }

    function test_Fork_GatekeeperDisable() public {
        vm.prank(gatekeeper);
        minting.disableMintRedeem();
        assertEq(minting.maxMintPerBlock(), 0);
        assertEq(minting.maxRedeemPerBlock(), 0);
    }

    function test_Fork_ReplayProtection() public {
        (uint256 price,) = priceFeed.getPrice(SEPOLIA_WETH);
        uint256 mAmount = 0.5 ether;
        uint256 collateralAmount = (mAmount * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 0,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: SEPOLIA_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        IMonogramMinting.Signature memory sig = _signOrder(order);
        IMonogramMinting.Route memory route = _singleRoute();

        vm.startPrank(minter);
        minting.mint(order, route, sig);
        vm.expectRevert(IMonogramMinting.InvalidNonce.selector);
        minting.mint(order, route, sig);
        vm.stopPrank();
    }

    function test_Fork_InvalidSignature() public {
        (uint256 price,) = priceFeed.getPrice(SEPOLIA_WETH);
        uint256 mAmount = 1 ether;
        uint256 collateralAmount = (1 ether * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 0,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: SEPOLIA_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        IMonogramMinting.Route memory route = _singleRoute();

        // Sign with wrong key
        uint256 wrongKey = 0xB0B;
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPE, order.order_type, order.expiry, order.nonce,
            order.benefactor, order.beneficiary, order.collateral_asset,
            order.collateral_amount, order.m_amount
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory sigBytes = abi.encodePacked(r, s, v);
        IMonogramMinting.Signature memory sig = IMonogramMinting.Signature({
            signature_type: IMonogramMinting.SignatureType.EIP712,
            signature_bytes: sigBytes
        });

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidSignature.selector);
        minting.mint(order, route, sig);
    }
}
