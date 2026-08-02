-- A plugin that goes bad in an update must not reach the worktree.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

local repo = H.make_repo("victim", "clean")
local lazy = H.setup({ { url = H.url(repo), name = "victim" } })

lazy.install({ wait = true, show = false })
H.ok(H.installed("victim"), "victim installed while clean")

local dir = H.root .. "/plugins/victim"
local before = require("aegis.git").head_sha(dir)

-- Upstream is compromised.
local bad_sha = H.mutate_repo(repo, "evil")
H.ok(before ~= bad_sha, "upstream moved to a new commit")

lazy.update({ wait = true, show = false })

local after = require("aegis.git").head_sha(dir)
H.eq(after, before, "worktree stayed on the last approved commit")
H.ok(vim.uv.fs_stat(dir .. "/lua/clean/init.lua") ~= nil, "clean source still on disk")
H.ok(vim.uv.fs_stat(dir .. "/lua/evil/init.lua") == nil, "malicious source never materialised")
H.ok(require("aegis.gate").blocked["victim"] ~= nil, "victim recorded as blocked")

-- Approving the old commit must not silently approve the new one.
require("aegis").approve("victim")
H.ok(require("aegis.cache").approved("victim", before), "approval pins the installed commit")
H.ok(
  not require("aegis.cache").approved("victim", bad_sha),
  "approval does not cover the incoming commit"
)

H.done("update gate")
