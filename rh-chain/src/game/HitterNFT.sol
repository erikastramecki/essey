// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IEntropy, IEntropyConsumer} from "../market/EsseyCasesDegen.sol";
import {IDonLike, IGameController, IScrip, GameRoles} from "./GameTypes.sol";

/// HitterNFT — the mass-mint crew unit (contracts-architecture §2.7), Phase-0 minimal per the
/// concept §4.4 manifest: mint, hunt/garrison availability flags, cooldown/hospital state, and the
/// SEALED-SLOT FAVOR. No 6551 vaults, no items, no kill-loot yet (Phase 1 adds the SeatVault clone
/// per Hitter when equipped gear becomes lootable); supply UNCAPPED, one SKU (B7).
///
/// Pricing: Phase 0 is Scrip-only, so the mint prices in Scrip at the peg of the ruled $9 sealed
/// SKU (B5) — 900 Scrip, burned (a sink; the $6/$3 cash split is a USDG-mode concern). Payment
/// draws from a Don's banked Scrip (the vault), keeping Scrip non-transferable end to end.
///
/// THE SEALED SLOT ("the Favor", economy §1): every mint carries it. Commit at mint (the user-side
/// randomness seed is fixed in the mint tx, before any odds can be steered), entropy reveal on
/// first use — the Cases odds pattern with the ruled published bands 70 / 20 / 8.5 / 1.5 (B5),
/// validated on-chain the Degen way. A sealed Favor past the timeout can be force-revealed
/// permissionlessly AT THE FLOOR BAND (Common), the reclaim philosophy: nothing stays sealed, and
/// the valve is never better than a real roll. Transfer-auto-reveal + the Edge-envelope machinery
/// are Phase-1 scope (flagged in the build report).
///
/// Metadata is REDACTED by design (art ships later; the dossier UI reads the flags): a minimal
/// on-chain JSON with the case-file framing.
contract HitterNFT is ERC721, IEntropyConsumer, ReentrancyGuard {
    using Strings for uint256;

    IGameController public immutable controller;
    IScrip public immutable scrip;
    IDonLike public immutable don;
    IEntropy public immutable entropy;
    address public immutable entropyProvider;
    uint32 public immutable callbackGasLimit;

    uint256 internal constant PPM = 1_000_000;
    /// $9 sealed SKU at the 0.01 peg (B5) — burned, the Scrip-mode sink.
    uint256 public constant MINT_PRICE = 900e18;
    /// Sealed past this window => anyone may floor-reveal at Common.
    uint256 public constant FORCE_REVEAL_TIMEOUT = 30 days;

    /// The ruled Favor bands: Common 70% / Uncommon 20% / Rare 8.5% / Legendary 1.5% —
    /// published on-chain before any mint is sold (economy §1.6 trust set).
    uint32 public constant CUM_COMMON_PPM = 700_000;
    uint32 public constant CUM_UNCOMMON_PPM = 900_000;
    uint32 public constant CUM_RARE_PPM = 985_000;
    // Legendary: the remainder to 1_000_000.

    uint256 public totalMinted;

    mapping(uint256 => bytes32) public favorCommit; // fixed at mint — the commit half
    mapping(uint256 => uint64) public mintedAt;
    mapping(uint256 => bool) public sealed_; // true until the Favor reveals
    mapping(uint256 => uint8) public favorOf; // 0 Common ... 3 Legendary (valid once revealed)
    mapping(uint256 => bool) public revealPending; // entropy in flight
    mapping(uint64 => uint256) public seqToHitter;

    // Game flags — written ONLY by the RAID_MODULE (one scoped power each).
    mapping(uint256 => uint64) public lastAttemptAt; // cooldown anchor (the (t/20h)^2 curve reads this)
    mapping(uint256 => uint64) public hospitalUntil; // 48h lockout after a kill-on-fail

    event HitterMinted(uint256 indexed id, uint256 indexed payerDonId, address indexed to, bytes32 commit);
    event FavorRevealRequested(uint256 indexed id, uint64 seq);
    event FavorRevealed(uint256 indexed id, uint8 band, bool forced);
    event AttemptNoted(uint256 indexed id, uint64 at);
    event Hospitalized(uint256 indexed id, uint64 until);

    error NotDonOwner();
    error NotHitterOwner();
    error NotRaidModule();
    error GenerationClosed();
    error NotSealed();
    error RevealInFlight();
    error NotYetForceable();
    error InsufficientFee();
    error RefundFailed();
    error AlreadyRevealed();
    error BadConfig();

    constructor(
        IGameController controller_,
        IScrip scrip_,
        IDonLike don_,
        IEntropy entropy_,
        address entropyProvider_,
        uint32 callbackGasLimit_
    ) ERC721("D.O.N. Hitter", "HITTER") {
        if (
            address(controller_) == address(0) || address(scrip_) == address(0)
                || address(don_) == address(0) || address(entropy_) == address(0) || callbackGasLimit_ == 0
        ) revert BadConfig();
        controller = controller_;
        scrip = scrip_;
        don = don_;
        entropy = entropy_;
        entropyProvider = entropyProvider_;
        callbackGasLimit = callbackGasLimit_;
    }

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    // ---------------------------------------------------------------- mint

    /// Mint a sealed Hitter to the caller, paid from their Don's banked Scrip (the vault). The
    /// Favor commitment is fixed HERE, in the mint tx — the assignment can't be steered after the
    /// fact (economy §1.6 #2), and the reveal roll later folds this commit into its randomness.
    function mint(uint256 payerDonId) external nonReentrant returns (uint256 id) {
        if (don.ownerOf(payerDonId) != msg.sender) revert NotDonOwner();
        if (controller.closed()) revert GenerationClosed();
        scrip.burn(don.vaultOf(payerDonId), MINT_PRICE); // the sink
        id = ++totalMinted;
        sealed_[id] = true;
        mintedAt[id] = uint64(block.timestamp);
        favorCommit[id] = keccak256(abi.encodePacked(id, msg.sender, blockhash(block.number - 1)));
        _safeMint(msg.sender, id);
        emit HitterMinted(id, payerDonId, msg.sender, favorCommit[id]);
    }

    // ---------------------------------------------------------------- the Favor

    function entropyFee() public view returns (uint256) {
        return entropy.getFeeV2(entropyProvider, callbackGasLimit);
    }

    /// Open the envelope — owner-triggered at first use (the client fires this alongside the
    /// Hitter's first raid; reveal-on-first-use per B5). Entropy fee as msg.value, excess refunded.
    function revealFavor(uint256 id) external payable nonReentrant returns (uint64 seq) {
        if (ownerOf(id) != msg.sender) revert NotHitterOwner();
        if (!sealed_[id]) revert AlreadyRevealed();
        if (revealPending[id]) revert RevealInFlight();
        revealPending[id] = true;

        uint256 fee = entropyFee();
        if (msg.value < fee) revert InsufficientFee();
        seq = entropy.requestV2{value: fee}(entropyProvider, favorCommit[id], callbackGasLimit);
        seqToHitter[seq] = id;
        emit FavorRevealRequested(id, seq);

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Map the verified word onto the published bands (the Degen `_multiplierFor` read).
    function entropyCallback(uint64 sequenceNumber, address, bytes32 randomNumber) internal override nonReentrant {
        uint256 id = seqToHitter[sequenceNumber];
        if (id == 0 || !sealed_[id]) revert AlreadyRevealed();
        sealed_[id] = false;
        revealPending[id] = false;
        favorOf[id] = _bandFor(uint256(keccak256(abi.encodePacked(randomNumber, favorCommit[id]))) % PPM);
        emit FavorRevealed(id, favorOf[id], false);
    }

    /// The reclaim valve: a Hitter sealed past the timeout (withheld reveal, abandoned mint) can be
    /// opened by ANYONE at the FLOOR band — Common, the worst outcome, so forcing can't be gamed;
    /// it only guarantees no NFT stays sealed forever.
    function forceRevealFloor(uint256 id) external {
        _requireOwned(id);
        if (!sealed_[id]) revert AlreadyRevealed();
        if (block.timestamp < uint256(mintedAt[id]) + FORCE_REVEAL_TIMEOUT) revert NotYetForceable();
        sealed_[id] = false;
        revealPending[id] = false;
        favorOf[id] = 0; // Common — "an empty envelope"
        emit FavorRevealed(id, 0, true);
    }

    function _bandFor(uint256 roll) internal pure returns (uint8) {
        if (roll < CUM_COMMON_PPM) return 0;
        if (roll < CUM_UNCOMMON_PPM) return 1;
        if (roll < CUM_RARE_PPM) return 2;
        return 3;
    }

    // ---------------------------------------------------------------- game flags (RAID_MODULE only)

    modifier onlyRaid() {
        if (msg.sender != controller.moduleOf(GameRoles.RAID_MODULE)) revert NotRaidModule();
        _;
    }

    function noteAttempt(uint256 id) external onlyRaid {
        lastAttemptAt[id] = uint64(block.timestamp);
        emit AttemptNoted(id, uint64(block.timestamp));
    }

    function hospitalize(uint256 id) external onlyRaid {
        hospitalUntil[id] = uint64(block.timestamp) + 48 hours;
        emit Hospitalized(id, hospitalUntil[id]);
    }

    // ---------------------------------------------------------------- metadata (REDACTED)

    /// Case-file metadata: name + sealed/revealed status only. Art and the full dossier render are
    /// the indexer/UI's job in Phase 0.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        string memory status = sealed_[id]
            ? '"sealed"'
            : string.concat('"', _bandName(favorOf[id]), '"');
        return string.concat(
            "data:application/json;utf8,",
            '{"name":"HITTER #',
            id.toString(),
            ' [REDACTED]","description":"Crew unit of the Developing On-chain Nation. File sealed by order of the Commission.","attributes":[{"trait_type":"Favor","value":',
            status,
            "}]}"
        );
    }

    function _bandName(uint8 band) internal pure returns (string memory) {
        if (band == 0) return "Empty envelope";
        if (band == 1) return "A small favor";
        if (band == 2) return "A real favor";
        return "The Don owes you";
    }
}
