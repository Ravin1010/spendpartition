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

forge script script/GasSweep.s.sol:GasSweep --rpc-url "$RPC" --broadcast --slow -q

python3 analysis/gas_sweep.py
