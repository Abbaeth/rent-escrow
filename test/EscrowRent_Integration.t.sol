// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EscrowRentBase} from "./EscrowRentBase.t.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ================================================================
//  INTEGRATION TESTS
//  Full end-to-end lifecycle flows. Each test walks through
//  multiple state transitions from deployment to final withdrawal,
//  verifying the system behaves correctly as a whole.
// ================================================================
contract EscrowRentIntegrationTest is EscrowRentBase {

    // ============================================================
    //  Happy Path — normal rental lifecycle
    // ============================================================

    /// @notice deploy → fund → activate → complete → both parties withdraw
    function test_Integration_HappyPath_FullLifecycle() public {
        // 1. Deployed in setUp — verify initial state
        assertTrue(escrow.status() == EscrowRent.Status.Created);
        assertEq(address(escrow).balance, 0);

        // 2. Tenant funds in full
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
        assertTrue(escrow.status() == EscrowRent.Status.Funded);
        assertEq(address(escrow).balance, TOTAL);

        // 3. Landlord activates on start date
        vm.warp(startDate);
        vm.prank(landlord);
        escrow.activate();
        assertTrue(escrow.status() == EscrowRent.Status.Active);

        // 4. Rental period ends — either party calls complete
        vm.warp(endDate + 1);
        vm.prank(landlord);
        escrow.complete();
        assertTrue(escrow.status() == EscrowRent.Status.Completed);
        assertEq(escrow.withdrawable(landlord), RENT);
        assertEq(escrow.withdrawable(tenant),   DEPOSIT);

        // 5. Both parties withdraw their correct shares
        uint256 tenantBefore   = tenant.balance;
        uint256 landlordBefore = landlord.balance;

        vm.prank(tenant);
        escrow.withdraw();

        vm.prank(landlord);
        escrow.withdraw();

        assertEq(tenant.balance,   tenantBefore   + DEPOSIT);
        assertEq(landlord.balance, landlordBefore + RENT);

        // 6. Contract is fully drained
        assertEq(address(escrow).balance, 0);
    }

    // ============================================================
    //  Dispute Path — arbiter resolves mid-rental disagreement
    // ============================================================

    /// @notice fund → activate → dispute → arbiter resolves → both withdraw after timelock
    function test_Integration_DisputePath_FullLifecycle() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();

        vm.warp(startDate);
        vm.prank(landlord);
        escrow.activate();
        assertTrue(escrow.status() == EscrowRent.Status.Active);

        // Landlord raises dispute near end date
        vm.warp(endDate - DISPUTE_WINDOW + 1);
        vm.prank(landlord);
        escrow.raiseDispute();
        assertTrue(escrow.status() == EscrowRent.Status.Disputed);

        // Arbiter awards rent to landlord, deposit back to tenant
        vm.prank(arbiter);
        escrow.resolveDispute(RENT, DEPOSIT);
        assertTrue(escrow.status() == EscrowRent.Status.Completed);

        // Must wait 48h timelock before withdrawing
        vm.warp(block.timestamp + 48 hours);

        vm.prank(landlord);
        escrow.withdraw();
        vm.prank(tenant);
        escrow.withdraw();

        assertEq(address(escrow).balance, 0);
    }

    /// @notice Arbiter awards everything to tenant (e.g. landlord breached)
    function test_Integration_DisputePath_FullAwardToTenant() public {
        _raiseDispute();

        vm.prank(arbiter);
        escrow.resolveDispute(0, TOTAL);

        // Wait out the 48h timelock
        vm.warp(block.timestamp + 48 hours);

        vm.prank(tenant);
        escrow.withdraw();

        assertEq(address(escrow).balance, 0);
        assertEq(escrow.withdrawable(landlord), 0);
    }

    // ============================================================
    //  Cancellation Paths
    // ============================================================

    /// @notice Landlord never activates — tenant cancels after grace period expires
    function test_Integration_CancelIfUnactivated_Path() public {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
        assertTrue(escrow.status() == EscrowRent.Status.Funded);

        // Landlord is unresponsive — grace period expires
        vm.warp(startDate + GRACE_PERIOD + 1);

        vm.prank(tenant);
        escrow.cancelIfUnactivated();
        assertTrue(escrow.status() == EscrowRent.Status.Cancelled);
        assertEq(escrow.withdrawable(tenant), TOTAL);
        assertEq(escrow.fundedAmount(), 0);

        uint256 before = tenant.balance;
        vm.prank(tenant);
        escrow.withdraw();

        assertEq(tenant.balance, before + TOTAL);
        assertEq(address(escrow).balance, 0);
    }
}
