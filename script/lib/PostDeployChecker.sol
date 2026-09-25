// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../../src/M.sol";
import "../../src/MonogramMinting.sol";
import "../../src/MonogramPriceFeed.sol";
import "../../src/StakedM.sol";
import "../../src/StakingRewardsDistributor.sol";
import {ISingleAdminAccessControl} from "../../src/interfaces/ISingleAdminAccessControl.sol";

/**
 * @title PostDeployChecker — 部署后状态断言
 * @notice 把「这次部署应该长什么样」显式写成 `Deployment`，逐项核对链上实际状态，失败即 revert。
 *         调用方（`script/PostDeployCheck.s.sol` 从 .env 构造，测试从内存构造）负责提供预期值。
 *
 * 设计约束：
 * - **不读环境变量**（保持可测）：预期值全部由调用方传入，脚本层只做 .env → 结构体的映射。
 * - **无法枚举 OZ AccessControl 的角色成员**，所以角色核对分两条腿：
 *   ① 期望名单里的每个地址都必须确实持有；
 *   ② 对「探针地址集合」（部署者、admin、各合约自身、运营/熔断/托管名单等）逐地址核对
 *      持有情况与期望完全一致 —— 这条腿专门抓「部署者残留 MINTER」这类多授权。
 *   名单之外的额外持有者检测不到，需要靠 `RoleGranted` 事件审计（写进 runbook）。
 * - 合规/运维角色（COLLATERAL_MANAGER、BLACKLIST_MANAGER、受限名单）只报告不判失败：
 *   它们的授予时机属于运行期决策（OES 接入 #8、合规处置），不是部署正确性。
 */
contract PostDeployChecker {
    error InvariantFailed(string what);

    /// @notice 两步移交的期望状态（owner=当前持有者，pending=待接受者，0 表示无待接受）
    struct Handover {
        address owner;
        address pending;
    }

    /// @notice 一份部署的完整预期状态
    struct Deployment {
        // --- 合约地址 ---
        address m;
        address priceFeed;
        address minting;
        address stakedM;
        address distributor;
        // --- admin / owner ---
        address admin; // 期望的最终 admin（多签地址；未移交时等于部署者）
        address deployer; // 部署者地址
        Handover mOwnership; // M（Ownable2Step）
        Handover mintingAdmin; // MonogramMinting（SingleAdminAccessControl）
        Handover stakedMAdmin; // StakedM（SingleAdminAccessControl）
        address[] feedAdmins; // priceFeed 的 DEFAULT_ADMIN_ROLE 期望持有者（OZ AccessControl，无两步移交）
        address[] distributorAdmins; // 分发器同理
        // --- 参数 ---
        bool whitelistEnabled;
        address[] benefactors; // whitelistEnabled 时逐个核对已在白名单
        uint256 maxPriceDeviationBps;
        uint256 globalMaxMintPerBlock;
        uint256 globalMaxRedeemPerBlock;
        uint256 stakedMCooldown;
        string stakedMName;
        string stakedMSymbol;
        // --- 资产与托管 ---
        address[] assets;
        uint256 maxMintPerBlock;
        uint256 maxRedeemPerBlock;
        address[] custodians;
        // --- 预言机（与 assets 逐位对齐；chainlinkFeeds 为空则整体跳过核对）---
        address[] chainlinkFeeds;
        bytes32[] pythFeeds;
        address expectedPyth; // 0 = 只要求非零
        uint128 oracleMaxAge;
        uint128 oracleMaxDeviation;
        bool checkOracleLiveness; // 是否真的调一次 getPrice
        // --- 角色 ---
        address[] operators; // MINTER + REDEEMER（+ 分发器 OPERATOR）；空则视为 [deployer]（同部署脚本默认）
        address[] gatekeepers; // GATEKEEPER；空则视为 [deployer]
        address[] rewarders; // StakedM REWARDER，分发器之外另有热钱包时填写
        // --- 其它 ---
        bool expectFreshVault; // 期望 sM 尚未有存款/奖励（部署后立刻校验时为 true）
        address[] extraProbes; // 额外要核对的地址（例如旧的运营地址）
    }

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @dev 与 MonogramMinting 内部 private 常量一致的 keccak 值（合约未暴露，见 issue #23）
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 internal constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 internal constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");

    uint256 private _passed;
    uint256 private _warnings;

    /* ------------------------------- 入口 ------------------------------- */

    function check(Deployment memory d) external {
        _passed = 0;
        _warnings = 0;

        console.log("");
        console.log(unicode"=== Monogram 部署后校验 ===");
        uint256 before = _passed;
        _requireContractsExist(d);
        _section(unicode"地址存在", before);
        before = _passed;
        _checkWiring(d);
        _section(unicode"接线", before);
        before = _passed;
        _checkMetadata(d);
        _section(unicode"代币元数据", before);
        before = _passed;
        _checkAdmins(d);
        _section(unicode"admin/owner", before);
        before = _passed;
        _checkRoles(d);
        _section(unicode"角色", before);
        before = _passed;
        _checkParams(d);
        _section(unicode"参数", before);
        before = _passed;
        _checkAssets(d);
        _section(unicode"资产与托管", before);
        before = _passed;
        _checkOracles(d);
        _section(unicode"预言机", before);

        console.log("");
        console.log(unicode"=== 通过 %s 项断言，%s 项警告 ===", _passed, _warnings);
        console.log("Post-deploy check PASSED");
    }

    /// @dev 逐段汇报通过项数：让运行输出本身就是一份可核对的证据链
    function _section(string memory name, uint256 passedBefore) internal view {
        console.log(unicode"  [%s] %s 项通过", name, _passed - passedBefore);
    }

    /* ---------------------------- 0. 地址存在 ---------------------------- */

    /// @dev 先确认地址上真的有代码：本地彩排/抄错地址时最典型的表现就是 code = 0x
    function _requireContractsExist(Deployment memory d) internal {
        _requireCode(d.m, "M");
        _requireCode(d.priceFeed, "MonogramPriceFeed");
        _requireCode(d.minting, "MonogramMinting");
        _requireCode(d.stakedM, "StakedM");
        _requireCode(d.distributor, "StakingRewardsDistributor");
    }

    function _requireCode(address target, string memory name) internal {
        _require(target.code.length > 0, string.concat(name, unicode" 地址上没有合约代码"));
    }

    /* ------------------------------ 1. 接线 ------------------------------ */

    function _checkWiring(Deployment memory d) internal {
        M m = M(d.m);
        MonogramMinting minting = MonogramMinting(payable(d.minting));
        MonogramPriceFeed feed = MonogramPriceFeed(d.priceFeed);
        StakedM stakedM = StakedM(d.stakedM);
        StakingRewardsDistributor distributor = StakingRewardsDistributor(d.distributor);

        _requireEq(address(m.minter()), d.minting, "M.minter != MonogramMinting");
        _requireEq(address(minting.m()), d.m, "MonogramMinting.m != M");
        _requireEq(address(minting.priceFeed()), d.priceFeed, "MonogramMinting.priceFeed != PriceFeed");
        _requireEq(stakedM.asset(), d.m, "StakedM.asset != M");
        _requireEq(address(distributor.stakedM()), d.stakedM, unicode"分发器.stakedM != StakedM");
        _requireEq(address(distributor.m()), d.m, unicode"分发器.m != M");
        _require(feed.pyth() != address(0), unicode"PriceFeed.pyth == 0（预言机不可用）");
        if (d.expectedPyth != address(0)) {
            _requireEq(feed.pyth(), d.expectedPyth, unicode"PriceFeed.pyth != 预期地址");
        }
    }

    /* --------------------------- 2. 代币元数据 --------------------------- */

    function _checkMetadata(Deployment memory d) internal {
        _require(
            keccak256(bytes(M(d.m).name())) == keccak256("M") && keccak256(bytes(M(d.m).symbol())) == keccak256("M"),
            unicode"M 的 name/symbol 不是 M"
        );
        _require(
            keccak256(bytes(StakedM(d.stakedM).name())) == keccak256(bytes(d.stakedMName)),
            unicode"StakedM.name != 预期"
        );
        _require(
            keccak256(bytes(StakedM(d.stakedM).symbol())) == keccak256(bytes(d.stakedMSymbol)),
            unicode"StakedM.symbol != 预期"
        );
    }

    /* ---------------------------- 3. admin/owner ---------------------------- */

    function _checkAdmins(Deployment memory d) internal {
        MonogramPriceFeed feed = MonogramPriceFeed(d.priceFeed);

        _checkOwnable2Step(M(d.m), d.mOwnership, "M");
        _checkSingleAdmin(ISingleAdminAccessControl(d.minting), d.mintingAdmin, "MonogramMinting");
        _checkSingleAdmin(ISingleAdminAccessControl(d.stakedM), d.stakedMAdmin, "StakedM");
        _checkRoleSet(feed, DEFAULT_ADMIN_ROLE, d.feedAdmins, _probeSet(d), unicode"PriceFeed.DEFAULT_ADMIN_ROLE");
        _checkRoleSet(feed, feed.ORACLE_ADMIN_ROLE(), d.feedAdmins, _probeSet(d), unicode"PriceFeed.ORACLE_ADMIN_ROLE");
        _checkRoleSet(
            StakingRewardsDistributor(d.distributor),
            DEFAULT_ADMIN_ROLE,
            d.distributorAdmins,
            _probeSet(d),
            unicode"分发器.DEFAULT_ADMIN_ROLE"
        );
    }

    function _checkOwnable2Step(M m, Handover memory expected, string memory name) internal {
        _requireEq(m.owner(), expected.owner, string.concat(name, unicode".owner != 预期"));
        _requireEq(m.pendingOwner(), expected.pending, string.concat(name, unicode".pendingOwner != 预期"));
    }

    function _checkSingleAdmin(ISingleAdminAccessControl target, Handover memory expected, string memory name)
        internal
    {
        _requireEq(target.owner(), expected.owner, string.concat(name, unicode".owner != 预期"));
        _requireEq(target.pendingAdmin(), expected.pending, string.concat(name, unicode".pendingAdmin != 预期"));
        if (expected.pending != address(0)) {
            _warn(
                string.concat(
                    name,
                    unicode" 的 admin 移交待接受：",
                    Strings.toHexString(expected.pending),
                    unicode" 需调用 acceptAdmin()"
                )
            );
        }
    }

    /* -------------------------------- 4. 角色 -------------------------------- */

    function _checkRoles(Deployment memory d) internal {
        MonogramMinting minting = MonogramMinting(payable(d.minting));
        StakingRewardsDistributor distributor = StakingRewardsDistributor(d.distributor);
        StakedM stakedM = StakedM(d.stakedM);
        address[] memory probes = _probeSet(d);

        _checkRoleSet(minting, MINTER_ROLE, d.operators, probes, "MonogramMinting.MINTER_ROLE");
        _checkRoleSet(minting, REDEEMER_ROLE, d.operators, probes, "MonogramMinting.REDEEMER_ROLE");
        _checkRoleSet(minting, GATEKEEPER_ROLE, d.gatekeepers, probes, "MonogramMinting.GATEKEEPER_ROLE");
        _checkRoleSet(distributor, distributor.OPERATOR_ROLE(), d.operators, probes, unicode"分发器.OPERATOR_ROLE");

        address[] memory expectedRewarders = new address[](d.rewarders.length + 1);
        expectedRewarders[0] = d.distributor;
        for (uint256 i = 0; i < d.rewarders.length; i++) {
            expectedRewarders[i + 1] = d.rewarders[i];
        }
        _checkRoleSet(stakedM, stakedM.REWARDER_ROLE(), expectedRewarders, probes, "StakedM.REWARDER_ROLE");

        // 以下角色不判失败：授予时机是运行期决策，部署脚本本就不授予
        _reportRole(
            minting,
            COLLATERAL_MANAGER_ROLE,
            probes,
            "MonogramMinting.COLLATERAL_MANAGER_ROLE",
            unicode"OES 接入时授予（#8）"
        );
        _reportRole(
            stakedM,
            stakedM.BLACKLIST_MANAGER_ROLE(),
            probes,
            "StakedM.BLACKLIST_MANAGER_ROLE",
            unicode"合规处置按需授予"
        );
        _reportRole(
            stakedM,
            stakedM.SOFT_RESTRICTED_STAKER_ROLE(),
            probes,
            "StakedM.SOFT_RESTRICTED_STAKER_ROLE",
            unicode"合规名单"
        );
        _reportRole(
            stakedM,
            stakedM.FULL_RESTRICTED_STAKER_ROLE(),
            probes,
            "StakedM.FULL_RESTRICTED_STAKER_ROLE",
            unicode"合规名单"
        );
    }

    /// @dev 期望名单全员在册 + 探针集合内「持有情况与期望完全一致」
    function _checkRoleSet(
        IAccessControl target,
        bytes32 role,
        address[] memory expected,
        address[] memory probes,
        string memory label
    ) internal {
        _require(
            expected.length > 0,
            string.concat(label, unicode": 期望名单为空（部署后应至少有一名持有者）")
        );
        for (uint256 i = 0; i < expected.length; i++) {
            _require(
                target.hasRole(role, expected[i]),
                string.concat(label, unicode": 期望持有者未持有 ", _hex(expected[i]))
            );
        }
        for (uint256 i = 0; i < probes.length; i++) {
            bool want = _contains(expected, probes[i]);
            bool actual = target.hasRole(role, probes[i]);
            if (want != actual) {
                revert InvariantFailed(string.concat(
                        label,
                        actual ? unicode": 多出的持有者 " : unicode": 缺少持有者 ",
                        _hex(probes[i]),
                        unicode"（探针集合内）"
                    ));
            }
        }
    }

    /// @dev 只报告不判失败：打印探针集合里的持有者
    function _reportRole(
        IAccessControl target,
        bytes32 role,
        address[] memory probes,
        string memory label,
        string memory note
    ) internal {
        uint256 count = 0;
        for (uint256 i = 0; i < probes.length; i++) {
            if (target.hasRole(role, probes[i])) {
                console.log(unicode"  [角色] %s 由 %s 持有（%s）", label, _hex(probes[i]), note);
                count++;
            }
        }
        if (count == 0) {
            console.log(unicode"  [角色] %s 当前无人持有（%s）", label, note);
        }
    }

    /// @notice 探针地址集合：期望角色名单 + 各方地址 + 额外指定
    function _probeSet(Deployment memory d) internal pure returns (address[] memory) {
        uint256 n = 7 + d.operators.length + d.gatekeepers.length + d.custodians.length + d.rewarders.length
            + d.extraProbes.length;
        address[] memory probes = new address[](n);
        uint256 k = 0;
        probes[k++] = d.deployer;
        probes[k++] = d.admin;
        probes[k++] = d.m;
        probes[k++] = d.priceFeed;
        probes[k++] = d.minting;
        probes[k++] = d.stakedM;
        probes[k++] = d.distributor;
        for (uint256 i = 0; i < d.operators.length; i++) {
            probes[k++] = d.operators[i];
        }
        for (uint256 i = 0; i < d.gatekeepers.length; i++) {
            probes[k++] = d.gatekeepers[i];
        }
        for (uint256 i = 0; i < d.custodians.length; i++) {
            probes[k++] = d.custodians[i];
        }
        for (uint256 i = 0; i < d.rewarders.length; i++) {
            probes[k++] = d.rewarders[i];
        }
        for (uint256 i = 0; i < d.extraProbes.length; i++) {
            probes[k++] = d.extraProbes[i];
        }
        return probes;
    }

    /* ------------------------------- 5. 参数 ------------------------------- */

    function _checkParams(Deployment memory d) internal {
        MonogramMinting minting = MonogramMinting(payable(d.minting));
        StakedM stakedM = StakedM(d.stakedM);

        _require(
            minting.whitelistEnabled() == d.whitelistEnabled,
            string.concat(
                unicode"whitelistEnabled != 预期（链上 ",
                minting.whitelistEnabled() ? "true" : "false",
                unicode"，注意单向棘轮不可逆）"
            )
        );
        if (d.whitelistEnabled) {
            for (uint256 i = 0; i < d.benefactors.length; i++) {
                _require(
                    minting.isWhitelistedBenefactor(d.benefactors[i]),
                    string.concat(unicode"白名单缺少 benefactor ", _hex(d.benefactors[i]))
                );
            }
            _warn(unicode"白名单已启用且不可逆：请确认 KYB 名单完整（#11 决议）");
        }
        _requireEq(minting.maxPriceDeviationBps(), d.maxPriceDeviationBps, unicode"maxPriceDeviationBps != 预期");
        (uint256 globalMint, uint256 globalRedeem) = minting.globalConfig();
        _requireEq(globalMint, d.globalMaxMintPerBlock, unicode"globalMaxMintPerBlock != 预期");
        _requireEq(globalRedeem, d.globalMaxRedeemPerBlock, unicode"globalMaxRedeemPerBlock != 预期");
        _requireEq(uint256(stakedM.cooldownDuration()), d.stakedMCooldown, unicode"StakedM.cooldownDuration != 预期");
        if (d.expectFreshVault) {
            _requireEq(stakedM.totalAssets(), 0, unicode"StakedM.totalAssets != 0（不是全新金库？）");
        }
    }

    /* ------------------------------- 6. 资产 ------------------------------- */

    function _checkAssets(Deployment memory d) internal {
        MonogramMinting minting = MonogramMinting(payable(d.minting));
        _require(d.assets.length > 0, unicode"预期资产清单为空");
        for (uint256 i = 0; i < d.assets.length; i++) {
            _require(
                minting.isSupportedAsset(d.assets[i]), string.concat(unicode"Assets 未支持 ", _hex(d.assets[i]))
            );
            (bool isActive, uint256 maxMint, uint256 maxRedeem) = minting.tokenConfig(d.assets[i]);
            _require(isActive, string.concat(unicode"tokenConfig.isActive == false ", _hex(d.assets[i])));
            _requireEq(
                maxMint, d.maxMintPerBlock, string.concat(unicode"maxMintPerBlock != 预期 ", _hex(d.assets[i]))
            );
            _requireEq(
                maxRedeem, d.maxRedeemPerBlock, string.concat(unicode"maxRedeemPerBlock != 预期 ", _hex(d.assets[i]))
            );
        }
        for (uint256 i = 0; i < d.custodians.length; i++) {
            _require(
                minting.isCustodianAddress(d.custodians[i]),
                string.concat(unicode"custodian 未注册 ", _hex(d.custodians[i]))
            );
        }
    }

    /* ------------------------------ 7. 预言机 ------------------------------ */

    function _checkOracles(Deployment memory d) internal {
        MonogramPriceFeed feed = MonogramPriceFeed(d.priceFeed);

        if (d.chainlinkFeeds.length == 0) {
            _warn(unicode"未提供 CHAINLINK_FEEDS，跳过预言机配置核对（仅适用于本地彩排）");
            return;
        }
        _require(
            d.chainlinkFeeds.length == d.assets.length,
            unicode"CHAINLINK_FEEDS 与 ASSETS 长度不一致（应逐位对齐）"
        );
        _require(
            d.pythFeeds.length == 0 || d.pythFeeds.length == d.assets.length,
            unicode"PYTH_FEED_IDS 与 ASSETS 长度不一致（应逐位对齐）"
        );

        for (uint256 i = 0; i < d.assets.length; i++) {
            (bytes32 pythFeed, address chainlinkFeed, uint128 maxAge, uint128 maxDeviation, bool exists) =
                feed.configs(d.assets[i]);
            string memory label = string.concat("oracleConfig[", _hex(d.assets[i]), "]");
            _require(exists, string.concat(label, unicode" 未配置"));
            _requireEq(chainlinkFeed, d.chainlinkFeeds[i], string.concat(label, unicode".chainlinkFeed != 预期"));
            _requireEq(uint256(maxAge), uint256(d.oracleMaxAge), string.concat(label, unicode".maxAge != 预期"));
            _requireEq(
                uint256(maxDeviation),
                uint256(d.oracleMaxDeviation),
                string.concat(label, unicode".maxDeviation != 预期")
            );
            bytes32 expectedPyth = d.pythFeeds.length == 0 ? bytes32(0) : d.pythFeeds[i];
            _require(pythFeed == expectedPyth, string.concat(label, unicode".pythFeed != 预期"));
        }

        if (!d.checkOracleLiveness) {
            _warn(
                unicode"CHECK_ORACLE_LIVENESS=false：未实际读取预言机价格（只适用于本地/模拟环境）"
            );
            return;
        }
        for (uint256 i = 0; i < d.assets.length; i++) {
            try feed.getPrice(d.assets[i]) returns (uint256 price, uint256 updatedAt) {
                _require(price > 0, string.concat(unicode"getPrice 返回 0 ", _hex(d.assets[i])));
                _require(updatedAt > 0, string.concat(unicode"getPrice 时间戳为 0 ", _hex(d.assets[i])));
            } catch {
                revert InvariantFailed(string.concat(
                        unicode"getPrice 回滚，预言机接线或价格不可用 ", _hex(d.assets[i])
                    ));
            }
        }
    }

    /* -------------------------------- 工具 -------------------------------- */

    function _require(bool condition, string memory what) internal {
        if (!condition) revert InvariantFailed(what);
        _passed++;
    }

    function _requireEq(address actual, address expected, string memory what) internal {
        if (actual != expected) {
            revert InvariantFailed(string.concat(
                    what, unicode"（链上 ", _hex(actual), unicode"，预期 ", _hex(expected), unicode"）"
                ));
        }
        _passed++;
    }

    function _requireEq(uint256 actual, uint256 expected, string memory what) internal {
        if (actual != expected) {
            revert InvariantFailed(string.concat(
                    what,
                    unicode"（链上 ",
                    Strings.toString(actual),
                    unicode"，预期 ",
                    Strings.toString(expected),
                    unicode"）"
                ));
        }
        _passed++;
    }

    function _warn(string memory what) internal {
        _warnings++;
        console.log(unicode"  [WARN] %s", what);
    }

    function _contains(address[] memory list, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == needle) return true;
        }
        return false;
    }

    function _hex(address a) internal pure returns (string memory) {
        return Strings.toHexString(a);
    }

    /* ------------------------------ 只读视图 ------------------------------ */

    /// @notice 上次 check() 的统计，供脚本/测试断言「0 警告」之类的收尾条件
    function lastRun() external view returns (uint256 passed, uint256 warnings) {
        return (_passed, _warnings);
    }
}
