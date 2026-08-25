// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Script.sol";
import "../src/interfaces/IMonogramMinting.sol";

contract EIP712Helper is Script {
    bytes32 constant ORDER_TYPE = keccak256(
        "Order(string order_id,uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("MonogramMinting");
    bytes32 constant VERSION_HASH = keccak256("1");

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        address mintingContract = vm.envAddress("MINTING_ADDRESS");

        IMonogramMinting.Order memory order = IMonogramMinting.Order({
            order_id: vm.envOr("ORDER_ID", string("")),
            order_type: vm.envOr("IS_MINT", true) ? IMonogramMinting.OrderType.MINT : IMonogramMinting.OrderType.REDEEM,
            expiry: block.timestamp + vm.envOr("EXPIRY_SECONDS", uint256(3600)),
            nonce: vm.envOr("NONCE", uint256(1)),
            benefactor: vm.envOr("BENEFACTOR", signer),
            beneficiary: vm.envOr("BENEFICIARY", signer),
            collateral_asset: vm.envAddress("COLLATERAL_ASSET"),
            collateral_amount: vm.envUint("COLLATERAL_AMOUNT"),
            m_amount: vm.envUint("M_AMOUNT")
        });

        (bytes32 domainSeparator, bytes32 digest) = _computeDigest(order, mintingContract);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("=== EIP-712 Signature ===");
        console.log("Signer:", signer);
        console.log("Domain Separator:");
        console.logBytes32(domainSeparator);
        console.log("Digest:");
        console.logBytes32(digest);
        console.log("Signature (r,s,v hex):");
        console.logBytes(signature);

        _logOrder(order, mintingContract);
    }

    function _computeDigest(IMonogramMinting.Order memory order, address mintingContract)
        internal
        view
        returns (bytes32 domainSeparator, bytes32 digest)
    {
        domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, mintingContract));
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
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _logOrder(IMonogramMinting.Order memory order, address mintingContract) internal pure {
        console.log("");
        console.log("=== Order Parameters ===");
        console.log("order_id:", order.order_id);
        console.log("order_type:", order.order_type == IMonogramMinting.OrderType.MINT ? "0 (MINT)" : "1 (REDEEM)");
        console.log("expiry:", order.expiry);
        console.log("nonce:", order.nonce);
        console.log("benefactor:", order.benefactor);
        console.log("beneficiary:", order.beneficiary);
        console.log("collateral_asset:", order.collateral_asset);
        console.log("collateral_amount:", order.collateral_amount);
        console.log("m_amount:", order.m_amount);
        console.log("");
        console.log("=== Cast Call ===");
        console.log("cast call", mintingContract);
        if (order.order_type == IMonogramMinting.OrderType.MINT) {
            console.log("  mint(...) -- use cast send with the above signature");
        } else {
            console.log("  redeem(...) -- use cast send with the above signature");
        }
    }
}
