#!/usr/bin/env bash
set -euo pipefail

# Versioni configurabili per Java e Maven
JAVA_MAJOR_VERSION="21"
MAVEN_VERSION="3.9.11"

log() {
  echo "[init-java] $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: comando richiesto non trovato: $1"
    exit 1
  fi
}

# Directory di lavoro dell'hook nel container (run_in_container.sh esporta SANDBOX_ENV_DIR=/codex_home)
SANDBOX_ENV_DIR="${SANDBOX_ENV_DIR:-"$PWD/.codex/.environment"}"
TOOLS_DIR="$SANDBOX_ENV_DIR/tools"
JAVA_DIR="$TOOLS_DIR/java-$JAVA_MAJOR_VERSION"
MAVEN_DIR="$TOOLS_DIR/apache-maven-$MAVEN_VERSION"
BIN_DIR="$SANDBOX_ENV_DIR/bin"
#ENV_SNIPPET="$SANDBOX_ENV_DIR/.env_init_java.sh"
BASHRC_PATH="$SANDBOX_ENV_DIR/.bashrc"

mkdir -p "$TOOLS_DIR" "$BIN_DIR"

require_cmd curl
require_cmd tar

install_java() {
  if [[ -x "$JAVA_DIR/bin/java" ]]; then
    if "$JAVA_DIR/bin/java" -version 2>&1 | grep -q "$JAVA_MAJOR_VERSION"; then
      log "Java $JAVA_MAJOR_VERSION già presente in $JAVA_DIR"
      export JAVA_HOME="$JAVA_DIR"
      export PATH="$JAVA_HOME/bin:$PATH"
      return
    fi
    log "Java presente in $JAVA_DIR ma versione diversa, reinstallo"
    rm -rf "$JAVA_DIR"
  fi

  # Adoptium build GA per l'architettura x64 Linux
  JAVA_URL="https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR_VERSION}/ga/linux/x64/jdk/hotspot/normal/eclipse"
  log "Scarico JDK ${JAVA_MAJOR_VERSION} da $JAVA_URL"

  (
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    cd "$tmp_dir"
    curl -fsSL "$JAVA_URL" -o jdk.tar.gz
    tar -xzf jdk.tar.gz
    extracted_dir="$(find . -maxdepth 1 -type d -name 'jdk-*' | head -n 1)"
    if [[ -z "${extracted_dir:-}" ]]; then
      log "ERROR: directory JDK non trovata dopo l'estrazione"
      exit 1
    fi
    mkdir -p "$JAVA_DIR"
    mv "$extracted_dir"/* "$JAVA_DIR"/
  )

  export JAVA_HOME="$JAVA_DIR"
  export PATH="$JAVA_HOME/bin:$PATH"
  log "Java ${JAVA_MAJOR_VERSION} installato in $JAVA_HOME"
}

install_maven() {
  if [[ -x "$MAVEN_DIR/bin/mvn" ]]; then
    if "$MAVEN_DIR/bin/mvn" -v 2>&1 | grep -q "Apache Maven $MAVEN_VERSION"; then
      log "Maven $MAVEN_VERSION già presente in $MAVEN_DIR"
      export PATH="$MAVEN_DIR/bin:$PATH"
      return
    fi
    log "Maven presente in $MAVEN_DIR ma versione diversa, reinstallo"
    rm -rf "$MAVEN_DIR"
  fi

  MAVEN_URL="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
  log "Scarico Maven ${MAVEN_VERSION} da $MAVEN_URL"

  (
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    cd "$tmp_dir"
    curl -fsSL "$MAVEN_URL" -o maven.tar.gz
    tar -xzf maven.tar.gz
    extracted_dir="$(find . -maxdepth 1 -type d -name "apache-maven-${MAVEN_VERSION}" | head -n 1)"
    if [[ -z "${extracted_dir:-}" ]]; then
      log "ERROR: directory Maven non trovata dopo l'estrazione"
      exit 1
    fi
    mv "$extracted_dir" "$MAVEN_DIR"
  )

  export PATH="$MAVEN_DIR/bin:$PATH"
  log "Maven ${MAVEN_VERSION} installato in $MAVEN_DIR"
}

install_java
install_maven

# Esponi i binari anche tramite symlink stabili in $SANDBOX_ENV_DIR/bin
ln -sf "$JAVA_DIR/bin/java" "$BIN_DIR/java"
ln -sf "$JAVA_DIR/bin/javac" "$BIN_DIR/javac"
ln -sf "$MAVEN_DIR/bin/mvn" "$BIN_DIR/mvn"

# Aggiorna il PATH (anche se il chiamante ha un PATH di default ridotto)
export PATH="$BIN_DIR:$JAVA_DIR/bin:$MAVEN_DIR/bin:$PATH"

# Rendi l'env persistente per future shell (es. docker exec interattivi)
#cat >"$ENV_SNIPPET" <<EOF
## shellcheck shell=bash
#export JAVA_HOME="$JAVA_DIR"
#for p in "$BIN_DIR" "$JAVA_DIR/bin" "$MAVEN_DIR/bin"; do
#  case ":\$PATH:" in
#    *":\$p:"*) ;;
#    *) PATH="\$p:\$PATH" ;;
#  esac
#done
#export PATH
#EOF

#if [[ ! -f "$BASHRC_PATH" ]]; then
#  echo 'source "$HOME/.env_init_java.sh" 2>/dev/null || true' >"$BASHRC_PATH"
#elif ! grep -Fq '.env_init_java.sh' "$BASHRC_PATH"; then
#  echo 'source "$HOME/.env_init_java.sh" 2>/dev/null || true' >>"$BASHRC_PATH"
#fi

# Verifica finale
log "java -version:"
java -version 2>&1 || true

log "mvn -v:"
mvn -v 2>&1 || true
