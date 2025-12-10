# Codex Sandbox Wrapper

Questo progetto fornisce un wrapper per eseguire la **Codex CLI** dentro un **container Docker isolato**, con:

- immagine custom `codex-sandbox` già pronta con Node + `@openai/codex`;
- firewall interno configurabile per limitare i domini raggiungibili;
- gestione della configurazione Codex (`auth.json`, `config.toml`, ecc.) separata tra **host** e **container**;
- hook di init opzionale: se esiste ed è eseguibile `.codex/.environment/init.sh` nella workdir montata, viene lanciato prima di `codex` (puoi popolarlo con `--init_script`, ad es. usando `sandbox-setup.sh` o `sandbox-setup-java-25.sh`).

La logica principale vive in:

- `codex-cli/scripts/Dockerfile.codex-sandbox`
- `codex-cli/scripts/run_in_container.sh`
- script di init di esempio: `sandbox-setup.sh` e `sandbox-setup-java-25.sh`
- `REQUISITI.md` (documento di design)

Note sul layout:

- le cartelle `original_codex/` e `other_implementation_example/` restano di sola lettura come riferimento;
- le copie attive, modificabili e usate dai comandi sono in `codex-cli/` e `codex-sandbox/` alla radice del repo.

---

## Funzionalità esportate
- Esecuzione Codex isolata sulla workdir passata allo script (`--work_dir`), con container dedicato e cleanup automatico.
- Hook di init configurabile via `--init_script`: esegue solo `/app$WORK_DIR/.codex/.environment/init.sh` se esiste ed è eseguibile, con artefatti isolati in `.codex/.environment` e variabile `SANDBOX_ENV_DIR` nel container.
- Configurazioni Codex su `/app$WORK_DIR/.codex/.environment` (montata come `/codex_home`): `config.toml` forzabile con `--config` (file oppure directory contenente `config.toml`, sovrascrive), altrimenti copiato dall’host se mancante; `auth.json` copiato solo se mancante (oppure forzato se presente nella directory passata a `--config`); sessioni dedicate nel container (default `.codex/.environment/sessions`, override `--sessions-path`, non clonate dall’host).
- Utente `codex` non-root nel container con piena lettura/scrittura sulla workdir montata.
- Firewall interno configurabile (`OPENAI_ALLOWED_DOMAINS`) con default deny e allowlist base per i domini OpenAI/ChatGPT; verifica di blocco e di reachability OpenAI; loopback sempre consentito, rete locale/gateway bloccati.
- Selezione immagine container via `CODEX_DOCKER_IMAGE` e default workdir via `WORKSPACE_ROOT_DIR`.
- Immagini pre-taggate per Node 18/20/22 (`build_node_variants.sh`), alias `codex-sandbox` su Node 22.
- Esempi di init inclusi (non auto-eseguiti): `sandbox-setup.sh` (Python/Maven/Node) e `sandbox-setup-java-25.sh` (JDK 25 locale al progetto).
- Mount multipli in sola lettura con `--read-only <path>` (ripetibile, file o directory, montati in `ro` su `/app<path>`); selezione/auto-upgrade versione Codex al runtime non ancora supportata (solo `CODEX_VERSION` in build).
- Protezione workdir: i percorsi passati a `--work_dir` vengono risolti e se risultano `/` vengono rifiutati (niente mount della root host nel container).
- Montare percorsi **writable** fuori dalla workdir (es. `--codex-home`, `--sessions-path`) richiede conferma interattiva e comporta l’esposizione in scrittura di quei path host al container: rispondi `y` solo se lo vuoi davvero.

## Prerequisiti

- Docker installato e funzionante.
- Accesso alla rete per costruire l’immagine (download pacchetti e `@openai/codex`).
- Una configurazione Codex esistente (tipicamente `~/.codex` con `auth.json`).

Non è necessario avere Codex CLI installato sull’host: viene installato nell’immagine `codex-sandbox`.

---

## Build dell’immagine `codex-sandbox`

Portati nella directory degli script attivi:

```bash
cd codex-cli/scripts
```

Build con versione di Codex CLI di default:

```bash
docker build -t codex-sandbox -f Dockerfile.codex-sandbox .
```

Build con una versione specifica di Codex CLI (es. `0.36.0`):

```bash
docker build \
  -t codex-sandbox:0.36.0 \
  -f Dockerfile.codex-sandbox \
  --build-arg CODEX_VERSION=0.36.0 .
```

Note:

- Il Dockerfile installa:
  - `@openai/codex@CODEX_VERSION` globalmente;
  - tool di sistema (`git`, `curl`, `dnsutils`, `python3`, `iptables`, `iproute2`, `ipset`, JDK 21 o fallback 17);
  - un utente non-root `codex` con `WORKDIR /workspace`.

---

## Script `run_in_container.sh`

Percorso: `codex-cli/scripts/run_in_container.sh`

Questo script:

1. Calcola la workdir da montare.
2. Risolve l'immagine Docker da usare per Codex CLI: puoi forzare una versione con `--codex-version` o `CODEX_VERSION`; se non la indichi, chiede a `npm view @openai/codex version` l'ultima release, prova `docker pull` del tag corrispondente o, in assenza, builda automaticamente `Dockerfile.codex-sandbox` con quel `CODEX_VERSION`.
3. Avvia un container `codex-sandbox` con:
   - mount della workdir su `/app$WORK_DIR`;
   - mount di `/app$WORK_DIR/.codex/.environment` come `/codex_home` (contenente config/auth/sessions del container);
   - capability di rete (`NET_ADMIN`, `NET_RAW`) per il firewall.
4. Scrive la lista di domini consentiti in `/etc/codex/allowed_domains.txt`.
5. Esegue `/usr/local/bin/init_firewall.sh` dentro il container.
6. Esegue, nella workdir container, `/app$WORK_DIR/.codex/.environment/init.sh` **solo se** esiste ed è eseguibile (tipicamente copiato lì da `--init_script`).
7. Avvia `codex --full-auto` con gli argomenti extra passati alla script.

### Uso base

Dal **root del tuo progetto**:

```bash
./codex-cli/scripts/run_in_container.sh
```

Comportamento:

- Usa come workdir la directory corrente (`$(pwd)`).
- Se non passi argomenti extra, esegue:

  ```bash
  codex --full-auto
  ```

  dentro il container, in `/app$WORK_DIR`.

### Uso con workdir specifica

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /percorso/del/progetto
```

Per passare argomenti extra a `codex`, aggiungili dopo `--work_dir`:

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /percorso/del/progetto \
  --model o3-mini \
  --tier pro
```

Nel container verrà eseguito:

```bash
codex --full-auto --model o3-mini --tier pro
```

### Uso con `.codex` in una posizione diversa (ma sempre dentro la workdir)

Per lasciare le credenziali/config in una cartella specifica del progetto diversa da `WORK_DIR/.codex`, ma sempre all’interno della workdir:

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /percorso/del/progetto \
  --codex-home /percorso/del/progetto/.segreti/codex
```

Se indichi un percorso fuori dalla workdir, lo script avvisa e chiede conferma (in non-interattivo rifiuta). Se non passi l’opzione, il default resta `WORK_DIR/.codex`.

### Uso con mount addizionali in sola lettura

Per condividere file o directory extra solo in lettura (anche fuori dalla workdir):

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /percorso/del/progetto \
  --read-only /percorso/dati \
  --read-only /etc/hosts
```

Ogni path viene validato sull'host, reso assoluto e montato in `ro` dentro il container preservando il riferimento: `/percorso/dati` diventa accessibile come `/app/percorso/dati`.

### Uso con selezione della versione Codex

Puoi specificare la versione della CLI da usare nel container, tramite flag o env (viene riutilizzata anche come tag dell'immagine). Se non la passi, lo script risolve la release più recente con `npm view`, prova a fare `docker pull <repo>:<version>` e, se necessario, builda l'immagine con quel `CODEX_VERSION`.

```bash
# flag esplicita
./codex-cli/scripts/run_in_container.sh --codex-version 0.36.0

# variabile d'ambiente equivalente
CODEX_VERSION=0.36.0 ./codex-cli/scripts/run_in_container.sh
```

Quando chiede l'ultima release (default, o `CODEX_VERSION=latest`), tenta comunque un `docker pull` anche se l'immagine è già presente, per aggiornare eventuali `:latest` locali.

---

## Variabili d’ambiente supportate

### `CODEX_DOCKER_IMAGE`

Immagine Docker da usare per il container (default: `codex-sandbox`):

```bash
CODEX_DOCKER_IMAGE=codex-sandbox:0.36.0 \
./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
```

### `WORKSPACE_ROOT_DIR`

Workdir di default quando non passi `--work_dir`:

```bash
WORKSPACE_ROOT_DIR=/percorso/default \
./codex-cli/scripts/run_in_container.sh
```

Se passi `--work_dir`, quest’ultima ha precedenza.

### `CODEX_VERSION` / `--codex-version`

Forza la versione della Codex CLI nel container. Viene usata come tag dell'immagine e come `--build-arg CODEX_VERSION` se l'immagine non esiste ed è necessario costruirla.

```bash
CODEX_VERSION=0.36.0 \
./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto

./codex-cli/scripts/run_in_container.sh --codex-version 0.36.0
```

Se non imposti la variabile/flag (o usi `latest`), lo script:

- chiede a `npm view @openai/codex version` l'ultima versione disponibile;
- prova a fare `docker pull <immagine>:<versione>` anche se l'immagine è già presente, per aggiornare eventuali tag `latest`;
- se l'immagine non esiste o non è disponibile in registry, la builda localmente usando `Dockerfile.codex-sandbox`.

### `OPENAI_ALLOWED_DOMAINS`

Lista di domini consentiti dal firewall, separati da spazi. Default (stack OpenAI/ChatGPT, già sufficiente per API + UI + login):

```bash
OPENAI_ALLOWED_DOMAINS="api.openai.com chat.openai.com chatgpt.com auth0.openai.com platform.openai.com openai.com"
```

Se imposti `OPENAI_ALLOWED_DOMAINS`, i domini che specifichi vengono **aggiunti** a quelli di default (non li sostituiscono). Per aggiungere altri domini (es. repository Maven, GitHub) puoi indicare solo gli extra:

```bash
OPENAI_ALLOWED_DOMAINS="repo.maven.apache.org github.com" \
./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
```

Lo script:

- valida ogni dominio con una regex;
- scrive `/etc/codex/allowed_domains.txt`;
- esegue `init_firewall.sh`, che:
  - risolve i domini in IP;
  - filtra gli IP privati/riservati dalle risoluzioni DNS (10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, 0.0.0.0/8, broadcast; ::1, fe80::/10, ff00::/8) e fallisce se restano solo quelli (override opt-in: `ALLOW_PRIVATE_DNS=1`);
  - configura iptables/ipset;
  - verifica che `https://example.com` sia **bloccato** e `https://api.openai.com` **raggiungibile**.
  - blocca la rete locale/gateway (resta permesso solo il loopback e i domini whitelisted).

### `CODEX_CONFIG_DIR`

Controlla **da dove** viene letta la configurazione Codex (incl. `auth.json`, `config.toml`) sul **tuo host**, poi la copia se mancante in `WORK_DIR/.codex/.environment/` e monta quella directory come `/codex_home` (con `CODEX_HOME=/codex_home`). Le sessioni non vengono copiate: il container usa un percorso dedicato (default `WORK_DIR/.codex/.environment/sessions`, override con `--sessions-path`). Puoi sovrascrivere il `config.toml` esplicitamente con `--config <file|dir_con_config.toml>`; se passi una directory con anche `auth.json`, verrà copiato (sovrascritto) anch’esso.

Se indichi `--codex-home` o `--sessions-path` fuori dalla workdir, lo script chiede conferma interattiva e ti ricorda che quel percorso host verrà esposto in scrittura al container: rispondi `y` solo se intendi davvero condividere quel path (rompe l’isolamento limitato alla workdir).

Ordine di ricerca per la sorgente host (usato solo se `--config` non è passato e il file è mancante):

1. `CODEX_CONFIG_DIR` (se esiste)
2. `$HOME/.codex` (default)
3. `$HOME/.config/codex`
4. `WORK_DIR/codex`
5. `WORK_DIR/.codex`

Esempi:

- Usare il default host (`~/.codex`):

  ```bash
  ./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
  ```

- Usare una config dedicata per il solo container:

  ```bash
  CODEX_CONFIG_DIR=/percorso/progetto/codex-config \
  ./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
  ```

- Config locale al progetto, senza toccare `~/.codex`:

  - crea la cartella nella workdir:

    ```bash
    mkdir -p /percorso/progetto/codex
    # copia dentro auth.json o intera dir da ~/.codex se vuoi
    ```

  - avvia:

    ```bash
    ./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
    ```

In questo caso lo script monta `/percorso/progetto/codex` come `/codex_home` e il tuo `~/.codex` host non viene usato.

---

## Hook di init

Lo script esegue un unico hook opzionale **solo se** è presente ed eseguibile `/app$WORK_DIR/.codex/.environment/init.sh`.

### Cosa viene lanciato

```bash
SANDBOX_ENV_DIR="/app$WORK_DIR/.codex/.environment"
cd "/app$WORK_DIR" && if [ -x "$SANDBOX_ENV_DIR/init.sh" ]; then "$SANDBOX_ENV_DIR/init.sh"; fi
codex --full-auto [eventuali argomenti...]
```

Non c’è fallback `bash`: il file deve essere eseguibile.

### Come popolare `init.sh`

- Passa `--init_script /percorso/script.sh`: lo copia in `.codex/.environment/init.sh` nella workdir e lo rende eseguibile.
- Oppure crea direttamente `.codex/.environment/init.sh` nella workdir (persistente tra esecuzioni) e rendilo eseguibile.

### Script di esempio

Alla radice del progetto trovi due **esempi** di init (`sandbox-setup.sh` per Python/Maven/Node e `sandbox-setup-java-25.sh` per installare un JDK 25 locale). Usali come hook esplicito oppure come base per il tuo script, ad esempio:

```bash
./codex-cli/scripts/run_in_container.sh \
  --work_dir /percorso/progetto \
  --init_script ./sandbox-setup.sh
```

Lo script di esempio `sandbox-setup.sh` è idempotente: se trova `requirements.txt` crea/attiva `.venv` e installa le dipendenze, se trova `pom.xml` esegue `mvn dependency:go-offline`, se trova `package.json` lancia `npm install`.

---

## Test firewall rules

`tests/test_firewall_rules.sh` simula l’esecuzione di `init_firewall.sh` con binari mockati e verifica che:

- loopback e DNS siano sempre aperti;
- i domini di `OPENAI_ALLOWED_DOMAINS` vengano risolti e aggiunti all’ipset `allowed-domains`;
- le policy predefinite siano DROP tranne il traffico verso gli IP autorizzati;
- `https://example.com` sia respinto e `https://api.openai.com` raggiungibile.

```bash
bash tests/test_firewall_rules.sh
```

---

## Gestione di `auth.json` e `config.toml`

### Caso: usare l’auth.json host, senza toccare la config globale

Se hai già fatto `codex login` sull’host e in `~/.codex` c’è un `auth.json` valido:

- puoi lasciare `CODEX_CONFIG_DIR` non impostata (default: `~/.codex`);
- oppure puntare a una directory dedicata contenente `auth.json`.

Nel container:
- `auth.json` viene copiato solo se manca in `WORK_DIR/.codex/.environment/`, oppure sovrascritto se è presente nella directory passata a `--config`.
- `config.toml` viene copiato solo se manca, oppure sovrascritto se passi `--config <file|dir_con_config.toml>`.
- Le sessioni sono sempre locali al container: default `WORK_DIR/.codex/.environment/sessions` (override `--sessions-path`).

Se vuoi **configurazioni diverse** solo per il container (es. `web_search_request` diverso), la cosa più pulita è:

1. Creare una directory dedicata, es.:

   ```bash
   mkdir -p /percorso/progetto/codex-config
   cp ~/.codex/auth.json /percorso/progetto/codex-config/
   ```

2. Creare lì un `config.toml` solo per il container, es.:

   ```toml
   # /percorso/progetto/codex-config/config.toml
   web_search_request = true
   ```

3. Avviare:

   ```bash
   CODEX_CONFIG_DIR=/percorso/progetto/codex-config \
   ./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
   ```

In questo modo:

- l’host continua a usare `~/.codex/config.toml` (se esiste);
- il container usa `/codex_home/config.toml` derivato da `/percorso/progetto/codex-config/config.toml`.

### Caso: config per progetto nella workdir

In alternativa puoi usare la cartella `codex/` dentro la workdir:

```bash
mkdir -p /percorso/progetto/codex
cp ~/.codex/auth.json /percorso/progetto/codex/
cat > /percorso/progetto/codex/config.toml << 'EOF'
web_search_request = true
EOF

./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
```

Lo script copierà il `config.toml` (se mancante) in `.codex/.environment/config.toml`, monterà `WORK_DIR/.codex/.environment` su `/codex_home` e userà sessioni locali alla cartella `.codex/.environment/sessions` (o quanto passato con `--sessions-path`).

---

## Abilitare le ricerche web dal container

Per poter effettuare ricerche internet da Codex dentro il container:

1. **Domini firewall**

   I domini OpenAI/ChatGPT necessari sono già whitelisted di default (`api.openai.com chat.openai.com chatgpt.com auth0.openai.com platform.openai.com openai.com`). `OPENAI_ALLOWED_DOMAINS` aggiunge domini extra senza rimuovere i default: se vedi errori verso altri host (repository, API esterne), aggiungili, ad esempio:

   ```bash
   OPENAI_ALLOWED_DOMAINS="repo.maven.apache.org github.com" \
   ./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
   ```

2. **Config Codex**

   Assicurati che nel `config.toml` usato dal container non ci sia:

   ```toml
   web_search_request = false
   ```

   e, se necessario, impostalo a `true` nel file di config dedicato al container (come descritto sopra).

---

## Flussi d’uso consigliati

### 1. “Sandbox veloce” con config host

- Usa `~/.codex` (auth + config) e la cartella attuale come workdir:

  ```bash
  ./codex-cli/scripts/run_in_container.sh
  ```

- Per aggiungere host extra oltre a quelli OpenAI/ChatGPT già whitelisted (gli extra vengono uniti ai default):

  ```bash
  OPENAI_ALLOWED_DOMAINS="repo.maven.apache.org" \
  ./codex-cli/scripts/run_in_container.sh
  ```

### 2. Config per progetto, separata dall’host

- Prepari `/percorso/progetto/codex-config` con `auth.json` e `config.toml` dedicati.
- Avvii:

  ```bash
  CODEX_CONFIG_DIR=/percorso/progetto/codex-config \
  ./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
  ```

### 3. Setup dipendenze automatico

- Tieni uno script di init nella root del progetto (puoi partire dall’esempio `./sandbox-setup.sh` o crearne uno tuo).
- Avvia passando l’hook: `./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto --init_script ./sandbox-setup.sh` (oppure prepara `.codex/.environment/init.sh` già eseguibile nella workdir).
- Lo script verrà eseguito prima di `codex`.

---

## Debug e note operative

- Ogni volta che lanci `run_in_container.sh`, viene creato un container dedicato alla workdir (`codex_<path_sanitized>`) e rimosso automaticamente alla fine (via `trap EXIT`).
- Se incontri errori di rete, controlla:
  - il contenuto di `/etc/codex/allowed_domains.txt` nel container (`docker exec` + `cat`);
  - i log del container (`docker logs <nome_container>`).
- Il wrapper non tocca la tua installazione di Codex sull’host (se presente): tutto avviene nell’immagine `codex-sandbox`.

Per i dettagli di design e requisiti, vedi `REQUISITI.md`.
