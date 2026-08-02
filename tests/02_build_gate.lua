-- Even with the clone gate off, a build hook must not run for a bad tree.
-- This is the checkpoint that matters most: `build` is arbitrary shell.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

local evil = H.make_repo("evil", "evil")
local clean = H.make_repo("clean", "clean")
local marker = H.root .. "/pwned"
local clean_marker = H.root .. "/clean-built"

local lazy = H.setup({
  { url = H.url(evil), name = "evil", build = "touch " .. marker },
  { url = H.url(clean), name = "clean", build = "touch " .. clean_marker },
}, {
  gates = { clone = false }, -- only the build gate is under test
})

lazy.install({ wait = true, show = false })

H.ok(H.installed("evil"), "evil cloned (clone gate disabled for this test)")
H.ok(vim.uv.fs_stat(marker) == nil, "malicious build hook never ran")
H.ok(vim.uv.fs_stat(clean_marker) ~= nil, "clean build hook did run")
H.ok(require("aegis.gate").blocked["evil"] ~= nil, "evil recorded as blocked")

H.done("build gate")
