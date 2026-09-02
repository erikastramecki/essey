// The faucet — testnet funding in one place. Restores the drip flow that was orphaned when the
// quest page was retired: gas ETH comes from the chain's own faucet (external), play-money tokens
// come from our TestnetFaucet contract via flows.drip (100,000 $ESSEY + 1,000 USDG, 8h cooldown).
// Route: /faucet. Testnet only — this page has no mainnet counterpart.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { flows, reads, NET, fmt, niceError } from "./live";
import { useWallet, ConnectButton } from "./wallet";

type Balances = { gas: bigint; essey: bigint; usdg: bigint };

export function FaucetPage() {
  const w = useWallet();
  const addr = (w.address as Address | null) ?? null;
  const [bal, setBal] = useState<Balances | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  // Balance refresh — on connect and after every drip. Best-effort: a read hiccup must not
  // blank the page, so failures just leave the last known numbers standing.
  const refresh = async (a: Address) => {
    try {
      const [gas, b] = await Promise.all([
        reads.gasBalance(a),
        reads.balances(a),
      ]);
      setBal({ gas, essey: b.essey as bigint, usdg: b.usdg as bigint });
    } catch {
      /* keep whatever we had */
    }
  };
  useEffect(() => {
    if (!addr || !w.chainOk) {
      setBal(null);
      return;
    }
    let stale = false;
    (async () => {
      try {
        const [gas, b] = await Promise.all([
          reads.gasBalance(addr),
          reads.balances(addr),
        ]);
        if (!stale)
          setBal({ gas, essey: b.essey as bigint, usdg: b.usdg as bigint });
      } catch {
        /* transient read failure — the drip button still works */
      }
    })();
    return () => {
      stale = true;
    };
  }, [addr, w.chainOk]);

  const drip = async () => {
    if (!addr) return;
    setBusy(true);
    setMsg(null);
    try {
      await flows.drip(addr);
      setMsg({
        ok: true,
        text: "✓ 100,000 $ESSEY + 1,000 USDG dripped. You're funded — get a Don and head for the Game. Come back in 8h for more.",
      });
      await refresh(addr);
    } catch (e) {
      setMsg({ ok: false, text: niceError(e) });
    } finally {
      setBusy(false);
    }
  };

  const noGas = bal !== null && bal.gas === 0n;
  return (
    <section className="band" id="faucet">
      <div className="wrap">
        <div className="band-head">
          <div>
            <span className="eyebrow">Play-money faucet</span>
            <h2>Fund your wallet with play money</h2>
            <p>
              The game is an experimental preview, so the
              tokens here are free and have no real value. Two things get you
              playing: <b>gas ETH</b> from the chain's own faucet, and{" "}
              <b>$ESSEY + USDG</b>
              from ours. $ESSEY is the token you spend to get in (mint tiers,
              trade Dons); USDG is the play-money stablecoin for fees and
              payouts.
            </p>
            <p>
              <b>Looking for Scrip (the game's points)?</b> Scrip never drips
              from a faucet — it is earned on the job board. Your first dispatch
              mints a free Safehouse and, while the stipend budget lasts, a{" "}
              <b>◫ 50</b> starter stake, and the training wire pays like a
              faucet: the <b>MILK RUN</b> takes 75 seconds and pays{" "}
              <b>◫ 6,000</b> on a near-sure roll. That funds a Hitter (◫ 900),
              hit orders (◫ 50), and your House in one go. When a job lands,{" "}
              <b>bank the hopper</b> at the House desk — pay isn't spendable
              until banked, and it is raidable until it is.{" "}
              <a href="/game/jobs/sprint">Run the Milk Run →</a>
            </p>
          </div>
        </div>

        <div className="live-card" style={{ maxWidth: 640 }}>
          <div className="live-h">
            PLAY MONEY <span className="preview-chip live">preview</span>
          </div>
          {!addr ? (
            <div className="live-row">
              <span className="live-note">
                Connect your wallet to get funds.
              </span>
              <ConnectButton />
            </div>
          ) : !w.chainOk ? (
            <div className="live-row">
              <span className="live-note">
                Wrong network. Switch to Robinhood Chain first.
              </span>
              <ConnectButton />
            </div>
          ) : (
            <>
              <div className="live-bal num">
                {bal ? (
                  <>
                    {fmt(bal.gas, 4)} ETH (gas) · {fmt(bal.essey)} $ESSEY ·{" "}
                    {fmt(bal.usdg)} USDG
                  </>
                ) : (
                  "…"
                )}
              </div>
              {/* Gas FIRST: every transaction needs it, and it comes from the chain's own faucet —
                  a separate step from our token drip. Emphasize it until they actually have some. */}
              {noGas && (
                <div className="fund-gas">
                  <span className="fund-step num">1</span>
                  <span>
                    You have <b>no gas ETH</b>, so nothing will send without it.
                    Get some from the chain faucet first (it's free, opens in a
                    new tab).
                  </span>
                  <a
                    className="btn btn-gold"
                    href={NET.faucet}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Get gas ETH ↗
                  </a>
                </div>
              )}
              <div className="live-row">
                {bal !== null && !noGas && (
                  <a
                    className="btn btn-ghost"
                    href={NET.faucet}
                    target="_blank"
                    rel="noreferrer"
                  >
                    More gas ↗
                  </a>
                )}
                <button className="btn btn-gold" disabled={busy} onClick={drip}>
                  {busy
                    ? "dripping…"
                    : noGas
                      ? "2 · Then get 100,000 $ESSEY + 1,000 USDG"
                      : "Get 100,000 $ESSEY + 1,000 USDG"}
                </button>
              </div>
              {msg && <div className="live-msg">{msg.text}</div>}
            </>
          )}
          <div className="live-note" style={{ marginTop: 10 }}>
            One drip per wallet every 8 hours. Funded? Head to the{" "}
            <Link to="/builder">builder</Link> to mint a Don, or{" "}
            <Link to="/how-it-works">read how it works</Link> first.
          </div>
        </div>
      </div>
    </section>
  );
}
