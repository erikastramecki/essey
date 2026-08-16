# Deploy checklist

Written 2026-08-16 after a night where a stack redeploy broke three things one at a time, hours
apart, each discovered by a tester rather than by us. Every one had the same shape: **something was
still pointing at the old stack, and nothing said so.** None of them threw an error anybody saw.

The rule this encodes: **a redeploy is not done when the contracts are up. It is done when every
consumer has been re-pointed AND read back.** Re-pointing is not verification. Read it back.

---

## A. Stack redeploy (new GameController / MissionBoard / RaidEngine / AffinityRegistry)

Work top to bottom. Every step has a read-back, because every failure below was silent.

### 1. Deploy and record

```bash
cd rh-chain && forge script script/DeployGame.s.sol --rpc-url rh_testnet --broadcast
```

Write the new addresses into `docs/DEPLOYMENT-testnet.md` **from the chain, not from the broadcast
log.** Confirm each engine actually bound what you think:

```bash
cast call $RAID  'affinity()(address)' --rpc-url $RPC
cast call $BOARD 'affinity()(address)' --rpc-url $RPC
```

### 2. Briefs — verify the board is SEVEN, not four

`DeployGame.s.sol::_seedBoardTail` posts 5-7. Before that fix existed the script seeded only four
and the UI addressed seven by id, so MILK RUN, OPEN WINDOW and DEEP RUN reverted `BriefNotLive` for
every player.

```bash
cast call $BOARD 'briefCount()(uint64)' --rpc-url $RPC        # expect 7
for i in 1 2 3 4 5 6 7; do cast call $BOARD "briefs(uint64)(bool,uint8,uint32,uint32,uint32,uint256,uint256,uint256,uint256,uint256,string)" $i --rpc-url $RPC | tail -1; done
```

Each codename must match `app/web/src/game/briefs.ts` **at the same id** — `chainId` there is
positional and hardcoded. Ids come from `++briefCount`, so seeding order is what makes them line up.

### 3. Budgets — a board with no budget reverts at depart

```bash
cast call $BOARD  'missionBudget()(uint256)'  --rpc-url $RPC
cast call $ESCROW 'stipendBudget()(uint256)'  --rpc-url $RPC
```

`missionBudget` reserves worst-case at dispatch, so it drains faster than payouts suggest: MILK RUN
alone reserves 6,000 per run, i.e. ~166 dispatches per 1M. `stipendBudget` funds the one-time ◫50
first-play stake at 50 per Don. **Nothing warns before either runs dry** — they just start reverting.
Top up with `fundMissionBudget` / the stipend funder (admin, instant, no timelock).

### 4. Keeper — re-point the FILE *and* restart the PROCESS *and* reset its state

This one cost a whole night. All three parts are required and the failure is completely silent.

- Update addresses in `rh-chain/game-keeper.sh` — **all four, and `ENTROPY` is the one that gets
  missed.** The 08-15 re-point updated `BOARD` and `RAID` and left `ENTROPY` on the old stack, so the
  keeper delivered every word to a contract nothing was waiting on. Missions sat at
  `entropyRequested=true, settled=false` forever and the keeper log looked perfectly busy. Read it
  off the contracts rather than copying it forward:

```bash
cast call $BOARD 'entropy()(address)' --rpc-url $RPC   # must equal ENTROPY in game-keeper.sh
cast call $RAID  'entropy()(address)' --rpc-url $RPC   # and so must this
```
- **Kill the running keeper.** A long-running bash loop holds the old script in memory, so editing
  the file changes nothing until the process restarts. Check its start time against the file mtime:

```bash
ps aux | grep game-keeper | grep -v grep      # started BEFORE the script mtime? it is stale
ls -la rh-chain/game-keeper.sh
```

- **Reset the low-water mark.** `rh-chain/.keeper-state/mission.lo` persists the lowest unsettled
  mission id. When the old board fully settled, the keeper wrote `tail + 1` (73). The new board had
  37 missions, so the scan range `73 → 37` was empty and it resolved nothing, forever, while looking
  perfectly healthy in `ps`.

```bash
kill <pid>
echo 1 > rh-chain/.keeper-state/mission.lo
cd rh-chain && nohup ./game-keeper.sh > /tmp/game-keeper.log 2>&1 &
```

- **The keeper is supervised by launchd** (`rh-chain/xyz.essey.game-keeper.plist`, installed at
  `~/Library/LaunchAgents/`). `KeepAlive` restarts it on crash and `RunAtLoad` survives reboot. The
  `PATH` entry is load-bearing: launchd starts with a minimal PATH and `cast` lives in
  `~/.foundry/bin`, so without it every chain call fails and the keeper looks alive while doing
  nothing. After editing the script, restart the job rather than the process:

```bash
launchctl kickstart -k gui/$(id -u)/xyz.essey.game-keeper
```

- **Then run the health check.** launchd only catches a crash; it cannot see the failure that
  actually happened on 2026-08-15, where the process was up and logging while resolving nothing:

```bash
./rh-chain/check-keeper.sh          # exits 1 on a stale mission or an ENTROPY mismatch
```

  It checks the symptom (a mission past due and unsettled) rather than the process, and it compares
  `board.entropy()` against the address in `game-keeper.sh` — the exact 08-15 defect. Verified in
  both directions: green on a healthy board, exit 1 when the old entropy address is put back.

- Read back that missions actually settle — do not trust the process being alive:

```bash
cast call $BOARD "missions(uint64)(uint256,uint64,uint64,uint64,bytes32,uint256,uint256,bool,bool)" <pastDueId> --rpc-url $RPC
```

The last two fields are `entropyRequested, settled`. `true false` for more than a few minutes means
entropy was requested and the callback never landed. `false false` past due means `resolve` is not
being called at all.

### 5. Attestation — a new registry starts empty

```bash
AFFINITY=0x… ./rh-chain/attest-dons.sh 1 <maxDonId>
```

Un-attested Dons are not broken — they read a zero sheet and play at published odds — so testing can
start before this finishes. Re-run it after new mints.

### 6. MCP

Update `mcp/essey-game.mjs` addresses **in the same commit as the contract change** (standing rule),
and exercise one real tool call against the new stack.

### 7. Site

Update `app/web/src/game/gameChain.ts`. Note `loadoutRegistry` aliases MissionBoard — it is the
EIP-712 `verifyingContract`, so a missed update breaks every depart signature, not just reads.

Then deploy per section B.

### 8. Copy + MCP reconciliation — MANDATORY, every contract deploy

**Founder ruling 2026-08-16: this runs on every contract deploy, without exception.** A deploy is
the thing that makes player-facing copy false, so the audit belongs here rather than on a calendar.

Dispatch one agent (`don-designer` — it needs the mechanics, not just the prose) with this brief:

> Re-read every player-facing surface against the contracts **as deployed right now**, and reconcile:
> `app/web/src/game/*.tsx`, `app/web/src/howtoplay.tsx`, `app/web/src/faucet.tsx`,
> `app/web/src/game/briefs.ts`, `docs/GAME-GUIDE.md`, and the `INSTRUCTIONS` block in
> `mcp/essey-mcp.mjs`. For every claim: **wrong about something built → fix it against source;
> not built but scoped → mark "arrives with a later posting"; not built and not planned → delete.**
> Verify every number by reading the contract, never by recall. If a claim is false and the correct
> replacement is not derivable, REPORT it — do not invent one. Voice rule: say the mechanic, cut the
> aphorism.

**Why this is not optional.** On 2026-08-15 traits went live and both the site and the MCP kept
telling players traits did nothing. The first run of this audit (2026-08-16) found **six** false
claims, including "Crew cap: five" — which is not a rule at all, cost a live tester real time, and
had the founder being told one thing by the docs and another by the desk.

---

## B. Site deploy

**Production is CLI-deploy-only, from the REPO ROOT.** The Vercel Root Directory is `app/web`, so
running `vercel` from inside `app/web` fails with a doubled path.

```bash
cd ~/Developer/assay && vercel --prod --yes
./app/web/check-deploy-assets.sh          # MUST exit 0
```

`app/web/public/{traits,builder}` are gitignored (27MB of pre-mint art, public repo). A git-sourced
build ships without them, and the SPA rewrite answers every missing asset with a **200 serving
index.html** — healthy status codes, green build, blank builder, placeholder SVG for every Don.
`check-deploy-assets.sh` asserts content **type**, never status code, which is the only signal.

`git.deploymentEnabled: {main: false}` in `app/web/vercel.json` stops pushes to main from building
production. **Do not remove it** without moving the art out of gitignore first.

---

## C. After any content change

- Player-facing copy can name a brief that is not posted. The site's How to Play cannot drift (it
  renders from `BRIEF_ORDER`), but the markdown guide and hardcoded error strings can, and did —
  `crew.tsx` and `raid.tsx` told stuck players to run a job that reverted.

```bash
grep -rn "MILK RUN\|DEEP RUN\|OPEN WINDOW\|PAPER ROUTE" app/web/src docs/GAME-GUIDE.md | grep -v briefs.ts
```

Every hit must name a brief that is live on chain.

---

## The three that would have caught all of tonight

None of these exist yet. In rough value order:

1. **A board check** — read `briefCount` and each codename, compare to `briefs.ts`, exit non-zero.
   Same shape as `check-deploy-assets.sh`, which caught its outage in seconds.
2. **A keeper heartbeat** — the keeper should fail loudly when its low-water mark exceeds
   `missionCount`, which is definitionally impossible and is exactly what happened.
3. **Resolve briefs by codename, not hardcoded id.** `briefs.ts` pins `chainId: 7n`; stripping the
   two training wires for a real-value season silently repoints every job in the UI.
