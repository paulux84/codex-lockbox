#!/usr/bin/env bash
set -euo pipefail

# Root-level init hook example.
# This runs as root inside the container *before* the user-level init.sh.
# Use this for apt installs or other privileged setup.

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl wget ca-certificates
