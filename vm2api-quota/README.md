# vm2api-quota

`/quota`: query the current account's **5h / 7d** usage quota, plus **per-account pool quotas**, from a vm2api gateway. **Read-only** — it only issues `GET` requests and never mutates anything.

It is implemented as a **UserPromptSubmit hook**, not a prompt template: typing `/quota` in a session is intercepted locally, the script runs, the report is printed to your terminal, and the prompt is blocked — **the model never sees it and nothing enters the LLM context**.

## Configuration

Resolution order (highest → lowest):

1. **Runtime config file** — `~/.config/vm2api-quota/config.json` (created by `/quota set`, permissions 0600)
2. **Plugin userConfig** — prompted when the plugin is enabled (`base_url`, `master_key`, `panel_token`; sensitive values live in secure storage and reach the hook as `CLAUDE_PLUGIN_OPTION_*` env vars)
3. **Environment variables** — `VM2API_BASE_URL` / `ANTHROPIC_BASE_URL`, `VM2API_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`, `VM2API_PANEL_TOKEN`
4. **`~/.claude/settings.json`** — `.env.ANTHROPIC_BASE_URL` / `.env.ANTHROPIC_AUTH_TOKEN` / `.env.ANTHROPIC_API_KEY`
5. **No defaults** — the gateway URL must come from one of the sources above; the report errors out with a hint if nothing is configured.

### Bare `/quota` (optional, one-time)

Plugin commands are always namespaced (`/vm2api-quota:quota`). To get the bare `/quota`, run once:

```text
/vm2api-quota:quota setup-bare
```

This creates the personal command `~/.claude/commands/quota.md` (personal commands are not namespaced). Reload plugins or restart the session, then `/quota`, `/quota --json`, `/quota config`, `/quota set …` all work, still intercepted by the hook with zero LLM involvement. Delete the file (or `setup-bare --force` to overwrite) to remove it.

### Runtime subcommands

```text
/quota config                          show effective config (masked) and sources
/quota set   base-url    <URL>         store gateway URL
/quota set   api-key     <KEY>         store master/api key (alias: master-key)
/quota set   panel-token <TOKEN>       store panel credential
/quota unset base-url|api-key|master-key|panel-token
```

Like the report itself, these are intercepted by the hook and executed locally — no model involvement.

The panel credential can be any `/api/panel/*` credential: the gateway's **master API key** (the same `VM2API_API_KEY` the server itself uses) or a **console session token** issued by `POST /api/panel/login`. A plain `sk-vm-…` key cannot read panel endpoints — the gateway answers `403 forbidden` for those routes. A configured master key doubles as the panel credential automatically.

### Finding the master key

`VM2API_API_KEY` is the gateway's own environment variable, set on the machine running vm2api. It is not issued by the console and never leaves the server config, so read it on the gateway host:

- **Docker deployment** — the container is usually named `vm2api` (confirm with `docker ps`):

  ```sh
  docker ps                                  # find the vm2api container name
  docker exec vm2api printenv VM2API_API_KEY
  ```

- **Bare metal / compose** — grep the env or compose file next to the vm2api install (commonly `/opt/vm2api`):

  ```sh
  grep -rn "VM2API_API_KEY" /opt/vm2api/.env* /opt/vm2api/docker-compose*.yml 2>/dev/null
  ```

Then store it on the client machine once — `/quota set api-key <master-key>` (or the namespaced `/vm2api-quota:quota set api-key …`). A master key authorizes both `/v1` and panel routes, so the pool and billing sections light up; no separate panel token is needed.

## Data sources (verified 2026-11-04)

- **`GET {base}/v1/usage?unit=percent_used`** (used for the current account; auth: `Authorization: Bearer sk-vm-…`). Response:

  ```json
  {
    "unit": "percent_used",
    "five_hour": { "utilization": 98, "status": "allowed_warning", "resets_at": "1793794200" },
    "seven_day": { "utilization": 58, "status": "allowed", "resets_at": "1793793600" },
    "source": "extra",
    "platform": "anthropic"
  }
  ```

  `resets_at` is a Unix timestamp in seconds (string).

- **`GET {base}/api/panel/vms`** (used for per-account pool quotas; auth: panel session token or master key). This is what the `/console#/vm` page requests. Relevant fields: `data.items[]` with `id`, `name`, `email`, `utilization_5h`/`utilization_7d` (**ratio 0–1**, unlike `/v1/usage` percent), `reset_5h`/`reset_7d`, `status_5h`/`status_7d`, and `estimate_5h`/`estimate_7d` USD figures (`spent_usd` / `total_usd` / `remaining_usd`).

- **`GET {base}/api/panel/usage`** (used for the billing summary; auth: panel session token or master key). Fields used: `data.billing.source`, `data.billing.currency`, `data.billing.today`, `data.billing.window_5h`, `data.billing.total` (cost and request counts per window).

- Other console endpoints (not used by the plugin, kept for reference):
  - `GET /api/panel/pool/stream` — SSE stream that pushes live per-account pool state.
  - `GET /api/panel/dashboard` — aggregate dashboard; also embeds per-VM quota in `data.vms[]`.

## Install

From the marketplace hosting this plugin (repo `Gwen0x4c3/vm2api-quota`, marketplace name `vm2api-plugins`):

```
/plugin marketplace add Gwen0x4c3/vm2api-quota   # or a local checkout directory
/plugin install vm2api-quota@vm2api-plugins
```

Shell equivalent: `claude plugin marketplace add …` and `claude plugin install vm2api-quota@vm2api-plugins`. A restart or `/reload-plugins` picks up local edits.

## Usage

Type any of these as a prompt in a session (they are intercepted before the model sees anything):

- `/quota` — human-readable report (progress bars, status tags, USD estimates, reset countdowns). Registered programmatically via the hooks-module JS API (`$.command.register`), so it works as a **bare** command on hosts that support JS hook modules.
- `/quota --json` — raw JSON: `{ "usage": …, "pool": …, "billing": … }`.
- `/quota config` — show effective configuration (masked).
- `/quota set <item> <value>` / `/quota unset <item>` — runtime configuration (see below).
- `/vm2api-quota:quota` — namespaced entry point, always available (falls back to the shell UserPromptSubmit hook on hosts without JS module support).

The report goes to your terminal only. Non-matching prompts pass through untouched.

## Example output

```text
❯ /quota
  ⎿  vm2api-quota: === vm2api quota @ http://192.0.2.10:8787 ===
     Current account (platform: anthropic, source: extra)
     5h window: [███████████·]  98%  [WARN]  resets 2026-11-04 20:10:00 CST (in 44m)
     7d window: [██████······]  58%  [OK]  resets 2026-11-04 20:00:00 CST (in 34m)

     === Per-account quota (pool) ===
     - vm-01 (01)
       5h window: [███████████·]  98%  [WARN]  resets 2026-11-04 20:10:00 CST (in 44m)  est $21.11/21.54
       7d window: [██████······]  58%  [OK]  resets 2026-11-04 20:00:00 CST (in 34m)  est $136.05/234.58

     === Billing ===
     source: anthropic-official (USD)
     today   $50.04  (333 req, since 2026-11-03T16:00:00.000Z)
     5h win  $21.11  (104 req, since 2026-11-04T06:49:26.589Z)
     7d win  $136.05  (966 req)
```

```text
❯ /quota config
  ⎿  vm2api-quota: === vm2api-quota config ===
     config file : /home/you/.claude/vm2api-quota-config.json
     gateway url : http://192.0.2.10:8787   [effective]
     api key     : mk-9f3c1a7d…(64 ch)  [effective]
     panel token : mk-9f3c1a7d…(64 ch)  [effective]

     stored in config file:
       base-url    : <not set>
       api-key     : mk-9f3c1a7d…(64 ch)
       panel-token : <not set>
```

(Account emails/UUIDs never appear in the report; credentials are always masked.)

## Data footprint

- Nothing ever enters the LLM context: the hook prints the report to your terminal and blocks the prompt, so no model request contains any of this data.
- The output contains **no credentials** (API keys and tokens are never printed). Default output also omits account emails/UUIDs; full identifiers appear **only** in `--json` output (opt-in, still terminal-only).
- Status meanings: `allowed` / `active` = normal; `allowed_warning` = near the limit; `blocked` / `throttled` = the gate has cut this window off.
