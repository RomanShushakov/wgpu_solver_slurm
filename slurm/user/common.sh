#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%(%F %T%z)T] %s\n' -1 "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_file() { [[ -f "$1" ]] || die "Missing file: $1"; }
require_exec() { [[ -x "$1" ]] || die "Not executable: $1"; }
require_dir()  { [[ -d "$1" ]] || die "Missing dir: $1"; }

ensure_env() {
  require_file "./slurm/env.sh"
  # shellcheck disable=SC1091
  source "./slurm/env.sh"

  : "${ROOT_DIR:?}"
  : "${CASE_DIR:?}"
  : "${OUT_DIR:?}"
  : "${BIN:?}"
  : "${IMAGE:?}"
  : "${PARTITION:?}"

  # Resolve ACCOUNT deterministically (do not rely on Slurm default resolution)
  # Priority:
  #   1) env.sh / caller provided ACCOUNT
  #   2) SlurmDB DefaultAccount for this UNIX user
  #   3) Fail loudly
  ACCOUNT="${ACCOUNT:-}"
  if [[ -z "${ACCOUNT}" ]]; then
    ACCOUNT="$(sacctmgr -n -P show user "${USER}" format=DefaultAccount 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "${ACCOUNT}" ]] || die "Could not resolve ACCOUNT for user=${USER}. Set ACCOUNT in slurm/env.sh or fix sacctmgr DefaultAccount."

  export ACCOUNT

  mkdir -p "${OUT_DIR}"
}

fix_unicode_dashes_here() {
  # Fix common copy/paste issue for all *.sh/*.sbatch in current dir
  perl -pi -e 's/[\x{2013}\x{2014}\x{2212}]/-/g' slurm/*.sh slurm/*.sbatch 2>/dev/null || true
}
