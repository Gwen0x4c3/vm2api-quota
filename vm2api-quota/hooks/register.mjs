// hooks/register.mjs — registers the BARE `/quota` command via the hooks-module
// JS API (the "mods" mechanism), and executes scripts/quota.sh through the
// sandboxed $.process.run (no shell, argument list). The script does the HTTP
// GETs itself, so this module stays a thin adapter — a single source of truth
// for report/config logic. Returns the script output as command text: no model
// turn, nothing enters the LLM context.
//
// Sandbox rules honored: no imports at all; $.env.get takes a LITERAL variable
// name; no globals like fetch (use $.http / $.process APIs instead).
//
// Fallbacks: if this module cannot load on some host, the namespaced
// /vm2api-quota:quota command + the shell UserPromptSubmit hook provide the
// same zero-LLM behavior.

function scriptFromModule() { // <plugin>/hooks/register.mjs -> <plugin>/scripts/quota.sh
  try {
    const p = decodeURIComponent(String(import.meta.url).replace(/^file:\/\//, ''))
    return p.replace(/\/hooks\/[^/]*$/, '/scripts/quota.sh')
  } catch {
    return ''
  }
}

async function locateScript($) {
  const direct = scriptFromModule()
  try {
    if (direct && (await $.fs.exists(direct))) return direct
  } catch {}
  // fallback: plugin cache dir, newest version first
  try {
    const home = (await $.env.get('HOME')) || ''
    const root = home + '/.claude/plugins/cache/vm2api-plugins/vm2api-quota'
    const entries = await $.fs.list(root)
    const versions = entries.filter((e) => e && e.kind !== 'file').map((e) => e.name).sort()
    for (let i = versions.length - 1; i >= 0; i--) {
      const p = root + '/' + versions[i] + '/scripts/quota.sh'
      if (await $.fs.exists(p)) return p
    }
  } catch {}
  return ''
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    try {
      await $.command.register({
        name: 'quota',
        description: 'vm2api 5h/7d usage quota — executed locally, no model involvement',
        argumentHint: '[--json | config | set <item> <value> | unset <item> | setup-bare]',
        immediate: true,
      })
    } catch {
      // bare name unavailable: /vm2api-quota:quota remains the entry point.
    }
    return next(e)
  })

  on('command.run', { command: ['quota'] }, async ($, e) => {
    const args = String(e.args || '').trim().split(/\s+/).filter(Boolean)
    const script = await locateScript($)
    if (!script) {
      return { text: 'quota: could not locate scripts/quota.sh; run /vm2api-quota:quota instead' }
    }
    try {
      const r = await $.process.run(['bash', script, ...args])
      const text = String((r && r.stdout) || '').trim()
        || String((r && r.stderr) || '').trim()
        || '(no output)'
      return { text }
    } catch (err) {
      return { text: 'quota failed: ' + (err && err.message ? err.message : String(err)) }
    }
  })
}
