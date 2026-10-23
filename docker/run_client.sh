#!/usr/bin/env bash
# Default usage, from the RoboProbe checkout (planner key in .secrets/):
#   terminal 1:  bash docker/serve_policy.sh
#   terminal 2:  bash docker/run_client.sh --task stack_bowls --planner deepseek
#   afterwards:  bash docker/view_trace.sh --task stack_bowls
#
# Run an L3 Inspect evaluation in the RoboDojo client container.
#
#   bash docker/run_client.sh --task stack_bowls --planner deepseek [options] [-- robodojo.sh client args]
#
# Start docker/serve_policy.sh first; this connects to it. The planner loop and
# every provider call run in this container, so planner settings and keys are
# passed here, not to the server.
#
# Options:
#   --task NAME        RoboDojo task (required)
#   --planner NAME     astra | gpt55 | kimi | deepseek (default: $L3_INSPECT_PLANNER, else astra)
#   --policy NAME      RoboDojo_Agent_L3_Inspect_EEF (default) or RoboDojo_Agent_L3_Inspect
#   --port PORT        policy server port (default: 6070)
#   --eval-num N       episodes to run (default: 1)
#   --seed N           eval seed (default: 0)
#   --env-gpu ID       simulator GPU (default: 0)
#   --ckpt LABEL       result-path label (default: the planner name)
#   --run-id ID        names the result and trace directories (default: a timestamp)
#
# Environment:
#   ROBODOJO_ROOT      RoboDojo checkout on the host
#                      (default: <workspace>/RoboDojo-eval, else <workspace>/RoboDojo)
#   CLIENT_IMAGE       image from build_client_image.sh (default: robodojo-roboprobe:cuda12.8)
#   TRACE_ROOT         host directory for transcripts (default: <checkout>/runs/l3_traces)
#   L3_INSPECT_BASE_URL
#                      provider host; defaults only for kimi and deepseek, whose
#                      hosts are public and fixed
#   <planner key>      DEEPSEEK_API_KEY / MOONSHOT_API_KEY / OPENAI_API_KEY[_BACKUP],
#                      or the file .secrets/<variable name in lower case>
#   L3_INSPECT_*       every one set on the host is forwarded into the container
set -euo pipefail

# Resolved through symlinks, so a link to this script from another checkout
# still finds this one.
XPL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORKSPACE_ROOT="$(cd "${XPL_ROOT}/.." && pwd)"
# shellcheck source=lib.sh
source "${XPL_ROOT}/docker/lib.sh"
ROBODOJO_ROOT="$(resolve_robodojo_root "${WORKSPACE_ROOT}")"
CLIENT_IMAGE="${CLIENT_IMAGE:-robodojo-roboprobe:cuda12.8}"
TRACE_ROOT="${TRACE_ROOT:-${XPL_ROOT}/runs/l3_traces}"
SECRETS_DIR="${SECRETS_DIR:-${XPL_ROOT}/.secrets}"
CONTAINER_ROOT="/workspace/RoboDojo"

task=""
planner="${L3_INSPECT_PLANNER:-astra}"
planner_named="${L3_INSPECT_PLANNER:+1}"
policy="RoboDojo_Agent_L3_Inspect_EEF"
port="6070"
eval_num="1"
seed="0"
env_gpu="0"
ckpt=""
run_id=""
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task="$2"; shift 2 ;;
    --planner) planner="$2"; planner_named=1; shift 2 ;;
    --policy) policy="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --eval-num) eval_num="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --env-gpu) env_gpu="$2"; shift 2 ;;
    --ckpt) ckpt="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --) shift; extra=("$@"); break ;;
    -h|--help) awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "[client] unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${task}" ]] || { echo "[client] --task is required" >&2; exit 2; }
case "${policy}" in
  RoboDojo_Agent_L3_Inspect|RoboDojo_Agent_L3_Inspect_EEF) ;;
  *) echo "[client] only the L3 Inspect harnesses run this way, got: ${policy}" >&2; exit 2 ;;
esac
if [[ ! -f "${ROBODOJO_ROOT}/scripts/robodojo.sh" ]]; then
  echo "[client] ${ROBODOJO_ROOT} is not a RoboDojo checkout; export ROBODOJO_ROOT" >&2
  exit 1
fi
if [[ ! -f "${ROBODOJO_ROOT}/task/RoboDojo/tasks/${task}.py" ]]; then
  echo "[client] no such RoboDojo task: ${task}" >&2
  exit 2
fi
if ! docker image inspect "${CLIENT_IMAGE}" >/dev/null 2>&1; then
  echo "[client] image ${CLIENT_IMAGE} not found; run: bash ${XPL_ROOT}/docker/build_client_image.sh" >&2
  exit 1
fi
if ! ss -ltnH 2>/dev/null | awk -v p="${port}" '$4 ~ "[:.]"p"$" {f=1} END {exit !f}'; then
  echo "[client] nothing listens on port ${port}; start: bash ${XPL_ROOT}/docker/serve_policy.sh --port ${port}" >&2
  exit 1
fi

export L3_INSPECT_PLANNER="${planner}"
case "${planner}" in
  deepseek) default_url="https://api.deepseek.com"; default_keys="DEEPSEEK_API_KEY" ;;
  kimi) default_url="https://api.moonshot.cn/v1"; default_keys="MOONSHOT_API_KEY" ;;
  astra|gpt55) default_url=""; default_keys="OPENAI_API_KEY,OPENAI_API_KEY_BACKUP" ;;
  *) echo "[client] unknown planner: ${planner}" >&2; exit 2 ;;
esac
export L3_INSPECT_BASE_URL="${L3_INSPECT_BASE_URL:-${default_url}}"
if [[ -z "${L3_INSPECT_BASE_URL}" ]]; then
  echo "[client] export L3_INSPECT_BASE_URL for ${planner}; there is no default host" >&2
  if [[ -z "${planner_named}" ]]; then
    echo "         (no --planner given, so ${planner} was assumed; e.g. --planner deepseek)" >&2
  fi
  exit 2
fi
export L3_INSPECT_API_KEY_ENV="${L3_INSPECT_API_KEY_ENV:-${default_keys}}"
key_args=()
found_key=""
IFS=',' read -r -a key_names <<< "${L3_INSPECT_API_KEY_ENV}"
for name in "${key_names[@]}"; do
  name="${name// /}"
  [[ -n "${name}" ]] || continue
  file="${SECRETS_DIR}/$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${!name:-}" && -f "${file}" ]]; then
    export "${name}=$(tr -d '[:space:]' < "${file}")"
  fi
  if [[ -n "${!name:-}" ]]; then
    # By name only, so the key never appears in the docker command line.
    key_args+=(-e "${name}")
    found_key=1
  fi
done
if [[ -z "${found_key}" ]]; then
  echo "[client] no planner key: export one of ${L3_INSPECT_API_KEY_ENV}" >&2
  echo "         or write it to ${SECRETS_DIR}/$(printf '%s' "${key_names[0]}" | tr '[:upper:]' '[:lower:]')" >&2
  exit 2
fi

# Defaults mirror policy/RoboDojo_Agent_L3_Inspect/eval.sh and run_fixed_layout.sh,
# which this path bypasses.
export L3_INSPECT_ACTION_TYPE=joint
export L3_INSPECT_REASONING_EFFORT="${L3_INSPECT_REASONING_EFFORT:-medium}"
export L3_INSPECT_KEEP_ALL_IMAGES="${L3_INSPECT_KEEP_ALL_IMAGES:-0}"
export L3_INSPECT_IMAGE_HORIZON="${L3_INSPECT_IMAGE_HORIZON:-2}"
if [[ "${policy}" == "RoboDojo_Agent_L3_Inspect_EEF" ]]; then
  export L3_INSPECT_MAX_LLM_CALLS="${L3_INSPECT_MAX_LLM_CALLS:-170}"
fi
case "${planner}" in
  kimi|deepseek) export L3_INSPECT_HARD_TIMEOUT_S="${L3_INSPECT_HARD_TIMEOUT_S:-240}" ;;
  *) export L3_INSPECT_HARD_TIMEOUT_S="${L3_INSPECT_HARD_TIMEOUT_S:-90}" ;;
esac
export L3_INSPECT_TRACE_DIR="/workspace/l3_traces/${task}"
env_args=()
env_names=()
while IFS= read -r name; do
  env_args+=(-e "${name}")
  env_names+=("${name}")
done < <(compgen -e | grep '^L3_INSPECT_' | sort)

ckpt="${ckpt:-${planner}}"
run_id="${run_id:-$(date +%Y-%m-%d_%H-%M-%S)}"
mkdir -p "${TRACE_ROOT}" "${HOME}/.cache/warp" "${HOME}/.local/share/ov" "${HOME}/.cache/ov"
trace_dir="${TRACE_ROOT}/${task}/${run_id}"
video_dir="${ROBODOJO_ROOT}/eval_result/RoboDojo/${task}/${policy}/arx_x5/${seed}_ckpt_name=${ckpt},action_type=joint/${run_id}"

tty_args=()
[[ -t 0 && -t 1 ]] && tty_args=(-it)

echo "[client] task=${task} policy=${policy} planner=${planner} run_id=${run_id}"
echo "[client] transcripts -> ${trace_dir}"
echo "[client] videos      -> ${video_dir}"

cmd=(
  docker run --rm "${tty_args[@]}" --gpus all --network host --ipc host
  -v "${ROBODOJO_ROOT}/Assets:${CONTAINER_ROOT}/Assets:ro"
  -v "${ROBODOJO_ROOT}/Assets:${ROBODOJO_ROOT}/Assets:ro"
  -v "${ROBODOJO_ROOT}/eval_result:${CONTAINER_ROOT}/eval_result"
  -v "${HOME}/.cache/warp:/root/.cache/warp"
  -v "${HOME}/.local/share/ov:/root/.local/share/ov"
  -v "${HOME}/.cache/ov:/root/.cache/ov"
  -v "${ROBODOJO_ROOT}/task:${CONTAINER_ROOT}/task:ro"
  -v "${XPL_ROOT}/policy/RoboDojo_Agent_L3_Inspect:${CONTAINER_ROOT}/XPolicyLab/policy/RoboDojo_Agent_L3_Inspect:ro"
  -v "${XPL_ROOT}/policy/RoboDojo_Agent_L3_Inspect_EEF:${CONTAINER_ROOT}/XPolicyLab/policy/RoboDojo_Agent_L3_Inspect_EEF:ro"
  -v "${TRACE_ROOT}:/workspace/l3_traces"
  -e ROBODOJO_ROOT="${CONTAINER_ROOT}"
  -e ROBODOJO_RUN_ID="${run_id}"
  "${env_args[@]}"
  "${key_args[@]}"
  "${CLIENT_IMAGE}"
  bash scripts/robodojo.sh client
  --task "${task}" --policy-name "${policy}"
  --policy-host 127.0.0.1 --policy-port "${port}"
  --ckpt "${ckpt}" --action-type joint
  --eval-num "${eval_num}" --seed "${seed}" --env-gpu "${env_gpu}"
  "${extra[@]}"
)
# `-e NAME` takes the value from this shell, so the values are listed here;
# keys are shown by length only.
echo "[client] forwarded environment:"
for name in "${env_names[@]}"; do
  printf '  %s=%q\n' "${name}" "${!name}"
done
for ((i = 1; i < ${#key_args[@]}; i += 2)); do
  name="${key_args[i]}"
  value="${!name}"
  printf '  %s=<%d characters, hidden>\n' "${name}" "${#value}"
done
SHOW_BREAK_BEFORE=("${CLIENT_IMAGE}" bash)
show_command client "${cmd[@]}"

status=0
"${cmd[@]}" || status=$?

echo "[client] finished with status ${status}"
if [[ -f "${video_dir}/_result.json" ]]; then
  echo "[client] result: $(tr -d '\n ' < "${video_dir}/_result.json")"
fi
echo "[client] replay: bash ${XPL_ROOT}/docker/view_trace.sh --task ${task} --run ${run_id}"
exit "${status}"
