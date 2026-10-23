# Helpers sourced by the docker/*.sh entry points.

# The RoboDojo checkout: ROBODOJO_ROOT when set, else the documented sibling
# RoboDojo-eval, else a sibling named plainly RoboDojo.
resolve_robodojo_root() {
  local workspace=$1 candidate
  if [[ -n "${ROBODOJO_ROOT:-}" ]]; then
    printf '%s\n' "${ROBODOJO_ROOT}"
    return
  fi
  for candidate in "${workspace}/RoboDojo-eval" "${workspace}/RoboDojo"; do
    if [[ -f "${candidate}/scripts/robodojo.sh" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  printf '%s\n' "${workspace}/RoboDojo-eval"
}

# Print a command exactly as it is about to run, shell-quoted so it can be
# copied back into a terminal, with each option on its own line. Arguments that
# are not options but still start a section (an image name, the command run in
# a container) can be listed in SHOW_BREAK_BEFORE to get a line of their own.
# SHOW_SUFFIX is appended verbatim, for a redirection that is not an argument.
SHOW_BREAK_BEFORE=()
SHOW_SUFFIX=""
show_command() {
  local tag=$1
  shift
  local out="" arg word brk
  for arg in "$@"; do
    brk=""
    if [[ -n "${out}" && "${arg}" == -* ]]; then
      brk=1
    elif [[ -n "${out}" ]]; then
      for word in "${SHOW_BREAK_BEFORE[@]}"; do
        if [[ "${arg}" == "${word}" ]]; then
          brk=1
        fi
      done
    fi
    if [[ -n "${brk}" ]]; then
      out+=$' \\\n    '
    elif [[ -n "${out}" ]]; then
      out+=" "
    fi
    out+="$(printf '%q' "${arg}")"
  done
  printf '[%s] command:\n  %s%s\n' "${tag}" "${out}" "${SHOW_SUFFIX:+ ${SHOW_SUFFIX}}"
}
