-- aegis-cli wrapper.
--
--   aegis analyze --ecosystem neovim <dir> --json
--
-- Lua AST capability scan over a plugin tree. Returns aegis's report table:
--   { name, version, verdict, risk_score, capabilities[], risk_flags[], evidence[] }
-- verdict is one of safe|review|prompt|block.
local Cache = require("aegis.cache")
local Config = require("aegis.config")
local Git = require("aegis.git")
local Proc = require("aegis.proc")

local M = {}

-- nil = unchecked, false = absent, string = version
local version_cache = nil

--- Resolved aegis version, or nil when the binary is not usable.
function M.version()
  if version_cache ~= nil then return version_cache or nil end

  local bin = Config.get().bin
  if vim.fn.executable(bin) ~= 1 then
    version_cache = false
    return nil
  end
  local res = Proc.exec({ bin, "version" }, { timeout = 10000 })
  local raw = res.code == 0 and res.stdout or ""
  version_cache = raw:match("%d[%w%.%-]*") or (res.code == 0 and "unknown") or false
  return version_cache or nil
end

function M.available() return M.version() ~= nil end

function M.forget_version() version_cache = nil end

--- Scan a directory that is already on disk. Does not consult the cache;
--- callers decide whether a cached verdict is acceptable.
---@param dir string
---@return table? report, string? err
function M.scan_dir(dir)
  local cfg = Config.get()
  if not M.available() then return nil, ("aegis binary %q not on PATH"):format(cfg.bin) end
  if vim.fn.isdirectory(dir) ~= 1 then return nil, "not a directory: " .. dir end

  local cmd = { cfg.bin, "analyze", "--ecosystem", "neovim", dir, "--json" }
  if cfg.evidence then table.insert(cmd, "--evidence") end

  local res = Proc.exec(cmd, { timeout = cfg.timeout })
  local report = Proc.decode_json(res.stdout)

  -- aegis exits non-zero for findings on some subcommands, so a bad exit code
  -- with a parseable report is still a usable verdict. Only an unparseable
  -- result is a scan failure.
  if not report then
    local detail = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
    return nil,
      ("aegis analyze failed (exit %d)%s"):format(res.code, detail ~= "" and ": " .. detail or "")
  end
  if not report.verdict then return nil, "aegis returned a report with no verdict" end
  return report
end

--- Verdict for the tree currently checked out at plugin.dir, cache-first.
---@param name string
---@param dir string
---@param opts? { force?:boolean }
---@return table? report, string? err
function M.scan_installed(name, dir, opts)
  opts = opts or {}
  local sha = Git.head_sha(dir)

  if not opts.force then
    local hit = Cache.get(name, sha)
    if hit then return hit end
  end

  local report, err = M.scan_dir(dir)
  if not report then return nil, err end

  report.sha = sha
  Cache.put(name, sha, report)
  return report
end

-- Materialise `rev` from `repo` into a throwaway worktree, scan it, tear it
-- down. Nothing is written to the repo's own worktree, so a rejected update
-- never lands. Objects for `rev` must already be fetched.
---@return table? report, string? err
local function scan_rev(repo, rev)
  local dest = vim.fn.tempname()

  local add = Proc.exec({ "git", "-C", repo, "worktree", "add", "--detach", dest, rev }, {
    timeout = Config.get().timeout,
  })
  if add.code ~= 0 then
    return nil, ("git worktree add %s failed: %s"):format(rev:sub(1, 8), vim.trim(add.stderr))
  end

  local report, err = M.scan_dir(dest)

  Proc.exec({ "git", "-C", repo, "worktree", "remove", "--force", dest }, { timeout = 30000 })
  vim.fn.delete(dest, "rf")
  -- Drop the administrative entry too, so a crashed nvim cannot accumulate them.
  Proc.exec({ "git", "-C", repo, "worktree", "prune" }, { timeout = 30000 })

  return report, err
end

--- Verdict for a commit that is fetched but not checked out. Used by the
--- update gate, so the scan happens before the worktree moves.
---@param name string
---@param dir string plugin.dir (an existing clone)
---@param sha string target commit
---@param opts? { force?:boolean }
---@return table? report, string? err
function M.scan_target(name, dir, sha, opts)
  opts = opts or {}
  if not opts.force then
    local hit = Cache.get(name, sha)
    if hit then return hit end
  end
  if not M.available() then return nil, ("aegis binary %q not on PATH"):format(Config.get().bin) end

  local report, err = scan_rev(dir, sha)
  if not report then return nil, err end

  report.sha = sha
  Cache.put(name, sha, report)
  return report
end

--- Clone `url` into a throwaway directory and scan it there. Used by
--- strict_clone so an unapproved tree never occupies plugin.dir.
---@return table? report, string? err, string? sha
function M.probe(url, branch)
  local cfg = Config.get()
  if not M.available() then return nil, ("aegis binary %q not on PATH"):format(cfg.bin) end

  local dest = vim.fn.tempname()
  -- Deliberately no --recurse-submodules: a submodule URL is code execution
  -- surface in older git, and we have not scanned anything yet.
  local args = { "git", "clone", "--depth=1", "--no-tags", "--quiet" }
  if branch then vim.list_extend(args, { "--branch", branch }) end
  vim.list_extend(args, { url, dest })

  local clone = Proc.exec(args, { timeout = cfg.timeout })
  if clone.code ~= 0 then
    vim.fn.delete(dest, "rf")
    return nil, ("probe clone failed: %s"):format(vim.trim(clone.stderr))
  end

  local sha = Git.head_sha(dest)
  local report, err = M.scan_dir(dest)
  vim.fn.delete(dest, "rf")

  if report then report.sha = sha end
  return report, err, sha
end

return M
