// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EscrowRentBase} from "./EscrowRentBase.t.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ================================================================
//  EDGE CASE TESTS
//  Boundary conditions, off-by-one timestamps, zero-value splits,
//  and arithmetic overflow checks.
// ================================================================
contract EscrowRentEdgeCaseTest is EscrowRentBase {

    // ============================================================
    //  Funding edge cases
    // ============================================================

    /// @notice [PATCH] Exact TOTAL succeeds — anything else reverts
    function test_Edge_FundExactTotal_Succeeds() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
        assertTrue(escrow.status() == EscrowRent.Status.Funded);
        assertEq(escrow.fundedAmount(), TOTAL);
    }

    /// @notice [PATCH] One wei under TOTAL reverts
    function test_Edge_FundOneLessThanTotal_Reverts() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: TOTAL - 1}();
        assertEq(address(escrow).balance, 0); // no ETH locked
    }

    /// @notice [PATCH] One wei over TOTAL reverts
    function test_Edge_FundOneOverTotal_Reverts() public {
        vm.prank(tenant);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: TOTAL + 1}();
    }

    // ============================================================
    //  Activation timestamp boundaries
    // ============================================================

    /// @notice activate() succeeds when called at exactly START_DATE
    function test_Edge_Activate_ExactlyAtStartDate() public {
        _fullFund();
        vm.warp(startDate); // exactly == START_DATE (require >= START_DATE)

        vm.prank(landlord);
        escrow.activate();
        assertTrue(escrow.status() == EscrowRent.Status.Active);
    }

    /// @notice activate() reverts when called at exactly END_DATE (require < END_DATE)
    function test_Edge_Activate_ExactlyAtEndDate_Reverts() public {
        _fullFund();
        vm.warp(endDate); // timestamp == END_DATE

        vm.prank(landlord);
        vm.expectRevert("Rental period expired");
        escrow.activate();
    }

    // ============================================================
    //  Completion timestamp boundaries
    // ============================================================

    /// @notice complete() succeeds when called at exactly END_DATE (require >= END_DATE)
    function test_Edge_Complete_ExactlyAtEndDate() public {
        _activateEscrow();
        vm.warp(endDate); // exactly == END_DATE

        vm.prank(tenant);
        escrow.complete();
        assertTrue(escrow.status() == EscrowRent.Status.Completed);
    }

    // ============================================================
    //  Dispute window boundaries
    // ============================================================

    /// @notice raiseDispute() succeeds at exactly the dispute window start
    function test_Edge_RaiseDispute_ExactlyAtWindowStart() public {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW); // exactly at window start

        vm.prank(tenant);
        escrow.raiseDispute();
        assertTrue(escrow.status() == EscrowRent.Status.Disputed);
    }

    /// @notice raiseDispute() reverts one second before the dispute window
    function test_Edge_RaiseDispute_OneSecondBeforeWindow() public {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW - 1);

        vm.prank(tenant);
        vm.expectRevert("Too early to raise dispute");
        escrow.raiseDispute();
    }

    // ============================================================
    //  Grace period boundaries
    // ============================================================

    /// @notice cancelIfUnactivated() succeeds at exactly the grace period boundary
    function test_Edge_CancelIfUnactivated_ExactGraceBoundary() public {
        _fullFund();
        vm.warp(startDate + GRACE_PERIOD); // exactly == START_DATE + GRACE_PERIOD

        vm.prank(tenant);
        escrow.cancelIfUnactivated();
        assertTrue(escrow.status() == EscrowRent.Status.Cancelled);
    }

    // ============================================================
    //  Dispute resolution edge cases
    // ============================================================

    /// @notice Arbiter awards full amount to landlord — tenant gets nothing
    function test_Edge_ResolveDispute_ZeroToTenant() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(TOTAL, 0);

        assertEq(escrow.withdrawable(landlord), TOTAL);
        assertEq(escrow.withdrawable(tenant),   0);

        // Warp past the 48h timelock so we reach the balance check, not the lock check
        vm.warp(block.timestamp + 48 hours);

        // Tenant has zero withdrawable — should get "Nothing to withdraw"
        vm.prank(tenant);
        vm.expectRevert("Nothing to withdraw");
        escrow.withdraw();
    }

    /// @notice Solidity 0.8 auto-reverts on uint256 overflow in resolveDispute args
    function test_Edge_ResolveDispute_OverflowReverts() public {
        _raiseDispute();

        vm.prank(arbiter);
        vm.expectRevert(); // arithmetic overflow panic
        escrow.resolveDispute(type(uint256).max, 1);
    }

    // ============================================================
    //  Withdrawal accounting
    // ============================================================

    /// @notice Landlord only gets RENT — never has access to DEPOSIT
    function test_Edge_Landlord_CannotWithdrawDeposit() public {
        _activateEscrow();
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();

        assertEq(escrow.withdrawable(landlord), RENT);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);

        // Landlord withdraws their share — contract still holds DEPOSIT for tenant
        vm.prank(landlord);
        escrow.withdraw();
        assertEq(address(escrow).balance, DEPOSIT);

        // Tenant withdraws the rest — contract fully drained
        vm.prank(tenant);
        escrow.withdraw();
        assertEq(address(escrow).balance, 0);
    }
}
