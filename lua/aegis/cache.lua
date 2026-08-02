-- Verdict cache and approval store, both keyed by commit sha.
--
-- Keying on the sha is the whole security property: an approval covers exactly
-- the tree that was scanned. Any update moves the sha, invalidating both the
-- cached verdict and the user's approval, so the new tree gets re-gated.
local Config = require("aegis.config")
local Git = require("aegis.git")

local M = {}

local function state_dir() return Config.get().state_dir end

local function verdict_dir() return vim.fs.joinpath(state_dir(), "verdicts") end

local function approvals_path() return vim.fs.joinpath(state_dir(), "approvals.json") end

local function read_json(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local body = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

local function write_json(path, tbl)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if not fd then return false end
  fd:write(vim.json.encode(tbl))
  fd:close()
  return true
end

-- Plugin names contain / and . for some specs; keep the filename flat.
local function slug(name) return (name:gsub("[^%w%-%._]", "_")) end

local function verdict_path(name, sha)
  return vim.fs.joinpath(verdict_dir(), ("%s@%s.json"):format(slug(name), Git.short(sha)))
end

--- Cached verdict for an exact (name, sha), or nil.
---@return table?
function M.get(name, sha)
  if not sha then return nil end
  local data = read_json(verdict_path(name, sha))
  if data then data.cached = true end
  return data
end

function M.put(name, sha, report)
  if not sha then return end
  report = vim.deepcopy(report)
  report.sha = sha
  -- aegis derives its `name` from the directory basename, which is a temp
  -- path for probe and target scans. The plugin name is what we key on and
  -- what the user sees, so it wins.
  report.name = name
  write_json(verdict_path(name, sha), report)
end

--- All cached verdicts, newest first. Used by `:Aegis status`.
function M.list()
  local out = {}
  local ok, it = pcall(vim.fs.dir, verdict_dir())
  if not ok then return out end
  for entry, kind in it do
    if kind == "file" and entry:match("%.json$") then
      local path = vim.fs.joinpath(verdict_dir(), entry)
      local data = read_json(path)
      if data then
        local st = vim.uv.fs_stat(path)
        data.scanned_at = st and st.mtime.sec or 0
        table.insert(out, data)
      end
    end
  end
  table.sort(out, function(a, b) return (a.scanned_at or 0) > (b.scanned_at or 0) end)
  return out
end

--- Most recent cached verdict for a plugin, whatever commit it was for.
---
--- A rejected plugin is deleted from the plugin root, so there is no installed
--- sha left to key on — but its report is exactly what the user needs in order
--- to decide whether to approve it. Keyed lookups cannot find that; this can.
---@return table?
function M.latest(name)
  local prefix = slug(name) .. "@"
  local newest, newest_at = nil, -1
  local ok, it = pcall(vim.fs.dir, verdict_dir())
  if not ok then return nil end
  for entry, kind in it do
    if kind == "file" and vim.startswith(entry, prefix) then
      local path = vim.fs.joinpath(verdict_dir(), entry)
      local st = vim.uv.fs_stat(path)
      local at = st and st.mtime.sec or 0
      if at > newest_at then
        newest, newest_at = read_json(path), at
      end
    end
  end
  return newest
end

function M.clear() vim.fn.delete(verdict_dir(), "rf") end

-- Approvals -----------------------------------------------------------------

function M.approvals() return read_json(approvals_path()) or {} end

--- True when the user has explicitly approved this exact tree.
function M.approved(name, sha)
  if not sha then return false end
  local entry = M.approvals()[name]
  return entry ~= nil and entry.sha == sha
end

function M.approve(name, sha, report)
  local all = M.approvals()
  all[name] = {
    sha = sha,
    verdict = report and report.verdict or "unknown",
    risk_score = report and report.risk_score or nil,
    -- os.time so the record survives a restart; only ever shown to the user.
    approved_at = os.time(),
  }
  write_json(approvals_path(), all)
end

function M.revoke(name)
  local all = M.approvals()
  if all[name] == nil then return false end
  all[name] = nil
  write_json(approvals_path(), all)
  return true
end

return M
