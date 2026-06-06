# lib/common.sh
# shellcheck shell=bash

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m' C_MAGENTA=$'\033[35m'
else
  # Used by sourced command modules; common.sh is also linted standalone.
  # shellcheck disable=SC2034
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_MAGENTA=""
fi

cfcn_step() { printf '%s==>%s %s\n' "$C_CYAN$C_BOLD" "$C_RESET" "$*" >&2; }
cfcn_info() { printf '    %s\n' "$*" >&2; }
cfcn_warn() { printf '%swarn:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
cfcn_err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
cfcn_ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
cfcn_tip()  { printf '%s→%s %s\n' "$C_MAGENTA" "$C_RESET" "$*" >&2; }

cfcn_require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    cfcn_err "required tool not found: $1"
    return 1
  fi
}

# Emit either a formatted table or raw JSON, depending on --json flag.
# Stdin: JSON array.
# Args: format-string and jq field expressions per column.
cfcn_render_table() {
  if [[ "${CFCN_JSON:-0}" == "1" ]]; then
    cat
    return 0
  fi
  local fmt="$1"; shift
  local jq_fields="$*"
  # Build a jq expression that prints @tsv of each row.
  # e.g. "[.name, .content, .proxied]"
  local jq_expr="[ $jq_fields ] | @tsv"
  local rows
  rows="$(jq -r ".[] | $jq_expr" 2>/dev/null)"
  [[ -z "$rows" ]] && return 0
  local cells=()
  local cell
  while IFS= read -r cell; do
    [[ -z "$cell" ]] && cell="-"
    cells+=("$cell")
  done < <(printf '%s\n' "$rows" | awk -F '\t' '{for (i=1; i<=NF; i++) print $i}')
  # shellcheck disable=SC2059
  printf "$fmt" "${cells[@]}"
}
