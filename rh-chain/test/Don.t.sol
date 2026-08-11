// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Don} from "../src/market/Don.sol";
import {SeatVault} from "../src/market/SeatVault.sol";
import {ISeatHook} from "../src/market/ISeatHook.sol";
import {ISeatArt} from "../src/market/ISeatArt.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// Records every hook invocation so tests can assert exactly when the Don notifies its Bell.
contract RecordingHook is ISeatHook {
    uint256 public calls;
    uint256 public lastId;
    address public lastFrom;
    address public lastTo;

    function onSeatTransfer(uint256 id, address from, address to) external {
        calls++;
        lastId = id;
        lastFrom = from;
        lastTo = to;
    }
}

contract FixedArt is ISeatArt {
    function tokenURI(uint256) external pure returns (string memory) {
        return "ipfs://don";
    }
}

contract DonTest is Test {
    Don don;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address treasury = address(0x7EE);

    uint96 constant ROYALTY_BPS = 500; // 5%

    bytes32 constant COMBO_A = keccak256("fedora/cigar/pinstripe");
    bytes32 constant COMBO_B = keccak256("homburg/ring/trench");

    function setUp() public {
        // test = minter; treasury is the royalty receiver at 5%. Tiny cap to exercise SoldOut.
        don = new Don("Essey Don", "DON", 3, address(this), treasury, ROYALTY_BPS);
    }

    // ---------------------------------------------------------------- mint

    function test_MintSetsTraitsAndStandsUpVault() public {
        uint256 id = don.mint(alice, COMBO_A);
        assertEq(id, 1, "ids are 1-based");
        assertEq(don.ownerOf(id), alice);
        assertEq(don.traits(id), COMBO_A, "trait commitment stored");
        assertFalse(don.locked(id), "mutable until staked");

        address vault = don.vaultOf(id);
        assertGt(vault.code.length, 0, "vault deployed in the mint tx");
        assertEq(SeatVault(payable(vault)).owner(), alice, "vault owned by the Don's holder");

        // The vault is bound in the same tx — nobody can initialize it to a different token.
        vm.expectRevert(SeatVault.AlreadyInitialized.selector);
        SeatVault(payable(vault)).initialize(address(0xBAD), 99);
    }

    function test_OnlyMinterMints() public {
        vm.prank(alice);
        vm.expectRevert(Don.NotMinter.selector);
        don.mint(alice, COMBO_A);
    }

    function test_MintCapHardStops() public {
        don.mint(alice, bytes32(uint256(1)));
        don.mint(alice, bytes32(uint256(2)));
        don.mint(alice, bytes32(uint256(3)));
        vm.expectRevert(Don.SoldOut.selector);
        don.mint(alice, bytes32(uint256(4)));
        assertEq(don.totalMinted(), 3);
    }

    function test_VaultAddressDeterministicBeforeMint() public {
        address predicted = don.vaultOf(7); // never minted
        assertEq(predicted.code.length, 0, "not deployed yet");
        // Mint up to id 3 (the cap): each minted id's vault matches its pre-computable address.
        uint256 id = don.mint(alice, COMBO_A);
        assertEq(don.vaultOf(id), don.vaultOf(id), "stable");
        assertGt(don.vaultOf(id).code.length, 0);
        assertEq(predicted, don.vaultOf(7), "prediction is pure - unchanged by unrelated mints");
    }

    // ---------------------------------------------------------------- reroll & lock

    function test_RerollMinterGatedAndMutableOnly() public {
        uint256 id = don.mint(alice, COMBO_A);

        vm.prank(alice); // even the OWNER can't reroll directly — only through the distributor
        vm.expectRevert(Don.NotMinter.selector);
        don.reroll(id, COMBO_B);

        don.reroll(id, COMBO_B);
        assertEq(don.traits(id), COMBO_B, "traits re-committed");

        vm.expectRevert(Don.NonexistentToken.selector);
        don.reroll(99, COMBO_B);
    }

    function test_LockIsOneWayAndFreezesTraits() public {
        uint256 id = don.mint(alice, COMBO_A);
        don.lockTraits(id);
        assertTrue(don.locked(id));

        vm.expectRevert(Don.TraitsLocked.selector);
        don.reroll(id, COMBO_B); // art frozen forever

        vm.expectRevert(Don.TraitsLocked.selector);
        don.lockTraits(id); // one-way transition is explicit

        vm.expectRevert(Don.NonexistentToken.selector);
        don.lockTraits(99);
    }

    function test_LockedDonStillTransfers() public {
        uint256 id = don.mint(alice, COMBO_A);
        don.lockTraits(id);
        vm.prank(alice);
        don.transferFrom(alice, bob, id); // the lock freezes ART, not ownership
        assertEq(don.ownerOf(id), bob);
        assertTrue(don.locked(id), "lock survives transfer");
    }

    // ---------------------------------------------------------------- hook & art wiring

    function test_HookFiresOnTransfersNotMints() public {
        RecordingHook hook = new RecordingHook();
        don.setHook(address(hook));

        uint256 id = don.mint(alice, COMBO_A);
        assertEq(hook.calls(), 0, "mints don't notify - fresh state needs no clearing");

        vm.prank(alice);
        don.transferFrom(alice, bob, id);
        assertEq(hook.calls(), 1, "true ownership transfer notifies");
        assertEq(hook.lastId(), id);
        assertEq(hook.lastFrom(), alice);
        assertEq(hook.lastTo(), bob);
    }

    function test_HookWiringOneShotAndContractOnly() public {
        vm.expectRevert(Don.HookNotContract.selector);
        don.setHook(address(0xBAD)); // codeless hook would brick every transfer

        RecordingHook hook = new RecordingHook();
        don.setHook(address(hook));
        vm.expectRevert(Don.HookAlreadySet.selector);
        don.setHook(address(hook));

        vm.prank(alice);
        vm.expectRevert(Don.NotMinter.selector);
        Don(don).setHook(address(hook));
    }

    // ---------------------------------------------------------------- lien (loan collateral)

    function test_LienManagerWiringOneShotAndContractOnly() public {
        vm.expectRevert(Don.LienManagerNotContract.selector);
        don.setLienManager(address(0xBAD));

        don.setLienManager(address(this)); // the test doubles as the facility
        vm.expectRevert(Don.LienManagerAlreadySet.selector);
        don.setLienManager(address(this));

        vm.prank(alice);
        vm.expectRevert(Don.NotMinter.selector);
        don.setLienManager(address(this));
    }

    function test_LienBlocksEveryTransferPath() public {
        don.setLienManager(address(this));
        uint256 id = don.mint(alice, COMBO_A);
        don.setLien(id, true);

        vm.prank(alice); // owner can't move their own liened Don
        vm.expectRevert(Don.LienActive.selector);
        don.transferFrom(alice, bob, id);

        vm.prank(alice);
        don.approve(bob, id); // approvals still settable, but useless while liened
        vm.prank(bob);
        vm.expectRevert(Don.LienActive.selector);
        don.transferFrom(alice, bob, id);

        don.setLien(id, false); // released -> transfers free again
        vm.prank(alice);
        don.transferFrom(alice, bob, id);
        assertEq(don.ownerOf(id), bob);
    }

    function test_LienManagerCanSeizeOnlyLienedDons() public {
        don.setLienManager(address(this));
        uint256 pledged = don.mint(alice, COMBO_A);
        uint256 free = don.mint(alice, COMBO_B);
        don.setLien(pledged, true);

        don.transferFrom(alice, bob, pledged); // facility moves a LIENED Don without approval (seizure)
        assertEq(don.ownerOf(pledged), bob);

        vm.expectRevert(); // ERC721InsufficientApproval - no authority over unliened Dons
        don.transferFrom(alice, bob, free);
    }

    function test_SetLienGuards() public {
        don.setLienManager(address(this));
        vm.expectRevert(Don.NonexistentToken.selector);
        don.setLien(99, true);

        uint256 id = don.mint(alice, COMBO_A);
        vm.prank(alice);
        vm.expectRevert(Don.NotLienManager.selector);
        don.setLien(id, true);
    }

    function test_ArtWiringOneShotAndRendered() public {
        uint256 id = don.mint(alice, COMBO_A);
        assertEq(don.tokenURI(id), "", "no renderer wired -> empty URI");

        vm.expectRevert(Don.ArtNotContract.selector);
        don.setArt(address(0xBAD));

        FixedArt art = new FixedArt();
        don.setArt(address(art));
        assertEq(don.tokenURI(id), "ipfs://don");

        vm.expectRevert(Don.ArtAlreadySet.selector);
        don.setArt(address(art));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        don.tokenURI(99);
    }

    // ---------------------------------------------------------------- royalties (ERC-2981)

    function test_RoyaltyInfoReturnsTreasuryAndFivePercent() public view {
        uint256 salePrice = 10 ether;
        (address receiver, uint256 amount) = don.royaltyInfo(1, salePrice);
        assertEq(receiver, treasury, "royalty routes to the treasury");
        assertEq(amount, (salePrice * ROYALTY_BPS) / 10_000, "5% of the sale");
        assertEq(amount, 0.5 ether, "10 ETH sale -> 0.5 ETH royalty");
    }

    function test_SupportsInterfaceDiamond() public view {
        assertTrue(don.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(don.supportsInterface(0x5b5e139f), "ERC-721 Metadata");
        assertTrue(don.supportsInterface(0x2a55205a), "ERC-2981 royalties");
        assertTrue(don.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(don.supportsInterface(0xdeadbeef), "a random id is unsupported");
    }

    function test_ConstructorRejectsRoyaltyOverCap() public {
        vm.expectRevert(Don.BadRoyalty.selector);
        new Don("Essey Don", "DON", 3, address(this), treasury, 1001); // > 10% ceiling
    }

    function test_SetDefaultRoyaltyMinterGatedAndCapped() public {
        // minter (this test) may re-point receiver + rate
        vm.expectEmit(true, false, false, true, address(don));
        emit Don.DefaultRoyaltySet(bob, 250);
        don.setDefaultRoyalty(bob, 250);
        (address receiver, uint256 amount) = don.royaltyInfo(1, 10_000);
        assertEq(receiver, bob, "receiver re-pointed");
        assertEq(amount, 250, "2.5% of 10000");

        // capped at 10%
        vm.expectRevert(Don.BadRoyalty.selector);
        don.setDefaultRoyalty(bob, 1001);

        // non-minter rejected
        vm.prank(alice);
        vm.expectRevert(Don.NotMinter.selector);
        don.setDefaultRoyalty(alice, 100);
    }

    // ---------------------------------------------------------------- contractURI (ERC-7572)

    function test_ContractURIDefaultsEmptyAndSetsWithEvent() public {
        assertEq(don.contractURI(), "", "empty until set post-deploy");

        vm.expectEmit(false, false, false, false, address(don));
        emit Don.ContractURIUpdated();
        don.setContractURI("ipfs://collection");
        assertEq(don.contractURI(), "ipfs://collection");

        vm.prank(alice);
        vm.expectRevert(Don.NotMinter.selector);
        don.setContractURI("ipfs://evil");
    }
}
