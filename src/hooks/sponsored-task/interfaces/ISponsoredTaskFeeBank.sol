// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ISponsoredTaskFeeBank
/// @notice Prefunded, idempotent creation-fee rail for sponsored tasks.
interface ISponsoredTaskFeeBank {
    struct ChargeReceipt {
        bytes32 key;
        address manager;
        address charger;
        address recipient;
        uint256 amount;
        uint256 chargedAt;
    }

    error ChargerRequired();
    error FeeRecipientRequired();
    error FeeRecipientIsBank();
    error FeeTokenRequired();
    error InsufficientCredit(address manager, uint256 available, uint256 required);
    error InvalidAmount();
    error InvalidManager();
    error InvalidRecipient();
    error InvalidUniqueKey();
    error TokenTransferAmountMismatch(uint256 expected, uint256 observed);
    error TokenRecipientAmountMismatch(uint256 expected, uint256 observed);
    error UnauthorizedCharger(address caller);
    error UniqueKeyConflict(bytes32 key, address chargedManager, address requestedManager);

    event ChargerAuthorizationUpdated(address indexed charger, bool authorized);
    event CreditDeposited(address indexed payer, address indexed manager, uint256 amount, uint256 managerCreditAfter);
    event CreditWithdrawn(
        address indexed manager, address indexed recipient, uint256 amount, uint256 managerCreditAfter
    );
    event FeeCharged(
        bytes32 indexed key, address indexed manager, address indexed charger, address recipient, uint256 amount
    );
    event FeeChargeReplayed(bytes32 indexed key, address indexed manager, address indexed caller);
    event FeeConfigUpdated(uint256 amount, address indexed recipient);

    function feeToken() external view returns (IERC20);

    function feeAmount() external view returns (uint256);

    function feeRecipient() external view returns (address);

    function creditOf(address manager) external view returns (uint256);

    function totalCreditLiability() external view returns (uint256);

    function authorizedChargers(address charger) external view returns (bool);

    function setFeeConfig(uint256 newAmount, address newRecipient) external;

    function setCharger(address charger, bool authorized) external;

    function deposit(uint256 amount) external returns (uint256 managerCreditAfter);

    function depositFor(address manager, uint256 amount) external returns (uint256 managerCreditAfter);

    function withdrawCredit(uint256 amount, address recipient) external returns (uint256 managerCreditAfter);

    /// @notice Charges the current fee once for `uniqueKey` and returns its immutable receipt.
    /// @dev An exact replay for the same manager is idempotent. A replay naming another manager reverts.
    function charge(address manager, bytes32 uniqueKey) external returns (ChargeReceipt memory receipt);

    function isCharged(bytes32 uniqueKey) external view returns (bool);

    function getReceipt(bytes32 uniqueKey) external view returns (ChargeReceipt memory receipt);
}
