-- Scratch-buffer output for :Aegis status / report.
local Aegis = require("aegis")
local Cache = require("aegis.cache")
local Git = require("aegis.git")

local M = {}

local NS = vim.api.nvim_create_namespace("aegis.nvim")

local HL = {
  safe = "DiagnosticOk",
  review = "DiagnosticHint",
  prompt = "DiagnosticWarn",
  block = "DiagnosticError",
  unknown = "Comment",
  approved = "DiagnosticInfo",
}

---@param lines string[]
---@param marks { line:integer, col:integer, end_col:integer, hl:string }[]
local function show(title, lines, marks)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, m in ipairs(marks or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.line, m.col, {
      end_col = m.end_col,
      hl_group = m.hl,
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "aegis"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(vim.o.columns - 8, 100)
  local height = math.min(vim.o.lines - 8, math.max(#lines + 1, 10))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<esc>", "<cmd>close<cr>", { buffer = buf, nowait = true })
  return buf, win
end

function M.status()
  local rows = Aegis.status()
  local lines, marks = {}, {}

  if #rows == 0 then return show("aegis", { "No lazy.nvim plugins found." }, {}) end

  local width = 0
  for _, r in ipairs(rows) do
    width = math.max(width, #r.name)
  end

  local counts = {}
  for _, r in ipairs(rows) do
    local state = r.approved and "approved" or (r.report and r.report.verdict or "unknown")
    counts[state] = (counts[state] or 0) + 1

    local prefix = ("  %-" .. width .. "s  "):format(r.name)
    local risk = r.report and r.report.risk_score or nil
    local line = ("%s%-9s %-8s %s"):format(
      prefix,
      state,
      risk and ("risk " .. risk) or "",
      r.report and table.concat(r.report.capabilities or {}, ",") or "not scanned"
    )
    if not r.decision.allow then line = line .. "   [BLOCKED]" end

    table.insert(lines, line)
    table.insert(marks, {
      line = #lines - 1,
      col = #prefix,
      end_col = #prefix + #state,
      hl = HL[state] or "Comment",
    })
  end

  local summary = {}
  for _, k in ipairs({ "block", "prompt", "review", "safe", "approved", "unknown" }) do
    if counts[k] then table.insert(summary, ("%s %d"):format(k, counts[k])) end
  end

  table.insert(lines, 1, "")
  table.insert(lines, 1, "  " .. table.concat(summary, "   "))
  table.insert(lines, "")
  table.insert(lines, "  :Aegis report <plugin>   evidence")
  table.insert(lines, "  :Aegis approve <plugin>  pin this exact commit as allowed")
  for _, m in ipairs(marks) do
    m.line = m.line + 2
  end

  return show("aegis status", lines, marks)
end

function M.report(name)
  local report, err = Aegis.report(name)
  if not report then return vim.notify("aegis: " .. tostring(err), vim.log.levels.ERROR) end

  local lines = {
    "",
    ("  %s @ %s"):format(report.name or name, Git.short(report.sha or report.version)),
    ("  verdict %s    risk %s    files %s"):format(
      report.verdict or "?",
      tostring(report.risk_score or "?"),
      tostring(report.files_analyzed or "?")
    ),
    "",
  }

  local approval = Cache.approvals()[name]
  if approval then
    table.insert(
      lines,
      ("  approved at %s (%s)"):format(
        Git.short(approval.sha),
        os.date("%Y-%m-%d %H:%M", approval.approved_at)
      )
    )
    table.insert(lines, "")
  end

  if report.risk_flags and #report.risk_flags > 0 then
    table.insert(lines, "  Risk flags")
    for _, f in ipairs(report.risk_flags) do
      table.insert(
        lines,
        ("    %-26s %s (weight %s)"):format(
          f.code or "?",
          f.detail or "",
          tostring(f.weight or "?")
        )
      )
    end
    table.insert(lines, "")
  end

  if report.evidence and #report.evidence > 0 then
    table.insert(lines, "  Evidence")
    for _, e in ipairs(report.evidence) do
      table.insert(
        lines,
        ("    %s:%s  [%s]"):format(e.file or "?", tostring(e.line or "?"), e.capability or "?")
      )
      local snippet = (e.snippet or ""):gsub("%s+", " ")
      if #snippet > 88 then snippet = snippet:sub(1, 85) .. "..." end
      table.insert(lines, "      " .. snippet)
    end
  end

  return show("aegis report: " .. name, lines, {})
end

return M
