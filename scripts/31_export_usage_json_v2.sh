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

ALL_USERS=0
FILTER_USER=""
FILTER_ACCOUNT=""
SINCE=""
UNTIL=""
OUT="usage_v2.json"

# parse args (add --all-users)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2;;
    --until) UNTIL="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --user) FILTER_USER="$2"; shift 2;;
    --account) FILTER_ACCOUNT="$2"; shift 2;;
    --all-users) ALL_USERS=1; shift;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

# auto-enable all-users if root and no explicit --user
if [[ "${EUID}" -eq 0 && -z "${FILTER_USER}" ]]; then
  ALL_USERS=1
fi

sacct_flags=(-n -P -X)   # parseable, no headers, no steps
if [[ "${ALL_USERS}" -eq 1 ]]; then
  sacct_flags+=(-a)
fi

time_flags=()
[[ -n "${SINCE}" ]] && time_flags+=(-S "${SINCE}")
[[ -n "${UNTIL}" ]] && time_flags+=(-E "${UNTIL}")

where_flags=()
[[ -n "${FILTER_USER}" ]] && where_flags+=(-u "${FILTER_USER}")
[[ -n "${FILTER_ACCOUNT}" ]] && where_flags+=(-A "${FILTER_ACCOUNT}")

FIELDS="JobIDRaw,User,Account,Partition,State,ElapsedRaw,AllocCPUS,ReqTRES,AllocTRES,Submit,Start,End,JobName"

RAW="$(sacct "${sacct_flags[@]}" "${time_flags[@]}" "${where_flags[@]}" -o "${FIELDS}")"

jq -Rn \
  --arg since "${SINCE}" \
  --arg until "${UNTIL}" \
  --arg user "${FILTER_USER}" \
  --arg account "${FILTER_ACCOUNT}" '
  def to_int:
    if . == null or . == "" then 0 else (try (.|tonumber) catch 0) end;

  def tres_int($key):
    ( . // "" )
    | ( capture("(^|,)" + $key + "=(?<n>[0-9]+)")? | .n ) // "0"
    | to_int;

  [ inputs
    | select(length > 0)
    | split("|") as $f
    | {
        job_id:      ($f[0] // ""),
        user:        ($f[1] // ""),
        account:     ($f[2] // ""),
        partition:   ($f[3] // ""),
        state:       ($f[4] // ""),
        elapsed_sec: (($f[5] // "") | to_int),
        alloc_cpus:  (($f[6] // "") | to_int),
        alloc_tres:  ($f[7] // "")
      }
    | .billing = (.alloc_tres | tres_int("billing") | if . == 0 then (.alloc_cpus) else . end)
    | .gpu_count = (.alloc_tres | tres_int("gres/gpu"))
    | .cpu_seconds = (.elapsed_sec * .alloc_cpus)
    | .billing_seconds = (.elapsed_sec * .billing)
    | .gpu_seconds = (.elapsed_sec * .gpu_count)
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
    }' <<< "${RAW}" > "${OUT}"

echo "OK: wrote ${OUT}"
jq '.meta, {jobs: (.jobs|length)}' "${OUT}"
