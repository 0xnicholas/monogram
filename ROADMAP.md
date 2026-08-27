# Monogram 协议开发路线图

## 阶段概览

```
Phase 0     Phase 1         Phase 2          Phase 3            Phase 4
  概念验证 → 核心合约部署 → 质押与收益     → 链下对冲系统     → 治理与规模化
              │               │                │                  │
            M + Minting    StakedM         Hedging Engine     MONO 代币
            Testnet        Rewards         Pricing API        Risk Committee
                           Distributor     OES 集成          多链扩展
```

---

## Phase 0: 概念验证（当前阶段 — 已完成）

### 目标
确认架构设计，完成技术分析。

### 交付物
| 产出 | 说明 |
|------|------|
| `MONOGRAM_VS_ETHENA.md` | Ethena 对比分析 |
| `adr/ADR-0000~0012` | 完整架构决策记录 |

### 状态
✅ 已完成

---

## Phase 1: 核心合约部署（1-2 个月）

### 目标
实现合成美元 M 的铸造与赎回核心逻辑，部署到以太坊测试网。

### 合约清单

| 合约 | 功能 |
|------|------|
| `M.sol` | ERC20 + Permit + Burnable，单 minter |
| `MonogramMinting.sol` | 铸造/赎回引擎，EIP-712 签名验证，per-block 限额，价格验证 |
| `MonogramPriceFeed.sol` | Pyth + Chainlink 双预言机价格汇聚 |

### 关键里程碑

#### M1.1 — 核心合约实现（第 1-2 周）
- [x] ADR 设计完成
- [ ] `M.sol` 实现与测试
- [ ] `MonogramMinting.sol` 实现（含 EIP-712 签名、Nonce Bitmap、per-block 限额）
- [ ] 角色管理（AccessControl）

#### M1.2 — 预言机集成（第 3 周）
- [ ] 集成 Pyth 合约（`IPyth` / `PythUpgradable`）
- [ ] 集成 Chainlink 合约（`AggregatorV3Interface`）
- [ ] `MonogramPriceFeed` 实现
- [ ] 价格偏差验证逻辑

#### M1.3 — 测试网部署（第 4 周）
- [ ] Foundry 测试套件（单元 + 集成 + fork 测试）
- [ ] 部署到 Sepolia / Holesky 测试网
- [ ] 链下签名服务原型（`cast` + `forge` 脚本验证）
- [ ] 安全审计（合约层面）

### 验证标准
```
✅ 可在测试网上铸造 M 和赎回 M
✅ EIP-712 签名验证正确阻止伪造订单
✅ Per-block 限额正确生效
✅ 预言机偏差 > ±5% 时拒绝交易
✅ Nonce Bitmap 正确防重放
✅ GATEKEEPER 可以关停 mint/redeem
```

### 不包含的范围
- ❌ StakedM（Phase 2）
- ❌ 链下对冲系统（Phase 3）
- ❌ 原生 ETH 处理（仅 ERC20）
- ❌ Route 比例路由（直接转到单 custodian）

---

## Phase 2: 质押与收益分发（2-3 个月）

### 目标
实现 sM 质押代币和收益分发机制，启动测试网生态激励。

### 合约清单

| 合约 | 功能 |
|------|------|
| `StakedM.sol` | ERC-4626 Vault，奖励自动复利 |
| `StakingRewardsDistributor.sol` | 自动化奖励分发 |

### 关键里程碑

#### M2.1 — StakedM 实现（第 5-6 周）
- [ ] ERC-4626 标准实现（`deposit` / `mint` / `withdraw` / `redeem`）
- [ ] 8 小时 linear vesting 奖励机制
- [ ] `transferInRewards()` — 仅 REWARDER 可调用
- [ ] 解质押冷却期（可配置，最长 90 天）
- [ ] 合规：SOFT_RESTRICTED / FULL_RESTRICTED 地址

#### M2.2 — 奖励分发（第 7 周）
- [ ] `StakingRewardsDistributor` 实现
- [ ] 每周多次自动分发（防 lumpy arbitrage）
- [ ] sM:M 汇率单调递增验证

#### M2.3 — 集成测试（第 8 周）
- [ ] 端到端测试：Mint → Stake → 奖励累积 → Unstake
- [ ] 模拟奖励分发场景
- [ ] 安全审计

### 验证标准
```
✅ 质押 M 获得 sM，sM:M 汇率单调递增
✅ 8 小时 vesting 防止闪电贷套利
✅ REWARDER 注入奖励后汇率正确上升
✅ 冷却期解质押流程正确
✅ 受限地址无法质押或解质押
```

### 不包含的范围
- ❌ 链下对冲系统（Phase 3）
- ❌ Reserve Fund（Phase 3 链下）
- ❌ 主网部署（Phase 3）

---

## Phase 3: 链下基础设施与主网上线（4-6 个月）

### 目标
构建链下对冲系统、集成 OES 托管商、部署主网。

### 组件

| 组件 | 功能 |
|------|------|
| Pricing API | RFQ 报价引擎，多 CEX 聚合定价 |
| Hedging Engine | 投资组合管理，delta-neutral 对冲，CEX 连接 |
| OES Integration | 托管商集成（逐家谈判接入） |
| Reserve Fund | 链下资金池负收益吸收 |
| 透明仪表盘 | 实时抵押率、储备金余额、custodian 分布 |

### 关键里程碑

#### M3.1 — 链下基础设施（第 9-12 周）
- [ ] Pricing API 设计与实现
  - CEX 订单簿数据消费（Binance/Bybit/OKX WebSocket API）
  - Pyth + Redstone 价格交叉验证
  - 滑点计算与 RFQ 报价
- [ ] Hedging Engine 原型
  - 投资组合追踪器
  - 热钱包 M 余额监控
  - 手动对冲操作接口

#### M3.2 — OES 托管集成（第 13-16 周）
- [ ] 与 Copper Clearloop 集成
- [ ] 与 Ceffu Mirror 集成
- [ ] OES 委托/取消委托流程
- [ ] PnL 结算自动化
- [ ] 法律/合规审查（托管协议、监管意见）

#### M3.3 — Reserve Fund（第 16 周）
- [ ] Foundation 法律实体设立
- [ ] 储备金地址建立
- [ ] 收益分配流程（正收益 → 储备金 + sM 奖励）
- [ ] 负收益吸收流程（储备金 → 协议）

#### M3.4 — 主网部署（第 17-20 周）
- [ ] 合约部署到 Ethereum 主网
- [ ] mint/redeem 白名单启用（KYB 做市商）：部署后 `setWhitelistEnabled(true)`（单向棘轮，不可逆），再 `transferAdmin` 移交多签；M 代币转账不设限，散户走二级市场（#11 决议）
- [ ] 有限上线：仅 whitelisted 做市商可 mint/redeem
- [ ] 外部安全公司全面审计
- [ ] 透明仪表盘上线

#### M3.5 — 公开上线（第 21-24 周）
- [ ] 开放 sM 质押（限允许辖区内用户）
- [ ] CEX 上市（Binance/Bybit/OKX）
- [ ] DEX 流动性部署（Curve/Uniswap M-USDe 池）
- [ ] DeFi 集成（Aave/Morpho/Pendle）

### 验证标准
```
✅ Pricing API 可稳定报价（延迟 < 100ms）
✅ Hedging Engine 铸造后自动开空，delta ≈ 0
✅ OES 委托/取消委托流程正确
✅ 主网 mint/redeem 通过审计
✅ 透明仪表盘实时更新
✅ M 在至少 1 个 CEX 和 1 个 DEX 上可交易
```

### 不包含的范围
- ❌ MONO 治理代币（Phase 4）
- ❌ Risk Committee（Phase 4）
- ❌ 多链扩展（Phase 4）

---

## Phase 4: 治理与规模化（6-12 个月）

### 目标
引入 MONO 治理代币，逐步将协议控制权转移至社区，扩展至多链。

### 组件

| 组件 | 功能 |
|------|------|
| MONO Token | 治理代币 |
| Staked MONO | MONO 质押参与治理 |
| Risk Committee | 风险管理委员会 |
| 多链扩展 | 跨链 M 部署 |

### 关键里程碑

#### M4.1 — MONO 治理代币（第 25-28 周）
- [ ] MONO 代币设计与部署
- [ ] 代币分配（团队、投资者、社区、生态）
- [ ] 治理合约（Timelock + GovernorBravo）
- [ ] 参数控制权转移至治理

#### M4.2 — Risk Committee（第 29-32 周）
- [ ] Risk Committee 章程
- [ ] 成员选举或任命（3-5 名）
- [ ] 资产配置限制 → 委员会决策
- [ ] 每季度风险报告

#### M4.3 — 多链扩展（第 33-48 周）
- [ ] 跨链 M（LayerZero / CCIP）
- [ ] sM 多链部署（Arbitrum / Optimism / Base）
- [ ] 各链流动性引导

### 验证标准
```
✅ MONO 持有者可参与治理投票
✅ Risk Committee 独立运作
✅ M 在 3+ 条链上可用
✅ 协议 TVL > $100M
```

---

## 时间线总览

```
Month:  1   2   3   4   5   6   7   8   9   10  11  12  13  14  15  16
        │   │   │   │   │   │   │   │   │   │   │   │   │   │   │   │
Phase1  ████████████
        M   M   T
            1.1 1.2 1.3

Phase2              ████████████
                    M2.1    M2.2    M2.3

Phase3                      ████████████████████████████
                            M3.1    M3.2    M3.3    M3.4    M3.5

Phase4                                              ████████████████
                                                    M4.1    M4.2    M4.3
```

### 依赖关系

```
Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4
  │                      │
  └── 审计通过方可上线     └── OES 法律审查是关键路径
                          └── CEX 上币需 KYC/KYB 流程
```

### 关键风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| 合约审计发现严重问题 | Phase 1 延迟 | 提前进行多轮内部测试 + 形式化验证 |
| OES 法律审查延迟 | Phase 3 延迟 | 提前启动，与多家托管商并行谈判 |
| CEX 上币流程长 | Phase 3.5 延迟 | 提前建立关系，准备合规文档 |
| 负资金费率持续 | Phase 3 收益降低 | Reserve Fund 缓冲 + 多源收益分散 |
| 监管变化 | Phase 2 质押功能受限 | 合规团队监控，SOFT_RESTRICTED 地址方案 |
