// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

interface IMonogramMinting {
    /* --------------- EVENTS --------------- */

    event Received(address, uint256);

    event Mint(
        string indexed order_id,
        address indexed benefactor,
        address indexed beneficiary,
        address minter,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

    event Redeem(
        string indexed order_id,
        address indexed benefactor,
        address indexed beneficiary,
        address redeemer,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

    event AssetAdded(address indexed asset);

    event AssetRemoved(address indexed asset);

    event BenefactorAdded(address indexed benefactor);

    event BenefactorRemoved(address indexed benefactor);

    event BeneficiaryAdded(address indexed benefactor, address indexed beneficiary);

    event BeneficiaryRemoved(address indexed benefactor, address indexed beneficiary);

    event CustodianAddressAdded(address indexed custodian);

    event CustodianAddressRemoved(address indexed custodian);

    event CustodyTransfer(address indexed wallet, address indexed asset, uint256 amount);

    event MSet(address indexed M);

    event MaxMintPerBlockChanged(uint256 oldMaxMintPerBlock, uint256 newMaxMintPerBlock, address indexed asset);

    event MaxRedeemPerBlockChanged(uint256 oldMaxRedeemPerBlock, uint256 newMaxRedeemPerBlock, address indexed asset);

    event DelegatedSignerAdded(address indexed signer, address indexed delegator);

    event DelegatedSignerRemoved(address indexed signer, address indexed delegator);

    event DelegatedSignerInitiated(address indexed signer, address indexed delegator);

    event MaxPriceDeviationBpsChanged(uint256 oldMaxPriceDeviationBps, uint256 newMaxPriceDeviationBps);

    /// @notice Monogram 偏离 V2 点：白名单开关（默认关闭），见 GitHub issue #5 决议
    event WhitelistEnabledSet(bool enabled);

    /* -------- */
    enum Role {
        Minter,
        Redeemer
    }

    enum OrderType {
        MINT,
        REDEEM
    }

    enum SignatureType {
        EIP712,
        EIP1271
    }

    enum DelegatedSignerStatus {
        REJECTED,
        PENDING,
        ACCEPTED
    }

    struct Signature {
        SignatureType signature_type;
        bytes signature_bytes;
    }

    struct Route {
        address[] addresses;
        uint256[] ratios;
    }

    struct Order {
        string order_id;
        OrderType order_type;
        uint256 expiry;
        uint256 nonce;
        address benefactor;
        address beneficiary;
        address collateral_asset;
        uint256 collateral_amount;
        uint256 m_amount;
    }

    struct TokenConfig {
        // V2 的 tokenType(STABLE/ASSET) 字段随 stablesDeltaLimit 价格机制一并在 issue #6 决策后再加
        /// @notice tracks if the asset is active
        bool isActive;
        /// @notice max mint per block for this given asset
        uint256 maxMintPerBlock;
        /// @notice max redeem per block for this given asset
        uint256 maxRedeemPerBlock;
    }

    struct BlockTotals {
        /// @notice M minted per block / per asset per block
        uint256 mintedPerBlock;
        /// @notice M redeemed per block / per asset per block
        uint256 redeemedPerBlock;
    }

    struct GlobalConfig {
        /// @notice max M that can be minted across all assets within a single block
        uint256 globalMaxMintPerBlock;
        /// @notice max M that can be redeemed across all assets within a single block
        uint256 globalMaxRedeemPerBlock;
    }

    /* --------------- ERRORS --------------- */
    error InvalidAddress();
    error InvalidMAddress();
    error InvalidZeroAddress();
    error InvalidAssetAddress();
    error InvalidBenefactorAddress();
    error InvalidBeneficiaryAddress();
    error InvalidCustodianAddress();
    error InvalidOrder();
    error InvalidAmount();
    error InvalidRoute();
    error UnsupportedAsset();
    error NoAssetsProvided();
    error BenefactorNotWhitelisted();
    error BeneficiaryNotApproved();
    error InvalidEIP712Signature();
    error InvalidEIP1271Signature();
    error UnknownSignatureType();
    error InvalidNonce();
    error SignatureExpired();
    error TransferFailed();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
    error GlobalMaxMintPerBlockExceeded();
    error GlobalMaxRedeemPerBlockExceeded();
    error DelegationNotInitiated();
    error StalePrice();
    error PriceDeviationExceeded();

    /* --------------- FUNCTIONS --------------- */
    function hashOrder(Order calldata order) external view returns (bytes32);

    function verifyOrder(Order calldata order, Signature calldata signature) external view returns (bytes32);

    function verifyRoute(Route calldata route) external view returns (bool);

    function verifyNonce(address sender, uint256 nonce) external view returns (uint256, uint256, uint256);

    function mint(Order calldata order, Route calldata route, Signature calldata signature) external;

    function mintWETH(Order calldata order, Route calldata route, Signature calldata signature) external;

    function redeem(Order calldata order, Signature calldata signature) external;
}
