// Essey Private — Phase 0 UI: stealth-address payments. Set up a private receiving address, pay someone
// to a fresh one-time address nobody can link to them, and sweep what you've privately received.
//
// EXPERIMENTAL. This is a stealth-address primitive (ERC-5564/6538), not a shielded pool — amounts are
// public on-chain; what it hides is the *link* between a recipient's public identity and where they were
// paid. The anonymity it gives grows with how many people use it. Testnet only.
import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { parseUnits, isAddress, type Address, type Hex } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { NET, ADDR, flows, fmt, niceError, lookupStealthMeta, scanPrivateInbox, scanPool, lookupPoolAccount, sharesToUsdg, usdgToShares, stockImpaired, SHIELDED_POOLS, type ShieldedPoolCfg, type StealthKeys, type PrivateHolding, type PoolNote, type PoolKeys } from "./live";

// Decimals are carried per-token, NOT hardcoded — testnet mocks are all 18-dec, but mainnet USDG is 6-dec,
// and a hardcoded 18 there would over-send by 1e12x. Update these when the mainnet addresses land.
const TOKENS: { key: string; addr: Address; decimals: number }[] = [
  { key: "USDG", addr: ADDR.usdg, decimals: 18 }, { key: "AAPL", addr: ADDR.aapl, decimals: 18 }, { key: "NVDA", addr: ADDR.nvda, decimals: 18 },
];
const USDG_DECIMALS = TOKENS.find((t) => t.addr === ADDR.usdg)?.decimals ?? 18; // shielded pool is USDG-only
const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);

export function PrivatePage() {
  const w = useWallet();
  const a = w.address as Address | null;
  const connected = !!a && w.chainOk;
  useEffect(() => { document.title = "Private · Essey"; }, []);

  const [keys, setKeys] = useState<StealthKeys | null>(null);
  const [registered, setRegistered] = useState<boolean | null>(null); // null = unknown
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  // send form
  const [to, setTo] = useState("");
  const [token, setToken] = useState<Address>(ADDR.usdg);
  const [amount, setAmount] = useState("");

  // where sweeps land (default: your main wallet — see the privacy note by the inbox)
  const [sweepTo, setSweepTo] = useState("");
  useEffect(() => { if (a && !sweepTo) setSweepTo(a); }, [a, sweepTo]);

  // inbox
  const [inbox, setInbox] = useState<PrivateHolding[] | null>(null);

  // shielded pools — HIDES AMOUNTS; cross-device recovery + receive-from-others (scan-based). One flagship
  // section, parametrized over USDG / AAPL / NVDA / private-yield supply. Keys are shared across all pools
  // (same circuit) — one unlock; balance + registration are per-selected-pool.
  const [poolKeys, setPoolKeys] = useState<PoolKeys | null>(null);
  const [selPoolKey, setSelPoolKey] = useState<string>("usdg");
  const selPool = SHIELDED_POOLS.find((p) => p.key === selPoolKey)!;
  const [pool, setPool] = useState<{ notes: PoolNote[]; balance: bigint }>({ notes: [], balance: 0n });
  const [usdgValue, setUsdgValue] = useState<bigint | null>(null); // supply: balance's USDG worth (incl. yield)
  const [impaired, setImpaired] = useState(false); // stock: issuer burned backing -> withdrawals take a haircut
  const [poolReg, setPoolReg] = useState<boolean | null>(null); // registered to receive in the selected pool?
  const [shieldAmt, setShieldAmt] = useState("");
  const [unshieldAmt, setUnshieldAmt] = useState("");
  const [unshieldTo, setUnshieldTo] = useState("");
  const [xferTo, setXferTo] = useState("");
  const [xferAmt, setXferAmt] = useState("");
  const [viaRelayer, setViaRelayer] = useState(true); // withdraw/transfer through the relayer by default (private, gasless)
  const [stage, setStage] = useState<string | null>(null);
  const isSupply = selPool.kind === "supply";
  // the unit users type in: supply talks USDG (notes are shares under the hood); everything else is native.
  const inputUnit = isSupply ? "USDG" : selPool.unit;
  const maxNote = pool.notes.reduce((m, n) => (BigInt(n.amount) > m ? BigInt(n.amount) : m), 0n); // largest single note (1 note/tx)
  const [maxNoteUsdg, setMaxNoteUsdg] = useState<bigint | null>(null); // supply: the largest note's USDG worth
  // A generation counter that bumps whenever the connected account changes; async pool ops capture it and skip
  // their trailing state writes if the account has since switched (so account A's balance can't paint under B).
  const scanGen = useRef(0);
  useEffect(() => { if (a && !unshieldTo) setUnshieldTo(a); }, [a, unshieldTo]);
  useEffect(() => { scanGen.current++; setPoolKeys(null); setPool({ notes: [], balance: 0n }); setUsdgValue(null); setImpaired(false); setMaxNoteUsdg(null); setPoolReg(null); }, [a]); // re-lock on wallet change

  // Am I already registered? (cheap read, no signature.)
  useEffect(() => {
    let live = true;
    if (!a) { setRegistered(null); return; }
    lookupStealthMeta(a).then((m) => { if (live) setRegistered(!!m && m.length > 2); }).catch(() => { if (live) setRegistered(null); });
    return () => { live = false; };
  }, [a]);

  const run = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); setStage(null); }
  };

  // Rescan `p`. Captures the generation at entry and drops its state writes if the account switched mid-scan.
  const rescan = async (keys: PoolKeys, p: ShieldedPoolCfg) => {
    const g = scanGen.current;
    const b = await scanPool(p, keys);
    const largest = b.notes.reduce((m, n) => (BigInt(n.amount) > m ? BigInt(n.amount) : m), 0n);
    const usdg = p.kind === "supply" ? await sharesToUsdg(p, b.balance) : null;
    const largestUsdg = p.kind === "supply" ? await sharesToUsdg(p, largest) : null;
    const imp = await stockImpaired(p);
    if (scanGen.current !== g) return; // account changed while scanning — don't paint stale data
    setPool(b); setUsdgValue(usdg); setMaxNoteUsdg(largestUsdg); setImpaired(imp);
  };

  // Switch the active pool: reset the per-pool view, then (if unlocked) rescan the newly-selected pool.
  const selectPool = (key: string) => {
    if (key === selPoolKey) return;
    const p = SHIELDED_POOLS.find((x) => x.key === key)!;
    setSelPoolKey(key);
    setPool({ notes: [], balance: 0n }); setUsdgValue(null); setMaxNoteUsdg(null); setImpaired(false); setPoolReg(null);
    setShieldAmt(""); setUnshieldAmt(""); setXferAmt(""); setXferTo("");
    if (poolKeys && a) run("switch", async () => {
      const g = scanGen.current;
      await rescan(poolKeys, p);
      const reg = !!(await lookupPoolAccount(p, a));
      if (scanGen.current === g) setPoolReg(reg);
    }, "");
  };

  // The largest single note, formatted in the unit the user sees — the per-transaction ceiling (1 note/tx).
  const maxHint = isSupply ? `≈ ${fmt(maxNoteUsdg ?? 0n, 2)} USDG` : `${fmt(maxNote, selPool.unit === "USDG" ? 2 : 4)} ${selPool.unit}`;

  // The 2-input circuit spends ONE note per tx — pick the largest note that covers `raw` (in the pool's raw unit).
  const pickNote = (raw: bigint): PoolNote => {
    const note = [...pool.notes].sort((x, y) => (BigInt(y.amount) > BigInt(x.amount) ? 1 : -1))[0];
    if (!note) throw new Error("Nothing shielded yet.");
    if (raw > BigInt(note.amount)) throw new Error(`That's more than your largest single note (${maxHint}). Each transaction spends one note at a time — withdraw/send in steps.`);
    return note;
  };

  // Turn what the user typed into the pool's RAW note unit. Plain pools: native units. Supply: the input is
  // USDG, converted to shares. If the user asked for MORE USDG than the largest single note is worth, return
  // the raw shares so pickNote surfaces the honest one-note-per-tx error; otherwise cap to that note so the
  // USDG→share rounding can't overshoot it (single-note "withdraw all" then works cleanly).
  const toRaw = async (input: string): Promise<bigint> => {
    if (!isSupply) return parseUnits(input || "0", selPool.decimals);
    const typedUsdg = parseUnits(input || "0", USDG_DECIMALS);
    const shares = await usdgToShares(selPool, typedUsdg);
    const largestUsdg = await sharesToUsdg(selPool, maxNote);
    if (typedUsdg > largestUsdg) return shares; // genuinely exceeds one note -> pickNote throws the honest error
    return shares > maxNote ? maxNote : shares;
  };

  const unlockPool = () => a && run("unlockPool", async () => {
    const g = scanGen.current;
    const keys = await flows.unlockPool(a);
    if (scanGen.current !== g) return; // account switched during the signature
    setPoolKeys(keys);
    await rescan(keys, selPool);
    const reg = !!(await lookupPoolAccount(selPool, a));
    if (scanGen.current === g) setPoolReg(reg);
  }, "✓ Unlocked — scanning your shielded balance.");

  const registerPool = () => a && poolKeys && run("registerPool", async () => {
    await flows.registerPool(a, poolKeys, selPool);
    setPoolReg(true);
  }, `✓ Registered — others can now send you shielded ${selPool.label} in-pool.`);

  const shield = () => a && poolKeys && run("shield", async () => {
    const amt = parseUnits(shieldAmt || "0", isSupply ? USDG_DECIMALS : selPool.decimals);
    if (amt <= 0n) throw new Error("Enter an amount to shield.");
    await flows.shieldDeposit(a, amt, poolKeys, selPool, setStage);
    setShieldAmt(""); await rescan(poolKeys, selPool);
  }, isSupply ? "✓ Supplied privately — your position and its yield are now hidden." : "✓ Shielded — your balance is now private.");

  const unshield = () => a && poolKeys && run("unshield", async () => {
    const raw = await toRaw(unshieldAmt);
    if (raw <= 0n) throw new Error("Enter an amount to unshield.");
    const dest = (unshieldTo.trim() || a) as Address;
    if (!isAddress(dest)) throw new Error("Enter a valid destination address.");
    await flows.shieldWithdraw(a, pickNote(raw), raw, dest, poolKeys, viaRelayer, selPool, setStage);
    setUnshieldAmt(""); await rescan(poolKeys, selPool);
  }, isSupply ? "✓ Withdrawn — USDG plus accrued yield sent to your address." : "✓ Unshielded to your chosen address.");

  const transfer = () => a && poolKeys && run("xfer", async () => {
    const raw = await toRaw(xferAmt);
    if (raw <= 0n) throw new Error("Enter an amount to send.");
    const dest = xferTo.trim();
    if (!isAddress(dest)) throw new Error("Enter the recipient's wallet address.");
    await flows.shieldTransfer(a, dest as Address, raw, pickNote(raw), poolKeys, viaRelayer, selPool, setStage);
    setXferAmt(""); await rescan(poolKeys, selPool);
  }, "✓ Sent privately — it will appear in the recipient's shielded balance.");

  const register = () => a && run("register", async () => {
    const k = await flows.registerStealth(a);
    setKeys(k); setRegistered(true);
  }, "✓ Private address set up. Others can now pay you privately.");

  const unlock = () => a && run("unlock", async () => {
    const k = await flows.unlockStealth(a);
    setKeys(k);
    await refreshInbox(k);
  }, "✓ Unlocked — scanning your private inbox.");

  const refreshInbox = async (k: StealthKeys) => {
    const held = await scanPrivateInbox(k.viewPriv, k.spendPub);
    setInbox(held);
  };

  const send = () => a && run("send", async () => {
    // Resolve the recipient: a 42-char address -> look up their registered meta; a 134-char hex -> raw meta.
    let meta: Hex;
    const t = to.trim();
    if (isAddress(t)) {
      const m = await lookupStealthMeta(t as Address);
      if (!m || m.length <= 2) throw new Error("That address hasn't set up a private receiving address yet.");
      meta = m;
    } else if (/^0x[0-9a-fA-F]{132}$/.test(t)) {
      meta = t as Hex;
    } else {
      throw new Error("Enter the recipient's wallet address, or their 66-byte meta-address.");
    }
    if (!amount || Number(amount) <= 0) throw new Error("Enter an amount to send.");
    const tok = TOKENS.find((t) => t.addr === token)!;
    const { stealthAddress } = await flows.payPrivate(a, token, meta, parseUnits(amount, tok.decimals));
    setMsg(`✓ Sent privately to a one-time address (${short(stealthAddress)}). Only the recipient can find it.`);
    setAmount("");
  }, "");

  const sweep = (h: PrivateHolding, tokenAddr: Address) => a && keys && run("sweep" + h.stealthAddress + tokenAddr, async () => {
    const dest = (sweepTo.trim() || a) as Address;
    if (!isAddress(dest)) throw new Error("Enter a valid sweep destination address.");
    await flows.sweepStealth(a, keys.spendPriv, h.sScalar, tokenAddr, dest);
    await refreshInbox(keys);
  }, "✓ Swept out.");

  return (
    <section className="band" id="private" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">Essey Private</span>
          <h2>Private balances. Private payments.</h2>
          <p>Two ways to move without being watched: <b>shielded pools</b> that hide your balance and amounts —
            for USDG, AAPL/NVDA stock, and yield-bearing supply — and <b>stealth addresses</b> that hide who
            you're paid as. Both on Robinhood Chain, both testnet.</p>
        </div>
          <span className="preview-chip">Experimental · P0</span>
        </div>

        <div className="live-card" style={{ marginBottom: 16 }}>
          <div className="live-note" style={{ lineHeight: 1.5 }}>
            <b>What this is.</b> Two privacy tools. The <b>shielded pools</b> (below) hide amounts — your balance and
            in-pool transfers are private, and deposits can't be linked to withdrawals; pick USDG, a stock (AAPL/NVDA),
            or private yield-bearing supply. <b>Stealth addresses</b> hide the link between your identity and where
            you're paid (amounts there stay public). Both grow stronger the more people use them. Experimental, testnet only.
          </div>
        </div>

        {!connected ? (
          <div className="live-card"><div className="live-row">
            <span className="live-note">Connect on Robinhood Chain testnet to use Essey Private.</span><ConnectButton />
          </div></div>
        ) : (
          <>
            <div className="pf-note" style={{ marginBottom: 12 }}>
              New here? Every action needs a little testnet <b>gas ETH</b>, and shielding needs <b>play-money tokens</b> — grab both free on the <Link className="pf-link gold" to="/start">Quest page ⚡</Link>.
            </div>
            {/* 0 — shielded pools (hide amounts) — the flagship. Parametrized: USDG / AAPL / NVDA / private-yield. */}
            <div className="pf-block">
              <div className="pf-block-h">Shielded balance <span className="preview-chip live">hides amounts</span></div>

              {/* Pool selector — one section over four pools. Keys are shared, so switching just rescans. */}
              <div className="pf-note" style={{ marginBottom: 6 }}>Choose what to make private:</div>
              <div className="live-row" style={{ gap: 8, flexWrap: "wrap", marginBottom: 12 }}>
                {SHIELDED_POOLS.map((p) => (
                  <button key={p.key} className="btn" disabled={!!busy} onClick={() => selectPool(p.key)}
                    style={{ padding: "6px 12px", fontSize: 13, opacity: p.key === selPoolKey ? 1 : 0.5, borderColor: p.key === selPoolKey ? "var(--gold, #c9a227)" : undefined }}>
                    {p.label}
                  </button>
                ))}
              </div>

              {!poolKeys ? (
                <div className="live-card"><div className="live-row" style={{ flexWrap: "wrap", gap: 12 }}>
                  <span className="live-note" style={{ flex: "1 1 320px" }}>
                    {selPool.blurb} Sign once to unlock — <b>no gas, no approvals, nothing spent, just a signature</b>. The
                    same keys work across every pool, and your notes are recovered by scanning the chain, so they follow you
                    across devices (and include anything others have sent you).
                  </span>
                  <button className="btn btn-gold" disabled={busy === "unlockPool"} onClick={unlockPool}>{busy === "unlockPool" ? (stage ? stage + "…" : "unlocking…") : "Unlock shielded balance"}</button>
                </div></div>
              ) : (
                <div className="live-card">
                  {isSupply ? (
                    <div style={{ marginBottom: 4 }}>
                      <div className="num" style={{ fontSize: 30, fontWeight: 700 }}>
                        ≈ {fmt(usdgValue ?? 0n, 2)} <span style={{ fontSize: 15, opacity: 0.6, fontWeight: 400 }}>USDG supplied</span>
                      </div>
                      <div className="pf-note">Private supply · earning yield · {fmt(pool.balance, 2)} shares held</div>
                    </div>
                  ) : (
                    <div className="num" style={{ fontSize: 30, fontWeight: 700, marginBottom: 4 }}>
                      {fmt(pool.balance, selPool.unit === "USDG" ? 2 : 4)} <span style={{ fontSize: 15, opacity: 0.6, fontWeight: 400 }}>{selPool.unit} shielded</span>
                    </div>
                  )}
                  <div className="pf-note" style={{ marginBottom: 14 }}>
                    {isSupply
                      ? <>Your supply position and the yield it earns are hidden — the note's share count is fixed, but the shares appreciate as interest accrues. Withdraw any time to receive USDG plus accrued yield.</>
                      : <>Your balance and any in-pool transfer are hidden, and the pool breaks the deposit↔withdrawal link. Deposit/withdraw <b>amounts</b> are public (matching amounts can re-link on a small pool — unshield to a fresh address).</>}
                    <button className="pf-link gold pf-inline-btn" disabled={!!busy} onClick={() => { if (poolKeys) run("rescan", () => rescan(poolKeys, selPool), "✓ Rescanned."); }}>rescan</button>
                  </div>

                  {pool.notes.length > 1 && (
                    <div className="pf-note" style={{ marginBottom: 14 }}>Your balance is made of separate deposits ("notes"); each transaction spends one at a time. Largest single withdrawal or transfer: <b>{maxHint}</b> — larger amounts go in steps.</div>
                  )}

                  {selPool.stock && impaired && (
                    <div className="live-card" style={{ marginBottom: 12, borderColor: "var(--gold, #c9a227)" }}>
                      <div className="pf-note" style={{ margin: 0 }}>⚠ <b>Backing impaired.</b> The issuer has burned some of this pool's stock, so withdrawals now pay a <b>pro-rata share</b> of what remains — the loss is split fairly across all holders, in the same proportion no matter when you exit. New deposits are closed until the backing is restored.</div>
                    </div>
                  )}

                  {poolReg === false && (
                    <div className="live-card" style={{ marginBottom: 12 }}>
                      <div className="live-row" style={{ flexWrap: "wrap", gap: 10 }}>
                        <span className="live-note" style={{ flex: "1 1 300px" }}>To <b>receive</b> shielded {selPool.label} from others, publish your keys once (a small tx). Not needed to shield/unshield your own funds.</span>
                        <button className="btn" disabled={!!busy} onClick={registerPool}>{busy === "registerPool" ? "registering…" : "Register to receive"}</button>
                      </div>
                    </div>
                  )}

                  <label className="pf-note" style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 14, cursor: "pointer" }}>
                    <input type="checkbox" checked={viaRelayer} onChange={(e) => setViaRelayer(e.target.checked)} />
                    <span>Withdraw / send <b>via relayer</b> — the relayer submits for you, so the tx doesn't come from your wallet (hides your tx-origin) and costs you no gas. Uncheck to submit yourself.</span>
                  </label>

                  {/* Shield (deposit) */}
                  <div className="pf-note" style={{ marginBottom: 6 }}>Heads-up: your <b>first</b> shield downloads a one-time ~12 MB proving key, so it takes ~30s (quick after that). The proof runs entirely in your browser — nothing is sent anywhere.</div>
                  <div className="live-row" style={{ gap: 10, flexWrap: "wrap", marginBottom: 14 }}>
                    <input className="live-input" placeholder={`amount to ${isSupply ? "supply" : "shield"} (${inputUnit})`} inputMode="decimal"
                      value={shieldAmt} onChange={(e) => setShieldAmt(e.target.value)} style={{ ...inputStyle, flex: "1 1 160px" }} />
                    <button className="btn btn-gold" disabled={!!busy || (selPool.stock && impaired)} onClick={shield}>
                      {busy === "shield" ? (stage ? stage + "…" : "shielding…") : (isSupply ? "Supply USDG →" : `Shield ${inputUnit} →`)}
                    </button>
                  </div>

                  {/* Send privately in-pool (transfer) */}
                  <div style={{ display: "flex", flexDirection: "column", gap: 10, borderTop: "1px solid var(--line, #333)", paddingTop: 14, marginBottom: 14 }}>
                    <div className="live-note">Send privately to another user (in-pool — nothing is unshielded):</div>
                    <input className="live-input" placeholder="recipient wallet address (0x…)" value={xferTo} onChange={(e) => setXferTo(e.target.value)} style={inputStyle} />
                    <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
                      <input className="live-input" placeholder={`amount to send (${inputUnit})`} inputMode="decimal" value={xferAmt} onChange={(e) => setXferAmt(e.target.value)} style={{ ...inputStyle, flex: "1 1 160px" }} />
                      <button className="btn" disabled={!!busy || pool.balance === 0n} onClick={transfer}>{busy === "xfer" ? (stage ? stage + "…" : "sending…") : "Send in-pool →"}</button>
                    </div>
                    <div className="pf-note">The recipient must have unlocked + registered <b>in this pool</b>. It appears in their shielded balance — no amount leaves the pool, so it's fully private.</div>
                  </div>

                  {/* Unshield (withdraw) */}
                  <div style={{ display: "flex", flexDirection: "column", gap: 10, borderTop: "1px solid var(--line, #333)", paddingTop: 14 }}>
                    <div className="live-note">{isSupply ? "Withdraw (USDG + yield) to:" : "Unshield to:"}</div>
                    <input className="live-input" placeholder="destination address (0x…)" value={unshieldTo} onChange={(e) => setUnshieldTo(e.target.value)} style={inputStyle} />
                    <div className="pf-note">⚠ Withdrawing to your own main wallet — or in an amount that matches your deposit — can re-link you on a small pool. Use a <b>fresh</b> address for stronger privacy.</div>
                    <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
                      <input className="live-input" placeholder={`amount to ${isSupply ? "withdraw" : "unshield"} (${inputUnit})`} inputMode="decimal"
                        value={unshieldAmt} onChange={(e) => setUnshieldAmt(e.target.value)} style={{ ...inputStyle, flex: "1 1 160px" }} />
                      <button className="btn" disabled={!!busy || pool.balance === 0n} onClick={unshield}>
                        {busy === "unshield" ? (stage ? stage + "…" : "unshielding…") : (isSupply ? "Withdraw →" : "Unshield →")}
                      </button>
                    </div>
                    {isSupply && <div className="pf-note">Amounts are in USDG; your position is held as yield-bearing shares, so a withdrawal redeems the equivalent shares and pays USDG including accrued yield (≈, since the share price moves).</div>}
                  </div>

                  <div className="pf-note" style={{ marginTop: 12 }}>
                    Notes are encrypted to your key and stored on-chain, so they recover from any device by scanning —
                    nothing is tied to this browser. Experimental, testnet only.
                  </div>
                </div>
              )}
            </div>

            {/* 1 — set up / unlock */}
            <div className="pf-block">
              <div className="pf-block-h">Your private address</div>
              {!keys ? (
                <div className="live-card"><div className="live-row" style={{ flexWrap: "wrap", gap: 12 }}>
                  <span className="live-note" style={{ flex: "1 1 320px" }}>
                    {registered === false
                      ? "Sign once to create your stealth keys and publish your receiving address. No gas, no approvals — just a signature."
                      : "Sign once to unlock your stealth keys on this device and scan for private payments. Same signature every time — it recreates the same keys."}
                  </span>
                  {registered === false
                    ? <button className="btn btn-gold" disabled={busy === "register"} onClick={register}>{busy === "register" ? "signing…" : "Set up private address"}</button>
                    : <button className="btn btn-gold" disabled={busy === "unlock"} onClick={unlock}>{busy === "unlock" ? "unlocking…" : "Unlock & scan"}</button>}
                </div></div>
              ) : (
                <div className="live-card">
                  <div className="live-note" style={{ marginBottom: 8 }}>Your reusable receiving handle — share it, or just tell senders your wallet address (it resolves to this):</div>
                  <div className="num" style={{ wordBreak: "break-all", fontSize: 12, opacity: 0.85, marginBottom: 10 }}>{keys.metaAddress}</div>
                  <div className="live-row" style={{ gap: 10 }}>
                    <button className="pf-link" onClick={() => navigator.clipboard?.writeText(keys.metaAddress)}>copy meta-address</button>
                    <button className="pf-link gold" disabled={!!busy} onClick={() => run("rescan", () => refreshInbox(keys), "✓ Rescanned.")}>refresh inbox</button>
                  </div>
                </div>
              )}
            </div>

            {/* 2 — send privately */}
            <div className="pf-block">
              <div className="pf-block-h">Send privately</div>
              <div className="live-card">
                <div className="live-note" style={{ marginBottom: 10 }}>Pay anyone who has set up a private address. Enter their <b>wallet address</b> (it resolves to their receiving handle) or paste their meta-address.</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                  <input className="live-input" placeholder="recipient wallet address (0x…) or meta-address"
                    value={to} onChange={(e) => setTo(e.target.value)} style={inputStyle} />
                  <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
                    <select value={token} onChange={(e) => setToken(e.target.value as Address)} style={{ ...inputStyle, flex: "0 0 120px" }}>
                      {TOKENS.map((t) => <option key={t.key} value={t.addr}>{t.key}</option>)}
                    </select>
                    <input className="live-input" placeholder="amount" inputMode="decimal"
                      value={amount} onChange={(e) => setAmount(e.target.value)} style={{ ...inputStyle, flex: "1 1 140px" }} />
                    <button className="btn btn-gold" disabled={busy === "send"} onClick={send}>{busy === "send" ? "sending…" : "Pay privately →"}</button>
                  </div>
                  <button className="pf-link" style={{ alignSelf: "flex-start" }} onClick={() => a && setTo(a)}>↳ pay my own private address</button>
                </div>
              </div>
            </div>

            {/* 3 — private inbox */}
            <div className="pf-block">
              <div className="pf-block-h">Private inbox {keys && <button className="pf-link gold pf-inline-btn" disabled={!!busy} onClick={() => run("rescan", () => refreshInbox(keys), "✓ Rescanned.")}>rescan</button>}</div>
              {keys && inbox && inbox.length > 0 && (
                <div className="live-card" style={{ marginBottom: 12 }}>
                  <div className="live-note" style={{ marginBottom: 8 }}>Sweep received funds to:</div>
                  <input className="live-input" placeholder="destination address (0x…)" value={sweepTo} onChange={(e) => setSweepTo(e.target.value)} style={inputStyle} />
                  <div className="pf-note" style={{ marginTop: 8 }}>⚠ Sweeping spends gas from your <b>main wallet</b> and moves the funds to the address above — both write an on-chain link between the one-time address and those wallets. For stronger unlinkability, sweep to a <b>fresh</b> address; relayer-funded gas (no main-wallet link) comes in a later phase.</div>
                </div>
              )}
              {!keys ? (
                <div className="pf-empty">Unlock above to scan for payments only you can see.</div>
              ) : inbox === null ? (
                <div className="pf-empty">Scanning…</div>
              ) : inbox.length === 0 ? (
                <div className="pf-empty">No private payments found yet. When someone pays your address, it shows up here — visible only to you.</div>
              ) : (
                <div className="pf-seats">
                  {inbox.map((h) => (
                    <div className="pf-seat" key={h.stealthAddress}>
                      <div className="pf-seat-top">
                        <span className="pf-seat-id num">{short(h.stealthAddress)}</span>
                        <a className="pf-link" href={`${NET.explorer}/address/${h.stealthAddress}`} target="_blank" rel="noreferrer">one-time address ↗</a>
                      </div>
                      {h.balances.length === 0 ? (
                        <div className="pf-seat-row num"><span className="pf-note">received, then swept (empty now).</span></div>
                      ) : h.balances.map((b) => (
                        <div className="pf-seat-row num" key={b.addr}>
                          <span><b>{fmt(b.amount, b.key === "USDG" ? 2 : 4)}</b> {b.key}</span>
                          <button className="pf-link gold pf-inline-btn" disabled={!!busy}
                            onClick={() => sweep(h, b.addr)}>
                            {busy === "sweep" + h.stealthAddress + b.addr ? "sweeping…" : "sweep →"}
                          </button>
                        </div>
                      ))}
                    </div>
                  ))}
                </div>
              )}
              {keys && <div className="pf-note" style={{ marginTop: 10 }}>Your stealth keys are derived from one signature and live in this browser tab only — never stored or sent. Sign again anytime to recover them on another device (standard EOA wallets only).</div>}
            </div>

            {msg && <div className="live-msg" style={{ marginTop: 14 }}>{msg}</div>}
            <div className="pf-note" style={{ marginTop: 18 }}>
              New here? <Link to="/portfolio" className="pf-link">Portfolio</Link> shows your public balances. Essey Private is an early primitive — expect rough edges.
            </div>
          </>
        )}
      </div>
    </section>
  );
}

const inputStyle: React.CSSProperties = {
  padding: "10px 12px", borderRadius: 8, border: "1px solid var(--line, #333)",
  background: "var(--bg-2, #111)", color: "inherit", fontSize: 16, fontFamily: "inherit", maxWidth: "100%",
};
