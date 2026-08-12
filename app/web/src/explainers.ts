// In-flow explainers — approved copy for every decision point (source: explainer set, 2026-08-11).
// Pure data, no JSX: page owners import EXPLAINERS and render `body` inline next to the control it
// explains (1–3 sentences, muted style). Bodies may contain {placeholder} tokens — these are LIVE
// numbers that must be rendered from chain state, never hard-coded. Use fillExplainer() to substitute.
//
// Placeholders by key:
//   buy              {buyCost}        = live price × 1.08, $ESSEY
//   snipe            {snipeCost}      = live price × 1.12, $ESSEY
//   sell             {sellProceeds}   = live price × 0.92, $ESSEY
//   redeem-warning   {floorPerDon}    = DonReserve.floorPerDon(), $ESSEY
//                    {vaultBalance}   = the Don's Vault holdings, summarized
//   activate         {tierFee} {weight}
//   upgrade          {tier} {feeDelta} {weight}
//   borrow           {maxBorrow}      = 50% of live floor, $ESSEY
//   liquidation-risk {debt} {threshold} (threshold = 70% of live floor, $ESSEY)
//   claim            {pending}        = unclaimed amount credited to the Don

export interface Explainer {
  title: string;
  body: string;
}

export type ExplainerKey =
  | "mint" // free WL claim
  | "reroll"
  | "custom" // builder reserve/confirm traits
  | "buy" // AMM
  | "snipe" // AMM
  | "sell" // AMM
  | "slippage" // all trades
  | "redeem-warning"
  | "activate"
  | "upgrade"
  | "elect"
  | "borrow"
  | "repay"
  | "liquidation-risk"
  | "claim";

export const EXPLAINERS: Record<ExplainerKey, Explainer> = {
  mint: {
    title: "Free whitelist mint",
    body: "Your whitelist allocation mints for gas only, and each Don rolls random traits. You can reroll the look as many times as you like before you stake; staking locks it forever.",
  },
  reroll: {
    title: "Reroll",
    body: "Re-randomize this Don's traits for 0.00075 ETH (~$3), unlimited until it's staked. Your old combo is released back to the pool and the fee buys stock for staked holders, all of it.",
  },
  custom: {
    title: "Custom mint",
    body: "This exact combination is checked against the on-chain uniqueness ledger. Once you mint it, no other Don can ever share it. Custom mint costs 0.0025 ETH (~$10), and 100% of the fee buys stock for staked holders.",
  },
  buy: {
    title: "Buy",
    body: "You pay the live price plus an 8% fee ({buyCost} $ESSEY) and receive the next Don from inventory. 70% of the fee buys stock for staked Dons; the price can never sit below the redemption floor.",
  },
  snipe: {
    title: "Snipe",
    body: "Picking this exact Don costs the live price plus a 12% fee ({snipeCost} $ESSEY) instead of the standard 8%. Same floor-pinned price, same 70% of the fee to staked holders.",
  },
  sell: {
    title: "Sell",
    body: "You'll receive the live price minus the 8% fee: {sellProceeds} $ESSEY. Selling clears this Don's tier and stock elections, and anything in its Vault travels with it, so claim and empty the Vault first.",
  },
  slippage: {
    title: "Slippage bound",
    body: "The price tracks the live floor, which can rise between now and your transaction confirming. Your trade reverts rather than filling worse than this bound, so set it to the most you'll pay (or the least you'll accept).",
  },
  "redeem-warning": {
    title: "Redeem: this is permanent",
    body: "This is permanent. Redeeming pays you this Don's full floor ({floorPerDon} $ESSEY) and locks the Don in the reserve forever: no more seat, no more payouts, and its Vault (including {vaultBalance} in unclaimed and held assets) is locked away with it. Claim and withdraw everything from the Vault before you redeem.",
  },
  activate: {
    title: "Activate a tier",
    body: "A one-time {tierFee} $ESSEY fee puts this Don on the payout roll at {weight}× weight, earning from the very next ring. The fee is a sink, not a deposit: 50% is burned, 50% goes to treasury, and the tier clears if the Don ever changes hands. Activating locks this Don's art permanently.",
  },
  upgrade: {
    title: "Upgrade tier",
    body: "Upgrading to {tier} costs only the difference: {feeDelta} $ESSEY. Your rewards so far are checkpointed at your old weight, and the new {weight}× applies to every ring from here on.",
  },
  elect: {
    title: "Elect stocks",
    body: "Choose up to 3 tokenized stocks and how your payouts split between them. Leave it empty and you're paid the default BUNDLE basket; if a conversion can't settle (market closed, stale feed), that slice arrives as USDG instead, never stuck. Elections clear when the Don changes hands.",
  },
  borrow: {
    title: "Borrow",
    body: "Draw {maxBorrow} $ESSEY in one shot: a fixed 50% of this Don's floor, with no amount to dial. Choose a term of 7–365 days; the interest is a separate ETH fee, prepaid at signing and split 70% to stock for staked Dons / 30% treasury. The debt itself is flat: you owe back exactly {maxBorrow}, 1:1, and it never grows. The Don stays in your wallet, still staked and earning, but can't be sold, swapped, or redeemed until the debt clears. There is a due date. Miss it by the 30-day grace and anyone can liquidate.",
  },
  repay: {
    title: "Repay",
    body: "Repay in $ESSEY, 1:1. The debt is flat, so you owe exactly what you drew, with nothing accrued (interest was prepaid in ETH at borrow and isn't part of this). Pay any amount, any time; anyone may repay on your behalf. Clear it in full and the lien releases immediately, so your Don walks free. Overpaying is safe: only the outstanding principal is taken.",
  },
  "liquidation-risk": {
    title: "Liquidation risk",
    body: "The trigger is the calendar, not a price: this loan is liquidatable only after it expires plus a 30-day grace. Your debt is flat at {debt} $ESSEY, and because it's a fixed 50% of a floor that only rises, it can never reach the {threshold} $ESSEY ratio backstop. Watch the due date, not the ratio. Past due + grace, anyone can liquidate: the Don is redeemed at the floor to clear the debt, a 1% tip pays the caller, and any surplus comes back to you. But the Don and everything in its Vault are gone. Repay before the grace clock ends to stay safe.",
  },
  claim: {
    title: "Claim",
    body: "Pulls {pending} into this Don's Vault, delivered as your elected stocks (or the BUNDLE by default). Claiming is open to anyone because it can only ever pay the Vault, and only you control the Vault. Claim before you sell, redeem, or run a loan hot: the Vault always travels with the Don.",
  },
};

/// Substitute {placeholder} tokens with live values. Unknown tokens are left as-is so a missing
/// value is visible in dev rather than silently rendering an empty hole.
export function fillExplainer(body: string, vars: Record<string, string | number>): string {
  return body.replace(/\{([a-zA-Z0-9_]+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m));
}
