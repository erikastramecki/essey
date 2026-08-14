// Essey MCP — the game half (D.O.N.), read-only.
//
// The lending tools in essey-mcp.mjs let an agent borrow against a Stock Token. These let an agent
// help someone actually PLAY: read a Don's position, read the live job board with real odds, and
// reason about the trade-offs. The pitch is the same shape as the lending half — an agent that can
// see the real numbers gives better advice than one working from a wiki.
//
// THREE RULES THIS FILE HOLDS TO, and they are the whole design:
//
//   1. FREE AND PUBLIC. There is no key, no auth, no tier. An edge available to only some players is
//      a whale advantage; available to everyone it just raises the floor.
//
//   2. THE FOG FIREWALL. Every read here is something a stranger with an RPC URL could already
//      compute. Nothing in this file may surface anything our own registries know that the chain does
//      not. The game's hidden information (garrison contents, raid targets before reveal, the entropy
//      that has not been drawn yet) is hidden CRYPTOGRAPHICALLY, and an advisor that leaked it would
//      quietly kill the game it is meant to help. So: public reads only, and the tools say plainly
//      what cannot be known.
//
//   3. ADVISE, NEVER ACT. Read-only. No calldata, no signing, no key — the same law the lending half
//      holds. The player takes every action themselves.

import { createPublicClient, http, defineChain, formatUnits } from "viem";

// ---------------------------------------------------------------- deployment

// RH testnet, deploy block 100489472. The Don collection is the real one — the game plays with the
// Dons people actually own.
const GAME = {
  don:         "0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c",
  missionBoard:"0xA4839CA4b595c768636E05bF37E32b167e482d99",
  houseDeed:   "0xe180dbda25966Cd6AE372C967200F0EB6D003368",
  houseEscrow: "0x869cbc012C37F7655FA5eA8F655E862Aa631C93C",
  hitter:      "0x219fafE26FB865b8dA4F55EF38ee99a91Ef969Cf",
  scrip:       "0xAE8AEB1E0eA9A6E6A55b469107DD5c7cbf28F1F6",
};

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

// ---------------------------------------------------------------- don_state

// Where a Don's money is, and therefore what is at risk. The three-state split IS the game: banked
// money is untouchable but idle, hopper money is what a raider can actually reach.
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
  return {
    donId: Number(id),
    owner,
    vault,
    away,
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

// The live job board, with the odds read off the contract rather than off a wiki. Expected value is
// computed both ways because the provision decision is the only real choice a brief offers.
export async function donBoard() {
  const count = await read(GAME.missionBoard, ABI.board, "briefCount");
  const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i + 1));
  const raw = await Promise.all(ids.map((i) => read(GAME.missionBoard, ABI.board, "briefs", [i])));

  const jobs = raw.map((b, i) => {
    // viem returns the tuple positionally, so read it in the order the contract declares.
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

    // Bare: pay the fee, provision nothing. Loaded: provision the cap, which is burned at dispatch
    // and only pays back through the success branch.
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

// The rules an advisor needs in order to be useful, and the honest boundaries of what advice can do.
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
    whatAnAdvisorCanDo: [
      "Compute expected value on any brief at any provision level, from live contract odds.",
      "Read your exposure and tell you what a raider could actually reach right now.",
      "Compare briefs on return per hour of exposure rather than on headline payout.",
    ],
    whatNobodyCanDo: [
      "See a defender's garrison before it is revealed. It is committed as a hash, so it is unreadable until they open it.",
      "See who else has a raid committed against a target. Pending raids do not name their target on chain.",
      "Predict any outcome. The randomness does not exist until the moment of settlement.",
      "Tell a bait House from a fat one. That is the core skill the game refuses to automate, and an advisor that claimed otherwise would be lying to you.",
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
  { name: "don_board", description:
      "The live job board with odds and payouts read from the contract, plus expected value with and without provision. Use this to compare briefs or to advise on a provision amount.",
    inputSchema: { type: "object", properties: {} } },
  { name: "don_playbook", description:
      "How D.O.N. works, the decisions a player actually faces, and an explicit list of what cannot be known by anyone. Read this before giving strategy advice.",
    inputSchema: { type: "object", properties: {} } },
];

export const GAME_HANDLERS = { don_state: donState, don_board: donBoard, don_playbook: donPlaybook };
