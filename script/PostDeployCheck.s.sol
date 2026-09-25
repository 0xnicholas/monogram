// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Script.sol";

import "./lib/PostDeployChecker.sol";
import "./lib/EnvParsing.sol";

/**
 * @title PostDeployCheck — 部署后校验脚本
 * @notice 把部署时用的同一份 .env 喂给本脚本，逐项核对链上状态；任一不符即 revert（带可读原因）。
 *         断言细节见 `PostDeployChecker`，本文件只做 .env → `Deployment` 的映射。
 *
 * 运行：
 *   forge script script/PostDeployCheck.s.sol --rpc-url $RPC
 *
 * 环境变量（除地址外与 DeployM 同名，直接复用部署用的 .env）：
 *   M_ADDRESS / PRICE_FEED_ADDRESS / MINTING_ADDRESS / STAKEDM_ADDRESS / DISTRIBUTOR_ADDRESS  必填
 *   PRIVATE_KEY 或 DEPLOYER_ADDRESS   部署者地址（用于核对角色残留）
 *   ADMIN_ADDRESS                     期望的最终 admin（多签）；未设置时视为部署者
 *   EXPECT_ADMIN_HANDOVER             none（默认，admin 仍是部署者）| pending | done
 *   ENABLE_WHITELIST / WHITELISTED_BENEFACTORS
 *   ASSETS / CUSTODIANS / OPERATORS / GATEKEEPERS / REWARDERS / PROBE_ADDRESSES
 *   MAX_MINT_PER_BLOCK / MAX_REDEEM_PER_BLOCK
 *   EXPECT_MAX_PRICE_DEVIATION_BPS（默认 500，即合约默认值）
 *   CHAINLINK_FEEDS / PYTH_FEED_IDS / PYTH_ADDRESS / ORACLE_MAX_AGE / ORACLE_MAX_DEVIATION_BPS
 *   CHECK_ORACLE_LIVENESS（默认 true；本地彩排必须显式置 false）
 *   EXPECT_FRESH_VAULT（默认 true；部署后立刻校验。若已有存款/奖励则置 false）
 *   STAKEDM_NAME / STAKEDM_SYMBOL / STAKEDM_COOLDOWN_SECONDS
 */
contract PostDeployCheck is Script {
    /// @dev 与 DeployM 的 SKIP_COOLDOWN_SENTINEL 语义一致：未设置 = 期望构造函数默认值（90 天）
    uint256 internal constant SKIP_COOLDOWN_SENTINEL = type(uint24).max;

    function run() external {
        PostDeployChecker.Deployment memory d = deploymentFromEnv();
        new PostDeployChecker().check(d);
    }

    function deploymentFromEnv() public returns (PostDeployChecker.Deployment memory d) {
        d.m = vm.envAddress("M_ADDRESS");
        d.priceFeed = vm.envAddress("PRICE_FEED_ADDRESS");
        d.minting = vm.envAddress("MINTING_ADDRESS");
        d.stakedM = vm.envAddress("STAKEDM_ADDRESS");
        d.distributor = vm.envAddress("DISTRIBUTOR_ADDRESS");

        d.deployer = _deployerAddress();
        d.admin = vm.envOr("ADMIN_ADDRESS", d.deployer);
        d = applyHandover(d, vm.envOr("EXPECT_ADMIN_HANDOVER", string("none")));

        // 参数
        d.whitelistEnabled = vm.envOr("ENABLE_WHITELIST", false);
        d.benefactors = EnvParsing.parseAddresses(vm.envOr("WHITELISTED_BENEFACTORS", string("")));
        d.maxPriceDeviationBps = vm.envOr("EXPECT_MAX_PRICE_DEVIATION_BPS", uint256(500));
        d.globalMaxMintPerBlock = vm.envOr("MAX_MINT_PER_BLOCK", uint256(1_000_000 ether));
        d.globalMaxRedeemPerBlock = vm.envOr("MAX_REDEEM_PER_BLOCK", uint256(1_000_000 ether));
        d.maxMintPerBlock = d.globalMaxMintPerBlock;
        d.maxRedeemPerBlock = d.globalMaxRedeemPerBlock;
        d.stakedMCooldown = resolveCooldown(
            vm.envOr("STAKEDM_COOLDOWN_SECONDS", SKIP_COOLDOWN_SENTINEL),
            uint256(StakedM(vm.envAddress("STAKEDM_ADDRESS")).MAX_COOLDOWN_DURATION())
        );
        d.stakedMName = vm.envOr("STAKEDM_NAME", string("Staked Monogram"));
        d.stakedMSymbol = vm.envOr("STAKEDM_SYMBOL", string("sM"));

        // 资产与托管
        d.assets = EnvParsing.parseAddresses(vm.envOr("ASSETS", string("")));
        d.custodians = EnvParsing.parseAddresses(vm.envOr("CUSTODIANS", string("")));

        // 角色（与 DeployM 相同的默认：未指定时授予部署者）
        d.operators = EnvParsing.parseAddresses(vm.envOr("OPERATORS", string("")));
        if (d.operators.length == 0) d.operators = _single(d.deployer);
        d.gatekeepers = EnvParsing.parseAddresses(vm.envOr("GATEKEEPERS", string("")));
        if (d.gatekeepers.length == 0) d.gatekeepers = _single(d.deployer);
        d.rewarders = EnvParsing.parseAddresses(vm.envOr("REWARDERS", string("")));

        // 预言机
        d.chainlinkFeeds = EnvParsing.parseAddresses(vm.envOr("CHAINLINK_FEEDS", string("")));
        d.pythFeeds = EnvParsing.parseHex32List(vm.envOr("PYTH_FEED_IDS", string("")));
        d.expectedPyth = vm.envOr("PYTH_ADDRESS", address(0));
        d.oracleMaxAge = _u128(vm.envOr("ORACLE_MAX_AGE", uint256(24 hours)), "ORACLE_MAX_AGE");
        d.oracleMaxDeviation = _u128(vm.envOr("ORACLE_MAX_DEVIATION_BPS", uint256(500)), "ORACLE_MAX_DEVIATION_BPS");
        d.checkOracleLiveness = vm.envOr("CHECK_ORACLE_LIVENESS", true);

        // 其它
        d.expectFreshVault = vm.envOr("EXPECT_FRESH_VAULT", true);
        d.extraProbes = EnvParsing.parseAddresses(vm.envOr("PROBE_ADDRESSES", string("")));
    }

    /// @dev EXPECT_ADMIN_HANDOVER：none = 部署者仍持有全部 admin/owner（测试网默认）；
    ///      pending = 已请求两步移交待多签接受；done = 移交已完成。
    ///      无两步移交的合约（PriceFeed / 分发器）在 pending/done 下都期望「admin 持有、部署者不持有」，
    ///      两步移交合约（M / MonogramMinting / StakedM）在 pending 下期望「部署者持有、admin 待接受」。
    ///      不读环境变量：env 层（`deploymentFromEnv`）只负责传参，便于单测映射逻辑。
    /// @dev 返回结构体而非原地修改：外部调用传的是内存副本，原地写不会回传（见测试 test_Handover_*）。
    function applyHandover(PostDeployChecker.Deployment memory d, string memory mode)
        public
        pure
        returns (PostDeployChecker.Deployment memory)
    {
        bytes32 modeHash = keccak256(bytes(mode));
        require(
            modeHash == keccak256("none") || modeHash == keccak256("pending") || modeHash == keccak256("done"),
            "EXPECT_ADMIN_HANDOVER must be none|pending|done"
        );
        if (modeHash == keccak256("none")) {
            d.mOwnership = PostDeployChecker.Handover({owner: d.deployer, pending: address(0)});
            d.mintingAdmin = PostDeployChecker.Handover({owner: d.deployer, pending: address(0)});
            d.stakedMAdmin = PostDeployChecker.Handover({owner: d.deployer, pending: address(0)});
            d.feedAdmins = _single(d.deployer);
            d.distributorAdmins = _single(d.deployer);
            return d;
        }

        require(d.admin != d.deployer, unicode"EXPECT_ADMIN_HANDOVER != none 时 ADMIN_ADDRESS 必须是多签地址");
        bool pending = modeHash == keccak256("pending");
        address currentOwner = pending ? d.deployer : d.admin;
        address pendingOwner = pending ? d.admin : address(0);
        d.mOwnership = PostDeployChecker.Handover({owner: currentOwner, pending: pendingOwner});
        d.mintingAdmin = PostDeployChecker.Handover({owner: currentOwner, pending: pendingOwner});
        d.stakedMAdmin = PostDeployChecker.Handover({owner: currentOwner, pending: pendingOwner});
        d.feedAdmins = _single(d.admin);
        d.distributorAdmins = _single(d.admin);
        return d;
    }

    /// @dev 冷却期：未设置（哨兵）→ 期望 StakedM 构造默认值；否则期望该值。
    ///      显式拒绝超出 uint24 的输入，否则静默截断可能把冷却期变成 0（等于关闭冷却）。
    function resolveCooldown(uint256 raw, uint256 maxCooldown) public pure returns (uint256) {
        require(raw <= type(uint24).max, "STAKEDM_COOLDOWN_SECONDS exceeds uint24");
        return raw == SKIP_COOLDOWN_SENTINEL ? maxCooldown : raw;
    }

    function _deployerAddress() internal returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        address explicit = vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(explicit != address(0), unicode"需要 PRIVATE_KEY 或 DEPLOYER_ADDRESS");
        return explicit;
    }

    function _single(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _u128(uint256 value, string memory name) internal pure returns (uint128) {
        require(value <= type(uint128).max, string.concat(name, " exceeds uint128"));
        return uint128(value);
    }
}
