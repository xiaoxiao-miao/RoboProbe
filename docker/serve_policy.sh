#!/usr/bin/env bash
# Default usage, from the RoboProbe checkout (planner key in .secrets/):
#   terminal 1:  bash docker/serve_policy.sh
#   terminal 2:  bash docker/run_client.sh --task stack_bowls --planner deepseek
#   afterwards:  bash docker/view_trace.sh --task stack_bowls
#
# Start the host-side policy server that the RoboDojo client container connects to.
#
#   bash docker/serve_policy.sh [--policy NAME] [--port 6070] [--host 127.0.0.1]
#
# At L3 Inspect this server is a stub: the planner loop runs in the client, and
# the server only has to accept the connection and answer `reset`. It holds no
# task state, so one server serves any number of client runs, task after task,
# until it is stopped with Ctrl-C. It needs no planner key and no GPU.
#
# Runs on <checkout>/.venv (`python -m venv .venv && .venv/bin/pip install -e .`).
set -euo pipefail

# Resolved through symlinks, so a link to this script from another checkout
# still finds this one.
XPL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORKSPACE_ROOT="$(cd "${XPL_ROOT}/.." && pwd)"
# shellcheck source=lib.sh
source "${XPL_ROOT}/docker/lib.sh"

policy="RoboDojo_Agent_L3_Inspect_EEF"
port="6070"
host="127.0.0.1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy) policy="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "[serve] unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "${policy}" in
  RoboDojo_Agent_L3_Inspect|RoboDojo_Agent_L3_Inspect_EEF) ;;
  *) echo "[serve] only the L3 Inspect harnesses run this way, got: ${policy}" >&2; exit 2 ;;
esac
if [[ ! -x "${XPL_ROOT}/.venv/bin/python" ]]; then
  echo "[serve] ${XPL_ROOT}/.venv is missing; build it with:" >&2
  echo "        cd ${XPL_ROOT} && python3 -m venv .venv && .venv/bin/pip install -e ." >&2
  exit 1
fi
# The server script reads action dimensions from <workspace>/XPolicyLab/..., i.e.
# it expects this checkout to be reachable under the import name.
if [[ ! -f "${WORKSPACE_ROOT}/XPolicyLab/utils/robot/_robot_info.json" ]]; then
  echo "[serve] ${WORKSPACE_ROOT}/XPolicyLab does not resolve to this checkout; create it with:" >&2
  echo "        ln -s $(basename "${XPL_ROOT}") ${WORKSPACE_ROOT}/XPolicyLab" >&2
  exit 1
fi
if ss -ltnH 2>/dev/null | awk -v p="${port}" '$4 ~ "[:.]"p"$" {f=1} END {exit !f}'; then
  echo "[serve] port ${port} is already in use; stop that process or pass --port" >&2
  exit 1
fi

export PYTHON="${XPL_ROOT}/.venv/bin/python"
# bench, task, ckpt and seed are labels the stub never reads, which is what lets
# one server outlive a single task.
cmd=(
  bash "${XPL_ROOT}/policy/${policy}/setup_eval_policy_server.sh"
  RoboDojo external external arx_x5 joint 0 "" uv "${port}" "${host}"
)
echo "[serve] PYTHON=${PYTHON}"
show_command serve "${cmd[@]}"
exec "${cmd[@]}"
