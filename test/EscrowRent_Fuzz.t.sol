// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EscrowRentBase} from "./EscrowRentBase.t.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ================================================================
//  FUZZ TESTS
//  Property-based tests. The fuzzer generates random inputs across
//  each run — the goal is to prove invariants hold for ALL inputs,
//  not just specific hand-picked values.
//
//  Run with: forge test --match-contract EscrowRentFuzzTest -vv
//  Increase runs: forge test --fuzz-runs 10000
// ================================================================
contract EscrowRentFuzzTest is EscrowRentBase {

    // ============================================================
    //  Funding invariants
    // ============================================================

    /// @notice [PATCH] Only exact TOTAL is accepted — any other amount reverts
    function testFuzz_Fund_OnlyExactTotalSucceeds(uint256 amount) public {
        vm.assume(amount != TOTAL);
        amount = bound(amount, 0, 100_000 ether);

        hoax(tenant, amount);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: amount}();

        // No ETH ever locked for wrong amounts
        assertEq(escrow.fundedAmount(), 0);
        assertEq(address(escrow).balance, 0);
    }

    /// @notice [PATCH] Overfunding always reverts with correct message
    function testFuzz_Fund_Overfunding_AlwaysReverts(uint256 excess) public {
        excess = bound(excess, 1, type(uint256).max - TOTAL);
        uint256 sendAmount = TOTAL + excess;
        if (sendAmount > 100_000 ether) sendAmount = TOTAL + 1;

        hoax(tenant, sendAmount);
        vm.expectRevert("Must fund exact total amount");
        escrow.fund{value: sendAmount}();
    }

    // ============================================================
    //  Dispute resolution invariants
    // ============================================================

    /// @notice resolveDispute always distributes exactly fundedAmount — no ETH created or lost
    function testFuzz_ResolveDispute_MustSumToFunded(uint256 landlordAmt) public {
        _raiseDispute();
        landlordAmt = bound(landlordAmt, 0, TOTAL);
        uint256 tenantAmt = TOTAL - landlordAmt;

        vm.prank(arbiter);
        escrow.resolveDispute(landlordAmt, tenantAmt);

        assertEq(escrow.withdrawable(landlord) + escrow.withdrawable(tenant), TOTAL);
        assertEq(escrow.fundedAmount(), 0);
    }

    /// @notice resolveDispute always reverts when amounts don't sum to fundedAmount
    function testFuzz_ResolveDispute_Reverts_WhenSumWrong(
        uint128 landlordAmt,
        uint128 tenantAmt
    ) public {
        _raiseDispute();
        vm.assume(uint256(landlordAmt) + uint256(tenantAmt) != TOTAL);

        vm.prank(arbiter);
        vm.expectRevert("Amounts must sum to funded total");
        escrow.resolveDispute(uint256(landlordAmt), uint256(tenantAmt));
    }

    // ============================================================
    //  Withdrawal invariants
    // ============================================================

    /// @notice withdraw() always zeroes the caller's withdrawable balance in one call
    function testFuzz_Withdraw_AlwaysZeroesBalance(uint256 landlordAmt) public {
        _raiseDispute();
        landlordAmt = bound(landlordAmt, 0, TOTAL);
        uint256 tenantAmt = TOTAL - landlordAmt;

        vm.prank(arbiter);
        escrow.resolveDispute(landlordAmt, tenantAmt);

        // Wait out the 48h timelock
        vm.warp(block.timestamp + 48 hours);

        if (landlordAmt > 0) {
            uint256 before = landlord.balance;
            vm.prank(landlord);
            escrow.withdraw();
            assertEq(escrow.withdrawable(landlord), 0);
            assertEq(landlord.balance, before + landlordAmt);
        }

        if (tenantAmt > 0) {
            uint256 before = tenant.balance;
            vm.prank(tenant);
            escrow.withdraw();
            assertEq(escrow.withdrawable(tenant), 0);
            assertEq(tenant.balance, before + tenantAmt);
        }
    }

    // ============================================================
    //  Accounting invariant
    // ============================================================

    /// @notice Contract ETH balance always equals sum of all withdrawable balances
    function testFuzz_Accounting_BalanceMatchesWithdrawables(uint256 landlordAmt) public {
        _raiseDispute();
        landlordAmt = bound(landlordAmt, 0, TOTAL);
        uint256 tenantAmt = TOTAL - landlordAmt;

        vm.prank(arbiter);
        escrow.resolveDispute(landlordAmt, tenantAmt);

        uint256 totalWithdrawable = escrow.withdrawable(landlord) + escrow.withdrawable(tenant);
        assertEq(address(escrow).balance, totalWithdrawable);
    }

    // ============================================================
    //  Access control invariant
    // ============================================================

    /// @notice No arbitrary address can ever call tenant- or landlord-gated functions
    function testFuzz_AccessControl_StrangerAlwaysReverts(address rando) public {
        vm.assume(rando != landlord);
        vm.assume(rando != tenant);
        vm.assume(rando != arbiter);
        vm.assume(rando != address(0));
        vm.deal(rando, TOTAL + 1 ether);

        hoax(rando, TOTAL);
        vm.expectRevert("Not tenant");
        escrow.fund{value: TOTAL}();

        vm.prank(rando);
        vm.expectRevert("Not tenant");
        escrow.cancel();

        vm.prank(rando);
        vm.expectRevert("Not landlord");
        escrow.activate();
    }

    // ============================================================
    //  Constructor invariant
    // ============================================================

    /// @notice Any valid future date range with duration > DISPUTE_WINDOW deploys successfully
    function testFuzz_Constructor_ValidDatesAlwaysSucceed(
        uint32 offsetStart,
        uint32 duration
    ) public {
        uint256 s = block.timestamp + bound(uint256(offsetStart), 0, 365 days);
        // [PATCH] Duration must be > DISPUTE_WINDOW (3 days)
        uint256 e = s + bound(uint256(duration), 3 days + 1, 365 days);

        vm.prank(landlord);
        EscrowRent newEscrow = new EscrowRent(
            tenant, arbiter, RENT, DEPOSIT, s, e
        );

        assertEq(newEscrow.START_DATE(), s);
        assertEq(newEscrow.END_DATE(),   e);
        assertTrue(newEscrow.status() == EscrowRent.Status.Created);
    }

}

