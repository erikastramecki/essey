// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployDons} from "../script/DeployDons.s.sol";
import {IConverter} from "../src/market/IConverter.sol";

/// Broadcast-free dry run of the whole Dons v3 deploy: every one-shot wire lands, in order, and the
/// resulting topology matches the audited design.
contract DeployDonsTest is Test {
    function test_DeployAllWiresTheFullStack() public {
        DeployDons script = new DeployDons();
        ERC20Mock essey = new ERC20Mock();
        ERC20Mock usdg = new ERC20Mock();

        DeployDons.Config memory c;
        c.admin = address(script); // deployAll's one-shot wiring runs as the script contract
        c.treasury = address(0x7EA);
        c.seeder = address(0x5EED);
        c.essey = IERC20(address(essey));
        c.usdg = IERC20(address(usdg));
        c.converter = IConverter(address(0));
        c.defaultPayout = address(0);
        c.minRing = 10e6;
        c.reserveCap = 2722;
        c.rerollFee = 0.00075 ether;
        c.customFee = 0.0025 ether;
        c.donPrice = 300_000e18;
        // route env unset -> feeRouter skipped, feeSink = treasury (the interim the script logs loudly)

        DeployDons.Deployed memory d = script.deployAll(c);

        // Topology: the audited relationships, wired one-shot.
        assertEq(d.don.minter(), address(d.distributor), "distributor is the sole minter");
        assertEq(d.don.maxSupply(), 8888);
        assertEq(d.don.hook(), address(d.bell), "Bell clears tiers on transfer");
        assertEq(d.don.lienManager(), address(d.loan), "DonLoan is the one lien authority");
        assertEq(d.distributor.bell(), address(d.bell), "reroll gate + lockOnStake read this Bell");
        assertEq(d.distributor.feeSink(), c.treasury, "interim sink until the fee route is wired");
        assertEq(d.reserve.backedSupply(), 8888, "floor pinned to the on-chain cap");
        assertEq(address(d.exchange.floorSource()), address(d.reserve), "price tracks the live floor");
        assertEq(address(d.loan.reserve()), address(d.reserve), "loans priced by the same floor");
        assertEq(d.bell.tierCount(), 5, "the 666-motif 5-rung ladder");
        assertEq(address(d.feeRouter), address(0), "router skipped when route env unset");
        assertEq(d.distributor.reserveCap(), 2722, "500 team + 2,222 AMM float");
    }
}
