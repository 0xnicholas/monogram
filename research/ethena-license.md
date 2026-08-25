# Ethena 参考源与 License 可行性研究

> 关联 issue：#3「Ethena 参考源与 license 可行性」
> 调研日期：2026-08-25（UTC）。所有链上/网页事实均于当日查证。
> 免责声明：本文为工程调研，不构成法律意见；重大 license 决策请咨询律师。

## TL;DR

- Ethena 核心合约源码有两个公开渠道：**GitHub 存档仓库**（`code4arena-contest`、`bbp-public-assets`）和 **Etherscan 已验证源码**。
- 所有 Ethena 自研合约文件都带 `SPDX-License-Identifier: GPL-3.0`；OpenZeppelin 依赖为 MIT。**没有任何 BUSL-1.1，也不是「无 license」**。
- 主网 5 个核心合约（EthenaMinting V2、USDe、StakedUSDeV2、USDeSilo、StakingRewardsDistributor）在 Etherscan 均为完整验证源码（Exact Match）。
- 注意：GitHub 上的 `EthenaMinting.sol` 是 **V1 时代**的代码；主网 V2 的完整源码**只在 Etherscan 上**，GitHub 无对应版本。
- 结论与建议：Ethena 代码是 **GPL-3.0 强 copyleft**。Monogram 若「默认复刻 V2」，属于衍生作品，最稳妥做法是 **Monogram 整体采用 GPL-3.0**、保留出处声明；若坚持用 MIT 等宽松 license，则必须 clean-room 重写（只参考文档与行为规格，不复用代码表达）。

---

## 1. GitHub 公开仓库

`ethena-labs` 组织共 13 个公开仓库（2026-08-25 查询 [GitHub API](https://api.github.com/orgs/ethena-labs/repos)）。与合约源码相关的只有 3 个，其余为 SDK/工具：

| 仓库 | 状态 | 仓库级 LICENSE | 文件 SPDX | 内容 |
|---|---|---|---|---|
| [ethena-labs/code4arena-contest](https://github.com/ethena-labs/code4arena-contest) | 已存档（2024-02 最后推送） | **GPL-3.0**（GitHub API `license.spdx_id = GPL-3.0`） | GPL-3.0 | 2023-10 Code4rena 审计代码快照（V1 时代），`protocols/USDe/contracts/` 下含 USDe/EthenaMinting/StakedUSDe/StakedUSDeV2/USDeSilo 等 |
| [ethena-labs/bbp-public-assets](https://github.com/ethena-labs/bbp-public-assets) | 已存档（2026-01-20 设为只读，2025-10 最后推送） | **无仓库级 LICENSE 文件**（GitHub API `license = null`） | **GPL-3.0**（每个合约文件头部） | Immunefi 赏金计划公开资产：完整合约源码 + 测试。`contracts/contracts/` 下含 USDe.sol、EthenaMinting.sol、StakedUSDe.sol、StakedUSDeV2.sol、USDeSilo.sol、StakingRewardsDistributor.sol、SingleAdminAccessControl.sol、ENA.sol 等 |
| [ethena-labs/ethena-usdtb-contest](https://github.com/ethena-labs/ethena-usdtb-contest) | 已存档 | 无仓库级 LICENSE | GPL-3.0（如 [USDtbMinting.sol](https://raw.githubusercontent.com/ethena-labs/ethena-usdtb-contest/main/contracts/usdtb/USDtbMinting.sol)） | USDtb（贝莱德 BUIDL 抵押版）审计代码 |

其余仓库（无核心合约源码）：`ethena-minting-client`/`usdtb-minting-client`/`usdm-minting-client`（铸造客户端，无 license）、`suiusde-sdk`（MIT）、`hyperliquid-python-sdk-july25`（MIT）、`role-verification`、`ethena_sats_adapters`、`example-native-token-transfers`（Wormhole NTT fork）等。来源：[ethena-labs 仓库列表](https://github.com/orgs/ethena-labs/repositories)。

要点：

- `bbp-public-assets` 虽然没有仓库级 LICENSE 文件，但**每个 Solidity 文件头部的 SPDX 注释本身即构成逐文件的 GPL-3.0 授权声明**（SPDX 的标准用途）；`code4arena-contest` 又有仓库级 GPL-3.0 LICENSE，双重印证 Ethena 对核心合约的授权意图就是 GPL-3.0。
- 各文件 SPDX 实测：
  - [USDe.sol](https://raw.githubusercontent.com/ethena-labs/bbp-public-assets/main/contracts/contracts/USDe.sol)：`GPL-3.0`
  - [EthenaMinting.sol](https://raw.githubusercontent.com/ethena-labs/bbp-public-assets/main/contracts/contracts/EthenaMinting.sol)：`GPL-3.0`
  - [StakedUSDe.sol](https://raw.githubusercontent.com/ethena-labs/bbp-public-assets/main/contracts/contracts/StakedUSDe.sol) / [StakedUSDeV2.sol](https://raw.githubusercontent.com/ethena-labs/bbp-public-assets/main/contracts/contracts/StakedUSDeV2.sol) / [USDeSilo.sol](https://raw.githubusercontent.com/ethena-labs/bbp-public-assets/main/contracts/contracts/USDeSilo.sol) / [StakingRewardsDistributor.sol](https://raw.githubusercontent.com/ethena-labs/bbp-public-assets/main/contracts/contracts/StakingRewardsDistributor.sol) / [SingleAdminAccessControl.sol](https://raw.githubusercontent.com/ethena-labs/bbp-public-assets/main/contracts/contracts/SingleAdminAccessControl.sol)：均 `GPL-3.0`
- 官方文档的合约说明见 [Ethena Docs — GitHub Overview](https://docs.ethena.fi/technical-design/overview/github-overview)。

## 2. Etherscan 已验证源码

地址以官方文档 [Key Addresses](https://docs.ethena.fi/technical-design/key-addresses) 为准。五个核心合约**全部有完整验证源码**（多文件验证，Exact Match），Ethena 自研文件 SPDX 均为 `GPL-3.0`，OpenZeppelin 依赖文件为 `MIT`：

| 合约 | 地址 | 验证 | 编译器 | SPDX（自研文件） |
|---|---|---|---|---|
| EthenaMinting **V2** | [0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3](https://etherscan.io/address/0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3#code) | ✅ Exact Match | v0.8.20+commit.a1b79de6，20k runs，shanghai | GPL-3.0（EthenaMinting、SingleAdminAccessControl、接口等 4 个文件）+ MIT（OZ，21+ 文件） |
| EthenaMinting **V1** | [0x2cc440b721d2cafd6d64908d6d8c4acc57f8afc3](https://etherscan.io/address/0x2cc440b721d2cafd6d64908d6d8c4acc57f8afc3#code) | ✅ | v0.8.19+commit.7dd6d404 | GPL-3.0 + MIT（OZ） |
| USDe | [0x4c9EDD5852cd905f086C759E8383e09bff1E68B3](https://etherscan.io/address/0x4c9EDD5852cd905f086C759E8383e09bff1E68B3#code) | ✅ | — | GPL-3.0 + MIT（OZ） |
| StakedUSDeV2（sUSDe） | [0x9D39A5DE30e57443BfF2A8307A4256c8797A3497](https://etherscan.io/address/0x9D39A5DE30e57443BfF2A8307A4256c8797A3497#code) | ✅ | — | GPL-3.0 + MIT（OZ） |
| USDeSilo | [0x7fc7c91d556b400afa565013e3f32055a0713425](https://etherscan.io/address/0x7fc7c91d556b400afa565013e3f32055a0713425#code) | ✅ Exact Match | v0.8.19+commit.7dd6d404 | GPL-3.0 + MIT（OZ） |
| StakingRewardsDistributor | [0xf2fa332bd83149c66b09b45670bce64746c6b439](https://etherscan.io/address/0xf2fa332bd83149c66b09b45670bce64746c6b439#code) | ✅ | — | GPL-3.0 + MIT（OZ） |

补充说明：

- USDeSilo 地址未在官方 key-addresses 页面列出，本次通过主网 `eth_call` 读取 sUSDe 的 `silo()`（selector `0xeb3beb29`）得到 `0x7fc7c91d556b400afa565013e3f32055a0713425`，并与「sUSDe 地址 + nonce 1 的 CREATE 地址」推导一致（构造函数内 `silo = new USDeSilo(...)`）。
- Etherscan 页面上的「License」栏对这些多文件验证合约显示 `-NA-`（因为源码内混有 GPL-3.0 与 MIT 两类 SPDX，无法单一归类），**不代表没有 license**——逐文件的 SPDX 标识是确定 license 的依据。
- 重要差异：**GitHub `bbp-public-assets` 中的 `EthenaMinting.sol` 是 V1 时代的实现**（与 V1 链上代码功能一致：route、delegatedSigner、mintWETH、全局 per-block 限额）。主网 V2 合约的完整源码目前只在 Etherscan 可见，GitHub 上没有对应版本——复刻 V2 时应以 Etherscan 验证源码为准。

## 3. V1 vs V2 差异

### 3.1 EthenaMinting V1 → V2

基于 V1/V2 的 Etherscan 验证源码与 ABI 对比：

V1（`0x2cc4...afc3`，2023-12 上线，solc 0.8.19）已有：EIP-712 订单签名、`route`（抵押品按 10000 基点比例分账到多个托管地址）、`delegatedSigner`（合约钱包委托 EOA 签名，仅 ECDSA `ecrecover`）、`mintWETH`（原生 ETH 经 WETH 通道）、全局 `maxMintPerBlock`/`maxRedeemPerBlock`、`GATEKEEPER_ROLE` 紧急关停与移除角色、`COLLATERAL_MANAGER_ROLE` 的 `transferToCustody`。

V2（`0xe349...62D3`，solc 0.8.20）**新增**（以 ABI 实测为准）：

- **EIP-1271 合约签名支持**：`Signature` 增加 `SignatureType` 枚举（EIP712 / EIP1271），新增错误 `InvalidEIP712Signature` / `InvalidEIP1271Signature` / `UnknownSignatureType`——智能合约钱包可直接作为 benefactor 签名，不必再走 delegatedSigner 迂回。
- **`order_id` 字符串字段**：Order 结构体首字段，便于链下订单与链上事件对账（Mint/Redeem 事件以 `order_id` 为首个 indexed 字段）。
- **白名单/KYC**：`addWhitelistedBenefactor` / `isWhitelistedBenefactor`（benefactor 准入）与 `setApprovedBeneficiary` / `isApprovedBeneficiary`（beneficiary 准入），新增错误 `BenefactorNotWhitelisted` / `BeneficiaryNotApproved`。
- **按资产的 per-block 限额**：`tokenConfig[asset] = {tokenType, isActive, maxMintPerBlock, maxRedeemPerBlock}`（uint128 压缩存储）+ `totalPerBlockPerAsset`；同时保留**全局限额** `globalConfig = {globalMaxMintPerBlock, globalMaxRedeemPerBlock}`。
- **稳定币抵押品价格偏差检查**：`stablesDeltaLimit` + `verifyStablesLimit()`（稳定币类抵押品mint/redeem 的报价与 1:1 的偏差上限），`TokenType` 区分 STABLE / UNSTABLE。
- **管理员两步转移**：`transferAdmin` / `acceptAdmin`。
- 类型全面收紧为 uint128/uint120（gas 与存储优化）。

### 3.2 StakedUSDe V1 → V2

注意命名：**主网 sUSDe（`0x9D39...`）自始部署的就是 StakedUSDeV2**（V1 只存在于 2023-10 审计代码中，未作为主网质押合约部署）。两版对比（[code4arena-contest 中的 StakedUSDe.sol](https://github.com/ethena-labs/code4arena-contest) vs StakedUSDeV2.sol）：

- V1 已有：ERC-4626 改造、奖励 **8 小时线性 vesting**（`vestingAmount`，防抢跑）、`REWARDER_ROLE`、`SOFT_RESTRICTED_STAKER_ROLE` / `FULL_RESTRICTED_STAKER_ROLE`（合规冻结/限制，含 `redistributeLockedAmount` 罚没再分配）。
- V2 新增：**提取冷却期** `cooldownShares` / `cooldownAssets`——发起解除质押即销毁 stUSDe，对应 USDe 转入独立的 **USDeSilo** 合约托管，冷却期结束后 `unstake` 取回；`cooldownDuration` 可由 admin 调整（0 表示即时赎回走普通 ERC4626 路径），上限 `MAX_COOLDOWN_DURATION = 90 天`。
- 链上实测：截至 2026-08-25，`cooldownDuration()` = 86400 秒（**1 天**；历史上曾设为 7 天，文档审计口径为 14 天，可随时由 admin 改）。

参考：[bbp-public-assets README（合约架构说明）](https://github.com/ethena-labs/bbp-public-assets)、[Ethena Docs — Staking USDe](https://docs.ethena.fi/technical-design/staking-usde)。

## 4. License 法律分析

### 4.1 事实层

- Ethena 核心合约是 **GPL-3.0**（强 copyleft），不是 BUSL-1.1，也不是「无 license 保留所有权利」。依据：仓库级 LICENSE（code4arena-contest）+ 逐文件 SPDX（bbp-public-assets 及全部 Etherscan 验证源码）。
- 「发布在 Etherscan 上」本身不授予任何权利；但这些已验证源码文件自带 GPL-3.0 SPDX，授权是明确的。
- OpenZeppelin 依赖为 MIT，可自由使用（保留版权声明即可）。

### 4.2 GPL-3.0 对「复刻」的含义

GPL-3.0 授予使用、复制、修改、再发布的自由，但附带强 copyleft 条件：

- **复制或改写 Ethena 文件即产生衍生作品**，再发布（含公开源码仓库；将修改后源码部署并公开验证也极大概率构成 convey）时必须：
  1. 衍生作品整体以 **GPL-3.0** 授权；
  2. 保留原版权声明与 license 文本；
  3. 对修改的文件**标明修改**（prominent notice）。
- GPL-3.0 **不禁止商用**（与 BUSL-1.1 的「竞争性商用冻结期」不同），但任何人都可以再 fork 你的衍生代码——无法靠 license 阻止竞争对手复用。
- GPL-3.0 附带**专利授权条款**（第 11 节），对专利报复有额外保护，这是相对 MIT 的一个优点。
- 如果不想被 copyleft 约束，唯一干净的路径是 **clean-room 重写**：只依据文档、ABI、行为规格重新实现，不复制代码表达（变量命名、结构、注释都不照搬）。「默认复刻 V2 实现」的项目方针与此路径冲突。

### 4.3 对 Monogram 的建议

**建议 Monogram 采用 GPL-3.0。** 理由：

1. 项目方针是「默认复刻 Ethena V2」，复制/改写 GPL-3.0 代码后，衍生作品本来就必须 GPL-3.0——主动采用只是履行义务，不损失任何商用权利。
2. GPL-3.0 是已部署 DeFi 合约中最常见的 license 之一（Uniswap V2 等先例），审计方、集成方都熟悉。
3. 附带专利授权/报复条款，对协议有额外保护。

落地要求：

- 仓库根目录放 GPL-3.0 `LICENSE` 文件；每个源文件头部加 `// SPDX-License-Identifier: GPL-3.0`。
- 对源自 Ethena 的文件：保留 Ethena 版权归属说明（如 `Portions Copyright (c) Ethena Labs, GPL-3.0`），并在文件头或 NOTICE 中注明「修改自 Ethena 的 X.sol」及修改要点。
- 记录每个文件的来源（原创 / 衍生自哪个 Ethena 文件 / OZ 依赖），建议维护一个 `NOTICE` 或 provenance 清单，方便后续审计与合规核查。
- 若未来决定改成 MIT 等宽松 license，前提是相关文件已完成 clean-room 重写、不含 Ethena 代码表达。

---

## 附：主要来源

- [ethena-labs GitHub 组织仓库列表](https://github.com/orgs/ethena-labs/repositories) 及 [GitHub API](https://api.github.com/orgs/ethena-labs/repos)
- [ethena-labs/bbp-public-assets](https://github.com/ethena-labs/bbp-public-assets)（存档，合约源码，SPDX GPL-3.0）
- [ethena-labs/code4arena-contest](https://github.com/ethena-labs/code4arena-contest)（存档，仓库级 GPL-3.0 LICENSE）
- [ethena-labs/ethena-usdtb-contest](https://github.com/ethena-labs/ethena-usdtb-contest)（存档，SPDX GPL-3.0）
- [Ethena Docs — Key Addresses](https://docs.ethena.fi/technical-design/key-addresses)
- [Etherscan — EthenaMinting V2](https://etherscan.io/address/0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3#code)
- [Etherscan — EthenaMinting V1](https://etherscan.io/address/0x2cc440b721d2cafd6d64908d6d8c4acc57f8afc3#code)
- [Etherscan — USDe](https://etherscan.io/address/0x4c9EDD5852cd905f086C759E8383e09bff1E68B3#code)
- [Etherscan — StakedUSDeV2 (sUSDe)](https://etherscan.io/address/0x9D39A5DE30e57443BfF2A8307A4256c8797A3497#code)
- [Etherscan — USDeSilo](https://etherscan.io/address/0x7fc7c91d556b400afa565013e3f32055a0713425#code)
- [Etherscan — StakingRewardsDistributor](https://etherscan.io/address/0xf2fa332bd83149c66b09b45670bce64746c6b439#code)
- 主网 `eth_call` 实测（RPC：ethereum-rpc.publicnode.com，2026-08-25）：sUSDe.`silo()` = `0x7fc7c91d556b400afa565013e3f32055a0713425`；sUSDe.`cooldownDuration()` = 86400
