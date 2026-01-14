#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/31_export_usage_json_v2.sh --since "<time>" [--until "<time>"] [--user <u>] [--account <a>] [--out <file>] [--all-users]

Examples:
  sudo bash scripts/31_export_usage_json_v2.sh --all-users --since "now-24hours" --out usage/usage_v2.json
  bash scripts/31_export_usage_json_v2.sh --since "2026-01-01" --user user1 --out user1.json
EOF
}

ALL_USERS=0
FILTER_USER=""
FILTER_ACCOUNT=""
SINCE=""
UNTIL=""
OUT="usage_v2.json"

GPU_LOG_DIR="${GPU_LOG_DIR:-/var/log/slurm/gpu-metrics}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2;;
    --until) UNTIL="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --user) FILTER_USER="$2"; shift 2;;
    --account) FILTER_ACCOUNT="$2"; shift 2;;
    --all-users) ALL_USERS=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
command -v sacct >/dev/null 2>&1 || { echo "sacct is required"; exit 1; }

# auto-enable all-users if root and no explicit --user
if [[ "${EUID}" -eq 0 && -z "${FILTER_USER}" ]]; then
  ALL_USERS=1
fi

sacct_flags=(-n -P -X)
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

# Read first GPU data row from gpu_wrap output:
# Header: ts,host,job_id,job_user,index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,temperature.gpu
# Return: util_gpu|util_mem|mem_used|mem_total|power|temp  or "|||||"
read_gpu_snapshot_wrap() {
  local file="$1"
  [[ -f "$file" ]] || { echo "|||||"; return 0; }

  awk -F',' '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NR==2 {
      for (i=1; i<=NF; i++) $i=trim($i);

      util_gpu=$8
      util_mem=$9
      mem_used=$10
      mem_total=$11
      power=$12
      temp=$13

      # Normalize "[N/A]" -> empty
      if (util_gpu=="[N/A]") util_gpu=""
      if (util_mem=="[N/A]") util_mem=""
      if (mem_used=="[N/A]") mem_used=""
      if (mem_total=="[N/A]") mem_total=""
      if (power=="[N/A]") power=""
      if (temp=="[N/A]") temp=""

      print util_gpu "|" util_mem "|" mem_used "|" mem_total "|" power "|" temp
      exit
    }
    END {
      # if file exists but has no data rows
      if (NR < 2) print "|||||"
    }
  ' "$file" 2>/dev/null || echo "|||||"
}

AUGMENTED="$(mktemp)"
trap 'rm -f "${AUGMENTED}"' EXIT

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  jobid="$(echo "${line}" | cut -d'|' -f1)"

  sfile="${GPU_LOG_DIR}/job-${jobid}-start.csv"
  efile="${GPU_LOG_DIR}/job-${jobid}-end.csv"

  start_vals="$(read_gpu_snapshot_wrap "${sfile}")"
  end_vals="$(read_gpu_snapshot_wrap "${efile}")"

  echo "${line}|${start_vals}|${end_vals}" >> "${AUGMENTED}"
done <<< "${RAW}"

jq -Rn \
  --arg since "${SINCE}" \
  --arg until "${UNTIL}" \
  --arg user "${FILTER_USER}" \
  --arg account "${FILTER_ACCOUNT}" \
  --arg gpu_log_dir "${GPU_LOG_DIR}" '
  def to_int:
    if . == null or . == "" then 0 else (try (.|tonumber) catch 0) end;

  def to_num_or_null:
    if . == null or . == "" then null else (try (.|tonumber) catch null) end;

  def tres_int($key):
    ( . // "" )
    | ( capture("(^|,)" + $key + "=(?<n>[0-9]+)")? | .n ) // "0"
    | to_int;

  def num0: (. // 0);

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
        req_tres:    ($f[7] // ""),
        alloc_tres:  ($f[8] // ""),
        submit:      ($f[9] // ""),
        start:       ($f[10] // ""),
        end:         ($f[11] // ""),
        job_name:    ($f[12] // ""),

        # gpu_wrap snapshots (first GPU row)
        # order: util_gpu | util_mem | mem_used | mem_total | power | temp
        gpu_util_start:      (($f[13] // "") | to_num_or_null),
        gpu_mem_util_start:  (($f[14] // "") | to_num_or_null),
        gpu_mem_used_start:  (($f[15] // "") | to_num_or_null),
        gpu_mem_total_start: (($f[16] // "") | to_num_or_null),
        gpu_power_start:     (($f[17] // "") | to_num_or_null),
        gpu_temp_start:      (($f[18] // "") | to_num_or_null),

        gpu_util_end:        (($f[19] // "") | to_num_or_null),
        gpu_mem_util_end:    (($f[20] // "") | to_num_or_null),
        gpu_mem_used_end:    (($f[21] // "") | to_num_or_null),
        gpu_mem_total_end:   (($f[22] // "") | to_num_or_null),
        gpu_power_end:       (($f[23] // "") | to_num_or_null),
        gpu_temp_end:        (($f[24] // "") | to_num_or_null)
      }
    | .billing = (.alloc_tres | tres_int("billing") | if . == 0 then (.alloc_cpus) else . end)
    | .gpu_count = (.alloc_tres | tres_int("gres/gpu"))
    | .cpu_seconds = (.elapsed_sec * .alloc_cpus)
    | .billing_seconds = (.elapsed_sec * .billing)
    | .gpu_seconds = (.elapsed_sec * .gpu_count)

    # "real-ish" activity from two-point snapshots (null-safe)
    | .gpu_activity_avg = ((.gpu_util_start|num0) + (.gpu_util_end|num0)) / 2
    | .gpu_mem_used_delta = ((.gpu_mem_used_end|num0) - (.gpu_mem_used_start|num0))
  ] as $jobs
  | {
      meta: {
        since: $since,
        until: ($until | if . == "" then null else . end),
        filter_user: ($user | if . == "" then null else . end),
        filter_account: ($account | if . == "" then null else . end),
        generated_at: (now | todateiso8601),
        source: "sacct + gpu_wrap snapshots",
        schema: "usage.v2",
        gpu_log_dir: $gpu_log_dir
      },
      jobs: $jobs
    }' < "${AUGMENTED}" > "${OUT}"

echo "OK: wrote ${OUT}"
jq '.meta, {jobs: (.jobs|length)}' "${OUT}"
