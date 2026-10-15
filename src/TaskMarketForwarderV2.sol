// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IPGTRForwarder } from "./interfaces/IPGTRForwarder.sol";
import { IPGTRPaymentForwarder } from "./interfaces/IPGTRPaymentForwarder.sol";

/**
 * @title TaskMarketForwarderV2
 * @notice PGTR forwarder for TaskMarket (ERC-8194) that also exposes the payment amount
 *         of the current relayed call through pgtrPaymentAmount().
 *
 *         Relay flow matches TaskMarketForwarder: the authorised relayer calls relay(), the
 *         forwarder pulls paymentAmount USDC from the relayer into TaskMarket, sets the call
 *         context, calls TaskMarket and clears the context. The context now holds both the
 *         actor (pgtrSender) and the amount transferred for this call (pgtrPaymentAmount), so
 *         TaskMarket can refuse to record a stake it did not receive.
 *
 *         The forwarder is not upgradeable. It is deployed beside the previous forwarder and
 *         both stay trusted by TaskMarket between addForwarder and removeForwarder (rev025).
 */
contract TaskMarketForwarderV2 is IPGTRPaymentForwarder, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable taskMarket;
    address public immutable authorizedRelayer;

    address private _pgtrSenderStorage;
    uint256 private _pgtrPaymentAmountStorage;

    mapping(bytes32 => bool) public consumedReceipts;

    error ReceiptAlreadyConsumed();
    error ReceiptExpired();
    error ReceiptNotYetValid();
    error RelayFailed();
    error UnauthorizedRelayer();
    error InvalidAddress();
    error NoActiveForwardedCall();
    error CalldataTooShort();

    constructor(address _usdc, address _taskMarket, address _authorizedRelayer) {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_taskMarket == address(0)) revert InvalidAddress();
        if (_authorizedRelayer == address(0)) revert InvalidAddress();
        usdc = IERC20(_usdc);
        taskMarket = _taskMarket;
        authorizedRelayer = _authorizedRelayer;
    }

    // -------------------------------------------------------------------------
    // IPGTRForwarder
    // -------------------------------------------------------------------------

    /// @inheritdoc IPGTRForwarder
    function isPGTRForwarder() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IPGTRForwarder
    function pgtrSender() external view override returns (address) {
        if (_pgtrSenderStorage == address(0)) revert NoActiveForwardedCall();
        return _pgtrSenderStorage;
    }

    /// @inheritdoc IPGTRPaymentForwarder
    function pgtrPaymentAmount() external view override returns (uint256) {
        if (_pgtrSenderStorage == address(0)) revert NoActiveForwardedCall();
        return _pgtrPaymentAmountStorage;
    }

    /// @inheritdoc IPGTRForwarder
    /// @dev This forwarder only trusts itself. External contracts that are PGTR
    ///      destinations call this to verify that a given msg.sender is a legitimate
    ///      PGTR forwarder before reading pgtrSender(). Returning true for address(this)
    ///      means TaskMarket (or any other destination) can safely call
    ///      IPGTRForwarder(msg.sender).pgtrSender() when msg.sender == address(this).
    function isTrustedForwarder(address addr) external view override returns (bool) {
        return addr == address(this);
    }

    // -------------------------------------------------------------------------
    // ERC-165
    // -------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPGTRPaymentForwarder).interfaceId || interfaceId == type(IPGTRForwarder).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // -------------------------------------------------------------------------
    // Relay
    // -------------------------------------------------------------------------

    /**
     * @notice Relay a call to TaskMarket with payment-gated authorization.
     * @param pgtrSenderAddr  The authenticated actor on whose behalf the call is made.
     *                        TaskMarket reads this via pgtrSender() to attribute the action.
     * @param paymentAmount   USDC amount to pull from msg.sender into TaskMarket escrow.
     *                        Pass 0 for operations with no payment (e.g. submitWork).
     * @param validBefore     Unix timestamp after which this receipt is invalid.
     * @param receiptNonce    Unique bytes32 per (pgtrSender, operation) to prevent replay.
     * @param data            ABI-encoded calldata for the TaskMarket function.
     */
    function relay(
        address pgtrSenderAddr,
        uint256 paymentAmount,
        uint256 validBefore,
        bytes32 receiptNonce,
        bytes calldata data
    ) external nonReentrant {
        if (msg.sender != authorizedRelayer) revert UnauthorizedRelayer();
        if (block.timestamp > validBefore) revert ReceiptExpired();
        if (data.length < 4) revert CalldataTooShort();

        bytes4 selector = bytes4(data[:4]);
        bytes32 receiptHash = keccak256(
            abi.encode(block.chainid, pgtrSenderAddr, paymentAmount, receiptNonce, validBefore, taskMarket, selector)
        );
        if (consumedReceipts[receiptHash]) revert ReceiptAlreadyConsumed();
        consumedReceipts[receiptHash] = true;

        if (paymentAmount > 0) {
            usdc.safeTransferFrom(msg.sender, taskMarket, paymentAmount);
        }

        _pgtrSenderStorage = pgtrSenderAddr;
        _pgtrPaymentAmountStorage = paymentAmount;
        // Dynamic calldata delegation — no typed interface possible for arbitrary TaskMarket calls.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = taskMarket.call(data);
        // _pgtrSenderStorage must be cleared after the call by design (it is the call context).
        // Clearing before the call would break pgtrSender() reads inside TaskMarket.
        // Protected against re-entry by nonReentrant on relay().
        // slither-disable-next-line reentrancy-benign,reentrancy-no-eth
        _pgtrSenderStorage = address(0);
        // slither-disable-next-line reentrancy-benign,reentrancy-no-eth
        _pgtrPaymentAmountStorage = 0;

        if (!success) {
            if (result.length == 0) revert RelayFailed();
            // Bubble up the revert reason verbatim — no Solidity equivalent for this pattern.
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        emit PaymentGatedCall(pgtrSenderAddr, taskMarket, selector, paymentAmount);
    }
}
