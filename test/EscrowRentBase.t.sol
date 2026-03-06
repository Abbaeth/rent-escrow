// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ================================================================
//  SHARED HELPER: Malicious tenant for reentrancy attack tests
// ================================================================
contract MaliciousTenant {
    EscrowRent public escrow;
    uint256 public attackCount;

    constructor(address _escrow) {
        escrow = EscrowRent(payable(_escrow));
    }

    /// @dev Re-point attacker at a newly deployed escrow after construction
    function setEscrow(address _escrow) external {
        escrow = EscrowRent(payable(_escrow));
    }

    function attack() external {
        escrow.withdraw();
    }

    receive() external payable {
        // Attempts re-entry — blocked by nonReentrant
        if (attackCount < 3 && address(escrow).balance > 0) {
            attackCount++;
            escrow.withdraw();
        }
    }
}

// ================================================================
//  BASE TEST CONTRACT
//  All test files inherit this to share actors, constants, setup,
//  and lifecycle helper functions.
// ================================================================
abstract contract EscrowRentBase is Test {

    // ── Actors ───────────────────────────────────────────────────
    address internal landlord;
    address internal tenant;
    address internal arbiter;
    address internal stranger;

    // ── Financial constants ──────────────────────────────────────
    uint256 internal constant RENT    = 1 ether;
    uint256 internal constant DEPOSIT = 0.5 ether;
    uint256 internal constant TOTAL   = RENT + DEPOSIT; // 1.5 ether

    // ── Time constants ────────────────────────────────────────────
    uint256 internal startDate;
    uint256 internal endDate;
    uint256 internal constant DURATION       = 30 days;
    uint256 internal constant GRACE_PERIOD   = 3 days;
    uint256 internal constant DISPUTE_WINDOW = 3 days;

    // ── Contract under test ──────────────────────────────────────
    EscrowRent internal escrow;

    // ────────────────────────────────────────────────────────────
    //  SETUP — runs before every test in every inheriting file
    // ────────────────────────────────────────────────────────────
    function setUp() public virtual {
        landlord = makeAddr("landlord");
        tenant   = makeAddr("tenant");
        arbiter  = makeAddr("arbiter");
        stranger = makeAddr("stranger");

        vm.deal(landlord, 10 ether);
        vm.deal(tenant,   10 ether);
        vm.deal(arbiter,  1 ether);
        vm.deal(stranger, 1 ether);

        vm.warp(1_000_000);

        startDate = block.timestamp + 1 days;
        endDate   = startDate + DURATION;

        vm.prank(landlord);
        escrow = new EscrowRent(
            tenant,
            arbiter,
            RENT,
            DEPOSIT,
            startDate,
            endDate
        );
    }

    // ────────────────────────────────────────────────────────────
    //  LIFECYCLE HELPERS
    //  Reusable state-transition shortcuts used across all files.
    // ────────────────────────────────────────────────────────────

    /// @dev Fund the contract fully (Created → Funded)
    function _fullFund() internal {
        vm.prank(tenant);
        escrow.fund{value: TOTAL}();
    }

    /// @dev Fund fully then activate (Created → Funded → Active)
    function _activateEscrow() internal {
        _fullFund();
        vm.warp(startDate);
        vm.prank(landlord);
        escrow.activate();
    }

    /// @dev Activate then warp into dispute window and raise dispute (→ Disputed)
    function _raiseDispute() internal {
        _activateEscrow();
        vm.warp(endDate - DISPUTE_WINDOW + 1);
        vm.prank(tenant);
        escrow.raiseDispute();
    }
}
