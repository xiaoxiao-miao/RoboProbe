# RoboDojo simulator image plus what the L3 Inspect harnesses need on the
# client side. At L3 the planner loop and every provider call run inside the
# RoboDojo client process (`deploy.py`), not in the policy server, so the
# simulator env needs `openai`; the harness code itself is bind-mounted.
#
# Every package already in the env is used as a constraint, so Isaac Sim's pins
# (typing_extensions==4.12.2 among them) are never moved. That rules out the
# openai==3.8.0 from pyproject.toml, which needs typing_extensions>=4.14; the
# resolver picks the newest openai that fits, which still has the Responses API.
#
# Build (from the RoboProbe checkout; nothing is copied, so no context):
#   docker build --network host --build-arg HTTPS_PROXY="${HTTPS_PROXY:-}" \
#     -t robodojo-roboprobe:cuda12.8 - < docker/robodojo_client.Dockerfile

ARG BASE_IMAGE=robodojo:cuda12.8
FROM ${BASE_IMAGE}

SHELL ["conda", "run", "--no-capture-output", "-n", "RoboDojo", "/bin/bash", "-c"]
RUN python -m pip list --format=freeze > /tmp/robodojo-pins.txt && \
    python -m pip install --no-cache-dir "openai>=1.66" -c /tmp/robodojo-pins.txt && \
    rm /tmp/robodojo-pins.txt && \
    python -c "import openai; print('openai', openai.__version__)"
SHELL ["/bin/bash", "-c"]
