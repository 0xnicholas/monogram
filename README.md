# Monogram

Monogram 是一个合成美元协议，完全参考 [Ethena](https://ethena.fi/) USDe 的设计。通过 delta-neutral 对冲策略，以加密资产为底层抵押，发行合成美元 **M**。

## 架构

```
链上合约                    链下服务
┌────────────────┐         ┌──────────────────┐
│  M.sol         │         │  Pricing API     │
│  (ERC20)       │◄─────── │  (RFQ 报价)      │
│  minter → Minting        └──────────────────┘
└────────┬───────┘
         │ mint/burn         ┌──────────────────┐
┌────────▼───────┐         │  Hedging Engine  │
│ MonogramMinting│◄────────┤  (delta-neutral)  │
│ (铸造/赎回引擎) │         └──────────────────┘
│                │
│ - EIP-712 签名  │         ┌──────────────────┐
│ - 双预言机价格  │         │  OES Custodians  │
│ - per-block 限额│◄────────┤  OES Custodians  │
│ - 角色权限      │         │  (多托管商)       │
└────────┬───────┘         └──────────────────┘
         │ rewards
┌────────▼───────┐
│  StakedM.sol   │
│  (ERC-4626)    │
│  sM 收益凭证    │
└────────────────┘
```

## 核心合约

| 合约 | 功能 | 对标 |
|------|------|------|
| `M.sol` | 合成美元 ERC20，单 minter，不可升级 | USDe |
| `MonogramMinting.sol` | 铸造/赎回引擎，EIP-712 签名验证，per-block 限额，价格验证 | EthenaMinting V2 |
| `MonogramPriceFeed.sol` | Pyth + Chainlink 双预言机价格汇聚 | —（自研，见 ADR-0008） |
| `StakedM.sol` | ERC-4626 Vault，8h vesting，冷却期互斥 + Silo 隔离 | sUSDeV2 |
| `UnstakingSilo.sol` | 解质押冷却资产隔离库 | USDeSilo |
| `StakingRewardsDistributor.sol` | 奖励分发（简化版，闭环 mint 押后 Phase 3） | StakingRewardsDistributor |
| `SingleAdminAccessControl.sol` | 单 admin 权限基座（两步移交） | SingleAdminAccessControl |
| `WETH9.sol` | 本地测试用 WETH | WETH9 |

## 角色体系

| 角色 | 权限 | 负责人 |
|------|------|--------|
| `DEFAULT_ADMIN_ROLE` | 全权限（角色/资产/参数管理） | 7/10 多签 + 7 天时间锁 |
| `MINTER_ROLE` | 铸造 M + transferToCustody | 协议运营方 |
| `REDEEMER_ROLE` | 赎回 M | 协议运营方 |
| `GATEKEEPER_ROLE` | 关停 mint/redeem + 移除角色 | 内部 3+ + 外部 3+ |

## 运行原理

```
MINT:
  用户 RFQ → 报价 → EIP-712 签名 → 验证签名+价格+限额
  → 资产转至 Custodian → M.mint() → CEX 开空对冲

REDEEM:
  用户 RFQ → 报价 → EIP-712 签名 → 验证签名+价格+限额
  → M.burnFrom() → 资产返回用户 → CEX 平空
```

## 开发

```bash
# 安装依赖（OZ 走 npm，forge-std 走 submodule）
npm install
git submodule update --init --recursive

# 编译
forge build

# 测试（fork 用例会走真实 RPC，可用 MAINNET_RPC_URL 覆盖）
forge test
forge test --no-match-path 'test/MonogramFork.t.sol'   # 纯本地，CI 友好

# 覆盖率（via_ir = true 下必须加 --ir-minimum）
forge coverage --ir-minimum --report summary
```

### 本地彩排（不写链上记录）

```bash
anvil --chain-id 31337            # 不要用 11155111 冒充 Sepolia：广播日志会看起来像真部署
cp .env.example .env              # 见 .env.example 的变量说明（CSV 列表不要带空格）
forge script script/DeployM.s.sol --rpc-url http://localhost:8545 --broadcast
forge script script/E2EMint.s.sol --rpc-url http://localhost:8545 --broadcast   # EIP-712 链下签名 + mint 冒烟
```

### 部署（测试网 / 主网）

```bash
forge script script/DeployM.s.sol --rpc-url sepolia --broadcast --verify
```

真实部署地址手工记录到 `deployments/<chainId>.json`（格式与三条硬性校验见 [deployments/README.md](./deployments/README.md)）；
`broadcast/` 是本地回放日志，已从版本控制忽略，不作为地址来源。

部署后**必跑**校验脚本（用同一份 `.env` 回头核对链上现实）：

```bash
forge script script/PostDeployCheck.s.sol --rpc-url sepolia
```

完整流程（环境准备 → 彩排 → 部署 → 校验 → admin 移交 → 冒烟 → 记录 / 失败处置）见
[docs/deploy-runbook.md](./docs/deploy-runbook.md)。

## 路线图

| 阶段 | 周期 | 内容 |
|------|------|------|
| Phase 1 | 1-2 月 | 核心合约实现 → 测试网 |
| Phase 2 | 2-3 月 | StakedM + 收益分发 |
| Phase 3 | 4-6 月 | 链下对冲 + OES + 主网 |
| Phase 4 | 6-12 月 | MONO 治理 + 多链扩展 |

详见 [ROADMAP.md](./ROADMAP.md)。

## 文档

| 文件 | 内容 |
|------|------|
| [MONOGRAM_VS_ETHENA.md](./MONOGRAM_VS_ETHENA.md) | Ethena 对比分析 |
| [adr/](./adr/) | 架构决策记录（ADR-0000 ~ 0012） |
| [ROADMAP.md](./ROADMAP.md) | 开发路线图 |
