# scripts/32_summarize_usage.sh  (UPDATED: adds gpu snapshot stats)
#!/usr/bin/env bash
set -euo pipefail

IN="${IN:-usage_v2.json}"
OUT="${OUT:-usage_summary.json}"

if [[ $# -ge 1 ]]; then IN="$1"; fi
if [[ $# -ge 2 ]]; then OUT="$2"; fi

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
[[ -f "${IN}" ]] || { echo "Missing input: ${IN}"; exit 1; }

jq '
def nz: . // 0;
def asnum: (tonumber? // 0);

def jobs:
  if type=="object" and has("jobs") then .jobs
  elif type=="array" then .
  else [] end;

def avg_or_null(arr):
  if (arr|length) == 0 then null else ((arr|add) / (arr|length)) end;

def max_or_null(arr):
  if (arr|length) == 0 then null else (arr|max) end;

{
  generated_at: (now | todateiso8601),
  source: $IN,
  totals: (
    jobs
    | reduce .[] as $j (
        {
          jobs: 0,
          elapsed_seconds: 0,
          cpu_seconds: 0,
          billing_seconds: 0,
          gpu_seconds: 0
        };
        .jobs += 1
        | .elapsed_seconds += (($j.elapsed_sec|nz|asnum))
        | .cpu_seconds += (($j.cpu_seconds|nz|asnum))
        | .billing_seconds += (($j.billing_seconds|nz|asnum))
        | .gpu_seconds += (($j.gpu_seconds|nz|asnum))
      )
  ),
  by_user: (
    jobs
    | group_by(.user)
    | map(
      . as $group
      | ($group | map(select(.gpu_util_end != null) | .gpu_util_end)) as $util_end
      | ($group | map(select(.gpu_mem_used_end != null) | .gpu_mem_used_end)) as $mem_end
      | {
          user: (.[0].user),
          jobs: length,
          elapsed_seconds: (map(.elapsed_sec|nz|asnum) | add),
          cpu_seconds: (map(.cpu_seconds|nz|asnum) | add),
          billing_seconds: (map(.billing_seconds|nz|asnum) | add),
          gpu_seconds: (map(.gpu_seconds|nz|asnum) | add),

          gpu_util_end_avg: (avg_or_null($util_end)),
          gpu_util_end_max: (max_or_null($util_end)),
          gpu_mem_used_end_avg: (avg_or_null($mem_end)),
          gpu_mem_used_end_max: (max_or_null($mem_end)),

          accounts: (
            group_by(.account)
            | map(
              . as $ag
              | ($ag | map(select(.gpu_util_end != null) | .gpu_util_end)) as $a_util_end
              | ($ag | map(select(.gpu_mem_used_end != null) | .gpu_mem_used_end)) as $a_mem_end
              | {
                  account: (.[0].account),
                  jobs: length,
                  elapsed_seconds: (map(.elapsed_sec|nz|asnum) | add),
                  cpu_seconds: (map(.cpu_seconds|nz|asnum) | add),
                  billing_seconds: (map(.billing_seconds|nz|asnum) | add),
                  gpu_seconds: (map(.gpu_seconds|nz|asnum) | add),

                  gpu_util_end_avg: (avg_or_null($a_util_end)),
                  gpu_util_end_max: (max_or_null($a_util_end)),
                  gpu_mem_used_end_avg: (avg_or_null($a_mem_end)),
                  gpu_mem_used_end_max: (max_or_null($a_mem_end))
                }
            )
          )
        }
    )
  )
}
' --arg IN "${IN}" "${IN}" > "${OUT}"

echo "OK: wrote ${OUT}"
