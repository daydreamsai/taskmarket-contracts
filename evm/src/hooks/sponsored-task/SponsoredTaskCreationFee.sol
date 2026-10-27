// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC3009Receive } from "./interfaces/IERC3009Receive.sol";

/// @title SponsoredTaskCreationFee
/// @notice The one-time vault creation fee a Sponsored Task factory takes from the vault creator.
/// @dev The fee exists to make mass-creating junk vaults cost something. It is taken inside the
///      vault-creation call, moves straight from the creator to the fee recipient, and is never
///      refunded. Creating tasks from a vault charges nothing.
///
///      The admin may change the amount and recipient for future vault creations only, and never
///      above the immutable `feeCeiling` fixed at deployment. The admin must be a deployed contract
///      (a Safe or timelock), through every ownership rotation, and ownership cannot be renounced.
abstract contract SponsoredTaskCreationFee is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Deployment parameters for the creation fee.
    struct CreationFeeConfig {
        address admin;
        IERC20 token;
        uint256 amount;
        address recipient;
        uint256 ceiling;
    }

    /// @notice The token the fee is paid in (USDC on every supported chain).
    IERC20 public immutable feeToken;
    /// @notice The highest fee the admin can ever set.
    uint256 public immutable feeCeiling;
    /// @notice The fee the next vault creation pays, in `feeToken` base units.
    uint256 public creationFee;
    /// @notice Where the next vault creation's fee is paid.
    address public creationFeeRecipient;

    error FeeAdminMustBeContract(address admin);
    error FeeTokenRequired();
    error FeeCeilingExceeded(uint256 requested, uint256 ceiling);
    error FeeRecipientRequired();
    error FeeRecipientInvalid(address recipient);
    error FeeTransferAmountMismatch(uint256 expected, uint256 received);
    error OwnershipRenunciationDisabled();

    event CreationFeeUpdated(uint256 amount, address indexed recipient);
    event CreationFeePaid(address indexed vault, address indexed payer, address indexed recipient, uint256 amount);

    constructor(CreationFeeConfig memory config) Ownable(config.admin) {
        if (config.admin.code.length == 0) revert FeeAdminMustBeContract(config.admin);
        if (address(config.token) == address(0) || address(config.token).code.length == 0) {
            revert FeeTokenRequired();
        }
        feeToken = config.token;
        feeCeiling = config.ceiling;
        _setCreationFee(config.amount, config.recipient);
    }

    /// @notice Sets the fee and recipient for future vault creations, within the ceiling.
    /// @dev A zero fee may use a zero recipient; a non-zero fee needs a recipient other than this
    ///      factory.
    function setCreationFee(uint256 amount, address recipient) external onlyOwner {
        _setCreationFee(amount, recipient);
    }

    /// @dev Keeps a Safe or timelock admin through two-step rotation. Zero still cancels a
    ///      pending transfer, as in Ownable2Step.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner != address(0) && newOwner.code.length == 0) revert FeeAdminMustBeContract(newOwner);
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    /// @dev Pulls the fee from `payer`, which must have approved this contract, straight to the
    ///      recipient.
    function _collectCreationFee(address vault, address payer) internal {
        uint256 amount = creationFee;
        if (amount == 0) return;
        address recipient = creationFeeRecipient;
        uint256 before = feeToken.balanceOf(recipient);
        feeToken.safeTransferFrom(payer, recipient, amount);
        _requireReceived(recipient, before, amount);
        emit CreationFeePaid(vault, payer, recipient, amount);
    }

    /// @dev Takes the fee with `payer`'s EIP-3009 authorization to this contract, then forwards
    ///      it to the recipient in the same call, so nothing stays here.
    function _collectCreationFeeWithAuthorization(
        address vault,
        address payer,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) internal {
        uint256 amount = creationFee;
        if (amount == 0) return;
        address recipient = creationFeeRecipient;
        uint256 heldBefore = feeToken.balanceOf(address(this));
        IERC3009Receive(address(feeToken))
            .receiveWithAuthorization(payer, address(this), amount, validAfter, validBefore, nonce, signature);
        _requireReceived(address(this), heldBefore, amount);
        uint256 before = feeToken.balanceOf(recipient);
        feeToken.safeTransfer(recipient, amount);
        _requireReceived(recipient, before, amount);
        emit CreationFeePaid(vault, payer, recipient, amount);
    }

    function _setCreationFee(uint256 amount, address recipient) private {
        if (amount > feeCeiling) revert FeeCeilingExceeded(amount, feeCeiling);
        if (amount != 0 && recipient == address(0)) revert FeeRecipientRequired();
        if (recipient == address(this)) revert FeeRecipientInvalid(recipient);
        creationFee = amount;
        creationFeeRecipient = recipient;
        emit CreationFeeUpdated(amount, recipient);
    }

    function _requireReceived(address account, uint256 before, uint256 amount) private view {
        uint256 afterBalance = feeToken.balanceOf(account);
        uint256 received = afterBalance >= before ? afterBalance - before : 0;
        if (received != amount) revert FeeTransferAmountMismatch(amount, received);
    }
}
