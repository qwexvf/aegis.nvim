-- A bad tree that is already installed must never reach runtimepath.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

-- Phase A runs in its own nvim: lazy can only be set up once per process, and
-- the load gate is evaluated during that one setup.
local phase_a = vim
  .system({
    "nvim",
    "--headless",
    "--clean",
    "-u",
    "NONE",
    "-l",
    H.plugin_root .. "/tests/_install_unchecked.lua",
  }, { text = true })
  :wait()
H.eq(phase_a.code, 0, "phase A installed the fixture unchecked")

local evil = H.make_repo("evil", "evil")
H.ok(H.installed("evil"), "evil is on disk before this nvim starts")

-- Cold cache is deliberately permissive, so make this the enforcing case.
H.setup({ { url = H.url(evil), name = "evil" } }, { load_unknown = "block" })

local LazyConfig = require("lazy.core.config")
-- cond=false makes lazy drop the plugin out of the active set entirely: it
-- sets enabled=false, and fix_disabled then moves it to spec.disabled.
H.ok(LazyConfig.plugins.evil == nil, "evil is not in the active plugin set")

local plugin = LazyConfig.spec.disabled.evil
H.ok(plugin ~= nil, "evil is in lazy's disabled set")
H.eq(plugin._.cond, false, "load gate set cond=false")

local dir = H.root .. "/plugins/evil"
H.ok(not vim.tbl_contains(vim.opt.rtp:get(), dir), "plugin dir not on runtimepath")
H.ok(package.loaded["evil"] == nil, "plugin module never loaded")
H.ok(pcall(require, "evil") == false, "require('evil') fails — it is not reachable")

-- Not even an explicit loader call gets it onto runtimepath.
pcall(function() require("lazy.core.loader").load(plugin, { task = "test" }) end)
H.ok(not vim.tbl_contains(vim.opt.rtp:get(), dir), "still off runtimepath after a forced load")
H.ok(pcall(require, "evil") == false, "still not requirable after a forced load")

-- An explicit approval for this exact commit reopens it.
require("aegis").approve("evil")
H.ok(require("aegis.gate").load_gate(plugin), "load gate allows the approved commit")

-- ...and only that commit.
local Cache = require("aegis.cache")
H.ok(
  not Cache.approved("evil", "0000000000000000000000000000000000000000"),
  "approval is commit-scoped"
)

H.done("load gate")
