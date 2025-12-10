#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults can be overridden via env vars
WORK_DIR="${WORKSPACE_ROOT_DIR:-$(pwd)}"
CODEX_DOCKER_IMAGE="${CODEX_DOCKER_IMAGE:-codex-sandbox}"
CODEX_VERSION="${CODEX_VERSION:-}"
ALLOW_REMOTE_IMAGE_PULL="${ALLOW_REMOTE_IMAGE_PULL:-0}"
DEFAULT_OPENAI_ALLOWED_DOMAINS=(api.openai.com chat.openai.com chatgpt.com auth0.openai.com platform.openai.com openai.com)
USER_OPENAI_ALLOWED_DOMAINS="${OPENAI_ALLOWED_DOMAINS-}"
OPENAI_ALLOWED_DOMAINS=""
INIT_SCRIPT=""
READ_ONLY_PATHS=()
CONFIG_OVERRIDE_FILE=""
SESSIONS_PATH=""
CODEX_DATA_DIR="${CODEX_DATA_DIR:-}"
WORKDIR_CODEX_DIR=""
CONFIG_SOURCE_DIR=""

# Merge default domains with user-supplied ones (user additions do not replace defaults)
declare -A __SEEN_DOMAINS=()
MERGED_OPENAI_ALLOWED_DOMAINS=()
for domain in "${DEFAULT_OPENAI_ALLOWED_DOMAINS[@]}"; do
  if [[ -n "$domain" && -z "${__SEEN_DOMAINS[$domain]+isset}" ]]; then
    MERGED_OPENAI_ALLOWED_DOMAINS+=("$domain")
    __SEEN_DOMAINS[$domain]=1
  fi
done
if [[ -n "$USER_OPENAI_ALLOWED_DOMAINS" ]]; then
  read -r -a __USER_DOMAINS <<<"$USER_OPENAI_ALLOWED_DOMAINS"
  for domain in "${__USER_DOMAINS[@]}"; do
    if [[ -n "$domain" && -z "${__SEEN_DOMAINS[$domain]+isset}" ]]; then
      MERGED_OPENAI_ALLOWED_DOMAINS+=("$domain")
      __SEEN_DOMAINS[$domain]=1
    fi
  done
fi
OPENAI_ALLOWED_DOMAINS="${MERGED_OPENAI_ALLOWED_DOMAINS[*]}"

get_latest_codex_version() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "Error: npm is required to resolve the latest Codex CLI version. Install npm or pass --codex-version / set CODEX_VERSION." >&2
    exit 1
  fi

  local latest
  if ! latest=$(npm view @openai/codex version 2>/dev/null | tr -d '\n'); then
    echo "Error: unable to fetch latest Codex version via 'npm view @openai/codex version'. Set CODEX_VERSION or use --codex-version." >&2
    exit 1
  fi

  if [[ -z "$latest" ]]; then
    echo "Error: empty Codex version returned by npm. Set CODEX_VERSION or use --codex-version." >&2
    exit 1
  fi

  echo "$latest"
}

ensure_image_with_version() {
  local image="$1" version="$2" force_pull="${3:-false}" allow_pull="${4:-0}"

  if [[ "$force_pull" == "true" && "$allow_pull" == "1" ]]; then
    echo "Ensuring Docker image $image is up to date..."
    if docker pull "$image" >/dev/null 2>&1; then
      return
    fi
    if docker image inspect "$image" >/dev/null 2>&1; then
      echo "Warning: unable to pull $image; using existing local image." >&2
      return
    fi
    echo "Info: pull failed and image missing locally; attempting local build..."
  elif [[ "$allow_pull" != "1" ]]; then
    echo "Skipping remote pull for $image (ALLOW_REMOTE_IMAGE_PULL=0); will use local image or build from Dockerfile."
  fi

  if docker image inspect "$image" >/dev/null 2>&1; then
    return
  fi

  if [[ "$allow_pull" == "1" ]]; then
    echo "Fetching Docker image $image..."
    if docker pull "$image" >/dev/null 2>&1; then
      return
    fi
  fi

  echo "Image $image not found remotely. Building locally with CODEX_VERSION=$version..."
  docker build -t "$image" \
    -f "$SCRIPT_DIR/Dockerfile.codex-sandbox" \
    --build-arg "CODEX_VERSION=$version" \
    "$SCRIPT_DIR"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work_dir|--work-dir)
      if [[ -z "${2-}" ]]; then
        echo "Error: --work_dir flag provided but no directory specified."
        exit 1
      fi
      WORK_DIR="$2"
      shift 2
      ;;
    --init_script)
      if [[ -z "${2-}" ]]; then
        echo "Error: --init_script flag provided but no script path specified."
        exit 1
      fi
      INIT_SCRIPT="$2"
      shift 2
      ;;
    --codex-version)
      if [[ -z "${2-}" ]]; then
        echo "Error: --codex-version flag provided but no version specified."
        exit 1
      fi
      CODEX_VERSION="$2"
      shift 2
      ;;
    --read-only)
      if [[ -z "${2-}" ]]; then
        echo "Error: --read-only flag provided but no path specified."
        exit 1
      fi
      READ_ONLY_PATHS+=("$2")
      shift 2
      ;;
    --config)
      if [[ -z "${2-}" ]]; then
        echo "Error: --config flag provided but no config file specified."
        exit 1
      fi
      CONFIG_OVERRIDE_FILE="$2"
      shift 2
      ;;
    --sessions-path)
      if [[ -z "${2-}" ]]; then
        echo "Error: --sessions-path flag provided but no path specified."
        exit 1
      fi
      SESSIONS_PATH="$2"
      shift 2
      ;;
    --codex-home)
      if [[ -z "${2-}" ]]; then
        echo "Error: --codex-home flag provided but no path specified."
        exit 1
      fi
      CODEX_DATA_DIR="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "$WORK_DIR" ]]; then
  echo "Error: No work directory provided and WORKSPACE_ROOT_DIR is not set."
  exit 1
fi

if [[ "$WORK_DIR" == "/" ]]; then
  echo "Error: refusing to use / as work directory."
  exit 1
fi

if [[ -z "$OPENAI_ALLOWED_DOMAINS" ]]; then
  echo "Error: OPENAI_ALLOWED_DOMAINS is empty."
  exit 1
fi

if ! WORK_DIR=$(realpath "$WORK_DIR"); then
  echo "Error: Unable to resolve work directory path."
  exit 1
fi

if [[ -n "${WORKSPACE_ROOT_DIR:-}" ]]; then
  if ROOT_REAL=$(realpath "$WORKSPACE_ROOT_DIR" 2>/dev/null); then
    if [[ "$WORK_DIR" != "$ROOT_REAL" && "$WORK_DIR" != "$ROOT_REAL"/* ]]; then
      echo "Error: work directory must be inside WORKSPACE_ROOT_DIR ($ROOT_REAL)"
      exit 1
    fi
  fi
fi

if [[ ! -d "$WORK_DIR" ]]; then
  echo "Error: Work directory does not exist: $WORK_DIR"
  exit 1
fi

if [[ -n "$CODEX_DATA_DIR" ]]; then
  if [[ ! -e "$CODEX_DATA_DIR" ]]; then
    if ! mkdir -p "$CODEX_DATA_DIR"; then
      echo "Error: Unable to create codex home path: $CODEX_DATA_DIR"
      exit 1
    fi
  fi
  if ! CODEX_DATA_DIR=$(realpath "$CODEX_DATA_DIR"); then
    echo "Error: Unable to resolve codex home path."
    exit 1
  fi
  if [[ "$CODEX_DATA_DIR" != "$WORK_DIR"/* ]]; then
    echo "Warning: codex home is outside the workdir and will be mounted writable in the container: $CODEX_DATA_DIR"
    if [ -t 0 ]; then
      read -r -p "Proceed with mounting codex home outside workdir? [y/N] " confirm_codex_home
      if [[ ! "$confirm_codex_home" =~ ^[Yy]$ ]]; then
        echo "Aborting per user choice."
        exit 1
      fi
    else
      echo "Error: Non-interactive shell; refusing to mount codex home outside workdir." >&2
      exit 1
    fi
  fi
else
  CODEX_DATA_DIR="$WORK_DIR/.codex"
fi

READ_ONLY_PATHS_ABS=()
for path in "${READ_ONLY_PATHS[@]}"; do
  if ! abs_path=$(realpath "$path"); then
    echo "Error: Unable to resolve read-only path: $path"
    exit 1
  fi
  if [[ ! -e "$abs_path" ]]; then
    echo "Error: Read-only path does not exist: $path"
    exit 1
  fi
  if [[ "$abs_path" != "$WORK_DIR"/* ]]; then
    echo "Error: refusing to mount read-only path outside workdir: $abs_path"
    exit 1
  fi
  READ_ONLY_PATHS_ABS+=("$abs_path")
done

IMAGE_REPO="$CODEX_DOCKER_IMAGE"
IMAGE_TAG=""
if [[ "${IMAGE_REPO##*/}" == *:* ]]; then
  IMAGE_TAG="${IMAGE_REPO##*:}"
  IMAGE_REPO="${IMAGE_REPO%:*}"
fi

LATEST_REQUESTED=false
if [[ -n "$CODEX_VERSION" ]]; then
  TARGET_CODEX_VERSION="$CODEX_VERSION"
elif [[ -n "$IMAGE_TAG" ]]; then
  TARGET_CODEX_VERSION="$IMAGE_TAG"
else
  TARGET_CODEX_VERSION="$(get_latest_codex_version)"
  LATEST_REQUESTED=true
fi

if [[ "$TARGET_CODEX_VERSION" == "latest" ]]; then
  LATEST_REQUESTED=true
fi

RESOLVED_DOCKER_IMAGE="$IMAGE_REPO:$TARGET_CODEX_VERSION"

ensure_image_with_version "$RESOLVED_DOCKER_IMAGE" "$TARGET_CODEX_VERSION" "$LATEST_REQUESTED" "$ALLOW_REMOTE_IMAGE_PULL"

# Prepare environment directory under chosen codex dir for init artifacts
ENV_DIR="$CODEX_DATA_DIR/.environment"
if ! mkdir -p "$ENV_DIR"; then
  echo "Error: Unable to create environment directory at $ENV_DIR"
  exit 1
fi

# Prepare Codex config directory inside environment and clone host config if missing
WORKDIR_CODEX_DIR="$CODEX_DATA_DIR"
mkdir -p "$WORKDIR_CODEX_DIR"

CONFIG_SOURCE_DIR=""
CONFIG_DIR_CANDIDATES=(
  "${CODEX_CONFIG_DIR:-$HOME/.codex}"
  "$HOME/.codex"
  "$HOME/.config/codex"
  "$WORK_DIR/codex"
  "$WORKDIR_CODEX_DIR"
)

for candidate in "${CONFIG_DIR_CANDIDATES[@]}"; do
  if [[ -d "$candidate" ]]; then
    CONFIG_SOURCE_DIR="$candidate"
    break
  fi
done

copy_if_missing() {
  local src="$1" dest="$2"
  if [[ -f "$src" && ! -e "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  fi
}

CODEX_HOME_DIR="$ENV_DIR"
mkdir -p "$CODEX_HOME_DIR"

if [[ -n "$CONFIG_OVERRIDE_FILE" ]]; then
  CONFIG_OVERRIDE_PATH="$CONFIG_OVERRIDE_FILE"
  if [[ -d "$CONFIG_OVERRIDE_PATH" ]]; then
    CONFIG_OVERRIDE_PATH="$CONFIG_OVERRIDE_PATH/config.toml"
    if [[ ! -f "$CONFIG_OVERRIDE_PATH" ]]; then
      echo "Error: --config directory missing config.toml: $CONFIG_OVERRIDE_FILE"
      exit 1
    fi
  fi
  if [[ ! -f "$CONFIG_OVERRIDE_PATH" ]]; then
    echo "Error: config file not found: $CONFIG_OVERRIDE_FILE"
    exit 1
  fi
  if ! cp "$CONFIG_OVERRIDE_PATH" "$CODEX_HOME_DIR/config.toml"; then
    echo "Error: failed to copy --config file into $CODEX_HOME_DIR"
    exit 1
  fi

  CONFIG_OVERRIDE_DIR="$(dirname "$CONFIG_OVERRIDE_PATH")"
  if [[ -f "$CONFIG_OVERRIDE_DIR/auth.json" ]]; then
    if ! cp "$CONFIG_OVERRIDE_DIR/auth.json" "$CODEX_HOME_DIR/auth.json"; then
      echo "Error: failed to copy auth.json from --config directory into $CODEX_HOME_DIR"
      exit 1
    fi
  fi
else
  if [[ -n "$CONFIG_SOURCE_DIR" ]]; then
    copy_if_missing "$CONFIG_SOURCE_DIR/config.toml" "$CODEX_HOME_DIR/config.toml"
    copy_if_missing "$CONFIG_SOURCE_DIR/auth.json" "$CODEX_HOME_DIR/auth.json"
  fi
fi

secure_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    chmod 600 "$file" 2>/dev/null || true
  fi
}

secure_if_exists "$CODEX_HOME_DIR/config.toml"
secure_if_exists "$CODEX_HOME_DIR/auth.json"

if [[ -d "$WORK_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
  if ! git -C "$WORK_DIR" check-ignore -q "${ENV_DIR#$WORK_DIR/}"; then
    echo "Warning: ${ENV_DIR#$WORK_DIR/} is not ignored by git; consider adding it to .gitignore to avoid committing credentials."
  fi
fi

if [[ -z "$SESSIONS_PATH" ]]; then
  SESSIONS_PATH="$CODEX_HOME_DIR/sessions"
fi
mkdir -p "$SESSIONS_PATH"
if SESSIONS_PATH_ABS=$(realpath "$SESSIONS_PATH"); then
  :
else
  echo "Error: Unable to resolve sessions path: $SESSIONS_PATH"
  exit 1
fi
if [[ "$SESSIONS_PATH_ABS" != "$WORK_DIR"/* ]]; then
  echo "Warning: sessions path is outside the workdir and will be mounted writable in the container: $SESSIONS_PATH_ABS"
  if [ -t 0 ]; then
    read -r -p "Proceed with mounting sessions path outside workdir? [y/N] " confirm_sessions
    if [[ ! "$confirm_sessions" =~ ^[Yy]$ ]]; then
      echo "Aborting per user choice."
      exit 1
    fi
  else
    echo "Error: Non-interactive shell; refusing to mount sessions path outside workdir." >&2
    exit 1
  fi
fi

# If an init script was provided, copy it into the environment directory
if [[ -n "$INIT_SCRIPT" ]]; then
  if [[ ! -f "$INIT_SCRIPT" ]]; then
    echo "Error: init script not found: $INIT_SCRIPT"
    exit 1
  fi
  if ! cp "$INIT_SCRIPT" "$ENV_DIR/init.sh"; then
    echo "Error: failed to copy init script into $ENV_DIR"
    exit 1
  fi
  chmod +x "$ENV_DIR/init.sh" || true
fi

# Container name derived from sanitized workdir path
CONTAINER_NAME="codex_$(echo "$WORK_DIR" | sed 's:/:_:g' | sed 's/[^a-zA-Z0-9_-]//g')"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [[ -n "${ALLOWED_DOMAINS_DIR:-}" && -d "$ALLOWED_DOMAINS_DIR" ]]; then
    rm -rf "$ALLOWED_DOMAINS_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Remove any existing container for this workdir
cleanup

ALLOWED_DOMAINS_DIR="$(mktemp -d)"
ALLOWED_DOMAINS_FILE="$ALLOWED_DOMAINS_DIR/allowed_domains.txt"
for domain in $OPENAI_ALLOWED_DOMAINS; do
  if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: Invalid domain format: $domain"
    exit 1
  fi
  echo "$domain" >>"$ALLOWED_DOMAINS_FILE"
done

DOCKER_RUN_ARGS=(
  --name "$CONTAINER_NAME"
  -d
  --cap-drop=ALL
  --security-opt no-new-privileges
  -v "$WORK_DIR:/app$WORK_DIR"
)

DOCKER_RUN_ARGS+=(-v "$CODEX_HOME_DIR:/codex_home")
DOCKER_RUN_ARGS+=(-e "CODEX_HOME=/codex_home")
DOCKER_RUN_ARGS+=(--mount "type=bind,src=$SESSIONS_PATH_ABS,dst=/codex_home/sessions")

for ro_path in "${READ_ONLY_PATHS_ABS[@]}"; do
  DOCKER_RUN_ARGS+=(--mount "type=bind,src=$ro_path,dst=/app$ro_path,ro")
done

docker run "${DOCKER_RUN_ARGS[@]}" "$RESOLVED_DOCKER_IMAGE" sleep infinity

# Initialize firewall in shared network namespace without granting NET_ADMIN to the main container
docker run --rm \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --user root \
  --network "container:$CONTAINER_NAME" \
  -v "$SCRIPT_DIR/init_firewall.sh:/usr/local/bin/init_firewall.sh:ro" \
  -v "$ALLOWED_DOMAINS_DIR:/etc/codex:ro" \
  --entrypoint bash \
  "$RESOLVED_DOCKER_IMAGE" \
  -c "/usr/local/bin/init_firewall.sh"

# Quote Codex args (if any)
quoted_args=""
for arg in "$@"; do
  quoted_args+=" $(printf '%q' "$arg")"
done

exec_flags=()
if [ -t 0 ]; then
  exec_flags+=(-it)
else
  exec_flags+=(-i)
fi

docker exec --user codex "${exec_flags[@]}" "$CONTAINER_NAME" bash -c "SANDBOX_ENV_DIR=\"/codex_home\"; cd \"/app$WORK_DIR\" && if [ -x \"\$SANDBOX_ENV_DIR/init.sh\" ]; then \"\$SANDBOX_ENV_DIR/init.sh\"; fi; codex --full-auto${quoted_args}"
