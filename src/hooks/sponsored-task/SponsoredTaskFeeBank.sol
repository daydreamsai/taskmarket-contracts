// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ISponsoredTaskFeeBank } from "./interfaces/ISponsoredTaskFeeBank.sol";

/// @title SponsoredTaskFeeBank
/// @notice Holds manager-funded USDC credit and charges one creation fee per unique task or intent.
/// @dev The hook should call `charge` inside the task-creation transaction. Any later revert in that
///      transaction also rolls the charge back. Successful retries with the same key are idempotent.
contract SponsoredTaskFeeBank is ISponsoredTaskFeeBank, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable override feeToken;

    uint256 public override feeAmount;
    address public override feeRecipient;
    uint256 public override totalCreditLiability;

    mapping(address manager => uint256 credit) public override creditOf;
    mapping(address charger => bool authorized) public override authorizedChargers;

    mapping(bytes32 uniqueKey => ChargeReceipt receipt) private _receipts;
    mapping(bytes32 uniqueKey => bool charged) private _charged;

    modifier onlyCharger() {
        if (!authorizedChargers[msg.sender]) revert UnauthorizedCharger(msg.sender);
        _;
    }

    constructor(address initialOwner, IERC20 feeToken_, uint256 initialFeeAmount, address initialFeeRecipient)
        Ownable(initialOwner)
    {
        if (address(feeToken_) == address(0)) revert FeeTokenRequired();
        feeToken = feeToken_;
        _setFeeConfig(initialFeeAmount, initialFeeRecipient);
    }

    /// @notice Changes the amount and recipient snapshotted by future charges only.
    /// @dev A zero fee may use a zero recipient. A non-zero fee must leave the bank.
    function setFeeConfig(uint256 newAmount, address newRecipient) external override onlyOwner {
        _setFeeConfig(newAmount, newRecipient);
    }

    function setCharger(address charger, bool authorized) external override onlyOwner {
        if (charger == address(0)) revert ChargerRequired();
        authorizedChargers[charger] = authorized;
        emit ChargerAuthorizationUpdated(charger, authorized);
    }

    /// @notice Adds fee credit for the caller.
    function deposit(uint256 amount) external override nonReentrant returns (uint256 managerCreditAfter) {
        return _deposit(msg.sender, msg.sender, amount);
    }

    /// @notice Adds fee credit for `manager`; the caller supplies the tokens.
    function depositFor(address manager, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 managerCreditAfter)
    {
        return _deposit(msg.sender, manager, amount);
    }

    /// @notice Withdraws the caller's currently uncharged credit.
    function withdrawCredit(uint256 amount, address recipient)
        external
        override
        nonReentrant
        returns (uint256 managerCreditAfter)
    {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();

        uint256 available = creditOf[msg.sender];
        if (available < amount) revert InsufficientCredit(msg.sender, available, amount);

        unchecked {
            managerCreditAfter = available - amount;
            creditOf[msg.sender] = managerCreditAfter;
            totalCreditLiability -= amount;
        }

        _transferExact(recipient, amount);
        emit CreditWithdrawn(msg.sender, recipient, amount, managerCreditAfter);
    }

    /// @inheritdoc ISponsoredTaskFeeBank
    function charge(address manager, bytes32 uniqueKey)
        external
        override
        onlyCharger
        nonReentrant
        returns (ChargeReceipt memory receipt)
    {
        if (manager == address(0)) revert InvalidManager();
        if (uniqueKey == bytes32(0)) revert InvalidUniqueKey();

        if (_charged[uniqueKey]) {
            receipt = _receipts[uniqueKey];
            if (receipt.manager != manager) revert UniqueKeyConflict(uniqueKey, receipt.manager, manager);
            emit FeeChargeReplayed(uniqueKey, manager, msg.sender);
            return receipt;
        }

        uint256 amount = feeAmount;
        address recipient = feeRecipient;
        uint256 available = creditOf[manager];
        if (available < amount) revert InsufficientCredit(manager, available, amount);

        unchecked {
            creditOf[manager] = available - amount;
            totalCreditLiability -= amount;
        }

        receipt = ChargeReceipt({
            key: uniqueKey,
            manager: manager,
            charger: msg.sender,
            recipient: recipient,
            amount: amount,
            chargedAt: block.timestamp
        });
        _receipts[uniqueKey] = receipt;
        _charged[uniqueKey] = true;

        if (amount != 0) _transferExact(recipient, amount);
        emit FeeCharged(uniqueKey, manager, msg.sender, recipient, amount);
    }

    function isCharged(bytes32 uniqueKey) external view override returns (bool) {
        return _charged[uniqueKey];
    }

    function getReceipt(bytes32 uniqueKey) external view override returns (ChargeReceipt memory receipt) {
        return _receipts[uniqueKey];
    }

    function _deposit(address payer, address manager, uint256 amount) private returns (uint256 managerCreditAfter) {
        if (manager == address(0)) revert InvalidManager();
        if (amount == 0) revert InvalidAmount();

        uint256 balanceBefore = feeToken.balanceOf(address(this));
        feeToken.safeTransferFrom(payer, address(this), amount);
        uint256 balanceAfter = feeToken.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert TokenTransferAmountMismatch(amount, received);

        managerCreditAfter = creditOf[manager] + amount;
        creditOf[manager] = managerCreditAfter;
        totalCreditLiability += amount;
        emit CreditDeposited(payer, manager, amount, managerCreditAfter);
    }

    function _setFeeConfig(uint256 newAmount, address newRecipient) private {
        if (newAmount != 0 && newRecipient == address(0)) revert FeeRecipientRequired();
        if (newAmount != 0 && newRecipient == address(this)) revert FeeRecipientIsBank();
        feeAmount = newAmount;
        feeRecipient = newRecipient;
        emit FeeConfigUpdated(newAmount, newRecipient);
    }

    function _transferExact(address recipient, uint256 amount) private {
        uint256 bankBalanceBefore = feeToken.balanceOf(address(this));
        uint256 recipientBalanceBefore = feeToken.balanceOf(recipient);

        feeToken.safeTransfer(recipient, amount);

        uint256 bankBalanceAfter = feeToken.balanceOf(address(this));
        uint256 recipientBalanceAfter = feeToken.balanceOf(recipient);
        uint256 sent = bankBalanceBefore >= bankBalanceAfter ? bankBalanceBefore - bankBalanceAfter : 0;
        uint256 received =
            recipientBalanceAfter >= recipientBalanceBefore ? recipientBalanceAfter - recipientBalanceBefore : 0;
        if (sent != amount) revert TokenTransferAmountMismatch(amount, sent);
        if (received != amount) revert TokenRecipientAmountMismatch(amount, received);
    }
}
