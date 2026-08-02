-- Configuration + verdict thresholds.
local M = {}

-- aegis verdicts, weakest to strongest. `fail_on` names the weakest verdict
-- that still blocks, so fail_on="block" blocks only outright-malicious.
M.VERDICTS = { "safe", "review", "prompt", "block" }

M.RANK = {}
for i, v in ipairs(M.VERDICTS) do
  M.RANK[v] = i
end

---@class AegisConfig
M.defaults = {
  -- aegis-cli binary. Absolute path is fine.
  bin = "aegis",

  -- Weakest verdict that blocks. safe|review|prompt|block.
  --
  -- "prompt" rather than "block" on purpose. aegis scores a Lua tree from its
  -- capabilities, and the block tier (>=100) is realistically only reached by
  -- a malicious build hook. A plugin that shells out, evals a downloaded
  -- payload, reads credentials from the environment and talks to a raw IP
  -- scores 75 — "prompt", aegis's own word for "a human has to say yes".
  -- `:Aegis approve` is that yes, pinned to the exact commit.
  fail_on = "prompt",

  -- Gates. Each can be disabled independently while you tune the policy.
  gates = {
    clone = true, -- new plugin: scan before the pipeline continues
    update = true, -- update: scan the target tree before it hits the worktree
    build = true, -- never run a build hook for an unapproved tree
    load = true, -- never add an unapproved plugin to runtimepath
  },

  -- Clone the repo into a throwaway dir and scan it there, so an unapproved
  -- tree never touches plugin.dir at all. Costs one extra shallow fetch.
  strict_clone = false,

  -- Applied to lazy's own options by require("aegis").lazy_opts().
  harden = {
    pkg = true, -- refuse repo-authored lazy.lua / rockspec / packspec specs
    rocks = true, -- refuse luarocks builds
    submodules = true, -- clone without --recurse-submodules
    require_https = true, -- reject git:// http:// and other plaintext remotes
    allowed_hosts = {}, -- empty = any host; e.g. { "github.com" }
  },

  -- What to do when we cannot get a verdict at all.
  on_missing_scanner = "warn", -- "warn" (allow) | "block"
  on_scan_error = "block", -- "allow" | "block"

  -- Load gate, plugin installed before aegis ever saw it. "block" here on a
  -- cold cache would refuse your whole config on first run, so the default is
  -- to allow once, scan in the background, and enforce from the next startup.
  -- Flip to "block" after a `:Aegis scan` has warmed the cache.
  load_unknown = "allow", -- "allow" | "block"

  -- Include file:line evidence in stored reports. Costs nothing at runtime,
  -- makes `:Aegis report` useful.
  evidence = true,

  -- Scanner timeout per plugin, ms.
  timeout = 120000,

  notify = true,

  -- Verdict cache, approvals and reports live here.
  state_dir = nil, -- default: stdpath("state")/aegis-nvim
}

---@type AegisConfig
M.options = nil

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  if not M.RANK[M.options.fail_on] then
    error(("aegis.nvim: fail_on must be one of %s"):format(table.concat(M.VERDICTS, "|")))
  end

  M.options.state_dir = M.options.state_dir
    or vim.fs.joinpath(vim.fn.stdpath("state"), "aegis-nvim")

  return M.options
end

-- Config access before setup() is a bug in the caller, but returning defaults
-- beats throwing from inside a gate that is mid-install.
function M.get() return M.options or M.setup({}) end

return M
