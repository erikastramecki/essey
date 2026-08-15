// Essey MCP — the game half (D.O.N.), read-only.
//
// Three laws this file holds to:
//   1. FREE AND PUBLIC — an edge only some players have is a whale advantage.
//   2. FOG FIREWALL — expose only what a stranger with an RPC URL could already derive. The game's
//      hidden state is hidden cryptographically; an advisor that leaked it would kill the game.
//   3. ADVISE, NEVER ACT — read-only, no key, no calldata.
//
// SHIPS WITH EVERY GAME CHANGE. When one of these moves, so does the other, in the same commit:
//   contracts redeployed        -> GAME addresses
//   read signature changed      -> ABI fragments
//   mechanic added or retired   -> donPlaybook() AND the instructions block in essey-mcp.mjs
//   trait -> stat mapping changes -> STAT_READING in donSheet() AND the build guidance in donPlaybook()
//   payout/odds/fee semantics   -> the EV arithmetic in donBoard()
//   new hidden-information rule -> the whatNobodyCanDo list
//   denomination changed        -> every unit helper and label
// v2 pending: the whole game layer redeploys and Scrip is removed. Verify against chain, not docs.

import { createPublicClient, http, defineChain, formatUnits } from "viem";

// ---------------------------------------------------------------- deployment

// RH testnet, deploy block 100489472. The Don collection is the real one — the game plays with the
// Dons people actually own.
const GAME = {
  don:         "0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c",
  missionBoard:"0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1",
  houseDeed:   "0x689dF249cEFF6e28d3EB7dDE125CEa7f7f29700d",
  houseEscrow: "0x24cB6Db8F4d52d78742bc0304B08710B053cdB7e",
  hitter:      "0x5C714163454D525906Ab6273d1cec701A5399103",
  scrip:       "0x31D04bd5b1c1eAE56698F1A90C3fEe3e590f6E93",
  affinity:    "0x2d9CC510D464977F0Eb597237F467b453CB3e484",
};

// The sheet decodes from the trait preimage, which lives server-side, so it comes from the site
// rather than from a chain read. previewSheet is the same pure function either way.
const SITE = process.env.ESSEY_SITE || "https://essey.xyz";

const rhTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain (testnet)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.chain.robinhood.com/rpc"] } },
});

const client = createPublicClient({ chain: rhTestnet, transport: http() });

const ABI = {
  don:     [{ type: "function", name: "vaultOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
            { type: "function", name: "ownerOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] }],
  scrip:   [{ type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }],
  escrow:  [{ type: "function", name: "deployedOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
            { type: "function", name: "hopperOf",   stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
            { type: "function", name: "damageBps",  stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] }],
  deed:    [{ type: "function", name: "tierOf",          stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint8" }] },
            { type: "function", name: "garrisonSlotsOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] }],
  board:   [{ type: "function", name: "isAway",     stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "bool" }] },
            { type: "function", name: "briefCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
            { type: "function", name: "briefs",     stateMutability: "view", inputs: [{ type: "uint64" }], outputs: [
              { name: "live", type: "bool" }, { name: "tier", type: "uint8" }, { name: "duration", type: "uint32" },
              { name: "cumSuccessPpm", type: "uint32" }, { name: "cumPartialPpm", type: "uint32" },
              { name: "successPay", type: "uint256" }, { name: "partialPay", type: "uint256" },
              { name: "dispatchFee", type: "uint256" }, { name: "provisionCap", type: "uint256" },
              { name: "betaBps", type: "uint256" }, { name: "codename", type: "string" }] }],
};

const scrip = (v) => Number(formatUnits(v, 18));
const read = (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args });

// ---------------------------------------------------------------- don_sheet

// Every reading is what the stat WILL govern. The deployed Phase-0 MissionBoard and RaidEngine do
// not read this registry — verified on chain, they have no registry pointer at all — so nothing here
// moves an outcome yet. Present-tense phrasing would be a lie to a player deciding what to buy.
const STAT_READING = {
  rpBps: "attack — will raise power when THIS Don is the raider",
  hdBps: "defense — will raise power when this Don is the one being hit",
  hdFlat: "flat defense, will apply before the percentage",
  nrvBps: "nerve — will shift mission success directly, in points of probability",
  lckBps: "luck — will nudge discrete lotteries, not mission odds",
  cmdGarrisonBps: "command — will make each garrison hitter count for more",
  cmdFactionBps: "command — will raise mission success on faction jobs only",
  cmdCooldownBps: "command — will cut the crew hunt cooldown",
  feeDiscBps: "yield — will cut fees the Don pays, capped at 25%",
  resHospBps: "resilience — will cut this Don's OWN hospital lockout",
  resPetrifyBps: "resilience — will lengthen a FAILED attacker's lockout",
  resAmbushBps: "resilience — will cut the chance of being ambushed in the field",
  guiTier: "guile — how deep a read the Scout will return, 0 to 2",
  yldCapSteps: "yield — extra deploy/provision headroom",
};

const NOT_LIVE =
  "NOT YET LIVE IN PLAY. This sheet is real and permanently committed — it decodes deterministically " +
  "from the Don's on-chain traits and can never change under it. But the deployed Phase-0 contracts " +
  "do not read it: MissionBoard and RaidEngine hold no registry pointer, so no job, raid or garrison " +
  "outcome is affected by any number here today. Treat it as what this Don WILL be, never as an edge " +
  "it currently has, and never tell a player a stat improved their odds on a job they just ran.";

export async function donSheet({ donId }) {
  const r = await fetch(`${SITE}/api/don/${Number(donId)}`).catch(() => null);
  const d = r && r.ok ? await r.json().catch(() => null) : null;
  if (!d) return { donId: Number(donId), sheet: null, note: "Could not reach the metadata service." };
  if (!d.stats)
    return {
      donId: Number(donId),
      sheet: null,
      traits: d.attributes ?? [],
      note: "This Don has no stat sheet: its trait preimage was never recorded, so nothing can be decoded. The owner can restore it by re-opening the builder. Do not guess its stats.",
    };

  const nonZero = Object.entries(d.stats).filter(
    ([k, v]) => typeof v === "number" && v > 0 && k in STAT_READING,
  );
  return {
    donId: Number(donId),
    archetype: d.stats.archetype,
    sheet: d.stats,
    traits: d.attributes ?? [],
    strengths: nonZero.map(([k, v]) => ({ stat: k, value: v, means: STAT_READING[k] })),
    notYetLive: NOT_LIVE,
    law: "Edge Budget: every sheet is saturated onto the SAME total budget. A rarer Don shifts WHERE its edge sits, never how much edge it has. There is no strictly stronger Don, so never tell a player one build beats another outright — tell them which jobs and which fights their edge actually fits.",
  };
}

// ---------------------------------------------------------------- don_state

export async function donState({ donId }) {
  const id = BigInt(donId);
  const [vault, owner] = await Promise.all([
    read(GAME.don, ABI.don, "vaultOf", [id]),
    read(GAME.don, ABI.don, "ownerOf", [id]).catch(() => null),
  ]);
  const [banked, deployed, hopper, damage, tier, garrison, away] = await Promise.all([
    read(GAME.scrip, ABI.scrip, "balanceOf", [vault]),
    read(GAME.houseEscrow, ABI.escrow, "deployedOf", [id]),
    read(GAME.houseEscrow, ABI.escrow, "hopperOf", [id]),
    read(GAME.houseEscrow, ABI.escrow, "damageBps", [id]).catch(() => 0n),
    read(GAME.houseDeed, ABI.deed, "tierOf", [id]).catch(() => 0),
    read(GAME.houseDeed, ABI.deed, "garrisonSlotsOf", [id]).catch(() => 0n),
    read(GAME.missionBoard, ABI.board, "isAway", [id]).catch(() => false),
  ]);

  const exposed = scrip(hopper) + scrip(deployed);
  const sheet = await donSheet({ donId }).catch(() => null);
  return {
    donId: Number(id),
    owner,
    vault,
    away,
    archetype: sheet?.archetype ?? null,
    sheet: sheet?.sheet ?? null,
    strengths: sheet?.strengths ?? [],
    houseTier: Number(tier),
    garrisonSlots: Number(garrison),
    damageBps: Number(damage),
    scrip: {
      banked: scrip(banked),
      deployed: scrip(deployed),
      hopper: scrip(hopper),
      exposed,
    },
    reading: {
      banked: "In the Don's vault. Cannot be raided, ever. It also earns nothing.",
      deployed: "Working capital in the House. Earns, and a raider can reach a capped slice of it.",
      hopper: "Unbanked winnings. The most exposed money you have, and the cheapest for a raider to take.",
      raidableWhile: away
        ? "This Don is AWAY, which is when a raid can legally land. Its exposed Scrip is reachable right now."
        : "This Don is HOME. A raid cannot be revealed against a Don that is not away.",
    },
    risks: [
      "Exposure is a choice. Banking is free and complete protection, so anything left exposed is a deliberate bet that the yield beats the odds of being hit.",
      "Testnet Scrip has no monetary value. Treat these numbers as a game score, not money.",
      "This is a public-chain read. Any other player can compute your exposure the same way, so assume you are visible.",
    ],
  };
}

// ---------------------------------------------------------------- don_board

export async function donBoard() {
  const count = await read(GAME.missionBoard, ABI.board, "briefCount");
  const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i + 1));
  const raw = await Promise.all(ids.map((i) => read(GAME.missionBoard, ABI.board, "briefs", [i])));

  const jobs = raw.map((b, i) => {
    const [live, tier, duration, cumSuccessPpm, cumPartialPpm,
           successPay, partialPay, dispatchFee, provisionCap, betaBps, codename] = b;
    const pSuccess = Number(cumSuccessPpm) / 1e6;
    const pPartial = (Number(cumPartialPpm) - Number(cumSuccessPpm)) / 1e6;
    const pFail = 1 - pSuccess - pPartial;
    const fee = scrip(dispatchFee);
    const cap = scrip(provisionCap);
    const beta = Number(betaBps) / 1e4;
    const success = scrip(successPay);
    const partial = scrip(partialPay);

    const evBare = pSuccess * success + pPartial * partial - fee;
    const evLoaded = pSuccess * (success + cap * beta) + pPartial * partial - fee - cap;
    const marginalRtp = pSuccess * beta;

    return {
      briefId: i + 1,
      codename,
      live,
      tier: Number(tier),
      durationHours: Number(duration) / 3600,
      odds: { success: +(pSuccess * 100).toFixed(2), sideways: +(pPartial * 100).toFixed(2), fail: +(pFail * 100).toFixed(2) },
      pays: { success, sideways: partial },
      dispatchFee: fee,
      provisionCap: cap,
      provisionMultiplier: beta,
      expectedValue: { noProvision: +evBare.toFixed(2), fullProvision: +evLoaded.toFixed(2) },
      marginalReturnOnProvision: +(marginalRtp * 100).toFixed(1),
    };
  });

  return {
    jobs: jobs.filter((j) => j.live),
    howToReadThis: [
      "Odds come straight from the contract's probability bands, not from documentation.",
      "Provision is BURNED at dispatch. It only comes back through the success branch, multiplied by the brief's own multiplier, so 'marginalReturnOnProvision' is what each provisioned point is really worth.",
      "Most briefs return about 90 on the hundred provisioned. A brief that returns far less is a deliberate wildcard, not a bug: it buys a bigger jackpot with a real loss band.",
      "A Don is AWAY for the whole duration, which is exactly when it can be raided. A long job is a long window of exposure.",
    ],
    risks: [
      "Expected value is an average over many attempts. Any single job is one roll, and the fail band is usually the biggest band.",
      "The randomness is drawn when the job resolves, not when you dispatch, so no amount of reading can predict an outcome.",
      "Bank your hopper before a long job unless you intend the exposure. Being away is what makes you reachable.",
    ],
  };
}

// ---------------------------------------------------------------- don_playbook

export async function donPlaybook() {
  return {
    theShape: [
      "You own a Don. The Don owns a House. Scrip sits in one of three places, and choosing between them is the game.",
      "VAULT: banked, untouchable, earns nothing. DEPLOYED: working capital that earns. HOPPER: unbanked winnings, the most exposed money on the board.",
      "Send the Don on a job and it is AWAY for that job's duration. Away is the only state in which a raid can land on it.",
      "Other players raid you for what is exposed. Banking is free, complete protection, which is why banking is the actual skill.",
    ],
    theDecisions: [
      "Bank or stay exposed. This is the only decision that matters most days.",
      "Which brief, and how much to provision. Provision buys a bigger success payout and is burned whether or not you succeed.",
      "How long a job to take. Longer jobs pay more and leave you reachable for longer.",
      "Whether to raid, and whom. A raid costs a fee that burns on a miss, so a bad target is a real loss.",
    ],
    theBuild: [
      "NOT YET LIVE: the stat sheet is committed and readable, but the deployed Phase-0 MissionBoard and RaidEngine do not consult it. No number on a sheet changes a job, raid or garrison outcome today. Say this before any advice that leans on traits.",
      "A Don's traits are its stats, not decoration — they are what the Don WILL bring when the sheet is wired in. Read them with don_sheet.",
      "EDGE BUDGET, the law that governs every sheet: all stats are saturated onto the same total budget, so a rarer Don shifts WHERE its edge sits and never how much edge it has. No build is strictly stronger than another.",
      "So the honest question is never 'is this Don good' but 'what is this Don's edge WILL BE for'. Attack and command point at raiding. Defense, flat defense and petrify point at being a hard target worth turtling. Nerve points at running more jobs. Guile buys deeper Scout reads. Yield cuts the fees a heavy player pays most.",
      "Archetype is a label FOR that shape, resolved deterministically from the sheet. It is a summary, not an extra power.",
      "A Don with no recorded preimage has no sheet at all. Say so and stop; never estimate stats from the picture.",
    ],
    whatAnAdvisorCanDo: [
      "Compute expected value on any brief at any provision level, from live contract odds.",
      "Read your exposure and tell you what a raider could actually reach right now.",
      "Compare briefs on return per hour of exposure rather than on headline payout.",
      "Read a Don's sheet and say which jobs and which fights its edge actually suits — and, when buying, which of two Dons fits the way that player already plays.",
    ],
    whatNobodyCanDo: [
      "See a defender's garrison before it is revealed. It is committed as a hash, so it is unreadable until they open it.",
      "See who else has a raid committed against a target. Pending raids do not name their target on chain.",
      "Predict any outcome. The randomness does not exist until the moment of settlement.",
      "Tell a bait House from a fat one. That is the core skill the game refuses to automate, and an advisor that claimed otherwise would be lying to you.",
      "Rank Dons by raw power. The Edge Budget makes that question meaningless, and answering it anyway would sell someone a Don on a false premise.",
    ],
    risks: [
      "This is a competitive game where other players take real positions from you. Advice improves your odds; it does not remove the risk.",
      "Testnet Scrip is a score, not money.",
    ],
  };
}

// ---------------------------------------------------------------- registry

export const GAME_TOOLS = [
  { name: "don_state", description:
      "Read one Don's live position in the D.O.N. game: banked, deployed and hopper Scrip, whether it is away, its House tier and garrison slots. Use this first when someone tells you which Don is theirs.",
    inputSchema: { type: "object", properties: { donId: { type: "number", description: "The Don's token id" } }, required: ["donId"] } },
  { name: "don_sheet", description:
      "Read a Don's stat sheet — archetype plus every stat the traits actually grant, with what each one does. Use this before advising on which jobs to run, whether to raid or turtle, or which Don to buy. Traits are not cosmetic; they are the build.",
    inputSchema: { type: "object", properties: { donId: { type: "number", description: "The Don's token id" } }, required: ["donId"] } },
  { name: "don_board", description:
      "The live job board with odds and payouts read from the contract, plus expected value with and without provision. Use this to compare briefs or to advise on a provision amount.",
    inputSchema: { type: "object", properties: {} } },
  { name: "don_playbook", description:
      "How D.O.N. works, the decisions a player actually faces, and an explicit list of what cannot be known by anyone. Read this before giving strategy advice.",
    inputSchema: { type: "object", properties: {} } },
];

export const GAME_HANDLERS = { don_state: donState, don_sheet: donSheet, don_board: donBoard, don_playbook: donPlaybook };
