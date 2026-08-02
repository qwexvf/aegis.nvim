-- Refusing an install deletes the clone, so approving it afterwards has no
-- worktree to read a sha from. That recovery path has to work anyway,
-- otherwise a blocked plugin is unrecoverable without editing state by hand.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

local evil = H.make_repo("evil", "evil")
local lazy = H.setup({ { url = H.url(evil), name = "evil" } })

lazy.install({ wait = true, show = false })
H.ok(not H.installed("evil"), "refused on the first install")

-- Evidence must survive the deletion, or there is nothing to decide on.
local report = require("aegis").report("evil")
H.ok(report ~= nil, "report still available after the clone was removed")
if report then
  H.eq(report.verdict, "prompt", "report kept its verdict")
  H.ok(report.evidence ~= nil and #report.evidence > 0, "report kept its evidence")
end

local ok, msg = require("aegis").approve("evil")
H.ok(ok, "approve works with no worktree present: " .. tostring(msg))

lazy.install({ wait = true, show = false })
H.ok(H.installed("evil"), "installs after approval")
H.ok(require("aegis.gate").blocked["evil"] == nil, "no longer recorded as blocked")

-- The approval must not survive the plugin changing underneath it.
local new_sha = H.mutate_repo(evil, "clean")
H.ok(
  not require("aegis.cache").approved("evil", new_sha),
  "approval does not carry to a new commit"
)

H.done("approval recovery")
