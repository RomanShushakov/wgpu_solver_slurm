#!/usr/bin/env bash
set -euo pipefail

IN="${IN:-usage_summary.json}"
OUT_MD="${OUT_MD:-usage_report.md}"
OUT_CSV="${OUT_CSV:-usage_report.csv}"

if [[ $# -ge 1 ]]; then IN="$1"; fi
if [[ $# -ge 2 ]]; then OUT_MD="$2"; fi
if [[ $# -ge 3 ]]; then OUT_CSV="$3"; fi

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
[[ -f "${IN}" ]] || { echo "Missing input: ${IN}"; exit 1; }

# CSV (user-level)
jq -r '
["user","jobs","elapsed_seconds","cpu_seconds","billing_seconds","gpu_seconds"],
(.by_user[] | [
  .user,
  (.jobs|tostring),
  (.elapsed_seconds|tostring),
  (.cpu_seconds|tostring),
  (.billing_seconds|tostring),
  (.gpu_seconds|tostring)
])
| @csv
' "${IN}" > "${OUT_CSV}"

# Markdown
{
  echo "# Slurm usage report"
  echo
  echo "- Generated: $(jq -r '.generated_at' "${IN}")"
  echo
  echo "## Totals"
  jq -r '.totals | "- jobs: \(.jobs)\n- elapsed_seconds: \(.elapsed_seconds)\n- cpu_seconds: \(.cpu_seconds)\n- billing_seconds: \(.billing_seconds)\n- gpu_seconds: \(.gpu_seconds)\n"' "${IN}"
  echo
  echo "## By user"
  echo
  echo "| user | jobs | elapsed_s | cpu_s | billing_s | gpu_s |"
  echo "|---|---:|---:|---:|---:|---:|"
  jq -r '.by_user[] | "| \(.user) | \(.jobs) | \(.elapsed_seconds) | \(.cpu_seconds) | \(.billing_seconds) | \(.gpu_seconds) |"' "${IN}"
  echo
  echo "CSV: ${OUT_CSV}"
} > "${OUT_MD}"

echo "OK: wrote ${OUT_MD}"
echo "OK: wrote ${OUT_CSV}"
