# L3 Inspect in the RoboDojo Docker image

Run the L3 Inspect harnesses against RoboDojo's simulator image, with the policy
server on the host. Covers `RoboDojo_Agent_L3_Inspect_EEF` (default) and
`RoboDojo_Agent_L3_Inspect`.

## Where things run

```text
container (robodojo-roboprobe, conda env RoboDojo)      host (<checkout>/.venv)
  RoboDojo client: Isaac Sim, CuRobo, scoring              policy server: a stub
  harness deploy.py: planner loop + provider calls  <--->  answers connect + reset
         |  ws://127.0.0.1:6070                             (model.py, no weights)
         v
  planner provider (DeepSeek, Moonshot, AIDP)
```

At L3 Inspect the planner loop needs the live simulator - CuRobo planning from
the current joint state, stepping the env, reading limits - so it runs inside
the client, in `deploy.py`. The server's `Model` refuses `get_action`; it exists
because the RoboDojo client will not start without a server to connect to.
Planner keys and `L3_INSPECT_*` settings therefore go to the **container**.

## One-time setup

```bash
cd <workspace>/RoboProbe

# 1. Server environment: this checkout's own dependencies only.
python3 -m venv .venv && .venv/bin/pip install -e .

# 2. The server reads <workspace>/XPolicyLab/..., the checkout's import name.
#    Skip when the checkout is already called XPolicyLab.
ln -s RoboProbe ../XPolicyLab

# 3. RoboDojo checkout: found as <workspace>/RoboDojo-eval or <workspace>/RoboDojo.
#    Only a checkout somewhere else needs this.
export ROBODOJO_ROOT=/elsewhere/RoboDojo

# 4. Client image: robodojo:cuda12.8 plus openai (needs RoboDojo's image built).
bash docker/build_client_image.sh

# 5. Planner key, read from the environment or from this file.
mkdir -p .secrets && printf '%s' 'sk-...' > .secrets/deepseek_api_key
```

The image installs the newest `openai` that fits RoboDojo's pinned packages
(2.x), not the `openai==3.8.0` this repo's native client path checks for: 3.x
needs a newer `typing_extensions` than Isaac Sim's pin. Runs made this way are
not on the official protocol stack.

## Run an evaluation

Terminal 1, left running across runs:

```bash
bash docker/serve_policy.sh                       # --port 6070 --policy RoboDojo_Agent_L3_Inspect_EEF
```

Terminal 2:

```bash
bash docker/run_client.sh --task stack_bowls --planner deepseek
bash docker/run_client.sh --task stack_bowls --planner deepseek --eval-num 5
```

`run_client.sh --help` lists the options. It mounts both harness directories
read-only (the EEF harness imports the joint one), so edits take effect on the
next run without a rebuild. Defaults follow the harness's own `eval.sh`:
`KEEP_ALL_IMAGES=0`, `IMAGE_HORIZON=2`, `REASONING_EFFORT=medium`, 170 LLM calls
for EEF, and a 240 s hard timeout for kimi/deepseek (90 s otherwise). Any
`L3_INSPECT_*` exported on the host is forwarded and wins over these.

Each run gets one run id, which names both of its outputs:

| Output | Host path |
| --- | --- |
| Transcript | `runs/l3_traces/<task>/<run_id>/layout-<N>/l3_inspect_transcript.json` |
| Videos, `_result.json` | `$ROBODOJO_ROOT/eval_result/RoboDojo/<task>/<policy>/arx_x5/<seed>_ckpt_name=<planner>,action_type=joint/<run_id>/` |

Both are written by the container and are owned by root.

An episode ends when the task succeeds, when RoboDojo's `step_lim` runs out
(800 env steps for `stack_bowls`, 25 per simulated second), when the LLM budget
runs out, or when the model calls `give_up`. Time spent waiting for the planner
costs no env steps.

## Replay an episode

```bash
bash docker/view_trace.sh --task stack_bowls                       # newest run, lowest layout
bash docker/view_trace.sh --task stack_bowls --run <run_id> --layout 3
```

Then open <http://127.0.0.1:18790>; Ctrl-C stops the viewer. The page shows:

- the official result, LLM call count and why the episode ended;
- head, left-wrist and right-wrist video, played in sync, with frame stepping;
- a timeline cut into one segment per planner turn - click one to jump there;
- for the selected turn: the model's note, its `move_eef` targets, the tool
  result (accepted, unreachable, or a repair prompt), the env-step and
  video-frame range it played, and the arrival error the next turn reported;
- the full prompt: system message, task goal and tool schema.

A useful order for a failed episode: read the `give_up` note, look for runs of
short segments (repeated small corrections that never converge), and compare
what the note says the cameras show with the wrist videos.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `ROBODOJO_ROOT is unset` in the container | Launched without `run_client.sh`; pass `-e ROBODOJO_ROOT=/workspace/RoboDojo` |
| `nothing listens on port 6070` | Start `serve_policy.sh` first, on the same `--port` |
| `HTTP 400` from DeepSeek | Keep `deepseek` on the Responses API; its chat surface rejects tool turns without echoed reasoning |
| `HTTP 401` | Wrong or missing key for the planner named |
| viewer: `ffprobe not found` | `sudo apt install ffmpeg` |
