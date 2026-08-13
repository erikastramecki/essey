// /how-to-play — the beginning-to-end walkthrough of D.O.N., built in the game's own dossier
// grammar (game.css + game/bits.tsx) so it FEELS like the game before you've touched it.
// Every number on this page is the number on the chain: briefs come straight from
// src/game/briefs.ts (the posted on-chain board) and the rest mirrors docs/GAME-GUIDE.md,
// the audited rulebook, linked at the bottom as "the full house rules."
// Honesty rule, verbatim: this season settles in Scrip (play points) marked to tickers;
// real-token settlement is the roadmap — never imply testers receive real stock now.
import { useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { CaseFile, WaxSeal, Stamp, RatingStamp, OddsLadder, BigEnvelope, fmtAmt } from "./game/bits";
import { BRIEFS, BRIEF_ORDER, SEASON, type BriefKey } from "./game/briefs";
import "./game/game.css";
import "./howtoplay.css";

const noop = () => {};

/// One static case file in the stack — CaseFile itself, pinned open by the .htp overrides.
function File({ no, tab, head, children }: { no?: string; tab: string; head: string; children: ReactNode }) {
  return (
    <CaseFile open tab={tab} head={head} onClose={noop}>
      {no && <div className="htp-step-no">{no}</div>}
      {children}
    </CaseFile>
  );
}

function W({ lbl, children }: { lbl?: string; children: ReactNode }) {
  return <p className="g-word">{lbl && <span className="lbl">{lbl}</span>}{children}</p>;
}

// ------------------------------------------------------------------ interactive bits

/// The four canonical briefs, tabbed — odds, pays, fees and provisioning read from briefs.ts
/// verbatim. The testnet proving-ground training wires are filtered out here and disclosed in
/// a note instead (they're season-zero courtesies, not the board's shape).
const CANON = BRIEF_ORDER.filter((key) => BRIEFS[key].ratingLabel !== "TRAINING");
const TRAINING = BRIEF_ORDER.filter((key) => BRIEFS[key].ratingLabel === "TRAINING");

function BriefBoard() {
  const [k, setK] = useState<BriefKey>("paper");
  const b = BRIEFS[k];
  const fullBoost = (b.provisionCap * b.betaBps) / 10_000n;
  return (
    <>
      <div className="htp-briefs">
        {CANON.map((key) => (
          <button key={key} aria-pressed={k === key} onClick={() => setK(key)}>{BRIEFS[key].code}</button>
        ))}
      </div>
      <div className="g-typed" style={{ margin: "6px 0 10px" }}>
        <p className="g-word"><span className="lbl">The job</span>{b.job}</p>
        <p className="g-word"><span className="lbl">Window</span>{b.durationH} hours — your Don is away, and your House stands open, for exactly this long. <RatingStamp rating={b.rating}>{b.ratingLabel}</RatingStamp></p>
        <p className="g-word"><span className="lbl">The word</span>{b.word}</p>
      </div>
      <OddsLadder odds={b.odds}
        payout={`◫ ${fmtAmt(b.partialPay, 1)} sideways · ◫ ${fmtAmt(b.successPay, 1)} clean`} />
      <div className="g-feeline">
        <span>door fee ◫ {fmtAmt(b.dispatchFee, 2)} · burned at dispatch</span>
        <span>provision cap ◫ {fmtAmt(b.provisionCap)} · beta {(Number(b.betaBps) / 10_000).toFixed(4)}×</span>
      </div>
      <p className="g-provnote">a full carry (◫ {fmtAmt(b.provisionCap)}) adds ◫ {fmtAmt(fullBoost, 1)} to the CLEAN take only —
        and burns win or lose. provisions never move the odds. never.</p>
      {TRAINING.length > 0 && (
        <p className="g-provnote">this test season the board also posts {TRAINING.length} proving-ground training
          wire{TRAINING.length > 1 ? "s" : ""} — {TRAINING.map((key) => `${BRIEFS[key].code} (${BRIEFS[key].tab.replace("proving ground · ", "")}, ◫ ${fmtAmt(BRIEFS[key].successPay)} clean)`).join(" and ")} —
          season-zero courtesies to bankroll your first Hitters. they strip before any real-value season.</p>
      )}
    </>
  );
}

/// The practice seal — the same single-click component the real dossier uses, firing nothing.
function PracticeSeal() {
  const [sealed, setSealed] = useState(false);
  return (
    <div className="htp-sealrow">
      <WaxSeal sealed={sealed} hint={sealed ? "SEALED — THAT'S THE WHOLE GESTURE" : "TRY IT · CLICK THE SEAL · THIS ONE SIGNS NOTHING"}
        onCommit={() => setSealed(true)} />
      {sealed && <Stamp ok thump>PRACTICE ONLY — NO TX FIRED</Stamp>}
    </div>
  );
}

/// The cooldown curve, playable: hours since last attempt → the share of full odds you keep.
/// Quadratic, exactly as the guide publishes it: (h/20)² — 20h back to 100%.
function CooldownToy() {
  const [h, setH] = useState(10);
  const pct = Math.round((Math.min(h, 20) / 20) ** 2 * 100);
  return (
    <div className="htp-cool">
      <input type="range" min={0} max={20} step={1} value={h} onChange={(e) => setH(+e.target.value)}
        aria-label="Hours since your Hitter's last attempt" />
      <div className="htp-cool-read">
        <span>{h}h since his last attempt</span>
        <span>he swings at <b>{pct}%</b> of full odds</span>
      </div>
      <p className="g-provnote">quadratic, so spam is self-punishing: two hasty attempts are worth less than one
        patient one, always. 20 hours is full strength. the curve is the law — no bookkeeping needed.</p>
    </div>
  );
}

// ------------------------------------------------------------------ the page

export function HowToPlayPage() {
  return (
    <div className="game-root htp">
      <div className="htp-wrap">

        <header className="htp-hero">
          <div className="htp-kicker">D.O.N. · how to play · season {SEASON.id} — {SEASON.name}</div>
          <h1>Welcome to Solvency.<br />Here's your file.</h1>
          <p className="htp-lede">A port city of 8,888 founding families, a job board with the odds printed on
            the folder, and one rule underneath everything: what you bank is yours forever, and only what you
            put to work can be taken. Ten files below and you'll know the whole game.</p>
          <div className="htp-honest">THE HONEST STAMP — <b>this season settles in Scrip</b> (play points)
            marked to tickers; <b>real-token settlement is the roadmap</b>. Nothing you win this season is real
            stock. Testnet funds only, no real value at stake.</div>
        </header>

        {/* ---------------- 01 · connect ---------------- */}
        <File no="Step 01 · gas &amp; papers" tab="FILE 1 · GET YOUR PAPERS" head="ORIENTATION — ARRIVING IN SOLVENCY">
          <W>You need a browser wallet (MetaMask or similar) pointed at <b>Robinhood Chain testnet</b> — the
            site offers to add and switch the network for you when you hit connect. Everything on this chain is
            play money.</W>
          <W lbl="Do this">Open the <Link to="/faucet">Faucet</Link> and drip yourself free testnet funds: a
            little gas ETH first (every action needs a sliver), then the play tokens. This is the one step
            everything else depends on.</W>
          <div className="g-note">the city keeps a file on every family. connect a wallet on the{" "}
            <Link to="/game">desk</Link> and we pull yours.</div>
        </File>

        {/* ---------------- 02 · get a Don ---------------- */}
        <File no="Step 02 · the operative" tab="FILE 2 · GET A DON" head="THE REGISTRY — 8,888 FOUNDING FAMILIES">
          <W>Your Don is your character, your seat, and his own on-chain wallet, all in one token. His Vault
            balance, his House deed, his crew — the whole estate lives inside the token and travels with him.</W>
          <W lbl="Three ways in">Claim free on the whitelist (traits roll random), reroll the look until you
            like it, or open the <Link to="/builder">builder</Link> and construct him trait by trait. However he
            arrives, he plays the same.</W>
          <W lbl="And the house">Every family starts with a free <b>Safehouse</b>. You don't even claim it —
            the deed mints itself inside your first dispatch. It is small. Nobody sneers at a Safehouse.</W>
        </File>

        {/* ---------------- 03 · where money lives ---------------- */}
        <File no="Step 03 · the ledger" tab="FILE 3 · WHERE MONEY LIVES" head="THE LEDGER — THREE CLAUSES, STILL TRUE">
          <W>8,888 families signed the founding instrument. Not a constitution — constitutions are promises.
            The Ledger is arithmetic:</W>
          <div className="htp-table-scroll"><table className="htp-table">
            <thead><tr><th>Box</th><th>Earns</th><th>Robbable</th></tr></thead>
            <tbody>
              <tr><td className="k">🔒 THE VAULT — banked</td><td>nothing, ever</td><td><b>never</b>. clause one</td></tr>
              <tr><td className="k">♠ THE HOUSE — deployed</td><td>0.15% per day, posted on-chain</td><td>only the big score, only while your Don is away</td></tr>
              <tr><td className="k">▤ THE HOPPER — unbanked pay</td><td>nothing</td><td>yes — the common hit takes exactly this, only while away</td></tr>
            </tbody>
          </table></div>
          <W>Exposure is always a choice. Money sits in the Vault by default; <b>deploying</b> it is an explicit
            act, and <b>taking a job</b> is the second explicit act — the one that opens the robbery window.
            The lazy man's summary: the Vault is a mattress, the House is a business, the hopper is the till.
            Robbers go for the till. Empty it nightly.</W>
        </File>

        {/* ---------------- 04 · deploy ---------------- */}
        <File no="Step 04 · working capital" tab="FILE 4 · DEPLOY TO THE HOUSE" head="PROPERTY — THE DEED LADDER">
          <W>Deployed Scrip earns <b>0.15% per day</b>, a fixed constant this season, posted on-chain. A bigger
            house earns nothing by itself — it raises the cap on what you may expose, adds chairs for your
            garrison, and hardens the door. The ladder sells capacity, never yield.</W>
          <div className="htp-table-scroll"><table className="htp-table">
            <thead><tr><th>Deed</th><th className="n">Price</th><th className="n">Deploy cap</th><th className="n">Chairs</th><th>This season</th></tr></thead>
            <tbody>
              <tr><td className="k">Safehouse</td><td className="n">free</td><td className="n">◫ 5,000</td><td className="n">2</td><td>open</td></tr>
              <tr><td className="k">Row House</td><td className="n">◫ 1,500 · burned</td><td className="n">◫ 15,000</td><td className="n">3</td><td>open</td></tr>
              <tr><td className="k">Brownstone</td><td className="n">◫ 4,000</td><td className="n">◫ 40,000</td><td className="n">3</td><td>opening soon</td></tr>
              <tr><td className="k">Estate</td><td className="n">◫ 12,000</td><td className="n">◫ 100,000</td><td className="n">4</td><td>opening soon</td></tr>
              <tr><td className="k">Compound</td><td className="n">◫ 40,000</td><td className="n">◫ 250,000</td><td className="n">5</td><td>opening soon</td></tr>
            </tbody>
          </table></div>
          <W lbl="Start small">Deploy a little, take a short job, come home, bank. Learn the rhythm before you
            raise the stakes. Upgrades level the deed in place — nothing is lost climbing.</W>
        </File>

        {/* ---------------- 05 · the job ---------------- */}
        <File no="Step 05 · the dossier" tab="FILE 5 · SEND HIM ON A JOB" head="DISPATCH — THE FOLDER IS THE ODDS">
          <W>A job arrives as a dossier: your Don's portrait clipped to the corner, the brief typed inside, and
            the odds ladder printed on the folder — because the folder <b>is</b> the on-chain odds table wearing
            a trench coat. The dispatcher never lies. Three outcomes on every folder:</W>
          <W lbl="The bands"><b>clean</b> — full pay. <b>sideways</b> — the job went sideways; the partial pay
            printed on the folder. <b>bust</b> — nothing lands, provisions gone. The chain rolls one number
            against the published bands; nothing about your gear, level, or luck ever moves them.</W>
          <W lbl="The live board">The four posted briefs, verbatim from the chain — tap through:</W>
          <BriefBoard />
          <hr className="g-dashrule" />
          <W lbl="The wax seal">Dispatching is one click on a wax seal. Under the wax it's an{" "}
            <b>EIP-712 signature</b> — a single typed message your wallet signs that says, in plain words:
            <i> "this Don, this job, this much provision, and this exact guard roster on my door."</i> The
            contract verifies that signature on-chain; nothing departs without it, and nobody can alter what
            you signed after the fact. The garrison commit rides inside the same signature — which is why your
            defense is frozen for the whole window, and why nobody conjures guards at the last second.</W>
          <PracticeSeal />
          <hr className="g-dashrule" />
          <W lbl="How it pays">At the window's end the Keeper rolls the outcome and your pay lands as Scrip in
            the <b>House hopper</b> — the till, not the Vault. The door fee burns at dispatch. If the Keeper
            ever stalls, anyone can settle a stuck job two hours past its window, and it settles at the
            sideways floor, never at zero. Slow is possible. Stuck is not. One active job per Don at a time —
            even legends work single file.</W>
          <W lbl="Later, when the take is real">Roadmap, stamped: in the real-asset seasons the district you
            work decides the asset you carry home — the tech quarters pay their tokenized equity, Ledger Row
            pays T-bills, the Refinery pays oil, the Mint pays silver. You don't buy it, you <b>win</b> it by
            playing, in fixed units of the asset itself. And won stock banks to a <b>claim box no raid can
            touch</b>: it's yours and safe the instant the job resolves. Not this season, and no dates —
            arrivals, not schedules.</W>
          <details>
            <summary>Provisioning — pressing your own bet</summary>
            <div><W>You can burn extra Scrip at dispatch, up to the folder's cap. Provisions <b>never move the
              odds</b> — what they buy is a fatter take on the clean outcome only, at the folder's posted beta.
              Go sideways or bust and the provision was a bonfire. Across the city, every 100 Scrip provisioned
              returns about 90 in expectation: provision because you like the job, not because it beats the
              math. It does not. Nothing here does.</W></div>
          </details>
        </File>

        {/* ---------------- 06 · bank it ---------------- */}
        <File no="Step 06 · the sacred function" tab="FILE 6 · BANK IT" head="THE VAULT — CLAUSE ONE">
          <div className="htp-sacred"><b>BANKING IS FREE. FOREVER.</b> Hopper → Vault costs gas and nothing
            else — no fee, no delay, no future knob. Every exit in this game is free: bank, claim, withdraw.
            The city charges you to take risks and to buy services. It never charges you to stop.</div>
          <W>And once it's banked, it's <b>sacred</b>: no mechanic, no robbery, no admin — nothing in the game
            can touch your Vault. What can be lost is exactly what you chose to expose: deployed Scrip, the
            hopper, provisions carried, and fees paid. That's the whole trust model, and it's clause one and
            two of the Ledger.</W>
          <W lbl="The habit">Your Don can only bank while he's <b>home</b> — home means untouchable, and home
            means you can sweep the till instantly. So the whole defensive art is three words long: bank
            often, garrison well, choose your windows. <b>Bank before you brag.</b></W>
        </File>

        {/* ---------------- 07 · hitters ---------------- */}
        <File no="Step 07 · the crew" tab="FILE 7 · MINT A HITTER" head="THE BENCH — NO PHOTOGRAPHS ON FILE">
          <W>A Don works jobs. A <b>crew</b> does the other thing. A Hitter mints for <b>◫ 900</b>, burned from
            your Don's vault — no ETH, a pure Scrip sink. Crew cap: five. And every Hitter is either <b>on the
            hunt</b> or <b>on the door</b>, never both: a garrisoned Hitter adds real defense but cannot rob
            anyone while he stands there. Everything in this city costs its alternative.</W>
          <div style={{ textAlign: "center", margin: "12px 0" }}><BigEnvelope /></div>
          <W lbl="The favor">Clipped inside every Hitter's dossier is a sealed envelope from the family. It
            opens on his first job, never before, and the odds are published on-chain before a single one is
            sold:</W>
          <div className="htp-table-scroll"><table className="htp-table">
            <thead><tr><th>The envelope</th><th className="n">Odds</th><th>Inside</th></tr></thead>
            <tbody>
              <tr><td className="k">Empty</td><td className="n">70%</td><td>nothing mechanical — a stamp, so the moment still prints</td></tr>
              <tr><td className="k">A small favor</td><td className="n">20%</td><td>one minor edge</td></tr>
              <tr><td className="k">A real favor</td><td className="n">8.5%</td><td>one real edge</td></tr>
              <tr><td className="k">The Don owes you</td><td className="n">1.5%</td><td>a named signature edge, announced citywide. 1 in 67</td></tr>
            </tbody>
          </table></div>
          <W>A sealed Hitter can't be sold sealed (no secondary market in secrets), nothing ever re-rolls an
            envelope, and favors bend odds, never money.</W>
        </File>

        {/* ---------------- 08 · raids ---------------- */}
        <File no="Step 08 · the other business" tab="FILE 8 · THE RAID" head="STAKEOUT — THE AWAY-WINDOW LAW">
          <W lbl="The law">A House can be hit <b>only while its Don is away on a job</b> — and depart lines
            print on the Tape, so a Don who took a 12-hour job left a door standing open for 12 hours, and
            everyone knows it. That's the away-window law, and the whole raiding profession lives inside it.</W>
          <W lbl="The filing">Your Hitter commits to a target without naming it in public: a sealed filing plus
            <b> ◫ 50, sunk win or lose</b>. Walk away without kicking the door and the 50 burns anyway —
            cowardice is a fee like everything else.</W>
          <W lbl="The window">You reveal the target <b>10 to 40 minutes</b> after the commit — the delay kills
            mempool sniping in both directions. You're attacking blind: the defender's garrison was frozen in
            their depart signature and stays fog until you're through the door.</W>
          <W lbl="What a hit takes">If you get in, a second roll decides the night: <b>92%</b> — the common
            hit: the hopper (every unbanked Scrip in the till), and the House earns −40% until repaired.
            <b> 8%</b> — the big score: 15–30% of <i>deployed</i> holdings (average ~20%), hard-capped, one
            big score per House per 48 hours. The Vault — never. The city takes <b>7.5%</b> of every
            transferred score; the Floor eats with the winners.</W>
          <W lbl="Your odds">The success band is clamped: never below 5%, never above 70% — no sure things in
            Solvency, in either direction. This season a fresh Hitter kicking an undefended starter House lands
            about <b>40%</b>; a full crew of five pushes the same door to about <b>62%</b>. Robbing negligence
            is a profession; robbing a defended House is a donation.</W>
          <W lbl="What you risk">A failed attempt isn't free: your Hitter risks being taken — 20% against a
            naked house, up to 43% against a full crew — and taken means a <b>48-hour hospital stay</b>,
            benched while the street keeps moving.</W>
          <W lbl="Later, when the take is real">A stamped roadmap note, so you hear it here too: the real-asset
            seasons keep this 48-hour lockout and the sacred Vault, but the big-score bite becomes
            <b> skill-scaled</b> — a dominant crew that scouted a wide-open House can reach a rare, earned
            ceiling of <b>65% of deployed</b>, and the <b>Fixer's Book</b> sells a cushion (roughly a quarter
            of a bad night handed back). Banking is, and always will be, the free protection. Nothing real this
            season; the full road is in <Link to="/docs/game-guide">the house rules</Link>.</W>
          <details>
            <summary>The full cap stack — for the spreadsheet crowd</summary>
            <div><div className="htp-table-scroll"><table className="htp-table">
              <thead><tr><th>Rule</th><th>Limit</th></tr></thead>
              <tbody>
                <tr><td className="k">Hitter cooldown</td><td>20h to full odds; early attempts on the curve below</td></tr>
                <tr><td className="k">Same attacker, same target</td><td>1 attempt per 24h</td></tr>
                <tr><td className="k">Target heat</td><td>8h immunity the moment an attempt is filed against you, from anyone</td></tr>
                <tr><td className="k">Big-score lockout</td><td>1 per House per 48h</td></tr>
                <tr><td className="k">Garrison</td><td>frozen at depart — the roster you sign is the roster for the whole window</td></tr>
                <tr><td className="k">Dispatches</td><td>1 active job per Don at a time</td></tr>
              </tbody>
            </table></div></div>
          </details>
        </File>

        {/* ---------------- 09 · repair + patience ---------------- */}
        <File no="Step 09 · the morning after" tab="FILE 9 · REPAIR &amp; THE COOLDOWN" head="THE CORK BOARD — PATIENCE IS A WEAPON">
          <W lbl="Repair">A hit House earns −40% until repaired. Repairs cost about a day and a half of that
            House's earning rate, pro-rated by damage — and a scarred, unrepaired House is a public confession
            on the Tape: dealing with it is a fee, and everyone can see you have not.</W>
          <W lbl="The cooldown curve">After any attempt, win or lose, a Hitter needs <b>20 hours</b> to swing
            at full odds. You can send him early. You should not:</W>
          <CooldownToy />
          <W>The math caps a Hitter at about 1.2 real attempts a day. A bad night's remedy is the oldest one in
            the city: bank, garrison, go again.</W>
        </File>

        {/* ---------------- 10 · house rules ---------------- */}
        <File no="Step 10 · what we owe you" tab="FILE 10 · THE HOUSE RULES" head="THE STANDARD THE CITY IS NAMED FOR">
          <W><b>Every roll's odds are published on-chain before you pay</b> — mission ladders, robbery bands,
            the Favor's four bands. Odds never change mid-season; a new table is a new posting, never a quiet
            edit. <b>The house keeps an edge and we say the number</b>: roughly 10 of every 100 Scrip staked on
            a gamble stays with the house. <b>Banked is sacred. Exits are free, forever. The Keeper cannot
            steal</b> — it resolves jobs and refreshes prices; if it stalls, your job settles at the sideways
            floor and your money remains yours. And <b>this season is testnet</b>: Scrip and test funds only,
            no real value at stake — the Skirmish exists precisely to prove the loop before real assets ride
            it.</W>
          <W lbl="Go deeper">The complete rulebook — every brief, every band, the ticker pegs, and everything
            stamped as arriving with a later posting — is <Link to="/docs/game-guide">the full house
            rules</Link> in the technical docs, rendered from the repo's own file.</W>
          <div className="g-cta htp-cta">
            <div className="g-cta-h">THE BELL IS ABOUT TO RING</div>
            <p>ten files read. one seat missing. the Registry is minting, and the desk is waiting.</p>
            <Link className="g-cta-btn" to="/game">ENTER SOLVENCY →</Link>
            <Link className="g-cta-btn" to="/builder">GET A DON · THE REGISTRY →</Link>
          </div>
        </File>

      </div>
    </div>
  );
}
