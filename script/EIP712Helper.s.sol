// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Script.sol";
import "../src/interfaces/IMonogramMinting.sol";

contract EIP712Helper is Script {
    bytes32 constant ORDER_TYPE = keccak256(
        "Order(uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant NAME_HASH = keccak256("MonogramMinting");
    bytes32 constant VERSION_HASH = keccak256("1");

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        address mintingContract = vm.envAddress("MINTING_ADDRESS");

        bool isMint = vm.envOr("IS_MINT", true);
        uint256 expiry = block.timestamp + vm.envOr("EXPIRY_SECONDS", uint256(3600));
        uint256 nonce = vm.envOr("NONCE", uint256(0));
        address benefactor = vm.envOr("BENEFACTOR", signer);
        address beneficiary = vm.envOr("BENEFICIARY", signer);
        address collateralAsset = vm.envAddress("COLLATERAL_ASSET");
        uint256 collateralAmount = vm.envUint("COLLATERAL_AMOUNT");
        uint256 mAmount = vm.envUint("M_AMOUNT");

        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, mintingContract)
        );

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE,
                isMint ? uint8(0) : uint8(1),
                expiry,
                nonce,
                benefactor,
                beneficiary,
                collateralAsset,
                collateralAmount,
                mAmount
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

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
        console.log("");
        console.log("=== Order Parameters ===");
        console.log("order_type:", isMint ? "0 (MINT)" : "1 (REDEEM)");
        console.log("expiry:", expiry);
        console.log("nonce:", nonce);
        console.log("benefactor:", benefactor);
        console.log("beneficiary:", beneficiary);
        console.log("collateral_asset:", collateralAsset);
        console.log("collateral_amount:", collateralAmount);
        console.log("m_amount:", mAmount);
        console.log("");
        console.log("=== Cast Call ===");
        console.log("cast call", mintingContract);
        if (isMint) {
            console.log("  mint(...) -- use cast send with the above signature");
        } else {
            console.log("  redeem(...) -- use cast send with the above signature");
        }
    }
}
