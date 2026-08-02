-- lazy_opts() must actually close the pre-gate execution paths, and the
-- remote policy must refuse a plaintext remote before anything is fetched.
package.path = (os.getenv("AEGIS_TEST_PLUGIN") or ".") .. "/tests/?.lua;" .. package.path
local H = require("helpers")

H.bootstrap()
local Aegis = require("aegis")

Aegis.setup({ notify = false })
local opts = Aegis.lazy_opts({})

H.eq(opts.pkg.enabled, false, "repo-authored lazy.lua/rockspec/packspec disabled")
H.eq(opts.rocks.enabled, false, "luarocks builds disabled")
H.eq(opts.defaults.submodules, false, "submodule cloning disabled")
H.eq(type(opts.defaults.cond), "function", "load gate installed as defaults.cond")

-- A user's own cond must still be honoured, not silently dropped.
local seen = false
local composed = Aegis.lazy_opts({
  defaults = {
    cond = function()
      seen = true
      return false
    end,
  },
})
H.eq(
  composed.defaults.cond({ name = "x", dir = H.root .. "/nope" }),
  false,
  "user cond still applies"
)
H.ok(seen, "user cond was actually called")

-- Opting out of hardening is possible but must be explicit.
Aegis.setup({ notify = false, harden = { pkg = false, rocks = false, submodules = false } })
local loose = Aegis.lazy_opts({})
H.eq(loose.pkg, nil, "pkg untouched when hardening is opted out")
H.eq(loose.rocks, nil, "rocks untouched when hardening is opted out")

-- Remote policy: plaintext remotes are refused before any fetch happens.
Aegis.setup({ notify = false })
local Policy = require("aegis.policy")
H.ok(not Policy.check_remote("http://example.com/evil.git"), "http remote refused")
H.ok(not Policy.check_remote("git://example.com/evil.git"), "git:// remote refused")
H.ok(Policy.check_remote("https://github.com/folke/lazy.nvim.git"), "https remote allowed")
H.ok(Policy.check_remote("git@github.com:folke/lazy.nvim.git"), "ssh remote allowed")

Aegis.setup({ notify = false, harden = { allowed_hosts = { "github.com" } } })
H.ok(Policy.check_remote("https://github.com/a/b.git"), "allowed host passes")
H.ok(not Policy.check_remote("https://evil.example/a/b.git"), "host outside the allowlist refused")

H.done("hardening")
