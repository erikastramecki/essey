// D.O.N. game — ABIs verified function-by-function against the AS-BUILT contracts in
// rh-chain/src/game/*.sol (testnet deploy, block 100489472). The architecture sketch's separate
// LoadoutRegistry/BriefPoster/TraitSeal were CONSOLIDATED: EIP-712 loadout settlement and brief
// storage live inside MissionBoard, and the sealed Favor slot lives inside HitterNFT — the
// missionBoardAbi/hitterAbi below are therefore the whole surface for those roles.
import { parseAbi } from "viem";

// The Loadout struct — EIP-712 payload AND `depart` calldata struct (MissionBoard.sol L55-62;
// must stay in lockstep with LOADOUT_TYPES in loadout.ts / LOADOUT_TYPEHASH on-chain).
export const missionBoardAbi = parseAbi([
  "struct Loadout { uint256 donId; uint64 briefId; uint256 provision; bytes32 garrisonHash; uint256 nonce; uint256 deadline; }",
  "function depart(Loadout l, bytes sig) returns (uint64 missionId)",
  "function resolve(uint64 missionId) payable",
  "function reclaim(uint64 missionId)",
  "function entropyFee() view returns (uint256)",
  "function isAway(uint256 donId) view returns (bool)",
  "function garrisonHashOf(uint256 donId) view returns (bytes32)",
  "function lastSettledNonce(uint256 donId) view returns (uint256)",
  "function activeMissionOf(uint256 donId) view returns (uint64)",
  "function hasDispatched(uint256 donId) view returns (bool)",
  "function kitClaimed(uint256 donId) view returns (bool)",
  "function kitClassOf(uint256 donId) view returns (uint8)",
  "function missionCount() view returns (uint64)",
  // public mapping getter — Mission struct flattened in field order
  "function missions(uint64 missionId) view returns (uint256 donId, uint64 briefId, uint64 departAt, uint64 due, bytes32 garrisonHash, uint256 provision, uint256 reserved, bool entropyRequested, bool settled)",
  "function briefCount() view returns (uint64)",
  // public mapping getter — Brief struct flattened in field order
  "function briefs(uint64 briefId) view returns (bool live, uint8 tier, uint32 duration, uint32 cumSuccessPpm, uint32 cumPartialPpm, uint256 successPay, uint256 partialPay, uint256 dispatchFee, uint256 provisionCap, uint256 betaBps, string codename)",
  "function missionBudget() view returns (uint256)",
  "event BriefPosted(uint64 indexed briefId, string codename, uint8 tier, uint32 duration)",
  "event Departed(uint64 indexed missionId, uint256 indexed donId, uint64 indexed briefId, uint256 provision, uint256 fee, uint256 reserved, bytes32 garrisonHash)",
  "event ResolveRequested(uint64 indexed missionId, uint64 seq)",
  "event Resolved(uint64 indexed missionId, uint256 indexed donId, uint8 outcome, uint256 payout)",
  "event Reclaimed(uint64 indexed missionId, uint256 indexed donId, uint256 payout)",
]);

/// Loadout settlement is INSIDE MissionBoard as-built — alias, kept for call-site clarity.
export const loadoutRegistryAbi = missionBoardAbi;

export const houseDeedAbi = parseAbi([
  "function deedOf(uint256 donId) view returns (uint256)",
  "function donOf(uint256 deedId) view returns (uint256)",
  "function tier(uint256 deedId) view returns (uint8)",
  "function tierOf(uint256 donId) view returns (uint8)",
  "function deployCapOf(uint256 donId) view returns (uint256)",
  "function defenseOf(uint256 donId) view returns (uint256)",
  "function garrisonSlotsOf(uint256 donId) view returns (uint256)",
  "function tierStats(uint8 t) pure returns ((uint256 upgradeFee, uint256 deployCap, uint16 defense, uint8 garrisonSlots))",
  "function upgrade(uint256 donId)",
  "event SafehouseClaimed(uint256 indexed donId, uint256 indexed deedId)",
  "event Upgraded(uint256 indexed donId, uint256 indexed deedId, uint8 toTier, uint256 fee)",
]);

export const houseEscrowAbi = parseAbi([
  "function deployedOf(uint256 donId) view returns (uint256)",
  "function hopperOf(uint256 donId) view returns (uint256)",
  "function damageBps(uint256 donId) view returns (uint256)",
  "function damageBaseDeployed(uint256 donId) view returns (uint256)",
  "function pendingYieldOf(uint256 donId) view returns (uint256)",
  "function repairFeeOf(uint256 donId) view returns (uint256)",
  "function deploy(uint256 donId, uint256 amount)",
  "function bank(uint256 donId, uint256 fromDeployed, uint256 fromHopper)",
  "function repair(uint256 donId)",
  "event Deployed(uint256 indexed donId, uint256 amount)",
  "event Banked(uint256 indexed donId, uint256 fromDeployed, uint256 fromHopper)",
  "event LootCredited(uint256 indexed donId, uint256 amount)",
  "event YieldAccrued(uint256 indexed donId, uint256 amount)",
  "event RaidApplied(uint256 indexed donId, uint8 outcome, uint256 taken, uint256 tax)",
  "event Damaged(uint256 indexed donId)",
  "event Repaired(uint256 indexed donId, uint256 fee)",
  "event StipendPaid(uint256 indexed donId, uint256 amount)",
]);

export const raidEngineAbi = parseAbi([
  "function commit(uint256 attackerDonId, bytes32 h) returns (uint64 raidId)",
  "function reveal(uint64 raidId, uint256[] hitterIds, uint256 targetDonId, bytes32 salt) payable returns (uint64 seq)",
  "function revealGarrison(uint64 raidId, uint256[] garrisonIds, bytes32 salt)",
  "function floorSettle(uint64 raidId)",
  "function reclaimRaid(uint64 raidId)",
  "function forfeit(uint64 raidId)",
  "function entropyFee() view returns (uint256)",
  "function crewOf(uint64 raidId) view returns (uint256[])",
  // public mapping getter — Raid struct flattened in field order (state is the RaidState enum: uint8)
  "function raids(uint64 raidId) view returns (uint256 attackerDon, uint256 targetDon, uint64 committedAt, uint64 revealedAt, bytes32 commitHash, bytes32 garrisonHash, uint256 attackPower, uint256 defensePower, bytes32 word, uint8 state, bool wordReceived, bool garrisonRevealed)",
  "function heatUntil(uint256 targetDonId) view returns (uint64)",
  "function bigLockUntil(uint256 targetDonId) view returns (uint64)",
  "function COMMIT_FEE() view returns (uint256)",
  "event RaidCommitted(uint64 indexed raidId, uint256 indexed attackerDon, bytes32 commitHash)",
  "event RaidRevealed(uint64 indexed raidId, uint256 indexed attackerDon, uint256 indexed targetDon, uint256 attackPower, uint64 seq)",
  "event GarrisonRevealed(uint64 indexed raidId, uint256 indexed targetDon, uint256 defensePower)",
  // outcome: 0 MISS / 1 COMMON hit / 2 BIG score / 4 RECLAIMED (entropy withheld). floorSettle
  // runs the REAL roll (garrison counts zero) so it also emits 0/1/2 — outcome 3 is never emitted.
  "event RaidSettled(uint64 indexed raidId, uint8 outcome, uint256 pHitPpm, uint256 taken, uint256 tax)",
  "event HitterDown(uint64 indexed raidId, uint256 indexed hitterId)",
  "event RaidForfeited(uint64 indexed raidId)",
]);

export const hitterAbi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function ownerOf(uint256 id) view returns (address)",
  "function totalMinted() view returns (uint256)",
  "function MINT_PRICE() view returns (uint256)",
  // mint burns MINT_PRICE Scrip from the payer Don's vault — no ETH, not payable
  "function mint(uint256 payerDonId) returns (uint256 id)",
  "function entropyFee() view returns (uint256)",
  "function revealFavor(uint256 id) payable returns (uint64 seq)",
  "function forceRevealFloor(uint256 id)",
  // the sealed-slot state (the Favor) lives here as-built — public mapping named `sealed_`
  "function sealed_(uint256 id) view returns (bool)",
  "function favorOf(uint256 id) view returns (uint8)",
  "function revealPending(uint256 id) view returns (bool)",
  "function lastAttemptAt(uint256 id) view returns (uint64)",
  "function hospitalUntil(uint256 id) view returns (uint64)",
  "function tokenURI(uint256 id) view returns (string)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
  "event HitterMinted(uint256 indexed id, uint256 indexed payerDonId, address indexed to, bytes32 commit)",
  "event FavorRevealRequested(uint256 indexed id, uint64 seq)",
  "event FavorRevealed(uint256 indexed id, uint8 band, bool forced)",
]);

/// The Favor lives INSIDE HitterNFT as-built — alias, kept for call-site clarity.
export const traitSealAbi = hitterAbi;

export const scripAbi = parseAbi([
  "function seasonId() view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function balanceOfAt(uint256 season, address account) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function totalBurned() view returns (uint256)",
]);
