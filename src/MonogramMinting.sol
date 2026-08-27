// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

import "./SingleAdminAccessControl.sol";
import "./interfaces/IM.sol";
import "./interfaces/IMonogramMinting.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/IMonogramPriceFeed.sol";

contract MonogramMinting is IMonogramMinting, SingleAdminAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* --------------- CONSTANTS --------------- */

    bytes32 private constant EIP712_DOMAIN =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant ROUTE_TYPE = keccak256("Route(address[] addresses,uint256[] ratios)");

    bytes32 private constant ORDER_TYPE = keccak256(
        "Order(string order_id,uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );

    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    bytes32 private constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    bytes32 private constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");

    bytes32 private constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");

    bytes4 private constant EIP1271_MAGICVALUE = bytes4(keccak256("isValidSignature(bytes32,bytes)"));

    address private constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes32 private constant EIP_712_NAME = keccak256("MonogramMinting");

    bytes32 private constant EIP712_REVISION = keccak256("1");

    uint256 private constant ROUTE_REQUIRED_RATIO = 10_000;

    IWETH9 private immutable WETH;

    IMonogramPriceFeed public immutable priceFeed;

    uint256 public maxPriceDeviationBps = 500;

    /* --------------- STATE VARIABLES --------------- */

    IM public immutable m;

    /// @notice whitelisted benefactors（仅当 whitelistEnabled 时强制检查）
    EnumerableSet.AddressSet private _whitelistedBenefactors;

    /// @notice approved beneficiaries for a given benefactor（仅当 whitelistEnabled 时强制检查）
    mapping(address => EnumerableSet.AddressSet) private _approvedBeneficiariesPerBenefactor;

    /// @notice Monogram 偏离 V2 点：白名单开关，默认关闭（V2 为强制检查），见 GitHub issue #5 决议；
    /// 主网部署后启用且不可逆（单向棘轮），见 GitHub issue #11 决议
    bool public whitelistEnabled;

    EnumerableSet.AddressSet internal _custodianAddresses;

    uint256 private immutable _chainId;

    bytes32 private immutable _domainSeparator;

    mapping(address => mapping(uint256 => uint256)) private _orderBitmaps;

    mapping(address => mapping(address => DelegatedSignerStatus)) public delegatedSigner;

    /// @notice global single block totals
    GlobalConfig public globalConfig;

    /// @notice running total M minted/redeemed per single block
    mapping(uint256 => BlockTotals) public totalPerBlock;

    /// @notice running total M minted/redeemed per single block per asset
    mapping(uint256 => mapping(address => BlockTotals)) public totalPerBlockPerAsset;

    /// @notice configurations per token asset
    mapping(address => TokenConfig) public tokenConfig;

    /* --------------- MODIFIERS --------------- */
    /// @notice ensure that the already minted M for the given asset in the actual block plus the amount to be minted is below the asset's maxMintPerBlock
    modifier belowMaxMintPerBlock(uint256 mintAmount, address asset) {
        TokenConfig memory _config = tokenConfig[asset];
        if (!_config.isActive) revert UnsupportedAsset();
        if (totalPerBlockPerAsset[block.number][asset].mintedPerBlock + mintAmount > _config.maxMintPerBlock) {
            revert MaxMintPerBlockExceeded();
        }
        _;
    }

    /// @notice ensure that the already redeemed M for the given asset in the actual block plus the amount to be redeemed is below the asset's maxRedeemPerBlock
    modifier belowMaxRedeemPerBlock(uint256 redeemAmount, address asset) {
        TokenConfig memory _config = tokenConfig[asset];
        if (!_config.isActive) revert UnsupportedAsset();
        if (totalPerBlockPerAsset[block.number][asset].redeemedPerBlock + redeemAmount > _config.maxRedeemPerBlock) {
            revert MaxRedeemPerBlockExceeded();
        }
        _;
    }

    /// @notice ensure that the globally minted M in the actual block plus the amount to be minted is below globalMaxMintPerBlock
    modifier belowGlobalMaxMintPerBlock(uint256 mintAmount) {
        if (totalPerBlock[block.number].mintedPerBlock + mintAmount > globalConfig.globalMaxMintPerBlock) {
            revert GlobalMaxMintPerBlockExceeded();
        }
        _;
    }

    /// @notice ensure that the globally redeemed M in the actual block plus the amount to be redeemed is below globalMaxRedeemPerBlock
    modifier belowGlobalMaxRedeemPerBlock(uint256 redeemAmount) {
        if (totalPerBlock[block.number].redeemedPerBlock + redeemAmount > globalConfig.globalMaxRedeemPerBlock) {
            revert GlobalMaxRedeemPerBlockExceeded();
        }
        _;
    }

    /* --------------- CONSTRUCTOR --------------- */
    constructor(
        IM _m,
        IWETH9 _weth,
        IMonogramPriceFeed _priceFeed,
        address[] memory _assets,
        TokenConfig[] memory _tokenConfig,
        GlobalConfig memory _globalConfig,
        address[] memory _custodians,
        address _admin
    ) {
        if (address(_m) == address(0)) revert InvalidMAddress();
        if (address(_priceFeed) == address(0)) revert InvalidZeroAddress();
        if (_assets.length == 0) revert NoAssetsProvided();
        if (_assets.length != _tokenConfig.length) revert InvalidAssetAddress();
        if (_admin == address(0)) revert InvalidZeroAddress();

        m = _m;
        WETH = _weth;
        priceFeed = _priceFeed;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        for (uint256 j = 0; j < _custodians.length;) {
            addCustodianAddress(_custodians[j]);
            unchecked {
                ++j;
            }
        }

        globalConfig = _globalConfig;

        for (uint256 k = 0; k < _assets.length;) {
            if (tokenConfig[_assets[k]].isActive || _assets[k] == address(0) || _assets[k] == address(_m)) {
                revert InvalidAssetAddress();
            }
            _setTokenConfig(_assets[k], _tokenConfig[k]);
            unchecked {
                ++k;
            }
        }

        if (msg.sender != _admin) {
            _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        }

        _chainId = block.chainid;
        _domainSeparator = _computeDomainSeparator();

        emit MSet(address(_m));
    }

    /* --------------- EXTERNAL --------------- */
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function mint(Order calldata order, Route calldata route, Signature calldata signature)
        external
        override
        nonReentrant
        onlyRole(MINTER_ROLE)
        belowMaxMintPerBlock(order.m_amount, order.collateral_asset)
        belowGlobalMaxMintPerBlock(order.m_amount)
    {
        if (order.order_type != OrderType.MINT) {
            revert InvalidOrder();
        }
        verifyOrder(order, signature);
        if (!verifyRoute(route)) revert InvalidRoute();
        _deduplicateOrder(order.benefactor, order.nonce);
        _validatePrice(order.collateral_asset, order.collateral_amount, order.m_amount);

        totalPerBlockPerAsset[block.number][order.collateral_asset].mintedPerBlock += order.m_amount;
        totalPerBlock[block.number].mintedPerBlock += order.m_amount;
        _transferCollateral(
            order.collateral_amount, order.collateral_asset, order.benefactor, route.addresses, route.ratios
        );
        m.mint(order.beneficiary, order.m_amount);
        emit Mint(
            order.order_id,
            order.benefactor,
            order.beneficiary,
            msg.sender,
            order.collateral_asset,
            order.collateral_amount,
            order.m_amount
        );
    }

    function mintWETH(Order calldata order, Route calldata route, Signature calldata signature)
        external
        nonReentrant
        onlyRole(MINTER_ROLE)
        belowMaxMintPerBlock(order.m_amount, order.collateral_asset)
        belowGlobalMaxMintPerBlock(order.m_amount)
    {
        if (order.order_type != OrderType.MINT) {
            revert InvalidOrder();
        }
        verifyOrder(order, signature);
        if (!verifyRoute(route)) revert InvalidRoute();
        _deduplicateOrder(order.benefactor, order.nonce);
        _validatePrice(order.collateral_asset, order.collateral_amount, order.m_amount);

        totalPerBlockPerAsset[block.number][order.collateral_asset].mintedPerBlock += order.m_amount;
        totalPerBlock[block.number].mintedPerBlock += order.m_amount;
        _transferEthCollateral(
            order.collateral_amount, order.collateral_asset, order.benefactor, route.addresses, route.ratios
        );
        m.mint(order.beneficiary, order.m_amount);
        emit Mint(
            order.order_id,
            order.benefactor,
            order.beneficiary,
            msg.sender,
            order.collateral_asset,
            order.collateral_amount,
            order.m_amount
        );
    }

    function redeem(Order calldata order, Signature calldata signature)
        external
        override
        nonReentrant
        onlyRole(REDEEMER_ROLE)
        belowMaxRedeemPerBlock(order.m_amount, order.collateral_asset)
        belowGlobalMaxRedeemPerBlock(order.m_amount)
    {
        if (order.order_type != OrderType.REDEEM) {
            revert InvalidOrder();
        }
        verifyOrder(order, signature);
        _deduplicateOrder(order.benefactor, order.nonce);
        _validatePrice(order.collateral_asset, order.collateral_amount, order.m_amount);

        totalPerBlockPerAsset[block.number][order.collateral_asset].redeemedPerBlock += order.m_amount;
        totalPerBlock[block.number].redeemedPerBlock += order.m_amount;
        m.burnFrom(order.benefactor, order.m_amount);
        _transferToBeneficiary(order.beneficiary, order.collateral_asset, order.collateral_amount);
        emit Redeem(
            order.order_id,
            order.benefactor,
            order.beneficiary,
            msg.sender,
            order.collateral_asset,
            order.collateral_amount,
            order.m_amount
        );
    }

    /// @notice Sets the overall, global maximum M mint size per block
    function setGlobalMaxMintPerBlock(uint256 _globalMaxMintPerBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        globalConfig.globalMaxMintPerBlock = _globalMaxMintPerBlock;
    }

    /// @notice Sets the overall, global maximum M redeem size per block
    function setGlobalMaxRedeemPerBlock(uint256 _globalMaxRedeemPerBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        globalConfig.globalMaxRedeemPerBlock = _globalMaxRedeemPerBlock;
    }

    function setMaxMintPerBlock(uint256 _maxMintPerBlock, address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxMintPerBlock(_maxMintPerBlock, asset);
    }

    function setMaxRedeemPerBlock(uint256 _maxRedeemPerBlock, address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxRedeemPerBlock(_maxRedeemPerBlock, asset);
    }

    function setMaxPriceDeviationBps(uint256 _maxPriceDeviationBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldValue = maxPriceDeviationBps;
        maxPriceDeviationBps = _maxPriceDeviationBps;
        emit MaxPriceDeviationBpsChanged(oldValue, maxPriceDeviationBps);
    }

    function disableMintRedeem() external onlyRole(GATEKEEPER_ROLE) {
        globalConfig.globalMaxMintPerBlock = 0;
        globalConfig.globalMaxRedeemPerBlock = 0;
    }

    function setDelegatedSigner(address _delegateTo) external {
        delegatedSigner[_delegateTo][msg.sender] = DelegatedSignerStatus.PENDING;
        emit DelegatedSignerInitiated(_delegateTo, msg.sender);
    }

    function confirmDelegatedSigner(address _delegatedBy) external {
        if (delegatedSigner[msg.sender][_delegatedBy] != DelegatedSignerStatus.PENDING) {
            revert DelegationNotInitiated();
        }
        delegatedSigner[msg.sender][_delegatedBy] = DelegatedSignerStatus.ACCEPTED;
        emit DelegatedSignerAdded(msg.sender, _delegatedBy);
    }

    function removeDelegatedSigner(address _removedSigner) external {
        delegatedSigner[_removedSigner][msg.sender] = DelegatedSignerStatus.REJECTED;
        emit DelegatedSignerRemoved(_removedSigner, msg.sender);
    }

    function transferToCustody(address wallet, address asset, uint256 amount)
        external
        nonReentrant
        onlyRole(COLLATERAL_MANAGER_ROLE)
    {
        if (wallet == address(0) || !_custodianAddresses.contains(wallet)) revert InvalidAddress();
        if (asset == NATIVE_TOKEN) {
            (bool success,) = wallet.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(wallet, amount);
        }
        emit CustodyTransfer(wallet, asset, amount);
    }

    /// @notice Removes an asset from the supported assets list
    function removeSupportedAsset(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!tokenConfig[asset].isActive) revert InvalidAssetAddress();
        delete tokenConfig[asset];
        emit AssetRemoved(asset);
    }

    /// @notice Checks if an asset is supported.
    function isSupportedAsset(address asset) external view returns (bool) {
        return tokenConfig[asset].isActive;
    }

    /// @notice Adds an asset with its per-asset config
    function addSupportedAsset(address asset, TokenConfig memory _tokenConfig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tokenConfig[asset].isActive || asset == address(0) || asset == address(m)) {
            revert InvalidAssetAddress();
        }
        _setTokenConfig(asset, _tokenConfig);
        emit AssetAdded(asset);
    }

    /// @notice Removes an custodian from the custodian address list
    function removeCustodianAddress(address custodian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_custodianAddresses.remove(custodian)) revert InvalidCustodianAddress();
        emit CustodianAddressRemoved(custodian);
    }

    /// @notice Removes the minter role from an account, this can ONLY be executed by the gatekeeper role
    /// @param minter The address to remove the minter role from
    function removeMinterRole(address minter) external onlyRole(GATEKEEPER_ROLE) {
        _revokeRole(MINTER_ROLE, minter);
    }

    /// @notice Removes the redeemer role from an account, this can ONLY be executed by the gatekeeper role
    /// @param redeemer The address to remove the redeemer role from
    function removeRedeemerRole(address redeemer) external onlyRole(GATEKEEPER_ROLE) {
        _revokeRole(REDEEMER_ROLE, redeemer);
    }

    /// @notice Removes the collateral manager role from an account, this can ONLY be executed by the gatekeeper role
    /// @param collateralManager The address to remove the collateralManager role from
    function removeCollateralManagerRole(address collateralManager) external onlyRole(GATEKEEPER_ROLE) {
        _revokeRole(COLLATERAL_MANAGER_ROLE, collateralManager);
    }

    /// @notice Removes the benefactor address from the benefactor whitelist
    function removeWhitelistedBenefactor(address benefactor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_whitelistedBenefactors.remove(benefactor)) revert InvalidAddress();
        emit BenefactorRemoved(benefactor);
    }

    /// @notice Enables the benefactor/beneficiary whitelist checks in verifyOrder (one-way ratchet)
    /// @dev 单向棘轮（#11 决议）：仅允许 false→true，启用后不可逆；关闭白名单在链上不可达，
    ///      紧急停机用 GATEKEEPER 的 disableMintRedeem
    function setWhitelistEnabled(bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_enabled) revert WhitelistDisableNotSupported();
        if (whitelistEnabled) revert WhitelistAlreadyEnabled();
        whitelistEnabled = _enabled;
        emit WhitelistEnabledSet(_enabled);
    }

    /* --------------- PUBLIC --------------- */

    function addCustodianAddress(address custodian) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (custodian == address(0) || custodian == address(m)) revert InvalidCustodianAddress();
        if (!_custodianAddresses.add(custodian)) revert InvalidCustodianAddress();
        emit CustodianAddressAdded(custodian);
    }

    /// @notice Adds a benefactor address to the benefactor whitelist
    function addWhitelistedBenefactor(address benefactor) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (benefactor == address(0) || !_whitelistedBenefactors.add(benefactor)) {
            revert InvalidBenefactorAddress();
        }
        emit BenefactorAdded(benefactor);
    }

    /// @notice Adds or removes a beneficiary address from the caller's approved beneficiaries list
    /// @param beneficiary The beneficiary address
    /// @param status true to approve, false to remove
    function setApprovedBeneficiary(address beneficiary, bool status) public {
        if (status) {
            if (!_approvedBeneficiariesPerBenefactor[msg.sender].add(beneficiary)) {
                revert InvalidBeneficiaryAddress();
            }
            emit BeneficiaryAdded(msg.sender, beneficiary);
        } else {
            if (!_approvedBeneficiariesPerBenefactor[msg.sender].remove(beneficiary)) {
                revert InvalidBeneficiaryAddress();
            }
            emit BeneficiaryRemoved(msg.sender, beneficiary);
        }
    }

    function getDomainSeparator() public view returns (bytes32) {
        if (block.chainid == _chainId) return _domainSeparator;
        return _computeDomainSeparator();
    }

    function hashOrder(Order calldata order) public view override returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", getDomainSeparator(), keccak256(encodeOrder(order))));
    }

    function encodeOrder(Order calldata order) public pure returns (bytes memory) {
        return abi.encode(
            ORDER_TYPE,
            keccak256(bytes(order.order_id)),
            order.order_type,
            order.expiry,
            order.nonce,
            order.benefactor,
            order.beneficiary,
            order.collateral_asset,
            order.collateral_amount,
            order.m_amount
        );
    }

    function verifyOrder(Order calldata order, Signature calldata signature)
        public
        view
        override
        returns (bytes32 taker_order_hash)
    {
        taker_order_hash = hashOrder(order);
        if (signature.signature_type == SignatureType.EIP712) {
            address signer = ECDSA.recover(taker_order_hash, signature.signature_bytes);
            if (
                signer != order.benefactor
                    && delegatedSigner[signer][order.benefactor] != DelegatedSignerStatus.ACCEPTED
            ) {
                revert InvalidEIP712Signature();
            }
        } else if (signature.signature_type == SignatureType.EIP1271) {
            if (
                IERC1271(order.benefactor).isValidSignature(taker_order_hash, signature.signature_bytes)
                    != EIP1271_MAGICVALUE
            ) {
                revert InvalidEIP1271Signature();
            }
        } else {
            revert UnknownSignatureType();
        }
        // Monogram 偏离 V2 点：白名单检查由开关控制，默认关闭（V2 为强制检查）
        if (whitelistEnabled) {
            if (!_whitelistedBenefactors.contains(order.benefactor)) {
                revert BenefactorNotWhitelisted();
            }
            if (
                order.benefactor != order.beneficiary
                    && !_approvedBeneficiariesPerBenefactor[order.benefactor].contains(order.beneficiary)
            ) {
                revert BeneficiaryNotApproved();
            }
        }
        if (order.beneficiary == address(0)) revert InvalidAddress();
        if (order.collateral_amount == 0 || order.m_amount == 0) revert InvalidAmount();
        if (block.timestamp > order.expiry) revert SignatureExpired();
    }

    function verifyRoute(Route calldata route) public view override returns (bool) {
        if (route.addresses.length == 0 || route.ratios.length == 0) return false;
        if (route.addresses.length != route.ratios.length) return false;
        uint256 totalRatio = 0;
        for (uint256 i = 0; i < route.ratios.length;) {
            if (!_custodianAddresses.contains(route.addresses[i]) || route.ratios[i] == 0) return false;
            totalRatio += route.ratios[i];
            unchecked {
                ++i;
            }
        }
        return totalRatio == ROUTE_REQUIRED_RATIO;
    }

    function verifyNonce(address sender, uint256 nonce) public view override returns (uint256, uint256, uint256) {
        if (nonce == 0) revert InvalidNonce();
        uint256 invalidatorSlot = nonce >> 8;
        uint256 invalidator = _orderBitmaps[sender][invalidatorSlot];
        uint256 invalidatorBit = 1 << (nonce & 0xFF);
        if (invalidator & invalidatorBit != 0) revert InvalidNonce();
        return (invalidatorSlot, invalidator, invalidatorBit);
    }

    /* --------------- PRIVATE --------------- */
    /// @notice deduplication of taker order
    function _deduplicateOrder(address sender, uint256 nonce) private {
        (uint256 invalidatorSlot, uint256 invalidator, uint256 invalidatorBit) = verifyNonce(sender, nonce);
        _orderBitmaps[sender][invalidatorSlot] = invalidator | invalidatorBit;
    }

    /* --------------- INTERNAL --------------- */

    function _validatePrice(address asset, uint256 collateralAmount, uint256 mAmount) internal view {
        (uint256 price, uint256 timestamp) = priceFeed.getPrice(asset);
        if (block.timestamp - timestamp > 3600) revert StalePrice();
        // 将抵押品数量按其 decimals 归一化到 18 位，再与 18 位精度的 price 相乘
        uint8 assetDecimals = asset == NATIVE_TOKEN ? 18 : IERC20Metadata(asset).decimals();
        uint256 normalizedAmount = collateralAmount;
        if (assetDecimals < 18) {
            normalizedAmount = collateralAmount * (10 ** (18 - assetDecimals));
        } else if (assetDecimals > 18) {
            normalizedAmount = collateralAmount / (10 ** (assetDecimals - 18));
        }
        uint256 collateralUsd = (normalizedAmount * price) / 1e18;
        if (collateralUsd == 0 || mAmount == 0) revert InvalidAmount();
        uint256 deviation = _absDiff(collateralUsd, mAmount) * 10_000 / mAmount;
        if (deviation > maxPriceDeviationBps) revert PriceDeviationExceeded();
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @notice transfer supported asset to beneficiary address
    function _transferToBeneficiary(address beneficiary, address asset, uint256 amount) internal {
        if (asset == NATIVE_TOKEN) {
            if (address(this).balance < amount) revert InvalidAmount();
            (bool success,) = (beneficiary).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            if (!tokenConfig[asset].isActive) revert UnsupportedAsset();
            IERC20(asset).safeTransfer(beneficiary, amount);
        }
    }

    /// @notice transfer supported asset to array of custody addresses per defined ratio
    function _transferCollateral(
        uint256 amount,
        address asset,
        address benefactor,
        address[] calldata addresses,
        uint256[] calldata ratios
    ) internal {
        // cannot mint using unsupported asset or native ETH even if it is supported for redemptions
        if (!tokenConfig[asset].isActive || asset == NATIVE_TOKEN) revert UnsupportedAsset();
        IERC20 token = IERC20(asset);
        uint256 totalTransferred = 0;
        for (uint256 i = 0; i < addresses.length;) {
            uint256 amountToTransfer = (amount * ratios[i]) / ROUTE_REQUIRED_RATIO;
            token.safeTransferFrom(benefactor, addresses[i], amountToTransfer);
            totalTransferred += amountToTransfer;
            unchecked {
                ++i;
            }
        }
        uint256 remainingBalance = amount - totalTransferred;
        if (remainingBalance > 0) {
            token.safeTransferFrom(benefactor, addresses[addresses.length - 1], remainingBalance);
        }
    }

    /// @notice transfer supported asset to array of custody addresses per defined ratio
    function _transferEthCollateral(
        uint256 amount,
        address asset,
        address benefactor,
        address[] calldata addresses,
        uint256[] calldata ratios
    ) internal {
        if (!tokenConfig[asset].isActive || asset == NATIVE_TOKEN || asset != address(WETH)) {
            revert UnsupportedAsset();
        }
        IERC20 token = IERC20(asset);
        token.safeTransferFrom(benefactor, address(this), amount);

        WETH.withdraw(amount);

        uint256 totalTransferred = 0;
        for (uint256 i = 0; i < addresses.length;) {
            uint256 amountToTransfer = (amount * ratios[i]) / ROUTE_REQUIRED_RATIO;
            (bool success,) = addresses[i].call{value: amountToTransfer}("");
            if (!success) revert TransferFailed();
            totalTransferred += amountToTransfer;
            unchecked {
                ++i;
            }
        }
        uint256 remainingBalance = amount - totalTransferred;
        if (remainingBalance > 0) {
            (bool success,) = addresses[addresses.length - 1].call{value: remainingBalance}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @notice Sets the per-asset config; maxMintPerBlock/maxRedeemPerBlock must be non-zero
    function _setTokenConfig(address asset, TokenConfig memory _tokenConfig) internal {
        if (_tokenConfig.maxMintPerBlock == 0 || _tokenConfig.maxRedeemPerBlock == 0) {
            revert InvalidAmount();
        }
        _tokenConfig.isActive = true;
        tokenConfig[asset] = _tokenConfig;
    }

    /// @notice Sets the max mintPerBlock limit for a given asset
    function _setMaxMintPerBlock(uint256 _maxMintPerBlock, address asset) internal {
        uint256 oldMaxMintPerBlock = tokenConfig[asset].maxMintPerBlock;
        tokenConfig[asset].maxMintPerBlock = _maxMintPerBlock;
        emit MaxMintPerBlockChanged(oldMaxMintPerBlock, _maxMintPerBlock, asset);
    }

    /// @notice Sets the max redeemPerBlock limit for a given asset
    function _setMaxRedeemPerBlock(uint256 _maxRedeemPerBlock, address asset) internal {
        uint256 oldMaxRedeemPerBlock = tokenConfig[asset].maxRedeemPerBlock;
        tokenConfig[asset].maxRedeemPerBlock = _maxRedeemPerBlock;
        emit MaxRedeemPerBlockChanged(oldMaxRedeemPerBlock, _maxRedeemPerBlock, asset);
    }

    /// @notice Compute the current domain separator
    /// @return The domain separator for the token
    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN, EIP_712_NAME, EIP712_REVISION, block.chainid, address(this)));
    }

    /* --------------- GETTERS --------------- */

    /// @notice returns whether an address is a custodian
    function isCustodianAddress(address custodian) public view returns (bool) {
        return _custodianAddresses.contains(custodian);
    }

    /// @notice returns whether an address is a whitelisted benefactor
    function isWhitelistedBenefactor(address benefactor) public view returns (bool) {
        return _whitelistedBenefactors.contains(benefactor);
    }

    /// @notice returns whether an address is an approved beneficiary for a given benefactor
    function isApprovedBeneficiary(address benefactor, address beneficiary) public view returns (bool) {
        return _approvedBeneficiariesPerBenefactor[benefactor].contains(beneficiary);
    }
}
