-- Subprocess helper.
--
-- Gates run inside lazy's task coroutines, where blocking the event loop with
-- vim.system():wait() would stall every other concurrent task. lazy already
-- solves this: its Process yields the coroutine and resumes on exit. Use it
-- when lazy is loaded, fall back to vim.system everywhere else (tests,
-- :Aegis scan outside a task).
local M = {}

local function lazy_process()
  local ok, Process = pcall(require, "lazy.manage.process")
  return ok and Process or nil
end

---@class AegisProcResult
---@field code number
---@field stdout string
---@field stderr string

---@param cmd string[]
---@param opts? { cwd?:string, timeout?:number }
---@return AegisProcResult
function M.exec(cmd, opts)
  opts = opts or {}
  local Process = lazy_process()

  if not Process then
    local res = vim.system(cmd, { cwd = opts.cwd, text = true, timeout = opts.timeout }):wait()
    return { code = res.code or 1, stdout = res.stdout or "", stderr = res.stderr or "" }
  end

  local proc = Process.spawn(cmd[1], {
    args = vim.list_slice(cmd, 2),
    cwd = opts.cwd,
    timeout = opts.timeout,
  })
  proc:wait()

  -- proc.data, not an on_data callback. lazy schedule_wraps opts.on_data, so
  -- under concurrent tasks those callbacks can still be queued when wait()
  -- returns — which silently truncates the output. proc.data is appended
  -- synchronously in the read handler, so it is complete once the process is.
  -- The cost is that stdout and stderr are interleaved in one string.
  return { code = proc.code or 1, stdout = proc.data or "", stderr = "" }
end

--- Decode aegis's `--json` object out of a possibly noisy stream.
---
--- Both streams can end up interleaved, so try the whole thing first, then the
--- widest {...} span. A narrow `%b{}` match is deliberately not used: against
--- truncated output it happily returns some inner object (a single risk flag,
--- say), which then looks like a valid report that merely lacks a verdict.
function M.decode_json(raw)
  if not raw or raw == "" then return nil end

  local function try(s)
    local ok, data = pcall(vim.json.decode, s)
    if ok and type(data) == "table" then return data end
  end

  local trimmed = vim.trim(raw)
  local data = try(trimmed)
  if data then return data end

  local first = trimmed:find("{", 1, true)
  local last = trimmed:reverse():find("}", 1, true)
  if not first or not last then return nil end
  return try(trimmed:sub(first, #trimmed - last + 1))
end

return M
