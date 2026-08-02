# aegis.nvim

Supply-chain gate for [lazy.nvim](https://github.com/folke/lazy.nvim), backed by
[aegis-cli](https://github.com/qwexvf/aegis-cli).

Every point where a plugin repository can get its own code executed is gated on
an aegis verdict for that exact commit. A plugin that fails the policy is not
warned about after the fact — it does not get cloned, checked out, built, or
added to `runtimepath`.

```
:Lazy install                        :Lazy update
  git.clone                            git.fetch          objects only, worktree untouched
  └─ AEGIS scan ───── block ─┐         git.checkout
  git.checkout               │         └─ AEGIS scan target ── block ─┐   worktree never moves
  plugin.docs                │         plugin.docs                    │
  plugin.build               │         plugin.build                   │
  └─ AEGIS re-check ── block ┤         └─ AEGIS re-check ──── block ───┤
                             │                                        │
startup                      │                                        │
  defaults.cond              │                                        │
  └─ AEGIS cached verdict ── block ─── plugin never reaches runtimepath ┘
```

## Why the gates sit where they do

Cloning a repository does not execute anything. Four things do, and each has a
gate or is switched off outright:

| Execution path | When | Handled by |
|---|---|---|
| `plugin.build` — shell strings, `build.lua`, `:cmd` | after install/update | build gate |
| `plugin/`, `ftdetect/`, `after/plugin/` auto-sourcing | when lazy adds the dir to `runtimepath` | load gate (`defaults.cond`) |
| lazy reading the repo's own `lazy.lua` / rockspec / packspec to build a spec | during spec resolve, **before install** | `pkg.enabled = false` |
| luarocks build scripts | install | `rocks.enabled = false` |
| submodule URLs (`ext::` RCE on older git) | fetched *during* clone | `defaults.submodules = false` |

The last three are not gated, they are removed. They run repo-authored code
earlier than any scan could see it, so there is nowhere to put a check.

## Requirements

- Neovim 0.10+
- lazy.nvim
- `aegis` on `PATH` — `aegis analyze --ecosystem neovim` must work

## Install

aegis.nvim has to be on `runtimepath` before `lazy.setup()` runs, so it is
bootstrapped next to lazy itself rather than managed by it.

```lua
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local aegispath = vim.fn.stdpath("data") .. "/lazy/aegis.nvim"

for path, url in pairs({
  [lazypath] = "https://github.com/folke/lazy.nvim.git",
  [aegispath] = "https://github.com/qwexvf/aegis.nvim.git",
}) do
  if not vim.uv.fs_stat(path) then
    vim.fn.system({ "git", "clone", "--filter=blob:none", url, path })
  end
end
vim.opt.rtp:prepend(aegispath)
vim.opt.rtp:prepend(lazypath)

require("aegis").setup({})

require("lazy").setup(spec, require("aegis").lazy_opts({
  -- your usual lazy options
}))
```

`lazy_opts()` is what wires everything in. Passing your options through it is
not optional — without it the hardening and the load gate are absent, and
`:checkhealth aegis` will say so.

To let `:Lazy update` keep aegis.nvim itself current, add a matching spec that
points at the bootstrap clone:

```lua
{ "qwexvf/aegis.nvim", dir = aegispath },
```

## Configuration

Defaults:

```lua
require("aegis").setup({
  bin = "aegis",
  fail_on = "prompt",          -- safe | review | prompt | block

  gates = {
    clone = true,
    update = true,
    build = true,
    load = true,
  },

  strict_clone = false,        -- scan in a throwaway clone first

  harden = {
    pkg = true,
    rocks = true,
    submodules = true,
    require_https = true,
    allowed_hosts = {},        -- e.g. { "github.com" }
  },

  on_missing_scanner = "warn", -- "warn" | "block"
  on_scan_error = "block",     -- "allow" | "block"
  load_unknown = "allow",      -- "allow" | "block"

  evidence = true,
  timeout = 120000,
  notify = true,
  state_dir = nil,             -- default stdpath("state")/aegis-nvim
})
```

### `fail_on` defaults to `prompt`, not `block`

aegis scores a Lua tree from the capabilities it finds: `shell-spawn` 20,
`dynamic-eval` 25, `fs-write-outside-root` 15, `raw-ip-literal` 15. Verdict
tiers are review ≥21, prompt ≥61, block ≥100.

A plugin that shells out, evals a downloaded payload, reads credentials from
the environment and talks to a hardcoded IP scores **75** — `prompt`, not
`block`. For a Lua-only plugin the block tier is realistically only reached via
a malicious build hook (`install-hook-suspicious`, weight 70). Gating on
`block` would therefore let the interesting cases through, so the default is
`prompt`: aegis's own word for "a human has to say yes". `:Aegis approve` is
that yes.

**Expect real plugins to trip this.** Measured against current upstream HEAD:

| Plugin | Verdict | Risk | Under the default |
|---|---|---|---|
| plenary.nvim | review | 40 | allowed |
| mason.nvim | review | 40 | allowed |
| telescope.nvim | review | 45 | allowed |
| which-key.nvim | review | 60 | allowed |
| gitsigns.nvim | prompt | 75 | **needs approval** |
| LuaSnip | prompt | 80 | **needs approval** |

Nothing is wrong with gitsigns or LuaSnip — they genuinely eval, read the
environment and ship native artifacts, and the scanner is right to say so. The
point of the default is that you look once, `:Aegis approve`, and then find out
if that ever changes.

If that trade is not the one you want, `fail_on = "block"` reduces this to
build-hook malware only.

### `load_unknown` starts permissive

On a cold cache, `load_unknown = "block"` would refuse your entire config on
first run. The default allows uncached plugins once, scans them in the
background, and enforces from the next startup. Once `:Aegis scan` has warmed
the cache, set it to `"block"`.

### `strict_clone`

Off by default. When on, a new plugin is cloned into a throwaway directory and
scanned there, so a rejected tree never occupies `plugin.dir` at all. Costs one
extra shallow fetch per new plugin.

With it off, the tree does land in `plugin.dir` before the scan — but nothing
has executed at that point (checkout, helptags and build all come later, and
`runtimepath` is untouched), and a rejected clone is deleted.

## Commands

| Command | Effect |
|---|---|
| `:Aegis` / `:Aegis status` | verdict, risk and capabilities per plugin |
| `:Aegis scan` | scan every plugin (`:Aegis! scan` ignores the cache) |
| `:Aegis scan <plugin>` | scan one |
| `:Aegis report <plugin>` | risk flags and `file:line` evidence |
| `:Aegis approve <plugin>` | allow the installed commit, and only that commit |
| `:Aegis revoke <plugin>` | drop an approval |
| `:Aegis clear` | clear the verdict cache, keep approvals |
| `:checkhealth aegis` | confirm the gates and hardening are actually wired |

Approvals are pinned to a commit sha. The next update moves the sha, the
approval stops applying, and the new tree is gated again.

## What this does not protect you from

- **A plugin aegis scores as benign.** This is static capability analysis, not
  proof of safety. Novel obfuscation, logic bombs, and malice expressed in
  ordinary-looking API calls all pass.
- **A compromised scanner.** `aegis` parses hostile input on your machine. Run
  it sandboxed if that matters to you: `bwrap --unshare-all --ro-bind ...`.
- **Your own config.** `init.lua`, and the `config`/`init`/`opts` functions in
  your specs, are yours and are never scanned.
- **Anything installed before adoption, until the cache is warm.** See
  `load_unknown`.
- **Non-lazy plugin managers.** For `vim.pack`, use
  [pakku.nvim](https://github.com/qwexvf/pakku.nvim), which has the same
  aegis integration.
- **A gate that is disabled.** `:checkhealth aegis` tells you which are live.

## Tests

```sh
tests/run.sh          # all
tests/run.sh 03       # one
```

Real nvim, real lazy.nvim, real aegis, real git repos over `file://`. Nothing
is mocked — each test asserts the malicious fixture is actually stopped:

| Suite | Asserts |
|---|---|
| `01_clone_gate` | malicious plugin is removed from the plugin root |
| `02_build_gate` | its build hook never runs, a clean plugin's does |
| `03_update_gate` | a plugin that goes bad on update never moves its worktree |
| `04_load_gate` | an already-installed bad tree never reaches `runtimepath` |
| `05_hardening` | `lazy_opts()` closes pkg/rocks/submodules, remote policy holds |
| `06_strict_clone` | a rejected tree never occupies `plugin.dir` |
| `07_approval_recovery` | a refused plugin can still be inspected and approved |

lazy.nvim is fetched into a cache dir on first run; point `AEGIS_TEST_LAZY` at
an existing checkout to skip that.

CI runs stylua and luacheck on every push. The e2e suite needs the `aegis`
binary, which currently lives in a private repo — public runners cannot fetch
it, so that job emits a "skipped" warning rather than failing. **Run
`tests/run.sh` locally before trusting a green CI badge on this repo.**

## License

MIT
