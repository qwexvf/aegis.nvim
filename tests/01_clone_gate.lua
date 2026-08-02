-- A malicious plugin must not survive `:Lazy install`.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

local evil = H.make_repo("evil", "evil")
local clean = H.make_repo("clean", "clean")

local lazy = H.setup({
  { url = H.url(evil), name = "evil" },
  { url = H.url(clean), name = "clean" },
})

lazy.install({ wait = true, show = false })

local Gate = require("aegis.gate")

H.ok(H.installed("clean"), "clean plugin installed")
H.ok(not H.installed("evil"), "malicious plugin removed from the plugin root")
H.ok(Gate.blocked["evil"] ~= nil, "evil recorded as blocked")
H.ok(Gate.blocked["clean"] == nil, "clean not blocked")

local decision = Gate.blocked["evil"]
if decision then
  H.eq(decision.verdict, "prompt", "evil verdict")
  H.ok(
    decision.reason:find("shell%-spawn") ~= nil,
    "reason names the capability: " .. decision.reason
  )
end

-- The verdict must be cached so later gates and startups do not rescan.
local reports = require("aegis.cache").list()
H.ok(#reports >= 1, "verdicts written to the cache")

H.done("clone gate")
