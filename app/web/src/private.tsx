// Essey Private — Phase 0 UI: stealth-address payments. Set up a private receiving address, pay someone
// to a fresh one-time address nobody can link to them, and sweep what you've privately received.
//
// EXPERIMENTAL. This is a stealth-address primitive (ERC-5564/6538), not a shielded pool — amounts are
// public on-chain; what it hides is the *link* between a recipient's public identity and where they were
// paid. The anonymity it gives grows with how many people use it. Testnet only.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { parseUnits, isAddress, type Address, type Hex } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { NET, ADDR, flows, fmt, niceError, lookupStealthMeta, scanPrivateInbox, scanPool, lookupPoolAccount, type StealthKeys, type PrivateHolding, type PoolNote, type PoolKeys } from "./live";

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

  // shielded pool — HIDES AMOUNTS; cross-device recovery + receive-from-others (scan-based)
  const [poolKeys, setPoolKeys] = useState<PoolKeys | null>(null);
  const [pool, setPool] = useState<{ notes: PoolNote[]; balance: bigint }>({ notes: [], balance: 0n });
  const [poolReg, setPoolReg] = useState<boolean | null>(null); // registered to receive?
  const [shieldAmt, setShieldAmt] = useState("");
  const [unshieldAmt, setUnshieldAmt] = useState("");
  const [unshieldTo, setUnshieldTo] = useState("");
  const [xferTo, setXferTo] = useState("");
  const [xferAmt, setXferAmt] = useState("");
  const [stage, setStage] = useState<string | null>(null);
  useEffect(() => { if (a && !unshieldTo) setUnshieldTo(a); }, [a, unshieldTo]);
  useEffect(() => { setPoolKeys(null); setPool({ notes: [], balance: 0n }); setPoolReg(null); }, [a]); // re-lock on wallet change

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

  const rescan = async (keys: PoolKeys) => { setPool(await scanPool(keys)); };

  // The 2-input circuit spends ONE note per tx — pick the largest note that covers `amt`.
  const pickNote = (amt: bigint): PoolNote => {
    const note = [...pool.notes].sort((x, y) => (BigInt(y.amount) > BigInt(x.amount) ? 1 : -1))[0];
    if (!note) throw new Error("Nothing shielded yet.");
    if (amt > BigInt(note.amount)) throw new Error(`Amount exceeds your largest single shielded note (${fmt(BigInt(note.amount), 2)} USDG). Use less, or in steps.`);
    return note;
  };

  const unlockPool = () => a && run("unlockPool", async () => {
    const keys = await flows.unlockPool(a);
    setPoolKeys(keys);
    await rescan(keys);
    setPoolReg(!!(await lookupPoolAccount(a)));
  }, "✓ Unlocked — scanning your shielded balance.");

  const registerPool = () => a && poolKeys && run("registerPool", async () => {
    await flows.registerPool(a, poolKeys);
    setPoolReg(true);
  }, "✓ Registered — others can now send you shielded USDG in-pool.");

  const shield = () => a && poolKeys && run("shield", async () => {
    const amt = parseUnits(shieldAmt || "0", USDG_DECIMALS);
    if (amt <= 0n) throw new Error("Enter an amount to shield.");
    await flows.shieldDeposit(a, amt, poolKeys, setStage);
    setShieldAmt(""); await rescan(poolKeys);
  }, "✓ Shielded — your balance is now private.");

  const unshield = () => a && poolKeys && run("unshield", async () => {
    const amt = parseUnits(unshieldAmt || "0", USDG_DECIMALS);
    if (amt <= 0n) throw new Error("Enter an amount to unshield.");
    const dest = (unshieldTo.trim() || a) as Address;
    if (!isAddress(dest)) throw new Error("Enter a valid destination address.");
    await flows.shieldWithdraw(a, pickNote(amt), amt, dest, poolKeys, setStage);
    setUnshieldAmt(""); await rescan(poolKeys);
  }, "✓ Unshielded to your chosen address.");

  const transfer = () => a && poolKeys && run("xfer", async () => {
    const amt = parseUnits(xferAmt || "0", USDG_DECIMALS);
    if (amt <= 0n) throw new Error("Enter an amount to send.");
    const dest = xferTo.trim();
    if (!isAddress(dest)) throw new Error("Enter the recipient's wallet address.");
    await flows.shieldTransfer(a, dest as Address, amt, pickNote(amt), poolKeys, setStage);
    setXferAmt(""); await rescan(poolKeys);
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
          <p>Two ways to move without being watched: a <b>shielded pool</b> that hides your balance and amounts,
            and <b>stealth addresses</b> that hide who you're paid as. Both on Robinhood Chain, both testnet.</p>
        </div>
          <span className="preview-chip">Experimental · P0</span>
        </div>

        <div className="live-card" style={{ marginBottom: 16 }}>
          <div className="live-note" style={{ lineHeight: 1.5 }}>
            <b>What this is.</b> Two privacy tools. The <b>shielded pool</b> (below) hides amounts — your balance and
            in-pool transfers are private, and deposits can't be linked to withdrawals. <b>Stealth addresses</b> hide
            the link between your identity and where you're paid (amounts there stay public). Both grow stronger the
            more people use them. Experimental, testnet only.
          </div>
        </div>

        {!connected ? (
          <div className="live-card"><div className="live-row">
            <span className="live-note">Connect on Robinhood Chain testnet to use Essey Private.</span><ConnectButton />
          </div></div>
        ) : (
          <>
            {/* 0 — shielded pool (hides amounts) — the flagship */}
            <div className="pf-block">
              <div className="pf-block-h">Shielded balance <span className="preview-chip live">hides amounts</span></div>
              {!poolKeys ? (
                <div className="live-card"><div className="live-row" style={{ flexWrap: "wrap", gap: 12 }}>
                  <span className="live-note" style={{ flex: "1 1 320px" }}>
                    Sign once to unlock your shielded balance. Your keys derive from the signature and your notes are
                    recovered by scanning the chain — so they follow you across devices, and include anything others have
                    sent you.
                  </span>
                  <button className="btn btn-gold" disabled={busy === "unlockPool"} onClick={unlockPool}>{busy === "unlockPool" ? (stage ? stage + "…" : "unlocking…") : "Unlock shielded balance"}</button>
                </div></div>
              ) : (
                <div className="live-card">
                  <div className="num" style={{ fontSize: 30, fontWeight: 700, marginBottom: 4 }}>
                    {fmt(pool.balance, 2)} <span style={{ fontSize: 15, opacity: 0.6, fontWeight: 400 }}>USDG shielded</span>
                  </div>
                  <div className="pf-note" style={{ marginBottom: 14 }}>
                    Your balance and any in-pool transfer are hidden, and the pool breaks the deposit↔withdrawal link.
                    Deposit/withdraw <b>amounts</b> are public (matching amounts can re-link on a small pool — unshield to a
                    fresh address). Notes recover from the chain, so they aren't tied to this browser.
                    <button className="pf-link gold pf-inline-btn" disabled={!!busy} onClick={() => { if (poolKeys) run("rescan", () => rescan(poolKeys), "✓ Rescanned."); }}>rescan</button>
                  </div>

                  {poolReg === false && (
                    <div className="live-card" style={{ marginBottom: 12 }}>
                      <div className="live-row" style={{ flexWrap: "wrap", gap: 10 }}>
                        <span className="live-note" style={{ flex: "1 1 300px" }}>To <b>receive</b> shielded USDG from others, publish your keys once (a small tx). Not needed to shield/unshield your own funds.</span>
                        <button className="btn" disabled={!!busy} onClick={registerPool}>{busy === "registerPool" ? "registering…" : "Register to receive"}</button>
                      </div>
                    </div>
                  )}

                  {/* Shield (deposit) */}
                  <div className="live-row" style={{ gap: 10, flexWrap: "wrap", marginBottom: 14 }}>
                    <input className="live-input" placeholder="amount to shield" inputMode="decimal"
                      value={shieldAmt} onChange={(e) => setShieldAmt(e.target.value)} style={{ ...inputStyle, flex: "1 1 160px" }} />
                    <button className="btn btn-gold" disabled={!!busy} onClick={shield}>
                      {busy === "shield" ? (stage ? stage + "…" : "shielding…") : "Shield USDG →"}
                    </button>
                  </div>

                  {/* Send privately in-pool (transfer) */}
                  <div style={{ display: "flex", flexDirection: "column", gap: 10, borderTop: "1px solid var(--line, #333)", paddingTop: 14, marginBottom: 14 }}>
                    <div className="live-note">Send privately to another user (in-pool — nothing is unshielded):</div>
                    <input className="live-input" placeholder="recipient wallet address (0x…)" value={xferTo} onChange={(e) => setXferTo(e.target.value)} style={inputStyle} />
                    <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
                      <input className="live-input" placeholder="amount to send" inputMode="decimal" value={xferAmt} onChange={(e) => setXferAmt(e.target.value)} style={{ ...inputStyle, flex: "1 1 160px" }} />
                      <button className="btn" disabled={!!busy || pool.balance === 0n} onClick={transfer}>{busy === "xfer" ? (stage ? stage + "…" : "sending…") : "Send privately →"}</button>
                    </div>
                    <div className="pf-note">The recipient must have unlocked + registered. It appears in their shielded balance — no amount leaves the pool, so it's fully private.</div>
                  </div>

                  {/* Unshield (withdraw) */}
                  <div style={{ display: "flex", flexDirection: "column", gap: 10, borderTop: "1px solid var(--line, #333)", paddingTop: 14 }}>
                    <div className="live-note">Unshield to:</div>
                    <input className="live-input" placeholder="destination address (0x…)" value={unshieldTo} onChange={(e) => setUnshieldTo(e.target.value)} style={inputStyle} />
                    <div className="pf-note">⚠ Unshielding to your own main wallet — or in an amount that matches your deposit — can re-link you on a small pool. Use a <b>fresh</b> address for stronger privacy.</div>
                    <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
                      <input className="live-input" placeholder="amount to unshield" inputMode="decimal"
                        value={unshieldAmt} onChange={(e) => setUnshieldAmt(e.target.value)} style={{ ...inputStyle, flex: "1 1 160px" }} />
                      <button className="btn" disabled={!!busy || pool.balance === 0n} onClick={unshield}>
                        {busy === "unshield" ? (stage ? stage + "…" : "unshielding…") : "Unshield →"}
                      </button>
                    </div>
                  </div>

                  <div className="pf-note" style={{ marginTop: 12 }}>
                    Notes are encrypted to your key and stored on-chain, so they recover from any device by scanning —
                    nothing is tied to this browser. The first shield downloads a ~12 MB proving key; proving runs in your
                    browser. Testnet USDG only.
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
                    <button className="btn btn-gold" disabled={busy === "send"} onClick={send}>{busy === "send" ? "sending…" : "Send privately →"}</button>
                  </div>
                  <button className="pf-link" style={{ alignSelf: "flex-start" }} onClick={() => a && setTo(a)}>↳ shield to myself (pay my own private address)</button>
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
                  <div className="pf-note" style={{ marginTop: 8 }}>⚠ Sweeping funds gas from your <b>main wallet</b> and moves the funds to the address above — both write an on-chain link between the one-time address and those wallets. For stronger unlinkability, sweep to a <b>fresh</b> address; relayer-funded gas (no main-wallet link) comes in a later phase.</div>
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
  background: "var(--bg-2, #111)", color: "inherit", fontSize: 14, fontFamily: "inherit",
};
