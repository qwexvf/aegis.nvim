-- The scanner probe and report shape. When the probe was wrong (aegis-cli's
-- Rust rewrite dropped the `version` subcommand), available() went false and
-- every gate failed open with only a warning. Every other test then failed
-- for an unrelated-looking reason, so this one runs first and says it plainly.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

H.bootstrap()
local Aegis = require("aegis")
local Scan = require("aegis.scan")

Aegis.setup({ notify = false })
Scan.forget_version()
H.ok(Scan.available(), "aegis on PATH is detected as available")
H.ok((Scan.version() or ""):match("^%d") ~= nil, "version parsed: " .. tostring(Scan.version()))

local report = Scan.scan_dir(H.fixtures .. "/evil")
H.ok(report ~= nil, "evil fixture produces a report")
if report then
  H.eq(type(report.risk_score), "number", "risk_score populated")
  H.ok(type(report.risk_flags) == "table" and #report.risk_flags > 0, "risk_flags populated")
  local flag = report.risk_flags and report.risk_flags[1] or {}
  H.ok(type(flag.code) == "string" and type(flag.weight) == "number", "flag has code and weight")
end

Aegis.setup({ notify = false, bin = H.root .. "/no-such-aegis" })
Scan.forget_version()
H.ok(not Scan.available(), "missing binary is not available")

-- Present but broken: exits non-zero for both probe spellings.
Aegis.setup({ notify = false, bin = "false" })
Scan.forget_version()
H.ok(not Scan.available(), "binary that fails both probes is not available")

H.done("scanner")
