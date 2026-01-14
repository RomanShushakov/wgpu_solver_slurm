#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOM'
Usage:
  bash scripts/33_export_billing_v2.sh --in usage/usage_v2.json --out usage/billing_v2.csv

Environment variables to price:
  PRICE_CPU_HR=0.00      (default)
  PRICE_GPU_HR=0.00      (default)
  PRICE_BILLING_HR=0.00  (default)

Notes:
- billing_seconds follows Slurm billing TRES if present (else alloc_cpus fallback in v2 exporter).
- gpu_seconds is allocated GPU seconds (Slurm), not utilization.
EOM
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

# Debug: count how many job objects we can see in this input
job_count="$(jq -r '
  def jobs_stream:
    def walk($x):
      if ($x|type) == "object" and (($x.jobs? | type?) == "array") then
        $x.jobs[] | walk(.)
      elif ($x|type) == "array" then
        $x[] | walk(.)
      elif ($x|type) == "object" then
        $x
      else
        empty
      end;
    walk(.)
    | select(type=="object")
    | select(has("job_id") and has("user"));

  [jobs_stream | .job_id] | length
' "$IN")"
echo "DEBUG: found ${job_count} job objects in ${IN}" >&2

jq -r \
  --arg price_cpu_hr     "${PRICE_CPU_HR:-0}" \
  --arg price_gpu_hr     "${PRICE_GPU_HR:-0}" \
  --arg price_billing_hr "${PRICE_BILLING_HR:-0}" '
  def to_num:
    if . == null or . == "" then 0 else (try tonumber catch 0) end;

  def sec_to_hr($sec): (($sec | to_num) / 3600);
  def cost($sec; $price_hr): (sec_to_hr($sec) * ($price_hr | to_num));

  def jobs_stream:
    def walk($x):
      if ($x|type) == "object" and (($x.jobs? | type?) == "array") then
        $x.jobs[] | walk(.)
      elif ($x|type) == "array" then
        $x[] | walk(.)
      elif ($x|type) == "object" then
        $x
      else
        empty
      end;
    walk(.)
    | select(type=="object")
    | select(has("job_id") and has("user"));

  [
    "user","account","job_id",
    "cpu_sec","gpu_sec","billing_sec",
    "cpu_hours","gpu_hours","billing_hours",
    "cpu_cost","gpu_cost","billing_cost",
    "total_cost"
  ] | @csv,

  (jobs_stream
    | . as $j
    | {
        user:        ($j.user // ""),
        account:     ($j.account // ""),
        job_id:      ($j.job_id // ""),
        cpu_sec:     ($j.cpu_seconds // 0),
        gpu_sec:     ($j.gpu_seconds // 0),
        billing_sec: ($j.billing_seconds // 0)
      }
    | .cpu_hours     = sec_to_hr(.cpu_sec)
    | .gpu_hours     = sec_to_hr(.gpu_sec)
    | .billing_hours = sec_to_hr(.billing_sec)

    | .cpu_cost     = cost(.cpu_sec; $price_cpu_hr)
    | .gpu_cost     = cost(.gpu_sec; $price_gpu_hr)
    | .billing_cost = cost(.billing_sec; $price_billing_hr)
    | .total_cost   = (.cpu_cost + .gpu_cost + .billing_cost)

    | [
        .user,
        .account,
        .job_id,
        (.cpu_sec|to_num),
        (.gpu_sec|to_num),
        (.billing_sec|to_num),
        (.cpu_hours),
        (.gpu_hours),
        (.billing_hours),
        (.cpu_cost),
        (.gpu_cost),
        (.billing_cost),
        (.total_cost)
      ]
    # IMPORTANT: stringify everything before @csv
    | map(tostring)
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
