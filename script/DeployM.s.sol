// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Script.sol";
import "../src/M.sol";
import "../src/MonogramMinting.sol";
import "../src/MonogramPriceFeed.sol";
import "../src/WETH9.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";

contract DeployM is Script {
    struct DeployConfig {
        address admin;
        address weth;
        address pyth;
        address[] assets;
        address[] custodians;
        uint256 maxMintPerBlock;
        uint256 maxRedeemPerBlock;
        bool deployWeth; // true for local/anvil, false for live networks
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        DeployConfig memory cfg = DeployConfig({
            admin: vm.addr(deployerPrivateKey),
            weth: vm.envOr("WETH_ADDRESS", address(0)),
            pyth: vm.envOr("PYTH_ADDRESS", address(0)), // 用 Pyth 升级版合约地址，见 ADR-0008「Pyth Core 升级」
            assets: _parseAddresses(vm.envOr("ASSETS", string(""))),
            custodians: _parseAddresses(vm.envOr("CUSTODIANS", string(""))),
            maxMintPerBlock: vm.envOr("MAX_MINT_PER_BLOCK", uint256(1_000_000 ether)),
            maxRedeemPerBlock: vm.envOr("MAX_REDEEM_PER_BLOCK", uint256(1_000_000 ether)),
            deployWeth: vm.envOr("DEPLOY_WETH", true)
        });

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy M token
        M m = new M(cfg.admin);
        console.log("M deployed at:", address(m));

        // 2. Deploy or use WETH
        IWETH9 weth;
        if (cfg.deployWeth || cfg.weth == address(0)) {
            weth = IWETH9(payable(address(new WETH9())));
            console.log("WETH9 deployed at:", address(weth));
        } else {
            weth = IWETH9(payable(cfg.weth));
            console.log("Using WETH at:", cfg.weth);
        }

        // 3. Set Pyth address in PriceFeed (using override pattern)
        MonogramPriceFeed priceFeed = new MonogramPriceFeed(cfg.admin, cfg.pyth);
        console.log("MonogramPriceFeed deployed at:", address(priceFeed));

        // 4. Deploy MonogramMinting
        if (cfg.assets.length == 0) {
            console.log("ERROR: No assets provided. Set ASSETS env var as comma-separated addresses.");
            revert("ASSETS required");
        }
        if (cfg.custodians.length == 0) {
            console.log("WARNING: No custodians provided. Set CUSTODIANS env var as comma-separated addresses.");
        }

        MonogramMinting minting = new MonogramMinting(
            IM(address(m)),
            weth,
            IMonogramPriceFeed(address(priceFeed)),
            cfg.assets,
            cfg.custodians,
            cfg.admin,
            cfg.maxMintPerBlock,
            cfg.maxRedeemPerBlock
        );
        console.log("MonogramMinting deployed at:", address(minting));

        // 5. Set M minter to MonogramMinting
        m.setMinter(address(minting));
        console.log("M minter set to:", address(minting));

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("M:", address(m));
        console.log("PriceFeed:", address(priceFeed));
        console.log("MonogramMinting:", address(minting));
        console.log("Admin:", cfg.admin);
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory) {
        if (bytes(csv).length == 0) return new address[](0);
        bytes memory data = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == ",") count++;
        }
        address[] memory addrs = new address[](count);
        uint256 idx = 0;
        uint256 last = 0;
        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == ",") {
                bytes memory chunk = new bytes(i - last);
                for (uint256 j = 0; j < i - last; j++) {
                    chunk[j] = data[last + j];
                }
                addrs[idx] = _parseAddress(string(chunk));
                idx++;
                last = i + 1;
            }
        }
        return addrs;
    }

    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42, "invalid address length");
        uint256 addr = 0;
        for (uint256 i = 2; i < b.length; i++) {
            uint8 digit;
            if (b[i] >= 0x30 && b[i] <= 0x39) {
                digit = uint8(b[i]) - 0x30;
            } else if (b[i] >= 0x41 && b[i] <= 0x46) {
                digit = uint8(b[i]) - 0x41 + 10;
            } else if (b[i] >= 0x61 && b[i] <= 0x66) {
                digit = uint8(b[i]) - 0x61 + 10;
            } else {
                revert("invalid address char");
            }
            addr = addr * 16 + digit;
        }
        return address(uint160(addr));
    }
}
