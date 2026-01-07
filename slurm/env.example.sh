#!/usr/bin/env bash
set -euo pipefail

# Required
export PARTITION="${PARTITION:-local}"

export ROOT_DIR="${ROOT_DIR:-$HOME/wgpu_workspace}"
export CASE_DIR="${CASE_DIR:-$ROOT_DIR/experiments/cases/test}"
export OUT_DIR="${OUT_DIR:-$ROOT_DIR/experiments/runs/test}"

export BIN="${BIN:-$ROOT_DIR/solvers/wgpu_solver_backend_cli}"
export IMAGE="${IMAGE:-$ROOT_DIR/apptainer/solver-runtime.sif}"

# Solver params
export BACKEND="${BACKEND:-auto}"
export MAX_ITERS="${MAX_ITERS:-2000}"
export REL_TOL="${REL_TOL:-1e-4}"
export ABS_TOL="${ABS_TOL:-1e-7}"

# Compare params
export X_REF="${X_REF:-$CASE_DIR/x_ref.bin}"
export CMP_REL_TOL="${CMP_REL_TOL:-1e-5}"
export CMP_ABS_TOL="${CMP_ABS_TOL:-1e-3}"
export TOP_K="${TOP_K:-10}"

# sbatch params
export SBATCH_TIME="${SBATCH_TIME:-00:10:00}"
export SBATCH_MEM="${SBATCH_MEM:-2G}"
export SBATCH_CPUS="${SBATCH_CPUS:-1}"

# Optional: set on GPU hosts later (example: "--nv")
export APPTAINER_GPU="${APPTAINER_GPU:-}"
