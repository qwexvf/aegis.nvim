local Config = require("aegis.config")

local M = {}

M.LEVEL_OF_VERDICT = {
  safe = vim.log.levels.INFO,
  review = vim.log.levels.INFO,
  prompt = vim.log.levels.WARN,
  block = vim.log.levels.ERROR,
}

function M.notify(msg, level)
  if not Config.get().notify then return end
  vim.schedule(
    function() vim.notify(msg, level or vim.log.levels.INFO, { title = "aegis.nvim" }) end
  )
end

--- One-line summary of a decision, for task logs and notifications.
function M.summary(name, decision)
  return ("aegis: %s %s — %s"):format(
    decision.allow and "allowed" or "BLOCKED",
    name,
    decision.reason
  )
end

function M.level_of(decision)
  if not decision.allow then return vim.log.levels.ERROR end
  return M.LEVEL_OF_VERDICT[decision.verdict] or vim.log.levels.INFO
end

return M
