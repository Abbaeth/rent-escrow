// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EscrowRentBase} from "./EscrowRentBase.t.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ================================================================
//  UNIT TESTS
//  One test per function, per revert path, per event.
//  Each test is isolated — no cross-function state dependencies.
// ================================================================
contract EscrowRentUnitTest is EscrowRentBase {

    // ============================================================
    //  constructor()
    // ============================================================

    function test_Constructor_SetsStateCorrectly() public view {
        assertEq(escrow.landlord(),       landlord);
        assertEq(escrow.tenant(),         tenant);
        assertEq(escrow.arbiter(),        arbiter);
        assertEq(escrow.RENT_AMOUNT(),    RENT);
        assertEq(escrow.DEPOSIT_AMOUNT(), DEPOSIT);
        assertEq(escrow.START_DATE(),     startDate);
        assertEq(escrow.END_DATE(),       endDate);
        assertEq(escrow.fundedAmount(),   0);
        assertTrue(escrow.status() == EscrowRent.Status.Created);
    }

    function test_Constructor_EmitsCreatedEvent() public { 
        vm.warp(1_000_000); 
        uint256 s = block.timestamp + 1 days; 
        uint256 e = s + DURATION; 

        vm.expectEmit(true, false, false, true); 
        emit EscrowRent.Created(landlord, block.timestamp);

        vm.prank(landlord);
        new EscrowRent(tenant, arbiter, RENT, DEPOSIT, s, e);
    }

    function test_Constructor_Revert_ZeroTenant() public {
        vm.prank(landlord);
        vm.expectRevert("Invalid tenant");
        new EscrowRent(address(0), arbiter, RENT, DEPOSIT, startDate, endDate);
    }

    function test_Constructor_Revert_ZeroArbiter() public {
        vm.prank(landlord);
        vm.expectRevert("Invalid arbiter");
        new EscrowRent(tenant, address(0), RENT, DEPOSIT, startDate, endDate);
    }

    function test_Constructor_Revert_ArbiterIsLandlord() public {
        vm.prank(landlord);
        vm.expectRevert("Arbiter cannot be landlord");
        new EscrowRent(tenant, landlord, RENT, DEPOSIT, startDate, endDate);
    }

    function test_Constructor_Revert_ArbiterIsTenant() public {
        vm.prank(landlord);
        vm.expectRevert("Arbiter cannot be tenant");
        new EscrowRent(tenant, tenant, RENT, DEPOSIT, startDate, endDate);
    }

    function test_Constructor_Revert_ZeroRent() public {
        vm.prank(landlord);
        vm.expectRevert("Rent must be > 0");
        new EscrowRent(tenant, arbiter, 0, DEPOSIT, startDate, endDate);
    }

    function test_Constructor_Revert_ZeroDeposit() public {
        vm.prank(landlord);
        vm.expectRevert("Deposit must be > 0");
        new EscrowRent(tenant, arbiter, RENT, 0, startDate, endDate);
    }

    function test_Constructor_Revert_EndBeforeStart() public {
        vm.prank(landlord);
        vm.expectRevert("End date must be after start");
        new EscrowRent(tenant, arbiter, RENT, DEPOSIT, startDate, startDate - 1);
    }

    function test_Constructor_Revert_StartInPast() public {
        vm.prank(landlord);
        vm.expectRevert("Start date must be in future");
        new EscrowRent(tenant, arbiter, RENT, DEPOSIT, block.timestamp - 1, endDate);
    }

    // ============================================================
    //  fund()
    // ============================================================

    function test_Fund_FullAmount_OneTransaction() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();

        assertEq(escrow.fundedAmount(), TOTAL);
        assertTrue(escrow.status() == EscrowRent.Status.Funded);
        assertEq(address(escrow).balance, TOTAL);
    }

    function test_Fund_PartialAmount_Reverts() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: RENT}(); // partial — no longer allowed
    }

    /// @notice fund() emits only the Funded event
    function test_Fund_EmitsEvents() public {
        vm.expectEmit(true, false, false, true);
        emit EscrowRent.Funded(tenant, TOTAL);

        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
    }

    function test_Fund_Revert_NotTenant() public {
        hoax(stranger, TOTAL); 
        vm.expectRevert("Not tenant");
        escrow.fund{value: TOTAL}();
    }

    function test_Fund_Revert_ZeroValue() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: 0}();
    }

    function test_Fund_Revert_Overfunding() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: TOTAL + 1}();
    }

    function test_Fund_Revert_WrongStatus() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();

        vm.prank(tenant);
        vm.expectRevert("Invalid status for this action");
        escrow.fund{value: 1}();
    }

    // ============================================================
    //  cancel()
    // ============================================================

    // NOTE: fund() requires exact TOTAL
    // so status immediately becomes Funded after fund(). cancel()
    // requires Status.Created with fundedAmount > 0 — this path is
    // only reachable if a future upgrade re-enables partial funding.
    // We test it by directly manipulating state via cancelIfUnactivated.
    // The cancel() function itself is tested for its revert guards.

    function test_Cancel_Revert_NothingFunded() public {
        vm.prank(tenant);
        vm.expectRevert("Nothing funded");
        escrow.cancel();
    }

    function test_Cancel_Revert_NotTenant() public {
        vm.prank(landlord);
        vm.expectRevert("Not tenant");
        escrow.cancel();
    }

    function test_Cancel_Revert_WrongStatus() public {
        // After fund(), status is Funded — cancel() requires Created
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();

        vm.prank(tenant);
        vm.expectRevert("Invalid status for this action");
        escrow.cancel();
    }



    // ============================================================
    //  activate()
    // ============================================================

    function test_Activate_HappyPath() public {
        _fullFund();
        vm.warp(startDate);

        vm.prank(landlord);
        escrow.activate();

        assertTrue(escrow.status() == EscrowRent.Status.Active);
    }

    function test_Activate_EmitsActiveEvent() public {
        _fullFund();
        vm.warp(startDate);

        vm.expectEmit(true, true, false, true);
        emit EscrowRent.Active(landlord, tenant, startDate);

        vm.prank(landlord);
        escrow.activate();
    }

    function test_Activate_Revert_TooEarly() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();

        vm.prank(landlord);
        vm.expectRevert("Too early to activate");
        escrow.activate();
    }

    function test_Activate_Revert_RentalExpired() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
        vm.warp(endDate + 1);

        vm.prank(landlord);
        vm.expectRevert("Rental period expired");
        escrow.activate();
    }

    function test_Activate_Revert_NotLandlord() public {
        _fullFund();
        vm.warp(startDate);

        vm.prank(tenant);
        vm.expectRevert("Not landlord");
        escrow.activate();
    }

    function test_Activate_Revert_WrongStatus() public {
        vm.warp(startDate);
        vm.prank(landlord);
        vm.expectRevert("Invalid status for this action");
        escrow.activate();
    }

    // ============================================================
    //  cancelIfUnactivated()
    // ============================================================

    function test_CancelIfUnactivated_HappyPath() public {
        _fullFund();
        vm.warp(startDate + GRACE_PERIOD + 1);

        vm.prank(tenant);
        escrow.cancelIfUnactivated();

        assertTrue(escrow.status() == EscrowRent.Status.Cancelled);
        assertEq(escrow.withdrawable(tenant), TOTAL);
        assertEq(escrow.fundedAmount(), 0);
    }

    function test_CancelIfUnactivated_Revert_GracePeriodNotOver() public {
        _fullFund();
        vm.warp(startDate + GRACE_PERIOD - 1);

        vm.prank(tenant);
        vm.expectRevert("Activation grace period not over");
        escrow.cancelIfUnactivated();
    }

    function test_CancelIfUnactivated_Revert_NotTenant() public {
        _fullFund();
        vm.warp(startDate + GRACE_PERIOD + 1);

        vm.prank(landlord);
        vm.expectRevert("Not tenant");
        escrow.cancelIfUnactivated();
    }

    function test_CancelIfUnactivated_Revert_WrongStatus() public {
        vm.warp(startDate + GRACE_PERIOD + 1);

        vm.prank(tenant);
        vm.expectRevert("Invalid status for this action");
        escrow.cancelIfUnactivated();
    }

    // ============================================================
    //  complete()
    // ============================================================

    function test_Complete_ByTenant_HappyPath() public {
        _activateEscrow();
        vm.warp(endDate + 1);

        vm.prank(tenant);
        escrow.complete();

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);
        assertEq(escrow.withdrawable(landlord), RENT);
    }

    function test_Complete_ByLandlord_HappyPath() public {
        _activateEscrow();
        vm.warp(endDate + 1);

        vm.prank(landlord);
        escrow.complete();

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(landlord), RENT);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);
    }

    function test_Complete_EmitsCompletedEvent() public {
        _activateEscrow();
        vm.warp(endDate + 1);

        vm.expectEmit(true, true, false, true);
        emit EscrowRent.Completed(tenant, landlord, RENT);

        vm.prank(landlord);
        escrow.complete();
    }

    function test_Complete_Revert_TooEarly() public {
        _activateEscrow();
        vm.warp(endDate - 1);

        vm.prank(tenant);
        vm.expectRevert("Rental period not finished");
        escrow.complete();
    }

    function test_Complete_Revert_NotParty() public {
        _activateEscrow();
        vm.warp(endDate + 1);

        vm.prank(stranger);
        vm.expectRevert("Not a party");
        escrow.complete();
    }

    function test_Complete_Revert_WrongStatus() public {
        _fullFund();
        vm.warp(endDate + 1);

        vm.prank(tenant);
        vm.expectRevert("Invalid status for this action");
        escrow.complete();
    }

    // ============================================================
    //  withdraw()
    // ============================================================

    function test_Withdraw_Tenant_AfterCancelIfUnactivated() public {
        // fund fully → landlord never activates → tenant cancels after grace
        _fullFund();
        vm.warp(startDate + GRACE_PERIOD + 1);
        vm.prank(tenant);
        escrow.cancelIfUnactivated();

        uint256 before = tenant.balance;
        vm.prank(tenant);
        escrow.withdraw();

        assertEq(tenant.balance, before + TOTAL);
        assertEq(escrow.withdrawable(tenant), 0);
    }

    function test_Withdraw_BothParties_AfterComplete() public {
        _activateEscrow();
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();

        uint256 tenantBefore   = tenant.balance;
        uint256 landlordBefore = landlord.balance;

        vm.prank(tenant);
        escrow.withdraw();

        vm.prank(landlord);
        escrow.withdraw();

        assertEq(tenant.balance,   tenantBefore   + DEPOSIT);
        assertEq(landlord.balance, landlordBefore + RENT);
    }

    function test_Withdraw_EmitsWithdrawnEvent() public {
        _activateEscrow();
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();

        vm.expectEmit(true, false, false, true);
        emit EscrowRent.Withdrawn(landlord, RENT);

        vm.prank(landlord);
        escrow.withdraw();
    }

    function test_Withdraw_Revert_NothingToWithdraw() public {
        _activateEscrow();
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();

        vm.prank(arbiter);
        vm.expectRevert("Nothing to withdraw");
        escrow.withdraw();
    }

    function test_Withdraw_Revert_WrongStatus() public {
        _activateEscrow();

        vm.prank(tenant);
        vm.expectRevert("Withdraw not allowed");
        escrow.withdraw();
    }

    function test_Withdraw_Revert_DoubleWithdraw() public {
        _activateEscrow();
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();

        vm.prank(landlord);
        escrow.withdraw(); // first — ok

        vm.prank(landlord);
        vm.expectRevert("Nothing to withdraw");
        escrow.withdraw(); // second — must revert
    }

    // ============================================================
    //  raiseDispute()
    // ============================================================

    function test_RaiseDispute_ByTenant() public {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW + 1);

        vm.prank(tenant);
        escrow.raiseDispute();

        assertTrue(escrow.status() == EscrowRent.Status.Disputed);
    }

    function test_RaiseDispute_ByLandlord() public {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW + 1);

        vm.prank(landlord);
        escrow.raiseDispute();

        assertTrue(escrow.status() == EscrowRent.Status.Disputed);
    }

    function test_RaiseDispute_EmitsEvent() public {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW + 1);

        vm.expectEmit(true, false, false, true);
        emit EscrowRent.DisputeRaised(tenant, block.timestamp);

        vm.prank(tenant);
        escrow.raiseDispute();
    }

    function test_RaiseDispute_Revert_TooEarly() public {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW - 1);

        vm.prank(tenant);
        vm.expectRevert("Too early to raise dispute");
        escrow.raiseDispute();
    }

    function test_RaiseDispute_Revert_NotParty() public {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW + 1);

        vm.prank(stranger);
        vm.expectRevert("Not a party");
        escrow.raiseDispute();
    }

    function test_RaiseDispute_Revert_WrongStatus() public {
        vm.warp(endDate - DISPUTE_WINDOW + 1);

        vm.prank(tenant);
        vm.expectRevert("Invalid status for this action");
        escrow.raiseDispute();
    }

    // ============================================================
    //  resolveDispute()
    // ============================================================

    function test_ResolveDispute_FullToLandlord() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(TOTAL, 0);

        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(landlord), TOTAL);
        assertEq(escrow.withdrawable(tenant),   0);
        assertEq(escrow.fundedAmount(),          0);
    }

    function test_ResolveDispute_FullToTenant() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(0, TOTAL);

        assertEq(escrow.withdrawable(tenant),   TOTAL);
        assertEq(escrow.withdrawable(landlord), 0);
    }

    function test_ResolveDispute_Split() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(RENT, DEPOSIT);

        assertEq(escrow.withdrawable(landlord), RENT);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);
    }

    function test_ResolveDispute_EmitsEvent() public {
        _raiseDispute();

        uint256 expectedUnlock = block.timestamp + 48 hours;
        vm.expectEmit(true, false, false, true);
        emit EscrowRent.DisputeResolved(arbiter, RENT, DEPOSIT, expectedUnlock);

        vm.prank(arbiter);
        escrow.resolveDispute(RENT, DEPOSIT);
    }

    function test_ResolveDispute_Revert_InvalidAmounts() public {
        _raiseDispute();

        vm.prank(arbiter);
        vm.expectRevert("Amounts must sum to funded total");
        escrow.resolveDispute(RENT, RENT);
    }

    function test_ResolveDispute_Revert_NotArbiter() public {
        _raiseDispute();

        vm.prank(landlord);
        vm.expectRevert("Not arbiter");
        escrow.resolveDispute(TOTAL, 0);
    }

    function test_ResolveDispute_Revert_WrongStatus() public {
        _activateEscrow();

        vm.prank(arbiter);
        vm.expectRevert("Invalid status for this action");
        escrow.resolveDispute(TOTAL, 0);
    }

    // ============================================================
    //  receive() and fallback()
    // ============================================================

    function test_Receive_Reverts_PlainEtherTransfer() public {
        vm.prank(tenant);
        (bool ok,) = address(escrow).call{value: 1 ether}("");
        assertFalse(ok, "Plain ETH transfer should have reverted");
    }

    function test_Fallback_Reverts_DataCall() public {
        vm.prank(tenant);
        (bool ok,) = address(escrow).call{value: 0}(hex"deadbeef");
        assertFalse(ok, "Fallback with calldata should have reverted");
    }
}
