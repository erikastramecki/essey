// /redeem — burn $ESSEY, take your pro-rata slice of the floor. GATED off the live domain (App.tsx
// REDEEM_ON) until the founder opens it; the contract itself is live and adminless on RH mainnet 4663.
//
// The page is deliberately a two-step ledger rather than a one-click "redeem" button, because that is
// what the contract is (EsseyReserve.sol:29-32): `redeem` burns and issues a receipt, `claim` pulls each
// token. Every figure here is UNITS of a token the reserve provably holds — there is no price on this
// page and there must never be one; $ESSEY has no market, so a dollar figure next to a burn would be
// invented. Nothing is signed before the confirm sheet has shown the exact per-token output.
import { useCallback, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import {
  formatUnits,
  parseEventLogs,
  parseUnits,
  type Address,
  type TransactionReceipt,
} from "viem";
import { deployed, fmt, MAINNET, readError, RESERVE } from "./reserve";
import {
  claimWeight,
  esseyAbi,
  ESSEY_DECIMALS,
  exitFeeOn,
  previewRedeem,
  reads,
  redeemAbi,
  redeemedEvent,
  rememberReceipt,
  type ClaimRow,
  type OpenReceipt,
  type Position,
  type Quote,
  type RedeemState,
} from "./redeem";
import {
  txUrl,
  useMainnetTx,
  useMainnetWallet,
  type TxState,
} from "./mainnet-tx";
import { coinSVG } from "./stockLogos";

/// Redemption slices are minuscule against an 8.888B claimBase, so a fixed 2-dp format would print most
/// legs as "0.00" — rounding a real payout into a lie. Show the exact value, trimmed to its first
/// significant digits, and let a genuine zero say zero.
function units(v: bigint, decimals: number, sig = 6): string {
  if (v === 0n) return "0";
  const [w, f = ""] = formatUnits(v, decimals).split(".");
  if (w !== "0")
    return `${BigInt(w).toLocaleString("en-US")}${f ? `.${f.slice(0, 4)}` : ""}`;
  const lead = f.length - f.replace(/^0+/, "").length;
  const cut = f.slice(0, lead + sig).replace(/0+$/, "");
  return cut ? `0.${cut}` : `0.${f}`;
}

const pct = (bps: bigint): string => `${(Number(bps) / 100).toFixed(0)}%`;

export function RedeemPage() {
  const w = useMainnetWallet();
  const tx = useMainnetTx();
  const [st, setSt] = useState<RedeemState | null>(null);
  const [pos, setPos] = useState<Position | null>(null);
  const [receipts, setReceipts] = useState<OpenReceipt[]>([]);
  const [ledger, setLedger] = useState<ClaimRow[]>([]);
  const [truncated, setTruncated] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [amt, setAmt] = useState("");
  const [confirm, setConfirm] = useState(false);

  const addr = w.address;

  const loadReserve = useCallback(async () => {
    try {
      setSt(await reads.state());
      setErr(null);
    } catch (e) {
      setErr(readError(e));
    }
  }, []);

  const loadHolder = useCallback(async () => {
    if (!addr || !st) {
      setPos(null);
      setReceipts([]);
      setLedger([]);
      return;
    }
    try {
      const [p, r] = await Promise.all([
        reads.position(addr),
        reads.receipts(addr, st.tokens, st.receiptCount),
      ]);
      setPos(p);
      setReceipts(r.receipts);
      setTruncated(r.truncated);
      setLedger(await reads.ledger(r.receipts, st.tokens));
    } catch (e) {
      setErr(readError(e));
    }
  }, [addr, st]);

  useEffect(() => {
    document.title = "Redeem · Essey";
    if (!deployed()) return;
    loadReserve();
    const t = setInterval(loadReserve, 20_000);
    return () => clearInterval(t);
  }, [loadReserve]);

  useEffect(() => {
    loadHolder();
  }, [loadHolder]);

  // The typed amount as base units. A malformed entry is not an error state — the quote simply has
  // nothing to price yet, and every action stays unavailable until it parses to a positive number.
  const wei = useMemo(() => {
    if (!amt.trim()) return 0n;
    try {
      return parseUnits(amt.trim(), ESSEY_DECIMALS);
    } catch {
      return -1n;
    }
  }, [amt]);

  const quotes: Quote[] = useMemo(
    () => (st && wei > 0n ? previewRedeem(wei, st.tokens, st.params) : []),
    [st, wei],
  );
  const payable = quotes.filter((q) => q.units > 0n);

  const overBalance = pos !== null && wei > pos.essey;
  const needsApproval = pos !== null && wei > 0n && pos.allowance < wei;
  const canBurn =
    !!addr && w.chainOk && wei > 0n && !overBalance && payable.length > 0;

  const refresh = async () => {
    await loadReserve();
    await loadHolder();
  };

  const approve = async () => {
    if (!addr || wei <= 0n) return;
    // Exact, never max: the approval is consumed by this one burn, so no standing allowance survives it.
    const ok = await tx.run({
      address: RESERVE.essey,
      abi: esseyAbi,
      functionName: "approve",
      args: [RESERVE.reserve, wei],
    });
    if (ok) await refresh();
  };

  const burn = async () => {
    if (!addr || wei <= 0n) return;
    setConfirm(false);
    const rcpt = await tx.run({
      address: RESERVE.reserve,
      abi: redeemAbi,
      functionName: "redeem",
      args: [wei],
    });
    if (rcpt) {
      const id = receiptIdFrom(rcpt);
      if (id !== null) rememberReceipt(addr, id);
      setAmt("");
      await refresh();
    }
  };

  const claimAll = async (r: OpenReceipt) => {
    const legs = r.legs.filter((l) => l.units > 0n && !l.claimed);
    if (legs.length === 0) return;
    const ok = await tx.run({
      address: RESERVE.reserve,
      abi: redeemAbi,
      functionName: "claimMany",
      args: [r.id, legs.map((l) => l.token.address)],
    });
    if (ok) await refresh();
  };

  const claimOne = async (r: OpenReceipt, token: Address) => {
    const ok = await tx.run({
      address: RESERVE.reserve,
      abi: redeemAbi,
      functionName: "claim",
      args: [r.id, token],
    });
    if (ok) await refresh();
  };

  if (!deployed()) return <NotOnChain />;

  return (
    <section className="band">
      <div className="wrap">
        <Head />
        <WalletBar w={w} />

        <div className="hw-stats">
          <Stat
            label="Your $ESSEY"
            value={pos ? fmt(pos.essey, ESSEY_DECIMALS, 2) : addr ? "…" : "—"}
          />
          <Stat label="Exit fee" value={st ? pct(st.params.exitFeeBps) : "…"} />
          <Stat
            label="Claim denominator"
            value={st ? fmt(st.params.claimBase, ESSEY_DECIMALS, 0) : "…"}
          />
          <Stat
            label="Tokens backing"
            value={
              st ? `${st.tokens.filter((t) => t.reserve > 0n).length}` : "…"
            }
          />
          <Stat
            label="Receipts issued"
            value={st ? st.receiptCount.toString() : "…"}
          />
        </div>

        <TxBanner state={tx.state} onDismiss={tx.reset} />

        <div className="hw-card">
          <div className="hw-card-h">
            Step 1 — how much $ESSEY are you burning?
          </div>
          <p>
            Your slice is paid <b>in the tokens themselves</b>, never in
            dollars. The table below is what the reserve would pay you at this
            instant, computed the way the contract computes it: your burn less
            the {st ? pct(st.params.exitFeeBps) : "exit"} exit fee, over the
            fixed genesis supply less anything already claimed against each
            token.
          </p>
          <div className="lend-input" style={{ margin: "12px 0 6px" }}>
            <input
              inputMode="decimal"
              placeholder="0.0"
              value={amt}
              onChange={(e) => setAmt(e.target.value)}
              aria-label="$ESSEY to redeem"
            />
            <span className="lend-unit">$ESSEY</span>
            {pos && pos.essey > 0n && (
              <button
                className="btn btn-ghost"
                onClick={() => setAmt(formatUnits(pos.essey, ESSEY_DECIMALS))}
              >
                Max
              </button>
            )}
          </div>
          {wei === -1n && (
            <p className="pf-note">That isn&apos;t a number we can read.</p>
          )}
          {overBalance && (
            <div className="hw-warn">
              <div className="hw-warn-h">More than you hold</div>
              <div>
                Your wallet holds{" "}
                <span className="num">
                  {fmt(pos!.essey, ESSEY_DECIMALS, 4)}
                </span>{" "}
                $ESSEY. Lower the amount.
              </div>
            </div>
          )}

          <QuoteTable
            quotes={quotes}
            wei={wei > 0n ? wei : 0n}
            st={st}
            loading={!st}
          />

          {st && wei > 0n && (
            <p className="pf-note">
              Exit fee on this burn:{" "}
              <span className="num">
                {fmt(exitFeeOn(wei, st.params), ESSEY_DECIMALS, 4)}
              </span>{" "}
              $ESSEY — forfeited to the reserve, where it raises the floor for
              everyone still holding. Your receipt carries the remaining{" "}
              <span className="num">
                {fmt(claimWeight(wei, st.params), ESSEY_DECIMALS, 4)}
              </span>{" "}
              $ESSEY of claim weight.
            </p>
          )}

          <div className="live-row" style={{ gap: 10, marginTop: 12 }}>
            {needsApproval ? (
              <button
                className="btn btn-gold"
                disabled={!canBurn || tx.state.phase === "pending"}
                onClick={approve}
              >
                Approve $ESSEY
              </button>
            ) : (
              <button
                className="btn btn-gold"
                disabled={!canBurn || tx.state.phase === "pending"}
                onClick={() => setConfirm(true)}
              >
                Review the burn →
              </button>
            )}
          </div>
          {wei > 0n && payable.length === 0 && st && (
            <p className="pf-note">
              That amount is too small to pay out a single unit of any token in
              the basket. Every leg would truncate to zero, so the reserve would
              take the burn and pay nothing. Raise the amount.
            </p>
          )}
        </div>

        <ReceiptsCard
          receipts={receipts}
          truncated={truncated}
          connected={!!addr}
          busy={tx.state.phase === "pending"}
          onClaimAll={claimAll}
          onClaimOne={claimOne}
        />

        <LedgerCard rows={ledger} />

        <Terms exitFee={st ? pct(st.params.exitFeeBps) : "5%"} />

        {err && (
          <div className="hw-warn">
            <div className="hw-warn-h">Reserve read failed</div>
            <div>{err}</div>
          </div>
        )}
      </div>

      {confirm && st && (
        <BurnConfirm
          wei={wei}
          quotes={payable}
          fee={exitFeeOn(wei, st.params)}
          onCancel={() => setConfirm(false)}
          onBurn={burn}
        />
      )}
    </section>
  );
}

/// The receiptId exists only in the `Redeemed` log — a mined transaction cannot hand back a return
/// value. Losing it does not lose the claim (the on-chain scan finds it by owner), so a parse failure
/// is non-fatal and simply falls through to that scan.
function receiptIdFrom(rcpt: TransactionReceipt): bigint | null {
  try {
    const logs = parseEventLogs({
      abi: [redeemedEvent],
      logs: rcpt.logs,
      eventName: "Redeemed",
    });
    const id = logs[0]?.args?.receiptId;
    return typeof id === "bigint" ? id : null;
  } catch {
    return null;
  }
}

function Head() {
  return (
    <div className="band-head">
      <div>
        <span className="eyebrow">Redemption</span>
        <h2>Burn $ESSEY, take your slice of the floor</h2>
        <p>
          $ESSEY is a redeemable claim on the tokenized stock held in an
          adminless reserve on Robinhood Chain mainnet. Redeeming burns your
          $ESSEY and pays your pro-rata share of every token the reserve holds,
          in units of those tokens. It is irreversible, and it is the only way
          anything ever leaves the reserve.
        </p>
      </div>
    </div>
  );
}

function NotOnChain() {
  return (
    <section className="band">
      <div className="wrap">
        <Head />
        <div className="hw-card">
          <div className="hw-card-h">
            The reserve is not readable{" "}
            <span className="preview-chip">not yet on chain</span>
          </div>
          <p>
            No reserve address is configured for this build, so this page will
            not show you a redemption it cannot read from the chain.
          </p>
        </div>
      </div>
    </section>
  );
}

function WalletBar({ w }: { w: ReturnType<typeof useMainnetWallet> }) {
  if (!w.ready) return <p className="pf-note">Checking your wallet…</p>;
  if (!w.hasProvider)
    return (
      <div className="hw-note">
        <b>No EVM wallet found.</b> Redeeming signs a transaction on Robinhood
        Chain, so you need a wallet like{" "}
        <a
          href="https://metamask.io/download/"
          target="_blank"
          rel="noreferrer"
        >
          MetaMask
        </a>
        . Install one and reload this page.
      </div>
    );
  if (!w.address)
    return (
      <div className="hw-note">
        <div className="live-row" style={{ gap: 12 }}>
          <button className="btn btn-gold" onClick={w.connect}>
            Connect wallet
          </button>
          <span>
            Connect to read your $ESSEY balance and any open receipts. Nothing
            is signed until you review a burn.
          </span>
        </div>
        {w.error && <p className="pf-note">{w.error}</p>}
      </div>
    );
  if (!w.chainOk)
    return (
      <div className="hw-note">
        <div className="live-row" style={{ gap: 12 }}>
          <button className="btn btn-gold" onClick={w.switchChain}>
            Switch to {MAINNET.name}
          </button>
          <span>
            The reserve lives on {MAINNET.name} (chain {MAINNET.chainId}). Your
            wallet is on a different network.
          </span>
        </div>
        {w.error && <p className="pf-note">{w.error}</p>}
      </div>
    );
  return (
    <p className="pf-note">
      Connected <span className="num">{w.address}</span> on {MAINNET.name}.
    </p>
  );
}

function QuoteTable({
  quotes,
  wei,
  st,
  loading,
}: {
  quotes: Quote[];
  wei: bigint;
  st: RedeemState | null;
  loading: boolean;
}) {
  if (loading) return <p className="pf-note">Reading the reserve…</p>;
  if (!st) return null;
  const held = st.tokens.filter((t) => t.reserve > 0n);
  if (held.length === 0)
    return (
      <div className="hw-warn">
        <div className="hw-warn-h">Nothing to redeem yet</div>
        <div>
          The reserve holds none of the basket today, so a burn would pay
          nothing. Redemption is open, but there is no backing behind it yet.
        </div>
      </div>
    );
  const rows = wei > 0n ? quotes.filter((q) => q.token.reserve > 0n) : [];
  return (
    <div className="hw-scroll">
      <table className="hw-table">
        <thead>
          <tr>
            <th>Token</th>
            <th className="n">Reserve holds</th>
            <th className="n">You receive · units</th>
          </tr>
        </thead>
        <tbody>
          {(rows.length > 0
            ? rows
            : held.map((token) => ({ token, units: 0n }))
          ).map((q) => (
            <tr key={q.token.address}>
              <td className="k">
                <span className="live-row" style={{ gap: 8 }}>
                  <Coin symbol={q.token.symbol} />
                  <a
                    href={`${MAINNET.explorer}/address/${q.token.address}`}
                    target="_blank"
                    rel="noreferrer"
                    title={q.token.address}
                  >
                    {q.token.symbol} ↗
                  </a>
                </span>
              </td>
              <td className="n">{units(q.token.reserve, q.token.decimals)}</td>
              <td className="n">
                {wei <= 0n ? (
                  <span style={{ color: "var(--tx-faint)" }}>
                    enter an amount
                  </span>
                ) : q.units === 0n ? (
                  <span style={{ color: "var(--tx-faint)" }}>
                    rounds to zero
                  </span>
                ) : (
                  `${units(q.units, q.token.decimals)} ${q.token.symbol}`
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function ReceiptsCard({
  receipts,
  truncated,
  connected,
  busy,
  onClaimAll,
  onClaimOne,
}: {
  receipts: OpenReceipt[];
  truncated: boolean;
  connected: boolean;
  busy: boolean;
  onClaimAll: (r: OpenReceipt) => void;
  onClaimOne: (r: OpenReceipt, t: Address) => void;
}) {
  return (
    <div className="hw-card">
      <div className="hw-card-h">
        Step 2 — pull your receipt, token by token
      </div>
      <p>
        Burning does not pay you; it issues a <b>receipt</b>. Each token is
        pulled separately so a paused Stock Token can never brick the rest of
        your redemption — a leg that fails simply waits and stays claimable. An
        open receipt keeps earning the floor&apos;s growth: deposits that land
        before you pull raise what it pays.
      </p>
      {!connected && (
        <p className="pf-note">Connect a wallet to see your receipts.</p>
      )}
      {connected && receipts.length === 0 && (
        <p className="pf-note">No open receipts on this address.</p>
      )}
      {receipts.map((r) => {
        const open = r.legs.filter((l) => l.units > 0n && !l.claimed);
        const done = r.legs.every((l) => l.claimed || l.units === 0n);
        return (
          <div key={r.id.toString()} style={{ marginTop: 14 }}>
            <div className="hw-card-k" style={{ color: "var(--gold)" }}>
              Receipt #{r.id.toString()} ·{" "}
              <span className="num">{fmt(r.essey, ESSEY_DECIMALS, 2)}</span>{" "}
              $ESSEY burned
            </div>
            <div className="hw-scroll">
              <table className="hw-table">
                <thead>
                  <tr>
                    <th>Token</th>
                    <th className="n">Waiting · units</th>
                    <th className="n">Status</th>
                    <th className="n"></th>
                  </tr>
                </thead>
                <tbody>
                  {r.legs
                    .filter((l) => l.units > 0n || l.claimed || l.paused)
                    .map((l) => (
                      <tr key={l.token.address}>
                        <td className="k">
                          <span className="live-row" style={{ gap: 8 }}>
                            <Coin symbol={l.token.symbol} />
                            {l.token.symbol}
                          </span>
                        </td>
                        <td className="n">
                          {l.claimed ? "—" : units(l.units, l.token.decimals)}
                        </td>
                        <td className="n">
                          {l.claimed
                            ? "claimed ✓"
                            : l.paused
                              ? "paused — retry later"
                              : "waiting"}
                        </td>
                        <td className="n">
                          {!l.claimed && l.units > 0n && (
                            <button
                              className="btn btn-ghost"
                              disabled={busy}
                              onClick={() => onClaimOne(r, l.token.address)}
                            >
                              Claim
                            </button>
                          )}
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
            {open.length > 0 ? (
              <button
                className="btn btn-gold"
                disabled={busy}
                onClick={() => onClaimAll(r)}
              >
                Claim all {open.length} token{open.length === 1 ? "" : "s"}
              </button>
            ) : (
              done && (
                <p className="pf-note">
                  Redeemed in full — every leg on this receipt has been pulled.
                </p>
              )
            )}
          </div>
        );
      })}
      {truncated && (
        <p className="pf-note">
          Showing the most recent receipts plus any this browser recorded. If
          you redeemed from another device and an older receipt is missing, it
          is still yours on chain — nothing expires.
        </p>
      )}
    </div>
  );
}

function LedgerCard({ rows }: { rows: ClaimRow[] }) {
  if (rows.length === 0) return null;
  return (
    <div className="hw-card">
      <div className="hw-card-h">What you have claimed</div>
      <p>
        Every leg you have pulled, with the units the reserve actually paid,
        taken from the contract&apos;s own <span className="num">Claimed</span>{" "}
        events. Each row links to its transaction.
      </p>
      <div className="hw-scroll">
        <table className="hw-table">
          <thead>
            <tr>
              <th>Receipt</th>
              <th>Token</th>
              <th className="n">Paid · units</th>
              <th className="n">Receipt ↗</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={`${r.receiptId}-${r.token}-${r.txHash}`}>
                <td className="k">#{r.receiptId.toString()}</td>
                <td className="k">
                  <span className="live-row" style={{ gap: 8 }}>
                    <Coin symbol={r.symbol} />
                    {r.symbol}
                  </span>
                </td>
                <td className="n">
                  {units(r.units, r.decimals)} {r.symbol}
                </td>
                <td className="n">
                  <a href={txUrl(r.txHash)} target="_blank" rel="noreferrer">
                    tx ↗
                  </a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

/// The last screen before an irreversible burn. It repeats the exact per-token output rather than a
/// summary, and the acknowledgement is a deliberate act — a mis-click on the amount field must not be
/// one gesture away from destroying supply.
function BurnConfirm({
  wei,
  quotes,
  fee,
  onCancel,
  onBurn,
}: {
  wei: bigint;
  quotes: Quote[];
  fee: bigint;
  onCancel: () => void;
  onBurn: () => void;
}) {
  const [ack, setAck] = useState(false);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onCancel();
    };
    window.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [onCancel]);

  return createPortal(
    <div
      className="warn-modal"
      role="dialog"
      aria-modal="true"
      aria-label="Confirm this redemption"
    >
      <div className="warn-box">
        <h2>This burn cannot be undone</h2>
        <p className="warn-lede">
          You are burning <b className="num">{fmt(wei, ESSEY_DECIMALS, 4)}</b>{" "}
          $ESSEY. It leaves the supply permanently, and in exchange you receive
          a receipt for the units below.
        </p>
        <div className="hw-scroll">
          <table className="hw-table">
            <thead>
              <tr>
                <th>You receive</th>
                <th className="n">Units</th>
              </tr>
            </thead>
            <tbody>
              {quotes.map((q) => (
                <tr key={q.token.address}>
                  <td className="k">
                    <span className="live-row" style={{ gap: 8 }}>
                      <Coin symbol={q.token.symbol} />
                      {q.token.symbol}
                    </span>
                  </td>
                  <td className="n">{units(q.units, q.token.decimals)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <ul className="warn-list">
          <li>
            <b className="num">{fmt(fee, ESSEY_DECIMALS, 4)}</b> $ESSEY of this
            burn is the exit fee. It stays in the reserve and raises the floor
            for everyone still holding — you do not get it back.
          </li>
          <li>
            The figures above are <b>units of each token</b>, quoted from the
            reserve&apos;s live balances. They are not dollars, and they can
            move with the next deposit or claim before your transaction
            confirms.
          </li>
          <li>
            Burning pays out nothing by itself. It issues a receipt, and you
            then claim each token — in any order, across as many transactions as
            you like.
          </li>
        </ul>
        <label
          className="live-row"
          style={{ gap: 10, marginTop: 14, cursor: "pointer" }}
        >
          <input
            type="checkbox"
            checked={ack}
            onChange={(e) => setAck(e.target.checked)}
          />
          <span>
            I understand this destroys my $ESSEY and cannot be reversed.
          </span>
        </label>
        {/* The burn button does not EXIST until the box is ticked. The design system has no disabled
            style, so a greyed-looking-but-live gold button would be the ambiguity we can least afford
            on an irreversible action. */}
        {ack ? (
          <button className="btn btn-gold warn-accept" onClick={onBurn}>
            Burn {fmt(wei, ESSEY_DECIMALS, 4)} $ESSEY
          </button>
        ) : (
          <p className="pf-note" style={{ marginTop: 14 }}>
            Tick the box above to enable the burn.
          </p>
        )}
        <button
          className="btn btn-ghost"
          style={{ width: "100%", marginTop: 10 }}
          onClick={onCancel}
        >
          Cancel
        </button>
      </div>
    </div>,
    document.body,
  );
}

function TxBanner({
  state,
  onDismiss,
}: {
  state: TxState;
  onDismiss: () => void;
}) {
  if (state.phase === "idle") return null;
  if (state.phase === "failed")
    return (
      <div className="hw-warn">
        <div className="hw-warn-h">Transaction failed</div>
        <div>
          {state.error}{" "}
          {state.hash && (
            <a href={txUrl(state.hash)} target="_blank" rel="noreferrer">
              view on explorer ↗
            </a>
          )}{" "}
          <button className="pf-link gold" onClick={onDismiss}>
            dismiss
          </button>
        </div>
      </div>
    );
  const line =
    state.phase === "checking"
      ? "Simulating against the reserve before anything is signed…"
      : state.phase === "signing"
        ? "Confirm in your wallet."
        : state.phase === "pending"
          ? "Submitted — waiting for the chain."
          : "Confirmed.";
  return (
    <div className="hw-note">
      {line}{" "}
      {state.hash && (
        <a href={txUrl(state.hash)} target="_blank" rel="noreferrer">
          view on explorer ↗
        </a>
      )}{" "}
      {state.phase === "confirmed" && (
        <button className="pf-link gold" onClick={onDismiss}>
          dismiss
        </button>
      )}
    </div>
  );
}

function Terms({ exitFee }: { exitFee: string }) {
  return (
    <div className="hw-card">
      <div className="hw-card-h">Redemption terms</div>
      <ul className="hw-list">
        <li>
          <b>Paid in stock, not dollars.</b> You receive units of each token the
          reserve holds. There is no price on this page and no dollar payout —
          $ESSEY has no market, so any dollar figure here would be invented.
        </li>
        <li>
          <b>A {exitFee} exit fee stays in the reserve.</b> It is forfeited, not
          charged to a treasury: it remains as over-collateralisation and lifts
          the floor for holders who stay. It is not a vault performance fee —
          that is a different mechanism on a different contract. Redeeming has
          no other fee.
        </li>
        <li>
          <b>The burn is irreversible.</b> Redeemed $ESSEY is removed from
          supply and cannot be recovered. Your receipt is owner-bound and is not
          a token — it will not appear in your wallet.
        </li>
        <li>
          <b>A paused token waits, it does not vanish.</b> Robinhood Stock
          Tokens can be paused by their issuer. The reserve skips a paused leg
          without consuming it, so you retry that token later.
        </li>
        <li>
          <b>Adminless.</b> No owner, no registrar, no withdraw, no upgrade. The
          only way any token leaves the reserve is a holder redeeming their own
          slice.
        </li>
      </ul>
      <p className="disclaim" style={{ marginTop: 12 }}>
        <b>Tokenized equities are securities</b> and carry issuer, custody, and
        market-gap risk. On Robinhood Chain the Stock Token issuer holds an
        adminBurn power that can destroy tokens at any address, so reserve
        holdings can change outside a redemption. Every figure here is read live
        from the chain and is not a projection. Not an offer of securities.
        Nothing here is financial advice.
      </p>
      <p className="pf-note">
        Reserve{" "}
        <a
          href={`${MAINNET.explorer}/address/${RESERVE.reserve}`}
          target="_blank"
          rel="noreferrer"
        >
          {RESERVE.reserve} ↗
        </a>
      </p>
    </div>
  );
}

/// The basket marks are generated SVG strings from our own static table (stockLogos.ts) — no user or
/// chain input reaches this markup.
function Coin({ symbol }: { symbol: string }) {
  return (
    <span
      style={{ display: "inline-flex", verticalAlign: "middle" }}
      dangerouslySetInnerHTML={{ __html: coinSVG(symbol, 20) }}
    />
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="hw-stat">
      <b>{value}</b>
      <span>{label}</span>
    </div>
  );
}
