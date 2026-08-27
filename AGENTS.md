# Monogram — Agent Guide

## Project

合成美元协议，参考 Ethena USDe。核心是 delta-neutral 稳定币 M，通过做空永续合约对冲现货抵押品的价格风险。

## Tech Stack

- **语言**: Solidity ^0.8.36
- **框架**: Foundry (forge, cast, anvil)
- **依赖**: OpenZeppelin Contracts v5.x
- **链**: Ethereum L1（主网 + Sepolia/Holesky 测试网）

## Commands

```bash
forge build          # 编译
forge test           # 运行测试
forge test -vvv      # 详细日志
forge coverage       # 测试覆盖率
forge snapshot       # Gas 快照
forge fmt            # 格式化
slither .            # 静态分析

# 部署
forge script script/DeployM.s.sol --rpc-url sepolia --broadcast
```

## Architecture

### 合约

| 合约 | 目录 | 说明 |
|------|------|------|
| `M.sol` | `src/` | ERC20 + Permit + Burnable，单 minter |
| `MonogramMinting.sol` | `src/` | 铸造/赎回引擎，EIP-712，per-block 限额，价格验证 |
| `StakedM.sol` | `src/` | ERC-4626 Vault，8h vesting 奖励 |
| `SingleAdminAccessControl.sol` | `src/` | MonogramMinting 的单 admin 权限基座（复刻 Ethena，见 ADR-0004） |
| `WETH9.sol` | `src/` | 供本地测试用 |

### 角色

- `DEFAULT_ADMIN_ROLE` — 多签 7/10，7 天时间锁
- `MINTER_ROLE` — 铸造 + transferToCustody
- `REDEEMER_ROLE` — 赎回
- `GATEKEEPER_ROLE` — 关停 mint/redeem + 移除角色

### ADR

设计决策记录在 `adr/` 目录：

```
adr/ADR-0000.md  索引
adr/ADR-0001.md  整体架构（链上 3 合约 + 链下 3 组件）
adr/ADR-0002.md  M 代币设计
adr/ADR-0003.md  铸造/赎回引擎
adr/ADR-0004.md  角色权限
adr/ADR-0005.md  EIP-712 签名验证
adr/ADR-0006.md  资产托管与 OES
adr/ADR-0007.md  质押与收益分发
adr/ADR-0008.md  预言机与价格验证
adr/ADR-0009.md  风控与安全
adr/ADR-0010.md  链下对冲系统
adr/ADR-0011.md  储备金
adr/ADR-0012.md  治理与信任模型
```

## Conventions

### 代码风格

- Solidity `^0.8.36`
- 使用 OpenZeppelin v5（AccessControl, ReentrancyGuard, SafeERC20, ERC4626）
- 无 Proxy 模式（合约不可升级），V2 通过新部署迁移
- 使用 forge fmt 格式化
- 每个合约在 `src/interfaces/` 中有对应接口
- 错误使用自定义 `error`（非 `require` 字符串）
- 事件在合约顶部定义

### 命名规范

- 合约: PascalCase（`MonogramMinting`）
- 函数: camelCase（`verifyOrder`）
- 常量: UPPER_SNAKE_CASE
- 私有/内部: `_` 前缀（`_transferCollateral`）
- 接口: `I` 前缀（`IMonogramMinting`）

### 测试

- 使用 Foundry 测试框架
- 测试文件放在 `test/`，文件名 `*.t.sol`
- 使用 `forge test -vvv` 调试
- 关键场景：正常 mint/redeem、签名错误、价格偏差超限、per-block 限额、重放攻击、角色权限

## Key Reference

- [Ethena 官方文档](https://docs.ethena.fi/)
- [EthenaMinting V2 合约](https://etherscan.io/address/0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3)
- [Ethena Github](https://github.com/ethena-labs)

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (`0xnicholas/monogram`), managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` at the repo root + ADRs in `adr/`. See `docs/agents/domain.md`.
