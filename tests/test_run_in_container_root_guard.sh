#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DOCKER_LOG="$TMP_DIR/docker.log"
export DOCKER_LOG

MOCK_BIN="$TMP_DIR/mockbin"
mkdir -p "$MOCK_BIN"

cat <<'EOS' > "$MOCK_BIN/docker"
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
exit 1
EOS

chmod +x "$MOCK_BIN/docker"
export PATH="$MOCK_BIN:$PATH"

SYMLINK_WORKDIR="$TMP_DIR/rootlink"
ln -s / "$SYMLINK_WORKDIR"

if bash "$ROOT_DIR/codex-cli/scripts/run_in_container.sh" --work_dir "$SYMLINK_WORKDIR" >/dev/null 2>&1; then
  echo "Expected run_in_container.sh to refuse workdir resolving to /" >&2
  exit 1
fi

echo "run_in_container root guard test passed"
