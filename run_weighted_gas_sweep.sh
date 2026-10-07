#!/usr/bin/env bash
# Isolated receipt-based sweep. Existing baseline broadcasts/results are never removed or written.
set -euo pipefail
cd "$(dirname "$0")"
for tool in forge cast anvil; do
  version="$("$tool" --version)"
  [[ "$version" == *"1.8.4"* ]] || { echo "Require $tool v1.8.4" >&2; exit 1; }
done
PORT="${PORT:-18545}"
RPC="http://127.0.0.1:${PORT}"
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "Port $PORT already has a chain; refusing to reuse state" >&2
  exit 1
fi
LOG="$(mktemp)"
args=(--port "$PORT" --accounts 60 --hardfork prague --timestamp 1700000000
      --mnemonic 'test test test test test test test test test test test junk' --silent)
# Only use an explicit override after recording a normal-limit failure; never silently raise it.
if [[ -n "${ANVIL_GAS_LIMIT:-}" ]]; then args+=(--gas-limit "$ANVIL_GAS_LIMIT"); fi
anvil "${args[@]}" >"$LOG" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true; wait "$ANVIL_PID" 2>/dev/null || true; rm -f "$LOG"' EXIT
for _ in $(seq 1 100); do
  kill -0 "$ANVIL_PID" 2>/dev/null || { cat "$LOG" >&2; exit 1; }
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
cast chain-id --rpc-url "$RPC" >/dev/null
export WEIGHTED_RPC="$RPC"
python3 analysis/weighted_gas_sweep.py --environment
rm -rf broadcast/WeightedGasSweep.s.sol
forge script script/WeightedGasSweep.s.sol:WeightedGasSweep --rpc-url "$RPC" --broadcast --slow -q
python3 analysis/weighted_gas_sweep.py
