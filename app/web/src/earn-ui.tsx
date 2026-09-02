// /earn — put a stock to work in the vault's concentrated LP position. GATED off the live domain
// (App.tsx EARN_ON) and gated again by earn.ts's `deployed()`: StockLpVault is built but NOT deployed
// anywhere and its audit gate G3 restarted from zero on 2026-09-02 (docs/MAINNET-ACTIVATION.md:1152).
//
// The page's spine is the contract's own asymmetry. Depositing is priced at the Chainlink mark and is
// therefore closed off equity hours or when the pool has drifted from that mark; withdrawing is a
// pro-rata claim on real holdings, consults no oracle, and is open 24/7. Every state that closes the
// deposit door says which of the three conditions closed it, because a dead button explains nothing.
//
// NOTE for whoever wires the routes: WalletBar and TxBanner here duplicate redeem-ui.tsx's private
// copies. They should be lifted into one shared module — this file was built under a no-touch rule on
// redeem-ui.tsx, so the duplication is deliberate and flagged rather than hidden.
import { useCallback, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { formatUnits, parseUnits, type Address } from "viem";
import {
  anyDeployed,
  bpsOf,
  deployed,
  floorBy,
  priceAtTick,
  quoteShares,
  reads,
  retainedFee,
  shareValueUsd18,
  SHARE_DECIMALS,
  DEPOSIT_SLIPPAGE_BPS,
  tokenAbi,
  vaultAbi,
  VAULTS,
  WITHDRAW_SLIPPAGE_BPS,
  type VaultDef,
  type VaultPosition,
  type VaultState,
} from "./earn";
import {
  txUrl,
  useMainnetTx,
  useMainnetWallet,
  type TxState,
} from "./mainnet-tx";
import { fmt, MAINNET, readError } from "./reserve";
import { coinSVG } from "./stockLogos";

const pct = (bps: number): string =>
  `${(bps / 100).toFixed(bps % 100 ? 2 : 0)}%`;
const usd18 = (v: bigint): string => `$${fmt(v, 18, 2)}`;
const hours = (seconds: bigint): string => `${Number(seconds) / 3600}-hour`;
const price = (n: number): string =>
  Number.isFinite(n)
    ? n.toLocaleString("en-US", { maximumFractionDigits: 2 })
    : "—";

/// A typed amount as base units. A malformed entry is not an error state — the quote simply has
/// nothing to price, and every action stays unavailable until it parses to a positive number.
function useWei(raw: string, decimals: number): bigint {
  return useMemo(() => {
    if (!raw.trim()) return 0n;
    try {
      return parseUnits(raw.trim(), decimals);
    } catch {
      return -1n;
    }
  }, [raw, decimals]);
}

export function EarnPage() {
  const w = useMainnetWallet();
  const tx = useMainnetTx();
  const [pick, setPick] = useState(0);
  const [v, setV] = useState<VaultState | null>(null);
  const [pos, setPos] = useState<VaultPosition | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [mode, setMode] = useState<"deposit" | "withdraw">("deposit");
  const [stockIn, setStockIn] = useState("");
  const [baseIn, setBaseIn] = useState("");
  const [shareIn, setShareIn] = useState("");
  const [wdQuote, setWdQuote] = useState<[bigint, bigint]>([0n, 0n]);
  const [confirm, setConfirm] = useState(false);

  const def: VaultDef | undefined = VAULTS[pick];
  const addr = w.address;

  const loadVault = useCallback(async () => {
    if (!def || !deployed(def)) return;
    try {
      setV(await reads.vault(def));
      setErr(null);
    } catch (e) {
      setErr(readError(e));
    }
  }, [def]);

  const loadPosition = useCallback(async () => {
    if (!addr || !v) {
      setPos(null);
      return;
    }
    try {
      setPos(await reads.position(v, addr));
    } catch (e) {
      setErr(readError(e));
    }
  }, [addr, v]);

  useEffect(() => {
    document.title = "Earn · Essey";
    if (!anyDeployed()) return;
    loadVault();
    const t = setInterval(loadVault, 20_000);
    return () => clearInterval(t);
  }, [loadVault]);

  useEffect(() => {
    loadPosition();
  }, [loadPosition]);

  const stockWei = useWei(stockIn, v?.stock.decimals ?? 18);
  const baseWei = useWei(baseIn, v?.base.decimals ?? 18);
  const shareWei = useWei(shareIn, SHARE_DECIMALS);

  // The withdraw quote is a live contract read, never the position scaled down: a concurrent harvest
  // or another holder's exit moves what a share pays between renders.
  useEffect(() => {
    if (!v || shareWei <= 0n) {
      setWdQuote([0n, 0n]);
      return;
    }
    let live = true;
    reads.previewWithdraw(v, shareWei).then((q) => live && setWdQuote(q));
    return () => {
      live = false;
    };
  }, [v, shareWei]);

  const expected = useMemo(
    () =>
      v && stockWei >= 0n && baseWei >= 0n && stockWei + baseWei > 0n
        ? quoteShares(v, stockWei, baseWei)
        : null,
    [v, stockWei, baseWei],
  );

  const refresh = async () => {
    await loadVault();
    await loadPosition();
  };

  const approve = async (token: Address, amount: bigint) => {
    if (!def) return;
    // Exact, never max: the allowance is consumed by this one deposit, so nothing standing survives it.
    const ok = await tx.run({
      address: token,
      abi: tokenAbi,
      functionName: "approve",
      args: [def.address, amount],
    });
    if (ok) await refresh();
  };

  const stake = async () => {
    if (!def || expected === null) return;
    setConfirm(false);
    const ok = await tx.run({
      address: def.address,
      abi: vaultAbi,
      functionName: "deposit",
      args: [stockWei, baseWei, floorBy(expected, DEPOSIT_SLIPPAGE_BPS)],
    });
    if (ok) {
      setStockIn("");
      setBaseIn("");
      await refresh();
    }
  };

  const takeBack = async () => {
    if (!def || shareWei <= 0n) return;
    const ok = await tx.run({
      address: def.address,
      abi: vaultAbi,
      functionName: "withdraw",
      args: [
        shareWei,
        floorBy(wdQuote[0], WITHDRAW_SLIPPAGE_BPS),
        floorBy(wdQuote[1], WITHDRAW_SLIPPAGE_BPS),
      ],
    });
    if (ok) {
      setShareIn("");
      await refresh();
    }
  };

  const crank = async (functionName: "harvest" | "compound") => {
    if (!def) return;
    const ok = await tx.run({
      address: def.address,
      abi: vaultAbi,
      functionName,
    });
    if (ok) await refresh();
  };

  if (!def || !deployed(def)) return <NotOnChain />;

  const busy = tx.state.phase === "pending" || tx.state.phase === "signing";
  const overStock = !!pos && stockWei > pos.stockBalance;
  const overBase = !!pos && baseWei > pos.baseBalance;
  const overShares = !!pos && shareWei > pos.shares;
  const needsStock = !!pos && stockWei > 0n && pos.stockAllowance < stockWei;
  const needsBase = !!pos && baseWei > 0n && pos.baseAllowance < baseWei;
  const canStake =
    !!addr &&
    w.chainOk &&
    !!v?.gate.open &&
    expected !== null &&
    expected > 0n &&
    !overStock &&
    !overBase;

  return (
    <section className="band">
      <div className="wrap">
        <Head />
        <WalletBar w={w} />
        {VAULTS.length > 1 && (
          <div className="seg" role="tablist" style={{ width: "fit-content" }}>
            {VAULTS.map((d, i) => (
              <button
                key={d.address}
                aria-selected={i === pick}
                onClick={() => setPick(i)}
              >
                {d.label}
              </button>
            ))}
          </div>
        )}

        <Stats v={v} pos={pos} />
        <TxBanner state={tx.state} onDismiss={tx.reset} />
        <GateBanner v={v} />

        <div className="hw-card">
          <div className="hw-card-h">
            {mode === "deposit"
              ? "Put your stock to work"
              : "Take your stock back"}
          </div>
          <div className="seg" role="tablist" style={{ width: "fit-content" }}>
            <button
              aria-selected={mode === "deposit"}
              onClick={() => setMode("deposit")}
            >
              Deposit
            </button>
            <button
              aria-selected={mode === "withdraw"}
              onClick={() => setMode("withdraw")}
            >
              Withdraw
            </button>
          </div>

          {mode === "deposit" ? (
            <>
              <p>
                Your deposit joins the vault&apos;s concentrated position on the{" "}
                {v ? `${v.stock.symbol}/${v.base.symbol}` : ""} pool and earns a
                share of its trading fees. Shares are minted at the{" "}
                <b>Chainlink mark, not the pool&apos;s spot price</b>, so nobody
                can push the pool to change what your shares are worth.
              </p>
              <AmountField
                label={v?.stock.symbol ?? "stock"}
                value={stockIn}
                onChange={setStockIn}
                balance={pos?.stockBalance ?? null}
                decimals={v?.stock.decimals ?? 18}
              />
              <AmountField
                label={v?.base.symbol ?? "base"}
                value={baseIn}
                onChange={setBaseIn}
                balance={pos?.baseBalance ?? null}
                decimals={v?.base.decimals ?? 18}
              />
              {(stockWei === -1n || baseWei === -1n) && (
                <p className="pf-note">That isn&apos;t a number we can read.</p>
              )}
              {(overStock || overBase) && (
                <div className="hw-warn">
                  <div className="hw-warn-h">More than you hold</div>
                  <div>
                    Lower the amount to what is in your wallet on {MAINNET.name}
                    .
                  </div>
                </div>
              )}
              {v && expected !== null && expected > 0n && (
                <p className="pf-note">
                  This mints about{" "}
                  <span className="num">
                    {fmt(expected, SHARE_DECIMALS, 4)}
                  </span>{" "}
                  {v.shareSymbol}. The transaction asks for at least{" "}
                  <span className="num">
                    {fmt(
                      floorBy(expected, DEPOSIT_SLIPPAGE_BPS),
                      SHARE_DECIMALS,
                      4,
                    )}
                  </span>{" "}
                  and reverts below that, so a share price that drifts before
                  your block lands costs you nothing.
                </p>
              )}
              <div className="live-row" style={{ gap: 10, marginTop: 12 }}>
                {needsStock ? (
                  <button
                    className="btn btn-gold"
                    disabled={busy}
                    onClick={() => approve(v!.stock.address, stockWei)}
                  >
                    Approve {v?.stock.symbol}
                  </button>
                ) : needsBase ? (
                  <button
                    className="btn btn-gold"
                    disabled={busy}
                    onClick={() => approve(v!.base.address, baseWei)}
                  >
                    Approve {v?.base.symbol}
                  </button>
                ) : (
                  <button
                    className="btn btn-gold"
                    disabled={!canStake || busy}
                    onClick={() => setConfirm(true)}
                  >
                    Review the deposit →
                  </button>
                )}
              </div>
            </>
          ) : (
            <>
              <p>
                Withdrawing burns your shares for a pro-rata slice of everything
                the vault physically holds.{" "}
                <b>No oracle is consulted and there is no withdrawal fee</b>, so
                this stays open around the clock — including when depositing is
                closed.
              </p>
              <AmountField
                label={v?.shareSymbol ?? "shares"}
                value={shareIn}
                onChange={setShareIn}
                balance={pos?.shares ?? null}
                decimals={SHARE_DECIMALS}
              />
              {shareWei === -1n && (
                <p className="pf-note">That isn&apos;t a number we can read.</p>
              )}
              {overShares && (
                <div className="hw-warn">
                  <div className="hw-warn-h">More shares than you hold</div>
                  <div>Lower the amount.</div>
                </div>
              )}
              {v && shareWei > 0n && (
                <p className="pf-note">
                  You receive{" "}
                  <span className="num">
                    {fmt(wdQuote[0], v.stock.decimals, 6)}
                  </span>{" "}
                  {v.stock.symbol} and{" "}
                  <span className="num">
                    {fmt(wdQuote[1], v.base.decimals, 4)}
                  </span>{" "}
                  {v.base.symbol}, read from the contract&apos;s own{" "}
                  <span className="num">previewWithdraw</span>. The transaction
                  floors each leg {Number(WITHDRAW_SLIPPAGE_BPS) / 100}% below
                  that, wide enough that an ordinary price move re-splitting the
                  two legs does not revert your exit.
                </p>
              )}
              <div className="live-row" style={{ gap: 10, marginTop: 12 }}>
                <button
                  className="btn btn-gold"
                  disabled={
                    !addr ||
                    !w.chainOk ||
                    busy ||
                    shareWei <= 0n ||
                    overShares ||
                    wdQuote[0] + wdQuote[1] === 0n
                  }
                  onClick={takeBack}
                >
                  Withdraw
                </button>
              </div>
            </>
          )}
        </div>

        <PositionCard v={v} pos={pos} connected={!!addr} />
        <FeesCard
          v={v}
          busy={busy}
          canWrite={!!addr && w.chainOk}
          onHarvest={() => crank("harvest")}
          onCompound={() => crank("compound")}
        />
        <RangeCard v={v} />
        <Terms v={v} />

        {err && (
          <div className="hw-warn">
            <div className="hw-warn-h">Vault read failed</div>
            <div>{err}</div>
          </div>
        )}
      </div>

      {confirm && v && expected !== null && (
        <DepositConfirm
          v={v}
          stockWei={stockWei}
          baseWei={baseWei}
          shares={expected}
          onCancel={() => setConfirm(false)}
          onStake={stake}
        />
      )}
    </section>
  );
}

function Head() {
  return (
    <div className="band-head">
      <div>
        <span className="eyebrow">Earn</span>
        <h2>Put your stock to work without selling it</h2>
        <p>
          The vault holds a concentrated liquidity position in a tokenized-stock
          pool on Robinhood Chain mainnet and earns the trading fees it
          collects. You deposit the stock, you hold shares in the position, and
          you can take your slice back at any hour — in the tokens themselves,
          priced off what the vault actually holds rather than off a quote.
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
            The earn vault deploys soon{" "}
            <span className="preview-chip">not yet on chain</span>
          </div>
          <p>
            No vault address is configured for this build, so this page will not
            show you a position it cannot read from the chain. The contract is
            written and tested against the live NVDA/USDG pool, and its
            independent audit round is running — nothing here is open until both
            finish and the vault is deployed.
          </p>
          <ul className="hw-list">
            <li>
              <b>Deposits will be session-gated.</b> Shares are minted at the
              Chainlink mark, so depositing opens during US market hours and
              closes when the pool drifts from that mark.
            </li>
            <li>
              <b>Withdrawals will not be.</b> Taking your stock back is a
              pro-rata claim on what the vault physically holds. It reads no
              price, and there is no withdrawal fee.
            </li>
            <li>
              <b>One fee, on the yield only.</b> A performance cut of the
              trading fees the position collects — never a cut of your
              principal.
            </li>
          </ul>
        </div>
      </div>
    </section>
  );
}

function Stats({
  v,
  pos,
}: {
  v: VaultState | null;
  pos: VaultPosition | null;
}) {
  const mine =
    v && pos && pos.shares > 0n ? shareValueUsd18(v, pos.shares) : null;
  return (
    <div className="hw-stats">
      <Stat
        label="Vault value · at the mark"
        value={
          v ? (v.valueUsd18 === null ? "closed" : usd18(v.valueUsd18)) : "…"
        }
      />
      <Stat
        label="Your shares"
        value={pos ? fmt(pos.shares, SHARE_DECIMALS, 2) : "—"}
      />
      <Stat
        label="Your slice · at the mark"
        value={
          !pos || pos.shares === 0n
            ? "—"
            : mine === null
              ? "closed"
              : usd18(mine)
        }
      />
      <Stat
        label="Performance fee"
        value={v ? pct(v.performanceFeeBps) : "…"}
      />
      <Stat
        label="Position"
        value={
          v
            ? !v.rangeSet
              ? "no range yet"
              : v.inRange
                ? "in range"
                : "out of range"
            : "…"
        }
      />
    </div>
  );
}

/// The one banner that has to be right: the deposit door is shut for three different reasons and each
/// carries different advice. Withdrawing is unaffected by all three, and the copy says so every time.
function GateBanner({ v }: { v: VaultState | null }) {
  if (!v || v.gate.open) return null;
  const dev = v.gate.deviation;
  const body =
    v.gate.why === "closed"
      ? "Depositing opens during US equity hours. Shares are minted at the Chainlink mark, and the feed reports itself out of session, so the vault refuses to price a deposit right now."
      : v.gate.why === "stale"
        ? "The price feed is not reporting a fresh value, so the vault will not price a deposit against it. This clears on its own when the feed updates."
        : `The pool has drifted ${dev === null ? "" : `${bpsOf(dev).toFixed(1)} bps `}from the Chainlink mark, past the ${Number(v.maxDeviationBps) / 100}% band the vault will deposit inside. It reopens when the pool trades back toward the mark.`;
  return (
    <div className="hw-warn">
      <div className="hw-warn-h">
        Depositing is closed right now — withdrawing is not
      </div>
      <div>
        {body} Taking your stock back reads no price at all and stays open.
      </div>
    </div>
  );
}

function AmountField({
  label,
  value,
  onChange,
  balance,
  decimals,
}: {
  label: string;
  value: string;
  onChange: (s: string) => void;
  balance: bigint | null;
  decimals: number;
}) {
  return (
    <div className="lend-input" style={{ margin: "12px 0 6px" }}>
      <input
        inputMode="decimal"
        placeholder="0.0"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        aria-label={`${label} amount`}
      />
      <span className="lend-unit">{label}</span>
      {balance !== null && balance > 0n && (
        <button
          className="btn btn-ghost"
          onClick={() => onChange(formatUnits(balance, decimals))}
        >
          Max
        </button>
      )}
    </div>
  );
}

function PositionCard({
  v,
  pos,
  connected,
}: {
  v: VaultState | null;
  pos: VaultPosition | null;
  connected: boolean;
}) {
  return (
    <div className="hw-card">
      <div className="hw-card-h">Your position</div>
      <p>
        What your shares are worth in <b>units of the tokens themselves</b>,
        read from the contract&apos;s{" "}
        <span className="num">previewWithdraw</span>. That figure is a claim on
        assets the vault provably holds, so it is available every hour of the
        week. The dollar column beside it is the Chainlink mark and is
        display-only.
      </p>
      {!connected && (
        <p className="pf-note">Connect a wallet to see your position.</p>
      )}
      {connected && v && pos && (
        <div className="hw-scroll">
          <table className="hw-table">
            <thead>
              <tr>
                <th>Holding</th>
                <th className="n">Units</th>
                <th className="n">At the mark</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className="k">{v.shareSymbol}</td>
                <td className="n">{fmt(pos.shares, SHARE_DECIMALS, 4)}</td>
                <td className="n">
                  {pos.shares === 0n
                    ? "—"
                    : marked(shareValueUsd18(v, pos.shares))}
                </td>
              </tr>
              <tr>
                <td className="k">
                  <span className="live-row" style={{ gap: 8 }}>
                    <Coin symbol={v.stock.symbol} />
                    {v.stock.symbol} on withdrawal
                  </span>
                </td>
                <td className="n">{fmt(pos.outStock, v.stock.decimals, 6)}</td>
                <td className="n">—</td>
              </tr>
              <tr>
                <td className="k">
                  <span className="live-row" style={{ gap: 8 }}>
                    <Coin symbol={v.base.symbol} />
                    {v.base.symbol} on withdrawal
                  </span>
                </td>
                <td className="n">{fmt(pos.outBase, v.base.decimals, 4)}</td>
                <td className="n">—</td>
              </tr>
            </tbody>
          </table>
        </div>
      )}
      {connected && pos && pos.shares === 0n && (
        <p className="pf-note">
          You hold no shares in this vault yet. Depositing above is what mints
          them.
        </p>
      )}
    </div>
  );
}

const marked = (v: bigint | null): string =>
  v === null ? "market closed" : usd18(v);

/// Both cranks are permissionless and optional. Collecting is safe at any hour because it reads no
/// price; reinvesting redeploys at pool spot and is therefore gated exactly like a deposit.
function FeesCard({
  v,
  busy,
  canWrite,
  onHarvest,
  onCompound,
}: {
  v: VaultState | null;
  busy: boolean;
  canWrite: boolean;
  onHarvest: () => void;
  onCompound: () => void;
}) {
  if (!v) return null;
  const gross = v.fees.stock + v.fees.base;
  const keptStock = retainedFee(v.fees.stock, v.performanceFeeBps);
  const keptBase = retainedFee(v.fees.base, v.performanceFeeBps);
  return (
    <div className="hw-card">
      <div className="hw-card-h">Fees waiting to be collected</div>
      <p>
        Trading fees the position has earned and not yet swept into the vault,
        from the contract&apos;s <span className="num">pendingFees</span> view.
        Collecting is permissionless: anyone may call it, the caller is paid a{" "}
        {pct(v.bountyBps)} bounty carved out of the {pct(v.performanceFeeBps)}{" "}
        performance cut, and the remainder stays in the vault as yours.
      </p>
      <div className="hw-scroll">
        <table className="hw-table">
          <thead>
            <tr>
              <th>Token</th>
              <th className="n">Harvestable · units</th>
              <th className="n">Kept by the vault</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td className="k">
                <span className="live-row" style={{ gap: 8 }}>
                  <Coin symbol={v.stock.symbol} />
                  {v.stock.symbol}
                </span>
              </td>
              <td className="n">{fmt(v.fees.stock, v.stock.decimals, 6)}</td>
              <td className="n">{fmt(keptStock, v.stock.decimals, 6)}</td>
            </tr>
            <tr>
              <td className="k">
                <span className="live-row" style={{ gap: 8 }}>
                  <Coin symbol={v.base.symbol} />
                  {v.base.symbol}
                </span>
              </td>
              <td className="n">{fmt(v.fees.base, v.base.decimals, 4)}</td>
              <td className="n">{fmt(keptBase, v.base.decimals, 4)}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <div className="live-row" style={{ gap: 10, marginTop: 12 }}>
        <button
          className="btn btn-ghost"
          disabled={!canWrite || busy || gross === 0n}
          onClick={onHarvest}
        >
          Collect fees
        </button>
        <button
          className="btn btn-ghost"
          disabled={!canWrite || busy || !v.gate.open}
          onClick={onCompound}
        >
          Reinvest fees
        </button>
      </div>
      <p className="pf-note">
        {gross === 0n
          ? "Nothing has accrued since the last collection."
          : "Collecting works at any hour — it reads no price."}{" "}
        Reinvesting redeploys the idle balance back into the range at pool spot,
        so it is gated the same way a deposit is.
      </p>
    </div>
  );
}

function RangeCard({ v }: { v: VaultState | null }) {
  if (!v) return null;
  if (!v.rangeSet)
    return (
      <div className="hw-card">
        <div className="hw-card-h">
          The range <span className="preview-chip">not set yet</span>
        </div>
        <p>
          No range has been set on this vault, so it is holding its balances
          idle and earning nothing. Deposits still mint shares and withdrawals
          still pay out; the position starts working once the keeper sets the
          first range.
        </p>
      </div>
    );
  // A tick maps to a price that INVERTS when the stock is token1, so the lower tick can be the higher
  // price. Ordering the rows by price rather than by tick is the difference between a readable band and
  // one that reads upside down.
  const ends = [
    { tick: v.tickLower, p: priceAtTick(v, v.tickLower) },
    { tick: v.tickUpper, p: priceAtTick(v, v.tickUpper) },
  ].sort((a, b) => a.p - b.p);
  const rows: [string, number, number][] = [
    ["Range low", ends[0].tick, ends[0].p],
    ["Pool now", v.tick, priceAtTick(v, v.tick)],
    ["Range high", ends[1].tick, ends[1].p],
  ];
  return (
    <div className="hw-card">
      <div className="hw-card-h">
        The range{" "}
        <span className="preview-chip">
          {v.inRange ? "in range · earning" : "out of range · fees paused"}
        </span>
      </div>
      <p>
        A concentrated position only earns while the pool price sits inside its
        band. Outside it, the position sits entirely on one side of the pair and
        collects nothing until the price comes back or the keeper moves the
        range. Only the keeper can move it — there is no user action here, and
        the keeper has no path to receive your funds.
      </p>
      <div className="hw-scroll">
        <table className="hw-table">
          <thead>
            <tr>
              <th>Bound</th>
              <th className="n">Tick</th>
              <th className="n">
                {v.stock.symbol} in {v.base.symbol}
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map(([label, tick, p]) => (
              <tr key={label}>
                <td className="k">{label}</td>
                <td className="n">{tick}</td>
                <td className="n">{price(p)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="pf-note">
        The price column is derived from the pool&apos;s ticks for legibility,
        and the rows are ordered by price — so with {v.stock.symbol} as the
        pool&apos;s {v.stockIs1 ? "second" : "first"} token the tick column runs{" "}
        {v.stockIs1 ? "downwards" : "upwards"}. The pool&apos;s spot price is
        not what your shares are valued at — the Chainlink mark is — and it is
        not a quote.
      </p>
    </div>
  );
}

function Terms({ v }: { v: VaultState | null }) {
  const fee = v ? pct(v.performanceFeeBps) : "a performance";
  return (
    <div className="hw-card">
      <div className="hw-card-h">Vault terms</div>
      <ul className="hw-list">
        <li>
          <b>No withdrawal fee.</b> Your principal is yours to take back at any
          time, including outside market hours. The only fee is {fee} of the{" "}
          <b>yield</b>, taken when trading fees are collected. This is not the
          reserve&apos;s 5% exit fee — that is a different mechanism on a
          different contract, and redeeming $ESSEY has nothing to do with this
          vault.
        </li>
        <li>
          <b>Your shares are valued at the Chainlink mark, not pool spot.</b>{" "}
          Moving the pool cannot move what your shares are worth, which is why
          depositing closes when the two drift apart.
        </li>
        <li>
          <b>Dollar figures here are display-only.</b> They come from an equity
          feed that reports 24/5, so they are unavailable outside session rather
          than stale-and-shown. Units are the honest figure and are always
          available.
        </li>
        <li>
          <b>You can end up with a different mix than you put in.</b> A
          concentrated position converts between the two tokens as the price
          moves through its range. Withdrawing pays what the vault holds at that
          moment, which may be more of one leg and less of the other than you
          deposited, and can be worth less than simply holding the stock.
        </li>
        <li>
          <b>No APR is shown.</b> There is no on-chain APR field and no harvest
          history to derive one from, so this page prints none rather than a
          projection.
        </li>
        {v?.feeLocked ? (
          <li>
            <b>The fee is permanently locked.</b> The governor has been
            renounced and these terms can never change.
          </li>
        ) : v?.pendingFee ? (
          <li>
            <b>A fee change is queued.</b> The performance fee moves to{" "}
            {pct(v.pendingFee.performanceBps)} at{" "}
            <span className="num">
              {new Date(Number(v.pendingFee.effective) * 1000).toUTCString()}
            </span>
            . Changes sit behind a {hours(v.feeTimelock)} timelock and are
            capped at 20% of yield.
          </li>
        ) : (
          v && (
            <li>
              <b>No fee change is pending.</b> Changes sit behind a{" "}
              {hours(v.feeTimelock)} timelock, are capped at 20% of yield, and
              can be frozen forever but never raised past that cap.
            </li>
          )
        )}
      </ul>
      <p className="disclaim" style={{ marginTop: 12 }}>
        <b>Tokenized equities are securities</b> and carry issuer, custody, and
        market-gap risk. On Robinhood Chain the Stock Token issuer holds an
        adminBurn power that can destroy tokens at any address, so a vault
        holding can change outside any action you take. Providing liquidity is
        not a yield promise and no return is guaranteed. Every figure here is
        read live from the chain and is not a projection. Nothing here is
        financial advice.
      </p>
      {v && (
        <p className="pf-note">
          Vault <Verify address={v.def.address} /> · pool{" "}
          <Verify address={v.pool} /> · oracle <Verify address={v.oracle} /> ·
          keeper <Verify address={v.keeper} /> · fees to{" "}
          <Verify address={v.feeRecipient} />
        </p>
      )}
    </div>
  );
}

/// The last screen before principal leaves the wallet. It restates the two things a deposit form
/// cannot: the session gate that will close behind them, and the conversion risk of a range position.
function DepositConfirm({
  v,
  stockWei,
  baseWei,
  shares,
  onCancel,
  onStake,
}: {
  v: VaultState;
  stockWei: bigint;
  baseWei: bigint;
  shares: bigint;
  onCancel: () => void;
  onStake: () => void;
}) {
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
      aria-label="Confirm this deposit"
    >
      <div className="warn-box">
        <h2>Review this deposit</h2>
        <p className="warn-lede">
          You are depositing into a live liquidity position. You can withdraw at
          any hour, but what you get back depends on where the pool has traded
          in the meantime.
        </p>
        <div className="hw-scroll">
          <table className="hw-table">
            <thead>
              <tr>
                <th>You deposit</th>
                <th className="n">Units</th>
              </tr>
            </thead>
            <tbody>
              {stockWei > 0n && (
                <tr>
                  <td className="k">{v.stock.symbol}</td>
                  <td className="n">{fmt(stockWei, v.stock.decimals, 6)}</td>
                </tr>
              )}
              {baseWei > 0n && (
                <tr>
                  <td className="k">{v.base.symbol}</td>
                  <td className="n">{fmt(baseWei, v.base.decimals, 4)}</td>
                </tr>
              )}
              <tr>
                <td className="k">You receive</td>
                <td className="n">
                  {fmt(shares, SHARE_DECIMALS, 4)} {v.shareSymbol}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <ul className="warn-list">
          <li>
            The position converts between {v.stock.symbol} and {v.base.symbol}{" "}
            as the price moves through its range. You may withdraw a different
            mix than you deposited, worth less than simply holding the stock.
          </li>
          <li>
            The only fee is {pct(v.performanceFeeBps)} of the trading fees the
            position earns. There is no fee on your principal and none on the
            way out.
          </li>
          <li>
            Withdrawing is always open — it reads no price. Depositing and
            reinvesting are not, and are closed outside US equity hours.
          </li>
        </ul>
        <button className="btn btn-gold warn-accept" onClick={onStake}>
          Deposit into the {v.stock.symbol}/{v.base.symbol} vault
        </button>
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

function WalletBar({ w }: { w: ReturnType<typeof useMainnetWallet> }) {
  if (!w.ready) return <p className="pf-note">Checking your wallet…</p>;
  if (!w.hasProvider)
    return (
      <div className="hw-note">
        <b>No EVM wallet found.</b> Depositing signs a transaction on Robinhood
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
            Connect to read your balances and your position. Nothing is signed
            until you review a deposit.
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
            The vault lives on {MAINNET.name} (chain {MAINNET.chainId}). Your
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
      ? "Simulating against the vault before anything is signed…"
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

function Verify({ address }: { address: Address }) {
  return (
    <a
      href={`${MAINNET.explorer}/address/${address}`}
      target="_blank"
      rel="noreferrer"
      title={address}
    >
      {address.slice(0, 6)}…{address.slice(-4)} ↗
    </a>
  );
}

/// The marks are generated SVG strings from our own static table (stockLogos.ts) — no user or chain
/// input reaches this markup.
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
