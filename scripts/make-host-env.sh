#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${ROOT_DIR}/env"
LINK_PATH="${ENV_DIR}/current.env"

# Allow override via NODE_NAME env or --node <name>
NODE_NAME_ARG=""
if [[ "${1:-}" == "--node" && -n "${2:-}" ]]; then
  NODE_NAME_ARG="$2"
fi

HOST_SHORT="$(hostname -s || hostname)"
CHOSEN_NODE="${NODE_NAME_ARG:-${NODE_NAME:-$HOST_SHORT}}"

# normalize expected hostnames → env filenames
case "$CHOSEN_NODE" in
  r730xd-1|node1) ENV_FILE="r730xd-1.env" ;;
  r730xd-2|node2) ENV_FILE="r730xd-2.env" ;;
  r730xd-3|node3) ENV_FILE="r730xd-3.env" ;;
  *)
    echo "[make-host-env] Unknown hostname '$CHOSEN_NODE'."
    echo "  Set NODE_NAME=r730xd-1|r730xd-2|r730xd-3 or run: $0 --node r730xd-2"
    exit 2
    ;;
esac

TARGET="${ENV_DIR}/${ENV_FILE}"
if [[ ! -f "$TARGET" ]]; then
  echo "[make-host-env] Missing ${TARGET}"
  exit 3
fi

ln -sfn "$TARGET" "$LINK_PATH"
echo "[make-host-env] Linked ${LINK_PATH} -> ${ENV_FILE}"
echo "[make-host-env] To use with compose:  docker compose --env-file ${LINK_PATH} up -d"
