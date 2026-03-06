// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EscrowRentBase} from "./EscrowRentBase.t.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ============================================================
//  MALICIOUS CONTRACT — reentrancy attacker
//  Simulates a tenant whose receive() tries to re-enter
//  withdraw() to drain the contract more than once.
// ============================================================
contract MaliciousTenant {
    EscrowRent public escrow;
    uint256 public attackCount;

    constructor(address _escrow) {
        escrow = EscrowRent(payable(_escrow));
    }

    /// @dev Lets the test re-point attacker at the real escrow after deployment
    function setEscrow(address _escrow) external {
        escrow = EscrowRent(payable(_escrow));
    }

    function attack() external {
        escrow.withdraw();
    }

    receive() external payable {
        // On receiving ETH, immediately try to re-enter withdraw()
        // nonReentrant should block this completely
        if (attackCount < 3 && address(escrow).balance > 0) {
            attackCount++;
            escrow.withdraw();
        }
    }
}

// ============================================================
//  SECURITY TESTS
//  Reentrancy, access control proofs, and ETH rejection
// ============================================================
contract EscrowRent_SecurityTest is EscrowRentBase {

    /// @notice ReentrancyGuard blocks a malicious tenant from draining via withdraw()
    function test_Security_ReentrancyOnWithdraw_IsBlocked() public {
        vm.warp(1_000_000);
        uint256 s = block.timestamp + 1 days;
        uint256 e = s + DURATION;

        // Step 1: Deploy attacker with dummy address — real escrow not known yet
        MaliciousTenant attacker = new MaliciousTenant(address(0));

        // Step 2: Deploy escrow with attacker as the registered tenant
        vm.prank(landlord);
        EscrowRent realTarget = new EscrowRent(
            address(attacker), arbiter, RENT, DEPOSIT, s, e
        );

        // Step 3: Wire attacker to the real escrow
        attacker.setEscrow(address(realTarget));

        // Step 4: Fund exact TOTAL (→ Funded), landlord never activates,
        //         warp past grace period, tenant cancels via cancelIfUnactivated()
        //         This puts TOTAL into withdrawable[attacker] with status Cancelled
        vm.deal(address(attacker), 10 ether);
        vm.prank(address(attacker));
        realTarget.fund{value: TOTAL}();

        vm.warp(s + 3 days + 1); // past ACTIVATION_GRACE
        vm.prank(address(attacker));
        realTarget.cancelIfUnactivated();

        assertEq(realTarget.withdrawable(address(attacker)), TOTAL);
        assertTrue(realTarget.status() == EscrowRent.Status.Cancelled);

        // Step 5: Trigger the attack — receive() will attempt re-entrant withdraw()
        vm.prank(address(attacker));
        attacker.attack();

        // Step 6: Verify nonReentrant held — attacker got funds exactly once
        assertEq(realTarget.withdrawable(address(attacker)), 0);
        assertEq(attacker.attackCount(), 0);       // re-entry never executed
        assertEq(address(realTarget).balance, 0);  // drained correctly, not double-drained
    }

    /// @notice Plain ETH transfers to the contract are rejected
    function test_Security_PlainEtherTransfer_IsRejected() public {
        vm.prank(tenant);
        (bool ok,) = address(escrow).call{value: 1 ether}("");
        assertFalse(ok, "Plain ETH transfer should have reverted");
    }

    /// @notice Calls with arbitrary calldata (unknown function selectors) are rejected
    function test_Security_FallbackWithCalldata_IsRejected() public {
        vm.prank(tenant);
        (bool ok,) = address(escrow).call{value: 0}(hex"deadbeef");
        assertFalse(ok, "Unknown selector call should have reverted");
    }

    /// @notice Arbiter cannot double-resolve a dispute
    function test_Security_DoubleResolve_IsBlocked() public {
        _raiseDispute();
        vm.prank(arbiter);
        escrow.resolveDispute(RENT, DEPOSIT);

        // Status is now Completed — second call must revert
        vm.prank(arbiter);
        vm.expectRevert("Invalid status for this action");
        escrow.resolveDispute(RENT, DEPOSIT);
    }

    /// @notice Landlord cannot steal deposit via resolveDispute by passing wrong amounts
    function test_Security_ArbiterCannotOverpayLandlord() public {
        _raiseDispute();
        vm.prank(arbiter);
        vm.expectRevert("Amounts must sum to funded total");
        escrow.resolveDispute(TOTAL + 1, 0); // more than fundedAmount
    }

    /// @notice Stranger cannot resolve a dispute
    function test_Security_StrangerCannotResolveDispute() public {
        _raiseDispute();
        vm.prank(stranger);
        vm.expectRevert("Not arbiter");
        escrow.resolveDispute(TOTAL, 0);
    }
}
