#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/31_export_usage_json_v2.sh --since "<time>" [--until "<time>"] [--user <u>] [--account <a>] [--out <file>]

Examples:
  bash scripts/31_export_usage_json_v2.sh --since "2026-01-07T00:00:00" --until "2026-01-08T00:00:00" --out usage.json
  bash scripts/31_export_usage_json_v2.sh --since "2026-01-01" --user user1 --out user1.json
EOF
}

SINCE=""
UNTIL=""
FILTER_USER=""
FILTER_ACCOUNT=""
OUT="usage_v2.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)   SINCE="${2:-}"; shift 2;;
    --until)   UNTIL="${2:-}"; shift 2;;
    --user)    FILTER_USER="${2:-}"; shift 2;;
    --account) FILTER_ACCOUNT="${2:-}"; shift 2;;
    --out)     OUT="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

[[ -n "${SINCE}" ]] || { echo "ERROR: --since is required"; usage; exit 2; }

command -v sacct >/dev/null 2>&1 || { echo "ERROR: sacct not found (install slurm-client)"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (sudo apt-get install -y jq)"; exit 2; }

FIELDS="JobIDRaw,User,Account,Partition,State,Submit,Start,End,ElapsedRaw,AllocCPUS,ReqTRES,AllocTRES"

SACCT_ARGS=(-n -P -X -o "${FIELDS}" -S "${SINCE}")
[[ -n "${UNTIL}" ]] && SACCT_ARGS+=(-E "${UNTIL}")
[[ -n "${FILTER_USER}" ]] && SACCT_ARGS+=(-u "${FILTER_USER}")
[[ -n "${FILTER_ACCOUNT}" ]] && SACCT_ARGS+=(-A "${FILTER_ACCOUNT}")

RAW="$(sacct "${SACCT_ARGS[@]}" || true)"

jq -Rn \
  --arg since "${SINCE}" \
  --arg until "${UNTIL}" \
  --arg user "${FILTER_USER}" \
  --arg account "${FILTER_ACCOUNT}" \
  '
  def to_int:
    if . == null or . == "" then 0 else (try (.|tonumber) catch 0) end;

  [ inputs
    | select(length > 0)
    | split("|") as $f
    | {
        job_id:      ($f[0] // ""),
        user:        ($f[1] // ""),
        account:     ($f[2] // ""),
        partition:   ($f[3] // ""),
        state:       ($f[4] // ""),
        submit_time: ($f[5] // ""),
        start_time:  ($f[6] // ""),
        end_time:    ($f[7] // ""),
        elapsed_sec: (($f[8] // "") | to_int),
        alloc_cpus:  (($f[9] // "") | to_int),
        req_tres:    ($f[10] // ""),
        alloc_tres:  ($f[11] // "")
      }
  ] as $jobs
  | {
      meta: {
        since: $since,
        until: ($until | if . == "" then null else . end),
        filter_user: ($user | if . == "" then null else . end),
        filter_account: ($account | if . == "" then null else . end),
        generated_at: (now | todateiso8601),
        source: "sacct",
        schema: "usage.v2"
      },
      jobs: $jobs
    }
  ' <<< "${RAW}" > "${OUT}"

echo "OK: wrote ${OUT}"
jq '.meta, {jobs: (.jobs|length)}' "${OUT}"
