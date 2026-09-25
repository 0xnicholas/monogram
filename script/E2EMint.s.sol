// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Script.sol";
import "../src/interfaces/IMonogramMinting.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";
import "../src/interfaces/IM.sol";
import "../src/interfaces/IWETH9.sol";

/**
 * @title E2EMint — EIP-712 链下签名服务原型（M1.3）
 * @notice 模拟生产链下组件的最小闭环： benefactor（签名方）+ operator（持 MINTER_ROLE 的提交方）。
 *
 * 流程：
 *   1. benefactor 包裹 ETH → WETH 并 approve MonogramMinting（链上广播）
 *   2. 读预言机价格，按 collateralUsd 计算 m_amount（链下）
 *   3. benefactor 本地 EIP-712 签名订单（不广播，vm.sign）
 *   4. operator 广播 mint(order, route, signature)（链上广播）
 *   5. 断言 beneficiary 收到 M、custodian 收到 WETH
 *
 * 环境变量：
 *   PRIVATE_KEY       benefactor 私钥（签名方）
 *   OPERATOR_KEY      operator 私钥（MINTER_ROLE，提交订单）
 *   MINTING_ADDRESS   已部署的 MonogramMinting
 *   CUSTODIAN_ADDRESS 单一 custodian 路由地址（需已在 minting 注册）
 *   COLLATERAL_ASSET  WETH 地址（默认从 minting 的 supportedAssets 查？显式传入更稳）
 *   AMOUNT            抵押数量（wei，默认 0.01e18）
 *   NONCE             订单 nonce（默认 1）
 *   ORDER_ID          订单号（默认 e2e-mint-<timestamp>）
 *
 * 运行（Sepolia）：
 *   forge script script/E2EMint.s.sol --rpc-url sepolia --broadcast
 */
contract E2EMint is Script {
    bytes32 constant ORDER_TYPE = keccak256(
        "Order(string order_id,uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("MonogramMinting");
    bytes32 constant VERSION_HASH = keccak256("1");

    function run() external {
        uint256 benefactorKey = vm.envUint("PRIVATE_KEY");
        uint256 operatorKey = vm.envUint("OPERATOR_KEY");
        address benefactor = vm.addr(benefactorKey);
        IMonogramMinting minting = IMonogramMinting(vm.envAddress("MINTING_ADDRESS"));
        address custodian = vm.envAddress("CUSTODIAN_ADDRESS");
        IERC20 collateral = IERC20(vm.envAddress("COLLATERAL_ASSET"));
        uint256 amount = vm.envOr("AMOUNT", uint256(0.01 ether));
        uint256 nonce = vm.envOr("NONCE", uint256(1));

        IM m = minting.m();
        IMonogramPriceFeed priceFeed = minting.priceFeed();

        // ---- 2. 链下：读价 + 计价 ----
        (uint256 price, uint256 updatedAt) = priceFeed.getPrice(address(collateral));
        console.log("Oracle price (1e18):", price);
        console.log("Oracle updatedAt:", updatedAt);
        uint8 decimals = IERC20Metadata(address(collateral)).decimals();
        uint256 normalized = decimals < 18 ? amount * (10 ** (18 - decimals)) : amount / (10 ** (decimals - 18));
        uint256 mAmount = (normalized * price) / 1e18;
        require(mAmount > 0, "m_amount is zero");

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_id: vm.envOr("ORDER_ID", string("e2e-mint")),
            order_type: IMonogramMinting.OrderType.MINT,
            expiry: block.timestamp + 1 hours,
            nonce: nonce,
            benefactor: benefactor,
            beneficiary: benefactor,
            collateral_asset: address(collateral),
            collateral_amount: amount,
            m_amount: mAmount
        });

        // ---- 3. 链下：EIP-712 签名（生产中由签名服务完成） ----
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(minting)));
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(benefactorKey, digest);
        IMonogramMinting.Signature memory sig = IMonogramMinting.Signature({
            signature_type: IMonogramMinting.SignatureType.EIP712, signature_bytes: abi.encodePacked(r, s, v)
        });
        console.log("Order digest:");
        console.logBytes32(digest);

        // ---- 1. benefactor：包裹 + 授权（若抵押品为 WETH） ----
        vm.startBroadcast(benefactorKey);
        uint256 wethBefore = collateral.balanceOf(benefactor);
        if (collateral.balanceOf(benefactor) < amount) {
            // 假定抵押品为 WETH：存入 ETH 换取
            IWETH9(address(collateral)).deposit{value: amount}();
        }
        if (collateral.allowance(benefactor, address(minting)) < amount) {
            collateral.approve(address(minting), type(uint256).max);
        }
        vm.stopBroadcast();

        address[] memory routeAddrs = new address[](1);
        routeAddrs[0] = custodian;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        // ---- 4. operator：提交订单 ----
        vm.startBroadcast(operatorKey);
        minting.mint(order, IMonogramMinting.Route({addresses: routeAddrs, ratios: ratios}), sig);
        vm.stopBroadcast();

        // ---- 5. 验证 ----
        require(m.balanceOf(benefactor) == mAmount, "beneficiary M balance mismatch");
        require(collateral.balanceOf(custodian) == amount, "custodian collateral mismatch");
        require(collateral.balanceOf(benefactor) == wethBefore, "benefactor WETH changed unexpectedly");

        console.log("\n=== E2E Mint Success ===");
        console.log("M minted to:", mAmount);
        console.log("Beneficiary:", benefactor);
        console.log("Custodian got collateral:", amount);
        console.log("order_id:", order.order_id);
        console.log("nonce:", nonce);
    }
}
