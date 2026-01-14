# wgpu_solver_slurm

![Slurm](https://img.shields.io/badge/Slurm-2B2B2B)
![Apptainer](https://img.shields.io/badge/Apptainer-663399)
![Linux](https://img.shields.io/badge/Linux-000000?logo=linux&logoColor=white)
![GPU](https://img.shields.io/badge/GPU-NVIDIA-76B900?logo=nvidia&logoColor=white)
![Status](https://img.shields.io/badge/status-learning%20%2F%20building-lightgrey)

Run GPU-based numerical workloads under **Slurm** using **Apptainer**, with a focus on
**reproducible execution, accounting, and reporting**, rather than peak performance.

This repository is a continuation of my work on GPU-accelerated iterative solvers
(`wgpu_solver_backend`) and explores how such workloads behave when placed into a
scheduler-driven environment similar to real HPC systems.

---

## Why this repository exists

Most examples of GPU compute focus on:

- single-node execution
- ad-hoc Docker containers
- manual GPU access

This repository explores a different question:

> _What does it take to run a custom GPU compute backend as a scheduled job,
> with resource accounting, isolation, and reproducibility?_

To answer that, this repo demonstrates:

- a minimal **Slurm** setup with accounting enabled
- **Apptainer** containers suitable for GPU workloads
- batch job submission for GPU compute
- extraction of **usage and billing-style metrics** from Slurm

The goal is **understanding the system mechanics**, not building a production cluster.

---

## What this repository is

- A small, self-contained **Slurm + GPU sandbox**
- A way to run `wgpu_solver_backend` as a **scheduled GPU job**
- A testbed for:
  - GPU allocation vs. utilization
  - Slurm accounting behavior
  - containerized GPU execution
  - job-level metrics export (CSV / JSON)

---

## What this repository is not

- Not a full HPC cluster
- Not a production-grade deployment
- Not optimized for performance or scale
- Not a replacement for real cluster tooling

Everything here is intentionally minimal and explicit.

---

## High-level architecture

- **Slurm**
  - Controller + compute node
  - Accounting enabled via `slurmdbd` and MariaDB
- **Apptainer**
  - GPU-enabled runtime image
  - Runs the solver backend without Docker
- **wgpu_solver_backend**
  - Invoked as a batch job
  - Reads binary inputs
  - Writes results and metrics

Slurm is responsible for **resource allocation and accounting**.  
The solver is responsible for **numerical work only**.

---

## Repository contents

- `slurm/` – Slurm configuration files and init scripts
- `apptainer/` – Definition files and runtime setup
- `jobs/` – Example `sbatch` scripts for GPU jobs
- `scripts/` – Helpers for exporting usage / billing data
- `docs/` – Notes and experiments during setup

---

## Example workflow (conceptual)

1. Build Apptainer image with GPU support
2. Start Slurm controller + compute node
3. Submit a GPU job via `sbatch`
4. Run `wgpu_solver_backend` inside Apptainer
5. Export:
   - job runtime
   - allocated resources
   - GPU seconds (as Slurm reports them)
6. Inspect results and accounting data

---

## Notes on GPU accounting

An important observation confirmed by this setup:

- **Slurm accounts GPU usage by allocation, not by real utilization**
- A job that reserves a GPU but does little work still consumes GPU time
- Fine-grained GPU utilization requires external tooling (outside Slurm)

This repo intentionally exposes that behavior rather than hiding it.

---

## Related repositories (same project chain)

- [`wgpu_solver_backend`](https://github.com/RomanShushakov/wgpu_solver_backend) — GPU compute backend (PCG + Block-Jacobi, wgpu-based)
- [`iterative_solvers`](https://github.com/RomanShushakov/iterative_solvers) — CPU iterative methods (CG / PCG)
- [`colsol`](https://github.com/RomanShushakov/colsol) — direct-solver experiments (LDLᵀ / column-style elimination)
- [`extended_matrix`](https://github.com/RomanShushakov/extended_matrix) — Sparse matrix structures and utilities
- [`finite_element_method`](https://github.com/RomanShushakov/finite_element_method) / [`fea_app`](https://github.com/RomanShushakov/fea_app) – FEM pipeline and problem generation

This repository focuses purely on **execution and scheduling**.

---

## Status

- End-to-end workflow working
- GPU jobs run correctly under Slurm
- Accounting and metrics export validated
- Intended as a learning and demonstration environment

Further extensions (multi-node, MPI, scaling) are intentionally out of scope.

---

## License

MIT License.

This project is intended as a learning and experimentation platform, not a production-ready scheduler or billing system.

---
