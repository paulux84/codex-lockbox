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
- Configurazioni Codex su `/app$WORK_DIR/.codex/.environment` (montata come `/codex_home`): `config.toml` forzabile con `--config` (file oppure directory contenente `config.toml`, sovrascrive), altrimenti copiato dall’host se mancante; `auth.json` resta sul path host (es. `~/.codex`, directory passata a `--config` o valore esplicito `--auth_file` / `CODEX_AUTH_FILE`) e viene montato in sola lettura come `/codex_home/auth.json`; sessioni dedicate nel container (default `.codex/.environment/sessions`, override `--sessions-path`, non clonate dall’host).
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

Puoi anche creare un file `allowed_domains.txt` dentro la cartella `--codex-home` (default: `WORK_DIR/.codex/allowed_domains.txt`): ogni riga può contenere uno o più domini separati da spazi. L’ordine di merge è:

1. domini di default;
2. domini dal file `allowed_domains.txt` (se esiste; righe vuote o che iniziano con `#` sono ignorate);
3. `OPENAI_ALLOWED_DOMAINS` (se impostata) che ha priorità e viene applicata per ultima.

I domini risultanti vengono uniti senza duplicati. Per aggiungere altri domini (es. repository Maven, GitHub) puoi indicare solo gli extra nell’`allowed_domains.txt` oppure con l’env:

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

## Sicurezza della rete e firewall

- Il firewall di `init_firewall.sh` imposta policy `DROP` su INPUT/OUTPUT/FORWARD e consente in uscita solo il traffico DNS verso resolver pubblici e il traffico verso il proxy (Squid interno o proxy esterno configurato con `PROXY_IP_V4/PROXY_IP_V6` e `PROXY_PORT`); nessuna connessione diretta può uscire senza passare dal proxy.
- Modalità selezionabile da `run_in_container.sh` con `--firewall proxy|acl` (default `proxy`): in modalità `proxy` usa Squid e iptables minimali; in modalità `acl` il proxy non viene usato e l’uscita è limitata via iptables/ipset ai domini consentiti.
- Squid, quando avviato automaticamente, si collega alla rete dedicata `codex_net_*` e applica ACL `allowed_sites` basate su `allowed_domains.txt` (domini OpenAI di default più eventuali extra). Sono bloccati i metodi CONNECT verso domini non consentiti e le reti private IPv4/v6; tutto il resto è negato.
- Il loopback (`-i lo`/`-o lo`) e le connessioni ESTABLISHED/RELATED restano aperte, così i processi nel container continuano a comunicare fra loro e con servizi locali.
- Il container Codex gira con `--cap-drop=ALL` e `--security-opt no-new-privileges`; le regole iptables vengono applicate da un container separato con `NET_ADMIN`/`NET_RAW` sulla stessa network namespace (`docker run --network container:$CONTAINER_NAME`), evitando che Codex possa modificare il firewall.

### `CODEX_CONFIG_DIR`

Controlla **da dove** viene letta la configurazione Codex (incl. `auth.json`, `config.toml`) sul **tuo host**: `config.toml` viene copiato se mancante in `WORK_DIR/.codex/.environment/` e la cartella risultante viene montata come `/codex_home` (con `CODEX_HOME=/codex_home`). L’`auth.json`, invece, **non** viene più copiato: lo script cerca un file valido seguendo lo stesso ordine delle sorgenti (`--auth_file`/`CODEX_AUTH_FILE`, directory passata con `--config`, `CODEX_CONFIG_DIR`, `~/.codex`, ecc.) e, quando trovato, lo monta in **sola lettura** come `/codex_home/auth.json`. In questo modo il token resta fuori dalla workdir. Le sessioni non vengono copiate: il container usa un percorso dedicato (default `WORK_DIR/.codex/.environment/sessions`, override con `--sessions-path`). Puoi sovrascrivere il `config.toml` esplicitamente con `--config <file|dir_con_config.toml>`.

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
    # opzionale: metti qui auth.json o punta a un path esterno con --auth_file
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

### `auth.json`: resta fuori dalla workdir

- Lo script **non** copia più il token dentro `WORK_DIR/.codex/.environment`.
- L’ordine di ricerca è: `--auth_file <path>` (o env `CODEX_AUTH_FILE`), directory passata a `--config`, `CODEX_CONFIG_DIR`, `~/.codex`, `$HOME/.config/codex`, `WORK_DIR/codex`, `WORK_DIR/.codex`, infine un eventuale `WORK_DIR/.codex/.environment/auth.json` già presente.
- Appena trova un file valido, lo monta in **sola lettura** come `/codex_home/auth.json`. In questo modo puoi tenere le credenziali sotto `~/.codex` (o in qualunque altra cartella fuori dalla workdir) senza esporle all’AI.
- Se non trova nulla, Codex nel container mostrerà il prompt di login standard e potrai autenticarti direttamente lì.

Esempi:

```bash
# usare il token globale host
./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto

# puntare a un file dedicato fuori dalla workdir
./codex-cli/scripts/run_in_container.sh \
  --work_dir /percorso/progetto \
  --auth_file /percorso/segreto/auth.json

# variante con variabile d'ambiente
CODEX_AUTH_FILE=/percorso/segreto/auth.json \
./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
```

### `config.toml`: copia nella sandbox

- `config.toml` continua a essere copiato (se mancante) in `WORK_DIR/.codex/.environment/config.toml` e montato come `/codex_home/config.toml`.
- Per differenziare le impostazioni del container rispetto all’host, prepara una directory dedicata (anche fuori dalla workdir), metti lì `config.toml` e, se vuoi, anche un `auth.json` (che verrà montato in ro da quel percorso). Poi avvia passando `CODEX_CONFIG_DIR=/path/dedicato` o `--config /path/dedicato`.
- Se preferisci una config locale al progetto puoi usare `WORK_DIR/codex/`, sapendo che tutto ciò che metti lì rimane accessibile nella workdir host.

Esempio con directory dedicata:

```bash
mkdir -p /percorso/progetto/codex-config
# facoltativo: copia un auth.json dedicato
cp ~/.codex/auth.json /percorso/progetto/codex-config/
cat > /percorso/progetto/codex-config/config.toml <<'EOF'
web_search_request = true
EOF

CODEX_CONFIG_DIR=/percorso/progetto/codex-config \
./codex-cli/scripts/run_in_container.sh --work_dir /percorso/progetto
```

In questo modo l’host continua a usare il proprio `~/.codex/config.toml`, mentre il container userà `/codex_home/config.toml` derivato dalla directory dedicata e il relativo `auth.json` verrà montato in sola lettura dal medesimo percorso.

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
