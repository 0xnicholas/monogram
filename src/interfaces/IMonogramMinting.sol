// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.36;

interface IMonogramMinting {

    /* --------------- EVENTS --------------- */

    event Received(address, uint256);

    event Mint(
        address indexed minter,
        address indexed benefactor,
        address indexed beneficiary,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

    event Redeem(
        address indexed redeemer,
        address indexed benefactor,
        address indexed beneficiary,
        address collateral_asset,
        uint256 collateral_amount,
        uint256 m_amount
    );

    event AssetAdded(address indexed asset);

    event AssetRemoved(address indexed asset);

    event CustodianAddressAdded(address indexed custodian);

    event CustodianAddressRemoved(address indexed custodian);

    event CustodyTransfer(address indexed wallet, address indexed asset, uint256 amount);

    event MSet(address indexed M);

    event MaxMintPerBlockChanged(uint256 oldMaxMintPerBlock, uint256 newMaxMinPerBlock);

    event MaxRedeemPerBlockChanged(uint256 oldMaxMintPerBlock, uint256 newMaxMinPerBlock);

    event DelegatedSignerAdded(address indexed signer, address indexed delegator);

    event DelegatedSignerRemoved(address indexed signer, address indexed delegator);

    event DelegatedSignerInitiated(address indexed signer, address indexed delegator);

    event MaxPriceDeviationBpsChanged(uint256 oldMaxPriceDeviationBps, uint256 newMaxPriceDeviationBps);

    /* -------- */
    enum Role {
        Minter,
        Redeemer
    }

    enum OrderType {
        MINT,
        REDEEM
    }

    enum SignatureType {EIP712}

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
        OrderType order_type;
        uint256 expiry;
        uint256 nonce;
        address benefactor;
        address beneficiary;
        address collateral_asset;
        uint256 collateral_amount;
        uint256 m_amount;
    }
    
    /* --------------- ERRORS --------------- */
    error InvalidAddress();
    error InvalidMAddress();
    error InvalidZeroAddress();
    error InvalidAssetAddress();
    error InvalidCustodianAddress();
    error InvalidOrder();
    error InvalidAmount();
    error InvalidRoute();
    error UnsupportedAsset();
    error NoAssetsProvided();
    error InvalidSignature();
    error InvalidNonce();
    error SignatureExpired();
    error TransferFailed();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
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