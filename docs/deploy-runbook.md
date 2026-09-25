# 部署运行手册

适用：`script/DeployM.s.sol`（M / MonogramPriceFeed / MonogramMinting / StakedM / StakingRewardsDistributor）
以及配套的部署后校验 `script/PostDeployCheck.s.sol`。

设计原则：**部署脚本负责"部署成什么"，校验脚本负责"自证部署对了"**。两者共用同一份 `.env`，
所以校验脚本会用部署时的预期值回头核对链上现实——任何一项不符都会 revert 并打印原因。

## 0. 前置条件

| 需要 | 说明 |
|---|---|
| 部署者私钥 | `PRIVATE_KEY`。测试网可用现有 EOA；主网必须走独立部署密钥 |
| 测试网/主网 ETH | 部署 5 个合约 + 后续授权与移交，`StakedM` 还要额外部署 `UnstakingSilo`，gas 留足 3 倍余量 |
| Pyth 合约地址 | 用 **Pyth 升级版合约**（见 ADR-0008「Pyth Core 升级」），不是老的 `Pyth` |
| 每个资产的 Chainlink feed | 地址必须与 `ASSETS` 逐位对齐 |
| custodian 地址 | Route 的目标地址（#8 决议的托管模型）；本地彩排可随便填 |
| Etherscan API key | 仅 `--verify` 需要 |

**主网地址来源**：`test/MonogramFork.t.sol` 里的 `MAINNET_*` 常量（ETH/USD feed、WETH、Pyth）
是已被 fork 测试实际读通的地址，优先从那取；Sepolia 地址在 #22 落地时写入 `deployments/sepolia.json`。

### 每个地址都要先验一次再写进 `.env`

```bash
cast code --rpc-url $RPC <address>        # 必须是 0x 之外的内容
```

写错地址是这套流程最贵的错误：`0x` 的目录在部署后才被发现，就得整轮重来（校验脚本第一段就是查这个）。

## 1. 准备 .env

```bash
cp .env.example .env
```

- **CSV 列表不能带空格**：`ASSETS=0xA,0xB` 可以，`0xA, 0xB` 会 revert `invalid address length`；
- `CHAINLINK_FEEDS` 与 `PYTH_FEED_IDS` 必须与 `ASSETS` 逐位对齐；
- `ENABLE_WHITELIST`：**测试网保持 false**；主网部署后单独 ratchet（#11，不可逆）；
- `OPERATORS` / `GATEKEEPERS`：**生产必须显式指定**。不设置时脚本会把 MINTER/REDEEMER/GATEKEEPER
  全部授予部署者，校验脚本会因此报错（这正是它要抓的情况）；
- `STAKEDM_COOLDOWN_SECONDS`：不设置 = 保持合约默认 90 天；`0` = 关闭冷却期（恢复标准 ERC-4626 提款）。

## 2. 本地彩排（不写链上记录）

```bash
anvil --chain-id 31337        # 别用 11155111：广播日志会看起来像真的 Sepolia 部署
```

`.env` 里本地彩排需要的几项：

```
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil 账户 #0
DEPLOY_WETH=true
ASSETS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512                                 # 上面的 DEPLOY_WETH 会部署到该地址
CUSTODIANS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PYTH_ADDRESS=0xDd24F84d36BF92C65F92307595335bdFab5Bbd21                           # 仅写入字段，本地不读价
CHAINLINK_FEEDS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512                        # 同上，占位
CHECK_ORACLE_LIVENESS=false                                                       # 本地没有真预言机
```

```bash
forge script script/DeployM.s.sol --rpc-url http://localhost:8545 --broadcast
```

期望输出（关键行）：`M / WETH9 / MonogramPriceFeed / MonogramMinting / StakedM / StakingRewardsDistributor`
六个地址、`Revoked placeholder REWARDER from: <部署者>`、`Oracle configured for asset: ...`、
`Whitelist enabled: false`。

## 3. 部署到测试网

```bash
forge script script/DeployM.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify
```

`DeployM` 的执行顺序（排查问题时对照）：

1. `M` → 2. WETH（本地新建 / 真链用 `WETH_ADDRESS`）→ 3. `MonogramPriceFeed`（此时 `pyth` 已写入）
→ 4. `MonogramMinting`（assets + per-block 限额 + custodians + admin）→ 5. `M.setMinter(minting)`
→ 6. 可选开启白名单 → 7. 可选 `transferAdmin(MINTING_ADMIN)` → 8. `StakedM`
→ 9. `StakingRewardsDistributor` + 移交 `REWARDER_ROLE` + 撤销 admin 占位授权
→ 10. 授予 MINTER/REDEEMER/GATEKEEPER/OPERATOR → 11. per-asset 预言机配置。

> ⚠️ 第 10 步未配置 `OPERATORS`/`GATEKEEPERS` 时角色会留在部署者手上；第 7 步只移交
> `MonogramMinting` 的 admin，`M` / `PriceFeed` / `StakedM` / 分发器 **不会**自动移交（见 #26）。

## 4. 部署后校验（必跑）

```bash
forge script script/PostDeployCheck.s.sol --rpc-url $SEPOLIA_RPC
```

期望输出（逐段给出通过项数，本身就是证据链）：

```
=== Monogram 部署后校验 ===
  [地址存在] 5 项通过
  [接线] 8 项通过
  [代币元数据] 3 项通过
  [admin/owner] 12 项通过
  [角色] 10 项通过
  [参数] 6 项通过
  [资产与托管] 6 项通过
  [预言机] 9 项通过
=== 通过 59 项断言，0 项警告 ===
Post-deploy check PASSED
```

（本地彩排会少掉预言机存活 2 项并多 1 条 `CHECK_ORACLE_LIVENESS=false` 警告。）

**红线**：`WARN` 必须逐条解释清楚才算收尾；`CHECK_ORACLE_LIVENESS` / `EXPECT_FRESH_VAULT`
这两个开关只允许在本地彩排里关（真链上它们正是"预言机接线错了"和"指错部署地址"的检测器）。

它检查什么、为什么不检查什么，见 `script/lib/PostDeployChecker.sol` 顶部注释。三条最值得知道的限制：

- 无法枚举 OZ AccessControl 的角色成员，只能核对"期望名单全员在册 + 探针地址集合内不多不少"，
  所以**额外的**持有者要靠 `RoleGranted` 事件审计发现；
- `COLLATERAL_MANAGER_ROLE` / `BLACKLIST_MANAGER_ROLE` / 受限名单只报告不判失败（授予时机属运行期决策）；
- 只校验部署状态，不校验 mint/redeem 能否跑通 —— 那一步在 §6。

## 5. admin 移交（生产必做，手动）

`MonogramMinting` 与 `StakedM` 是两步移交，`M` 是 `Ownable2Step` 两步移交，
而 `PriceFeed` / 分发器是普通 OZ `AccessControl`（没有两步交接）。顺序与注意事项：

```solidity
// 1) 两步移交：先"请求"，多签随后 accept
minting.transferAdmin(MULTISIG);        // 多签调 acceptAdmin() 生效
stakedM.transferAdmin(MULTISIG);        // 多签调 acceptAdmin() 生效
m.transferOwnership(MULTISIG);          // 多签调 acceptOwnership() 生效

// 2) 无两步移交：直接授予多签，并撤销部署者 —— 撤销 DEFAULT_ADMIN_ROLE 必须放在最后，
//    因为 revokeRole 自身也受 onlyRole(getRoleAdmin) 约束
feed.grantRole(DEFAULT_ADMIN_ROLE, MULTISIG);
feed.grantRole(ORACLE_ADMIN_ROLE, MULTISIG);
feed.revokeRole(ORACLE_ADMIN_ROLE, DEPLOYER);
feed.revokeRole(DEFAULT_ADMIN_ROLE, DEPLOYER);   // 最后
distributor.grantRole(DEFAULT_ADMIN_ROLE, MULTISIG);
distributor.revokeRole(DEFAULT_ADMIN_ROLE, DEPLOYER);
```

从此刻起 `PostDeployCheck` 用 `EXPECT_ADMIN_HANDOVER=pending|done` 复核：

- `pending` = 已请求、待多签接受：`owner()` 仍是部署者、`pendingAdmin()`/`pendingOwner()` 是多签；
- `done` = 多签已接手：`owner()` 是多签、无 pending；
- `none`（默认）= 交接还没开始，全部 admin/owner 仍是部署者（仅测试网）。

移交完成后多签侧的动作：`minting.acceptAdmin()`、`stakedM.acceptAdmin()`、`m.acceptOwnership()`。

> `pendingAdmin()` 是本仓库为这一步新增的只读 getter（见 ADR-0004）：没有它就无法在链上确证
> "已请求、待接受"这一中间态，而漏掉 `transferAdmin` 要等 7 天后多签调用失败才会暴露。

## 6. 冒烟 mint / redeem

```bash
forge script script/E2EMint.s.sol --rpc-url $SEPOLIA_RPC --broadcast
```

benefactor 签单（`vm.sign`，不广播）+ operator 广播 `mint`，断言 M 到账、custodian 收到抵押品。
跑第二次时务必递增 `NONCE`（Nonce Bitmap 会拦住重放）。

## 7. 记录（收入 `deployments/<chainId>.json`）

```bash
cast code   --rpc-url $RPC <address>    # 非 0x
cast receipt --rpc-url $RPC <txHash>    # 可查到
cast nonce  --rpc-url $RPC $DEPLOYER    # ≠ 0（证明该账户确实在这条链上发过交易）
```

三条都过再按 `deployments/README.md` 的格式落库，并把 `PostDeployCheck` 的输出贴到部署记录/issue 里。
`broadcast/` 不入库：它只证明"某次在某个 RPC 上跑过"，不证明链上存在。

## 8. 失败处置

| 情形 | 处置 |
|---|---|
| 校验报"地址上没有合约代码" | 抄错地址或指错链；直接用正确地址重跑校验，不必重部署 |
| 角色缺失/多余 | 用 `grantRole`/`revokeRole`（admin 在部署者手上时可直接修），改完重跑校验 |
| 参数错（限额、冷却期、预言机 maxAge） | 同上，`setMaxMintPerBlock` / `setCooldownDuration` / `setOracleConfig` 修正后重跑 |
| `M.setMinter` 未生效或指错 | `M.setMinter` 只有 owner 能改；先查 `M.owner()` |
| 白名单已开启但名单不全 | **不可逆**（#11 单向棘轮）。只能继续补白名单，或部署新实例 |
| 预言机存活失败 | 先确认 feed 地址与 `maxAge`；确认 Pyth 的 `publishTime` 是否已推送。真有问题就 `disableMintRedeem()`（GATEKEEPER）后修配置 |

关停手段：`GATEKEEPER_ROLE` 的 `disableMintRedeem()`（见 ADR-0009）。

## 9. 已知缺口（部署脚本尚未自动化的部分）

- **admin 移交只覆盖 `MonogramMinting`**：`M` / `PriceFeed` / `StakedM` / 分发器的 admin 仍留在部署者手上，
  需要按 §5 手动做（跟踪：#26）；
- **`COLLATERAL_MANAGER_ROLE` 不授予**：`transferToCustody` 目前无人可调用；
  OES 接入时作为独立治理动作授予（#8 / Phase 3）；
- **`BLACKLIST_MANAGER_ROLE` 不授予**：合规处置前需先授权（ADR-0007）；
- **角色变更审计**：校验脚本只能核对探针集合，完整的授权历史需要按 `RoleGranted`/`RoleRevoked` 事件复核。
