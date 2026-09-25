# 部署记录

真实链上的部署地址记录在本目录，一个链一个文件：`deployments/<chainId>.json`（手工维护，入库）。

`broadcast/` 目录被 `.gitignore` 忽略：那是 forge script 的本地回放日志，只证明"某次在某个 RPC 上跑过"，
不是权威地址来源。

## 文件格式

```json
{
  "chainId": 11155111,
  "network": "sepolia",
  "deployedAt": "2026-09-25T00:00:00Z",
  "deployer": "0x...",
  "commit": "5a2237a",
  "contracts": {
    "M": { "address": "0x...", "txHash": "0x...", "block": 12345678 },
    "MonogramPriceFeed": { "address": "0x...", "txHash": "0x...", "block": 12345678 },
    "MonogramMinting": { "address": "0x...", "txHash": "0x...", "block": 12345678 },
    "StakedM": { "address": "0x...", "txHash": "0x...", "block": 12345678 },
    "StakingRewardsDistributor": { "address": "0x...", "txHash": "0x...", "block": 12345678 }
  },
  "config": {
    "assets": ["0x..."],
    "custodians": ["0x..."],
    "operators": ["0x..."],
    "gatekeepers": ["0x..."],
    "whitelistEnabled": false,
    "admin": "0x..."
  },
  "verification": {
    "checkedAt": "2026-09-25T00:00:00Z",
    "script": "script/PostDeployCheck.s.sol",
    "result": "pass"
  }
}
```

## 收录前的三条硬性校验

写入任何地址前，逐条实操并留痕（这是本地 anvil 彩排事件暴露出来的教训）：

1. `cast code --rpc-url <rpc> <address>` 必须非 `0x`；
2. `cast nonce --rpc-url <rpc> <deployer>` 必须非 0（证明该账户确实在这条链上发过交易）；
3. `cast receipt --rpc-url <rpc> <txHash>` 必须能查到，且 `blockNumber` 与记录一致。

## 待办

- 目前**尚无真实链部署记录**。2026-08-29 的那次部署彩排是在本地 anvil 上以
  `--chain-id 11155111` 跑的，链上不存在对应交易（部署者账户在真 Sepolia 上 nonce = 0），
  其 `broadcast/` 产物已删除，不作为记录保留。
- 首次真实部署后按上述格式补 `deployments/sepolia.json`。本地彩排请使用 `--chain-id 31337`。

## 收录步骤

见 [docs/deploy-runbook.md](../docs/deploy-runbook.md)：部署 → 跑 `script/PostDeployCheck.s.sol`
（把 `verification.result` 一并记入）→ 过三条硬性校验 → 落库 → 冒烟 mint/redeem。
