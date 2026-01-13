# scripts/31_export_usage_json_v2.sh  (UPDATED: attaches Option-A GPU snapshots if present)
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

# For gpu-<jobid>.csv produced by your sbatch scripts:
# Each line looks like:
# JOBID,START,timestamp,index,uuid,name,util.gpu,util.mem,mem.used,mem.total
# JOBID,END,  timestamp,index,uuid,name,util.gpu,util.mem,mem.used,mem.total
#
# Returns: util_gpu|mem_used|util_mem|mem_total  (numbers), or "|||"
read_gpu_snapshot_from_combined() {
  local file="$1"
  local phase="$2"   # START or END

  if [[ ! -f "$file" ]]; then
    echo "|||"
    return 0
  fi

  # Take the first GPU row for that phase (GPU index 0 usually)
  awk -F',' -v phase="$phase" '
    $2==phase {
      # trim spaces
      for (i=1; i<=NF; i++) gsub(/^ +| +$/, "", $i);

      util_gpu=$7;
      util_mem=$8;
      mem_used=$9;
      mem_total=$10;

      # Guard: only print if util_gpu looks numeric
      if (util_gpu ~ /^[0-9.]+$/) {
        print util_gpu "|" mem_used "|" util_mem "|" mem_total;
        exit
      }
    }
    END { if (NR==0) print "|||"; }
  ' "$file" 2>/dev/null || echo "|||"
}

# Augment each sacct line with:
# gpu_util_start|gpu_mem_used_start|gpu_mem_util_start|gpu_mem_total_start|gpu_util_end|gpu_mem_used_end|gpu_mem_util_end|gpu_mem_total_end
AUGMENTED="$(mktemp)"
trap 'rm -f "${AUGMENTED}"' EXIT

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  jobid="$(echo "${line}" | cut -d'|' -f1)"

  gfile="${GPU_LOG_DIR}/gpu-${jobid}.csv"

  start_vals="$(read_gpu_snapshot_from_combined "${gfile}" "START")"
  end_vals="$(read_gpu_snapshot_from_combined "${gfile}" "END")"

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

        # Option-A snapshots from gpu-<jobid>.csv (first GPU row), may be null if no logs
        # Parsed order: util_gpu | mem_used | util_mem | mem_total
        gpu_util_start:       (($f[13] // "") | to_num_or_null),
        gpu_mem_used_start:   (($f[14] // "") | to_num_or_null),
        gpu_mem_util_start:   (($f[15] // "") | to_num_or_null),
        gpu_mem_total_start:  (($f[16] // "") | to_num_or_null),

        gpu_util_end:         (($f[17] // "") | to_num_or_null),
        gpu_mem_used_end:     (($f[18] // "") | to_num_or_null),
        gpu_mem_util_end:     (($f[19] // "") | to_num_or_null),
        gpu_mem_total_end:    (($f[20] // "") | to_num_or_null)
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
        schema: "usage.v2",
        gpu_log_dir: $gpu_log_dir
      },
      jobs: $jobs
    }' < "${AUGMENTED}" > "${OUT}"

echo "OK: wrote ${OUT}"
jq '.meta, {jobs: (.jobs|length)}' "${OUT}"
