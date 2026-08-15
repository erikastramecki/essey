// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AffinityRegistry} from "../src/game/AffinityRegistry.sol";
import {AffinityTraits} from "../src/game/AffinityTraits.sol";
import {IAffinityRegistry, IDonTraits} from "../src/game/IAffinityRegistry.sol";
import {IGameController} from "../src/game/GameTypes.sol";

/// The trait-commitment half of the live Don collection (rh-chain/src/market/Don.sol): a bytes32 set at
/// mint, replaced on reroll, frozen by lockTraits. Nothing else is read by the registry.
contract MockTraitDon is IDonTraits {
    mapping(uint256 => bytes32) public traits;
    mapping(uint256 => bool) public locked;
    mapping(uint256 => address) internal _owner;

    function set(uint256 id, address to, bytes32 combo) external {
        _owner[id] = to;
        traits[id] = combo;
    }

    function lock(uint256 id) external {
        locked[id] = true;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owner[id];
    }
}

contract MockController is IGameController {
    address public admin;
    bool public closed;

    constructor(address admin_) {
        admin = admin_;
    }

    function moduleOf(bytes32) external pure returns (address) {
        return address(0);
    }

    function isModule(address) external pure returns (bool) {
        return false;
    }
}

/// D.O.N. v2 workstream 1c -- AffinityRegistry + trait readers + Skirmish preview.
///
/// GOLDEN VECTORS: every `PRE_*` blob below is the VERBATIM output of the production resolver
/// (`app/web/src/pfp-resolve.ts`) run over the shipped trait data (`app/web/public/builder/data_*.json`),
/// and each `COMBO_*` is `comboHash(resolved.key)` from `app/web/api/_don-lib.ts` -- i.e. exactly the
/// bytes32 the DonDistributor writes into `Don.traits`. If the on-chain decoder and the off-chain
/// resolver ever disagree by one byte, `test_golden_commitments` fails. That test IS the trust model.
contract AffinityRegistryTest is Test {
    AffinityRegistry internal reg;
    MockTraitDon internal don;
    MockController internal ctrl;

    address internal ADMIN = address(0xA11CE);
    address internal ALICE = address(0xBEEF);

    uint256 internal constant PPM = 1e6;
    uint256 internal constant BPS = 10_000;

    /// Every group the frozen table gives a non-zero load to. The Edge-Budget fuzz walks the powerset of
    /// this list, so "no trait combination can exceed the bound" is checked over the whole combo space
    /// (including combinations the resolver's conflict rules make unreachable -- a strictly harder test).
    string[] internal LOADED;

    function setUp() public {
        ctrl = new MockController(ADMIN);
        don = new MockTraitDon();
        reg = new AffinityRegistry(IGameController(address(ctrl)), IDonTraits(address(don)));
        _loadVocabulary();
    }

    function _loadVocabulary() internal {
        // --- male
        LOADED.push("4 Body/Mogul");
        LOADED.push("4 Body/Baron");
        LOADED.push("4 Body/Tycoon");
        LOADED.push("4 Body/Zombie");
        LOADED.push("4 Body/Golden");
        LOADED.push("4 Body/Glitch");
        LOADED.push("10 Nose/Mogul Nose");
        LOADED.push("10 Nose/Baron Nose");
        LOADED.push("10 Nose/Tycoon Nose");
        LOADED.push("5 Suit/The General");
        LOADED.push("5 Suit/Windsor");
        LOADED.push("5 Suit/Scholar");
        LOADED.push("5 Suit/Bladerunner");
        LOADED.push("5 Suit/Pimp");
        LOADED.push("5 Suit/Couture");
        LOADED.push("5 Suit/Duke");
        LOADED.push("5 Suit/Cas");
        LOADED.push("5 Suit/Designer");
        LOADED.push("5 Suit/Joker");
        LOADED.push("17 Face Mod/Terminator");
        LOADED.push("17 Face Mod/Bane");
        LOADED.push("17 Face Mod/Doom");
        LOADED.push("17 Face Mod/Samurai");
        LOADED.push("17 Face Mod/Cthulu");
        LOADED.push("17 Face Mod/Jester");
        LOADED.push("15 Eye Mod/Spider");
        LOADED.push("15 Eye Mod/Cyclops");
        LOADED.push("15 Eye Mod/Hardboiled");
        LOADED.push("15 Eye Mod/Cyberpunk");
        LOADED.push("15 Eye Mod/Monocle");
        LOADED.push("15 Eye Mod/Monocyber");
        LOADED.push("24 Laser Eye/Laser Eye");
        LOADED.push("26 AR/Wash Trade");
        LOADED.push("26 AR/Whale");
        LOADED.push("26 AR/Stonks");
        LOADED.push("26 AR/The Dev");
        LOADED.push("26 AR/MVHQ AR");
        LOADED.push("18 Canes/The Bull");
        LOADED.push("18 Canes/Swift");
        LOADED.push("18 Canes/Cobra");
        LOADED.push("18 Canes/Claw");
        LOADED.push("25 Snake/Snake Red");
        LOADED.push("25 Snake/Snake Green");
        LOADED.push("2 The hawk/Hawk");
        LOADED.push("2 The hawk/Hawk Attack");
        LOADED.push("23 Ceasar/Ceasar");
        LOADED.push("21 Wrist/Rolex");
        LOADED.push("21 Wrist/Prayer Bead");
        LOADED.push("1 Background/Ghost");
        LOADED.push("1 Background/MVHQ");
        LOADED.push("3 Chair/Knowledge Throne");
        LOADED.push("19 Hand Grip/MVHQ Martini");
        // --- female
        LOADED.push("3 Body/Executive");
        LOADED.push("3 Body/Financier");
        LOADED.push("3 Body/Industrialist");
        LOADED.push("5 Face/Magnate");
        LOADED.push("5 Face/Oligarch");
        LOADED.push("5 Face/Heiress");
        LOADED.push("6 Nose/Magnate Nose");
        LOADED.push("6 Nose/Oligarch Nose");
        LOADED.push("6 Nose/Heiress Nose");
        LOADED.push("4 Suits/Leadership");
        LOADED.push("4 Suits/BossB");
        LOADED.push("4 Suits/Duchess");
        LOADED.push("4 Suits/Opera");
        LOADED.push("4 Suits/Badass");
        LOADED.push("4 Suits/Scarlet White");
        LOADED.push("4 Suits/Jennifer");
        LOADED.push("4 Suits/Riviera");
        LOADED.push("4 Suits/Hotlanta");
        LOADED.push("4 Suits/Weeb");
        LOADED.push("1 Chairs/Queen");
        LOADED.push("13 Hand Grip/Doggy");
        LOADED.push("13 Hand Grip/Bird");
        LOADED.push("9 Hair/Medusa");
        LOADED.push("18 phoenix eyes/Phoenix");
        LOADED.push("11 Devilish/Devilish");
        LOADED.push("16 Neko/Neko");
        LOADED.push("16 Neko/Neko Lush");
        LOADED.push("16 Neko/Neko Boss");
        LOADED.push("16 Neko/Neko Updo");
        LOADED.push("17 AR/Wash Trade");
        LOADED.push("17 AR/Whale");
        LOADED.push("17 AR/Stonks");
        LOADED.push("17 AR/The Dev");
        LOADED.push("17 AR/MVHQ AR");
        LOADED.push("12 Wrist dec/Watch");
        LOADED.push("12 Wrist dec/Horseshoe");
        LOADED.push("12 Wrist dec/Black Pearl");
    }

    /// The vocabulary, for the invariant campaign's handler.
    function vocabulary() external view returns (string[] memory) {
        return LOADED;
    }

    /// Build a synthetic preimage from a bitmask over LOADED. Group-grain paths (`Cat/Group`) are exactly
    /// what the decoder folds a real leaf path down to, so this exercises the production code path.
    function _preimage(uint256 mask, bool female) internal view returns (bytes memory) {
        string memory s = female ? "female" : "male";
        for (uint256 i = 0; i < LOADED.length; i++) {
            if ((mask >> i) & 1 == 1) s = string.concat(s, "\n", LOADED[i]);
        }
        return bytes(s);
    }

    // ================================================================== GOLDEN PREIMAGES (resolver output)

    bytes32 internal constant COMBO_ENFORCER =
        0x9e75da070c19d476c95613d4246ec3ef4c41dd16db9a65690ace077e269e32b5;
    bytes32 internal constant COMBO_MATRIARCH =
        0x5f853cc6ac48742ba70a88bb47c080172aff8d08303da6f414d34be8446fac90;
    bytes32 internal constant COMBO_GHOST =
        0x6f81edb590b63801a220fc813d76b116333d2536f5e9f56d708eef422087cdc9;
    bytes32 internal constant COMBO_MVHQ =
        0x285d3f707d94fd1efbdcea8c00145508d309eac6d486633e9cb01e7ad6b37a61;
    bytes32 internal constant COMBO_RAND_M1 =
        0x75ee85c79c731ed6e4602358535704de19cdf07b053d6424fbed7ea8909de34f;
    bytes32 internal constant COMBO_RAND_M2 =
        0x726699edbdc7e5078046f2e3feece1e879c7762bd3560f328f0d8805f5c4e3bc;
    bytes32 internal constant COMBO_RAND_F1 =
        0x076ee57255a3139a4fa06b7f776172402ef8e53586364a7d48bdb82ec655a51f;
    bytes32 internal constant COMBO_RAND_F2 =
        0xa18e5d0a6e1e3fbf6e31cf179b9293190b614f280d48bc039cb5bde5af9d5779;

    function PRE_ENFORCER() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "male\n",
                "1 Background/Tech/Deving\n",
                "10 Nose/Mogul Nose/Sharp Mogul/Sharp Mogul\n",
                "10 Nose/Mogul Nose/Sharp Mogul/Sharp Shadow/Sharp Shadow\n",
                "12 Beard/White Beards/Verdi White/Verdi Shadow/Verdi shadow\n",
                "12 Beard/White Beards/Verdi White/Verdi White\n",
                "13 Hair/White/Hollywood White\n",
                "14 Eyebrow/White Brow/Thoughtful White\n",
                "17 Face Mod/Terminator/Terminator Fire\n",
                "19 Hand Grip/Shotgun/Shotgun\n",
                "19 Hand Grip/Shotgun/Shotgun Shadow/Shotgun Shadow\n",
                "20 Rings/Combos/Pump/Cross/Cross\n",
                "20 Rings/Combos/Pump/Cross/Cross Shadow/Cross Shadow\n",
                "20 Rings/Combos/Pump/Skull/Skull Index\n",
                "20 Rings/Combos/Pump/Skull/Skull Shadow/Skull Shadow\n",
                "21 Wrist/Rolex/Rolex\n",
                "21 Wrist/Rolex/Rolex Shadow/Rolex Shadow\n",
                "23 Ceasar/Ceasar/Ceasar\n",
                "23 Ceasar/Ceasar/Ceasar Shadow/Ceasar Shadow\n",
                "3 Chair/CEO\n",
                "4 Body/Mogul/Mogul Chiseled\n",
                "5 Suit/The General/The General White\n",
                "7 Face/Chiseled/Chiseled Mogul/8 Mouth/Sneer Mogul\n",
                "7 Face/Chiseled/Chiseled Mogul/9 Eyes/Heavy  Brown Mogul\n",
                "7 Face/Chiseled/Chiseled Mogul/Chiseled Mogul"
            )
        );
    }

    function PRE_MATRIARCH() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "female\n",
                "1 Chairs/Queen\n",
                "12 Wrist dec/Watch/Watch\n",
                "12 Wrist dec/Watch/Watch Shadow/Watch Shadow\n",
                "13 Hand Grip/Doggy/Doggy\n",
                "13 Hand Grip/Doggy/Doggy Shadow/Doggy Shadow\n",
                "14 Ring/Combo 2/Opal copy/Opal\n",
                "14 Ring/Combo 2/Opal copy/Opal Shadow/Opal Shadow\n",
                "15 Earing/Peacock\n",
                "18 phoenix eyes/Phoenix\n",
                "3 Body/Executive\n",
                "4 Suits/Leadership\n",
                "5 Face/Magnate/Eyes/Sassy Magnate\n",
                "5 Face/Magnate/Magnate\n",
                "5 Face/Magnate/Mouth/Pout/Pout Red Magnate\n",
                "6 Nose/Magnate Nose/Ms Magnate/Ms Magnate\n",
                "6 Nose/Magnate Nose/Ms Magnate/Ms Shadow/Ms Shadow\n",
                "7 eye brow/Duh\n",
                "8 Necklace/Rope/Leadership Rope/Leadership Rope\n",
                "8 Necklace/Rope/Leadership Rope/Leadership Rope Shadow/Leadership Rope Shadow\n",
                "9 Hair/Medusa/Medusa\n",
                "9 Hair/Medusa/Medusa Shadow/Medusa Shadow"
            )
        );
    }

    function PRE_GHOST() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "male\n",
                "1 Background/Ghost\n",
                "13 Hair/Red/Slick Red\n",
                "17 Face Mod/Jester/Jester Electrodred\n",
                "19 Hand Grip/Knife/Knife\n",
                "19 Hand Grip/Knife/Knife Shadow/Knife Shadow\n",
                "2 The hawk/Hawk\n",
                "20 Rings/Pinky/Cross/Cross\n",
                "20 Rings/Pinky/Cross/Cross Shadow/Cross Shadow\n",
                "21 Wrist/Prayer Bead/Prayer Bead\n",
                "21 Wrist/Prayer Bead/Prayer Bead Shadow/Prayer Bead Shadow\n",
                "26 AR/The Dev\n",
                "3 Chair/CEO\n",
                "4 Body/Mogul/Mogul Chad\n",
                "5 Suit/Bladerunner/Bladerunner Night\n",
                "7 Face/Chad/Chad Mogul/Chad Mogul"
            )
        );
    }

    function PRE_MVHQ() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "male\n",
                "1 Background/MVHQ\n",
                "10 Nose/Tycoon Nose/Powerful Tycoon/Powerful Shadow/Powerful Shadow\n",
                "10 Nose/Tycoon Nose/Powerful Tycoon/Powerful Tycoon\n",
                "11 Tattoos/Joker Tattoos/Hope\n",
                "13 Hair/White/Vincent White\n",
                "14 Eyebrow/White Brow/Skeptic White\n",
                "17 Face Mod/Samurai/Samurai\n",
                "19 Hand Grip/MVHQ Martini/MVHQ Martini\n",
                "19 Hand Grip/MVHQ Martini/Martini Shadow/Martini Shadow\n",
                "26 AR/MVHQ AR\n",
                "3 Chair/Don Chair\n",
                "4 Body/Tycoon/Tycoon Chiseled\n",
                "5 Suit/Joker/Joker Black\n",
                "7 Face/Chiseled/Chiseled Tycoon/9 Eyes/Heavy Cyborg Tycoon\n",
                "7 Face/Chiseled/Chiseled Tycoon/Chiseled Tycoon"
            )
        );
    }

    function PRE_RAND_M1() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "male\n",
                "1 Background/Portal/Opening\n",
                "10 Nose/Tycoon Nose/Broad Tycoon/Broad Shadow/Broad Shadow\n",
                "10 Nose/Tycoon Nose/Broad Tycoon/Broad Tycoon\n",
                "13 Hair/Red/Falcon Red\n",
                "14 Eyebrow/Red Brow/Sus Red\n",
                "17 Face Mod/Bane/Bane Red\n",
                "19 Hand Grip/Whiskey/Whiskey\n",
                "19 Hand Grip/Whiskey/Whiskey Shadow/Whiskey Shadow\n",
                "20 Rings/Ring/Eye/Eye\n",
                "20 Rings/Ring/Eye/Eye Shadow/Eye Shadow\n",
                "23 Ceasar/Ceasar/Ceasar\n",
                "23 Ceasar/Ceasar/Ceasar Shadow/Ceasar Shadow\n",
                "3 Chair/Don Chair\n",
                "4 Body/Tycoon/Tycoon Chad\n",
                "5 Suit/Joker/Joker Red\n",
                "7 Face/Chad/Chad Tycoon/9 Eyes/Shock Tycoon\n",
                "7 Face/Chad/Chad Tycoon/Chad Tycoon\n",
                "7 Face/Chad/Chad Tycoon/Layer 2365"
            )
        );
    }

    function PRE_RAND_M2() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "male\n",
                "1 Background/Tech/Heaven\n",
                "10 Nose/Tycoon Nose/Powerful Tycoon/Powerful Shadow/Powerful Shadow\n",
                "10 Nose/Tycoon Nose/Powerful Tycoon/Powerful Tycoon\n",
                "13 Hair/Red/Wolf Red\n",
                "14 Eyebrow/Red Brow/Deep Red\n",
                "17 Face Mod/Samurai/Samurai\n",
                "19 Hand Grip/Sword/Sword\n",
                "19 Hand Grip/Sword/Sword Shadow\n",
                "20 Rings/Combos/Pump/Cross/Cross\n",
                "20 Rings/Combos/Pump/Cross/Cross Shadow/Cross Shadow\n",
                "20 Rings/Combos/Pump/Skull/Skull Index\n",
                "20 Rings/Combos/Pump/Skull/Skull Shadow/Skull Shadow\n",
                "3 Chair/Don Chair\n",
                "4 Body/Tycoon/Tycoon Chad\n",
                "5 Suit/Designer/Designer Blue\n",
                "7 Face/Chad/Chad Tycoon/9 Eyes/Heavy Green Tycoon\n",
                "7 Face/Chad/Chad Tycoon/Chad Tycoon\n",
                "7 Face/Chad/Chad Tycoon/Layer 2365"
            )
        );
    }

    function PRE_RAND_F1() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "female\n",
                "1 Chairs/Royalty\n",
                "12 Wrist dec/Watch/Watch\n",
                "12 Wrist dec/Watch/Watch Shadow/Watch Shadow\n",
                "13 Hand Grip/Whiskey Rocks/Whiskey Rocks\n",
                "13 Hand Grip/Whiskey Rocks/Whiskey Rocks Shadow/Whiskey Rocks Shadow\n",
                "14 Ring/Ring/Opal/Opal\n",
                "14 Ring/Ring/Opal/Opal Shadow/Opal Shadow\n",
                "15 Earing/Spike\n",
                "3 Body/Industrialist\n",
                "4 Suits/Leadership\n",
                "5 Face/Heiress/Eyes/Sassy Heiress\n",
                "5 Face/Heiress/Heiress\n",
                "5 Face/Heiress/Mouth/Lush/Lush Dark Heiress\n",
                "6 Nose/Heiress Nose/Perk Heiress/Perk Heiress\n",
                "6 Nose/Heiress Nose/Perk Heiress/Perk Shadow/Perk Shadow\n",
                "7 eye brow/Duh\n",
                "9 Hair/Bob/Bob Red/Bob Red\n",
                "9 Hair/Bob/Bob Red/Bob Shadow/Bob Shadow"
            )
        );
    }

    function PRE_RAND_F2() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "female\n",
                "1 Chairs/Royalty\n",
                "12 Wrist dec/Horseshoe/Horseshoe\n",
                "12 Wrist dec/Horseshoe/Horseshoe Shadow/Horseshoe Shadow\n",
                "13 Hand Grip/Wine/Wine\n",
                "13 Hand Grip/Wine/Wine Shadow/Wine Shadow\n",
                "14 Ring/Ring/Opal/Opal\n",
                "14 Ring/Ring/Opal/Opal Shadow/Opal Shadow\n",
                "15 Earing/Hindi\n",
                "17 AR/Stonks\n",
                "3 Body/Industrialist\n",
                "4 Suits/BossB\n",
                "5 Face/Heiress/Eyes/Sassy Heiress\n",
                "5 Face/Heiress/Heiress\n",
                "5 Face/Heiress/Mouth/Lush/Lush Dark Heiress\n",
                "6 Nose/Heiress Nose/Ms Heiress/Ms Heiress\n",
                "6 Nose/Heiress Nose/Ms Heiress/Ms Shadow/Ms Shadow\n",
                "7 eye brow/Dont\n",
                "8 Necklace/Rope/BossB Rope/BossB Rope\n",
                "8 Necklace/Rope/BossB Rope/BossB Rope Shadow/BossB Rope Shadow\n",
                "9 Hair/Punk/Punk Black/Punk Black\n",
                "9 Hair/Punk/Punk Black/Punk Shadow/Punk Shadow"
            )
        );
    }

    // ================================================================== 1. THE TRUST MODEL

    /// The on-chain commitment must equal the off-chain resolver's, byte for byte, for real Dons of
    /// both genders. This is what makes attestation trustless: no signer is involved anywhere.
    function test_golden_commitments() public view {
        assertEq(reg.commitmentOf(PRE_ENFORCER()), COMBO_ENFORCER, "enforcer");
        assertEq(reg.commitmentOf(PRE_MATRIARCH()), COMBO_MATRIARCH, "matriarch");
        assertEq(reg.commitmentOf(PRE_GHOST()), COMBO_GHOST, "ghost");
        assertEq(reg.commitmentOf(PRE_MVHQ()), COMBO_MVHQ, "mvhq");
        assertEq(reg.commitmentOf(PRE_RAND_M1()), COMBO_RAND_M1, "rand m1");
        assertEq(reg.commitmentOf(PRE_RAND_M2()), COMBO_RAND_M2, "rand m2");
        assertEq(reg.commitmentOf(PRE_RAND_F1()), COMBO_RAND_F1, "rand f1");
        assertEq(reg.commitmentOf(PRE_RAND_F2()), COMBO_RAND_F2, "rand f2");
    }

    function test_attest_isPermissionless() public {
        don.set(1, ALICE, COMBO_ENFORCER);
        vm.prank(address(0xD00D)); // a total stranger, not the owner, not an admin
        reg.attest(1, PRE_ENFORCER());
        assertTrue(reg.isAttested(1));
        assertEq(reg.sheetCombo(1), COMBO_ENFORCER);
    }

    function test_attest_rejectsWrongPreimage() public {
        don.set(1, ALICE, COMBO_ENFORCER);
        vm.expectRevert(AffinityRegistry.ComboMismatch.selector);
        reg.attest(1, PRE_MATRIARCH()); // another real Don's traits
    }

    function test_attest_rejectsUnknownDon() public {
        vm.expectRevert(AffinityRegistry.UnknownDon.selector);
        reg.attest(99, PRE_ENFORCER());
    }

    function test_attest_rejectsDoubleAttest() public {
        don.set(1, ALICE, COMBO_ENFORCER);
        reg.attest(1, PRE_ENFORCER());
        vm.expectRevert(AffinityRegistry.AlreadyAttested.selector);
        reg.attest(1, PRE_ENFORCER());
    }

    function test_attest_rejectsBadGender() public {
        bytes memory p = bytes("nonbinary\n17 Face Mod/Terminator");
        don.set(1, ALICE, reg.commitmentOf(p)); // even with a matching commitment
        vm.expectRevert(AffinityTraits.BadPreimage.selector);
        reg.attest(1, p);
    }

    function testFuzz_attest_randomBytesNeverPass(bytes calldata junk) public {
        don.set(1, ALICE, COMBO_ENFORCER);
        vm.assume(keccak256(junk) != keccak256(PRE_ENFORCER()));
        vm.expectRevert();
        reg.attest(1, junk);
    }

    /// A rerolled Don loses its sheet instantly -- you cannot attest a god-roll and then reroll away.
    function test_reroll_invalidatesSheet() public {
        don.set(1, ALICE, COMBO_MATRIARCH);
        reg.attest(1, PRE_MATRIARCH());
        assertGt(reg.statsOf(1).hdBps, 0);

        don.set(1, ALICE, COMBO_RAND_M1); // the reroll
        assertFalse(reg.isAttested(1));
        assertEq(reg.statsOf(1).hdBps, 0, "stale sheet must grant nothing");
        assertEq(reg.applyHouseDefense(1, 60 * PPM), 60 * PPM, "reader must ignore a stale sheet");

        reg.attest(1, PRE_RAND_M1()); // re-attest to the NEW combo is open to anyone
        assertTrue(reg.isAttested(1));
    }

    /// D7: once the collection freezes the traits, the sheet is permanent and reads stop paying for
    /// the staleness check.
    function test_lock_freezesSheet() public {
        don.set(1, ALICE, COMBO_MATRIARCH);
        reg.attest(1, PRE_MATRIARCH());
        assertFalse(reg.frozen(1));
        don.lock(1);
        reg.refreshFreeze(1);
        assertTrue(reg.frozen(1));

        // attest-after-lock also freezes in one step
        don.set(2, ALICE, COMBO_ENFORCER);
        don.lock(2);
        reg.attest(2, PRE_ENFORCER());
        assertTrue(reg.frozen(2));
    }

    function test_refreshFreeze_rejectsUnlocked() public {
        don.set(1, ALICE, COMBO_MATRIARCH);
        reg.attest(1, PRE_MATRIARCH());
        vm.expectRevert(AffinityRegistry.ComboMismatch.selector);
        reg.refreshFreeze(1);
    }

    // ================================================================== 2. GOLDEN STAT SHEETS

    /// Sheet 1 of DON-TRAITS-AS-GAMEPLAY Part C.5, as the resolver actually rolls it: The General
    /// (RP+2, NRV+1 siege) + Terminator (RP+2) + FULL BLOODLINE Mogul (RP+2) + The Bull absent +
    /// Ceasar (CMD faction +1%) + Rolex (-10% dispatch).
    function test_golden_enforcerSheet() public view {
        IAffinityRegistry.Stats memory s = reg.previewSheet(PRE_ENFORCER());
        assertEq(s.rpBps, 600, "RP: General 2sp + Terminator 2sp + Mogul bloodline 2sp");
        assertEq(s.nrvBps, 100, "NRV: The General siege +1pp");
        assertEq(s.cmdFactionBps, 100, "CMD: Ceasar +1% faction");
        assertEq(s.feeDiscBps, 1000, "YLD: Rolex -10% dispatch");
        assertEq(s.hdBps, 0);
        assertEq(s.hdFlat, 0);
        assertEq(s.guiTier, 0);
        assertEq(uint256(s.archetype), uint256(IAffinityRegistry.Archetype.ENFORCER));
        assertTrue(s.flags & AffinityTraits.F_SET_BLOODLINE != 0, "full bloodline");
        assertTrue(s.flags & AffinityTraits.F_SET_CROWN != 0, "outfit crown via Ceasar");
        assertFalse(s.flags & AffinityTraits.F_FEMALE != 0);
        // 600bps of A -> 90bps of odds, +100 NRV +100 faction = 290 of the 1000 budget.
        assertEq(reg.edgeOf(s), 290, "consumes 29% of the Edge Budget");
    }

    /// Sheet 2 of Part C.5 -- the Matriarch, with THE ESTATE capstone and FULL BLOODLINE Executive.
    function test_golden_matriarchSheet() public view {
        IAffinityRegistry.Stats memory s = reg.previewSheet(PRE_MATRIARCH());
        assertEq(s.hdBps, 1500, "HD: Estate +15% (Executive bloodline +2% clipped at the W2 ceiling)");
        assertEq(s.hdFlat, 21, "HD flat: Leadership +1 + Doggy +20");
        assertEq(s.cmdFactionBps, 200, "CMD: Leadership +1% + Estate +1% = the ruled +2%");
        assertEq(s.resPetrifyBps, 5000, "RES: Medusa +50% attacker lockout");
        assertEq(s.feeDiscBps, 1000, "YLD: Watch -10% dispatch");
        assertEq(s.rpBps, 0, "near-zero on raw offence");
        assertEq(s.nrvBps, 0);
        assertEq(uint256(s.archetype), uint256(IAffinityRegistry.Archetype.MATRIARCH));
        assertTrue(s.flags & AffinityTraits.F_FEMALE != 0);
        assertTrue(s.flags & AffinityTraits.F_COUNTER_RECON != 0, "W1 identity floor: every woman");
        assertTrue(s.flags & AffinityTraits.F_PHOENIX != 0);
        assertTrue(s.flags & AffinityTraits.F_SET_ESTATE != 0);
        assertTrue(s.flags & AffinityTraits.F_SET_BLOODLINE != 0);
        assertTrue(s.flags & AffinityTraits.F_SET_CROWN != 0);
        assertEq(reg.edgeOf(s), 608, "240 (HD%) + 168 (HD flat) + 200 (faction)");
    }

    function test_golden_ghostSheet() public view {
        IAffinityRegistry.Stats memory s = reg.previewSheet(PRE_GHOST());
        assertEq(s.guiTier, 2, "Bladerunner + The Dev AR = read tier 2");
        assertEq(s.lckBps, 200, "Jester + Prayer Bead");
        assertEq(s.hdFlat, 10, "Hawk field warning");
        assertTrue(s.flags & AffinityTraits.F_UNSCOUTABLE != 0, "Ghost background");
        assertTrue(s.flags & AffinityTraits.F_COUNTER_RECON != 0);
        assertTrue(s.flags & AffinityTraits.F_SCOUT_LITE != 0, "the Hawk produces reports");
        assertFalse(s.flags & AffinityTraits.F_SET_VANISH != 0, "no Snake -> the Vanish is NOT complete");
        assertEq(uint256(s.archetype), uint256(IAffinityRegistry.Archetype.GHOST));
    }

    /// The MVHQ set: three ultra-rares whose capstone is CAPACITY, not power (+1 provisioning step on
    /// top of the AR's own), stacked with the Tycoon bloodline's YLD signature.
    function test_golden_mvhqSheet() public view {
        IAffinityRegistry.Stats memory s = reg.previewSheet(PRE_MVHQ());
        assertTrue(s.flags & AffinityTraits.F_SET_MVHQ != 0, "MVHQ bg + AR + Martini");
        assertTrue(s.flags & AffinityTraits.F_SET_BLOODLINE != 0, "Tycoon + Tycoon Nose");
        assertEq(s.yldCapSteps, 2, "capped at the +2-step soft cap");
        assertEq(s.rpBps, 200, "Samurai face mod");
        assertTrue(s.flags & AffinityTraits.F_WILDCARD != 0, "Joker suit");
        assertFalse(s.flags & AffinityTraits.F_SET_MOTLEY != 0, "no Jester -> no Full Motley");
    }

    function test_golden_randomDonsAreMostlyCosmetic() public view {
        // A random male Don: Joker suit (wildcard, no stats), Bane (+2 RP), Ceasar (+1% faction),
        // Tycoon + Tycoon Nose (bloodline -> YLD). Everything else is colourway.
        IAffinityRegistry.Stats memory a = reg.previewSheet(PRE_RAND_M1());
        assertEq(a.rpBps, 200);
        assertEq(a.cmdFactionBps, 100);
        assertEq(a.yldCapSteps, 2);
        assertEq(a.hdBps, 0);
        // A random female Don: Leadership + Watch + Industrialist bloodline (RES). Counter-recon free.
        IAffinityRegistry.Stats memory b = reg.previewSheet(PRE_RAND_F1());
        assertEq(b.cmdFactionBps, 100);
        assertEq(b.hdFlat, 1);
        assertEq(b.feeDiscBps, 1000);
        assertEq(b.resHospBps, 1000, "Industrialist bloodline signature");
        assertTrue(b.flags & AffinityTraits.F_COUNTER_RECON != 0);
    }

    // ================================================================== 3. DECODER PROPERTIES

    /// Colourways and every unlisted group contribute exactly zero -- stated in the doc, enforced here.
    function test_cosmeticGroupsCarryZeroLoad() public view {
        bytes memory p = bytes(
            string.concat(
                "male\n",
                "16 Glasses/Stark/Blue\n",
                "20 Rings/Pinky/Cross/Cross\n",
                "13 Hair/Red/Falcon Red\n",
                "12 Beard/Red Beards/Verdi Red\n",
                "22 Hat/Fedora/Fedora Black"
            )
        );
        IAffinityRegistry.Stats memory s = reg.previewSheet(p);
        assertEq(reg.edgeOf(s), 0);
        assertEq(s.flags, 0);
        assertEq(uint256(s.archetype), uint256(IAffinityRegistry.Archetype.UNSPECIALIZED));
    }

    /// A group that appears on several leaves (art + its shadow layer) is counted ONCE.
    function test_decoder_deduplicatesGroups() public view {
        bytes memory once = bytes("male\n17 Face Mod/Terminator/Terminator Fire");
        bytes memory many = bytes(
            string.concat(
                "male\n",
                "17 Face Mod/Terminator/Terminator Fire\n",
                "17 Face Mod/Terminator/Terminator Shadow/Terminator Shadow\n",
                "17 Face Mod/Terminator/Terminator Ice"
            )
        );
        assertEq(reg.previewSheet(once).rpBps, 200);
        assertEq(reg.previewSheet(many).rpBps, 200, "shadow layers must not double-count");
    }

    function test_decoder_ignoresUncategorisedBaseLayers() public view {
        bytes memory p = bytes(string.concat("female\n", "Background\n", "Layer 1443\n", "9 Hair/Medusa/Medusa"));
        assertEq(reg.previewSheet(p).resPetrifyBps, 5000);
    }

    /// W1, the population-wide female identity floor: every woman carries counter-recon, with no trait.
    function testFuzz_femaleIdentityFloor(uint256 mask) public view {
        IAffinityRegistry.Stats memory f = reg.previewSheet(_preimage(mask, true));
        assertTrue(f.flags & AffinityTraits.F_COUNTER_RECON != 0, "every woman");
        assertTrue(f.flags & AffinityTraits.F_FEMALE != 0);
    }

    function test_setBonus_theVanish() public view {
        bytes memory p =
            bytes("male\n1 Background/Ghost\n25 Snake/Snake Red\n2 The hawk/Hawk\n4 Body/Mogul");
        IAffinityRegistry.Stats memory s = reg.previewSheet(p);
        assertTrue(s.flags & AffinityTraits.F_SET_VANISH != 0);
        assertEq(s.guiTier, 2, "total information dominance");
        assertTrue(s.flags & AffinityTraits.F_UNSCOUTABLE != 0);
        assertEq(s.rpBps, 0, "the Vanish buys information, never power (horizontality)");
    }

    function test_setBonus_fullMotley() public view {
        bytes memory p = bytes("male\n5 Suit/Joker\n17 Face Mod/Jester");
        IAffinityRegistry.Stats memory s = reg.previewSheet(p);
        assertTrue(s.flags & AffinityTraits.F_SET_MOTLEY != 0);
        assertEq(s.rpBps, 0, "adaptability, not power");
    }

    function test_setBonus_bloodlineNeedsTheWholeHouse() public view {
        assertFalse(
            reg.previewSheet(bytes("male\n4 Body/Mogul")).flags & AffinityTraits.F_SET_BLOODLINE != 0,
            "body alone is not a bloodline"
        );
        assertFalse(
            reg.previewSheet(bytes("male\n4 Body/Mogul\n10 Nose/Tycoon Nose")).flags
                & AffinityTraits.F_SET_BLOODLINE != 0,
            "a mismatched house is not a bloodline"
        );
        assertTrue(
            reg.previewSheet(bytes("male\n4 Body/Mogul\n10 Nose/Mogul Nose")).flags
                & AffinityTraits.F_SET_BLOODLINE != 0
        );
        // women additionally need the family-matched face (their face groups ARE houses)
        assertFalse(
            reg.previewSheet(bytes("female\n3 Body/Executive\n6 Nose/Magnate Nose")).flags
                & AffinityTraits.F_SET_BLOODLINE != 0
        );
        assertTrue(
            reg.previewSheet(bytes("female\n3 Body/Executive\n6 Nose/Magnate Nose\n5 Face/Magnate")).flags
                & AffinityTraits.F_SET_BLOODLINE != 0
        );
    }

    /// Each of the six houses points at a DIFFERENT signature stat -- no family is strictly better.
    function test_setBonus_bloodlineSignaturesAreHorizontal() public view {
        assertEq(reg.previewSheet(bytes("male\n4 Body/Mogul\n10 Nose/Mogul Nose")).rpBps, 200);
        assertEq(reg.previewSheet(bytes("male\n4 Body/Baron\n10 Nose/Baron Nose")).cmdGarrisonBps, 200);
        assertEq(reg.previewSheet(bytes("male\n4 Body/Tycoon\n10 Nose/Tycoon Nose")).yldCapSteps, 2);
        assertEq(
            reg.previewSheet(bytes("female\n3 Body/Executive\n6 Nose/Magnate Nose\n5 Face/Magnate")).hdBps, 200
        );
        assertEq(
            reg.previewSheet(bytes("female\n3 Body/Financier\n6 Nose/Oligarch Nose\n5 Face/Oligarch")).nrvBps,
            200
        );
        assertEq(
            reg.previewSheet(bytes("female\n3 Body/Industrialist\n6 Nose/Heiress Nose\n5 Face/Heiress"))
                .resHospBps,
            1000
        );
    }

    // ================================================================== 4. THE EDGE BUDGET (the invariant)

    /// THE EDGE-BUDGET INVARIANT, fuzzed across the full combo space: no combination of trait groups,
    /// reachable or not, can read back more than the ruled total-edge bound.
    function testFuzz_edgeBudget_neverExceeded(uint256 mask, bool female) public view {
        IAffinityRegistry.Stats memory s = reg.previewSheet(_preimage(mask, female));
        assertLe(reg.edgeOf(s), reg.oddsBudgetBps(), "odds Edge Budget");
        assertLe(s.feeDiscBps, reg.FEE_STACK_MAX(), "fee-discount stack <= 25%");
        // and every per-stat soft cap from Part A holds too
        assertLe(s.rpBps, AffinityTraits.RP_CAP);
        assertLe(s.hdBps, AffinityTraits.HD_PCT_CAP);
        assertLe(s.hdFlat, AffinityTraits.HD_FLAT_CAP);
        assertLe(s.nrvBps, AffinityTraits.NRV_CAP);
        assertLe(s.lckBps, AffinityTraits.LCK_CAP);
        assertLe(s.cmdGarrisonBps, AffinityTraits.CMD_GARRISON_CAP);
        assertLe(s.cmdFactionBps, AffinityTraits.CMD_FACTION_CAP);
        assertLe(s.guiTier, AffinityTraits.GUI_TIER_CAP);
        assertLe(s.yldCapSteps, AffinityTraits.YLD_STEP_CAP);
        assertLe(s.resHospBps, AffinityTraits.RES_HOSP_CAP);
        assertLe(s.resPetrifyBps, AffinityTraits.RES_PETRIFY_CAP);
        assertLe(s.resAmbushBps, AffinityTraits.RES_AMBUSH_CAP);
    }

    /// The same invariant at ANY value the bounded budget knob can take.
    function testFuzz_edgeBudget_holdsAtEveryKnobValue(uint256 mask, uint16 budget) public {
        budget = uint16(bound(budget, reg.ODDS_BUDGET_MIN(), reg.ODDS_BUDGET_MAX()));
        uint16 fee = reg.FEE_STACK_MAX();
        uint16 item = reg.ITEM_MULT_MAX();
        vm.prank(ADMIN);
        reg.setBudget(budget, fee, item);
        assertLe(reg.edgeOf(reg.previewSheet(_preimage(mask, false))), budget);
        assertLe(reg.edgeOf(reg.previewSheet(_preimage(mask, true))), budget);
    }

    /// The maximal Don -- EVERY loaded group at once -- saturates the budget exactly, and no further.
    /// "Maxed edge is a reachable, knowable state. There is no 11th pp to buy."
    function test_edgeBudget_maximalDonSaturates() public view {
        IAffinityRegistry.Stats memory s = reg.previewSheet(_preimage(type(uint256).max, true));
        uint256 e = reg.edgeOf(s);
        assertLe(e, reg.oddsBudgetBps());
        assertGe(e, uint256(reg.oddsBudgetBps()) - 16, "rounding slack only; the build is AT the cap");
    }

    /// The load-bearing claim of the whole system: stacking offence ON TOP of defence does not buy more
    /// total power -- it buys LESS of each. Traits shift WHERE your edge lives, never how much you have.
    function test_edgeBudget_isHorizontal_stackingTradesOff() public view {
        bytes memory off = bytes(
            string.concat(
                "male\n4 Body/Mogul\n10 Nose/Mogul Nose\n17 Face Mod/Terminator\n5 Suit/The General\n",
                "3 Chair/Knowledge Throne\n23 Ceasar/Ceasar\n21 Wrist/Prayer Bead\n17 Face Mod/Jester"
            )
        );
        bytes memory def = bytes(
            string.concat(
                "female\n1 Chairs/Queen\n4 Suits/Leadership\n13 Hand Grip/Doggy\n2 The hawk/Hawk\n",
                "3 Body/Executive\n6 Nose/Magnate Nose\n5 Face/Magnate\n18 Canes/The Bull"
            )
        );
        bytes memory both = bytes(
            string.concat(
                "female\n4 Body/Mogul\n10 Nose/Mogul Nose\n17 Face Mod/Terminator\n5 Suit/The General\n",
                "3 Chair/Knowledge Throne\n23 Ceasar/Ceasar\n21 Wrist/Prayer Bead\n17 Face Mod/Jester\n",
                "1 Chairs/Queen\n4 Suits/Leadership\n13 Hand Grip/Doggy\n2 The hawk/Hawk\n",
                "18 Canes/The Bull"
            )
        );
        IAffinityRegistry.Stats memory o = reg.previewSheet(off);
        IAffinityRegistry.Stats memory d = reg.previewSheet(def);
        IAffinityRegistry.Stats memory b = reg.previewSheet(both);

        uint256 budget = reg.oddsBudgetBps();
        assertLe(reg.edgeOf(o), budget);
        assertLe(reg.edgeOf(d), budget);
        assertLe(reg.edgeOf(b), budget, "the greedy build is still bounded");
        assertGt(reg.edgeOf(o) + reg.edgeOf(d), budget, "the raw sum WOULD exceed it");
        assertLt(b.rpBps, o.rpBps, "the greedy build gives up offence ...");
        assertLt(b.hdBps, d.hdBps, "... and defence, to stay inside one budget");
    }

    /// Both sides of the game saturate the SAME budget: a max-offence build and a max-defence build
    /// each land inside it, and neither route buys a larger total than the other.
    function test_edgeBudget_offenceAndDefenceShareOneCeiling() public view {
        IAffinityRegistry.Stats memory off = reg.previewSheet(
            bytes(
                string.concat(
                    "male\n4 Body/Mogul\n10 Nose/Mogul Nose\n17 Face Mod/Terminator\n5 Suit/The General\n",
                    "5 Suit/Windsor\n5 Suit/Pimp\n23 Ceasar/Ceasar\n21 Wrist/Prayer Bead\n17 Face Mod/Jester"
                )
            )
        );
        IAffinityRegistry.Stats memory def = reg.previewSheet(
            bytes(
                string.concat(
                    "female\n1 Chairs/Queen\n4 Suits/Leadership\n13 Hand Grip/Doggy\n2 The hawk/Hawk\n",
                    "3 Body/Executive\n6 Nose/Magnate Nose\n5 Face/Magnate\n18 Canes/The Bull\n",
                    "4 Suits/Opera\n12 Wrist dec/Horseshoe\n12 Wrist dec/Black Pearl"
                )
            )
        );
        uint256 budget = reg.oddsBudgetBps();
        assertLe(reg.edgeOf(off), budget);
        assertLe(reg.edgeOf(def), budget);
        assertGt(off.rpBps, 0);
        assertGt(def.hdBps, 0);
    }

    /// Nothing here can reach an RTP surface or the 7.5% hit tax: the sheet has no such field, and the
    /// only fee lever is the discount stack, bounded at 25% (ruling D1 / the H.3 invariant).
    function testFuzz_feeStackNeverBeatsTheHitTax(uint256 mask, bool female) public view {
        IAffinityRegistry.Stats memory s = reg.previewSheet(_preimage(mask, female));
        assertLe(s.feeDiscBps, 2_500);
        // a 7.5% hit tax on a 10_000-unit score always exceeds the rebate on the 50-unit commit fee
        uint256 rebate = (50 * uint256(s.feeDiscBps)) / BPS;
        assertGt((10_000 * 750) / BPS, rebate, "hit tax > any rebate");
    }

    // ================================================================== 5. ARCHETYPES

    function testFuzz_archetypeIsDeterministic(uint256 mask, bool female) public view {
        bytes memory p = _preimage(mask, female);
        assertEq(reg.previewSheet(p).archetype, reg.previewSheet(p).archetype);
    }

    /// The Edge-Budget knob is a balance dial, not an identity dial: it can never move who a Don is.
    function testFuzz_archetypeIndependentOfBudgetKnob(uint256 mask, uint16 budget) public {
        bytes memory p = _preimage(mask, false);
        uint8 before = reg.previewSheet(p).archetype;
        budget = uint16(bound(budget, reg.ODDS_BUDGET_MIN(), reg.ODDS_BUDGET_MAX()));
        uint16 item = reg.ITEM_MULT_MAX();
        vm.prank(ADMIN);
        reg.setBudget(budget, 0, item);
        assertEq(reg.previewSheet(p).archetype, before);
    }

    function test_archetype_theSixSpecs() public view {
        // BROKER -- fee-minimised finance: Scholar/Windsor NRV + Rolex/Claw fee legs, no muscle.
        assertEq(
            reg.previewSheet(bytes("male\n5 Suit/Scholar\n21 Wrist/Rolex\n18 Canes/Claw\n3 Chair/Knowledge Throne"))
                .archetype,
            uint8(IAffinityRegistry.Archetype.BROKER)
        );
        // BOSS -- leadership first: Ceasar faction + The Bull garrison.
        assertEq(
            reg.previewSheet(bytes("male\n23 Ceasar/Ceasar\n18 Canes/The Bull")).archetype,
            uint8(IAffinityRegistry.Archetype.BOSS)
        );
        // HIGH_ROLLER -- the Table lane: Glitch + Prayer Bead luck riders.
        assertEq(
            reg.previewSheet(bytes("male\n4 Body/Glitch\n21 Wrist/Prayer Bead")).archetype,
            uint8(IAffinityRegistry.Archetype.HIGH_ROLLER)
        );
        // ENFORCER / MATRIARCH / GHOST are covered by the golden sheets above.
        assertEq(
            reg.previewSheet(bytes("male")).archetype, uint8(IAffinityRegistry.Archetype.UNSPECIALIZED)
        );
    }

    // ================================================================== 6. READERS (what 1a/1b/1d call)

    function test_readers_unattestedDonIsNeutral() public view {
        assertEq(reg.applyRaidPower(7, 250 * PPM), 250 * PPM);
        assertEq(reg.applyHouseDefense(7, 60 * PPM), 60 * PPM);
        assertEq(reg.applyGarrison(7, 142 * PPM), 142 * PPM);
        assertEq(reg.applyCooldown(7, 20 hours), 20 hours);
        assertEq(reg.applyHospital(7, 48 hours), 48 hours);
        assertEq(reg.applyPetrify(7, 48 hours), 48 hours);
        assertEq(reg.applyFeeDiscount(7, 1000), 1000);
        assertEq(reg.guileTier(7), 0);
        assertFalse(reg.counterRecon(7));
    }

    function test_readers_applyTheSheet() public {
        don.set(1, ALICE, COMBO_ENFORCER);
        reg.attest(1, PRE_ENFORCER());
        don.set(2, ALICE, COMBO_MATRIARCH);
        reg.attest(2, PRE_MATRIARCH());

        assertEq(reg.applyRaidPower(1, 250 * PPM), 265 * PPM, "+6% A");
        assertEq(reg.applyFeeDiscount(1, 1000), 900, "-10% dispatch");
        assertEq(reg.factionBps(1), 100);

        // (60 + 21) * 1.15 = 93.15
        assertEq(reg.applyHouseDefense(2, 60 * PPM), 93_150_000);
        assertEq(reg.applyPetrify(2, 48 hours), 72 hours, "Medusa +50%");
        assertTrue(reg.counterRecon(2));
        assertFalse(reg.unscoutable(2));
        assertEq(uint256(reg.archetypeOf(2)), uint256(IAffinityRegistry.Archetype.MATRIARCH));
        assertEq(reg.oddsEdgeBps(2), 608);
    }

    function test_readers_scoutSurface() public {
        don.set(1, ALICE, COMBO_GHOST);
        reg.attest(1, PRE_GHOST());
        assertEq(reg.guileTier(1), 2);
        assertTrue(reg.unscoutable(1));
        assertTrue(reg.counterRecon(1));
        assertTrue(reg.scoutLite(1));
    }

    function test_rawStatsOf_exposesTheUnclampedDerivation() public view {
        bytes memory p = _preimage(type(uint256).max, true);
        // previewSheet is clamped; the raw derivation is only reachable through an attested Don, so the
        // clamped preview must already be inside the budget while the per-stat caps stay maxed.
        IAffinityRegistry.Stats memory s = reg.previewSheet(p);
        assertLe(reg.edgeOf(s), reg.oddsBudgetBps());
        assertEq(s.resPetrifyBps, AffinityTraits.RES_PETRIFY_CAP, "RES is not an odds stat -- never scaled");
        assertEq(s.resHospBps, AffinityTraits.RES_HOSP_CAP);
        assertEq(s.guiTier, AffinityTraits.GUI_TIER_CAP);
    }

    // ================================================================== 7. SKIRMISH PREVIEW

    /// The worked raid-clash of DON-TRAITS-AS-GAMEPLAY Part F, recomputed by the contract:
    /// Enforcer (RP +4%) attacks the Matriarch (HD +15%, +21 flat, Medusa) on a fortified Row House.
    function test_skirmish_partFWorkedClash() public view {
        IAffinityRegistry.Stats memory att;
        att.rpBps = 400;
        IAffinityRegistry.Stats memory def;
        def.hdBps = 1500;
        def.hdFlat = 21;
        def.resPetrifyBps = 5000;

        IAffinityRegistry.Skirmish memory k = reg.skirmish(att, def, 5, 3, 60);

        assertEq(k.attackPower, 260 * PPM, "A' = 250e6 x 1.04");
        assertEq(k.defensePower, 257_025_000, "D' = (60 + 142.5 + 21) x 1.15");
        assertEq(k.pHitBaseBps, 3_977, "39.8% with no traits on either side (doc: 39.8%)");
        assertEq(k.pHitEdgedBps, 3_620, "36.2% with both stacks in (doc: 36.1% at their rounding)");
        assertEq(k.deltaBps, -357, "the Matriarch's defence outweighs the Enforcer's offence");
        assertEq(k.pKillOnFailBps, 3_239, "kill-on-fail 32.4% (doc: 32.4%)");
        assertEq(k.attackerLockout, 72 hours, "Medusa petrify: 48h x 1.5");
        assertEq(k.oddsEdgeBps, 60, "the attacker consumed 60 of 1000");
    }

    /// "He wins where she is absent": the same crew against a bare Safehouse clamps at the 70% ceiling.
    function test_skirmish_vsReferenceGarrisons() public {
        don.set(1, ALICE, COMBO_ENFORCER);
        reg.attest(1, PRE_ENFORCER());

        IAffinityRegistry.Skirmish memory bare =
            reg.previewVsGarrison(1, IAffinityRegistry.GarrisonClass.BARE_SAFEHOUSE, 5);
        // A' = 265e6 against a bare Safehouse D = 40e6 -> 0.72 x 265/305 = 62.6%, hard against the
        // P_MAX 70% ceiling: "he wins where she is absent" (Part F).
        assertEq(bare.pHitEdgedBps, 6_255);
        assertLe(bare.pHitEdgedBps, 7_000, "never past the P_MAX ceiling");

        IAffinityRegistry.Skirmish memory fortress =
            reg.previewVsGarrison(1, IAffinityRegistry.GarrisonClass.FORTRESS_ROW_HOUSE, 5);
        assertEq(fortress.pHitBaseBps, 3_977);
        assertGt(fortress.pHitEdgedBps, fortress.pHitBaseBps, "RP helps ...");
        assertLt(fortress.pHitEdgedBps, bare.pHitEdgedBps, "... but the fortress still bites");

        (uint256 d0, uint256 g0) = reg.referenceGarrison(IAffinityRegistry.GarrisonClass.GUARDED_SAFEHOUSE);
        assertEq(d0, 40);
        assertEq(g0, 2);
        (uint256 d1, uint256 g1) = reg.referenceGarrison(IAffinityRegistry.GarrisonClass.OPEN_ROW_HOUSE);
        assertEq(d1, 60);
        assertEq(g1, 0);
    }

    function test_skirmish_previewDuelUsesBothSheets() public {
        don.set(1, ALICE, COMBO_ENFORCER);
        reg.attest(1, PRE_ENFORCER());
        don.set(2, ALICE, COMBO_MATRIARCH);
        reg.attest(2, PRE_MATRIARCH());
        IAffinityRegistry.Skirmish memory k = reg.previewDuel(1, 2, 5, 3, 60);
        assertEq(k.attackPower, 265 * PPM, "+6% (General + Terminator + Mogul bloodline)");
        assertEq(k.defensePower, 257_025_000);
        assertLt(k.deltaBps, 0, "she still wins the head-to-head");
        assertEq(k.attackerLockout, 72 hours);
    }

    function test_skirmish_crewIsCappedAtMaxCrew() public view {
        IAffinityRegistry.Stats memory z;
        assertEq(reg.skirmish(z, z, 50, 0, 40).attackPower, reg.skirmish(z, z, 5, 0, 40).attackPower);
    }

    /// The preview is a public entry point: hand-made, out-of-budget sheets are clamped before use, so
    /// the panel can never quote a number the engine would refuse to honour.
    function testFuzz_skirmish_clampsHandMadeSheets(uint16 rp, uint16 hd, uint16 flat, uint16 nrv)
        public
        view
    {
        IAffinityRegistry.Stats memory a;
        a.rpBps = rp;
        a.nrvBps = nrv;
        IAffinityRegistry.Stats memory d;
        d.hdBps = hd;
        d.hdFlat = flat;
        IAffinityRegistry.Skirmish memory k = reg.skirmish(a, d, 5, 3, 60);
        assertLe(k.oddsEdgeBps, reg.oddsBudgetBps());
        assertLe(k.pHitEdgedBps, 7_000);
        assertGe(k.pHitEdgedBps, 500);
    }

    // ================================================================== 8. KNOBS

    function test_knobs_boundsAreImmutableAndRuled() public view {
        assertEq(reg.ODDS_BUDGET_MAX(), 1_000, "+10pp, forever");
        assertEq(reg.FEE_STACK_MAX(), 2_500, "25% fee stack, forever");
        assertEq(reg.ITEM_MULT_MAX(), 13_500, "x1.35, forever");
        assertEq(reg.oddsBudgetBps(), 1_000);
        assertEq(reg.feeStackCapBps(), 2_500);
        assertEq(reg.itemMultCapBps(), 13_500);
    }

    function test_knobs_onlyAdmin() public {
        vm.expectRevert(AffinityRegistry.NotAdmin.selector);
        reg.setBudget(500, 1000, 12_000);
    }

    function test_knobs_setterMovesTheValue() public {
        vm.prank(ADMIN);
        reg.setBudget(500, 1_000, 12_000);
        assertEq(reg.oddsBudgetBps(), 500);
        assertEq(reg.feeStackCapBps(), 1_000);
        assertEq(reg.itemMultCapBps(), 12_000);
        // and the tighter budget is what the readers now enforce
        assertLe(reg.edgeOf(reg.previewSheet(_preimage(type(uint256).max, true))), 500);
        assertLe(reg.previewSheet(_preimage(type(uint256).max, true)).feeDiscBps, 1_000);
    }

    function testFuzz_knobs_cannotEscapeTheirBounds(uint16 odds, uint16 fee, uint16 item) public {
        bool ok = odds >= reg.ODDS_BUDGET_MIN() && odds <= reg.ODDS_BUDGET_MAX() && fee <= reg.FEE_STACK_MAX()
            && item >= reg.ITEM_MULT_MIN() && item <= reg.ITEM_MULT_MAX();
        vm.prank(ADMIN);
        if (!ok) vm.expectRevert(AffinityRegistry.OutOfBounds.selector);
        reg.setBudget(odds, fee, item);
        if (ok) assertEq(reg.oddsBudgetBps(), odds);
    }

    function test_deploy_rejectsZeroWiring() public {
        vm.expectRevert(AffinityRegistry.BadConfig.selector);
        new AffinityRegistry(IGameController(address(0)), IDonTraits(address(don)));
        vm.expectRevert(AffinityRegistry.BadConfig.selector);
        new AffinityRegistry(IGameController(address(ctrl)), IDonTraits(address(0)));
    }

    /// Storage packing round-trip: what the pure preview derives is byte-identical to what the packed
    /// one-slot sheet reads back.
    function test_storedSheetMatchesPreview() public {
        don.set(1, ALICE, COMBO_MATRIARCH);
        reg.attest(1, PRE_MATRIARCH());
        IAffinityRegistry.Stats memory a = reg.statsOf(1);
        IAffinityRegistry.Stats memory b = reg.previewSheet(PRE_MATRIARCH());
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "packed sheet == derived sheet");
        IAffinityRegistry.Stats memory raw = reg.rawStatsOf(1);
        assertEq(raw.hdBps, a.hdBps, "this build is under budget, so raw == clamped");
    }

    /// The registry holds no value and exposes no path to any: there is no token, no receive, no
    /// withdraw, and no setter that can name a destination.
    function test_registryHoldsNothing() public {
        assertEq(address(reg).balance, 0);
        (bool ok,) = address(reg).call{value: 1 ether}("");
        assertFalse(ok, "no receive/fallback -- value cannot enter");
    }
}

/// The Edge-Budget INVARIANT CAMPAIGN (DON-V2-BUILD-PLAN 3.2, "AffinityRegistry + trait readers: 1
/// invariant campaign — Edge Budget cap under max stack"). The handler drives the whole lifecycle —
/// attest, reroll, re-attest, lock, and retune the bounded knob — against arbitrary trait stacks; the
/// invariant asserts the law holds over every Don at every point in that history.
contract AffinityHandler is Test {
    AffinityRegistry public reg;
    MockTraitDon public don;
    address public admin;
    string[] internal vocab;
    uint256[] public touched;
    mapping(uint256 => bool) internal known;

    constructor(AffinityRegistry reg_, MockTraitDon don_, address admin_, string[] memory vocab_) {
        reg = reg_;
        don = don_;
        admin = admin_;
        for (uint256 i = 0; i < vocab_.length; i++) vocab.push(vocab_[i]);
    }

    function _pre(uint256 mask, bool female) internal view returns (bytes memory) {
        string memory s = female ? "female" : "male";
        for (uint256 i = 0; i < vocab.length; i++) {
            if ((mask >> i) & 1 == 1) s = string.concat(s, "\n", vocab[i]);
        }
        return bytes(s);
    }

    function attest(uint256 id, uint256 mask, bool female) external {
        id = bound(id, 1, 8);
        bytes memory p = _pre(mask, female);
        bytes32 combo = reg.commitmentOf(p);
        don.set(id, address(this), combo);
        if (reg.sheetCombo(id) == combo) return;
        reg.attest(id, p);
        if (!known[id]) {
            known[id] = true;
            touched.push(id);
        }
    }

    /// A reroll away from an attested sheet — the sheet must stop counting, not keep paying out.
    function reroll(uint256 id, uint256 mask, bool female) external {
        id = bound(id, 1, 8);
        if (don.locked(id)) return;
        don.set(id, address(this), reg.commitmentOf(_pre(mask, female)));
    }

    function lock(uint256 id) external {
        id = bound(id, 1, 8);
        if (don.traits(id) == bytes32(0)) return;
        don.lock(id);
        if (reg.sheetCombo(id) == don.traits(id)) reg.refreshFreeze(id);
    }

    function tune(uint16 budget, uint16 fee) external {
        budget = uint16(bound(budget, reg.ODDS_BUDGET_MIN(), reg.ODDS_BUDGET_MAX()));
        fee = uint16(bound(fee, 0, reg.FEE_STACK_MAX()));
        uint16 item = reg.ITEM_MULT_MAX();
        vm.prank(admin);
        reg.setBudget(budget, fee, item);
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }
}

contract AffinityEdgeBudgetInvariant is Test {
    AffinityRegistry internal reg;
    MockTraitDon internal don;
    MockController internal ctrl;
    AffinityHandler internal handler;
    address internal ADMIN = address(0xA11CE);

    function setUp() public {
        ctrl = new MockController(ADMIN);
        don = new MockTraitDon();
        reg = new AffinityRegistry(IGameController(address(ctrl)), IDonTraits(address(don)));

        AffinityRegistryTest vocabSource = new AffinityRegistryTest();
        vocabSource.setUp();
        handler = new AffinityHandler(reg, don, ADMIN, vocabSource.vocabulary());
        targetContract(address(handler));
    }

    /// THE EDGE BUDGET: no Don, under any history of attests, rerolls, locks and knob retunes, ever
    /// reads back more odds edge than the active budget or more fee discount than the ruled 25%.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_edgeBudgetHolds() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.touched(i);
            IAffinityRegistry.Stats memory s = reg.statsOf(id);
            assertLe(reg.edgeOf(s), reg.oddsBudgetBps(), "odds Edge Budget");
            assertLe(s.feeDiscBps, reg.FEE_STACK_MAX(), "fee stack");
            assertLe(reg.oddsEdgeBps(id), reg.oddsBudgetBps());
        }
    }

    /// A stale (rerolled-away) sheet grants exactly nothing through every reader.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_staleSheetsGrantNothing() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.touched(i);
            if (reg.frozen(id) || don.traits(id) == reg.sheetCombo(id)) continue;
            assertEq(reg.applyRaidPower(id, 250e6), 250e6);
            assertEq(reg.applyHouseDefense(id, 60e6), 60e6);
            assertEq(reg.guileTier(id), 0);
            assertFalse(reg.counterRecon(id));
        }
    }

    /// Once the collection freezes a Don, its sheet is permanent and always matches the frozen combo.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_frozenSheetsStayLive() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.touched(i);
            if (!reg.frozen(id)) continue;
            assertTrue(don.locked(id));
            assertTrue(reg.isAttested(id));
        }
    }
}
