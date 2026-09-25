// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Script.sol";
import "../src/M.sol";
import "../src/MonogramMinting.sol";
import "../src/MonogramPriceFeed.sol";
import "../src/StakedM.sol";
import "../src/StakingRewardsDistributor.sol";
import "../src/WETH9.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";

contract DeployM is Script {
    // MonogramMinting 角色常量为 private（Ethena 风格），此处本地重建
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 internal constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");

    /// @notice STAKEDM_COOLDOWN_SECONDS 未设置时的哨兵值：表示沿用构造函数默认冷却期（90 天）
    uint256 internal constant SKIP_COOLDOWN_SENTINEL = type(uint24).max;

    struct DeployConfig {
        address admin;
        address weth;
        address pyth;
        address[] assets;
        address[] custodians;
        uint256 maxMintPerBlock;
        uint256 maxRedeemPerBlock;
        bool deployWeth; // true for local/anvil, false for live networks
        bool enableWhitelist; // 主网部署后启用白名单（单向棘轮，#11 决议）；测试网保持 false
        address mintingAdmin; // 可选：部署后请求移交 DEFAULT_ADMIN 的目标多签地址
        string stakedMName;
        string stakedMSymbol;
        uint24 stakedMCooldown;
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
            deployWeth: vm.envOr("DEPLOY_WETH", true),
            enableWhitelist: vm.envOr("ENABLE_WHITELIST", false),
            mintingAdmin: vm.envOr("MINTING_ADMIN", address(0)),
            stakedMName: vm.envOr("STAKEDM_NAME", string("Staked Monogram")),
            stakedMSymbol: vm.envOr("STAKEDM_SYMBOL", string("sM")),
            stakedMCooldown: uint24(_cooldownFromEnv()) // 未设置 = 保持构造值 90 天；填 0 = 关闭冷却期
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

        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](cfg.assets.length);
        for (uint256 i = 0; i < cfg.assets.length; i++) {
            tokenConfigs[i] = IMonogramMinting.TokenConfig({
                isActive: true, maxMintPerBlock: cfg.maxMintPerBlock, maxRedeemPerBlock: cfg.maxRedeemPerBlock
            });
        }
        IMonogramMinting.GlobalConfig memory globalConfig = IMonogramMinting.GlobalConfig({
            globalMaxMintPerBlock: cfg.maxMintPerBlock, globalMaxRedeemPerBlock: cfg.maxRedeemPerBlock
        });

        MonogramMinting minting = new MonogramMinting(
            IM(address(m)),
            weth,
            IMonogramPriceFeed(address(priceFeed)),
            cfg.assets,
            tokenConfigs,
            globalConfig,
            cfg.custodians,
            cfg.admin
        );
        console.log("MonogramMinting deployed at:", address(minting));

        // 5. Set M minter to MonogramMinting
        m.setMinter(address(minting));
        console.log("M minter set to:", address(minting));

        // 6. Enable whitelist (mainnet sequence, one-way ratchet per issue #11)
        //    测试网/本地不要设置 ENABLE_WHITELIST，保持 false 以便自由测试
        if (cfg.enableWhitelist) {
            minting.setWhitelistEnabled(true);
            console.log("Whitelist ENABLED (irreversible)");
        }

        // 7. Optional: request two-step admin transfer to multisig
        //    多签需随后调用 acceptAdmin() 完成接管
        if (cfg.mintingAdmin != address(0)) {
            minting.transferAdmin(cfg.mintingAdmin);
            console.log("Admin transfer requested to:", cfg.mintingAdmin);
            console.log("NOTE: multisig must call acceptAdmin() to complete");
        }

        // 8. Deploy StakedM（初始 REWARDER=admin 占位，随后授予分发器）
        StakedM stakedM = new StakedM(IERC20(address(m)), cfg.admin, cfg.admin, cfg.stakedMName, cfg.stakedMSymbol);
        console.log("StakedM deployed at:", address(stakedM));
        if (cfg.stakedMCooldown != SKIP_COOLDOWN_SENTINEL) {
            stakedM.setCooldownDuration(cfg.stakedMCooldown);
            console.log("StakedM cooldown set to (s):", uint256(cfg.stakedMCooldown));
        }

        // 9. Deploy StakingRewardsDistributor 并接管 REWARDER
        StakingRewardsDistributor distributor =
            new StakingRewardsDistributor(IStakedM(address(stakedM)), IM(address(m)), cfg.admin);
        stakedM.grantRole(stakedM.REWARDER_ROLE(), address(distributor));
        console.log("StakingRewardsDistributor deployed at:", address(distributor));

        // 10. Grant operating roles（默认全部授予部署者，测试网便利；生产用 OPERATORS/GATEKEEPERS 指定独立密钥）
        address[] memory operators = _envAddressList("OPERATORS", cfg.admin);
        for (uint256 i = 0; i < operators.length; i++) {
            minting.grantRole(MINTER_ROLE, operators[i]);
            minting.grantRole(REDEEMER_ROLE, operators[i]);
            distributor.grantRole(distributor.OPERATOR_ROLE(), operators[i]);
            console.log("Granted MINTER/REDEEMER/OPERATOR to:", operators[i]);
        }
        address[] memory gatekeepers = _envAddressList("GATEKEEPERS", cfg.admin);
        for (uint256 i = 0; i < gatekeepers.length; i++) {
            minting.grantRole(GATEKEEPER_ROLE, gatekeepers[i]);
            console.log("Granted GATEKEEPER to:", gatekeepers[i]);
        }

        // 11. Configure oracles per asset（CHAINLINK_FEEDS / PYTH_FEED_IDS 与 ASSETS 对齐；未提供则跳过）
        _configureOracles(priceFeed, cfg.assets);

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("M:", address(m));
        console.log("PriceFeed:", address(priceFeed));
        console.log("MonogramMinting:", address(minting));
        console.log("StakedM:", address(stakedM));
        console.log("StakingRewardsDistributor:", address(distributor));
        console.log("Admin:", cfg.mintingAdmin != address(0) ? cfg.mintingAdmin : cfg.admin);
        console.log("Whitelist enabled:", minting.whitelistEnabled());
    }

    /// @notice per-asset 预言机配置：CHAINLINK_FEEDS / PYTH_FEED_IDS 与 ASSETS 逐位对齐（CSV）
    /// @dev 默认参数（maxAge=24h、deviation=500bps）为测试网值，同 fork 测试；生产按 ADR-0008 治理
    function _configureOracles(MonogramPriceFeed priceFeed, address[] memory assets) internal {
        string memory clCsv = vm.envOr("CHAINLINK_FEEDS", string(""));
        if (bytes(clCsv).length == 0) {
            console.log("NOTE: CHAINLINK_FEEDS not set, oracle configs left to operator");
            return;
        }
        address[] memory clFeeds = _parseAddresses(clCsv);
        string[] memory pythIds = _parseHex32List(vm.envOr("PYTH_FEED_IDS", string("")));
        uint128 maxAge = uint128(vm.envOr("ORACLE_MAX_AGE", uint256(24 hours)));
        uint128 maxDeviation = uint128(vm.envOr("ORACLE_MAX_DEVIATION_BPS", uint256(500)));
        require(assets.length == clFeeds.length, "CHAINLINK_FEEDS length mismatch");
        require(pythIds.length == 0 || pythIds.length == assets.length, "PYTH_FEED_IDS length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            bytes32 pythId = pythIds.length == 0 ? bytes32(0) : vm.parseBytes32(pythIds[i]);
            priceFeed.setOracleConfig(assets[i], pythId, clFeeds[i], maxAge, maxDeviation);
            console.log("Oracle configured for asset:", assets[i]);
        }
    }

    /// @notice 读冷却期配置，显式拒绝超出 uint24 的值（否则静默截断可能把冷却期变成 0）
    /// @dev 上限（90 天）由 StakedM.setCooldownDuration 校验
    function _cooldownFromEnv() internal view returns (uint256) {
        uint256 raw = vm.envOr("STAKEDM_COOLDOWN_SECONDS", SKIP_COOLDOWN_SENTINEL);
        require(raw <= type(uint24).max, "STAKEDM_COOLDOWN_SECONDS exceeds uint24");
        return raw;
    }

    function _envAddressList(string memory name, address fallbackSingle) internal returns (address[] memory out) {
        string memory csv = vm.envOr(name, string(""));
        if (bytes(csv).length == 0) {
            out = new address[](1);
            out[0] = fallbackSingle;
            return out;
        }
        return _parseAddresses(csv);
    }

    function _parseHex32List(string memory csv) internal pure returns (string[] memory) {
        if (bytes(csv).length == 0) return new string[](0);
        bytes memory data = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == ",") count++;
        }
        string[] memory items = new string[](count);
        uint256 idx = 0;
        uint256 last = 0;
        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == ",") {
                bytes memory chunk = new bytes(i - last);
                for (uint256 j = 0; j < i - last; j++) {
                    chunk[j] = data[last + j];
                }
                items[idx] = string(chunk);
                idx++;
                last = i + 1;
            }
        }
        return items;
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
