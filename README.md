# Codex Egress Sandbox

Run the **OpenAI Codex CLI** inside a **sandboxed Docker container** with:

- a custom `codex-sandbox` image that ships with Node.js and `@openai/codex`;
- an internal, default‑deny firewall with an allowlist of outbound domains;
- clean separation between **host** and **container** configuration (`auth.json`, `config.toml`, sessions, prompts);
- an optional init hook that prepares your project environment before Codex starts.

This repository does **not** replace the Codex CLI itself. It wraps it in a hardened container so you can safely point Codex at your local codebases.

Core logic lives in:

- `codex-cli/scripts/Dockerfile.codex-sandbox`
- `codex-cli/scripts/run_in_container.sh`
- example init scripts: `sandbox-setup.sh`, `sandbox-setup-java-25.sh`
- `REQUIREMENTS.md` (design and requirements document)


---

## Why use this wrapper?

**Main benefits:**

- **Isolated execution per project** – Codex runs in a disposable container bound to a single project directory.
- **Network sandboxing** – outbound traffic is blocked by default; only OpenAI/ChatGPT domains and an explicit allowlist are permitted.
- **Safer secrets handling** – `auth.json` stays on the host and is mounted read‑only into the container.
- **Per‑project Codex configuration** – keep different `config.toml`, prompts, and sessions for each project.
- **Pluggable init hook** – automatically install dependencies or run setup logic before Codex starts.
- **Non‑root container user** – Codex runs as an unprivileged `codex` user with write access only to mounted paths.

If you already use the Codex CLI, this wrapper gives you stronger isolation and a repeatable environment for your projects.

---

## Prerequisites

- Docker installed and running.
- Network access to build the image (packages + `@openai/codex`).
- An existing Codex configuration with credentials (for example `~/.codex/auth.json`).

You do **not** need Codex CLI installed on the host; it is installed in the `codex-sandbox` image.

---

## Building the `codex-sandbox` image

From the root of this repository, go to the scripts directory:

```bash
cd codex-cli/scripts
```

Build with the default Codex CLI version:

```bash
docker build -t codex-sandbox -f Dockerfile.codex-sandbox .
```

Build with a specific Codex CLI version (for example `0.36.0`):

```bash
docker build \
  -t codex-sandbox:0.36.0 \
  -f Dockerfile.codex-sandbox \
  --build-arg CODEX_VERSION=0.36.0 .
```

The Dockerfile installs:

- `@openai/codex@CODEX_VERSION` globally,
- essential system tools (`git`, `curl`, `dnsutils`, `python3`, `iptables`, `iproute2`, `ipset`, JDK 21 or fallback 17),
- a non‑root `codex` user with `WORKDIR /workspace`.

You can also build variant images for different Node versions (18/20/22) using `build_node_variants.sh`. By default, `codex-sandbox` points to the Node 22 variant.

---

## Getting started

The main entry point is `codex-cli/scripts/run_in_container.sh`. It:

1. Resolves the project directory to mount as the **workdir**.
2. Chooses the Docker image for Codex CLI.
3. Prepares a per‑project Codex home inside the workdir (`.codex/.environment`).
4. Configures the internal firewall and optional proxy.
5. Optionally runs an init hook.
6. Starts `codex` inside the container in the project directory.

### Quick start (sandboxed Codex for the current directory)

From your project directory:

```bash
./codex-cli/scripts/run_in_container.sh
```

This will:

- treat the current directory as the workdir,
- mount it into the container at `/app$WORK_DIR`,
- create (if needed) `.codex/.environment` inside the workdir and mount it as `/codex_home`,
- start an interactive Codex session in the project directory.

If you prefer to be explicit about the project path:

```bash
./codex-cli/scripts/run_in_container.sh --work_dir /path/to/project
```

### Example: reuse your global Codex config

Use your existing `~/.codex` (auth + config) while still running Codex in a sandboxed container:

```bash
./codex-cli/scripts/run_in_container.sh --work_dir /path/to/project
```

By default the script will:

- locate `auth.json` in your host configuration (for example `~/.codex`),
- mount it read‑only as `/codex_home/auth.json` inside the container,
- copy `config.toml` into `.codex/.environment/config.toml` if it does not already exist.

### Example: project‑specific Codex config

Keep Codex config and credentials separate from the host by using a dedicated directory:

```bash
mkdir -p /path/to/project/codex-config

cp ~/.codex/auth.json /path/to/project/codex-config/
cat > /path/to/project/codex-config/config.toml <<'EOF'
web_search_request = true
EOF

CODEX_CONFIG_DIR=/path/to/project/codex-config \
./codex-cli/scripts/run_in_container.sh --work_dir /path/to/project
```

In this setup:

- the host can continue using its own `~/.codex/config.toml`,
- the container uses `/codex_home/config.toml` from `codex-config`,
- `auth.json` from `codex-config` is mounted **read‑only** inside the container.

You can also place a project‑local configuration under `WORK_DIR/codex/`; everything there remains visible in the host project directory.

### Example: automatic dependency setup with an init script

You can run a custom script before Codex starts. A typical use case is installing project dependencies inside the container.

Keep a script like `sandbox-setup.sh` in your project root and run:

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /path/to/project \
  --init_script ./sandbox-setup.sh
```

The wrapper will:

- copy the script into `.codex/.environment/init.sh` inside the workdir,
- expose `.codex/.environment` as `SANDBOX_ENV_DIR` inside the container,
- execute the hook from the project directory **before** starting Codex.

You can also manually prepare `.codex/.environment/init.sh` in the workdir; it will be used automatically when present and executable.

### Example: allow additional outbound domains

The container firewall is default‑deny. OpenAI/ChatGPT domains are always allowed; other hosts must be explicitly whitelisted.

To allow extra domains (for example Maven Central and GitHub):

```bash
OPENAI_ALLOWED_DOMAINS="repo.maven.apache.org github.com" \
./codex-cli/scripts/run_in_container.sh --work_dir /path/to/project
```

Inside the container:

- loopback is always open,
- local network and gateway traffic is blocked,
- OpenAI/ChatGPT domains are always whitelisted,
- domains from `OPENAI_ALLOWED_DOMAINS` are added on top of the defaults.

Make sure `web_search_request` is not forced to `false` in the `config.toml` used by the container if you want Codex to perform web requests:

```toml
web_search_request = true
```

### More examples

#### Java project with host Maven cache

Mount your host Maven repository read‑only and point Maven at it from an init script:

```bash
OPENAI_ALLOWED_DOMAINS="repo.maven.apache.org" \
./codex-cli/scripts/run_in_container.sh \
  --work_dir /path/to/java-project \
  --read-only /home/youruser/.m2/repository \
  --init_script ./sandbox-setup-java-25.sh
```

Inside `sandbox-setup-java-25.sh`, configure the local repository to use the mounted path (adjust the path to match your host):

```bash
mkdir -p "$HOME/.m2"
cat >"$HOME/.m2/settings.xml" <<'EOF'
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">
  <localRepository>/app/home/youruser/.m2/repository</localRepository>
</settings>
EOF
```

This lets the container reuse your existing Maven cache without giving it write access.

#### Multiple read‑only mounts (shared SDKs and tools)

You can expose several host directories as read‑only, for example shared SDKs or pre‑downloaded dependencies:

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /path/to/project \
  --read-only /opt/shared-libs \
  --read-only /opt/sdkman
```

Inside the container these paths are available under `/app/opt/shared-libs` and `/app/opt/sdkman`.

#### Custom sessions directory outside the repo

Store Codex sessions outside the project (for example in a central directory):

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /path/to/project \
  --sessions-path /path/to/codex-sessions
```

Because this path is writable and outside the workdir, the wrapper will ask for confirmation in interactive mode.

---

## Configuration reference

### Workdir and workspace protection

- `--work_dir <path>` – project directory to mount into the container.
- If omitted, the current directory is used.
- The script resolves the path and **refuses** to mount `/` to avoid exposing the whole host.
- If `WORKSPACE_ROOT_DIR` is set, the workdir must be inside that directory.

### Codex home, config, and credentials

- The container’s Codex home is always `/codex_home`, backed by `WORK_DIR/.codex/.environment` on the host.
- `config.toml`:
  - is copied into `WORK_DIR/.codex/.environment/config.toml` if missing,
  - can be overridden by passing `--config <file|dir_with_config.toml>` or by setting `CODEX_CONFIG_DIR`.
- `auth.json`:
  - is **never** copied into `.codex/.environment`,
  - is searched in this order: `--auth_file` / `CODEX_AUTH_FILE`, directory passed to `--config`, `CODEX_CONFIG_DIR`, `~/.codex`, `$HOME/.config/codex`, `WORK_DIR/codex`, `WORK_DIR/.codex`, then a pre‑existing `WORK_DIR/.codex/.environment/auth.json`,
  - as soon as a valid file is found, it is mounted read‑only as `/codex_home/auth.json`.

If no credentials are found, Codex inside the container will show its normal login prompt and you can authenticate there.

### Sessions and prompts

- Session history:
  - by default stored in `WORK_DIR/.codex/.environment/sessions`,
  - can be overridden with `--sessions-path <path>`.
- Prompts:
  - the script looks for the first `prompts` directory in this order:
    1. the directory passed to `--config` (if it is a directory),
    2. `CODEX_CONFIG_DIR`,
    3. `~/.codex`,
    4. `~/.config/codex`,
    5. `WORK_DIR/codex`,
    6. `WORK_DIR/.codex`,
  - prompt files are copied into `.codex/.environment/prompts` **without overwriting** existing files.

### Init hook

- `--init_script <path>`:
  - copies the given script into `WORK_DIR/.codex/.environment/init.sh`,
  - marks it executable,
  - runs it from the workdir inside the container **before** starting Codex.
- The environment variable `SANDBOX_ENV_DIR` points to `/app$WORK_DIR/.codex/.environment` inside the container so your script can write any temporary artifacts there.

If `/app$WORK_DIR/.codex/.environment/init.sh` already exists and is executable, it will be used even if you do not pass `--init_script`.

### Docker image selection

- By default the wrapper uses the `codex-sandbox` image.
- You can override it with:
  - `CODEX_DOCKER_IMAGE=your-image:tag`,
  - or by building variant images tagged with a specific Codex version (for example `codex-sandbox:0.36.0`).
- Runtime selection/auto‑upgrade of Codex is not yet supported; you choose the version at build time via `CODEX_VERSION`.

### Additional mounts and safety

- `--read-only <path>`:
  - can be passed multiple times,
  - each path (file or directory) is mounted read‑only into the container under `/app<path>`.
- Writable mounts **outside** the workdir (for example `--codex-home`, `--sessions-path` pointing elsewhere) require an explicit confirmation and are rejected in non‑interactive mode, because they expose more of your host filesystem to the container.

### Environment inside the container

- Codex runs as the `codex` user, not root.
- The workdir is mounted at `/app$WORK_DIR` and used as the working directory.
- `/codex_home` is the container’s Codex home, backed by `WORK_DIR/.codex/.environment`.

---

## Troubleshooting and debug tips

- Each run of `run_in_container.sh` creates a dedicated container named after the workdir (for example `codex_<sanitized_path>`) and removes it automatically when Codex exits.
- If you see network issues:
  - inspect `/etc/codex/allowed_domains.txt` inside the container (for example via `docker exec`),
  - check container logs with `docker logs <container_name>`.
- The wrapper does **not** modify your host Codex installation (if any); all sandboxing logic lives entirely in the `codex-sandbox` image and its runtime configuration.

For a more formal description of goals and functional requirements, see `REQUIREMENTS.md`.

---

## Contributing

Contributions are welcome. To keep the project maintainable:

- Open an issue or discussion before large or behavior‑changing work.
- Keep shell scripts small, readable, and consistent with the existing style (POSIX‑friendly, lowercase‑hyphen file names).
- When changing behaviour, update both `README.md` (user‑facing) and `REQUIREMENTS.md` (design/requirements).
- For changes that touch networking or mounting logic, manually verify:
  - that workdir validation still rejects unsafe paths,
  - that the firewall behaves as documented (blocked generic host, reachable OpenAI endpoints),
  - that the wrapper cleans up containers after exit.

Pull requests that include a short explanation of *what* changed and *why* are especially helpful.
