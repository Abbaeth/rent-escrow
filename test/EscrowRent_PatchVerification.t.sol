// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ============================================================
//  PATCH VERIFICATION TESTS
//  Each test proves one exploit no longer works.
//  Every test must PASS — a passing test means the attack FAILS.
// ============================================================

contract EscrowRentPatchedBase is Test {

    address internal landlord = makeAddr("landlord");
    address internal tenant   = makeAddr("tenant");
    address internal arbiter  = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant RENT    = 1 ether;
    uint256 internal constant DEPOSIT = 0.5 ether;
    uint256 internal constant TOTAL   = RENT + DEPOSIT;

    uint256 internal constant DISPUTE_WINDOW     = 3 days;
    uint256 internal constant ACTIVATION_GRACE   = 3 days;
    uint256 internal constant RESOLUTION_TIMELOCK = 48 hours;
    uint256 internal constant ARBITER_TIMEOUT    = 7 days;

    uint256 internal startDate;
    uint256 internal endDate;

    EscrowRent internal escrow;

    function setUp() public virtual {
        vm.warp(1_000_000);
        vm.deal(landlord, 10 ether);
        vm.deal(tenant,   10 ether);
        vm.deal(arbiter,  1 ether);
        vm.deal(stranger, 1 ether);

        startDate = block.timestamp + 1 days;
        endDate   = startDate + 30 days; // 30 days >> DISPUTE_WINDOW

        vm.prank(landlord);
        escrow = new EscrowRent(
            tenant, arbiter, RENT, DEPOSIT, startDate, endDate
        );
    }

    // ── Shared helpers ───────────────────────────────────────

    function _fund() internal {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
    }

    function _activate() internal {
        _fund();
        vm.warp(startDate);
        vm.prank(landlord);
        escrow.activate();
    }

    function _raiseDispute() internal {
        _activate();
        vm.warp(endDate - DISPUTE_WINDOW + 1);
        vm.prank(tenant);
        escrow.raiseDispute();
    }
}

// ============================================================
//  PATCH 1 — CRITICAL-1: Dust griefing fixed
//  fund() now requires the exact full amount in one tx.
//  Partial amounts revert. TOTAL-1 reverts. TOTAL+1 reverts.
//  The limbo state (Created with partial ETH) cannot occur.
// ============================================================
contract PatchVerify_Critical1_DustGriefing is EscrowRentPatchedBase {

    /// @notice Sending TOTAL-1 (the griefing amount) now reverts
    function test_Patch_DustGrief_PartialFundReverts() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: TOTAL - 1}();

        // Status unchanged — still Created
        assertTrue(escrow.status() == EscrowRent.Status.Created);
        assertEq(escrow.fundedAmount(), 0);
    }

    /// @notice Sending 1 wei (the minimum dust) now reverts
    function test_Patch_DustGrief_OneWeiReverts() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: 1}();
    }

    /// @notice Sending TOTAL+1 (overfunding) now reverts
    function test_Patch_DustGrief_OverfundReverts() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: TOTAL + 1}();
    }

    /// @notice Landlord's window is safe — tenant cannot freeze contract
    function test_Patch_DustGrief_LandlordWindowProtected() public {
        // Tenant tries the TOTAL-1 grief attack
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: TOTAL - 1}();

        // Time passes — rental window approaches
        vm.warp(startDate);

        // Landlord cannot activate (not funded) but that's expected —
        // the key point is NO ETH is locked in the contract
        assertEq(address(escrow).balance, 0);
        assertEq(escrow.fundedAmount(), 0);

        // Tenant must fund the full amount or not at all
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
        assertTrue(escrow.status() == EscrowRent.Status.Funded);
    }

    /// @notice Happy path still works — exact TOTAL succeeds
    function test_Patch_DustGrief_ExactTotalSucceeds() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();

        assertEq(escrow.fundedAmount(), TOTAL);
        assertTrue(escrow.status() == EscrowRent.Status.Funded);
        assertEq(address(escrow).balance, TOTAL);
    }
}

// ============================================================
//  PATCH 2 — CRITICAL-2: Arbiter collusion timelock
//  resolveDispute() now sets a 48h withdrawal lock.
//  Funds cannot be moved until withdrawalUnlockTime passes.
//  Instant theft via colluding arbiter is no longer possible.
// ============================================================
contract PatchVerify_Critical2_ArbiterCollusion is EscrowRentPatchedBase {

    /// @notice Colluding arbiter resolves instantly — but withdraw is locked
    function test_Patch_ArbiterCollusion_WithdrawLockedFor48h() public {
        _raiseDispute();

        // Colluding arbiter tries to award everything to landlord instantly
        vm.prank(arbiter);
        escrow.resolveDispute(TOTAL, 0);

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(landlord), TOTAL);

        // Landlord tries to withdraw immediately — BLOCKED by timelock
        vm.prank(landlord);
        vm.expectRevert("Funds locked: resolution timelock active");
        escrow.withdraw();

        // Still blocked 1 second before unlock
        vm.warp(block.timestamp + RESOLUTION_TIMELOCK - 1);
        vm.prank(landlord);
        vm.expectRevert("Funds locked: resolution timelock active");
        escrow.withdraw();
    }

    /// @notice After 48h timelock, withdrawal succeeds
    function test_Patch_ArbiterCollusion_WithdrawSucceedsAfterTimelock() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(RENT, DEPOSIT);

        // Warp past the 48h timelock
        vm.warp(block.timestamp + RESOLUTION_TIMELOCK);

        uint256 landlordBefore = landlord.balance;
        uint256 tenantBefore   = tenant.balance;

        vm.prank(landlord);
        escrow.withdraw();

        vm.prank(tenant);
        escrow.withdraw();

        assertEq(landlord.balance, landlordBefore + RENT);
        assertEq(tenant.balance,   tenantBefore   + DEPOSIT);
    }

    /// @notice isWithdrawalUnlocked() view reflects timelock state correctly
    function test_Patch_ArbiterCollusion_ViewHelperCorrect() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(TOTAL, 0);

        // Immediately after resolution — locked
        assertFalse(escrow.isWithdrawalUnlocked());

        // After timelock — unlocked
        vm.warp(block.timestamp + RESOLUTION_TIMELOCK);
        assertTrue(escrow.isWithdrawalUnlocked());
    }

    /// @notice Normal complete() path has NO timelock (withdrawalUnlockTime stays 0)
    function test_Patch_ArbiterCollusion_NormalCompleteHasNoTimelock() public {
        _activate();
        vm.warp(endDate + 1);

        vm.prank(landlord);
        escrow.complete();

        // withdrawalUnlockTime was never set — withdraw is immediate
        assertEq(escrow.withdrawalUnlockTime(), 0);
        assertTrue(escrow.isWithdrawalUnlocked());

        vm.prank(landlord);
        escrow.withdraw(); // succeeds immediately — no revert
    }
}

// ============================================================
//  PATCH 3 — CRITICAL-3: Dispute window no longer blocks complete()
//  complete() is now callable in both Active AND Disputed status
//  once END_DATE is reached. Landlord can no longer force
//  arbitration by raising a dispute before END_DATE.
// ============================================================
contract PatchVerify_Critical3_DisputeBlocksComplete is EscrowRentPatchedBase {

    /// @notice Landlord raises dispute before END_DATE — tenant can still complete() after END_DATE
    function test_Patch_DisputeBlocksComplete_TenantCanStillComplete() public {
        _activate();

        // Landlord raises dispute at the earliest opportunity
        vm.warp(endDate - DISPUTE_WINDOW);
        vm.prank(landlord);
        escrow.raiseDispute();

        assertTrue(escrow.status() == EscrowRent.Status.Disputed);

        // Warp to END_DATE — tenant calls complete() despite Disputed status
        vm.warp(endDate);
        vm.prank(tenant);
        escrow.complete(); // must NOT revert

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);
        assertEq(escrow.withdrawable(landlord), RENT);
    }

    /// @notice Landlord raises dispute AND tries to block — tenant completes anyway
    function test_Patch_DisputeBlocksComplete_LandlordCannotForceArbitration() public {
        _activate();

        vm.warp(endDate - DISPUTE_WINDOW);
        vm.prank(landlord);
        escrow.raiseDispute();

        // Landlord intended to force arbitration with their chosen arbiter
        // But tenant completes at END_DATE before arbiter can act
        vm.warp(endDate);
        vm.prank(tenant);
        escrow.complete();

        // Arbiter's resolveDispute() is now invalid — status is Completed
        vm.prank(arbiter);
        vm.expectRevert("Invalid status for this action");
        escrow.resolveDispute(TOTAL, 0);
    }

    /// @notice complete() still requires END_DATE — cannot be called before
    function test_Patch_DisputeBlocksComplete_StillRequiresEndDate() public {
        _activate();

        vm.warp(endDate - DISPUTE_WINDOW);
        vm.prank(landlord);
        escrow.raiseDispute();

        // Try to complete before END_DATE — must revert
        vm.prank(tenant);
        vm.expectRevert("Rental period not finished");
        escrow.complete();
    }
}

// ============================================================
//  PATCH 4 — HIGH-1: Front-run complete() with raiseDispute()
//  Even if landlord's raiseDispute() lands first, tenant's
//  complete() at END_DATE still succeeds in Disputed status.
// ============================================================
contract PatchVerify_High1_FrontRunComplete is EscrowRentPatchedBase {

    /// @notice Landlord front-runs with raiseDispute() — tenant's complete() still wins
    function test_Patch_FrontRun_TenantCompleteWinsAfterDispute() public {
        _activate();
        vm.warp(endDate);

        // Landlord's tx lands first (higher gas in real mempool)
        vm.prank(landlord);
        escrow.raiseDispute();
        assertTrue(escrow.status() == EscrowRent.Status.Disputed);

        // Tenant's complete() lands second — still succeeds
        vm.prank(tenant);
        escrow.complete();

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);
        assertEq(escrow.withdrawable(landlord), RENT);
    }
}

// ============================================================
//  PATCH 5 — HIGH-2: Short rental dispute window fixed
//  Constructor now reverts if rental duration <= DISPUTE_WINDOW.
//  Landlord cannot deploy a contract where activate() and
//  raiseDispute() are callable in the same block.
// ============================================================
contract PatchVerify_High2_ShortRentalDispute is EscrowRentPatchedBase {

    /// @notice Deploying a rental shorter than DISPUTE_WINDOW reverts
    function test_Patch_ShortRental_ConstructorReverts() public {
        vm.warp(1_000_000);
        uint256 s = block.timestamp + 1 days;
        uint256 e = s + 2 days; // 2 days < DISPUTE_WINDOW (3 days)

        vm.prank(landlord);
        vm.expectRevert("Rental duration must exceed dispute window");
        new EscrowRent(tenant, arbiter, RENT, DEPOSIT, s, e);
    }

    /// @notice Deploying a rental exactly equal to DISPUTE_WINDOW reverts
    function test_Patch_ShortRental_ExactWindowReverts() public {
        vm.warp(1_000_000);
        uint256 s = block.timestamp + 1 days;
        uint256 e = s + DISPUTE_WINDOW; // equal, not greater

        vm.prank(landlord);
        vm.expectRevert("Rental duration must exceed dispute window");
        new EscrowRent(tenant, arbiter, RENT, DEPOSIT, s, e);
    }

    /// @notice Deploying a rental one second longer than DISPUTE_WINDOW succeeds
    function test_Patch_ShortRental_JustOverWindowSucceeds() public {
        vm.warp(1_000_000);
        uint256 s = block.timestamp + 1 days;
        uint256 e = s + DISPUTE_WINDOW + 1; // one second more than window

        vm.prank(landlord);
        EscrowRent newEscrow = new EscrowRent(
            tenant, arbiter, RENT, DEPOSIT, s, e
        );
        assertEq(newEscrow.END_DATE(), e);
    }

    /// @notice Activate + raiseDispute in same block is impossible on valid contracts
    function test_Patch_ShortRental_CannotActivateAndDisputeSameBlock() public {
        // With 30-day rental, dispute window opens at endDate - 3 days
        // After activation at startDate, there are 27 days before dispute is valid
        _activate();

        // Attempt raiseDispute immediately after activation — must revert
        vm.prank(landlord);
        vm.expectRevert("Too early to raise dispute");
        escrow.raiseDispute();
    }
}

// ============================================================
//  PATCH 6 — MED-1: Dead arbiter replacement
//  If arbiter is unresponsive for ARBITER_TIMEOUT (7 days),
//  both parties can jointly agree on a replacement.
// ============================================================
contract PatchVerify_Med1_DeadArbiter is EscrowRentPatchedBase {

    address internal newArbiter = makeAddr("newArbiter");

    /// @notice Both parties agree on new arbiter after timeout — replacement succeeds
    function test_Patch_DeadArbiter_ReplacementSucceeds() public {
        _raiseDispute();

        // Arbiter goes silent — 7 days pass with no resolution
        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        // Both parties propose the same new arbiter
        vm.prank(landlord);
        escrow.proposeNewArbiter(newArbiter);

        vm.prank(tenant);
        escrow.proposeNewArbiter(newArbiter);

        // Arbiter is now replaced
        assertEq(escrow.arbiter(), newArbiter);
    }

    /// @notice New arbiter can resolve after replacement
    function test_Patch_DeadArbiter_NewArbiterCanResolve() public {
        _raiseDispute();

        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        vm.prank(landlord);
        escrow.proposeNewArbiter(newArbiter);
        vm.prank(tenant);
        escrow.proposeNewArbiter(newArbiter);

        assertEq(escrow.arbiter(), newArbiter);

        // New arbiter resolves fairly
        vm.prank(newArbiter);
        escrow.resolveDispute(RENT, DEPOSIT);

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
    }

    /// @notice Replacement cannot happen before timeout
    function test_Patch_DeadArbiter_CannotReplaceBeforeTimeout() public {
        _raiseDispute();

        vm.warp(block.timestamp + ARBITER_TIMEOUT - 1); // one second short

        vm.prank(landlord);
        vm.expectRevert("Arbiter timeout not reached");
        escrow.proposeNewArbiter(newArbiter);
    }

    /// @notice One party cannot unilaterally replace arbiter — both must agree
    function test_Patch_DeadArbiter_RequiresBothParties() public {
        _raiseDispute();
        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        // Only landlord proposes — not enough
        vm.prank(landlord);
        escrow.proposeNewArbiter(newArbiter);

        // Arbiter unchanged until tenant also approves
        assertEq(escrow.arbiter(), arbiter);
    }

    /// @notice If parties propose different addresses, approvals reset
    function test_Patch_DeadArbiter_DisagreementResetsApproval() public {
        _raiseDispute();
        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        address arbiterA = makeAddr("arbiterA");
        address arbiterB = makeAddr("arbiterB");

        vm.prank(landlord);
        escrow.proposeNewArbiter(arbiterA);

        // Tenant proposes a different address — resets landlord's approval
        vm.prank(tenant);
        escrow.proposeNewArbiter(arbiterB);

        // Arbiter is still the original — no agreement reached
        assertEq(escrow.arbiter(), arbiter);

        // Now landlord agrees to arbiterB — replacement goes through
        vm.prank(landlord);
        escrow.proposeNewArbiter(arbiterB);

        assertEq(escrow.arbiter(), arbiterB);
    }

    /// @notice Stranger cannot propose a new arbiter
    function test_Patch_DeadArbiter_StrangerCannotPropose() public {
        _raiseDispute();
        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        vm.prank(stranger);
        vm.expectRevert("Not a party");
        escrow.proposeNewArbiter(newArbiter);
    }

    /// @notice isArbiterTimedOut() view returns correct value
    function test_Patch_DeadArbiter_ViewHelperCorrect() public {
        _raiseDispute();

        assertFalse(escrow.isArbiterTimedOut()); // not yet

        vm.warp(block.timestamp + ARBITER_TIMEOUT);
        assertTrue(escrow.isArbiterTimedOut());  // now timed out
    }

    /// @notice isArbiterTimedOut() returns false when status is not Disputed
    function test_Patch_DeadArbiter_ViewHelper_FalseWhenNotDisputed() public {
        // Status is Created — not Disputed
        assertFalse(escrow.isArbiterTimedOut());

        // Status is Funded — not Disputed
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
        assertFalse(escrow.isArbiterTimedOut());

        // Status is Active — not Disputed
        vm.warp(startDate);
        vm.prank(landlord);
        escrow.activate();
        assertFalse(escrow.isArbiterTimedOut());

        // Status is Completed — not Disputed
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();
        assertFalse(escrow.isArbiterTimedOut());
    }

    /// @notice isArbiterTimedOut() returns false when disputeRaisedAt is 0
    function test_Patch_DeadArbiter_ViewHelper_FalseWhenNoDispute() public {
        // disputeRaisedAt is 0 — no dispute ever raised
        assertEq(escrow.disputeRaisedAt(), 0);
        assertFalse(escrow.isArbiterTimedOut());
    }

    /// @notice proposeNewArbiter reverts when new arbiter is landlord
    function test_Patch_DeadArbiter_CannotProposeArbiterAsLandlord() public {
        _raiseDispute();
        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        vm.prank(tenant);
        vm.expectRevert("Arbiter cannot be landlord");
        escrow.proposeNewArbiter(landlord);
    }

    /// @notice proposeNewArbiter reverts when new arbiter is tenant
    function test_Patch_DeadArbiter_CannotProposeArbiterAsTenant() public {
        _raiseDispute();
        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        vm.prank(landlord);
        vm.expectRevert("Arbiter cannot be tenant");
        escrow.proposeNewArbiter(tenant);
    }

    /// @notice proposeNewArbiter reverts when address is zero
    function test_Patch_DeadArbiter_CannotProposeZeroAddress() public {
        _raiseDispute();
        vm.warp(block.timestamp + ARBITER_TIMEOUT);

        vm.prank(landlord);
        vm.expectRevert("Invalid arbiter address");
        escrow.proposeNewArbiter(address(0));
    }
}

// ============================================================
//  COVERAGE: cancel() dead-code path
//  cancel() requires Status.Created with fundedAmount > 0.
//  With the patched fund() requiring exact TOTAL, status goes
//  directly to Funded — the Created+funded state is unreachable
//  via the normal API. We use vm.store to force the state and
//  hit the cancel() body for coverage completeness.
// ============================================================
contract PatchVerify_CancelDeadCode is EscrowRentPatchedBase {

    /// @notice Force Created+funded state via vm.store to cover cancel() body
    function test_Coverage_Cancel_ForcedCreatedState() public {
        // OZ v5 ReentrancyGuard uses EIP-7201 namespaced storage (not slot 0).
        // EscrowRent state variable slots:
        //   slot 0: status (Status enum, uint8)
        //   slot 1: fundedAmount (uint256)
        //
        // Status.Created == 0 (already the default), so only fundedAmount needs setting.

        // Write fundedAmount = TOTAL into slot 1
        vm.store(address(escrow), bytes32(uint256(1)), bytes32(TOTAL));

        assertEq(uint256(escrow.status()), 0); // Status.Created == 0
        assertEq(escrow.fundedAmount(), TOTAL);

        // Give escrow the ETH to back the withdrawable balance
        vm.deal(address(escrow), TOTAL);

        // Now cancel() is reachable — hit the body for coverage
        uint256 before = tenant.balance;
        vm.prank(tenant);
        escrow.cancel();

        assertTrue(escrow.status() == EscrowRent.Status.Cancelled);
        assertEq(escrow.fundedAmount(), 0);
        assertEq(escrow.withdrawable(tenant), TOTAL);

        vm.prank(tenant);
        escrow.withdraw();
        assertEq(tenant.balance, before + TOTAL);
    }
}

// ============================================================
//  COVERAGE: View helpers and remaining branches
// ============================================================
contract PatchVerify_ViewHelpers is EscrowRentPatchedBase {

    /// @notice isWithdrawalUnlocked() true when unlockTime is 0 (never set)
    function test_View_WithdrawalUnlocked_WhenNeverSet() public view {
        assertEq(escrow.withdrawalUnlockTime(), 0);
        assertTrue(escrow.isWithdrawalUnlocked());
    }

    /// @notice isWithdrawalUnlocked() false before timelock, true after
    function test_View_WithdrawalUnlocked_TimelockLifecycle() public {
        _raiseDispute();
        vm.prank(arbiter);
        escrow.resolveDispute(RENT, DEPOSIT);

        // Immediately after — locked
        assertFalse(escrow.isWithdrawalUnlocked());

        // Exactly at unlock time — unlocked
        vm.warp(escrow.withdrawalUnlockTime());
        assertTrue(escrow.isWithdrawalUnlocked());
    }

    /// @notice withdraw() with timelock==0 (normal complete path) — no timelock check
    function test_View_Withdraw_NoTimelockOnNormalComplete() public {
        _activate();
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();

        assertEq(escrow.withdrawalUnlockTime(), 0);

        // Withdraw immediately — no timelock
        vm.prank(tenant);
        escrow.withdraw();
        vm.prank(landlord);
        escrow.withdraw();

        assertEq(address(escrow).balance, 0);
    }

    /// @notice complete() callable in Disputed status at END_DATE
    function test_View_Complete_FromDisputedStatus() public {
        _activate();
        vm.warp(endDate - 3 days);
        vm.prank(landlord);
        escrow.raiseDispute();

        assertTrue(escrow.status() == EscrowRent.Status.Disputed);

        vm.warp(endDate);
        vm.prank(tenant);
        escrow.complete();

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);
        assertEq(escrow.withdrawable(landlord), RENT);
    }
}

// ============================================================
//  FULL HAPPY PATH — verify nothing is broken by patches
// ============================================================
contract PatchVerify_HappyPath is EscrowRentPatchedBase {

    function test_Patch_HappyPath_FullLifecycle() public {
        // Fund exactly
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
        assertTrue(escrow.status() == EscrowRent.Status.Funded);

        // Activate
        vm.warp(startDate);
        vm.prank(landlord);
        escrow.activate();
        assertTrue(escrow.status() == EscrowRent.Status.Active);

        // Complete after end date
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();
        assertTrue(escrow.status() == EscrowRent.Status.Completed);

        // No timelock on normal complete — withdraw immediately
        assertEq(escrow.withdrawalUnlockTime(), 0);

        uint256 tenantBefore   = tenant.balance;
        uint256 landlordBefore = landlord.balance;

        vm.prank(tenant);
        escrow.withdraw();
        vm.prank(landlord);
        escrow.withdraw();

        assertEq(tenant.balance,   tenantBefore   + DEPOSIT);
        assertEq(landlord.balance, landlordBefore + RENT);
        assertEq(address(escrow).balance, 0);
    }

    function test_Patch_HappyPath_CancelIfUnactivated() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();

        vm.warp(startDate + ACTIVATION_GRACE + 1);
        vm.prank(tenant);
        escrow.cancelIfUnactivated();

        assertTrue(escrow.status() == EscrowRent.Status.Cancelled);

        uint256 before = tenant.balance;
        vm.prank(tenant);
        escrow.withdraw();
        assertEq(tenant.balance, before + TOTAL);
    }

    function test_Patch_HappyPath_DisputeResolvesAfterTimelock() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(RENT, DEPOSIT);

        // Timelock is active
        assertFalse(escrow.isWithdrawalUnlocked());

        // After 48h
        vm.warp(block.timestamp + RESOLUTION_TIMELOCK);
        assertTrue(escrow.isWithdrawalUnlocked());

        vm.prank(landlord);
        escrow.withdraw();
        vm.prank(tenant);
        escrow.withdraw();

        assertEq(address(escrow).balance, 0);
    }
}
