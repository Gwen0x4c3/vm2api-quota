# vm2api-quota

A Claude Code / ZCode plugin marketplace hosting **vm2api-quota** — type `/quota` to query the current account's 5h/7d usage quota, per-account pool quotas, and billing totals from a [vm2api](https://github.com/dofastted/vm2api) gateway. **Read-only** (only `GET` requests) and **zero LLM involvement** (see [vm2api-quota/README.md](./vm2api-quota/README.md)).

## Install

Replace `Gwen0x4c3/vm2api-quota` with the actual published repo, or use a local checkout path.

**Option A — inside Claude Code / ZCode (slash commands):**

```
/plugin marketplace add Gwen0x4c3/vm2api-quota
/plugin install vm2api-quota@vm2api-plugins
```

**Option B — from the shell (Claude Code CLI):**

```sh
claude plugin marketplace add Gwen0x4c3/vm2api-quota
claude plugin install vm2api-quota@vm2api-plugins
```

**Option C — UI path:** Plugin Marketplace → Add → Add Plugin Marketplace, paste this repo (or a local directory), then install **vm2api Quota**.

Local checkout instead of GitHub: point `marketplace add` at this directory, e.g. `/plugin marketplace add /path/to/this-repo`.

## Use

Type one of these as a prompt in any session:

- `/quota` — human-readable report (progress bars, status tags, USD estimates, reset countdowns).
- `/quota --json` — raw JSON: `{ "usage": …, "pool": …, "billing": … }`.

The input is intercepted and executed locally: the report prints to your terminal, and **no model request is ever made** — nothing enters the LLM context.

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

## macOS menu bar app (bonus)

`menubar/` holds a **native SwiftUI menu-bar app** (single file, no Xcode project) built as a lightweight menu-bar utility:

- **Menu bar**: `89 18` — 5h then optional 7d usage percentages, colored by severity (green → yellow → orange → red; red = close to the limit, `⚠` on WARN/BLOCKED). The 7d number can be turned off in settings; hover for a tooltip naming each window.
- **Click** opens a compact popover (440 pt): a header with a health capsule (Healthy / Warning / Blocked), two usage cards (big percentage + capsule bar, fill = usage, reset countdown, USD estimate), billing with hierarchy (Today large, 5h/7d windows as secondary rows), and Quality of Service (summary row with success rate, expandable Details: error rate with 429/503/529, TTFT and duration percentiles, QPS/TPS, cache hit, sticky sessions, per-model rows — same `/api/panel/request-logs/stats` window the console overview renders). The per-account pool section appears only when there is more than one account, avoiding duplication.
- Auto-refresh every 60 s, manual refresh button, read-only GETs only.
- **Configuration is built in**: click the gear (⚙) in the popover — or it opens automatically on first run — and enter the gateway URL, API key, and optional panel token. Stored in the app's own file `~/.config/vm2api-quota/menubar.json` (0600). A master key covers both `/v1` and panel routes.

```sh
cd menubar
./build.sh                    # -> bin/VmQuotaBar
./bin/VmQuotaBar              # run directly
./build.sh --app              # or build a proper .app bundle
open bin/VmQuotaBar.app       #   and launch it (login item: add in System Settings)
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Manage

```
/plugin                                  # open the plugin manager UI
/plugin marketplace update vm2api-plugins
/plugin marketplace remove vm2api-plugins
claude plugin list                       # CLI: installed plugins
claude plugin uninstall vm2api-quota@vm2api-plugins
```

## Credentials & configuration

Nothing is hardcoded — each machine uses its own config. Resolution: **runtime config file → plugin userConfig → env vars → `~/.claude/settings.json` → defaults**.

- On install/enable, the plugin prompts for optional **userConfig**: `base_url`, `master_key`, `panel_token` (sensitive values stored in secure storage, not plaintext).
- Runtime subcommands (also hook-intercepted, zero LLM):
  ```text
  /quota config                    show effective config (masked)
  /quota set api-key <KEY>         store master/api key (alias: master-key)
  /quota set panel-token <TOKEN>   store panel credential
  /quota set base-url <URL>        store gateway URL
  /quota unset <item>
  ```
- Plain env vars still work: `VM2API_BASE_URL` / `ANTHROPIC_BASE_URL`, `VM2API_API_KEY` / `ANTHROPIC_AUTH_TOKEN`, `VM2API_PANEL_TOKEN`.
- Master key tip (Docker): it is the gateway container's `VM2API_API_KEY` env — `docker exec vm2api printenv VM2API_API_KEY` (container usually named `vm2api`; check with `docker ps`). A master key unlocks the pool/billing sections on both `/v1` and panel routes.

See [vm2api-quota/README.md](./vm2api-quota/README.md) for endpoint details and the full resolution order.
