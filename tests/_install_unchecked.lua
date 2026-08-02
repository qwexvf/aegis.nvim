-- Phase-A helper for 04_load_gate: install the malicious fixture with the
-- install-time gates off, so the next nvim starts with a bad tree already on
-- disk — the "you adopted aegis after the fact" case.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

local evil = H.make_repo("evil", "evil")
local lazy = H.setup({ { url = H.url(evil), name = "evil" } }, {
  gates = { clone = false, build = false, load = false },
})
lazy.install({ wait = true, show = false })

assert(vim.fn.isdirectory(H.root .. "/plugins/evil") == 1, "phase A: evil should be on disk")
vim.cmd("cq 0")
