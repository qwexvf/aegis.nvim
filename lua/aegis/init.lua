-- aegis.nvim — supply-chain gate for lazy.nvim.
--
-- Every point where a plugin repo can get its code executed is gated on an
-- aegis verdict for that exact commit:
--
--   clone    a new plugin is scanned before its pipeline continues
--   update   the incoming commit is scanned before it reaches the worktree
--   build    build hooks never run for an unapproved tree
--   load     an unapproved tree never reaches runtimepath
--
-- Plus hardening applied to lazy itself (see lazy_opts): repo-authored spec
-- files and luarocks builds are refused outright, because both execute code
-- from the repo before any gate could see it.
local Cache = require("aegis.cache")
local Config = require("aegis.config")
local Gate = require("aegis.gate")
local Git = require("aegis.git")
local Policy = require("aegis.policy")
local Scan = require("aegis.scan")
local Util = require("aegis.util")

local M = {}

M.config = Config

--- Must run before require("lazy").setup().
---@param opts? AegisConfig
function M.setup(opts)
  Config.setup(opts)
  Gate.attach()
  return M
end

--- Merge aegis's requirements into your lazy options.
---
---   require("aegis").setup({})
---   require("lazy").setup(spec, require("aegis").lazy_opts({
---     -- your usual lazy options
---   }))
---
--- Three of these are not negotiable if the gates are to mean anything:
---   pkg   — lazy loads `lazy.lua` / rockspec / packspec *from the repo* to
---           build the spec. That is repo code running before install.
---   rocks — luarocks build scripts are arbitrary code.
---   defaults.submodules — submodule URLs are a code-execution surface on
---           older git, and are fetched during clone, before any scan.
---@param opts? table lazy.nvim options
---@return table
function M.lazy_opts(opts)
  opts = vim.deepcopy(opts or {})
  local cfg = Config.get()

  if cfg.harden.pkg then
    opts.pkg = vim.tbl_deep_extend("force", opts.pkg or {}, { enabled = false })
  end
  if cfg.harden.rocks then
    opts.rocks = vim.tbl_deep_extend("force", opts.rocks or {}, { enabled = false })
  end

  opts.defaults = opts.defaults or {}
  if cfg.harden.submodules then opts.defaults.submodules = false end

  if cfg.gates.load then
    local user_cond = opts.defaults.cond
    opts.defaults.cond = function(plugin)
      if not Gate.load_gate(plugin) then return false end
      if user_cond == false then return false end
      if type(user_cond) == "function" then return user_cond(plugin) ~= false end
      return true
    end
  end

  return opts
end

-- API ------------------------------------------------------------------------

local function lazy_plugins()
  local ok, LazyConfig = pcall(require, "lazy.core.config")
  if not ok or not LazyConfig.plugins then return {} end
  local out = {}
  for name, plugin in pairs(LazyConfig.plugins) do
    if plugin.dir and plugin.name ~= "aegis.nvim" then out[name] = plugin end
  end
  -- Disabled-by-cond plugins are the ones we most want to report on.
  for name, plugin in pairs(LazyConfig.spec and LazyConfig.spec.disabled or {}) do
    if plugin.dir and out[name] == nil and plugin.name ~= "aegis.nvim" then out[name] = plugin end
  end
  return out
end

M.plugins = lazy_plugins

--- Scan one installed plugin now. Blocking; used by :Aegis scan.
---@param name string
---@param opts? { force?:boolean }
function M.scan(name, opts)
  local plugin = lazy_plugins()[name]
  if not plugin then return nil, ("unknown plugin %q"):format(name) end
  local sha = Git.head_sha(plugin.dir)
  local report, err = Scan.scan_installed(name, plugin.dir, opts)
  return Policy.decide(name, sha, report, err), err
end

--- Scan every installed plugin. Returns name -> decision.
---@param opts? { force?:boolean, on_progress?: fun(name:string, i:number, total:number) }
function M.scan_all(opts)
  opts = opts or {}
  local results = {}
  local names = vim.tbl_keys(lazy_plugins())
  table.sort(names)
  for i, name in ipairs(names) do
    if opts.on_progress then opts.on_progress(name, i, #names) end
    local decision = M.scan(name, { force = opts.force })
    if decision then results[name] = decision end
  end
  return results
end

--- Approve a tree at `name`. The approval is pinned to one commit and dies the
--- moment the plugin moves off it.
---
--- By default this blesses the *installed* commit, and only that — so a refused
--- update, which leaves the worktree on the old commit, cannot silently approve
--- the incoming one. Pass `{ target = true }` (`:Aegis approve!`) to instead
--- approve the commit an update wants to move to: the explicit, human-in-the-loop
--- yes to a new commit you have looked at.
---@param name string
---@param opts? { target?: boolean }
function M.approve(name, opts)
  opts = opts or {}
  local plugin = lazy_plugins()[name]
  if not plugin then return false, ("unknown plugin %q"):format(name) end

  local report, sha

  if opts.target then
    -- The commit the pending update resolves to — the same one the update gate
    -- scans and blocks. Prefer lazy's live resolution; fall back to whatever the
    -- gate recorded as blocked this session.
    sha = Gate.target_sha(plugin) or (Gate.blocked[name] and Gate.blocked[name].sha)
    if not sha then
      return false, ("no pending update target for %s — run `:Lazy update %s` first")
        :format(name, name)
    end
    if sha == Git.head_sha(plugin.dir) then
      return false, ("%s is already at %s; nothing to approve"):format(name, Git.short(sha))
    end
    report = Cache.get(name, sha)
      or (Gate.blocked[name] and Gate.blocked[name].report)
      or Scan.scan_target(name, plugin.dir, sha)
  else
    -- A refused install is deleted, so there is usually nothing on disk to read
    -- a sha from — and that is precisely when the user wants to approve. Fall
    -- back to the commit the gate refused, then to the last one we scanned.
    sha = Git.head_sha(plugin.dir)
    if sha then
      report = Cache.get(name, sha)
    else
      report = (Gate.blocked[name] and Gate.blocked[name].report) or Cache.latest(name)
      sha = (Gate.blocked[name] and Gate.blocked[name].sha) or (report and report.sha)
    end
  end

  if not sha then
    return false, ("no scanned commit for %s — run `:Aegis scan %s` first"):format(name, name)
  end

  Cache.approve(name, sha, report)
  Gate.blocked[name] = nil
  local verb = opts.target and "update" or "install"
  return true,
    ("approved %s at %s — run `:Lazy %s` to complete it"):format(name, Git.short(sha), verb)
end

function M.revoke(name)
  if not Cache.revoke(name) then return false, ("no approval for %q"):format(name) end
  return true, ("revoked approval for %s"):format(name)
end

--- Current decision for every installed plugin, cache-only (no scanning).
function M.status()
  local rows = {}
  local unknown_allowed = Config.get().load_unknown ~= "block"

  for name, plugin in pairs(lazy_plugins()) do
    local sha = Git.head_sha(plugin.dir)
    local report = Cache.get(name, sha)

    -- Three distinct states, and conflating them is how a security tool ends
    -- up lying: scanned, refused by a gate (dir may be gone, so no sha to
    -- look up), or simply never scanned.
    local decision
    if report then
      decision = Policy.decide(name, sha, report, nil)
    elseif Gate.blocked[name] then
      decision = Gate.blocked[name]
      report = decision.report
    else
      decision = { allow = unknown_allowed, reason = "not scanned" }
    end
    table.insert(rows, {
      name = name,
      sha = sha,
      report = report,
      decision = decision,
      approved = Cache.approved(name, sha),
      loaded = plugin._ and plugin._.loaded ~= nil or false,
      cond_false = plugin._ and plugin._.cond == false or false,
    })
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

function M.report(name)
  local plugin = lazy_plugins()[name]
  if not plugin then return nil, ("unknown plugin %q"):format(name) end

  local sha = Git.head_sha(plugin.dir)
  local cached = sha and Cache.get(name, sha) or nil
  if cached then return cached end

  -- Refused plugins are no longer on disk; their report is all that is left.
  local kept = (Gate.blocked[name] and Gate.blocked[name].report) or Cache.latest(name)
  if kept then return kept end

  return Scan.scan_installed(name, plugin.dir)
end

M.notify = Util.notify

return M
