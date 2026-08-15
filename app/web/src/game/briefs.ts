// The job-board data — reconciled to the AS-BUILT MissionBoard: 4 core briefs seeded at deploy
// (ids 1-4), 2 testnet proving-ground wires (ids 5-6) and the DEEP RUN expedition (id 7), each
// immutable once posted, each with a FIXED duration and one cumPpm odds ladder.
// Contract semantics (MissionBoard.entropyCallback): roll ∈ [0, 1e6);
//   roll < cumSuccessPpm                 => SUCCESS  (successPay + provision × betaBps / 1e4)
//   cumSuccessPpm <= roll < cumPartialPpm => PARTIAL ("the job went sideways" — partialPay)
//   else                                  => FAIL    (nothing lands; provision burned at dispatch)
// Payouts are SCRIP minted to the House hopper; dispatch fee + provision burn from the vault.
import type { SceneKey } from "./stills";

export type BriefKey =
  "paper" | "glass" | "pow" | "zero" | "deeprun" | "sprint" | "windowjob";

/// Scrip amount with 2-dp precision → 18-dec bigint.
const S = (x: number): bigint => BigInt(Math.round(x * 100)) * 10n ** 16n;

export type GameBrief = {
  key: BriefKey;
  chainId: bigint; // the posted on-chain briefId (1..7)
  no: string;
  code: string;
  tab: string;
  arch: string;
  durationH: number; // FIXED per brief on-chain (Brief.duration)
  rating: "low" | "std" | "steep" | "unins";
  ratingLabel: string;
  featured: boolean;
  riskBlocks: number;
  exhibit: string;
  scene: SceneKey;
  job: string;
  takeLine: string;
  risk: string;
  word: string;
  odds: [number, number, number]; // [success, partial, fail] % — straight off the cumPpm bands
  successPay: bigint;
  partialPay: bigint; // Scrip
  dispatchFee: bigint;
  provisionCap: bigint; // Scrip (fee burned; provision burned, boosts success)
  betaBps: bigint; // success-payout boost per provisioned Scrip, in bps
};

/// Only the four DeployGame.s.sol launch briefs are posted on chain. sprint/windowjob mirror the
/// E2E harness rows (GameE2E.s.sol) and deeprun has no counterpart at all — listing any of them
/// sends players at a briefId that reverts BriefNotLive. Re-add a key here only once it is posted.
export const BRIEF_ORDER: BriefKey[] = ["paper", "glass", "pow", "zero"];

/// On-chain briefId for a lore archetype — the posted ids, verbatim.
export const briefIdFor = (key: BriefKey): bigint => BRIEFS[key].chainId;

export const BRIEFS: Record<BriefKey, GameBrief> = {
  paper: {
    key: "paper",
    chainId: 1n,
    no: "4470",
    code: "PAPER ROUTE",
    tab: "the treasury run · ledger row",
    arch: "The Treasury Run · Ledger Row",
    durationH: 3,
    rating: "low",
    ratingLabel: "LOW",
    featured: false,
    riskBlocks: 1,
    exhibit: "EXHIBIT 1-A · the armored run, on schedule",
    scene: "armored-run",
    job: "Ride escort on the armored run from the Long Window to the Registry.",
    takeLine:
      "36 Scrip on a clean run, 14.4 if it goes sideways. Small, near-certain, dull as paint.",
    risk: "Approximately none, which is why it pays approximately that.",
    word: "The Row's armored cars run on a schedule you could set a watch by, and the schedule does most of the work. There's no shame in the Paper Route. There's barely any interest, either.",
    odds: [78, 15, 7],
    successPay: S(36),
    partialPay: S(14.4),
    dispatchFee: S(0.45),
    provisionCap: S(15),
    betaBps: 11538n,
  },
  glass: {
    key: "glass",
    chainId: 2n,
    no: "4468",
    code: "GLASS HARVEST · RUSH",
    tab: "the chip-fab job · the foundry",
    arch: "The Chip-Fab Job · The Foundry",
    durationH: 5,
    rating: "std",
    ratingLabel: "STANDARD",
    featured: false,
    riskBlocks: 4,
    exhibit: "EXHIBIT 2-A · dock 4 at shift change",
    scene: "fab-dock",
    job: "Walk finished wafers out of the fab through Dock 4 during the shift change.",
    takeLine: "75 Scrip on a clean walk-out, 30 if the airlock cycles early.",
    risk: "Prime target the whole window — everyone on the Tape knows what Dock 4 moves, and your House stands open while you're gloved up.",
    word: 'The fab runs three shifts and the airlocks cycle slowest at handover — eleven minutes when the cleanline watches itself. The wafers manifest as "glass, industrial," which is technically true and legally hilarious. Try to look bored.',
    odds: [70, 18, 12],
    successPay: S(75),
    partialPay: S(30),
    dispatchFee: S(0.87),
    provisionCap: S(30),
    betaBps: 12857n,
  },
  pow: {
    key: "pow",
    chainId: 3n,
    no: "4471",
    code: "PROOF OF WORK",
    tab: "the rig job · the racks",
    arch: "The Rig Job · The Racks",
    durationH: 12,
    rating: "steep",
    ratingLabel: "STEEP",
    featured: true,
    riskBlocks: 5,
    exhibit: "EXHIBIT 4-C · the rig hall, through the fence",
    scene: "rig-hall",
    job: "Cut the Rig's output over to your wallet for one power cycle.",
    takeLine:
      "236 Scrip for the full cycle, 94.4 for a partial cut. The peg is real — say so like it's ordinary.",
    risk: "Feast or famine — the take's chart is the steepest thing in the district, and the district includes the Substation.",
    word: "The Rig turns the city's power bill into digital gold and doesn't much care whose address is on the payout line — that's a config file, and config files can be edited by anyone standing in the right hall with the right badge at the right hour. Twelve hours on the swing shift, one cutover, no alarms: the machines genuinely cannot tell. You did the work. Here's the proof.",
    odds: [60, 22, 18],
    successPay: S(236),
    partialPay: S(94.4),
    dispatchFee: S(2.44),
    provisionCap: S(80),
    betaBps: 15000n,
  },
  zero: {
    key: "zero",
    chainId: 4n,
    no: "4474",
    code: "ABSOLUTE ZERO",
    tab: "the quantum grab · the kelvin quarter",
    arch: "The Quantum Grab · The Kelvin Quarter",
    durationH: 24,
    rating: "unins",
    ratingLabel: "UNINSURABLE",
    featured: false,
    riskBlocks: 8,
    exhibit: "EXHIBIT 9-K · annex K, fridge cycle",
    scene: "cryo-annex",
    job: "Lift the prototype from Annex K while the refrigerators are cycling.",
    takeLine:
      "2,775 Scrip if the dewar makes it out. 222 for fragments. Usually: nothing.",
    risk: "The Fixer won't underwrite this district. Read that sentence twice.",
    word: "The fridge cycle gives you one warm hour in twenty-four; the prototype travels in a dewar the size of a coffin and complains about vibration. A full day exposed, long odds, and a number on the other side with more zeros than sense. That's not a warning. That's the pitch.",
    odds: [12, 23, 65],
    successPay: S(2775),
    partialPay: S(222),
    dispatchFee: S(5.76),
    provisionCap: S(200),
    betaBps: 75000n,
  },
  // ── THE EXPEDITION (brief 7, posted 2026-08-13). The ONE sanctioned exception to the flat-90
  // provision rule every other brief obeys: betaBps 9000 against a 12% success band is a marginal
  // provision RTP of 10.8%, i.e. a real-loss stake. Opt-in wildcard tier (tier 5 on-chain), and the
  // player copy has to say so plainly — this is the only posting where provisioning is -EV.
  // Worst-case reservation at full provision: 800 + 500 × 0.9 = 1,250 Scrip.
  deeprun: {
    key: "deeprun",
    chainId: 7n,
    no: "4477",
    code: "DEEP RUN",
    tab: "the expedition · past the grid",
    arch: "The Expedition · Past The Grid",
    durationH: 16,
    rating: "unins",
    ratingLabel: "WILDCARD",
    featured: true,
    riskBlocks: 8,
    exhibit: "EXHIBIT 7-D · the last lit block, 04:10",
    scene: "armored-run",
    job: "Take the long haul past the last lit block, out where the grid stops and the map gives up.",
    takeLine:
      "800 Scrip if you come back loaded, 60 for scraps. Seven runs in ten come back with neither.",
    risk: "The only posting on the board where your stake is a real loss. Provision the full 500 and a clean return adds 450 on top, but clean lands 12% of the time: about 54 Scrip back on 500 staked. Every other brief hands back 90 on the hundred. This one does not, and that is the trade you are opting into.",
    word: "Sixteen hours out, sixteen hours your House stands open, and no wire to tell you how it's going. Nobody watches the Deep Run because there is nothing out there to watch from. Most crews come back with a story and an empty truck. About one in eight comes back with the thing that pays for the year. Provision it or don't. The dispatcher has seen both endings and won't pretend to know which one is yours.",
    odds: [12, 18, 70],
    successPay: S(800),
    partialPay: S(60),
    dispatchFee: S(1.6),
    provisionCap: S(500),
    betaBps: 9000n,
  },
  // ── PROVING-GROUND WIRES (testnet only, founder-requested faucet 2026-08-13): the admin-posted
  // fast briefs 5/6, surfaced so testers can bankroll Hitters + raids without waiting out a 3h job.
  // The 75s run IS the Scrip faucet — it flows through the real mission engine (budget-minted,
  // worst-case reserved) instead of a side-door mint the sealed controller couldn't add anyway.
  // STRIP BOTH before any real-value season.
  sprint: {
    key: "sprint",
    chainId: 5n,
    no: "9105",
    code: "MILK RUN",
    tab: "proving ground · 75s",
    arch: "Proving Ground · The Milk Run",
    durationH: 0.021,
    rating: "low",
    ratingLabel: "TRAINING",
    featured: true,
    riskBlocks: 1,
    exhibit: "PROVING GROUND · the testnet training wire",
    scene: "milk-corner",
    job: "A 75-second answer for the family bankroll. Run it once, fund your whole night.",
    takeLine:
      "6,000 Scrip on a clean run: a Hitter off the rack is 900, a hit order is 50. Do the math.",
    risk: "Training wire. The city looks the other way.",
    word: "Every recruit runs the milk route once. Nobody talks about it, everybody has done it. The pay is a season-zero courtesy: this wire exists so you can learn the life before the life costs you anything real.",
    odds: [98.5, 1.45, 0.05],
    successPay: S(6000),
    partialPay: S(2400),
    dispatchFee: S(1),
    provisionCap: 0n,
    betaBps: 0n,
  },
  windowjob: {
    key: "windowjob",
    chainId: 6n,
    no: "9106",
    code: "OPEN WINDOW",
    tab: "proving ground · 20min",
    arch: "Proving Ground · The Open Window",
    durationH: 0.33,
    rating: "low",
    ratingLabel: "TRAINING",
    featured: false,
    riskBlocks: 1,
    exhibit: "PROVING GROUND · a raidable away window",
    scene: "open-window",
    job: "Twenty minutes in the field, and your House stands open the whole while.",
    takeLine: "100 Scrip on a clean run. The real pay is the lesson.",
    risk: "The raid-practice wire: your hopper is exposed for 20 minutes. That is the point.",
    word: "You want to learn how robberies feel from both sides? Take the window job and tell a friend when you leave. The reveal clock runs ten minutes, the window runs twenty. Arithmetic is a weapon.",
    odds: [98.5, 1.45, 0.05],
    successPay: S(100),
    partialPay: S(40),
    dispatchFee: S(1),
    provisionCap: 0n,
    betaBps: 0n,
  },
};

/// The season header — Phase 0 launch season.
export const SEASON = { id: 1, name: "The Season of the First Bell" };

/// House tier names. Phase 0 ships tiers 0-1 (Safehouse, Row House).
export const HOUSE_TIERS = [
  "Safehouse",
  "Row House",
  "Brownstone",
  "Estate",
  "Compound",
] as const;
export const HOUSE_TIER_LINES = [
  "new in town, and welcome",
  "the first purchase decision",
  "established, with opinions",
  "serious capital",
  "the endgame, and the target",
] as const;
