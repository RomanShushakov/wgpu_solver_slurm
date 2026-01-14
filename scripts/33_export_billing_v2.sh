#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/33_export_billing_v2.sh --in usage/usage_v2.json --out usage/billing_v2.csv

Environment variables to price:
  PRICE_CPU_HR=0.00      (default)
  PRICE_GPU_HR=0.00      (default)
  PRICE_BILLING_HR=0.00  (default)

Notes:
- billing_seconds follows Slurm billing TRES if present (else alloc_cpus fallback in v2 exporter).
- gpu_seconds is allocated GPU seconds (Slurm), not utilization.
EOF
}

IN="usage/usage_v2.json"
OUT="usage/billing_v2.csv"

PRICE_CPU_HR="${PRICE_CPU_HR:-0.00}"
PRICE_GPU_HR="${PRICE_GPU_HR:-0.00}"
PRICE_BILLING_HR="${PRICE_BILLING_HR:-0.00}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
[[ -f "$IN" ]] || { echo "ERROR: missing input $IN"; exit 1; }
mkdir -p "$(dirname "$OUT")"

# Count jobs (quick sanity)
jobs_n="$(jq -r '(.jobs|length) // 0' "$IN")"
echo "DEBUG: .jobs length = ${jobs_n}" >&2

# Header
{
  echo "\"user\",\"account\",\"job_id\",\"cpu_sec\",\"gpu_sec\",\"billing_sec\",\"cpu_hours\",\"gpu_hours\",\"billing_hours\",\"cpu_cost\",\"gpu_cost\",\"billing_cost\",\"total_cost\""

  # Emit jobs as TSV: user account job_id cpu_sec gpu_sec billing_sec
  jq -r '
    .jobs[]?
    | [
        (.user // ""),
        (.account // ""),
        (.job_id // ""),
        ((.cpu_seconds // 0) | tostring),
        ((.gpu_seconds // 0) | tostring),
        ((.billing_seconds // 0) | tostring)
      ]
    | @tsv
  ' "$IN" \
  | awk -F'\t' \
      -v pcpu="${PRICE_CPU_HR}" \
      -v pgpu="${PRICE_GPU_HR}" \
      -v pbill="${PRICE_BILLING_HR}" '
      function q(s){ gsub(/"/,"\"\"",s); return "\"" s "\"" }
      function to_num(x){ if (x=="" || x=="null") return 0; return x+0 }
      BEGIN{
        # nothing
      }
      {
        user=$1; account=$2; job=$3;
        cpu_sec=to_num($4); gpu_sec=to_num($5); bill_sec=to_num($6);

        cpu_hr=cpu_sec/3600.0;
        gpu_hr=gpu_sec/3600.0;
        bill_hr=bill_sec/3600.0;

        cpu_cost=cpu_hr*(pcpu+0);
        gpu_cost=gpu_hr*(pgpu+0);
        bill_cost=bill_hr*(pbill+0);

        total=cpu_cost+gpu_cost+bill_cost;

        # Print with decent precision; adjust if you want more/less
        printf "%s,%s,%s,%.0f,%.0f,%.0f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f\n",
          q(user), q(account), q(job),
          cpu_sec, gpu_sec, bill_sec,
          cpu_hr, gpu_hr, bill_hr,
          cpu_cost, gpu_cost, bill_cost, total
      }
    '
} > "$OUT"

echo "OK: wrote $OUT"
echo "Pricing:"
echo "  PRICE_CPU_HR=$PRICE_CPU_HR"
echo "  PRICE_GPU_HR=$PRICE_GPU_HR"
echo "  PRICE_BILLING_HR=$PRICE_BILLING_HR"
echo
head -n 20 "$OUT"
