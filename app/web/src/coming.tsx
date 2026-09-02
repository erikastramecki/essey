import { Link } from "react-router-dom";

type Item = { tag: string; head: string; body: string; note?: string };

const HEADLINE: Item[] = [
  {
    tag: "the take becomes the ticker",
    head: "Jobs pay in real stock",
    body: "Every brief in Solvency is already pegged to a real tokenized company, and the guide prints each contract so you can check it. Today the take is Scrip marked to that peg. It will be the asset itself: the chip fab job pays the chip company, the wafer run pays the flagship, the long odds pay the long shots.",
    note: "AAPL and NVDA are wired on chain today, token and price both. The rest of the ledger is marked pending its proof, and stays marked until it passes.",
  },
  {
    tag: "districts",
    head: "Each district pays its own asset",
    body: "The board stops being one payout curve and becomes a map. Tech pays its tickers, the broad-market run pays the index, the treasury run pays T-bills. Which district you work becomes a position you are taking rather than a flavour of loot.",
    note: "The guide's ledger prints every peg with its contract, and marks the ones still pending their proof. A district opens when its asset is verified on chain, not before. Commodity districts wait on assets that are not there yet.",
  },
  {
    tag: "the other family business",
    head: "Robberies move real positions",
    body: "When one Don hits another, actual shares change hands. Not points. That is the whole reason the vault is sacred and banking is free: what you leave on the table is genuinely someone else's payday.",
    note: "The protocol takes a cut of the transfer. It never takes a cut of a loss.",
  },
];

const NEXT: Item[] = [
  {
    tag: "defence",
    head: "Your house can be hit at home",
    body: "Vulnerability follows unbanked money rather than location, so a garrison stops being decoration and becomes a standing investment. Leave a score out overnight and someone can come for it.",
  },
  {
    tag: "the loadout",
    head: "Traits become the stat sheet",
    body: "The trait registry is written and tested. Once it is live your Don's face is its build: attack, nerve, guile, how fast a crew recovers, how hard you are to read. The bounds are fixed so a rare Don shifts where your edge sits, never how much of it you have.",
  },
  {
    tag: "intel",
    head: "The Scout, and what money cannot buy",
    body: "Paid reconnaissance on a mark: how exposed they are, how long they are out, banded rather than exact. What stays hidden stays hidden by cryptography. A garrison is a sealed commitment until it opens, and nobody sells you a look at it.",
  },
  {
    tag: "crews",
    head: "Outfits, and doors one Don cannot open",
    body: "Charter a crew for a specific job, run it, and the charter dissolves. Some houses will be defended past what any single Don can breach, which is the only honest reason to bring five.",
  },
];

function Card({ i }: { i: Item }) {
  return (
    <div className="soon-card">
      <div className="soon-tag">{i.tag}</div>
      <h3>{i.head}</h3>
      <p>{i.body}</p>
      {i.note ? <p className="soon-note">{i.note}</p> : null}
    </div>
  );
}

export function ComingPage() {
  return (
    <div className="soon">
      <div className="soon-stamp">designed and ruled · not yet shipped</div>
      <p className="soon-lede">
        What you are playing is the loop, proved with play money.
        Everything below is designed, argued over and written down. None of it
        is live yet, and some of it will change before it is. We would rather
        tell you that than sell you a roadmap as though it were a product.
      </p>

      <div className="soon-grid">
        {HEADLINE.map((i) => (
          <Card key={i.head} i={i} />
        ))}
      </div>

      <h2 className="soon-h">Also on the board</h2>
      <div className="soon-grid">
        {NEXT.map((i) => (
          <Card key={i.head} i={i} />
        ))}
      </div>

      <div className="soon-foot">
        <h3>What is already real</h3>
        <p>
          The game runs today, live with play money. Jobs resolve,
          robberies land, houses take damage, and every roll is drawn at
          settlement rather than in a transaction you could rewind. You can hand
          the board to Claude and let it do the arithmetic. That part is not a
          promise, it is deployed, and the numbers on it are read off the
          contracts.
        </p>
        <p className="soon-cta">
          <Link className="btn btn-gold" to="/game">
            Play it now
          </Link>
          <Link className="btn btn-ghost" to="/docs/game-guide">
            Read the guide
          </Link>
        </p>
      </div>
    </div>
  );
}
