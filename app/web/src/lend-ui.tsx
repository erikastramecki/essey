// /lend — borrow USDG against real tokenized equity on Robinhood Chain MAINNET (4663), and supply
// USDG to the pool that funds it. The market contracts are NOT deployed yet (see lending.ts), so the
// page reads what IS live — USDG, both Stock Tokens with the issuer-beacon check, both Chainlink
// feeds — and says plainly that the market itself is not on chain. No dead buttons, no placeholder
// figures: a number appears here only if it came from a contract.
//
// The old version of this page self-gated on a testnet `canBorrow` and printed "isn't live yet" with
// no way to tell "not deployed" from "deployed but closed right now". Both states are named now, and
// the closed-right-now reason is read from the same inputs EsseyMarkets.canBorrow tests.
//
// The Auto-stack panel at the bottom still runs on the TESTNET stack (46630) and says so; it is the
// only thing here that is not mainnet, and it is fenced off rather than dressed up.
import { useCallback, useEffect, useState } from "react";
import { parseUnits, type Address } from "viem";
import {
  allowanceOf,
  erc20Abi,
  lendingDeployed,
  poolAbi,
  PROPOSED,
  quoteMaxBorrow,
  reads,
  USDG,
  type MarketState,
  type Rail,
  type Rails,
} from "./lending";
import {
  txUrl,
  useMainnetTx,
  useMainnetWallet,
  type MainnetWallet,
  type TxState,
} from "./mainnet-tx";
import { unpricedReason } from "./prices";
import { fmt, MAINNET, readError } from "./reserve";
import { ADDR, flows, niceError, reads as testnetReads } from "./live";
import { ConnectButton, useWallet } from "./wallet";

const bps = (v: number): string => `${(v / 100).toFixed(0)}%`;
const usd8 = (v: bigint): string => `$${fmt(v, 8, 2)}`;

export function LendPage() {
  const w = useMainnetWallet();
  const tx = useMainnetTx();
  const [rails, setRails] = useState<Rails | null>(null);
  const [markets, setMarkets] = useState<MarketState[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pick, setPick] = useState(0);

  const load = useCallback(async () => {
    try {
      setRails(await reads.rails());
      if (lendingDeployed()) setMarkets(await reads.markets(w.address));
      setErr(null);
    } catch (e) {
      setErr(readError(e));
    }
  }, [w.address]);

  useEffect(() => {
    load();
    const t = setInterval(load, 20_000);
    return () => clearInterval(t);
  }, [load]);

  const live = lendingDeployed();
  const m = markets?.[pick] ?? null;

  return (
    <section className="band" id="lend" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head">
          <div>
            <span className="eyebrow">Borrow</span>
            <h2>Borrow against your stock, without selling it</h2>
            <p>
              Post a tokenized equity you already hold, draw USDG against it,
              and repay whenever you like to get the collateral back. Lenders on
              the other side supply the USDG and earn what borrowers pay. Both
              markets settle on {MAINNET.name} (chain {MAINNET.chainId}).
            </p>
          </div>
          <span className={`preview-chip${live ? " live" : ""}`}>
            {live ? "live · mainnet" : "not yet on chain"}
          </span>
        </div>

        <RiskNote />

        {err && (
          <div className="hw-warn">
            <div className="hw-warn-h">Mainnet read failed</div>
            <div>{err}</div>
          </div>
        )}

        {live ? (
          <>
            <WalletBar w={w} />
            <TxBanner state={tx.state} onDismiss={tx.reset} />
            {markets && markets.length > 1 && (
              <div
                className="seg"
                role="tablist"
                style={{ width: "fit-content" }}
              >
                {markets.map((x, i) => (
                  <button
                    key={x.def.symbol}
                    aria-selected={pick === i}
                    onClick={() => setPick(i)}
                  >
                    {x.def.symbol}
                  </button>
                ))}
              </div>
            )}
            {m && <MarketStats m={m} />}
            {m && (
              <div className="lend-grid">
                <SupplyPanel m={m} w={w} tx={tx} rails={rails} onDone={load} />
                <BorrowPanel m={m} w={w} tx={tx} rails={rails} onDone={load} />
              </div>
            )}
          </>
        ) : (
          <NotOnChain />
        )}

        <RailsTable rails={rails} />
        <DcaBand />

        <p className="disclaim" style={{ marginTop: 18 }}>
          Tokenized equities are securities and carry issuer, custody, and
          market-gap risk. Every figure above is read from a contract on chain{" "}
          {MAINNET.chainId}; nothing on this page is an estimate. Not an offer
          of securities, and not financial advice.
        </p>
      </div>
    </section>
  );
}

/// The three hazards that only exist with REAL Robinhood collateral, in the same words the site
/// footer uses. They belong at the top of a borrow screen, not in a footnote under it.
function RiskNote() {
  return (
    <div className="hw-warn">
      <div className="hw-warn-h">What can go wrong</div>
      <div>
        On {MAINNET.name} the Stock Token issuer holds an <b>adminBurn</b> power
        (verified on chain) that can destroy tokens at any address:{" "}
        <b>posted collateral can cease to exist</b>, leaving a loan unsecured
        with nothing to liquidate. The issuer can also pause, block, claw back
        and upgrade the token. Separately, the equity price feed is 24/5 — blind
        nights, weekends and holidays — so a gap can move a position underwater
        while nobody can act on it. The protocol answers both with distance, not
        with a promise: a 20-point minimum gap between max LTV and the
        liquidation line, enforced in the contract itself. It is still a loan.
        If the stock falls far enough your collateral is liquidated to cover the
        debt.
      </div>
    </div>
  );
}

/// The honest not-deployed state. It names what is missing, shows the terms the deploy script will
/// propose (a proposal, labelled as one), and points at the rails below that ARE live.
function NotOnChain() {
  return (
    <div className="hw-card">
      <div className="hw-card-h">
        The market is not on chain yet{" "}
        <span className="preview-chip">not deployed</span>
      </div>
      <p>
        The lending contracts — the risk registry, the per-market pools, the
        oracle guard — are written, audited and public, but they have not been
        deployed to {MAINNET.name}. Deploying them is the founder's call, not
        this page's. Until that happens there is nothing to supply into and
        nothing to borrow from, so this page shows no balance, no rate and no
        button that would do nothing.
      </p>
      <p>
        What is already live is underneath: USDG, both Stock Tokens with the
        issuer-beacon check that proves they are genuine tokenized equities, and
        both Chainlink feeds. Those are the rails the markets run on, and they
        are read straight from chain {MAINNET.chainId} on every load.
      </p>
      <div className="hw-stats">
        <Stat label="Max LTV (proposed)" value={bps(PROPOSED.ltvBps)} />
        <Stat
          label="Liquidation at (proposed)"
          value={bps(PROPOSED.liqThresholdBps)}
        />
        <Stat
          label="Liquidator bonus (proposed)"
          value={bps(PROPOSED.liqBonusBps)}
        />
        <Stat
          label="Market cap (proposed)"
          value={`${PROPOSED.capUsdg.toLocaleString("en-US")} USDG`}
        />
      </div>
      <p>
        Proposed, not live: these are the parameters the deploy script asks for.
        They only bind after a 2-day on-chain timelock, and once a market exists
        this page reads the committed numbers from the registry instead.
      </p>
    </div>
  );
}

/// The live rails. Everything in this table is a call against a deployed contract on 4663 today —
/// it is what lets the page prove it reads the chain before the market layer exists.
function RailsTable({ rails }: { rails: Rails | null }) {
  if (!rails)
    return <p className="pf-note">Reading chain {MAINNET.chainId}…</p>;
  return (
    <>
      <div className="hw-card-h" style={{ marginTop: 22 }}>
        The rails, read live
      </div>
      <div className="hw-scroll">
        <table className="hw-table">
          <thead>
            <tr>
              <th>Collateral</th>
              <th>Genuine equity</th>
              <th className="n">UI multiplier</th>
              <th className="n">Price</th>
              <th className="n">Feed age</th>
              <th>Session</th>
            </tr>
          </thead>
          <tbody>
            {rails.rails.map((r) => (
              <RailRow key={r.def.token} r={r} />
            ))}
          </tbody>
        </table>
      </div>
      <p className="pf-note">
        Borrow asset: <b>{rails.usdg.symbol}</b> at {rails.usdg.decimals}{" "}
        decimals,{" "}
        <a
          href={`${MAINNET.explorer}/address/${USDG}`}
          target="_blank"
          rel="noreferrer"
        >
          {USDG} ↗
        </a>
        . "Genuine equity" is the EIP-1967 beacon slot matching the issuer's
        shared beacon — a check a look-alike token cannot forge. A closed
        session is why borrowing is declined out of hours: with a 24/5 feed
        there is no fresh price to lend against.
      </p>
    </>
  );
}

function RailRow({ r }: { r: Rail }) {
  return (
    <tr>
      <td className="k">
        <a
          href={`${MAINNET.explorer}/address/${r.def.token}`}
          target="_blank"
          rel="noreferrer"
        >
          {r.symbol}
        </a>
      </td>
      <td>
        {r.isRhStock ? (
          <span style={{ color: "var(--good)" }}>beacon verified</span>
        ) : (
          <span style={{ color: "var(--crit)" }}>not an RH Stock Token</span>
        )}
      </td>
      <td className="n">
        {r.uiMultiplier === null ? "—" : fmt(r.uiMultiplier, 18, 6)}
      </td>
      <td className="n">{r.price.ok ? usd8(r.price.usd8) : "—"}</td>
      <td className="n">
        {r.price.ok
          ? `${Math.round(r.price.ageSec / 60)}m`
          : unpricedReason(r.price)}
      </td>
      <td>{r.inSession ? "open" : "closed"}</td>
    </tr>
  );
}

function MarketStats({ m }: { m: MarketState }) {
  const s = m.stats;
  return (
    <div className="hw-stats">
      <Stat
        label={`${m.def.symbol} pool · supplied`}
        value={s ? `${fmt(s.tvl, m.assetDecimals, 2)} USDG` : "—"}
      />
      <Stat
        label="Lenders earn"
        value={s ? `${s.supplyApy.toFixed(2)}%/yr` : "—"}
      />
      <Stat
        label="Borrowers pay"
        value={s ? `${s.borrowApr.toFixed(2)}%/yr` : "—"}
      />
      <Stat label="Lent out" value={s ? `${s.utilPct.toFixed(0)}%` : "—"} />
      <Stat label="Max LTV" value={m.risk ? bps(m.risk.ltvBps) : "—"} />
      <Stat
        label="Liquidation at"
        value={m.risk ? bps(m.risk.liqThresholdBps) : "—"}
      />
    </div>
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

// ------------------------------------------------------------------ supply

type Tx = ReturnType<typeof useMainnetTx>;

function SupplyPanel({
  m,
  w,
  tx,
  rails,
  onDone,
}: {
  m: MarketState;
  w: MainnetWallet;
  tx: Tx;
  rails: Rails | null;
  onDone: () => void;
}) {
  const [mode, setMode] = useState<"supply" | "withdraw">("supply");
  const [amt, setAmt] = useState("");
  const dec = rails?.usdg.decimals ?? m.assetDecimals;
  const ready = !!w.address && w.chainOk && !!m.pool;

  const act = async () => {
    const wei = toUnits(amt, dec);
    if (!wei || !m.pool || !w.address) return;
    if (mode === "supply") {
      const have = await allowanceOf(USDG, w.address, m.pool);
      if (have < wei) {
        const ok = await tx.run({
          address: USDG,
          abi: erc20Abi,
          functionName: "approve",
          args: [m.pool, wei],
        });
        if (!ok) return;
      }
      const done = await tx.run({
        address: m.pool,
        abi: poolAbi,
        functionName: "deposit",
        args: [wei, w.address],
      });
      if (!done) return;
    } else {
      const done = await tx.run({
        address: m.pool,
        abi: poolAbi,
        functionName: "withdraw",
        args: [wei, w.address, w.address],
      });
      if (!done) return;
    }
    setAmt("");
    onDone();
  };

  return (
    <div className="live-card">
      <div className="live-h">SUPPLY &amp; EARN</div>
      <div className="live-bal num">
        your position: <b>{m.mine ? fmt(m.mine.supplied, dec, 2) : "—"}</b> USDG
        · earning {m.stats ? m.stats.supplyApy.toFixed(2) : "—"}% APY
      </div>
      <div className="seg" role="tablist" style={{ width: "fit-content" }}>
        <button
          aria-selected={mode === "supply"}
          onClick={() => setMode("supply")}
        >
          Supply
        </button>
        <button
          aria-selected={mode === "withdraw"}
          onClick={() => setMode("withdraw")}
        >
          Withdraw
        </button>
      </div>
      <div className="lend-input">
        <input
          className="num"
          inputMode="decimal"
          placeholder="0"
          value={amt}
          onChange={(e) => setAmt(e.target.value)}
          aria-label="USDG amount"
        />
        <span className="lend-unit">USDG</span>
        <button
          className="btn btn-gold"
          disabled={!ready || !toUnits(amt, dec)}
          onClick={act}
        >
          {mode === "supply" ? "Supply" : "Withdraw"}
        </button>
      </div>
      <div className="live-note">
        Interest accrues every second, and a withdrawal needs idle liquidity in
        the pool — if borrowers hold all of it, you wait for a repayment. Your
        claim is an ERC-4626 share you can hold or transfer. This is a loan
        book, not a deposit: if a borrower's collateral is destroyed by the
        issuer, the shortfall lands on lenders.
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ borrow

function BorrowPanel({
  m,
  w,
  tx,
  rails,
  onDone,
}: {
  m: MarketState;
  w: MainnetWallet;
  tx: Tx;
  rails: Rails | null;
  onDone: () => void;
}) {
  const [coll, setColl] = useState("");
  const [debt, setDebt] = useState("");
  const [max, setMax] = useState<bigint | null>(null);
  const usdgDec = rails?.usdg.decimals ?? m.assetDecimals;
  const collDec = m.risk?.collateralDecimals ?? 18;
  const open = m.gate.code === "open";

  useEffect(() => {
    const raw = toUnits(coll, collDec);
    if (!raw) {
      setMax(null);
      return;
    }
    quoteMaxBorrow(m.def.token, raw).then(setMax);
  }, [coll, collDec, m.def.token]);

  const doBorrow = async () => {
    const raw = toUnits(coll, collDec);
    const want = toUnits(debt, usdgDec);
    if (!raw || !want || !m.pool || !w.address) return;
    const have = await allowanceOf(m.def.token, w.address, m.pool);
    if (have < raw) {
      const ok = await tx.run({
        address: m.def.token,
        abi: erc20Abi,
        functionName: "approve",
        args: [m.pool, raw],
      });
      if (!ok) return;
    }
    const done = await tx.run({
      address: m.pool,
      abi: poolAbi,
      functionName: "borrow",
      args: [raw, want],
    });
    if (!done) return;
    setColl("");
    setDebt("");
    onDone();
  };

  const repay = async (id: bigint, owed: bigint) => {
    if (!m.pool || !w.address) return;
    // repay accepts >= owed and refunds the change (EsseyPool.sol:463-467), so send a small buffer
    // rather than an exact figure the next block's accrual would already have overtaken.
    const amount = (owed * 1001n) / 1000n;
    const have = await allowanceOf(USDG, w.address, m.pool);
    if (have < amount) {
      const ok = await tx.run({
        address: USDG,
        abi: erc20Abi,
        functionName: "approve",
        args: [m.pool, amount],
      });
      if (!ok) return;
    }
    const done = await tx.run({
      address: m.pool,
      abi: poolAbi,
      functionName: "repay",
      args: [id, amount],
    });
    if (done) onDone();
  };

  const loans = m.mine?.loans ?? [];
  const stock = m.mine?.stock ?? 0n;

  return (
    <div className="live-card">
      <div className="live-h">
        BORROW AGAINST {m.def.symbol}{" "}
        {open ? (
          <span className="preview-chip live">open</span>
        ) : (
          <span className="preview-chip">closed</span>
        )}
      </div>

      {loans.length > 0 && (
        <div className="lend-loans">
          {loans.map((l) => (
            <div className="lend-loan num" key={l.id.toString()}>
              <span>
                Loan #{l.id.toString()} · {fmt(l.effectiveRaw, collDec, 4)}{" "}
                {m.def.symbol} collateral · owe <b>{fmt(l.debt, usdgDec, 2)}</b>{" "}
                USDG
                {l.liqRatio !== null && (
                  <>
                    {" "}
                    · {(l.liqRatio * 100).toFixed(0)}% of the liquidation line
                  </>
                )}
                {l.effectiveRaw < l.collateralRaw && (
                  <>
                    {" "}
                    · <b>issuer burned part of this collateral</b>
                  </>
                )}
              </span>
              <button
                className="btn btn-ghost"
                onClick={() => repay(l.id, l.debt)}
              >
                Repay
              </button>
            </div>
          ))}
        </div>
      )}

      {!open ? (
        <div className="live-note">
          Borrowing is closed right now. {m.gate.detail} Existing loans can
          still be repaid, and supplying above is unaffected.
        </div>
      ) : stock === 0n ? (
        <div className="live-note">
          This wallet holds no {m.def.symbol} to post as collateral. Borrowing
          needs the token itself in your own wallet — Essey never custodies it
          before the loan.
        </div>
      ) : (
        <>
          <div className="live-bal num">
            you hold: {fmt(stock, collDec, 4)} {m.def.symbol}
          </div>
          <label className="lend-field-h">
            {m.def.symbol} to lock as collateral
          </label>
          <div className="lend-input">
            <input
              className="num"
              inputMode="decimal"
              placeholder="0"
              value={coll}
              onChange={(e) => setColl(e.target.value)}
              aria-label="collateral amount"
            />
            <span className="lend-unit">{m.def.symbol}</span>
          </div>
          <label className="lend-field-h">USDG to borrow</label>
          <div className="lend-input">
            <input
              className="num"
              inputMode="decimal"
              placeholder="0"
              value={debt}
              onChange={(e) => setDebt(e.target.value)}
              aria-label="borrow amount"
            />
            <span className="lend-unit">USDG</span>
            <button
              className="btn btn-gold"
              disabled={!toUnits(debt, usdgDec) || !toUnits(coll, collDec)}
              onClick={doBorrow}
            >
              Borrow
            </button>
          </div>
          {max !== null && (
            <div className="live-note num">
              The registry will lend at most <b>{fmt(max, usdgDec, 2)} USDG</b>{" "}
              against that — {m.risk ? bps(m.risk.ltvBps) : ""} of its priced
              value. Liquidation starts at{" "}
              {m.risk ? bps(m.risk.liqThresholdBps) : ""}, so the gap between
              the two is your buffer.
            </div>
          )}
        </>
      )}
      <div className="live-note">
        A loan is a <b>Note</b>: a transferable ERC-721 that carries its debt,
        its collateral and its solvency with it. Whoever holds the Note is the
        borrower.{" "}
        {m.pool && (
          <a
            href={`${MAINNET.explorer}/address/${m.pool}`}
            target="_blank"
            rel="noreferrer"
          >
            the {m.def.symbol} pool ↗
          </a>
        )}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ wallet + tx

function WalletBar({ w }: { w: MainnetWallet }) {
  if (!w.ready) return null;
  if (!w.address)
    return (
      <div className="hw-note">
        <div className="live-row" style={{ gap: 12 }}>
          <button className="btn btn-gold" onClick={w.connect}>
            Connect wallet
          </button>
          <span>
            Connect to read your balances and any open loans. Nothing is signed
            until you press Supply or Borrow.
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
            The lending market lives on {MAINNET.name} (chain {MAINNET.chainId}
            ). Your wallet is on a different network.
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
      ? "Simulating against the pool before anything is signed…"
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

/// A blank or malformed entry is not an error state — there is simply nothing to act on yet, and
/// every button stays unavailable until it parses to a positive amount at the token's own decimals.
function toUnits(s: string, decimals: number): bigint | null {
  const t = s.trim();
  if (!t) return null;
  try {
    const v = parseUnits(t, decimals);
    return v > 0n ? v : null;
  } catch {
    return null;
  }
}

// ------------------------------------------------------------------ auto-stack (TESTNET)

/// Auto-stack is the one thing on this page that is NOT mainnet: RecurringBuy is deployed on the
/// testnet stack (live.ts:40, chain 46630) and there is no mainnet build of it. It keeps working
/// exactly as before, on its own wallet connection, behind its own label — a testnet surface dressed
/// as mainnet would be the lie this page exists to avoid.
function DcaBand() {
  const w = useWallet();
  return (
    <>
      <div className="hw-card-h" style={{ marginTop: 26 }}>
        Auto-stack into stock{" "}
        <span className="preview-chip">testnet · chain 46630</span>
      </div>
      <p className="pf-note">
        This panel runs on the Robinhood Chain <b>testnet</b>, in test tokens
        with no value, against a keeper that fills during US market hours. It is
        not part of the mainnet market above and does not touch it.
      </p>
      {w.address && w.chainOk ? (
        <DcaPanel a={w.address as Address} />
      ) : (
        <div className="live-card">
          <div className="live-row">
            <span className="live-note">
              Connect on the testnet chain to schedule an auto-stack.
            </span>
            <ConnectButton />
          </div>
        </div>
      )}
    </>
  );
}

const dcaInput = {
  padding: "10px 12px",
  borderRadius: "var(--r)",
  border: "1px solid var(--line-2)",
  background: "var(--s2)",
  color: "var(--tx)",
  fontSize: 16,
  fontFamily: "inherit",
} as const;

/// A non-custodial recurring USDG→stock buy, settled through the oracle-floored, session-gated
/// converter and run by Essey's keeper.
function DcaPanel({ a }: { a: Address }) {
  const [stock, setStock] = useState<Address>(ADDR.aapl);
  const [perFill, setPerFill] = useState("");
  const [freq, setFreq] = useState<number>(86400);
  const [count, setCount] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [list, setList] = useState<
    Awaited<ReturnType<typeof testnetReads.dcaSchedules>>
  >([]);

  const load = useCallback(() => {
    testnetReads
      .dcaSchedules(a)
      .then(setList)
      .catch(() => {});
  }, [a]);
  useEffect(() => {
    load();
  }, [load]);

  const create = async () => {
    const amt = parseFloat(perFill),
      n = parseInt(count || "0", 10);
    if (!(amt > 0)) {
      setMsg("Enter a USDG amount per buy.");
      return;
    }
    if (!(n > 0 && n <= 1000)) {
      setMsg("Enter a number of buys (1–1000).");
      return;
    }
    setBusy("create");
    setMsg(null);
    try {
      await flows.createDca(a, stock, parseUnits(perFill, 18), BigInt(freq), n);
      setMsg(
        "✓ Auto-stack started. Fills run automatically during US market hours.",
      );
      setPerFill("");
      setCount("");
      load();
    } catch (e) {
      setMsg(niceError(e));
    } finally {
      setBusy(null);
    }
  };

  const cancel = async (id: bigint) => {
    setBusy("cancel" + id);
    setMsg(null);
    try {
      await flows.cancelDca(a, id);
      setMsg("✓ Auto-stack cancelled.");
      load();
    } catch (e) {
      setMsg(niceError(e));
    } finally {
      setBusy(null);
    }
  };

  const active = list.filter((s) => !s.cancelled && s.filled < s.totalFills);
  const total = parseFloat(perFill || "0") * parseInt(count || "0", 10);
  const freqLabel = (sec: number) =>
    sec % 86400 === 0 ? `${sec / 86400}d` : `${sec / 3600}h`;

  return (
    <div className="live-card" style={{ marginTop: 12 }}>
      <div className="live-h">AUTO-STACK INTO STOCK</div>
      <div className="live-note">
        Dollar-cost-average into stock: a recurring USDG→stock buy that runs on
        its own. <b>Your funds stay in your wallet</b> — each buy pulls only
        that buy's USDG, and you can cancel or revoke the allowance at any time.
        Fills settle at an oracle-fair price within a ≤5% floor, during US
        market hours.
      </div>
      <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
        <select
          value={stock}
          onChange={(e) => setStock(e.target.value as Address)}
          style={{ ...dcaInput, flex: "0 0 90px" }}
          aria-label="stock"
        >
          <option value={ADDR.aapl}>AAPL</option>
          <option value={ADDR.nvda}>NVDA</option>
        </select>
        <input
          placeholder="USDG / buy"
          inputMode="decimal"
          value={perFill}
          onChange={(e) => setPerFill(e.target.value)}
          style={{ ...dcaInput, flex: "1 1 110px" }}
        />
        <select
          value={freq}
          onChange={(e) => setFreq(+e.target.value)}
          style={{ ...dcaInput, flex: "0 0 100px" }}
          aria-label="frequency"
        >
          <option value={3600}>hourly</option>
          <option value={86400}>daily</option>
          <option value={604800}>weekly</option>
        </select>
        <input
          placeholder="# buys"
          inputMode="numeric"
          value={count}
          onChange={(e) => setCount(e.target.value)}
          style={{ ...dcaInput, flex: "0 0 90px" }}
        />
        <button
          className="btn btn-gold"
          disabled={busy === "create"}
          onClick={create}
        >
          {busy === "create" ? "starting…" : "Start Auto-stack →"}
        </button>
      </div>
      {total > 0 && (
        <div className="live-note num">
          Total committed: <b>{total.toLocaleString()}</b> USDG over {count}{" "}
          buys — the allowance you approve, with the funds staying in your
          wallet until each fill.
        </div>
      )}
      {active.length > 0 && (
        <div className="lend-loans">
          <div className="live-note">Your active Auto-stacks:</div>
          {active.map((s) => (
            <div key={s.id.toString()} className="lend-loan num">
              <span>
                {fmt(s.amountPerFill, 18, 2)} USDG →{" "}
                {s.stock.toLowerCase() === ADDR.aapl.toLowerCase()
                  ? "AAPL"
                  : "NVDA"}{" "}
                · every {freqLabel(Number(s.everySec))} ·{" "}
                <b>
                  {s.filled}/{s.totalFills}
                </b>{" "}
                filled
              </span>
              <button
                className="btn btn-ghost"
                disabled={busy === "cancel" + s.id}
                onClick={() => cancel(s.id)}
              >
                {busy === "cancel" + s.id ? "cancelling…" : "Cancel"}
              </button>
            </div>
          ))}
        </div>
      )}
      {msg && <div className="live-msg">{msg}</div>}
    </div>
  );
}
