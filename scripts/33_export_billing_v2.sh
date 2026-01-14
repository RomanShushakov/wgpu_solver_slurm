#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/33_export_billing_v2.sh --in usage/usage_v2.json --out usage/billing_v2.csv

Environment variables to price:
  PRICE_CPU_HR=0.00   (default)
  PRICE_GPU_HR=0.00   (default)
  PRICE_BILLING_HR=0.00 (default)

Notes:
- "billing_seconds" follows Slurm billing TRES if present (else alloc_cpus fallback in your v2 exporter).
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

# We write CSV with header.
jq -r \
  --arg price_cpu_hr "$PRICE_CPU_HR" \
  --arg price_gpu_hr "$PRICE_GPU_HR" \
  --arg price_billing_hr "$PRICE_BILLING_HR" '
  def n: if . == null then 0 else . end;
  def to_num: try tonumber catch 0;

  def job_is_top_level:
    (.job_id | tostring | test("\\.") ) | not;

  def norm_account:
    if (.account | tostring | length) == 0 then "unknown" else .account end;

  def sec_to_hr: (. / 3600);

  def cost($sec; $price_hr):
    (sec_to_hr($sec) * ($price_hr|to_num));

  (["account","user","jobs","cpu_hours","gpu_hours","billing_hours","cpu_cost","gpu_cost","billing_cost","total_cost"] | @csv),
  (
    .jobs
    | map(select(job_is_top_level))
    | map(.account = norm_account)
    | group_by(.account, .user)
    | map({
        account: (.[0].account),
        user: (.[0].user),
        jobs: (length),

        cpu_sec:     (map(.cpu_seconds     | n) | add),
        gpu_sec:     (map(.gpu_seconds     | n) | add),
        billing_sec: (map(.billing_seconds | n) | add)
      })
    | map(. + {
        cpu_hours:     (sec_to_hr(.cpu_sec)),
        gpu_hours:     (sec_to_hr(.gpu_sec)),
        billing_hours: (sec_to_hr(.billing_sec)),

        cpu_cost:     (cost(.cpu_sec;     $price_cpu_hr)),
        gpu_cost:     (cost(.gpu_sec;     $price_gpu_hr)),
        billing_cost: (cost(.billing_sec; $price_billing_hr))
      })
    | map(. + { total_cost: (.cpu_cost + .gpu_cost + .billing_cost) })
    | sort_by(-.total_cost)
    | .[]
    | [ .account, .user, .jobs,
        (.cpu_hours|tostring), (.gpu_hours|tostring), (.billing_hours|tostring),
        (.cpu_cost|tostring), (.gpu_cost|tostring), (.billing_cost|tostring),
        (.total_cost|tostring)
      ]
    | @csv
  )
' "$IN" > "$OUT"

echo "OK: wrote $OUT"
echo "Pricing:"
echo "  PRICE_CPU_HR=$PRICE_CPU_HR"
echo "  PRICE_GPU_HR=$PRICE_GPU_HR"
echo "  PRICE_BILLING_HR=$PRICE_BILLING_HR"
echo
head -n 20 "$OUT"
