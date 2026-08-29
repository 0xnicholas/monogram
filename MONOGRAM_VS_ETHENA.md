# Monogram vs Ethena — 技术分析

> [!WARNING]
> **本文档已过时（写于 stub 阶段，2026-08）**。当前差距与复刻决策以以下为准：
> - 刷新差距报告：[issue #2](https://github.com/0xnicholas/monogram/issues/2)
> - 各模块决策：map [issue #1](https://github.com/0xnicholas/monogram/issues/1) 的 Decisions so far
> - 落地后架构：`adr/`（ADR-0001 ~ 0012）
>
> 保留本文仅作历史参考（初始对比视角）。

## 概述

Monogram 是一个对标 [Ethena](https://ethena.fi/) 的合成美元协议，代码库基于 Foundry（Solidity 0.8.28），当前处于**早期 stub 阶段**。本文从智能合约架构、代币经济、托管模型、风控机制四个维度进行对比分析。

---

## 1. 核心稳定币

| 维度 | Ethena | Monogram |
|------|--------|----------|
| 稳定币 | USDe (ERC20 + Permit + Burnable) | M (ERC20 + Permit + Burnable + Ownable2Step) |
| 合约 | `USDe.sol` | `M.sol` |
| 发行权限 | 单个 `minter` 地址（指向 `EthenaMinting`） | 单个 `minter` 地址 |
| 禁止 renounce | ✅ 铸造后不可放弃所有权 | ✅ `renounceOwnership()` revert |
| 部署者权限 | 可调用 `transferOwnership` + `setMinter` | 相同模式 |

**结论**: `M.sol` 与 `USDe.sol` 设计几乎一致，都是标准 ERC20 + Permit + 单 minter 模式。Monogram 的 `M` 额外继承了 `Ownable2Step`。

---

## 2. 铸造/赎回引擎

这是两个协议最核心的合约。对比 `MonogramMinting.sol` vs `EthenaMinting.sol`。

### 2.1 实现状态

| 功能 | EthenaMinting V2 | MonogramMinting |
|------|-----------------|-----------------|
| EIP-712 签名验证 | ✅ 完整实现 | ❌ `hashOrder()` / `verifyOrder()` 空实现 |
| Nonce Bitmap 防重放 | ✅ | ⚠️ `_deduplicateOrder` 骨架写了，但 `verifyNonce` 空实现 |
| Route 路由验证 | ❌ 无此概念 | ⚠️ `verifyRoute()` 空实现 |
| 每区块限额 | ✅ | ✅ `mintedPerBlock` / `redeemedPerBlock` mapping 存在，逻辑完整 |
| 价格预言机验证 | ✅ Pyth + Redstone (±5%) | ❌ 不存在（README 里提到但从没实现） |
| EIP-1271 支持 | ✅ | ❌ |
| 委托签名人 | ❌ 无此概念 | ⚠️ `delegatedSigner` 状态机（PENDING→ACCEPTED），逻辑完整 |

### 2.2 角色体系对比

| 角色 | Ethena | Monogram |
|------|--------|----------|
| MINTER | 铸造调用 | ✅ 定义 | ✅ 定义（空字符串常量） |
| REDEEMER | 赎回调用 | ✅ | ✅ |
| COLLATERAL_MANAGER | 转移托管资金 | ❌ 直接由多签控制 | ✅ 单独角色 |
| GATEKEEPER | 紧急冻结/撤销权限 | ✅ | ✅ |
| DEFAULT_ADMIN | 管理所有角色 | ✅ | ✅ |

**发现**: Monogram 的角色常量定义为 `""`（空字符串），这是一个**明显的 bug 或 stub**。OpenZeppelin 的 `AccessControl` 使用 `keccak256` 哈希作为角色标识，空字符串会导致权限检查永远失败或错乱。

### 2.3 关键差异

**Ethena 特有:**
- 价格预言机验证（Pyth + Redstone，最大 5% 偏差）
- 资产分组限额（stablecoin vs LST 各有独立限额）
- Mandate Delta Limit（防止稳定币脱钩套利）
- GATEKEEPER 监控错误定价并即时关停

**Monogram 特有:**
- `Route` 结构：将抵押资产按比例分配到多个托管地址
- `DelegatedSigner`：允许用户委托他人签名（两层授权模型）
- `transferToCustody()`：独立的金库转出操作（COLLATERAL_MANAGER_ROLE）

---

## 3. 托管模型

### Ethena: Off-Exchange Settlement (OES)

```
用户抵押资产 → EthenaMinting → OES 托管商 (Copper/Ceffu/Kraken)
                                     ↓
                            按需委托名义价值到 CEX 作为保证金
                                     ↓
                            短仓永续合约对冲 delta 风险
```

- 资产物理上在托管商处，从不进入交易所
- 交易所只能看到"名义金额"，不能动用底层资产
- 破产隔离：交易所倒闭不影响本金，最多损失未结 PnL
- 多托管商冗余（Copper、Ceffu、Kraken、Anchorage）

### Monogram: 直接托管转移

```
用户抵押资产 → MonogramMinting → Route 分配 → 多个托管钱包地址
                                                    ↓
                                            COLLATERAL_MANAGER 可调取资金
```

- 完全链上托管，没有 OES 概念
- `Route` 结构将资产按比例拆分到多个地址
- `transferToCustody()` 将资金从合约转到外部托管钱包
- 没有对冲逻辑（没有做空永续合约）

### 差异总结

| 维度 | Ethena | Monogram |
|------|--------|----------|
| 对冲 | ✅ 完整 delta-neutral 对冲系统（链下） | ❌ 无 |
| 托管 | OES（交易所破产隔离） | 直接转账到地址 |
| 收益来源 | 资金费率 + 基差 + DeFi 借贷 + RWA | ❌ 未定义 |
| 分散托管 | 多 OES 提供商 | Route 多地址分配 |
| 透明度 | 实时仪表盘 + 每周 PoR | ❌ |

Monogram 的 `Route` 机制实际上与 Ethena 的多托管商策略**思路相似但实现层级不同**——Monogram 在单合约内做链上路由，Ethena 在链下 OES 层面做托管商分配。

---

## 4. 质押与收益

### Ethena: sUSDe

| 组件 | 状态 |
|------|------|
| `StakedUSDeV2.sol` | ERC-4626 Vault，完整实现 |
| `StakingRewardsDistributor.sol` | 自动化周级奖励分发 |
| `USDeSilo.sol` | 解质押冷却期合约 |
| 奖励来源 | 资金费率、基差、DeFi 借贷、RWA 等 |
| 负收益 | Reserve Fund 吸收，用户永不承担 |
| 冷却期 | 可配置（最长 90 天） |

### Monogram: stM

- **`StakedM.sol`**：3 行空壳，无任何逻辑
- **`IStakedM.sol`**：空接口
- 没有 `RewardsDistributor`、没有 `Reserve Fund`、没有冷却期机制

**结论**: Monogram 的质押层**完全未实现**。

---

## 5. 预言机与喂价

### Ethena
- 链上：Pyth + Redstone 双预言机验证
- 链下：多 CEX 订单簿聚合计算报价
- 允许最大 5% 偏差
- 分资产类型验证（ERC20、LST、稳定币各有不同逻辑）

### Monogram
- README 中列出 `MonogramPriceFeed.sol`、`ChainlinkOracleAdapter.sol`
- **源代码中这两个文件不存在**
- `verifyOrder()` 空实现，没有调用任何价格验证

**结论**: 预言机层完全未实现。

---

## 6. 注册表与可升级性

### Ethena
- 使用 Proxy 模式（可升级）
- 合约间耦合通过硬编码地址 + 角色控制

### Monogram
- README 列出 `ContractRegistry.sol`、`MonogramConfig.sol`
- **源代码中不存在**
- 当前代码不可升级（无 Proxy）

---

## 7. 签名与授权

| 维度 | Ethena | Monogram |
|------|--------|----------|
| 订单签名 | EIP-712 完整实现 | 空实现（`verifyOrder` 无内容） |
| Nonce 防重放 | Bitmap 实现 | ⚠️ 结构完整但 `verifyNonce` 空 |
| EIP-1271 | ✅ 支持合约钱包 | ❌ |
| 委托签名 | ❌ | ✅ `DelegatedSigner`（发起→确认→拒绝） |

Monogram 的 `DelegatedSigner` 机制是 Ethena 没有的功能，允许用户注册一个代理签名地址。这在链下经纪商场景中有意义，但也引入了额外的信任假设。

---

## 8. 风控机制对比

| 风控项 | Ethena | Monogram |
|--------|--------|----------|
| 每区块限额 | ✅ | ✅（但 maxMintPerBlock/maxRedeemPerBlock 写在常量而非存储中？实际是 storage） |
| Gatekeeper 一键冻结 | ✅ | ✅ `disableMintRedeem()` |
| 价格偏差校验 | ✅ ±5% | ❌ |
| Nonce 防重放 | ✅ | ⚠️ 空实现 |
| 防重入 | ✅ | ✅ `ReentrancyGuard` |
| 白名单 | ✅ beneficiar/benefactor 链上白名单 | ❌ |
| 冷却期 | ✅ 解质押冷却 | ❌ |
| Reserve Fund | ✅ 负收益吸收 | ❌ |
| 角色权限到期 | ❌ | ✅ `expiry` 字段在 Order 中（但未被验证） |

---

## 9. Monogram 代码问题清单

1. **角色常量为空字符串**（`MonogramMinting.sol:27-35`）
   ```solidity
   bytes32 private constant MINTER_ROLE = "";
   ```
   应该改为 `keccak256("MINTER_ROLE")`，否则 `onlyRole(MINTER_ROLE)` 角色检查永远不通过。

2. **多处函数的 `if` 条件重复/错误**（`MonogramMinting.sol:96`）
   ```solidity
   if (address(_m) == address(0)) revert InvalidMAddress();
   if (address(_m) == address(0)) revert InvalidZeroAddress();  // 重复条件
   ```

3. **五个核心函数空实现**：
   - `addSupportedAsset()` — 没有向 `_supportedAssets` 添加
   - `hashOrder()` — 没有计算 order hash
   - `verifyOrder()` — 没有签名验证逻辑
   - `verifyRoute()` — 没有路由验证逻辑
   - `verifyNonce()` — 没有 nonce 检查

4. **`addSupportedAsset` 和 `addCustodianAddress` 定义为 `public` 且没有内部调用**，构造函数中循环调用它们，但因为空实现所以不生效。

5. **`getDomainSeparator()` 和 `encodeOrder()` 空实现**

6. **未使用的 import**：`ECDSA.sol` 被引入但从未使用。

---

## 10. 总体差异矩阵

| 模块 | Ethena | Monogram | Monogram 完成度 |
|------|--------|----------|:------------:|
| 稳定币代币 | ✅ USDe | ✅ M | **100%** |
| 铸造/赎回引擎 | ✅ EthenaMinting V2 | ⚠️ MonogramMinting | **~30%**（骨架有，逻辑空） |
| 质押/收益 | ✅ sUSDe (ERC-4626) | ❌ StakedM.sol | **0%**（空壳） |
| 收益分发 | ✅ StakingRewardsDistributor | ❌ 不存在 | **0%** |
| 多托管路由 | ✅ OES 多提供商 | ⚠️ Route 机制 | **~50%**（结构有，验证空） |
| 对冲系统 | ✅ 链下全自动对冲 | ❌ 不存在 | **0%** |
| 预言机 | ✅ Pyth + Redstone | ❌ 不存在 | **0%** |
| 价格验证 | ✅ ±5% on-chain check | ❌ 不存在 | **0%** |
| 注册表 | ❌ 硬编码地址 | ❌ 不存在 | **0%** |
| 权限控制 | ✅ AccessControl | ✅ SingleAdminAccessControl | **90%**（小 bug） |
| 签名验证 | ✅ EIP-712 + EIP-1271 | ⚠️ 骨架 | **~20%** |
| Reserve Fund | ✅ | ❌ | **0%** |
| 白名单 | ✅ 链上 | ❌ | **0%** |
| 冷启动期/冷却期 | ✅ | ❌ | **0%** |
| 透明度 | ✅ 仪表盘 + PoR | ❌ | **0%** |

**整体加权完成度：约 15-20%**

---

## 11. 架构总结

### Ethena 的核心创新
1. **Delta-neutral 合成美元**：用做空永续合约对冲现货持仓，从资金费率盈利
2. **Off-Exchange Settlement**：资产托管在第三方，只委托名义价值给交易所，实现破产隔离
3. **多收入源**：资金费率 + 基差 + DeFi 借贷 + RWA，形成多样化收益
4. **Reserve Fund**：负收益周期用储备金吸收，确保 sUSDe 永不贬值

### Monogram 的设计选择
1. **纯链上托管路由**：用 `Route` 结构在合约层做多地址资产拆分，不依赖 OES
2. **委托签名人机制**：允许用户授权代理签名，适合经纪商模式
3. **无对冲设计**：README 和代码中均未提及永续合约或 delta-neutral 策略

### Monogram 如果要追赶 Ethena，需要补充

```
优先级 P0（协议生存必须）
├── 实现 hashOrder / verifyOrder / verifyNonce 签名验证
├── 修复角色常量 bug
├── 实现价格预言机（Pyth / Chainlink）
└── 实现多资产路由验证

优先级 P1（经济模型必须）
├── 定义收益来源（资金费率 / 基差 / DeFi 收益）
├── 实现 StakedM + RewardsDistributor
└── 实现 Reserve Fund

优先级 P2（托管与风控）
├── 设计 OES 或等效破产隔离方案
├── 链下对冲系统
├── 白名单机制
└── 实时透明度报告

优先级 P3（可升级性与治理）
├── UUPS 或透明代理
├── ContractRegistry / MonogramConfig
├── 时间锁
└── ENA 式治理代币
```
