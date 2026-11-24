#!/usr/bin/env bash
# Build and run tb_systolic_controller with Verilator 5 (Linux, WSL or CI).
# Usage: bash tb/run_verilator.sh [seed]
set -euo pipefail
TB_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$TB_DIR/../Matrix_multiplier.srcs/sources_1/new"
WORK="$TB_DIR/verilator_work"
SEED="${1:-1}"

python3 "$TB_DIR/gen_vectors.py" --seed "$SEED"

verilator --binary --timing -Wno-fatal --top-module tb_systolic_controller \
    --Mdir "$WORK" -o tb_systolic_controller \
    "$RTL_DIR/pe.sv" "$RTL_DIR/Systolic_NxN.sv" "$RTL_DIR/systolic_controller.sv" \
    "$TB_DIR/tb_systolic_controller.sv" > "$WORK.build.log" 2>&1 \
    || { cat "$WORK.build.log"; exit 1; }

"$WORK/tb_systolic_controller" +VEC_DIR="$TB_DIR/vectors" | tee "$TB_DIR/sim.log"
grep -q "^TB PASS" "$TB_DIR/sim.log"
