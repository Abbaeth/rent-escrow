// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {EscrowRent} from "../src/EscrowRent.sol";

// ============================================================
//  ESCROWRENT DEPLOYMENT SCRIPT
//
//  Usage (Sepolia):
//    forge script script/Deploy.s.sol \
//      --rpc-url $SEPOLIA_RPC_URL \
//      --broadcast \
//      --verify \
//      --etherscan-api-key $ETHERSCAN_API_KEY \
//      -vvvv
//
//  Required environment variables (.env):
//    PRIVATE_KEY          — deployer wallet private key (landlord)
//    SEPOLIA_RPC_URL      — Sepolia RPC endpoint (Alchemy / Infura)
//    ETHERSCAN_API_KEY    — for contract verification
//
//  Deployment parameters (edit before deploying):
//    TENANT_ADDRESS       — wallet address of the tenant
//    ARBITER_ADDRESS      — wallet address of the agreed arbiter
//    RENT_AMOUNT          — rent in wei
//    DEPOSIT_AMOUNT       — deposit in wei
//    START_DATE           — Unix timestamp for rental start
//    END_DATE             — Unix timestamp for rental end
// ============================================================

contract DeployEscrowRent is Script {

    // ── Deployment parameters ────────────────────────────────
    // Edit these before deploying.
    // All amounts are in wei (1 ether = 1e18 wei).

    address constant TENANT_ADDRESS  = address(0x894E3ac6eaf4957dAE16d78eff7C9239280dF6B4); // TODO: set tenant address
    address constant ARBITER_ADDRESS = address(0xA35822857467eC859863747006513D9cDea5Dce0); // TODO: set arbiter address

    uint256 constant RENT_AMOUNT    = 0.1 ether;  // TODO: set rent amount
    uint256 constant DEPOSIT_AMOUNT = 0.05 ether; // TODO: set deposit amount

    // Timestamps — generate with:
    //   date -d "2025-06-01" +%s   (Linux)
    //   date -j -f "%Y-%m-%d" "2025-06-01" +%s   (macOS)
    uint256 constant START_DATE = 1773400286; // TODO: set start Unix timestamp
    uint256 constant END_DATE   = 1775992286; // TODO: set end Unix timestamp

    // ── Run ──────────────────────────────────────────────────

    function run() external returns (EscrowRent escrow) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Validate all parameters are set before broadcasting
        _validateParams(deployer);

        console2.log("======================================");
        console2.log("  EscrowRent Deployment");
        console2.log("======================================");
        console2.log("Network:         Sepolia");
        console2.log("Deployer:       ", deployer);
        console2.log("Tenant:         ", TENANT_ADDRESS);
        console2.log("Arbiter:        ", ARBITER_ADDRESS);
        console2.log("Rent (wei):     ", RENT_AMOUNT);
        console2.log("Deposit (wei):  ", DEPOSIT_AMOUNT);
        console2.log("Total (wei):    ", RENT_AMOUNT + DEPOSIT_AMOUNT);
        console2.log("Start date:     ", START_DATE);
        console2.log("End date:       ", END_DATE);
        console2.log("Duration (days):", (END_DATE - START_DATE) / 1 days);
        console2.log("--------------------------------------");

        vm.startBroadcast(deployerPrivateKey);

        escrow = new EscrowRent(
            TENANT_ADDRESS,
            ARBITER_ADDRESS,
            RENT_AMOUNT,
            DEPOSIT_AMOUNT,
            START_DATE,
            END_DATE
        );

        vm.stopBroadcast();

        console2.log("Contract deployed at:", address(escrow));
        console2.log("Status:              ", uint256(escrow.status())); // 0 = Created
        console2.log("======================================");
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Share contract address with tenant:", address(escrow));
        console2.log("2. Tenant calls fund() with exactly", RENT_AMOUNT + DEPOSIT_AMOUNT, "wei");
        console2.log("3. Landlord calls activate() after START_DATE:", START_DATE);
        console2.log("");
        console2.log("View on Etherscan:");
        console2.log("https://sepolia.etherscan.io/address/", address(escrow));
    }

    // ── Pre-flight validation ────────────────────────────────

    function _validateParams(address deployer) internal view {
        require(TENANT_ADDRESS  != address(0), "Deploy: tenant address not set");
        require(ARBITER_ADDRESS != address(0), "Deploy: arbiter address not set");
        require(TENANT_ADDRESS  != ARBITER_ADDRESS, "Deploy: tenant and arbiter must differ");

        require(deployer != TENANT_ADDRESS,  "Deploy: deployer cannot be tenant");
        require(deployer != ARBITER_ADDRESS, "Deploy: deployer cannot be arbiter");

        require(RENT_AMOUNT    > 0, "Deploy: rent amount not set");
        require(DEPOSIT_AMOUNT > 0, "Deploy: deposit amount not set");

        require(START_DATE > 0,          "Deploy: start date not set");
        require(END_DATE   > START_DATE, "Deploy: end date must be after start");
        require(START_DATE > block.timestamp, "Deploy: start date must be in future");

        uint256 DISPUTE_WINDOW = 3 days;
        require(
            END_DATE - START_DATE > DISPUTE_WINDOW,
            "Deploy: rental duration must exceed 3-day dispute window"
        );

        console2.log("Pre-flight checks passed.");
    }
}
