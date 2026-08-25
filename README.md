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
| `MonogramMinting.sol` | 铸造/赎回引擎，EIP-712 签名验证，per-block 限额，价格验证 | EthenaMinting |
| `StakedM.sol` | ERC-4626 Vault，奖励自动复利，8h vesting | sUSDe |

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
# 安装依赖
forge install

# 编译
forge build

# 测试
forge test

# 部署（测试网）
forge script script/Deploy.s.sol --rpc-url sepolia
```

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
