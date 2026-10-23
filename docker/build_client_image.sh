#!/usr/bin/env bash
# Build the RoboDojo client image the L3 Inspect harnesses run in.
#
#   bash docker/build_client_image.sh
#
# The image is robodojo:cuda12.8 plus `openai`, resolved against every package
# already in the simulator env (see robodojo_client.Dockerfile). Nothing from this
# checkout is baked in: run_client.sh bind-mounts the harnesses, so editing them
# needs no rebuild.
#
# Environment:
#   BASE_IMAGE    simulator image to extend (default: robodojo:cuda12.8)
#   CLIENT_IMAGE  tag to build (default: robodojo-roboprobe:cuda12.8)
#   HTTPS_PROXY   forwarded to pip when set; the build uses the host network, so a
#                 proxy on 127.0.0.1 is reachable
set -euo pipefail

# Resolved through symlinks, so a link to this script from another checkout
# still finds this one.
XPL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
BASE_IMAGE="${BASE_IMAGE:-robodojo:cuda12.8}"
CLIENT_IMAGE="${CLIENT_IMAGE:-robodojo-roboprobe:cuda12.8}"
DOCKERFILE="${XPL_ROOT}/docker/robodojo_client.Dockerfile"
# shellcheck source=lib.sh
source "${XPL_ROOT}/docker/lib.sh"

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "[build] base image ${BASE_IMAGE} not found; build RoboDojo's image first" >&2
  exit 1
fi

cmd=(
  docker build --network host
  --build-arg BASE_IMAGE="${BASE_IMAGE}"
  --build-arg HTTPS_PROXY="${HTTPS_PROXY:-}"
  --build-arg HTTP_PROXY="${HTTP_PROXY:-}"
  -t "${CLIENT_IMAGE}" -
)
echo "[build] Dockerfile ${DOCKERFILE} (comments omitted):"
grep -v '^\s*#' "${DOCKERFILE}" | sed '/^\s*$/d; s/^/  /'
SHOW_SUFFIX="< $(printf '%q' "${DOCKERFILE}")"
show_command build "${cmd[@]}"
"${cmd[@]}" < "${DOCKERFILE}"
echo "[build] ${CLIENT_IMAGE} ready"
