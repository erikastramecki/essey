// Launch: the self-serve operator panel for USDG-backed tokenized assets. Anyone — a person or a company
// (CoinVoyage, TravelSwap, …) — creates a backed voucher line (their own USDG backs it, isolated per launch),
// defines tiers, mints, and optionally stands up a Gotcha box that plugs into the shared ESSEY + Bell economy.
// It is template-driven so new asset kinds are presets over the one primitive, not new code.
import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { parseUnits, formatUnits, isAddress } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { launchpad, niceError, type LaunchProduct, type LaunchRaffle } from "./live";

const inp = { padding: "10px 12px", borderRadius: 8, border: "1px solid var(--line, #333)", background: "var(--bg-2, #111)", color: "inherit", fontSize: 16, fontFamily: "inherit", maxWidth: "100%" } as const;

const usd = (x: bigint, dec: number) => Number(formatUnits(x, dec)).toLocaleString(undefined, { maximumFractionDigits: 2 });

// Templates are presets over the SAME backed-voucher primitive — travel is just one skin.
const TEMPLATES = [
  { key: "travel", label: "Travel voucher", name: "Travel Voucher", symbol: "TRIP", settleLabel: "Booking / fulfilment wallet", blurb: "A predefined trip, redeemable for a real booking funded at your settlement wallet." },
  { key: "giftcard", label: "Gift card / credit", name: "Gift Card", symbol: "GIFT", settleLabel: "Redemption wallet", blurb: "Store credit redeemable at your venue." },
  { key: "custom", label: "Custom", name: "", symbol: "", settleLabel: "Settlement wallet (redemptions send backing here)", blurb: "Any USDG-backed claim you define." },
] as const;

export function OperatorPage() {
  const w = useWallet();
  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;
  const [dec, setDec] = useState(18);
  const [products, setProducts] = useState<LaunchProduct[]>([]);
  const [raffles, setRaffles] = useState<LaunchRaffle[]>([]);

  const load = useCallback(() => {
    if (!a) return;
    launchpad.usdgDecimals().then(setDec).catch(() => {});
    launchpad.myProducts(a).then(setProducts).catch(() => {});
    launchpad.myRaffles(a).then(setRaffles).catch(() => {});
  }, [a]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => { document.title = "Launch · Essey"; }, []);

  return (
    <section className="band" id="launch" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">Launch</span>
          <h2>Create a money-backed tokenized asset</h2>
          <p>Stand up your own USDG-backed voucher line: a trip, a gift card, brand credit, anything with a
            price. Every unit you mint is covered 1:1 by real USDG you deposit, so it can never be unbacked.
            Optionally drop it into a Gotcha box that raffles it through the shared Essey economy. Your backing
            lives in its own contract, isolated from every other operator.</p>
        </div>
          <span className="preview-chip live">testnet</span>
        </div>

        {!launchpad.deployed() ? (
          <div className="live-card"><span className="live-note">The launchpad isn’t deployed on this network yet.
            Once <code>BackedAssetFactory</code> is deployed and its address is set, this page goes live.</span></div>
        ) : !ready ? (
          <div className="live-card"><div className="live-row">
            <span className="live-note">Connect on Robinhood Chain testnet to launch a backed asset.</span><ConnectButton />
          </div></div>
        ) : (
          <>
            <LaunchPanel a={a!} onDone={load} />
            {products.length > 0 && (
              <div style={{ marginTop: 16, display: "flex", flexDirection: "column", gap: 14 }}>
                <div className="live-note">Your launches:</div>
                {products.map((p) => (
                  <ProductCard key={p.voucher} a={a!} dec={dec} product={p}
                    raffle={raffles.find((r) => r.voucher.toLowerCase() === p.voucher.toLowerCase()) || null}
                    onDone={load} />
                ))}
              </div>
            )}
          </>
        )}
      </div>
    </section>
  );
}

/// Create a new backed-asset line (deploys an isolated, operator-owned voucher contract).
function LaunchPanel({ a, onDone }: { a: Address; onDone: () => void }) {
  const [tpl, setTpl] = useState<(typeof TEMPLATES)[number]>(TEMPLATES[0]);
  const [name, setName] = useState<string>(TEMPLATES[0].name);
  const [symbol, setSymbol] = useState<string>(TEMPLATES[0].symbol);
  const [settlement, setSettlement] = useState<string>(a); // default: your own wallet
  const [feeWallet, setFeeWallet] = useState<string>(a);
  const [spreadPct, setSpreadPct] = useState("5");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const pick = (t: (typeof TEMPLATES)[number]) => { setTpl(t); setName(t.name); setSymbol(t.symbol); };

  const launch = async () => {
    const pct = parseFloat(spreadPct);
    if (!name.trim() || !symbol.trim()) { setMsg("Give it a name and a short symbol."); return; }
    if (!isAddress(settlement)) { setMsg("Settlement must be a valid address."); return; }
    if (!isAddress(feeWallet)) { setMsg("Fee wallet must be a valid address."); return; }
    if (!(pct >= 0 && pct <= 20)) { setMsg("Sell-back spread must be 0–20%."); return; }
    setBusy(true); setMsg(null);
    try {
      await launchpad.flows.launch(a, name.trim(), symbol.trim(), settlement as Address, Math.round(pct * 100), feeWallet as Address);
      setMsg("✓ Launched. Your backed-asset line is live below. Next: add a tier, then mint & back it.");
      onDone();
    } catch (e) { setMsg(niceError(e)); } finally { setBusy(false); }
  };

  return (
    <div className="live-card">
      <div className="live-h">CREATE A BACKED ASSET <span className="preview-chip">step 1</span></div>
      <div className="live-row" style={{ gap: 8, flexWrap: "wrap", marginBottom: 12 }}>
        {TEMPLATES.map((t) => (
          <button key={t.key} className={t.key === tpl.key ? "btn btn-gold" : "btn btn-ghost"} onClick={() => pick(t)}>{t.label}</button>
        ))}
      </div>
      <div className="live-note" style={{ marginBottom: 12 }}>{tpl.blurb}</div>
      <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
        <input className="live-input" placeholder="Name (e.g. CoinVoyage Travel Voucher)" value={name} onChange={(e) => setName(e.target.value)} style={{ ...inp, flex: "2 1 240px" }} />
        <input className="live-input" placeholder="Symbol" value={symbol} onChange={(e) => setSymbol(e.target.value)} style={{ ...inp, flex: "0 0 100px" }} />
      </div>
      <div className="live-row" style={{ gap: 10, flexWrap: "wrap", marginTop: 10 }}>
        <label style={{ flex: "1 1 260px", display: "flex", flexDirection: "column", gap: 4 }}>
          <span className="live-note">{tpl.settleLabel}</span>
          <input className="live-input" value={settlement} onChange={(e) => setSettlement(e.target.value)} style={inp} />
        </label>
        <label style={{ flex: "1 1 260px", display: "flex", flexDirection: "column", gap: 4 }}>
          <span className="live-note">Fee wallet (earns the sell-back spread)</span>
          <input className="live-input" value={feeWallet} onChange={(e) => setFeeWallet(e.target.value)} style={inp} />
        </label>
        <label style={{ flex: "0 0 130px", display: "flex", flexDirection: "column", gap: 4 }}>
          <span className="live-note">Sell-back spread</span>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <input className="live-input" inputMode="decimal" value={spreadPct} onChange={(e) => setSpreadPct(e.target.value)} style={{ ...inp, width: 70 }} /> %
          </div>
        </label>
      </div>
      <div className="live-row" style={{ marginTop: 12 }}>
        <button className="btn btn-gold" disabled={busy} onClick={launch}>{busy ? "launching…" : "Launch backed asset →"}</button>
      </div>
      {msg && <div className="live-msg">{msg}</div>}
    </div>
  );
}

/// One launched product: its backing + tiers, plus the operator actions (add tier, mint & back, run a box).
function ProductCard({ a, dec, product, raffle, onDone }: { a: Address; dec: number; product: LaunchProduct; raffle: LaunchRaffle | null; onDone: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const run = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); onDone(); }
    catch (e) { setMsg(niceError(e)); } finally { setBusy(null); }
  };

  // add-tier form
  const [tierNo, setTierNo] = useState("1");
  const [tierVal, setTierVal] = useState("");
  const addTier = () => {
    const t = parseInt(tierNo, 10), v = parseFloat(tierVal);
    if (!(t >= 1 && t <= 8)) return setMsg("Tier is 1–8.");
    if (!(v > 0)) return setMsg("Enter a dollar value for the tier.");
    run("tier", () => launchpad.flows.setTier(a, product.voucher, t, parseUnits(tierVal, dec)), `✓ Tier ${t} set to $${v.toLocaleString()}.`);
  };

  // mint form
  const [mintTier, setMintTier] = useState<number>(product.tiers[0]?.tier ?? 1);
  const [mintCount, setMintCount] = useState("");
  const unit = product.tiers.find((x) => x.tier === Number(mintTier))?.value ?? 0n;
  const mintTotal = unit * BigInt(parseInt(mintCount || "0", 10) || 0);
  const mint = () => {
    const c = parseInt(mintCount, 10);
    if (!(c > 0)) return setMsg("How many vouchers to mint?");
    if (unit === 0n) return setMsg("Pick a defined tier first.");
    run("mint", () => launchpad.flows.issue(a, product.voucher, Number(mintTier), c, unit), `✓ Minted ${c}. $${usd(mintTotal, dec)} USDG deposited as backing.`);
  };

  // seed (into an existing box)
  const seed = () => run("seed", async () => {
    const ids = await launchpad.seedableIds(a, product.voucher);
    if (ids.length === 0) throw new Error("No un-seeded vouchers to add. Mint some first.");
    return launchpad.flows.seed(a, raffle!.travelCase, product.voucher, ids);
  }, "✓ Vouchers seeded into the box. They’re live prizes now.");

  return (
    <div className="live-card">
      <div className="live-h">{product.name} <span className="preview-chip">{product.symbol}</span></div>
      <div className="live-note num" style={{ marginBottom: 10 }}>
        backing held <b>${usd(product.reserve, dec)}</b> · owed to holders <b>${usd(product.reserved, dec)}</b> USDG
        {product.tiers.length > 0 && <> · tiers {product.tiers.map((t) => `#${t.tier} $${usd(t.value, dec)}`).join(" · ")}</>}
      </div>

      {/* step 2 — add a tier */}
      <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
        <span className="live-note" style={{ flex: "0 0 100%" }}>Add a tier (a predefined package value):</span>
        <select value={tierNo} onChange={(e) => setTierNo(e.target.value)} style={{ ...inp, flex: "0 0 90px" }} aria-label="tier number">
          {[1, 2, 3, 4, 5, 6, 7, 8].map((t) => <option key={t} value={t}>tier {t}</option>)}
        </select>
        <input className="live-input" placeholder="value in USD (e.g. 250)" inputMode="decimal" value={tierVal} onChange={(e) => setTierVal(e.target.value)} style={{ ...inp, flex: "1 1 160px" }} />
        <button className="btn btn-ghost" disabled={busy === "tier"} onClick={addTier}>{busy === "tier" ? "setting…" : "Set tier"}</button>
      </div>

      {/* step 3 — mint & back */}
      {product.tiers.length > 0 && (
        <div className="live-row" style={{ gap: 10, flexWrap: "wrap", marginTop: 10 }}>
          <span className="live-note" style={{ flex: "0 0 100%" }}>Mint &amp; back (deposits count × tier value in USDG):</span>
          <select value={mintTier} onChange={(e) => setMintTier(Number(e.target.value))} style={{ ...inp, flex: "0 0 150px" }} aria-label="mint tier">
            {product.tiers.map((t) => <option key={t.tier} value={t.tier}>tier {t.tier} · ${usd(t.value, dec)}</option>)}
          </select>
          <input className="live-input" placeholder="# to mint" inputMode="numeric" value={mintCount} onChange={(e) => setMintCount(e.target.value)} style={{ ...inp, flex: "0 0 110px" }} />
          <button className="btn btn-gold" disabled={busy === "mint"} onClick={mint}>{busy === "mint" ? "minting…" : "Mint & back"}</button>
          {mintTotal > 0n && <span className="live-note num" style={{ flex: "0 0 100%" }}>deposits <b>${usd(mintTotal, dec)}</b> USDG as backing</span>}
        </div>
      )}

      {/* step 4 — the Gotcha box */}
      <div style={{ marginTop: 12, borderTop: "1px solid var(--line, #333)", paddingTop: 12 }}>
        {raffle ? (
          <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
            <span className="live-note num" style={{ flex: "1 1 auto" }}>Gotcha box live · <b>{raffle.inventory.toString()}</b> in inventory, <b>{raffle.free.toString()}</b> free to win</span>
            <button className="btn btn-gold" disabled={busy === "seed"} onClick={seed}>{busy === "seed" ? "seeding…" : "Seed minted vouchers →"}</button>
          </div>
        ) : (
          <RaffleForm a={a} voucher={product.voucher} run={run} busy={busy} />
        )}
      </div>

      {msg && <div className="live-msg">{msg}</div>}
    </div>
  );
}

/// Stand up a Gotcha box for this product (priced in ESSEY; buy-fee feeds the shared Bell).
function RaffleForm({ a, voucher, run, busy }: { a: Address; voucher: Address; run: (l: string, fn: () => Promise<unknown>, ok: string) => void; busy: string | null }) {
  const [price, setPrice] = useState("");
  const [fee, setFee] = useState("0");
  const [booster, setBooster] = useState("100");
  const create = () => {
    const p = parseFloat(price), f = parseFloat(fee || "0"), b = parseFloat(booster);
    if (!(p > 0)) return; // button hint below
    run("raffle", () => launchpad.flows.launchRaffle(a, voucher, parseUnits(String(p), 18), parseUnits(String(f), 18), Math.round(b * 100), a),
      "✓ Gotcha box launched. Now seed your minted vouchers into it.");
  };
  return (
    <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
      <span className="live-note" style={{ flex: "0 0 100%" }}>Launch a Gotcha box (players pay ESSEY to draw one of your vouchers; the buy fee feeds the shared Bell):</span>
      <input className="live-input" placeholder="case price (ESSEY)" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} style={{ ...inp, flex: "1 1 130px" }} />
      <input className="live-input" placeholder="buy fee (USDG)" inputMode="decimal" value={fee} onChange={(e) => setFee(e.target.value)} style={{ ...inp, flex: "1 1 120px" }} />
      <div style={{ display: "flex", alignItems: "center", gap: 6, flex: "0 0 auto" }}>
        <input className="live-input" inputMode="decimal" value={booster} onChange={(e) => setBooster(e.target.value)} style={{ ...inp, width: 64 }} aria-label="booster percent" /> <span className="live-note">% to Bell</span>
      </div>
      <button className="btn btn-gold" disabled={busy === "raffle" || !(parseFloat(price) > 0)} onClick={create}>{busy === "raffle" ? "launching…" : "Launch box"}</button>
    </div>
  );
}
