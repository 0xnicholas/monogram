// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "../src/M.sol";
import "../src/MonogramMinting.sol";
import "../src/MonogramPriceFeed.sol";
import "../src/StakedM.sol";
import "../src/StakingRewardsDistributor.sol";
import "../src/interfaces/IMonogramMinting.sol";
import "../src/interfaces/IMonogramPriceFeed.sol";
import "../src/interfaces/IPyth.sol";
import "../src/interfaces/AggregatorV3Interface.sol";
import "../script/lib/PostDeployChecker.sol";
import "../script/PostDeployCheck.s.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Test Collateral", "TC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPyth is IPyth {
    mapping(bytes32 => Price) public prices;

    function setPrice(bytes32 feedId, Price memory price) external {
        prices[feedId] = price;
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        return prices[id];
    }
}

contract MockChainlinkFeed is AggregatorV3Interface {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;

    function setAnswer(int256 _answer, uint8 _decimals) external {
        answer = _answer;
        decimals = _decimals;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }
}

/**
 * @title PostDeployCheckTest — 部署后校验器自身的测试
 * @notice 验收标准（issue #21）：对一个「正确」的部署全绿；故意改坏任一参数就红。
 *         setUp 复刻 DeployM.s.sol 的部署序列（第 1~11 步），这样校验器断言的正是部署脚本的产物。
 */
contract PostDeployCheckTest is Test {
    M public m;
    MonogramPriceFeed public feed;
    MonogramMinting public minting;
    StakedM public stakedM;
    StakingRewardsDistributor public distributor;
    MockAsset public asset;
    MockPyth public mockPyth;
    MockChainlinkFeed public clFeed;
    PostDeployChecker public checker;
    PostDeployCheck public checkScript;

    address public deployer = makeAddr("deployer");
    address public operator = makeAddr("operator");
    address public gatekeeper = makeAddr("gatekeeper");
    address public custodian = makeAddr("custodian");
    address public multisig = makeAddr("multisig");

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 public constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");

    bytes32 public constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    uint256 public constant MAX_PER_BLOCK = 1_000_000 ether;
    uint128 public constant ORACLE_MAX_AGE = 24 hours;
    uint128 public constant ORACLE_MAX_DEVIATION = 500;

    function setUp() public {
        vm.warp(1_700_000_000);
        // 预先创建：vm.expectRevert 会被下一个 call 消费，而 `new` 也是一次 call
        checker = new PostDeployChecker();
        checkScript = new PostDeployCheck();

        vm.startPrank(deployer);

        // 1. M
        m = new M(deployer);
        // 2~3. 抵押品与预言机
        asset = new MockAsset();
        mockPyth = new MockPyth();
        clFeed = new MockChainlinkFeed();
        feed = new MonogramPriceFeed(deployer, address(mockPyth));

        // 4. MonogramMinting
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory custodians = new address[](1);
        custodians[0] = custodian;
        IMonogramMinting.TokenConfig[] memory tokenConfigs = new IMonogramMinting.TokenConfig[](1);
        tokenConfigs[0] = IMonogramMinting.TokenConfig({
            isActive: true, maxMintPerBlock: MAX_PER_BLOCK, maxRedeemPerBlock: MAX_PER_BLOCK
        });
        IMonogramMinting.GlobalConfig memory globalConfig = IMonogramMinting.GlobalConfig({
            globalMaxMintPerBlock: MAX_PER_BLOCK, globalMaxRedeemPerBlock: MAX_PER_BLOCK
        });

        minting = new MonogramMinting(
            IM(address(m)),
            IWETH9(payable(address(0))),
            IMonogramPriceFeed(address(feed)),
            assets,
            tokenConfigs,
            globalConfig,
            custodians,
            deployer
        );

        // 5. M minter
        m.setMinter(address(minting));

        // 8~9. StakedM + 分发器，REWARDER 占位授权撤销
        stakedM = new StakedM(IERC20(address(m)), deployer, deployer, "Staked Monogram", "sM");
        distributor = new StakingRewardsDistributor(IStakedM(address(stakedM)), IM(address(m)), deployer);
        stakedM.grantRole(REWARDER_ROLE, address(distributor));
        stakedM.revokeRole(REWARDER_ROLE, deployer);

        // 10. 运营角色
        minting.grantRole(MINTER_ROLE, operator);
        minting.grantRole(REDEEMER_ROLE, operator);
        minting.grantRole(GATEKEEPER_ROLE, gatekeeper);
        distributor.grantRole(distributor.OPERATOR_ROLE(), operator);

        // 11. 预言机配置
        feed.setOracleConfig(address(asset), ETH_USD_FEED_ID, address(clFeed), ORACLE_MAX_AGE, ORACLE_MAX_DEVIATION);

        vm.stopPrank();

        // 双源价格一致且新鲜：Pyth 2000.00000000（expo -8）、Chainlink 2000e8（8 位小数）
        mockPyth.setPrice(
            ETH_USD_FEED_ID, IPyth.Price({price: 2000e8, conf: 1e8, expo: -8, publishTime: uint64(block.timestamp)})
        );
        clFeed.setAnswer(2000e8, 8);
    }

    /* ------------------------------- 工具 ------------------------------- */

    /// @notice 与 setUp 产出的「正确部署」对应的预期状态
    function _deployment() internal view returns (PostDeployChecker.Deployment memory d) {
        d.m = address(m);
        d.priceFeed = address(feed);
        d.minting = address(minting);
        d.stakedM = address(stakedM);
        d.distributor = address(distributor);

        d.admin = deployer;
        d.deployer = deployer;
        d.mOwnership = PostDeployChecker.Handover({owner: deployer, pending: address(0)});
        d.mintingAdmin = PostDeployChecker.Handover({owner: deployer, pending: address(0)});
        d.stakedMAdmin = PostDeployChecker.Handover({owner: deployer, pending: address(0)});
        d.feedAdmins = _single(deployer);
        d.distributorAdmins = _single(deployer);

        d.whitelistEnabled = false;
        d.benefactors = new address[](0);
        d.maxPriceDeviationBps = 500;
        d.globalMaxMintPerBlock = MAX_PER_BLOCK;
        d.globalMaxRedeemPerBlock = MAX_PER_BLOCK;
        d.maxMintPerBlock = MAX_PER_BLOCK;
        d.maxRedeemPerBlock = MAX_PER_BLOCK;
        d.stakedMCooldown = uint256(stakedM.MAX_COOLDOWN_DURATION());
        d.stakedMName = "Staked Monogram";
        d.stakedMSymbol = "sM";

        d.assets = _single(address(asset));
        d.custodians = _single(custodian);

        d.chainlinkFeeds = _single(address(clFeed));
        d.pythFeeds = new bytes32[](1);
        d.pythFeeds[0] = ETH_USD_FEED_ID;
        d.expectedPyth = address(mockPyth);
        d.oracleMaxAge = ORACLE_MAX_AGE;
        d.oracleMaxDeviation = ORACLE_MAX_DEVIATION;
        d.checkOracleLiveness = true;

        d.operators = _single(operator);
        d.gatekeepers = _single(gatekeeper);
        d.rewarders = new address[](0);

        d.expectFreshVault = true;
        d.extraProbes = new address[](0);
    }

    function _single(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _check(PostDeployChecker.Deployment memory d) internal {
        checker.check(d);
    }

    function _expectFailed(string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(PostDeployChecker.InvariantFailed.selector, what));
    }

    /* ------------------------------ 绿：正确部署 ------------------------------ */

    function test_Check_PassesOnCorrectDeployment() public {
        _check(_deployment());
        (uint256 passed, uint256 warnings) = checker.lastRun();
        assertGt(passed, 40, unicode"断言数量异常");
        assertEq(warnings, 0, unicode"正确部署不应有警告");
    }

    function test_Check_WarnsWhenOracleConfigNotProvided() public {
        PostDeployChecker.Deployment memory d = _deployment();
        d.chainlinkFeeds = new address[](0);
        d.pythFeeds = new bytes32[](0);
        d.expectedPyth = address(0);

        _check(d);
        (, uint256 warnings) = checker.lastRun();
        assertEq(warnings, 1, unicode"应警告「未提供 CHAINLINK_FEEDS，跳过核对」");
    }

    function test_Check_WarnsWhenLivenessDisabled() public {
        PostDeployChecker.Deployment memory d = _deployment();
        d.checkOracleLiveness = false;

        _check(d);
        (, uint256 warnings) = checker.lastRun();
        assertEq(warnings, 1, unicode"应警告「未实际读取预言机价格」");
    }

    function test_Check_PassesOnPendingAdminHandover() public {
        // 生产序列：M / MonogramMinting / StakedM 已请求移交（待多签 acceptAdmin）；
        // PriceFeed 与分发器（OZ AccessControl，无两步移交）直接授予多签并撤销部署者
        vm.startPrank(deployer);
        m.transferOwnership(multisig);
        minting.transferAdmin(multisig);
        stakedM.transferAdmin(multisig);
        feed.grantRole(feed.DEFAULT_ADMIN_ROLE(), multisig);
        feed.grantRole(feed.ORACLE_ADMIN_ROLE(), multisig);
        // DEFAULT_ADMIN_ROLE 必须最后撤销：revokeRole 自身也受 onlyRole(getRoleAdmin) 约束
        feed.revokeRole(feed.ORACLE_ADMIN_ROLE(), deployer);
        feed.revokeRole(feed.DEFAULT_ADMIN_ROLE(), deployer);
        distributor.grantRole(distributor.DEFAULT_ADMIN_ROLE(), multisig);
        distributor.revokeRole(distributor.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();

        PostDeployChecker.Deployment memory d = _deployment();
        d.admin = multisig;
        d.mOwnership = PostDeployChecker.Handover({owner: deployer, pending: multisig});
        d.mintingAdmin = PostDeployChecker.Handover({owner: deployer, pending: multisig});
        d.stakedMAdmin = PostDeployChecker.Handover({owner: deployer, pending: multisig});
        d.feedAdmins = _single(multisig);
        d.distributorAdmins = _single(multisig);

        _check(d);
        (uint256 passed,) = checker.lastRun();
        assertGt(passed, 40);
    }

    /* --------------------------- 红：逐项改坏 --------------------------- */

    function test_Check_FailsWhenCodeMissing() public {
        PostDeployChecker.Deployment memory d = _deployment();
        d.m = makeAddr("noCode");
        _expectFailed(unicode"M 地址上没有合约代码");
        _check(d);
    }

    function test_Check_FailsWhenMinterNotMinting() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        m.setMinter(operator);
        _expectFailed(
            string.concat(
                "M.minter != MonogramMinting",
                unicode"（链上 ",
                Strings.toHexString(operator),
                unicode"，预期 ",
                Strings.toHexString(address(minting)),
                unicode"）"
            )
        );
        _check(d);
    }

    /// @dev 部署脚本未配置 OPERATORS 时的最典型形态：运营角色残留在部署者手上
    function test_Check_FailsWhenDeployerKeepsOperatorRole() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        minting.grantRole(MINTER_ROLE, deployer);
        _expectFailed(
            string.concat(
                "MonogramMinting.MINTER_ROLE",
                unicode": 多出的持有者 ",
                Strings.toHexString(deployer),
                unicode"（探针集合内）"
            )
        );
        _check(d);
    }

    function test_Check_FailsWhenExpectedOperatorLacksRole() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        minting.revokeRole(MINTER_ROLE, operator);

        _expectFailed(
            string.concat(
                "MonogramMinting.MINTER_ROLE", unicode": 期望持有者未持有 ", Strings.toHexString(operator)
            )
        );
        _check(d);
    }

    function test_Check_FailsWhenRewarderPlaceholderNotRevoked() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        stakedM.grantRole(REWARDER_ROLE, deployer);
        _expectFailed(
            string.concat(
                "StakedM.REWARDER_ROLE",
                unicode": 多出的持有者 ",
                Strings.toHexString(deployer),
                unicode"（探针集合内）"
            )
        );
        _check(d);
    }

    function test_Check_FailsWhenOracleMaxAgeDiffers() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        feed.setOracleConfig(address(asset), ETH_USD_FEED_ID, address(clFeed), 1 hours, ORACLE_MAX_DEVIATION);
        _expectFailed(
            string.concat(
                "oracleConfig[",
                Strings.toHexString(address(asset)),
                "]",
                unicode".maxAge != 预期（链上 3600，预期 86400）"
            )
        );
        _check(d);
    }

    function test_Check_FailsWhenWhitelistStateDiffers() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        minting.setWhitelistEnabled(true);
        _expectFailed(unicode"whitelistEnabled != 预期（链上 true，注意单向棘轮不可逆）");
        _check(d);
    }

    function test_Check_FailsWhenCustodianNotRegistered() public {
        PostDeployChecker.Deployment memory d = _deployment();
        address missing = makeAddr("missingCustodian");
        d.custodians = new address[](2);
        d.custodians[0] = custodian;
        d.custodians[1] = missing;
        _expectFailed(string.concat(unicode"custodian 未注册 ", Strings.toHexString(missing)));
        _check(d);
    }

    function test_Check_FailsWhenCooldownDiffers() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        stakedM.setCooldownDuration(7 days);
        _expectFailed(
            string.concat(
                unicode"StakedM.cooldownDuration != 预期（链上 ",
                Strings.toString(uint256(7 days)),
                unicode"，预期 ",
                Strings.toString(uint256(stakedM.MAX_COOLDOWN_DURATION())),
                unicode"）"
            )
        );
        _check(d);
    }

    function test_Check_FailsWhenPerBlockLimitDiffers() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(deployer);
        minting.setMaxMintPerBlock(1 ether, address(asset));
        _expectFailed(
            string.concat(
                unicode"maxMintPerBlock != 预期 ",
                Strings.toHexString(address(asset)),
                unicode"（链上 ",
                Strings.toString(uint256(1 ether)),
                unicode"，预期 ",
                Strings.toString(MAX_PER_BLOCK),
                unicode"）"
            )
        );
        _check(d);
    }

    function test_Check_FailsWhenVaultNotEmpty() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.prank(address(minting));
        m.mint(address(this), 1 ether);
        m.approve(address(stakedM), 1 ether);
        stakedM.deposit(1 ether, address(this));
        _expectFailed(
            unicode"StakedM.totalAssets != 0（不是全新金库？）（链上 1000000000000000000，预期 0）"
        );
        _check(d);
    }

    function test_Check_FailsOnDeadOracle() public {
        PostDeployChecker.Deployment memory d = _deployment();
        // Pyth 推送陈旧 → getPrice revert StalePythPrice → 校验器捕获并报错
        mockPyth.setPrice(
            ETH_USD_FEED_ID,
            IPyth.Price({price: 2000e8, conf: 1e8, expo: -8, publishTime: uint64(block.timestamp - 2 days)})
        );
        _expectFailed(
            string.concat(
                unicode"getPrice 回滚，预言机接线或价格不可用 ", Strings.toHexString(address(asset))
            )
        );
        _check(d);
    }

    function test_Check_FailsWhenFeedAdminDiffers() public {
        PostDeployChecker.Deployment memory d = _deployment();
        d.feedAdmins = _single(multisig);
        _expectFailed(
            string.concat(
                "PriceFeed.DEFAULT_ADMIN_ROLE", unicode": 期望持有者未持有 ", Strings.toHexString(multisig)
            )
        );
        _check(d);
    }

    /* --------------------------- 移交模式映射（纯函数） --------------------------- */

    function test_Handover_None() public {
        PostDeployChecker.Deployment memory d = _deployment();
        d = checkScript.applyHandover(d, "none");

        assertEq(d.mintingAdmin.owner, deployer);
        assertEq(d.mintingAdmin.pending, address(0));
        assertEq(d.stakedMAdmin.owner, deployer);
        assertEq(d.feedAdmins.length, 1);
        assertEq(d.feedAdmins[0], deployer);
        assertEq(d.distributorAdmins[0], deployer);
    }

    function test_Handover_Pending() public {
        PostDeployChecker.Deployment memory d = _deployment();
        d.admin = multisig;
        d = checkScript.applyHandover(d, "pending");

        assertEq(d.mOwnership.owner, deployer, unicode"pending 时 owner 仍是部署者");
        assertEq(d.mOwnership.pending, multisig);
        assertEq(d.mintingAdmin.pending, multisig);
        assertEq(d.stakedMAdmin.pending, multisig);
        assertEq(d.feedAdmins[0], multisig, unicode"无两步移交的合约直接期望多签持有");
    }

    function test_Handover_Done() public {
        PostDeployChecker.Deployment memory d = _deployment();
        d.admin = multisig;
        d = checkScript.applyHandover(d, "done");

        assertEq(d.mOwnership.owner, multisig);
        assertEq(d.mOwnership.pending, address(0));
        assertEq(d.mintingAdmin.owner, multisig);
        assertEq(d.stakedMAdmin.owner, multisig);
        assertEq(d.feedAdmins[0], multisig);
    }

    function test_Handover_RevertsOnUnknownMode() public {
        PostDeployChecker.Deployment memory d = _deployment();
        vm.expectRevert("EXPECT_ADMIN_HANDOVER must be none|pending|done");
        checkScript.applyHandover(d, "later");
    }

    function test_Handover_RevertsWhenNoMultisigGiven() public {
        PostDeployChecker.Deployment memory d = _deployment(); // admin == deployer
        vm.expectRevert();
        checkScript.applyHandover(d, "done");
    }

    /* ------------------------------- 冷却期映射 ------------------------------- */

    function test_Cooldown_SentinelMeansConstructorDefault() public view {
        uint256 maxCooldown = uint256(stakedM.MAX_COOLDOWN_DURATION());
        assertEq(checkScript.resolveCooldown(type(uint24).max, maxCooldown), maxCooldown);
    }

    function test_Cooldown_ExplicitValue() public view {
        assertEq(
            checkScript.resolveCooldown(0, uint256(stakedM.MAX_COOLDOWN_DURATION())), 0, unicode"0 = 关闭冷却期"
        );
        assertEq(checkScript.resolveCooldown(7 days, uint256(stakedM.MAX_COOLDOWN_DURATION())), uint256(7 days));
    }

    function test_Cooldown_RevertsAboveUint24() public {
        vm.expectRevert("STAKEDM_COOLDOWN_SECONDS exceeds uint24");
        checkScript.resolveCooldown(uint256(type(uint24).max) + 1, 90 days);
    }
}
