import { useEffect, useState } from "react";
import {
  deployed,
  fmt,
  MAINNET,
  readError,
  reads,
  RESERVE,
  type TokenRow,
  type TreasuryState,
} from "./reserve";

const pct = (bps: bigint): string => `${(Number(bps) / 100).toFixed(0)}%`;

/// floorOf is units per 1e18 $ESSEY — a minuscule figure while the reserve is filling. Redemption is
/// linear and pro-rata, so scaling it to a 1,000-$ESSEY basis is exact arithmetic, not a fabricated
/// mark: hold 1,000 $ESSEY and this is the gross slice you claim, before the 5% exit fee.
const FLOOR_BASIS = 1_000n;

export function TreasuryPage() {
  const [st, setSt] = useState<TreasuryState | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    document.title = "Treasury · Essey";
    if (!deployed()) return;
    let live = true;
    const load = () =>
      reads
        .treasury()
        .then((s) => {
          if (live) {
            setSt(s);
            setErr(null);
          }
        })
        .catch((e) => {
          if (live) setErr(readError(e));
        });
    load();
    const t = setInterval(load, 20_000);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, []);

  if (!deployed()) {
    return (
      <section className="band">
        <div className="wrap">
          <Head />
          <div className="hw-card">
            <div className="hw-card-h">
              The reserve deploys soon{" "}
              <span className="preview-chip">not yet on chain</span>
            </div>
            <p>
              The EsseyReserve is being deployed to Robinhood Chain mainnet.
              Once it is on chain, the full backing appears here live — every
              token in the basket, the units the reserve holds of each, and the
              per-token floor — read straight from the contract and verifiable
              on the block explorer.
            </p>
            <p>
              Nothing is minted or backed until the treasury funds the reserve.
              This page will not show a number it cannot read from the chain, so
              it stays on this notice until the reserve address is live.
            </p>
          </div>
          <Terms />
        </div>
      </section>
    );
  }

  const equities = st?.tokens.filter((t) => t.kind === "equity") ?? [];
  const crypto = st?.tokens.filter((t) => t.kind === "crypto") ?? [];
  const equitiesFunded = equities.filter((t) => t.reserve > 0n).length;
  const anyBacking = st ? st.tokens.some((t) => t.reserve > 0n) : false;

  return (
    <section className="band">
      <div className="wrap">
        <Head />

        <div className="hw-stats">
          <Stat
            label="$ESSEY supply"
            value={st ? fmt(st.esseyTotal, 18, 0) : "…"}
          />
          <Stat
            label="Claim-eligible"
            value={st ? fmt(st.circulating, 18, 0) : "…"}
          />
          <Stat
            label="Backing funded"
            value={
              st
                ? `${st.tokens.filter((t) => t.reserve > 0n).length} tokens`
                : "…"
            }
          />
          <Stat
            label="Equities funded"
            value={st ? `${equitiesFunded} / ${equities.length}` : "…"}
          />
          <Stat label="Exit fee" value={st ? pct(st.exitFeeBps) : "…"} />
        </div>

        {st && !anyBacking && (
          <div className="hw-warn">
            <div className="hw-warn-h">Basket listed, not yet funded</div>
            <div>
              The reserve holds none of these tokens today, so every floor below
              reads zero. Backing appears here the moment the treasury makes its
              first deposit; nothing here is projected.
            </div>
          </div>
        )}

        <div className="hw-card">
          <div className="hw-card-h">How the backing works</div>
          <p>
            Holding $ESSEY is a redeemable, pro-rata claim on a basket of
            tokenized stock — paid in the stock itself, not in dollars. The
            reserve is <b>fully adminless</b>: no owner, no registrar, no admin.
            Anyone can deposit stock to raise the floor — any token sent in
            counts automatically — but no key can ever withdraw the basket. The
            only way tokens leave is a holder redeeming their own slice.
          </p>
          <ul className="hw-list">
            <li>
              <b>Redemption is pro-rata and in-kind.</b> Burn $ESSEY and receive
              your share of every token the reserve holds, in units of that
              token — never a dollar payout.
            </li>
            <li>
              <b>A 5% exit fee stays in the reserve.</b> The retained slice,
              plus the burned supply, raise the floor for everyone who keeps
              holding.
            </li>
            <li>
              <b>The floor only ratchets up.</b> Each token&apos;s floor is its
              reserve balance divided by the fixed genesis supply; deposits
              raise it and redemptions never lower it.
            </li>
            <li>
              <b>The peg is quoted in units, not dollars.</b> Solvency is
              unconditional because every payout is a number of tokens the
              reserve provably holds, read live below.
            </li>
            <li>
              <b>Not tradable here.</b> No market is seeded against $ESSEY in
              this reserve — this is a backing ledger, not a price.
            </li>
          </ul>
        </div>

        <div className="hw-card">
          <div className="hw-card-h">Reliable floor — tokenized equities</div>
          <p>
            The equity legs of the basket. These are the backing the floor is
            measured against — the reliable, stock-denominated claim under
            $ESSEY. Each figure is read from the reserve right now; tap a symbol
            to verify the contract&apos;s holding on the explorer.
          </p>
          <BasketTable
            rows={equities}
            loading={!st}
            circulating={st?.circulating ?? null}
          />
        </div>

        <div className="hw-card">
          <div className="hw-card-h">Additive upside — crypto lines</div>
          <p>
            Volatile crypto lines ride in the same reserve and redeem the same
            pro-rata way, but we{" "}
            <b>do not count them toward the reliable floor</b> — they are upside
            on top of it. The split is drawn on chain, not by hand: a token is
            reliable only if it passes the Robinhood Stock Token beacon check;
            anything else lands here. The reserve itself pays every token
            identically.
          </p>
          <BasketTable
            rows={crypto}
            loading={!st}
            circulating={st?.circulating ?? null}
          />
        </div>

        <Terms />

        {err && (
          <div className="hw-warn">
            <div className="hw-warn-h">Reserve read failed</div>
            <div>{err}</div>
          </div>
        )}
      </div>
    </section>
  );
}

function Head() {
  return (
    <div className="band-head">
      <div>
        <span className="eyebrow">Treasury</span>
        <h2>What backs $ESSEY, on chain</h2>
        <p>
          $ESSEY is a redeemable claim on a basket of tokenized stock held in an
          adminless reserve on Robinhood Chain mainnet. Here is the token, here
          is exactly what backs it, and here is how to verify every figure
          yourself.
        </p>
      </div>
    </div>
  );
}

function BasketTable({
  rows,
  loading,
  circulating,
}: {
  rows: TokenRow[];
  loading: boolean;
  circulating: bigint | null;
}) {
  if (loading) return <p className="pf-note">Reading the reserve…</p>;
  if (rows.length === 0)
    return <p className="pf-note">No tokens listed in this band.</p>;
  const empty = circulating === 0n;
  return (
    <div className="hw-scroll">
      <table className="hw-table">
        <thead>
          <tr>
            <th>Token</th>
            <th className="n">Reserve holds</th>
            <th className="n">Floor · units / 1,000 $ESSEY</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((t) => (
            <tr key={t.address}>
              <td className="k">
                <a
                  href={`${MAINNET.explorer}/address/${RESERVE.reserve}?tab=token_transfers`}
                  target="_blank"
                  rel="noreferrer"
                  title={t.address}
                >
                  {t.symbol} ↗
                </a>
              </td>
              <td className="n">
                {fmt(t.reserve, t.decimals, 4)} {t.symbol}
              </td>
              <td className="n">
                {empty
                  ? "—"
                  : `${fmt(t.floor * FLOOR_BASIS, t.decimals, 6)} ${t.symbol}`}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Terms() {
  return (
    <div className="hw-card">
      <div className="hw-card-h">Redemption terms</div>
      <p>
        Redeem any amount of $ESSEY for 95% of its pro-rata slice of every token
        the reserve holds, settled in the tokens themselves. The 5% exit fee and
        any integer dust stay in the reserve, and the redeemed $ESSEY is removed
        from supply — both raise the floor for holders who remain. A token whose
        transfer is paused is skipped and stays claimable later: its slice
        simply waits in the reserve. There is no owner, no registrar, no
        withdraw, and no way for any key to drain the basket.
      </p>
      <p className="disclaim" style={{ marginTop: 12 }}>
        <b>Tokenized equities are securities</b> and carry issuer, custody, and
        market-gap risk. On Robinhood Chain the Stock Token issuer holds an
        adminBurn power that can destroy tokens at any address; reserve holdings
        can therefore change outside a redemption. Backing figures are read live
        from the chain and are not a projection. Not an offer of securities.
        Nothing here is financial advice.
      </p>
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
