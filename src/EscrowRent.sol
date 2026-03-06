// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

// ============================================================
//  ESCROW RENTAL AGREEMENT
//  A simple escrow contract for rental agreements with:
//  - Landlord, tenant, and arbiter roles
//  - Funding, activation, completion, cancellation, and dispute flows
//  - ReentrancyGuard on all state-changing functions
//  - ETH reception only via fund() with exact amount required
// ============================================================

contract EscrowRent is ReentrancyGuard {

    // ── Status enum ─────────────────────────────────────────
    enum Status {
        Created,   // Contract deployed, awaiting full funding
        Funded,    // Fully funded by tenant in one transaction
        Active,    // Landlord activated — rental period running
        Completed, // Rental completed — funds distributed
        Cancelled, // Cancelled before activation — funds refunded
        Disputed   // Dispute raised — awaiting arbiter resolution
    }

    // ── State ───────────────────────────────────────────────
    Status  public status;
    uint256 public fundedAmount;

    address public immutable landlord;
    address public immutable tenant;
    address public arbiter;

    uint256 public immutable RENT_AMOUNT;
    uint256 public immutable DEPOSIT_AMOUNT;
    uint256 public immutable START_DATE;
    uint256 public immutable END_DATE;

    // ── Constants ───────────────────────────────────────────

    /// @dev Grace period after START_DATE for landlord to activate.
    ///      After this, tenant can cancel and reclaim funds.
    uint256 public constant ACTIVATION_GRACE = 3 days;

    /// @dev Window before END_DATE during which disputes may be raised.
    uint256 public constant DISPUTE_WINDOW = 3 days;

    /// @dev Delay between resolveDispute() and
    ///      when funds become withdrawable. Gives the losing party
    ///      time to react off-chain before funds move.
    uint256 public constant RESOLUTION_TIMELOCK = 48 hours;

    /// @dev If arbiter has not resolved within this
    ///      window after dispute was raised, parties may replace arbiter.
    uint256 public constant ARBITER_TIMEOUT = 7 days;

    // ── Dispute tracking ─────────────────────────────────────

    /// @dev Timestamp after which resolved funds
    ///      become withdrawable. Zero means no timelock active.
    uint256 public withdrawalUnlockTime;

    /// @dev Timestamp when the dispute was raised.
    ///      Used to enforce ARBITER_TIMEOUT.
    uint256 public disputeRaisedAt;

    /// @dev Pending new arbiter address — both parties
    ///      must approve before the replacement takes effect.
    address public pendingArbiter;
    bool    public landlordApprovedNewArbiter;
    bool    public tenantApprovedNewArbiter;

    // ── Withdrawable balances ─────────────────────────────────
    mapping(address => uint256) public withdrawable;

    // ── Events ───────────────────────────────────────────────
    event Created(address indexed landlord, uint256 timestamp);
    event Funded(address indexed tenant, uint256 amount);
    event Active(address indexed landlord, address indexed tenant, uint256 timestamp);
    event Completed(address indexed tenant, address indexed landlord, uint256 rentAmount);
    event Cancelled(address indexed tenant, address indexed landlord);
    event Withdrawn(address indexed user, uint256 amount);
    event DisputeRaised(address indexed raiser, uint256 timestamp);
    event DisputeResolved(address indexed arbiter, uint256 landlordAmount, uint256 tenantAmount, uint256 unlockTime);
    event ArbiterReplaceProposed(address indexed proposer, address indexed newArbiter);
    event ArbiterReplaced(address indexed oldArbiter, address indexed newArbiter);

    // ── Modifiers ────────────────────────────────────────────

    modifier onlyLandlord() {
        _onlyLandlord();
        _;
    }
        function _onlyLandlord() internal {
        require(msg.sender == landlord, "Not landlord");
    }

    modifier onlyTenant() {
        _onlyTenant();
        _;
    }

    function _onlyTenant() internal {
        require(msg.sender == tenant, "Not tenant");
    }

    modifier onlyParty() {
        _onlyParty();
        _;
    }
    function _onlyParty() internal {
        require(msg.sender == landlord || msg.sender == tenant, "Not a party");
    }

    modifier onlyArbiter() {
        _onlyArbiter();
        _;
    }
    function _onlyArbiter() internal {
        require(msg.sender == arbiter, "Not arbiter");
    }

    modifier inStatus(Status _status) {
        _inStatus(_status);
        _;
    }
    function _inStatus(Status _status) internal view {
        require(status == _status, "Invalid status for this action");
    }

    modifier inWithdrawableState() {
        _inWithdrawableState();
        _;
    }
    function _inWithdrawableState() internal view {
        require(
            status == Status.Completed || status == Status.Cancelled,
            "Withdraw not allowed"
        );
    }

    // ── Constructor ──────────────────────────────────────────

    /// @param _tenant         Address of the tenant
    /// @param _arbiter        Address of the arbiter (must be approved by both parties off-chain)
    /// @param _rentAmount     Rent amount in wei
    /// @param _depositAmount  Deposit amount in wei
    /// @param _startDate      Unix timestamp for rental start
    /// @param _endDate        Unix timestamp for rental end
    constructor(
        address _tenant,
        address _arbiter,
        uint256 _rentAmount,
        uint256 _depositAmount,
        uint256 _startDate,
        uint256 _endDate
    ) {
        require(_tenant  != address(0), "Invalid tenant");
        require(_arbiter != address(0), "Invalid arbiter");
        require(_arbiter != msg.sender, "Arbiter cannot be landlord");
        require(_arbiter != _tenant,    "Arbiter cannot be tenant");
        require(_rentAmount   > 0, "Rent must be > 0");
        require(_depositAmount > 0, "Deposit must be > 0");
        require(_startDate >= block.timestamp, "Start date must be in future");
        require(_endDate   >  _startDate,      "End date must be after start");

        // Rental duration must exceed the dispute window.
        // Prevents landlord from activating and immediately raising a dispute
        // in contracts where END_DATE - START_DATE <= DISPUTE_WINDOW.
        require(
            _endDate - _startDate > DISPUTE_WINDOW,
            "Rental duration must exceed dispute window"
        );

        landlord       = msg.sender;
        tenant         = _tenant;
        arbiter        = _arbiter;
        RENT_AMOUNT    = _rentAmount;
        DEPOSIT_AMOUNT = _depositAmount;
        START_DATE     = _startDate;
        END_DATE       = _endDate;

        status = Status.Created;

        emit Created(landlord, block.timestamp);
    }

    // ── ETH guard ────────────────────────────────────────────

    receive() external payable {
        revert("Use fund()");
    }

    fallback() external payable {
        revert("Invalid call");
    }

    // ── Core functions ───────────────────────────────────────

    /// @notice Tenant funds the contract in full in a single transaction.
    /// @dev    The tenant must send exactly RENT_AMOUNT + DEPOSIT_AMOUNT in one tx.
    function fund() external payable onlyTenant inStatus(Status.Created) nonReentrant {
        uint256 requiredAmount = RENT_AMOUNT + DEPOSIT_AMOUNT;

        // Exact amount required — no partial, no over
        require(msg.value == requiredAmount, "Must fund exact total amount");

        fundedAmount = msg.value;
        status       = Status.Funded;

        emit Funded(msg.sender, fundedAmount);
    }

    /// @notice Tenant cancels before activation and reclaims their deposit.
    /// @dev    In practice this is now only reachable if fund() was called
    ///         and then cancelled before the landlord activates i.e.
    ///         This function is kept for Created status edge cases where
    ///         a future upgrade might re-enable partial funding.
    function cancel() external onlyTenant inStatus(Status.Created) nonReentrant {
        require(fundedAmount > 0, "Nothing funded");

        withdrawable[tenant] += fundedAmount;
        fundedAmount = 0;
        status = Status.Cancelled;

        emit Cancelled(tenant, landlord);
    }

    /// @notice Landlord activates the agreement once fully funded.
    function activate() external onlyLandlord inStatus(Status.Funded) {
        require(block.timestamp >= START_DATE, "Too early to activate");
        require(block.timestamp <  END_DATE,   "Rental period expired");

        status = Status.Active;

        emit Active(msg.sender, tenant, block.timestamp);
    }

    /// @notice Tenant cancels if landlord has not activated within the grace period.
    /// @dev    Grace period is ACTIVATION_GRACE seconds after START_DATE.
    function cancelIfUnactivated() external onlyTenant inStatus(Status.Funded) nonReentrant {
        require(
            block.timestamp >= START_DATE + ACTIVATION_GRACE,
            "Activation grace period not over"
        );

        withdrawable[tenant] += fundedAmount;
        fundedAmount = 0;
        status = Status.Cancelled;

        emit Cancelled(tenant, landlord);
    }

    /// @notice Either party completes the agreement after END_DATE.
    /// @dev    complete() is callable in BOTH Active AND Disputed status,
    ///         as long as block.timestamp >= END_DATE. This allows the agreement to be completed even if a dispute was raised but not resolved, preventing locked funds indefinitely.
    function complete() external onlyParty {
        require(
            status == Status.Active || status == Status.Disputed,
            "Invalid status for this action"
        );
        require(block.timestamp >= END_DATE, "Rental period not finished");

        uint256 requiredAmount = RENT_AMOUNT + DEPOSIT_AMOUNT;
        require(fundedAmount == requiredAmount, "Incorrect funded amount");

        withdrawable[tenant]   += DEPOSIT_AMOUNT;
        withdrawable[landlord] += RENT_AMOUNT;

        status = Status.Completed;

        emit Completed(tenant, landlord, RENT_AMOUNT);
    }

    /// @notice Either party raises a dispute during the dispute window.
    /// @dev    Dispute window opens at END_DATE - DISPUTE_WINDOW.
    function raiseDispute() external onlyParty inStatus(Status.Active) {
        require(
            block.timestamp >= END_DATE - DISPUTE_WINDOW,
            "Too early to raise dispute"
        );

        disputeRaisedAt = block.timestamp;
        status = Status.Disputed;

        emit DisputeRaised(msg.sender, block.timestamp);
    }

    /// @notice Arbiter resolves the dispute by splitting funds between parties.
    /// @dev    Resolution does NOT immediately make funds
    ///         withdrawable. A RESOLUTION_TIMELOCK (48h) is enforced, giving
    ///         the losing party time to react off-chain before funds move.
    ///         withdraw() checks withdrawalUnlockTime before transferring.
    /// @param landlordAmount  Amount awarded to landlord (must sum to fundedAmount)
    /// @param tenantAmount    Amount awarded to tenant   (must sum to fundedAmount)
    function resolveDispute(
        uint256 landlordAmount,
        uint256 tenantAmount
    ) external onlyArbiter inStatus(Status.Disputed) nonReentrant {
        require(
            landlordAmount + tenantAmount == fundedAmount,
            "Amounts must sum to funded total"
        );

        withdrawable[landlord] += landlordAmount;
        withdrawable[tenant]   += tenantAmount;

        withdrawalUnlockTime = block.timestamp + RESOLUTION_TIMELOCK;

        fundedAmount = 0;
        status = Status.Completed;

        emit DisputeResolved(msg.sender, landlordAmount, tenantAmount, withdrawalUnlockTime);
    }

    /// @notice Withdraw available funds after agreement is completed or cancelled.
    /// @dev    If funds were set via resolveDispute(), they
    ///         are locked until withdrawalUnlockTime has passed.
    ///         Normal complete() and cancel() paths are NOT timelocked —
    ///         withdrawalUnlockTime is 0 in those cases, so the check passes.
    function withdraw() external inWithdrawableState nonReentrant {
        //Enforce timelock only when set by resolveDispute()
        if (withdrawalUnlockTime > 0) {
            require(
                block.timestamp >= withdrawalUnlockTime,
                "Funds locked: resolution timelock active"
            );
        }

        uint256 amount = withdrawable[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        withdrawable[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    // ── Arbiter replacement (MED-1 patch) ────────────────────

    /// @notice Either party proposes or approves a new arbiter.
    /// @dev    If the arbiter becomes unresponsive (i.e.
    ///         ARBITER_TIMEOUT seconds have passed since disputeRaisedAt
    ///         with no resolution), both landlord AND tenant must call
    ///         this function with the SAME new arbiter address to replace.
    ///         Requires consensus — neither party can unilaterally replace.
    /// @param _newArbiter  Proposed replacement arbiter address
    function proposeNewArbiter(address _newArbiter) external onlyParty inStatus(Status.Disputed) {
        require(
            block.timestamp >= disputeRaisedAt + ARBITER_TIMEOUT,
            "Arbiter timeout not reached"
        );
        require(_newArbiter != address(0),  "Invalid arbiter address");
        require(_newArbiter != landlord,    "Arbiter cannot be landlord");
        require(_newArbiter != tenant,      "Arbiter cannot be tenant");

        // If proposing a different address from the current pending one,
        // reset both approvals so parties must re-agree on the same address
        if (_newArbiter != pendingArbiter) {
            pendingArbiter              = _newArbiter;
            landlordApprovedNewArbiter  = false;
            tenantApprovedNewArbiter    = false;
        }

        // Record this party's approval
        if (msg.sender == landlord) {
            landlordApprovedNewArbiter = true;
        } else {
            tenantApprovedNewArbiter = true;
        }

        emit ArbiterReplaceProposed(msg.sender, _newArbiter);

        // If both parties have approved the same address, replace arbiter
        if (landlordApprovedNewArbiter && tenantApprovedNewArbiter) {
            address oldArbiter = arbiter;
            arbiter = pendingArbiter;

            // Reset approval state
            pendingArbiter             = address(0);
            landlordApprovedNewArbiter = false;
            tenantApprovedNewArbiter   = false;

            emit ArbiterReplaced(oldArbiter, arbiter);
        }
    }

    // ── View helpers ─────────────────────────────────────────

    /// @notice Returns true if the resolution timelock has expired or was never set.
    function isWithdrawalUnlocked() external view returns (bool) {
        return withdrawalUnlockTime == 0 || block.timestamp >= withdrawalUnlockTime;
    }

    /// @notice Returns true if the arbiter replacement timeout has been reached.
    function isArbiterTimedOut() external view returns (bool) {
        return status == Status.Disputed &&
               disputeRaisedAt > 0 &&
               block.timestamp >= disputeRaisedAt + ARBITER_TIMEOUT;
    }
}
