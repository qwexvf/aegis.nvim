-- The lazy.nvim enforcement points.
--
-- lazy resolves task implementations at queue time
-- (`require("lazy.manage.task." .. mod)[name]` in manage/runner.lua), so
-- replacing a function on those module tables before the pipeline starts is
-- enough — no fork of lazy required.
--
-- Pipelines (lazy/manage/init.lua):
--   install: exists > git.clone > git.checkout > plugin.docs > wait > plugin.build
--   update:  exists > git.origin > git.branch > git.fetch > git.status
--                   > git.checkout > plugin.docs > wait > plugin.build
--
-- A task that calls `self:error()` stops that plugin's pipeline — runner.lua
-- explicitly refuses to advance a plugin whose current task has errors. That
-- is what makes a blocked verdict fatal rather than advisory: no checkout, no
-- helptags, no build.
local Cache = require("aegis.cache")
local Config = require("aegis.config")
local Git = require("aegis.git")
local Policy = require("aegis.policy")
local Proc = require("aegis.proc")
local Scan = require("aegis.scan")
local Util = require("aegis.util")

local M = {}

M.installed = false

-- Plugins blocked this session, name -> decision (with .sha). Surfaced by
-- :Aegis status.
M.blocked = {}

-- Records are scoped to the commit they were made about. A rejected update
-- leaves the worktree on the old, allowed commit — and lazy re-resolves the
-- spec right after an update, which runs the load gate over that old commit
-- and produces an allow. Clearing on any allow would erase the very block
-- that kept the bad commit out.
local function record(name, decision, sha)
  if not decision.allow then
    decision.sha = sha
    M.blocked[name] = decision
    return
  end
  local prev = M.blocked[name]
  if prev == nil or prev.sha == nil or prev.sha == sha then M.blocked[name] = nil end
end

-- Fail a task and leave a breadcrumb the user can act on.
local function deny(task, name, decision, sha)
  record(name, decision, sha)
  local msg = Util.summary(name, decision)
  task:error(msg)
  task:log(
    "aegis: `:Aegis report "
      .. name
      .. "` for evidence, `:Aegis approve "
      .. name
      .. "` to override"
  )
  Util.notify(msg, vim.log.levels.ERROR)
end

local function allow(task, name, decision, sha)
  record(name, decision, sha)
  if decision.verdict and decision.verdict ~= "safe" then
    task:log(Util.summary(name, decision), vim.log.levels.WARN)
  end
end

-- clone ----------------------------------------------------------------------

-- Strict mode: clone to a throwaway dir, scan there, and only let lazy clone
-- for real once the tree is cleared. Costs a second shallow fetch.
local function strict_clone(task, orig, opts)
  local plugin = task.plugin
  local report, err, sha = Scan.probe(plugin.url, plugin.branch)
  -- Cache before deciding: a rejected plugin is exactly the one whose
  -- evidence the user wants from `:Aegis report`, and it is about to be gone.
  if report and sha then Cache.put(plugin.name, sha, report) end

  local decision = Policy.decide(plugin.name, sha, report, err)
  if not decision.allow then
    deny(task, plugin.name, decision, sha)
    return
  end
  allow(task, plugin.name, decision, sha)

  orig(task, opts)

  -- The probe and the real clone are separate fetches; a moving branch could
  -- land a different commit than the one we cleared.
  if plugin._.cloned and Git.head_sha(plugin.dir) ~= sha then
    M.gate_installed(task, { on_block = M.remove_clone })
  end
end

--- Delete a rejected fresh clone and put lazy's state back to "not installed".
function M.remove_clone(task)
  local plugin = task.plugin
  vim.fn.delete(plugin.dir, "rf")
  vim.uv.fs_unlink(plugin.dir .. ".cloning")
  plugin._.installed = false
  plugin._.cloned = false
  plugin._.dirty = false
end

--- Scan whatever is currently checked out at plugin.dir and enforce.
---@param task table lazy task
---@param opts? { on_block?: fun(task:table), force?:boolean }
---@return boolean allowed
function M.gate_installed(task, opts)
  opts = opts or {}
  local plugin = task.plugin
  local sha = Git.head_sha(plugin.dir)
  local report, err = Scan.scan_installed(plugin.name, plugin.dir, { force = opts.force })
  local decision = Policy.decide(plugin.name, sha, report, err)

  if decision.allow then
    allow(task, plugin.name, decision, sha)
    return true
  end

  if opts.on_block then opts.on_block(task) end
  deny(task, plugin.name, decision, sha)
  return false
end

function M.wrap_clone()
  local git = require("lazy.manage.task.git")
  local orig = git.clone.run

  git.clone.run = function(task, opts)
    local plugin = task.plugin

    -- Remote policy runs before a single byte is fetched.
    local ok, reason = Policy.check_remote(plugin.url)
    if not ok then
      deny(task, plugin.name, { allow = false, reason = reason })
      return
    end

    if Config.get().strict_clone then return strict_clone(task, orig, opts) end

    orig(task, opts)

    -- Clone failed: lazy already logged it, and there is nothing to scan.
    if not plugin._.cloned then return end

    -- The tree is on disk but inert — checkout, helptags and build all come
    -- later in the pipeline, and runtimepath has not been touched.
    M.gate_installed(task, { on_block = M.remove_clone })
  end
end

-- checkout / update -----------------------------------------------------------

-- What commit is this checkout about to move to? Reuses lazy's own resolution
-- so we scan the same tree lazy is about to write.
local function target_sha(plugin, opts)
  local LazyGit = require("lazy.manage.git")
  local Lock = require("lazy.manage.lock")

  local info = LazyGit.info(plugin.dir)
  local target = LazyGit.get_target(plugin)
  if not target then return nil end

  if plugin.pin and not plugin._.cloned then return info and info.commit end
  if opts and opts.lockfile then
    local lock = Lock.get(plugin)
    if lock then return lock.commit end
  end
  return target.commit
end

function M.wrap_checkout()
  local git = require("lazy.manage.task.git")
  local orig = git.checkout.run

  git.checkout.run = function(task, opts)
    local plugin = task.plugin

    -- A fresh clone is the clone gate's business; it has already run.
    if plugin._.cloned then return orig(task, opts) end

    local from = Git.head_sha(plugin.dir)
    local to = target_sha(plugin, opts)

    -- Nothing moving, or we could not tell: fall through and verify after.
    if to and from and to ~= from then
      local report, err = Scan.scan_target(plugin.name, plugin.dir, to)
      local decision = Policy.decide(plugin.name, to, report, err)
      if not decision.allow then
        deny(task, plugin.name, decision, to)
        return
      end
      allow(task, plugin.name, decision, to)
    end

    orig(task, opts)

    -- Verify what actually landed. If lazy resolved a different commit than
    -- we cleared, gate the real tree and roll back rather than trust it.
    local landed = Git.head_sha(plugin.dir)
    if landed and landed ~= from and landed ~= to then
      M.gate_installed(task, {
        on_block = function() M.rollback(task, from) end,
      })
    end
  end
end

--- Return the worktree to `sha` after a rejected update.
function M.rollback(task, sha)
  if not sha then return end
  local plugin = task.plugin
  local res = Proc.exec(
    { "git", "-C", plugin.dir, "checkout", "--force", sha },
    { timeout = 60000 }
  )
  if res.code == 0 then
    plugin._.updated = nil
    plugin._.dirty = false
    task:log(
      ("aegis: rolled %s back to %s"):format(plugin.name, Git.short(sha)),
      vim.log.levels.WARN
    )
  else
    task:error(
      ("aegis: rollback of %s to %s FAILED: %s"):format(
        plugin.name,
        Git.short(sha),
        vim.trim(res.stderr)
      )
    )
  end
end

-- build -----------------------------------------------------------------------

function M.wrap_build()
  local plugin_tasks = require("lazy.manage.task.plugin")
  local orig = plugin_tasks.build.run

  plugin_tasks.build.run = function(task, opts)
    -- Build hooks are arbitrary shell and arbitrary Lua. This is the last
    -- checkpoint before that runs, so it re-verifies rather than trusting an
    -- earlier gate in the same pipeline.
    if not M.gate_installed(task) then return end
    return orig(task, opts)
  end
end

-- load ------------------------------------------------------------------------

--- lazy `defaults.cond`: decides whether a plugin may reach runtimepath.
---
--- Runs on the main loop during spec resolve, once per plugin per startup, so
--- it must not spawn anything. Cache lookups only; anything uncached is
--- resolved by the `load_unknown` policy and queued for a background scan.
---@param plugin table LazyPlugin
---@return boolean
function M.load_gate(plugin)
  local cfg = Config.get()
  if not cfg.gates.load then return true end
  -- Never gate ourselves out of existence, and leave local/dev trees alone.
  if plugin.name == "aegis.nvim" or plugin.dir == nil then return true end

  local sha = Git.head_sha(plugin.dir)
  if not sha then return true end -- not installed yet; install gates cover it

  if Cache.approved(plugin.name, sha) then return true end

  local report = Cache.get(plugin.name, sha)
  if not report then
    M.queue_background_scan(plugin)
    return cfg.load_unknown ~= "block"
  end

  local decision = Policy.decide(plugin.name, sha, report, nil)
  record(plugin.name, decision, sha)
  if not decision.allow then
    Util.notify(
      ("%s\nnot loaded. `:Aegis report %s` for evidence."):format(
        Util.summary(plugin.name, decision),
        plugin.name
      ),
      vim.log.levels.ERROR
    )
  end
  return decision.allow
end

-- Plugins seen with no cached verdict, drained after startup.
M.pending = {}

function M.queue_background_scan(plugin) M.pending[plugin.name] = plugin.dir end

--- Scan everything the load gate could not decide, off the startup path.
function M.drain_pending()
  local names = vim.tbl_keys(M.pending)
  if #names == 0 then return end
  if not Scan.available() then
    M.pending = {}
    return
  end

  local queue = M.pending
  M.pending = {}

  local i = 0
  local function next_one()
    i = i + 1
    local name = names[i]
    if not name then
      Util.notify(("background scan done (%d plugin%s)"):format(#names, #names == 1 and "" or "s"))
      return
    end
    local dir = queue[name]
    local cfg = Config.get()
    local cmd = { cfg.bin, "analyze", "--ecosystem", "neovim", dir, "--json" }
    if cfg.evidence then table.insert(cmd, "--evidence") end

    vim.system(cmd, { text = true, timeout = cfg.timeout }, function(res)
      vim.schedule(function()
        local report = Proc.decode_json(res.stdout)
        if report and report.verdict then
          local sha = Git.head_sha(dir)
          report.sha = sha
          Cache.put(name, sha, report)
          local decision = Policy.decide(name, sha, report, nil)
          record(name, decision, sha)
          if not decision.allow then
            Util.notify(
              ("%s\nstill loaded this session — restart to enforce."):format(
                Util.summary(name, decision)
              ),
              vim.log.levels.ERROR
            )
          end
        end
        next_one()
      end)
    end)
  end
  next_one()
end

-- wiring ----------------------------------------------------------------------

--- Patch lazy's task table. Idempotent; safe to call from several events.
function M.install()
  if M.installed then return end
  local ok, err = pcall(function()
    local cfg = Config.get()
    if cfg.gates.clone then M.wrap_clone() end
    if cfg.gates.update then M.wrap_checkout() end
    if cfg.gates.build then M.wrap_build() end
  end)
  if not ok then
    Util.notify("failed to install gates: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  M.installed = true
end

--- Patching happens on lazy's `*Pre` events rather than at setup() time.
--- lazy fires those from Manager.run before it builds the runner, and by then
--- lazy.core.config is initialised — requiring the task modules any earlier
--- risks loading them against a half-built config.
function M.attach()
  local group = vim.api.nvim_create_augroup("AegisGate", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "LazyInstallPre", "LazyUpdatePre", "LazySyncPre", "LazyRestorePre", "LazyCheckPre" },
    callback = function() M.install() end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazyVimStarted",
    once = true,
    callback = function() M.drain_pending() end,
  })
  -- LazyVimStarted only exists in LazyVim; VimEnter is the portable backstop.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    callback = function()
      vim.defer_fn(function() M.drain_pending() end, 200)
    end,
  })
end

return M
