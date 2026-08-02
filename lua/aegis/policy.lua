-- Turns a scan result into an allow/block decision.
local Cache = require("aegis.cache")
local Config = require("aegis.config")
local Git = require("aegis.git")
local Scan = require("aegis.scan")

local M = {}

---@class AegisDecision
---@field allow boolean
---@field reason string
---@field verdict? string
---@field report? table
---@field approved? boolean

---@param name string
---@param sha string?
---@param report table?
---@param err string?
---@return AegisDecision
function M.decide(name, sha, report, err)
  local cfg = Config.get()

  -- An explicit approval pins one exact tree. It outranks the verdict, and
  -- dies the moment the sha moves.
  if Cache.approved(name, sha) then
    return {
      allow = true,
      approved = true,
      report = report,
      verdict = report and report.verdict,
      reason = ("approved for %s"):format(Git.short(sha)),
    }
  end

  if not report then
    local missing = not Scan.available()
    local mode = missing and cfg.on_missing_scanner or cfg.on_scan_error
    local allow = mode ~= "block"
    return {
      allow = allow,
      reason = ("no verdict (%s)%s"):format(
        err or "scan failed",
        allow and " — allowed by policy" or ""
      ),
    }
  end

  local rank = Config.RANK[report.verdict]
  if not rank then
    return {
      allow = cfg.on_scan_error ~= "block",
      report = report,
      verdict = report.verdict,
      reason = ("unrecognised verdict %q"):format(tostring(report.verdict)),
    }
  end

  if rank >= Config.RANK[cfg.fail_on] then
    return {
      allow = false,
      report = report,
      verdict = report.verdict,
      reason = ("verdict=%s risk=%s caps=[%s]"):format(
        report.verdict,
        tostring(report.risk_score or "?"),
        table.concat(report.capabilities or {}, ", ")
      ),
    }
  end

  return {
    allow = true,
    report = report,
    verdict = report.verdict,
    reason = ("verdict=%s risk=%s"):format(report.verdict, tostring(report.risk_score or "?")),
  }
end

--- Remote URL policy. Runs before anything is fetched.
---@return boolean ok, string? reason
function M.check_remote(url)
  local cfg = Config.get().harden
  local host, scheme = Git.host_of(url)

  if not host then
    -- Local/dev plugins have no parseable remote; those are the user's own
    -- files and are gated by the load scan instead.
    return true
  end

  if cfg.require_https and scheme ~= "https" and scheme ~= "ssh" then
    return false, ("refusing %s remote %s"):format(scheme or "unknown-scheme", url)
  end

  if cfg.allowed_hosts and #cfg.allowed_hosts > 0 then
    if not vim.tbl_contains(cfg.allowed_hosts, host) then
      return false, ("host %q not in allowed_hosts"):format(host)
    end
  end

  return true
end

return M
