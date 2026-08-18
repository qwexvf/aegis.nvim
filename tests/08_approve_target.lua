-- A prompt-verdict update the user actually wants must have a way through.
-- Bare `:Aegis approve` only ever blesses the installed commit (see 03), so
-- `:Aegis approve!` / approve(name, {target=true}) is the explicit yes to the
-- commit an update is trying to move to.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

local repo = H.make_repo("victim", "clean")
local lazy = H.setup({ { url = H.url(repo), name = "victim" } })

lazy.install({ wait = true, show = false })
H.ok(H.installed("victim"), "victim installed while clean")

local dir = H.root .. "/plugins/victim"
local before = require("aegis.git").head_sha(dir)

-- Upstream moves to a commit that trips the prompt gate.
local incoming = H.mutate_repo(repo, "evil")
H.ok(before ~= incoming, "upstream moved to a new commit")

lazy.update({ wait = true, show = false })
H.eq(require("aegis.git").head_sha(dir), before, "blocked update left the worktree put")
H.ok(require("aegis.gate").blocked["victim"] ~= nil, "victim recorded as blocked")

-- Bare approve must still refuse to cover the incoming commit.
require("aegis").approve("victim")
H.ok(
  not require("aegis.cache").approved("victim", incoming),
  "bare approve does not cover the incoming commit"
)

-- The bang is the explicit yes to the target the update wants.
local ok, msg = require("aegis").approve("victim", { target = true })
H.ok(ok, "approve! succeeds: " .. tostring(msg))
H.ok(require("aegis.cache").approved("victim", incoming), "approve! pins the incoming commit")

-- ...and now the update actually lands.
lazy.update({ wait = true, show = false })
H.eq(require("aegis.git").head_sha(dir), incoming, "worktree moved to the approved commit")
H.ok(vim.uv.fs_stat(dir .. "/lua/evil/init.lua") ~= nil, "incoming source materialised")

-- Approving a target when nothing is pending is a no-op error, not a footgun.
local ok2, msg2 = require("aegis").approve("victim", { target = true })
H.ok(not ok2, "approve! with no pending update refuses: " .. tostring(msg2))

H.done("approve target")
