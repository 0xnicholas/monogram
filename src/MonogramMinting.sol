// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./SingleAdminAccessControl.sol";
import "./interfaces/IM.sol";
import "./interfaces/IMonogramMinting.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/IMonogramPriceFeed.sol";

contract MonogramMinting is IMonogramMinting, SingleAdminAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;


    /* --------------- CONSTANTS --------------- */

    bytes32 private constant EIP712_DOMAIN = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant ROUTE_TYPE = keccak256("Route(address[] addresses,uint256[] ratios)");

    bytes32 private constant ORDER_TYPE = keccak256(
        "Order(uint8 order_type,uint256 expiry,uint256 nonce,address benefactor,address beneficiary,address collateral_asset,uint256 collateral_amount,uint256 m_amount)"
    );

    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    bytes32 private constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    bytes32 private constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");

    bytes32 private constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");

    address private constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes32 private constant EIP_712_NAME = keccak256("MonogramMinting");
    
    bytes32 private constant EIP712_REVISION = keccak256("1");
    
    uint256 private constant ROUTE_REQUIRED_RATIO = 10_000;

    IWETH9 private immutable WETH;

    IMonogramPriceFeed public immutable priceFeed;

    uint256 public maxPriceDeviationBps = 500;


    /* --------------- STATE VARIABLES --------------- */

    IM public immutable m;

    EnumerableSet.AddressSet internal _supportedAssets;

    EnumerableSet.AddressSet internal _custodianAddresses;

    uint256 private immutable _chainId;

    bytes32 private immutable _domainSeparator;

    mapping(address => mapping(uint256 => uint256)) private _orderBitmaps;

    mapping(uint256 => uint256) public mintedPerBlock;
    mapping(uint256 => uint256) public redeemedPerBlock;

    mapping(address => mapping(address => DelegatedSignerStatus)) public delegatedSigner;

    uint256 public maxMintPerBlock;
    uint256 public maxRedeemPerBlock;

    /* --------------- MODIFIERS --------------- */
    /// @notice ensure that the already minted USDe in the actual block plus the amount to be minted is below the maxMintPerBlock var
    /// @param mintAmount The USDe amount to be minted
    modifier belowMaxMintPerBlock(uint256 mintAmount) {
        if (mintedPerBlock[block.number] + mintAmount > maxMintPerBlock) revert MaxMintPerBlockExceeded();
        _;
    }

    /// @notice ensure that the already redeemed USDe in the actual block plus the amount to be redeemed is below the maxRedeemPerBlock var
    /// @param redeemAmount The USDe amount to be redeemed
    modifier belowMaxRedeemPerBlock(uint256 redeemAmount) {
        if (redeemedPerBlock[block.number] + redeemAmount > maxRedeemPerBlock) revert MaxRedeemPerBlockExceeded();
        _;
    }

    /* --------------- CONSTRUCTOR --------------- */
    constructor(
        IM _m, 
        IWETH9 _weth,
        IMonogramPriceFeed _priceFeed,
        address[] memory _assets,
        address[] memory _custodians,
        address _admin,
        uint256 _maxMintPerBlock,
        uint256 _maxRedeemPerBlock
    ) {
        if (address(_m) == address(0)) revert InvalidMAddress();
        if (address(_m) == address(0)) revert InvalidZeroAddress();
        if (address(_priceFeed) == address(0)) revert InvalidZeroAddress();
        if (_assets.length == 0) revert NoAssetsProvided();
        if (_admin == address(0)) revert InvalidZeroAddress(); 

        m = _m;
        WETH = _weth;
        priceFeed = _priceFeed;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        for (uint256 i = 0; i < _assets.length;) {
            addSupportedAsset(_assets[i]);
            unchecked {
                ++i;
            }
        }

        for (uint256 j = 0; j < _custodians.length;) {
            addCustodianAddress(_custodians[j]);
            unchecked {
                ++j;
            }
        }

        _setMaxMintPerBlock(_maxMintPerBlock);
        _setMaxRedeemPerBlock(_maxRedeemPerBlock);

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
        belowMaxMintPerBlock(order.m_amount)
    {
        if (order.order_type != OrderType.MINT) revert InvalidOrder();
        verifyOrder(order, signature);
        if (!verifyRoute(route)) revert InvalidRoute();
        _deduplicateOrder(order.benefactor, order.nonce);
        _validatePrice(order.collateral_asset, order.collateral_amount, order.m_amount);

        mintedPerBlock[block.number] += order.m_amount;
        _transferCollateral(
            order.collateral_amount, order.collateral_asset, order.benefactor, route.addresses, route.ratios
        );
        m.mint(order.beneficiary, order.m_amount);
        emit Mint(
            msg.sender,
            order.benefactor,
            order.beneficiary,
            order.collateral_asset,
            order.collateral_amount,
            order.m_amount
        );
    }

    function mintWETH(Order calldata order, Route calldata route, Signature calldata signature) 
        external
        nonReentrant
        onlyRole(MINTER_ROLE)
        belowMaxMintPerBlock(order.m_amount)
    {
        if (order.order_type != OrderType.MINT) revert InvalidOrder();
        verifyOrder(order, signature);
        if (!verifyRoute(route)) revert InvalidRoute();
        _deduplicateOrder(order.benefactor, order.nonce);
        _validatePrice(order.collateral_asset, order.collateral_amount, order.m_amount);

        mintedPerBlock[block.number] += order.m_amount;
        _transferEthCollateral(
            order.collateral_amount, order.collateral_asset, order.benefactor, route.addresses, route.ratios
        );
        m.mint(order.beneficiary, order.m_amount);
        emit Mint(
            msg.sender,
            order.benefactor,
            order.beneficiary,
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
        belowMaxRedeemPerBlock(order.m_amount)
    {
        if (order.order_type != OrderType.REDEEM) revert InvalidOrder();
        verifyOrder(order, signature);
        _deduplicateOrder(order.benefactor, order.nonce);
        _validatePrice(order.collateral_asset, order.collateral_amount, order.m_amount);

        redeemedPerBlock[block.number] += order.m_amount;
        m.burnFrom(order.benefactor, order.m_amount);
        _transferToBeneficiary(order.beneficiary, order.collateral_asset, order.collateral_amount);
        emit Redeem(
            msg.sender,
            order.benefactor,
            order.beneficiary,
            order.collateral_asset,
            order.collateral_amount,
            order.m_amount
        );
    }

    function setMaxMintPerBlock(uint256 _maxMintPerBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxMintPerBlock(_maxMintPerBlock);
    }

    function setMaxRedeemPerBlock(uint256 _maxRedeemPerBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxRedeemPerBlock(_maxRedeemPerBlock);
    }

    function setMaxPriceDeviationBps(uint256 _maxPriceDeviationBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldValue = maxPriceDeviationBps;
        maxPriceDeviationBps = _maxPriceDeviationBps;
        emit MaxPriceDeviationBpsChanged(oldValue, maxPriceDeviationBps);
    }

    function disableMintRedeem() external onlyRole(GATEKEEPER_ROLE) {
        _setMaxMintPerBlock(0);
        _setMaxRedeemPerBlock(0);
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
        if (!_supportedAssets.remove(asset)) revert InvalidAssetAddress();
        emit AssetRemoved(asset);
    }

    /// @notice Checks if an asset is supported.
    function isSupportedAsset(address asset) external view returns (bool) {
        return _supportedAssets.contains(asset);
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

    /* --------------- PUBLIC --------------- */

    function addSupportedAsset(address asset) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert InvalidZeroAddress();
        if (!_supportedAssets.add(asset)) revert InvalidAssetAddress();
        emit AssetAdded(asset);
    }

    function addCustodianAddress(address custodian) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (custodian == address(0)) revert InvalidZeroAddress();
        if (!_custodianAddresses.add(custodian)) revert InvalidCustodianAddress();
        emit CustodianAddressAdded(custodian);
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
        if (order.expiry < block.timestamp) revert SignatureExpired();
        address signer = ECDSA.recover(taker_order_hash, signature.signature_bytes);
        if (signer != order.benefactor && delegatedSigner[signer][order.benefactor] != DelegatedSignerStatus.ACCEPTED) {
            revert InvalidSignature();
        }
    }

    function verifyRoute(Route calldata route) public view override returns (bool) {
        if (route.addresses.length == 0 || route.ratios.length == 0) return false;
        if (route.addresses.length != route.ratios.length) return false;
        uint256 totalRatio = 0;
        for (uint256 i = 0; i < route.ratios.length;) {
            totalRatio += route.ratios[i];
            if (!_custodianAddresses.contains(route.addresses[i])) return false;
            unchecked {
                ++i;
            }
        }
        return totalRatio == ROUTE_REQUIRED_RATIO;
    }

    function verifyNonce(address sender, uint256 nonce) public view override returns (uint256, uint256, uint256) {
        uint256 invalidatorSlot = nonce >> 8;
        uint256 invalidator = _orderBitmaps[sender][invalidatorSlot];
        uint256 invalidatorBit = 1 << (nonce & 0xFF);
        return (invalidatorSlot, invalidator, invalidatorBit);
    }

    /* --------------- PRIVATE --------------- */
    /// @notice deduplication of taker order
    function _deduplicateOrder(address sender, uint256 nonce) private {
        (uint256 invalidatorSlot, uint256 invalidator, uint256 invalidatorBit) = verifyNonce(sender, nonce);
        if (invalidator & invalidatorBit != 0) revert InvalidNonce();
        _orderBitmaps[sender][invalidatorSlot] = invalidator | invalidatorBit;
    }

    /* --------------- INTERNAL --------------- */

    function _validatePrice(address asset, uint256 collateralAmount, uint256 mAmount) internal view {
        (uint256 price, uint256 timestamp) = priceFeed.getPrice(asset);
        if (block.timestamp - timestamp > 3600) revert StalePrice();
        uint256 collateralUsd = (collateralAmount * price) / 1e18;
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
        if (!_supportedAssets.contains(asset)) revert UnsupportedAsset();
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
        if (!_supportedAssets.contains(asset) || asset == NATIVE_TOKEN) revert UnsupportedAsset();
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
        if (!_supportedAssets.contains(asset) || asset == NATIVE_TOKEN || asset != address(WETH)) revert UnsupportedAsset();
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

    /// @notice Sets the max mintPerBlock limit
    function _setMaxMintPerBlock(uint256 _maxMintPerBlock) internal {
        uint256 oldMaxMintPerBlock = maxMintPerBlock;
        maxMintPerBlock = _maxMintPerBlock;
        emit MaxMintPerBlockChanged(oldMaxMintPerBlock, maxMintPerBlock);
    }

    /// @notice Sets the max redeemPerBlock limit
    function _setMaxRedeemPerBlock(uint256 _maxRedeemPerBlock) internal {
        uint256 oldMaxRedeemPerBlock = maxRedeemPerBlock;
        maxRedeemPerBlock = _maxRedeemPerBlock;
        emit MaxRedeemPerBlockChanged(oldMaxRedeemPerBlock, maxRedeemPerBlock);
    }

    /// @notice Compute the current domain separator
    /// @return The domain separator for the token
    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN, EIP_712_NAME, EIP712_REVISION, block.chainid, address(this)));
    }
}