# wgpu_solver_slurm

![Rust](https://img.shields.io/badge/Rust-000000?logo=rust&logoColor=white)
![Slurm](https://img.shields.io/badge/Slurm-2B2B2B)
![Apptainer](https://img.shields.io/badge/Apptainer-663399)
![Linux](https://img.shields.io/badge/Linux-000000?logo=linux&logoColor=white)
![GPU](https://img.shields.io/badge/GPU-NVIDIA-76B900?logo=nvidia&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-demo%2Ftraining-informational)

Run GPU-enabled numerical workloads under **Slurm** using **Apptainer**, with **SlurmDBD/MariaDB** accounting and scripts to export **usage** and **billing** reports.

This repository is part of a longer chain of work around numerical methods, sparse linear algebra, iterative solvers, FEM experiments, and GPU execution.

Related repositories:

- https://github.com/RomanShushakov/extended_matrix
- https://github.com/RomanShushakov/colsol
- https://github.com/RomanShushakov/iterative_solvers
- https://github.com/RomanShushakov/finite_element_method
- https://github.com/RomanShushakov/fea_app
- https://github.com/RomanShushakov/wgpu_solver_backend

---

## Why this repo exists

Once a solver runs correctly on a real GPU, the next practical step is understanding how it behaves in a scheduler-driven environment:

- multiple users
- resource allocation and limits
- accounting and reporting
- containerized execution on GPU nodes

This repository explores those mechanics in a **small, explicit, and inspectable** setup.

The goal is not to build a full HPC platform, but to understand how the pieces fit together in practice.

---

## What is implemented

### 1) Single-node Slurm with accounting

The scripts bootstrap a minimal Slurm setup with:

- `slurmctld`, `slurmd`
- `munge`
- `slurmdbd` backed by MariaDB
- GPU accounting enabled via GRES / TRES (allocation-based)

This is sufficient to model real multi-user behavior on a single GPU node.

---

### 2) Apptainer runtime for GPU jobs

Workloads are executed via **Apptainer**, following common HPC practice:

- `apptainer exec --nv` for GPU visibility
- explicit bind mounts for user workspaces
- a portable solver runtime packaged as a `.sif`

This keeps execution reproducible while remaining close to production clusters.

---

### 3) Two-step job pipeline

A single “case run” consists of two Slurm jobs:

1. **PCG solver job**
   - runs on a GPU
   - writes solution output and solver metrics

2. **Compare job**
   - CPU-only
   - validates the result against a reference solution

The jobs are chained using Slurm dependencies (`afterok`).

---

### 4) GPU snapshots (optional)

A lightweight wrapper (`gpu_wrap`) can record start/end snapshots using `nvidia-smi`:

- GPU utilization
- memory usage
- power draw and temperature (when supported by hardware)

These snapshots are **diagnostic only** and intentionally kept simple.

They are not used as billing input.

---

### 5) Usage, summary, and billing export

Accounting data is exported in three stages:

- **Usage JSON** — per-job records
- **Summary JSON** — aggregated by user and account
- **Billing CSV** — seconds → hours → cost using configurable rates

This mirrors how many real clusters separate accounting, reporting, and pricing.

---

## Usage model (important)

Slurm GPU accounting is **allocation-based**, not utilization-based.

In this repository:

- `gpu_seconds` = `elapsed_time × allocated_gpu_count`
- CPU and billing seconds follow the same principle

GPU utilization snapshots are optional and:

- may be unavailable depending on GPU model / driver
- are not reliable enough for billing
- are treated strictly as diagnostics

This repo is structured around that reality rather than trying to infer “true” GPU usage.

---

## Branches

This repository intentionally maintains two branches.

### `master`

- intended for local experimentation and demos
- minimal assumptions
- focuses on Slurm mechanics, accounting, and reproducibility

### `cluster`

- used for real GPU cloud instances (e.g. Vultr)
- contains provider-specific adjustments:
  - GPU models and device layout
  - host setup constraints
- not merged into `master` intentionally

Clusters are not interchangeable in practice, and the branch split makes that explicit.

---

## Repository layout (high level)

```text
admin/              # MariaDB + slurmdbd helpers
apptainer/          # solver runtime image
scripts/            # provisioning, accounting, export
slurm/              # sbatch templates and helpers
solvers/            # solver binary (CLI)
experiments/        # small test cases
usage/              # generated usage/billing outputs
```

## Status

Feature-complete for **demo and training purposes**:

- jobs run on real GPUs under Slurm
- accounting is enabled and validated
- usage, summary, and billing exports are reproducible

Further work would mainly involve polish or scaling, not core design changes.

---

## License

MIT License.

This project is intended as a learning and experimentation platform, not a production-ready scheduler or billing system.

---
