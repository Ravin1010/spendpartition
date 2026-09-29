#!/usr/bin/env bash
# Gas sweep on a fresh local anvil chain.
# 1. start anvil (60 funded accounts from the default mnemonic, prague rules)
# 2. broadcast script/GasSweep.s.sol: every deployment and payment is its own transaction
# 3. parse gasUsed from the receipts into results/gas_sweep.csv and results/gas_vs_N.png
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"

anvil --port "$PORT" --accounts 60 --hardfork prague --silent &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
cast chain-id --rpc-url "$RPC" >/dev/null

rm -rf broadcast/GasSweep.s.sol

forge script script/GasSweep.s.sol:GasSweep --rpc-url "$RPC" --broadcast --slow -q --sig "run()"

# Phase 3: the chain clock is advanced between calls, so each payment lands in its own
# one-second window and the first write after a rollover is measured on real transactions.
forge script script/GasSweep.s.sol:GasSweep --rpc-url "$RPC" --broadcast --slow -q --sig "rolloverDeploy()"
for _ in 1 2 3 4; do
  cast rpc evm_increaseTime 5 --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  forge script script/GasSweep.s.sol:GasSweep --rpc-url "$RPC" --broadcast --slow -q --sig "rolloverPay()"
done

python3 analysis/gas_sweep.py
