#!/usr/bin/env bash
set -euo pipefail

# Install Python via uv (assumes uv/uvx already available).
# Docs: https://docs.astral.sh/uv/

install_python_for_user() {
  local target_user="$1"
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$target_user" -H bash -lc '
      set -euo pipefail
      if command -v python3 >/dev/null 2>&1; then
        echo "python3 already available for user: $(command -v python3)"
        exit 0
      fi
      if ! command -v uv >/dev/null 2>&1; then
        echo "Error: uv not found on PATH for user."
        exit 1
      fi
      export PATH="$HOME/.local/bin:$PATH"
      uv python install
      uv python install --default
      uv python list
      if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 still not found on PATH for user."
        exit 1
      fi
    '
  elif [ "$(id -u)" -eq 0 ]; then
    su - "$target_user" -c '
      set -euo pipefail
      if command -v python3 >/dev/null 2>&1; then
        echo "python3 already available for user: $(command -v python3)"
        exit 0
      fi
      if ! command -v uv >/dev/null 2>&1; then
        echo "Error: uv not found on PATH for user."
        exit 1
      fi
      export PATH="$HOME/.local/bin:$PATH"
      uv python install
      uv python install --default
      uv python list
      if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 still not found on PATH for user."
        exit 1
      fi
    '
  else
    if command -v python3 >/dev/null 2>&1; then
      echo "python3 is already available: $(command -v python3)"
      return 0
    fi
    if ! command -v uv >/dev/null 2>&1; then
      echo "Error: uv not found on PATH."
      return 1
    fi
    echo "Installing Python via uv..."
    uv python install
    uv python install --default
    uv python list
    if command -v python3 >/dev/null 2>&1; then
      echo "python3 is now available: $(command -v python3)"
    else
      echo "Python installation completed but python3 not found on PATH."
      echo "Try opening a new shell, or run: uv python install --default"
      return 1
    fi
  fi
}

install_python_for_user "$(id -un)"
if id -u codex >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  install_python_for_user "codex"
fi

# Provide a /usr/local/bin/python symlink if possible (some tools call `python`).
if command -v python3 >/dev/null 2>&1; then
  python3_path="$(command -v python3)"
  if [ -w /usr/local/bin ]; then
    ln -sf "$python3_path" /usr/local/bin/python
    echo "Linked python -> python3 in /usr/local/bin."
  else
    echo "Note: python3 is installed but /usr/local/bin is not writable; 'python' may be missing."
  fi
fi
