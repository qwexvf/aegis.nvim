local Config = require("aegis.config")
local Gate = require("aegis.gate")
local Scan = require("aegis.scan")

local M = {}

function M.check()
  local h = vim.health
  h.start("aegis.nvim")

  if not Config.options then
    h.error("setup() has not run — call require('aegis').setup{} before lazy.setup()")
    return
  end

  local version = Scan.version()
  if version then
    h.ok(("aegis-cli %s (%s)"):format(version, Config.options.bin))
  else
    local level = Config.options.on_missing_scanner == "block" and h.error or h.warn
    level(
      ("aegis-cli %q not on PATH — plugins are %s"):format(
        Config.options.bin,
        Config.options.on_missing_scanner == "block" and "blocked" or "NOT gated"
      )
    )
  end

  local ok_lazy = pcall(require, "lazy.core.config")
  if ok_lazy then
    h.ok("lazy.nvim detected")
  else
    h.error("lazy.nvim not found — aegis.nvim only gates lazy.nvim")
  end

  if Gate.installed then
    h.ok("install/update/build gates are patched in")
  else
    h.info("gates patch themselves on the first Lazy operation (not yet run this session)")
  end

  local lazy_opts = ok_lazy and require("lazy.core.config").options or {}
  local hard = Config.options.harden
  if hard.pkg then
    if lazy_opts.pkg and lazy_opts.pkg.enabled == false then
      h.ok("pkg sources disabled (repo-authored lazy.lua/rockspec/packspec cannot run)")
    else
      h.error(
        "pkg sources still enabled — did you pass lazy options through require('aegis').lazy_opts()?"
      )
    end
  end
  if hard.rocks then
    if lazy_opts.rocks and lazy_opts.rocks.enabled == false then
      h.ok("luarocks builds disabled")
    else
      h.error("luarocks builds still enabled — route lazy options through lazy_opts()")
    end
  end
  if hard.submodules then
    if lazy_opts.defaults and lazy_opts.defaults.submodules == false then
      h.ok("submodule cloning disabled")
    else
      h.warn("submodules still cloned — route lazy options through lazy_opts()")
    end
  end
  if Config.options.gates.load then
    if lazy_opts.defaults and type(lazy_opts.defaults.cond) == "function" then
      h.ok("load gate wired into defaults.cond")
    else
      h.error("load gate not wired — route lazy options through lazy_opts()")
    end
  end

  h.info(
    ("fail_on=%s  load_unknown=%s  strict_clone=%s"):format(
      Config.options.fail_on,
      Config.options.load_unknown,
      tostring(Config.options.strict_clone)
    )
  )
  h.info("state dir: " .. Config.options.state_dir)

  local blocked = vim.tbl_keys(Gate.blocked)
  if #blocked > 0 then h.warn("blocked this session: " .. table.concat(blocked, ", ")) end
end

return M
