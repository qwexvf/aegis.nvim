if vim.g.loaded_aegis_nvim then return end
vim.g.loaded_aegis_nvim = true

local SUBCOMMANDS = { "status", "scan", "report", "approve", "revoke", "clear" }

local function complete(arg_lead, line)
  local args = vim.split(vim.trim(line), "%s+")
  if #args <= 2 and not line:match("%s$") or #args == 1 then
    return vim.tbl_filter(function(c) return vim.startswith(c, arg_lead) end, SUBCOMMANDS)
  end
  if not vim.tbl_contains({ "report", "approve", "revoke", "scan" }, args[2]) then return {} end

  local names = vim.tbl_keys(require("aegis").plugins())
  table.sort(names)
  return vim.tbl_filter(function(n) return vim.startswith(n, arg_lead) end, names)
end

vim.api.nvim_create_user_command("Aegis", function(cmd)
  local Aegis = require("aegis")
  local action = cmd.fargs[1] or "status"
  local name = cmd.fargs[2]

  if action == "status" then
    require("aegis.ui").status()
  elseif action == "report" then
    if not name then return vim.notify("aegis: :Aegis report <plugin>", vim.log.levels.ERROR) end
    require("aegis.ui").report(name)
  elseif action == "approve" then
    if not name then return vim.notify("aegis: :Aegis approve <plugin>", vim.log.levels.ERROR) end
    local ok, msg = Aegis.approve(name)
    vim.notify("aegis: " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  elseif action == "revoke" then
    if not name then return vim.notify("aegis: :Aegis revoke <plugin>", vim.log.levels.ERROR) end
    local ok, msg = Aegis.revoke(name)
    vim.notify("aegis: " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  elseif action == "clear" then
    require("aegis.cache").clear()
    vim.notify("aegis: verdict cache cleared (approvals kept)")
  elseif action == "scan" then
    if name then
      local decision, err = Aegis.scan(name, { force = cmd.bang })
      if not decision then return vim.notify("aegis: " .. tostring(err), vim.log.levels.ERROR) end
      vim.notify(
        require("aegis.util").summary(name, decision),
        require("aegis.util").level_of(decision)
      )
    else
      vim.notify("aegis: scanning all plugins…")
      vim.schedule(function()
        local results = Aegis.scan_all({ force = cmd.bang })
        local blocked = {}
        for pname, decision in pairs(results) do
          if not decision.allow then table.insert(blocked, pname) end
        end
        if #blocked > 0 then
          vim.notify(
            ("aegis: %d blocked — %s"):format(#blocked, table.concat(blocked, ", ")),
            vim.log.levels.ERROR
          )
        else
          vim.notify(("aegis: %d plugins scanned, none blocked"):format(vim.tbl_count(results)))
        end
      end)
    end
  else
    vim.notify("aegis: unknown subcommand " .. action, vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  bang = true,
  complete = complete,
  desc = "aegis.nvim supply-chain gate",
})
