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

// 固定喂价：mint/redeem 流程测试不依赖主网 Pyth 推送节奏
uint256 constant MOCK_ETH_PRICE = 2500e18;

/// @dev 实测新 Pyth 合约 ETH/USD 推送间隔 >3.7h，而 _validatePrice 的
/// StalePrice 窗口是硬编码 3600s，用真实喂价会让流程测试变成不可控的活数据金丝雀；
/// 活预言机冒烟由 test_PriceFeed_ReadsFromLiveOracle 单独承担
contract MockForkPriceFeed is IMonogramPriceFeed {
    function getPrice(address) external view returns (uint256, uint256) {
        return (MOCK_ETH_PRICE, block.timestamp);
    }

    function getPriceAndTimestamp(address asset) external view returns (uint256, uint256) {
        return this.getPrice(asset);
    }

    function setOracleConfig(address, bytes32, address, uint128, uint128) external {}
    function removeOracleConfig(address) external {}
}

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

    // Mainnet addresses（fork 主网而非 Sepolia：Pyth 在测试网是 pull 预言机，
    // 推送间隔以天计且推送的 publishTime 本身就过期数小时，常规 maxAge 在
    // Sepolia 任何区块都无法满足；主网有常态化推送）
    //
    // Pyth 用升级版合约（pro-compatible-production）：旧合约 0x4305... 在
    // 2026-08-26 DAO 原地升级前已停止接收推送，新合约接口不变。
    // 注意：新合约 ETH/USD 的推送间隔实测可达数小时（2026-08 观测 >3.7h），
    // 因此 fork 测试的 maxAge 用 24h（FORK_MAX_AGE）。maxAge 是 per-asset
    // 治理参数（ADR-0008），这里放宽只影响测试，不代表生产配置。
    // 地址来源：pyth-crosschain/contract_manager EvmPriceFeedContracts.json
    address public constant MAINNET_PYTH = 0x14b9932cc9AC8Ee03301665a8644A753f46D8552;
    address public constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant MAINNET_CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    bytes32 public constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    uint128 public constant FORK_MAX_AGE = 24 hours;
    // 双源偏差阈值：Pyth 推送滞后时两源价差会瞬时拉大（观测 >1%），fork 冒烟测试
    // 放宽到 5%；生产阈值同样是 per-asset 治理参数
    uint128 public constant FORK_MAX_DEVIATION_BPS = 500;
    // 死源检测窗口：超过它视为预言机已停推（如旧 Pyth 合约被 DAO 升级后停推），
    // 测试应失败以提醒更新地址；窗口内的推送滞后（当前实测 27h+）不算故障
    uint256 public constant DEAD_FEED_MAX_AGE = 7 days;

    bytes32 public constant ORDER_TYPE = keccak256(
        "Order(string order_id,uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant NAME_HASH = keccak256("MonogramMinting");
    bytes32 public constant VERSION_HASH = keccak256("1");

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork("mainnet");
        }

        benefactor = vm.addr(benefactorPrivateKey);
        admin = makeAddr("admin");
        minter = makeAddr("minter");
        redeemer = makeAddr("redeemer");
        gatekeeper = makeAddr("gatekeeper");
        custodian = makeAddr("custodian");

        vm.startPrank(admin);

        m = new M(admin);
        weth = IWETH9(payable(MAINNET_WETH));
        priceFeed = new MonogramPriceFeed(admin, MAINNET_PYTH);

        address[] memory assets = new address[](1);
        assets[0] = MAINNET_WETH;

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
            weth,
            IMonogramPriceFeed(address(new MockForkPriceFeed())),
            assets,
            tokenConfigs,
            globalConfig,
            custodians,
            admin
        );

        m.setMinter(address(minting));

        minting.grantRole(keccak256("MINTER_ROLE"), minter);
        minting.grantRole(keccak256("REDEEMER_ROLE"), redeemer);
        minting.grantRole(keccak256("GATEKEEPER_ROLE"), gatekeeper);

        priceFeed.setOracleConfig(
            MAINNET_WETH, ETH_USD_FEED_ID, MAINNET_CHAINLINK_ETH_USD, FORK_MAX_AGE, FORK_MAX_DEVIATION_BPS
        );

        vm.stopPrank();

        deal(MAINNET_WETH, benefactor, 10 ether);
        vm.prank(benefactor);
        IERC20(MAINNET_WETH).approve(address(minting), type(uint256).max);
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(benefactorPrivateKey, digest);
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

    /// @dev 活预言机冒烟：锁定「接线正确」而非「推送新鲜」。
    /// Pyth pro-compatible-production 推送间隔持续恶化（2026-08 观测 >3.7h，
    /// 2026-09 实测 27h+），把 maxAge 当硬断言会让测试变成 Pyth 运维节奏的金丝雀。语义：
    ///   1. getPrice() 成功 → 全量断言（可读 + 新鲜度在 FORK_MAX_AGE 内）
    ///   2. 仅因 StalePythPrice/StaleChainlinkPrice revert → 接线正确但推送滞后，
    ///      回退到原始读数验证：双源皆可读、解码量级合理、7 天内未死源
    ///   3. 其他 revert（conf 超限 / 双源偏差 / 未配置）→ 仍然失败
    function test_PriceFeed_ReadsFromLiveOracle() public view {
        try priceFeed.getPrice(MAINNET_WETH) returns (uint256 price, uint256 updatedAt) {
            assertTrue(price > 0, "price should be > 0");
            assertTrue(updatedAt > 0, "updatedAt should be > 0");
            assertTrue(block.timestamp - updatedAt < FORK_MAX_AGE, "price should be fresh");
        } catch (bytes memory reason) {
            bytes32 stalePyth = keccak256(abi.encodeWithSelector(IMonogramPriceFeed.StalePythPrice.selector));
            bytes32 staleCl = keccak256(abi.encodeWithSelector(IMonogramPriceFeed.StaleChainlinkPrice.selector));
            bytes32 reasonHash = keccak256(reason);
            bool stale = reasonHash == stalePyth || reasonHash == staleCl;
            assertTrue(stale, string.concat("unexpected revert: ", vm.toString(reason)));
            _assertOracleWiringAlive();
        }
    }

    /// @dev staleness 回退路径：原始读数验证接线（双源皆可读、量级合理、未死源）
    function _assertOracleWiringAlive() internal view {
        IPyth.Price memory p = IPyth(MAINNET_PYTH).getPriceUnsafe(ETH_USD_FEED_ID);
        assertGt(p.price, 0, "pyth price should be positive");
        assertGt(p.publishTime, 0, "pyth publishTime should be positive");
        assertLt(block.timestamp - p.publishTime, DEAD_FEED_MAX_AGE, "pyth feed looks dead");

        // 解码量级：expo 归一到 18 位小数后应在 $100 ~ $1M 之间（防 expo 回归）
        uint256 pythPrice18 = _normalizeTo18(uint256(uint64(p.price)), p.expo);
        assertGe(pythPrice18, 100 ether, "pyth price out of sane range");
        assertLe(pythPrice18, 1_000_000 ether, "pyth price out of sane range");

        (, int256 clAnswer,, uint256 clUpdatedAt,) = AggregatorV3Interface(MAINNET_CHAINLINK_ETH_USD).latestRoundData();
        assertGt(clAnswer, 0, "chainlink answer should be positive");
        assertGt(clUpdatedAt, 0, "chainlink updatedAt should be positive");
        assertLt(block.timestamp - clUpdatedAt, DEAD_FEED_MAX_AGE, "chainlink feed looks dead");
    }

    function _normalizeTo18(uint256 raw, int32 expo) internal pure returns (uint256) {
        int256 e = int256(expo) + 18;
        return e >= 0 ? raw * 10 ** uint256(e) : raw / 10 ** uint256(-e);
    }

    function test_ForkMint() public {
        uint256 price = MOCK_ETH_PRICE;
        uint256 mAmount = 1 ether;
        uint256 collateralAmount = (1 ether * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_id: "fork-order",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: MAINNET_WETH,
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
        uint256 price = MOCK_ETH_PRICE;
        uint256 mAmount = 1 ether;
        // 抵押品比公允价值多 5%，配合 100bps 阈值必然超限
        // （若抵押品按预言机价格精确折算，偏差恒为 0，阈值再低也不会 revert）
        uint256 collateralAmount = (1 ether * 1e18 * 105) / (price * 100);

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(100);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_id: "fork-order",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: MAINNET_WETH,
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
        uint256 price = MOCK_ETH_PRICE;
        uint256 mAmount = 1 ether;
        uint256 collateralAmount = (1 ether * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory mintOrder = IMonogramMinting.Order({
            order_id: "fork-order",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: MAINNET_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        vm.prank(minter);
        minting.mint(mintOrder, _singleRoute(), _signOrder(mintOrder));

        // Approve M for burning
        vm.prank(benefactor);
        m.approve(address(minting), type(uint256).max);

        // Fund contract with WETH for redemption
        deal(MAINNET_WETH, address(minting), collateralAmount);

        IMonogramMinting.Order memory redeemOrder = IMonogramMinting.Order({
            order_id: "fork-redeem-1",
            order_type: IMonogramMinting.OrderType.REDEEM,
            expiry: block.timestamp + 1 hours,
            nonce: 2,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: MAINNET_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        uint256 mBefore = m.balanceOf(benefactor);
        uint256 wethBefore = IERC20(MAINNET_WETH).balanceOf(benefactor);

        vm.prank(redeemer);
        minting.redeem(redeemOrder, _signOrder(redeemOrder));

        assertEq(m.balanceOf(benefactor), mBefore - mAmount, "M should be burned");
        assertEq(IERC20(MAINNET_WETH).balanceOf(benefactor), wethBefore + collateralAmount, "WETH should be returned");
    }

    function test_Fork_GatekeeperDisable() public {
        vm.prank(gatekeeper);
        minting.disableMintRedeem();
        (uint256 globalMaxMint, uint256 globalMaxRedeem) = minting.globalConfig();
        assertEq(globalMaxMint, 0);
        assertEq(globalMaxRedeem, 0);
    }

    function test_Fork_ReplayProtection() public {
        uint256 price = MOCK_ETH_PRICE;
        uint256 mAmount = 0.5 ether;
        uint256 collateralAmount = (mAmount * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_id: "fork-order",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: MAINNET_WETH,
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
        uint256 price = MOCK_ETH_PRICE;
        uint256 mAmount = 1 ether;
        uint256 collateralAmount = (1 ether * 1e18) / price;

        vm.prank(admin);
        minting.setMaxPriceDeviationBps(1000);

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_id: "fork-order",
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: 1,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: MAINNET_WETH,
            collateral_amount: collateralAmount,
            m_amount: mAmount
        });

        IMonogramMinting.Route memory route = _singleRoute();

        // Sign with wrong key
        uint256 wrongKey = 0xB0B;
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory sigBytes = abi.encodePacked(r, s, v);
        IMonogramMinting.Signature memory sig = IMonogramMinting.Signature({
            signature_type: IMonogramMinting.SignatureType.EIP712, signature_bytes: sigBytes
        });

        vm.prank(minter);
        vm.expectRevert(IMonogramMinting.InvalidEIP712Signature.selector);
        minting.mint(order, route, sig);
    }
}
