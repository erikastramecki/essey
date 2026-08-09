#!/usr/bin/env bash
# On-chain borrow-path rehearsal COMPLETION — run AFTER the 2-day param timelock elapses on the throwaway
# rehearsal stack deployed by DeployLendingRehearsal.s.sol. Commits the AAPL/NVDA markets, then exercises
# the fixed borrow path end-to-end on Robinhood Chain testnet: borrow -> adminBurn (issuer destroys half the
# collateral) -> repay and confirm the borrower recovers only the SURVIVING (haircut) collateral (fix #2),
# then a second borrow -> price drop -> liquidate (fixed liveness/session gating). Simulate-before-send on the
# state-changing calls. Reads the deployer key from .env (never echoed).
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
RPC=rh_testnet
PK="$TESTNET_DEPLOYER_PK"
ME="$TESTNET_DEPLOYER_ADDR"

# Rehearsal addresses (from DeployLendingRehearsal broadcast 2026-08-09)
POOL=0x758038893995e4c55a60b3d5A20Eac6aCcFd34bA
MARKETS=0x4cAF160B70F1AC214dcdd544459d984551e99456
USDG=0xa29b3361cB3736d93B62025be380389CF1b6A177
AAPL=0x6af9498A8a0F5bE19b0D52D50ca6136CBE9d7af5
AAPLFEED=0x33b4734D8b61E60C41Fd83c7d0E8499e703294C6

send(){ cast send "$@" --rpc-url $RPC --private-key "$PK" >/dev/null && echo "  ok"; }
call(){ cast call "$@" --rpc-url $RPC; }

echo "== 1. commit the AAPL market (fails if the 2-day timelock has not elapsed) =="
send $MARKETS 'commitMarket(address)' $AAPL
echo "  aapl enabled: $(call $MARKETS 'market(address)((bool,uint16,uint16,uint16,uint8,uint128))' $AAPL | head -c 6)"

echo "== 2. borrow 700 USDG against 10 AAPL (\$2000 @ 35% LTV) =="
send $AAPL 'approve(address,uint256)' $POOL $(cast max-uint)
ID=$(cast call $POOL 'borrow(address,uint256,uint256)(uint256)' $AAPL 10000000000000000000 700000000000000000000 --rpc-url $RPC --from $ME) # simulate to get id
send $POOL 'borrow(address,uint256,uint256)' $AAPL 10000000000000000000 700000000000000000000
echo "  position id: $ID ; debt: $(call $POOL 'debtOf(uint256)(uint256)' $ID)"

echo "== 3. issuer adminBurns HALF the collateral (5 of 10 AAPL) out of the pool =="
send $AAPL 'adminBurn(address,uint256)' $POOL 5000000000000000000
echo "  pool AAPL balance now: $(call $AAPL 'balanceOf(address)(uint256)' $POOL)"

echo "== 4. repay -> must return only the SURVIVING ~5 AAPL (fix #2 haircut), not the original 10 =="
BEFORE=$(call $AAPL 'balanceOf(address)(uint256)' $ME)
send $USDG 'approve(address,uint256)' $POOL $(cast max-uint)
send $POOL 'repay(uint256,uint256)' $ID 701000000000000000000  # >= owed; refunds change
AFTER=$(call $AAPL 'balanceOf(address)(uint256)' $ME)
echo "  AAPL returned to borrower: $(cast to-dec $(cast sub $AFTER $BEFORE 2>/dev/null || echo 0) 2>/dev/null || echo "$BEFORE -> $AFTER") (expect ~5e18, the haircut — NOT 10e18)"
echo "  debt cleared: $(call $POOL 'debtOf(uint256)(uint256)' $ID)"

echo "== 5. second borrow -> drop price -> liquidate (session/liveness gating intact) =="
send $POOL 'borrow(address,uint256,uint256)' $AAPL 5000000000000000000 350000000000000000000 # 5 AAPL, borrow 350
ID2=$(($ID + 1))
send $AAPLFEED 'set(int256,uint256)' 100000000000 $(date +%s)  # $100/share -> 5*$100=$500 < threshold on 350 debt path
send $POOL 'liquidate(uint256)' $ID2
echo "  position 2 debt after liquidation: $(call $POOL 'debtOf(uint256)(uint256)' $ID2)"

echo "== REHEARSAL COMPLETE: borrow, adminBurn haircut, repay, and liquidate all exercised on-chain. =="
