#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/32_summarize_usage_v2.sh --in usage/usage_v2.json --out usage/summary_v2.json

Creates a compact summary grouped by user and by account.
EOF
}

IN="usage/usage_v2.json"
OUT="usage/summary_v2.json"

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

jq '
  def n: if . == null then 0 else . end;

  def job_is_top_level:
    # ignore batch steps if you want; keep simple: ignore ".batch" and ".extern"
    (.job_id | tostring | test("\\.") ) | not;

  def norm_account:
    if (.account | tostring | length) == 0 then "unknown" else .account end;

  . as $root
  | ($root.jobs | map(select(job_is_top_level))) as $jobs
  | {
      meta: ($root.meta + { schema: "summary.v2", source_schema: ($root.meta.schema // "usage.v2") }),

      totals: {
        jobs: ($jobs | length),
        cpu_seconds:     ($jobs | map(.cpu_seconds     | n) | add),
        billing_seconds: ($jobs | map(.billing_seconds | n) | add),
        gpu_seconds:     ($jobs | map(.gpu_seconds     | n) | add),

        gpu_activity_avg_mean: (
          ($jobs | map(.gpu_activity_avg) | map(select(. != null))) as $a
          | if ($a|length)==0 then null else ($a|add)/($a|length) end
        ),

        gpu_mem_used_delta_sum: ($jobs | map(.gpu_mem_used_delta | n) | add)
      },

      by_user: (
        $jobs
        | group_by(.user)
        | map({
            user: (.[0].user),
            jobs: (length),
            cpu_seconds:     (map(.cpu_seconds     | n) | add),
            billing_seconds: (map(.billing_seconds | n) | add),
            gpu_seconds:     (map(.gpu_seconds     | n) | add),

            gpu_activity_avg_mean: (
              (map(.gpu_activity_avg) | map(select(. != null))) as $a
              | if ($a|length)==0 then null else ($a|add)/($a|length) end
            ),

            gpu_mem_used_delta_sum: (map(.gpu_mem_used_delta | n) | add),

            last_job_end: (map(.end) | max)
          })
        | sort_by(-.billing_seconds)
      ),

      by_account: (
        $jobs
        | map(.account = (norm_account))
        | group_by(.account)
        | map({
            account: (.[0].account),
            jobs: (length),
            users: (map(.user) | unique | length),
            cpu_seconds:     (map(.cpu_seconds     | n) | add),
            billing_seconds: (map(.billing_seconds | n) | add),
            gpu_seconds:     (map(.gpu_seconds     | n) | add),
            last_job_end: (map(.end) | max)
          })
        | sort_by(-.billing_seconds)
      )
    }
' "$IN" > "$OUT"

echo "OK: wrote $OUT"
jq '.meta, .totals, {by_user: (.by_user|length), by_account: (.by_account|length)}' "$OUT"
