# 刷新差距现状：当前代码 vs Ethena V2

> Issue #2 · 研究日期 2026-08-25 · 分支 `research/refresh-gap`
>
> 本文取代仓库根目录 `MONOGRAM_VS_ETHENA.md`（写于 stub 阶段，已严重过时）。

## 0. 数据来源与方法

**Monogram 侧**：通读工作区 `src/` 全部 7 个合约、`src/interfaces/` 8 个接口、`test/` 5 个测试文件（约 95 个测试用例）。

**Ethena 侧**（均为链上已验证源码，非文档转述）：

| 合约 | 地址 | 编译器 | 来源 |
|------|------|--------|------|
| EthenaMinting (V2) | `0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3` | 0.8.20 | Blockscout 已验证源码 |
| USDe | `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` | 0.8.19 | 同上 |
| StakedUSDeV2 | `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` | 0.8.19 | 同上（含 StakedUSDe、USDeSilo 全部附加源码） |
| StakingRewardsDistributor | `0xf2fa332bD83149c66b09B45670bCe64746C6b439` | 0.8.20 | 同上 |

**验证限制**：本环境 `forge` 二进制因缺少 `libusb-1.0.0.dylib` 无法运行，测试未能实际执行；结论基于静态阅读。测试文件本身的覆盖面见第 10 节。

## 1. 总体完成度矩阵（刷新）

| 模块 | 旧文档评估 | 当前实际 | 完成度 |
|------|-----------|----------|:------:|
| 稳定币代币 M | 100% | 与 USDe.sol **逐行等价** | **100%** |
| 铸造/赎回引擎 | ~30%（骨架空实现） | EIP-712/nonce/route/限额/价格验证全部实现 | **~75%** |
| 预言机 | 0%（不存在） | MonogramPriceFeed 已实现（Pyth+Chainlink 双源） | **80%*** |
| 质押 StakedM | 0%（空壳） | ERC-4626 + 8h vesting + 冷却 + 受限地址已实现 | **~65%** |
| 收益分发 | 0%（不存在） | StakingRewardsDistributor 已实现（简化版） | **~50%** |
| 托管路由 | ~50% | Route/verifyRoute/transferToCustody 完整（与 Ethena 等价） | **~90%** |
| 权限角色 | 90%（有空字符串 bug） | bug 已修，SingleAdminAccessControl 照抄 Ethena | **95%** |
| 签名验证 | ~20% | EIP-712 完整；仍无 EIP-1271 | **~70%** |
| 白名单 | 0% | 仍无 benefactor 白名单 / approved beneficiary | **0%** |
| 储备金 | 0% | 仍无 Reserve Fund | **0%** |
| 链下对冲系统 | 0% | 仍无（链下组件，不属于本仓库） | **0%** |
| 透明度（PoR/仪表盘） | 0% | 仍无 | **0%** |

\* Ethena V2 链上**根本没有**价格预言机（见第 3.4 节），Monogram 的预言机层是超出 Ethena 的设计，百分比按其自身设计目标衡量。

**整体加权完成度：约 55-60%**（旧文档的 15-20% 已不适用）。

## 2. 代币：M.sol vs USDe.sol

两者**逐行等价**：`Ownable2Step + ERC20Burnable + ERC20Permit`、单 `minter` 地址、`setMinter` onlyOwner、`renounceOwnership` revert、构造时零地址检查。唯一差别是名称/符号和 Monogram 把事件/错误直接写在合约内（Ethena 放在 `IUSDeDefinitions` 接口）。此模块无差距。

## 3. 铸造/赎回引擎：MonogramMinting vs EthenaMinting V2

### 3.1 已实现且与 V2 等价的部分

- EIP-712 签名验证：`hashOrder` / `encodeOrder` / `getDomainSeparator`（含 chainId 变化时重算 domain separator，防分叉重放）——与 V2 逻辑一致（`abi.encodePacked("\x19\x01",...)` 与 `ECDSA.toTypedDataHash` 等价）。
- Nonce bitmap 防重放：`_orderBitmaps` + `_deduplicateOrder`，slot/bit 算法与 V2 相同。
- Route 路由验证：比例总和必须 = 10000、地址必须在托管人集合内——与 V2 相同。
- 委托签名人 `delegatedSigner` 三态状态机（PENDING→ACCEPTED/REJECTED）——**与 V2 完全相同**。
- Per-block 限额 + Gatekeeper 一键关停（`disableMintRedeem` 将限额设 0）。
- `transferToCustody`（COLLATERAL_MANAGER_ROLE，目标必须在托管人集合）。
- `mintWETH`（WETH 解包为原生 ETH 分发）——与 V2 相同。
- 角色集合 MINTER/REDEEMER/COLLATERAL_MANAGER/GATEKEEPER + gatekeeper 可移除 minter/redeemer/collateralManager——与 V2 相同。

### 3.2 仍存在的具体差异（Monogram 缺失）

1. **无 EIP-1271 合约签名支持**。V2 的 `SignatureType` 有 `EIP712` 和 `EIP1271` 两个分支，会对 `order.benefactor` 调 `isValidSignature` 并校验 magic value。Monogram 的 `SignatureType` 枚举只有 `EIP712`，且 `verifyOrder`（`MonogramMinting.sol:349-361`）**根本不读 `signature.signature_type`**，合约钱包 benefactor 无法使用。
2. **无 benefactor 白名单**。V2 在 `verifyOrder` 末尾强制 `_whitelistedBenefactors.contains(order.benefactor)`（KYC 门控，admin 可增删）。Monogram 无任何白名单。
3. **无 approved beneficiary 机制**。V2 要求 benefactor≠beneficiary 时，beneficiary 必须在 `_approvedBeneficiariesPerBenefactor[benefactor]` 中（benefactor 自己管理）。Monogram 不校验，签名的 M 可被发到任意地址。
4. **无 per-asset 限额与 TokenConfig**。V2 每种资产有独立 `TokenConfig{tokenType, maxMintPerBlock, maxRedeemPerBlock, isActive}`，外加全局 `GlobalConfig` 双层限额。Monogram 只有单一全局 `maxMintPerBlock`/`maxRedeemPerBlock`，无法按资产分别限流或单独停用某资产 mint（只能整体 removeSupportedAsset）。
5. **无 `order_id` 字段**。V2 的 Order 含 `string order_id` 并进入签名哈希与事件，供链下 RFQ 系统对账。Monogram 的 Order 无此字段。
6. **无 `verifyStablesLimit` / `stablesDeltaLimit`**。V2 对 `TokenType.STABLE` 资产做 1:1 附近的链上价差检查（防稳定币脱钩套利）。Monogram 用通用预言机偏差检查替代（见 3.4），功能上有覆盖但机制不同。
7. **verifyOrder 校验项更少**。V2 还检查 `beneficiary != 0`、`collateral_amount/usde_amount != 0`。Monogram 只在 `_validatePrice` 中间接拦截零金额，`beneficiary == address(0)` 无检查（M 会铸到零地址 → revert 于 ERC20 层，但错误语义不清）。
8. **nonce==0 未拒绝**。V2 `verifyNonce` 对 `nonce == 0` revert；Monogram（`MonogramMinting.sol:377-382`）允许 nonce 0 使用一次。
9. **verifyRoute 允许 ratio=0 的地址**。V2 对 `ratios[i] == 0` 返回 false；Monogram（`MonogramMinting.sol:363-375`）不检查单项比例非零。

### 3.3 Monogram 超出 Ethena 的部分

- **链上价格验证 `_validatePrice`**（`MonogramMinting.sol:394-401`）：调 `priceFeed.getPrice`，要求抵押品美元价值与 M 数量偏差 ≤ `maxPriceDeviationBps`（默认 500bps），并有 1 小时 staleness 检查。Ethena V2 链上没有这一层（价格由链下 RFQ 服务器定价，用户签名即认可报价）。

### 3.4 需要纠正的旧文档错误认知

- 旧文档称 Ethena V2「链上 Pyth + Redstone ±5% 验证」——**错误**。EthenaMinting V2 已验证源码中没有任何预言机调用，链上价格相关检查只有 `verifyStablesLimit`（稳定币 1:1 delta limit）。多 CEX 订单簿定价发生在链下。
- 旧文档称 DelegatedSigner 是「Monogram 特有、Ethena 无此概念」——**错误**。V2 有完全相同的 `delegatedSigner` 机制（V2 注释："For smart contracts to delegate signing to EOA address"），Monogram 是照抄。

### 3.5 当前实现中的可疑缺陷（新发现）

- **小数位未归一化**：`_validatePrice` 计算 `collateralUsd = collateralAmount * price / 1e18`，隐含假设抵押品为 18 位小数。对 USDC/USDT（6 位小数）mint 必然因偏差超限而 revert——按当前实现，6 位小数稳定币抵押品实际上不可用。
- **`StalePrice` 检查是死代码**：`MonogramPriceFeed.getPrice` 返回的 `updatedAt` 恒为 `block.timestamp`（`MonogramPriceFeed.sol:56`），所以 `block.timestamp - timestamp > 3600` 永远不成立。真实的 staleness 校验在 feed 内部（`maxAge`），minting 合约里这层是摆设。
- 构造函数重复条件仍存在，见第 8 节。

## 4. 预言机：MonogramPriceFeed

Ethena 链上无对应合约，此模块是 Monogram 自有设计：Pyth（`getPriceUnsafe`）+ Chainlink 双源，偏差超 `maxDeviation` 则 revert，取两者均值，按资产配置 `maxAge`。AccessControl 管理配置（ORACLE_ADMIN_ROLE）。

注意点：
- 用 `getPriceUnsafe` 而不校验 Pyth 置信区间（`conf`），极端行情下可能采信低置信价格。
- `updatedAt` 返回 `block.timestamp` 而非底层发布时间（下游依赖它的检查失效，见 3.5）。
- 偏差基准 `base` 取两者较大值，偏差被低估约一半（相对较小值），影响轻微。
- Fork 测试（`test/MonogramFork.t.sol`）已覆盖 Sepolia 上 Pyth/Chainlink 真实读取。

## 5. 质押与收益：StakedM vs StakedUSDeV2

### 5.1 已实现且等价的部分

- ERC-4626 vault，`totalAssets()` 扣除未 vesting 奖励，**8 小时线性 vesting**（与 Ethena `VESTING_PERIOD` 相同）。
- `transferInRewards`（REWARDER_ROLE）：Ethena 要求上一笔 vesting 完才能转新奖励（`StillVesting`），Monogram 改为把未 vesting 余额合并进新一轮（`_totalRewards` 重算）——语义不同但目的等价，Monogram 版更灵活。
- `MAX_COOLDOWN_DURATION = 90 days`、`setCooldownDuration` admin 可配。
- SOFT/FULL 受限地址角色、`redistributeLockedAmount`（烧 FULL 受限地址份额并铸给新地址）。

### 5.2 仍存在的具体差异（Monogram 缺失或有缺陷）

1. **冷却期可被完全绕过（关键设计缺陷）**。StakedUSDeV2 在 `cooldownDuration > 0` 时**禁用** ERC-4626 的 `withdraw/redeem`（`ensureCooldownOff`/`ensureCooldownOn` 二选一互斥），解质押必须走 `cooldownShares/cooldownAssets` → 资产进 USDeSilo → `unstake` 领取。Monogram 的 `withdraw/redeem`（`StakedM.sol:56-72`）永远可用，`requestRedeem/claimRedemption` 冷却路径形同虚设——用户随时可即时赎回，冷却期没有任何强制力。
2. **无 USDeSilo，且 requestRedeem 的会计方式有风险**。Ethena 冷却时资产立即转入 Silo、退出 `totalAssets`，不再产生收益也不稀释。Monogram `requestRedeem`（`StakedM.sol:102-117`）在请求时**烧掉 shares 但资产留在 vault 内**，仍计入 `totalAssets`——已排队赎回的资产继续推高其他持有人份额价格（稀释），且若 vault 余额在冷却期内被其他提取消耗，`claimRedemption` 可能无款可付。
3. **无 MIN_SHARES 防捐赠攻击检查**（Ethena 要求 totalSupply 为 0 或 ≥1 ether）。
4. **受限地址语义不同且更弱**。Ethena：SOFT 只挡 deposit，FULL 挡 withdraw 且通过 `_beforeTokenTransfer` 钩子**禁止转账**；Monogram 的 `_checkNotRestricted` 对 deposit/mint/withdraw/redeem 一律同时挡 SOFT+FULL，但**不拦截 ERC20 transfer**——FULL 受限地址仍能把 stM 转走。
5. **无黑名单管理接口**。Ethena 有 `BLACKLIST_MANAGER_ROLE` + `addToBlacklist/removeFromBlacklist` + `notOwner` 保护；Monogram 定义了 `BLACKLISTER_ROLE` 但只用于 `redistributeLockedAmount`，加/移黑名单只能由 DEFAULT_ADMIN 走通用 `grantRole`。
6. **其他小项**：无 `renounceRole` 禁用（Ethena 直接 revert）、无 `rescueTokens`、`redistributeLockedAmount` 不支持 `to == address(0)` 的 burn-to-vest 分支（Ethena 有）、无 `ERC20Permit`（sUSDe 有）。

## 6. 收益分发：StakingRewardsDistributor

两者角色定位相同（operator 定期把收益转入 staking vault），但资金路径不同：

- **Ethena 版**（Ownable2Step）：operator 是 EthenaMinting 的 delegated signer，合约持有的抵押品（WETH 等）可直接**在分发器内走完整 mint 流程铸出 USDe** 再 `transferInRewards`——收益从抵押品增值到 sUSDe 全链上闭环，含 approveToMintContract、rescue 等。
- **Monogram 版**（AccessControl）：operator 必须自己持有 M，合约 `transferFrom` 拉过来再 `approve + transferInRewards`，外加 1 天最小分发间隔（`DISTRIBUTION_INTERVAL`）。**没有与 MonogramMinting 的任何集成**，M 从哪来完全依赖链下流程。功能约为 Ethena 版的 50%。

## 7. 托管路由与权限角色

- 链上部分（Route 比例分配、托管人集合、`transferToCustody`）与 Ethena **基本等价**，差距主要在 3.2 列出的校验细节。OES（Copper/Ceffu 等破产隔离托管）本身是链下安排，两边合约层都只有「转到白名单托管地址」这一层。
- `SingleAdminAccessControl` 与 Ethena 同名合约逐行等价（单 DEFAULT_ADMIN、两步转移、禁止对 admin 角色直接 grant/revoke/renounce）。注意 **AGENTS.md 声称该合约「已废弃，改用 OZ AccessControl」，但 `MonogramMinting.sol:15` 仍在继承使用它**——文档与代码不一致，应二选一。StakedM/StakingRewardsDistributor/MonogramPriceFeed 用的是普通 OZ AccessControl。
- 治理层面（多签 7/10、7 天时间锁）只在 AGENTS.md 文字中，链上无任何 timelock 实现；Ethena 同样靠链下多签，此项持平。

## 8. 旧文档第 9 节「代码问题清单」校验

| # | 旧问题 | 现状 |
|---|--------|------|
| 1 | 角色常量为空字符串 `""` | ✅ **已修复**，`MonogramMinting.sol:30-36` 均为 `keccak256("..._ROLE")` |
| 2 | 构造函数重复 `if (address(_m) == address(0))` | ❌ **仍存在**，`MonogramMinting.sol:101-102` 两行条件完全相同，第二行应检查 `_weth` |
| 3 | 五个核心函数空实现 | ✅ **全部已实现**（hashOrder/verifyOrder/verifyRoute/verifyNonce/addSupportedAsset） |
| 4 | addSupportedAsset/addCustodianAddress 构造调用不生效 | ✅ 已随实现修复（构造函数先 `_grantRole(DEFAULT_ADMIN_ROLE, msg.sender)`，循环调用有效） |
| 5 | getDomainSeparator/encodeOrder 空实现 | ✅ 已修复 |
| 6 | 未使用的 ECDSA import | ✅ 已修复（`ECDSA.recover` 在 verifyOrder 中使用） |

**新发现问题**（详见 3.5/4/5.2）：构造函数重复检查、`_validatePrice` 小数位假设、`StalePrice` 死代码、冷却期可绕过、requestRedeem 资产滞留稀释、FULL 受限地址可转账、verifyRoute 允许零比例、nonce==0 未拒绝。

## 9. 风控机制现状

| 风控项 | Ethena V2 | Monogram 现状 |
|--------|-----------|---------------|
| Per-block 限额 | ✅ 全局 + 每资产双层 | ⚠️ 仅全局 |
| Gatekeeper 关停 | ✅ | ✅ `disableMintRedeem` |
| 链上价格校验 | 仅 stables delta limit | ✅ 预言机偏差 ±500bps（超出 Ethena，但有 3.5 的缺陷） |
| Nonce 防重放 | ✅ | ✅（nonce 0 边界除外） |
| 防重入 | ✅ | ✅ |
| Benefactor 白名单 / KYC | ✅ | ❌ |
| Approved beneficiary | ✅ | ❌ |
| 解质押冷却 | ✅ 强制（禁用即时赎回 + Silo） | ⚠️ 有代码但可绕过 |
| 受限地址（合规） | ✅ 含转账拦截 | ⚠️ 不拦截转账 |
| Reserve Fund | ✅（链下/治理） | ❌ |
| PoR / 仪表盘 | ✅ | ❌ |
| Timelock | 链下多签 | 链下多签（持平） |

## 10. 测试覆盖概况

约 95 个用例：MonogramMinting（40 个，含 mint/redeem 正路、签名错误、重放、限额、route、角色、delegated signer）、StakedM（24 个，含 vesting、冷却、受限、redistribute）、MonogramPriceFeed（7 个，mock 双预言机 + 偏差）、Integration（5 个端到端：mint→stake→rewards→unstake）、MonogramFork（7 个，Sepolia 真实 Pyth/Chainlink/WETH fork 测试）。未覆盖：EIP-1271、白名单（功能本身缺失）、6 位小数抵押品、冷却绕过路径。**注意：本次研究环境 forge 无法运行，以上测试最近一次的通过状态未经本次验证。**

## 11. 追赶优先级建议（刷新版）

```
P0（现有代码正确性）
├── 修复 _validatePrice 小数位归一化（否则 USDC/USDT 抵押品不可用）
├── 修复 StakedM 冷却绕过：cooldownDuration>0 时禁用 ERC4626 withdraw/redeem，
│   并引入 Silo 式资产隔离（或至少把待领资产移出 totalAssets）
└── 修复构造函数重复 if（MonogramMinting.sol:101-102）

P1（对齐 Ethena V2 功能）
├── EIP-1271 签名分支 + SignatureType 校验
├── benefactor 白名单 + approved beneficiary
├── per-asset TokenConfig（每资产限额 + isActive）
├── Order 增加 order_id（链下对账）
└── 黑名单管理接口 + FULL 受限地址转账拦截 + MIN_SHARES

P2（经济闭环）
├── StakingRewardsDistributor 与 MonogramMinting 的 mint 集成
├── Reserve Fund / 保险基金
└── 链下对冲系统（delta-neutral 核心，当前仓库外）

P3（运营与信任）
├── Timelock 多签的链上实现
├── PoR / 透明度仪表盘
└── AGENTS.md 与 SingleAdminAccessControl 的文档/代码一致性
```
