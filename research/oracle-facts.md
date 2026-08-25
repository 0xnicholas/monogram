# 预言机选型事实：Chainlink vs Pyth vs RedStone

> 对应 GitHub issue #4。本文只做事实整理，不做最终选型决策（决策在 issue #6）。
> 调研日期：2026-08-25。所有链上数据为该日实测。

## 0. 范围：Monogram 抵押资产

依据 `adr/ADR-0008.md`（预言机与价格验证）与 `src/MonogramPriceFeed.sol`，链上价格验证需覆盖：

- ETH/USD、BTC/USD（波动资产，maxAge 3600s）
- USDC/USD、USDT/USD（稳定币，maxAge 86400s）
- stETH/USD（LST，maxAge 3600s）；wstETH 由 stETH/wstETH 汇率派生或直接喂价

当前代码 `MonogramPriceFeed.getPrice()` 读取 Pyth（`getPriceUnsafe`）+ Chainlink（`AggregatorV3Interface`）双源并校验偏差（见 `src/MonogramPriceFeed.sol:39-57`）。

## 1. Feed 支持（Ethereum 主网）

### Chainlink（push 模型，读取链上常驻价格）

| 资产 | Feed proxy | 偏差阈值 | Heartbeat | 小数位 | 验证方式 |
|------|-----------|---------|-----------|--------|---------|
| ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | 0.5% | 1h | 8 | 官方地址 JSON + 链上实测（2026-08-25 02:29Z 更新，当时 $2529.27，5.5 分钟前） |
| BTC/USD | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` | 0.5% | 1h | 8 | 官方地址 JSON |
| USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` | 0.25% | 24h | 8 | 官方地址 JSON |
| USDT/USD | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` | 0.25% | 24h | 8 | 官方地址 JSON |
| stETH/USD | `0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8` | （页面上参数未能抓取） | （同左） | 8 | **链上实测**：`description()` = "STETH / USD"，`latestRoundData()` 于 2026-08-25 02:29Z 更新（$2521.62，5.3 分钟前），feed 存活且新鲜 |
| stETH/ETH | `0x86392dC19c0b719886221c78AB11eb8Cf5c52812` | 2% | 24h | 18 | 官方地址 JSON |
| wstETH/USD | **无独立主网 feed**（官方 225 个主网 proxy 清单中无） | — | — | — | 可用 stETH/USD + Lido `wstETH.stEthPerToken()` 组合 |

来源：[Chainlink 官方地址数据（docs 站点同源 JSON）](https://cl-docs-addresses.web.app/addresses.json)、[data.chain.link ETH/USD 页](https://data.chain.link/feeds/ethereum/mainnet/eth-usd)（显示 deviation 0.5%）、链上 JSON-RPC 实测（`eth_call`，2026-08-25）。

注意：官方地址 JSON（docs 用数据源）未收录 stETH/USD，但链上该 proxy 存在且正常更新——以链上实测为准。

### Pyth（pull 模型，需把签名价格更新推上链后读取）

以下 feed ID 经 Hermes API（`hermes.pyth.network/v2/price_feeds`）实测存在：

| 资产 | Feed ID |
|------|---------|
| ETH/USD | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |
| BTC/USD | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |
| USDC/USD | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` |
| USDT/USD | `0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` |
| STETH/USD | `0x846ae1bdb6300b817cee5fdee2a6da192775030db5615b94a465f53bd40850b5` |
| WSTETH/USD | `0x6df640f3b8963d8f8358f791f352b8364513f6ab1cca5ed3f1f7b5448980e784` |

- Pyth EVM 合约（Ethereum 主网）：`0x4305FB66699C3B2702D4d05CF36551390A4c69C6`（链上实测已部署）。
- **风险/待办**：Pyth 官方公告 Pyth Core EVM 合约将于 **2026-08-26 16:00 UTC** 升级，新集成应使用升级后的地址（见 [contract addresses 页](https://docs.pyth.network/price-feeds/core/contract-addresses/evm)）。

来源：[Pyth Price Feeds 文档](https://docs.pyth.network/price-feeds/core/price-feeds)、[Hermes API](https://hermes.pyth.network/v2/price_feeds?asset_type=crypto)、[合约地址页](https://docs.pyth.network/price-feeds/core/contract-addresses/evm)。

### RedStone（pull / push 双模型）

- **Pull（Core）**：签名价格数据包附加在用户交易 calldata 中，链上验证签名者与时间戳后取用。`redstone-primary-prod` 数据服务实测（2026-08-25）支持 ETH、BTC、USDC、USDT、stETH、wstETH；stETH 价格为多 CEX + DEX（Curve、Uniswap）聚合。官方 oracle-node manifest `primary.json` 确认含 `stETH`、`wstETH`、`wstETH/stETH`、`wstETH_FUNDAMENTAL` 等 418 个标的。
- **Push（Classic）**：relayer 按条件推送上链，接口兼容 Chainlink Aggregator；可按资产部署。

来源：[RedStone 公共 API 实测](https://api.redstone.finance/prices?symbols=ETH,BTC,USDC,USDT,stETH,wstETH&provider=redstone-primary-prod)、[redstone-oracles-monorepo `primary.json`](https://github.com/redstone-finance/redstone-oracles-monorepo/blob/main/packages/node-remote-config/dev/manifests/data-services/primary.json)、[RedStone Push 文档](https://docs.redstone.finance/docs/get-started/models/redstone-push)。

## 2. 更新机制与新鲜度

| | Chainlink | Pyth | RedStone |
|--|-----------|------|----------|
| 模型 | Push：DON 在偏差超阈值或 heartbeat 到期时写链 | Pull：Pythnet 约每 400ms 产出签名价格，由使用方经 Hermes 拉取并 `updatePriceFeeds()` 推上链 | Pull（Core）：数据随用户交易上链；Push（Classic）：relayer 按 heartbeat/偏差推送 |
| 触发参数 | ETH/BTC：0.5% 或 1h；USDC/USDT：0.25% 或 24h；stETH/ETH：2% 或 24h | 源端 ~400ms；**链上新鲜度取决于最近一次有人推送更新**，MonogramPriceFeed 用 `getPriceUnsafe` 需自行保证推送者 | Pull：随取随新（数据包时间戳验证窗口可调）；Push：`UPDATE_PRICE_INTERVAL` + `MIN_DEVIATION_PERCENTAGE` 自定义 |
| 对 ±5% 校验的含义 | 价格常驻链上，`view` 读取即可；稳定币 24h heartbeat 下价格可能滞后但波动小 | 必须在 mint/redeem 交易内（或之前紧邻区块）推送更新，否则 `StalePythPrice` | Pull 同样随交易更新；Push 需运营 relayer |

来源：[Chainlink Data Feeds 文档（heartbeat/deviation 模型与消费方监控建议）](https://docs.chain.link/data-feeds)、[Pyth llms-price-feeds-core.txt（"400ms updates"）](https://docs.pyth.network/llms-price-feeds-core.txt)、[RedStone Push 文档](https://docs.redstone.finance/docs/get-started/models/redstone-push)、[RedStone Pull 文档](https://docs.redstone.finance/docs/get-started/models/redstone-pull)。

## 3. 成本

- **Chainlink**：消费方读取是 `view` 调用，官方消费示例无任何付费/LINK 转移；成本为零（链上写操作 gas 由预言机网络承担）。来源：[Using Data Feeds](https://docs.chain.link/data-feeds/using-data-feeds)。
- **Pyth**：每次链上更新收取小额费用，EVM 上通常 **1 wei/次**（以 `getUpdateFee()` 返回为准），外加推送交易 gas。来源：[Pyth llms-price-feeds-core.txt](https://docs.pyth.network/llms-price-feeds-core.txt)（"Each on-chain price update costs a small fee (typically 1 wei on EVM)"）。
- **RedStone**：Pull 模式无预言机协议费，成本为 calldata 与签名验证的额外 gas；Push 模式的更新 gas 由 relayer 运营方承担。公共数据服务（如 `redstone-primary-prod`）免费开放。来源：[RedStone Pull 文档](https://docs.redstone.finance/docs/get-started/models/redstone-pull)、[RedStone push/pull 对比博客](https://blog.redstone.finance/2024/08/21/pull-oracles-vs-push-oracles/)。

## 4. 安全机制与 Ethena 的实际用法

- **Chainlink**：去中心化节点网络（OCR 共识聚合）；deviation threshold + heartbeat 触发更新；aggregator 历史上设有 `minAnswer`/`maxAnswer` 边界（现多数 feed 不再强制）；proxy/aggregator 的 owner 为 multisig，可升级配置——官方明确建议消费方自行监控 `updatedAt` 与合理价格上下限。来源：[Chainlink Data Feeds 文档](https://docs.chain.link/data-feeds)、[data.chain.link ETH/USD（节点运营商列表）](https://data.chain.link/feeds/ethereum/mainnet/eth-usd)。
- **Pyth**：第一方数据源聚合；每个价格附 **confidence interval（`conf`）**；官方 best practices 要求消费方做 staleness 检查（防 adversarial selection——pull 模型下用户可在约束内挑选历史价格）；链上验证来自 Pythnet 的签名价格更新。来源：[Pyth Best Practices](https://docs.pyth.network/price-feeds/core/best-practices)。
- **RedStone**：链上验证数据包签名（授权签名者白名单）、时间戳有效性；多签名者中位数聚合；`getUniqueSignersThreshold()` 可调签名者数量门槛；relayer 无许可（数据最终链上验证）。来源：[RedStone Pull 文档](https://docs.redstone.finance/docs/get-started/models/redstone-pull)、[RedStone Push 文档](https://docs.redstone.finance/docs/get-started/models/redstone-push)。
- **Ethena 实际做法**（[Use of Oracles](https://docs.ethena.fi/technical-design/use-of-oracles) + [Order Validity Checks](https://docs.ethena.fi/technical-design/minting-usde/order-validity-checks.md)）：
  - Ethena 实时消费 CEX（Binance/Bybit/OKX/Deribit/Bitmex/Bitget）行情作为主定价源，并用 **Pyth + RedStone 交叉验证内部定价**；
  - 该校验发生在**链下**——每笔 mint/redeem 被接受前执行 11 项验证，第 9 项「External price check」：签名订单价格需在 "specific tolerance" 内匹配 Pyth/RedStone 等外部价格源；第 8 项「Last look」同理在链下比对现价与订单价；
  - **Ethena 官方文档未公布具体容差数值**——Monogram ADR-0008 的 ±5%（500 bps）是本项目自定参数，并非来自 Ethena 文档；
  - Ethena 链上合约（EthenaMinting V2，`0xe3490297a08d6fC8Da46Edb7B6142E4F461b62D3`）只做 EIP-712 签名与限额校验，不读链上预言机——价格正确性依赖链下验证 + last-look。

## 5. 三家对比表

| 维度 | Chainlink | Pyth | RedStone |
|------|-----------|------|----------|
| 主网抵押资产覆盖 | ETH/BTC/USDC/USDT/stETH 全覆盖；无独立 wstETH/USD | 全部覆盖（含 WSTETH/USD） | 全部覆盖（含 wstETH、wstETH/stETH） |
| 模型 | Push（价格常驻链上） | Pull（需主动推送更新） | Pull 为主，Push 可选 |
| 源端频率 | 0.25–2% 偏差或 1h–24h heartbeat | ~400ms | 亚秒级（pull 随取）/ 可配（push） |
| 链上新鲜度保证 | 由 DON 运营保证 | 需协议自备推送者（keeper 或随 tx 更新） | Pull：随 tx 自带；Push：自营 relayer |
| 消费成本 | 0（view 读取） | ~1 wei/次更新 + 推送 gas | 0 协议费，calldata/验证 gas |
| 安全机制 | DON 共识、multisig 管理、阈值触发 | conf 置信区间、staleness 检查、签名验证 | 链上签名+时间戳验证、多签者中位数 |
| 与现有代码契合 | 已接入（`AggregatorV3Interface`） | 已接入（`IPyth.getPriceUnsafe`） | 未接入（接口兼容 Chainlink Aggregator 的 Push 模式可低成本替换） |
| Ethena 同款 | 否 | 是（链下交叉验证） | 是（链下交叉验证） |

## 6. 选型事实基础（非决策）

1. **链上 ±5% 校验需要"价格已在链上"**。Chainlink 满足开箱即用；Pyth/RedStone pull 都需要有人先把更新推上链，否则 `getPriceUnsafe` 读到的是旧价——当前 `MonogramPriceFeed._readPyth` 依赖外部推送者，这是一个明确的运营依赖（Ethena 之所以能用 Pyth+RedStone，是因为它的校验在链下 RFQ 系统里做，随时拉最新价，无此约束）。
2. **Ethena 的 Pyth+RedStone 组合是链下验证架构**，与其"白名单 RFQ + last-look"流程绑定；Monogram 若要在链上复刻 ±5% 校验，三家的高频价格都可用，但 pull 型价格必须解决推送问题（mint 交易内附带更新，或 keeper 高频推送）。
3. **wstETH 是 Chainlink 的覆盖缺口**（无独立主网 feed），Pyth 与 RedStone 均有直接 WSTETH feed；Chainlink 路线需组合 stETH/USD + Lido 链上汇率。
4. **成本差异在 mint/redeem 量级可忽略**：Chainlink 免费读；Pyth 约 1 wei/次 + gas；RedStone pull 仅 gas。决定因素不是费用，而是新鲜度保证与运营复杂度。
5. **时效性风险**：Pyth Core EVM 合约 2026-08-26 升级，集成时需确认最终地址；Chainlink 地址 JSON 与链上状态可能不一致（stETH/USD 即一例），配置应以链上 `description()`/`latestRoundData()` 实测为准。

## 附：验证方法

- Chainlink 参数：`https://cl-docs-addresses.web.app/addresses.json`（docs.chain.link 数据源）；stETH/USD、ETH/USD 经 `eth_call`（publicnode RPC）实测 `description()`/`decimals()`/`latestRoundData()`，2026-08-25 02:29Z 更新，查询时约 5 分钟前。
- Pyth feed ID：Hermes API `GET /v2/price_feeds?query=<pair>&asset_type=crypto`；合约存在性经 `eth_getCode` 实测。
- RedStone：`https://api.redstone.finance/prices?symbols=...&provider=redstone-primary-prod` 实测返回全部 6 个标的；feed 清单交叉核对 oracle-node manifest `primary.json`。
- Ethena：`docs.ethena.fi` 的 Use of Oracles 与 Order Validity Checks 页（含 `.md` 原文）。
