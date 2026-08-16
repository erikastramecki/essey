#!/usr/bin/env python3
# Assert the deployed board is the board DeployGame.s.sol seeds. The 2026-08-15 redeploy left four
# briefs under a UI addressing seven by id, and every one of the three orphans reverted BriefNotLive
# for hours without anything logging it — a depart just failed in the player's wallet.
#
#   python3 rh-chain/check-board.py [boardAddress]
#
# Run it after every stack redeploy. Exits non-zero on any mismatch.
import os, subprocess, sys

MB = sys.argv[1] if len(sys.argv) > 1 else "0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1"
RPC = os.environ.get("RH_TESTNET_RPC", "https://rpc.testnet.chain.robinhood.com/rpc")
E18 = 10**18

# Exactly what DeployGame.s.sol::_seedBriefs + _seedBoardTail post, time units expanded.
EXPECT = {
    1: ("PAPER ROUTE", 1, 10800, 780_000, 930_000, 36*E18, 144*E18//10, 45*E18//100, 15*E18, 11_538),
    2: ("GLASS HARVEST - RUSH", 2, 18000, 700_000, 880_000, 75*E18, 30*E18, 87*E18//100, 30*E18, 12_857),
    3: ("PROOF OF WORK", 3, 43200, 600_000, 820_000, 236*E18, 944*E18//10, 244*E18//100, 80*E18, 15_000),
    4: ("ABSOLUTE ZERO", 4, 86400, 120_000, 350_000, 2775*E18, 222*E18, 576*E18//100, 200*E18, 75_000),
    5: ("MILK RUN", 1, 75, 985_000, 999_500, 6000*E18, 2400*E18, 1*E18, 0, 0),
    6: ("OPEN WINDOW", 1, 1200, 985_000, 999_500, 100*E18, 40*E18, 1*E18, 0, 0),
    7: ("DEEP RUN", 5, 57600, 120_000, 300_000, 800*E18, 60*E18, 16*E18//10, 500*E18, 9_000),
}
FIELDS = ["codename", "tier", "duration", "cumSuccessPpm", "cumPartialPpm",
          "successPay", "partialPay", "dispatchFee", "provisionCap", "betaBps"]
SIG = "briefs(uint64)(bool,uint8,uint32,uint32,uint32,uint256,uint256,uint256,uint256,uint256,string)"


def read(i):
    out = subprocess.run(["cast", "call", MB, SIG, str(i), "--rpc-url", RPC],
                         capture_output=True, text=True, timeout=90)
    if out.returncode != 0:
        raise SystemExit(f"cast failed on brief {i}: {out.stderr.strip()}")
    rows = [r.strip() for r in out.stdout.strip().splitlines()]
    num = lambda s: int(s.split(" ")[0])
    return {
        "live": rows[0] == "true", "tier": num(rows[1]), "duration": num(rows[2]),
        "cumSuccessPpm": num(rows[3]), "cumPartialPpm": num(rows[4]),
        "successPay": num(rows[5]), "partialPay": num(rows[6]), "dispatchFee": num(rows[7]),
        "provisionCap": num(rows[8]), "betaBps": num(rows[9]),
        "codename": rows[10].strip('"'),
    }


fails = 0
count = subprocess.run(["cast", "call", MB, "briefCount()(uint64)", "--rpc-url", RPC],
                       capture_output=True, text=True, timeout=90).stdout.split()[0]
print(f"briefCount on chain: {count}  (script seeds {len(EXPECT)})")
if int(count) != len(EXPECT):
    print("FAIL  briefCount != number the script seeds")
    fails += 1

for i, exp in EXPECT.items():
    got = read(i)
    bad = [f"{f}: script={e!r} chain={got[f]!r}" for f, e in zip(FIELDS, exp) if got[f] != e]
    if not got["live"]:
        bad.append("live: chain=False")
    print(("PASS  " if not bad else "FAIL  ") + f"brief {i} {exp[0]}")
    for b in bad:
        print("        " + b)
    fails += len(bad)

print("--- BRIEF SEED AUDIT: " + ("PASS ---" if not fails else f"FAIL ({fails}) ---"))
sys.exit(1 if fails else 0)
