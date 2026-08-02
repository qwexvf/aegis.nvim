-- strict_clone: the scan happens in a throwaway clone, so a rejected tree
-- never occupies plugin.dir at all.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

local evil = H.make_repo("evil", "evil")
local clean = H.make_repo("clean", "clean")

local lazy = H.setup({
  { url = H.url(evil), name = "evil" },
  { url = H.url(clean), name = "clean" },
}, { strict_clone = true })

lazy.install({ wait = true, show = false })

H.ok(not H.installed("evil"), "malicious plugin never occupied the plugin root")
H.ok(H.installed("clean"), "clean plugin installed normally under strict_clone")
H.ok(require("aegis.gate").blocked["evil"] ~= nil, "evil recorded as blocked")

-- The probe still caches a verdict, so `:Aegis report` works for something
-- that was never installed.
local found = false
for _, r in ipairs(require("aegis.cache").list()) do
  if r.name == "evil" then found = true end
end
H.ok(found, "probe verdict cached for evidence")

H.done("strict clone")
