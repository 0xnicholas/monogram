## Monogram

### Architecture
| 模块                                | 主要合约                                                                  | 功能简介                                |
| --------------------------------- | --------------------------------------------------------------------- | ----------------------------------- |
| **核心资产层 (Stablecoin Core)**       | `MonogramMinting.sol`、`M.sol`、`stM.sol`                            | 实现稳定币 $M 的发行与赎回，以及收益凭证 stM 的逻辑  |
| **收益与质押层 (Staking & Rewards)**    | `StakedM.sol`、`RewardsDistributor.sol`、`MonogramOperatorRewards.sol` | 管理 stM 的质押收益、分配奖励、计算 APR          |
| **托管与路由层 (Custody & Routing)**    | `CustodianRouter.sol`、`CollateralManager.sol`                         | 负责抵押资产在多个托管方之间分配、转移、赎回              |
| **安全与访问控制层 (Access & Security)**  | `SingleAdminAccessControl.sol`、`Pausable.sol`、`ReentrancyGuard.sol`   | 管理多角色权限、暂停机制、防重入攻击                  |
| **预言机与喂价层 (Oracle & Price Feed)** | `MonogramPriceFeed.sol`、`ChainlinkOracleAdapter.sol`                    | 获取外部资产价格、校验抵押比例、计算 mint / redeem 限额 |
| **工具与签名层 (Utils & Verification)** | `SignatureVerifier.sol`、`EIP712Verifier.sol`                          | 验证来自链下系统（撮合、broker）的签名指令            |
| **合约注册与治理层 (Registry / Config)**  | `ContractRegistry.sol`、`MonogramConfig.sol`                             | 管理全局参数、各模块地址、可升级配置                  |


### Core Smart Contracts

#### `MonogramMinting.sol`
`MonogramMinting` 是一个「链上铸造/赎回控制器」，接收来自授权系统的订单（带签名），在严格风控与权限管理下执行资产流转与 $M 的增发/销毁。它是 链上网关（On-chain Gateway），把用户和经纪商的链上抵押、托管系统、$M 发行逻辑连接在一起。

* 功能：实现 $M 稳定币的 mint与 redeem 流程.
* 设计：用户抵押 ETH 或 WETH，协议通过链下/托管机构管理资金，铸造或销毁$M.
* 关键机制：EIP-712 签名验证、分批托管路由、权限分层、每区块限额防风控.

架构模块
| 模块|功能|
| ----------------------------- | -------------------------------------------------------------------------- |
| **访问控制层**                     | 使用 `SingleAdminAccessControl` 管理多种角色（MINTER、REDEEMER、CUSTODIAN、GATEKEEPER） |
| **安全层**                       | 使用 `ReentrancyGuard` 防止重入攻击                                                |
| **签名与验证层**                    | 使用 EIP-712 标准的结构化签名验证（`verifyOrder` / `verifyRoute`）                       |
| **托管路由层 (Custodian Routing)** | 支持将抵押资产按比例分配到多个托管地址（`Route` 结构）                                            |
| **限额风控层**                     | 限制每个区块的最大 mint/redeem 数量                                                   |
| **指令防重放层**                    | 使用 nonce bitmap 防止订单重复执行 (`_deduplicateOrder`)                             |

核心角色
| 角色                          | 权限                           | 说明                        |
| --------------------------- | ---------------------------- | ------------------------- |
| **MINTER_ROLE**             | 只能调用 `mint()` / `mintWETH()` | 通常是链下撮合系统或官方服务端           |
| **REDEEMER_ROLE**           | 只能调用 `redeem()`              | 执行赎回请求                    |
| **COLLATERAL_MANAGER_ROLE** | 调用 `transferToCustody()`     | 把托管资金从合约转到实际 custodian 钱包 |
| **GATEKEEPER_ROLE**         | 紧急冻结 mint/redeem；撤销其他角色权限    | 防止风险传播或攻击扩散               |
| **DEFAULT_ADMIN_ROLE**      | 管理所有角色和系统参数                  | 系统最高权限                    |

核心数据结构
- Order — 表示一次 mint 或 redeem 请求
```solidity
order_type     // MINT 或 REDEEM
expiry         // 过期时间戳
nonce          // 防重放编号
benefactor     // 资产提供者
beneficiary    // 收款人
collateral_asset // 抵押资产
collateral_amount // 抵押数量
m_amount    // 要铸造或赎回的 $M 数量
```
- Route 指定托管地址的分配比例：
``` solidity
addresses[]  // 托管钱包列表
ratios[]     // 每个钱包分配比例，总和必须等于 10000
```
- Signature
```solidity
SignatureType signature_type; // 目前只支持 EIP712
bytes signature_bytes;        // 实际签名内容
```

- **Mint流程**

| 步骤 | 操作                              | 说明                         |
| -- | ------------------------------- | -------------------------- |
| 1  | 调用 `mint()` 或 `mintWETH()`      | 仅限 MINTER_ROLE             |
| 2  | 验证订单签名（`verifyOrder`）           | 使用 EIP-712 验证 `order`      |
| 3  | 验证托管路由（`verifyRoute`）           | 确保 custodian 地址合法、比例正确     |
| 4  | 防止重复 nonce（`_deduplicateOrder`） | 防 replay 攻击                |
| 5  | 检查每区块 mint 限额                   | 防止闪电攻击或操作滥用                |
| 6  | 调用 `_transferCollateral()`      | 把用户抵押资产按比例转到托管地址           |
| 7  | 调用 `m.mint()`                | 铸造 $M 到 `beneficiary` 地址 |

- **Redemm流程**

| 步骤 | 操作                                | 说明               |
| -- | --------------------------------- | ---------------- |
| 1  | 调用 `redeem()`                     | 仅限 REDEEMER_ROLE |
| 2  | 验证订单签名                            |                  |
| 3  | 防 nonce 重放                        |                  |
| 4  | 检查每区块 redeem 限额                   |                  |
| 5  | 销毁用户的 $M (`burnFrom`)           |                  |
| 6  | 向 `beneficiary` 转回抵押资产（ETH/ERC20） |                  |


- **风控与防护机制**

| 机制                   | 功能                       |
| -------------------- | ------------------------ |
| **Nonce Bitmap**     | 防止相同订单被多次执行              |
| **Max per block 限额** | 防止巨额 mint/redeem 导致流动性失衡 |
| **角色分层**             | 不同权限账户隔离，降低被攻破风险         |
| **EIP-712 签名**       | 防止伪造操作与重放攻击              |
| **ReentrancyGuard**  | 防止重入漏洞                   |
| **Gatekeeper 一键冻结**  | 紧急停机开关                   |


- **架构理念总结**

| 设计目标        | 实现机制                               |
| ----------- | ---------------------------------- |
| **资产安全**    | 用户资产仅通过安全合约转移，托管钱包可控               |
| **链下指令控制**  | 通过 EIP712 签名 + Minter 权限确保仅授权系统可操作 |
| **多路托管与风控** | Route 机制确保资产分散托管                   |
| **低信任执行**   | 尽管操作依赖链下经纪商，但链上验证严格约束可操作范围         |

