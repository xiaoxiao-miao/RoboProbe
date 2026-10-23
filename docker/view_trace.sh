#!/usr/bin/env bash
# Replay an L3 Inspect episode: planner turns synchronized with the three camera videos.
#
#   bash docker/view_trace.sh --task stack_bowls                  # latest run, first layout
#   bash docker/view_trace.sh --task stack_bowls --run RUN_ID --layout 3
#   bash docker/view_trace.sh --trace-dir DIR --video-dir DIR     # any pair, explicitly
#
# Serves http://127.0.0.1:<port> until Ctrl-C. A transcript and its videos are
# paired by run id: run_client.sh writes the transcript under
# TRACE_ROOT/<task>/<run_id>/layout-<N>/ and RoboDojo the videos under
# eval_result/RoboDojo/<task>/<policy>/<env_cfg>/<seed>_<labels>/<run_id>/.
#
# Options:
#   --task NAME        task whose runs to look in
#   --run ID           run id (default: the newest under TRACE_ROOT/<task>)
#   --layout N         layout to show when a run has several (default: the lowest)
#   --port PORT        default: 18790
#   --trace-dir DIR    a layout directory holding l3_inspect_transcript.json
#   --video-dir DIR    the RoboDojo run directory holding the episode MP4s
#
# Environment: ROBODOJO_ROOT and TRACE_ROOT as in run_client.sh. Needs ffprobe.
set -euo pipefail

# Resolved through symlinks, so a link to this script from another checkout
# still finds this one.
XPL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORKSPACE_ROOT="$(cd "${XPL_ROOT}/.." && pwd)"
# shellcheck source=lib.sh
source "${XPL_ROOT}/docker/lib.sh"
ROBODOJO_ROOT="$(resolve_robodojo_root "${WORKSPACE_ROOT}")"
TRACE_ROOT="${TRACE_ROOT:-${XPL_ROOT}/runs/l3_traces}"
PYTHON="${XPL_ROOT}/.venv/bin/python"

task=""
run_id=""
layout=""
port="18790"
trace_dir=""
video_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task="$2"; shift 2 ;;
    --run) run_id="$2"; shift 2 ;;
    --layout) layout="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --trace-dir) trace_dir="$2"; shift 2 ;;
    --video-dir) video_dir="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "[view] unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v ffprobe >/dev/null || { echo "[view] ffprobe not found; apt install ffmpeg" >&2; exit 1; }
[[ -x "${PYTHON}" ]] || { echo "[view] ${XPL_ROOT}/.venv is missing" >&2; exit 1; }

if [[ -z "${trace_dir}" || -z "${video_dir}" ]]; then
  [[ -n "${task}" ]] || { echo "[view] pass --task, or both --trace-dir and --video-dir" >&2; exit 2; }
  if [[ -z "${run_id}" ]]; then
    # Newest run that got as far as a transcript; one that died before its first
    # episode leaves an empty directory behind.
    run_id="$(ls -1d "${TRACE_ROOT}/${task}"/*/layout-*/l3_inspect_transcript.json 2>/dev/null \
      | awk -F/ '{print $(NF-2)}' | sort -u | tail -n 1)"
    [[ -n "${run_id}" ]] || { echo "[view] no transcripts under ${TRACE_ROOT}/${task}" >&2; exit 1; }
  fi
  run_trace="${TRACE_ROOT}/${task}/${run_id}"
  if [[ -z "${layout}" ]]; then
    layout="$(ls -1 "${run_trace}" 2>/dev/null | sed -n 's/^layout-\([0-9]*\)$/\1/p' | sort -n | head -n 1)"
    [[ -n "${layout}" ]] || { echo "[view] no layout-* directory under ${run_trace}" >&2; exit 1; }
  fi
  trace_dir="${trace_dir:-${run_trace}/layout-${layout}}"
  if [[ -z "${video_dir}" ]]; then
    matches=("${ROBODOJO_ROOT}"/eval_result/RoboDojo/"${task}"/*/*/*/"${run_id}")
    [[ -d "${matches[0]}" ]] || { echo "[view] no videos for run ${run_id} under ${ROBODOJO_ROOT}/eval_result" >&2; exit 1; }
    video_dir="${matches[0]}"
  fi
fi
[[ -f "${trace_dir}/l3_inspect_transcript.json" ]] \
  || { echo "[view] ${trace_dir}/l3_inspect_transcript.json not found" >&2; exit 1; }

# RoboDojo numbers episodes in run order and records which layout each one was,
# so the layout picks the video rather than assuming episode N is layout N.
episode_args=()
if [[ -n "${layout}" && -f "${video_dir}/_result.json" ]]; then
  episode="$("${PYTHON}" - "${video_dir}/_result.json" "${layout}" <<'PY'
import json, sys
details = json.load(open(sys.argv[1])).get("details", {})
print(next((k for k, v in details.items() if str(v.get("layout_id")) == sys.argv[2]), ""))
PY
)"
  [[ -n "${episode}" ]] && episode_args=(--episode-index "${episode}")
fi

if ss -ltnH 2>/dev/null | awk -v p="${port}" '$4 ~ "[:.]"p"$" {f=1} END {exit !f}'; then
  echo "[view] port ${port} is in use (an earlier viewer?); stop it or pass --port" >&2
  exit 1
fi
echo "[view] transcript ${trace_dir}"
echo "[view] videos     ${video_dir}"
cd "${XPL_ROOT}"
export PYTHONPATH="${WORKSPACE_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"
cmd=(
  "${PYTHON}" -m XPolicyLab.policy.RoboDojo_Agent_L3_Inspect.trace_viewer
  --trace-dir "${trace_dir}" --video-dir "${video_dir}" "${episode_args[@]}"
  --host 127.0.0.1 --port "${port}"
)
echo "[view] cd ${XPL_ROOT} && PYTHONPATH=${PYTHONPATH}"
show_command view "${cmd[@]}"
exec "${cmd[@]}"
