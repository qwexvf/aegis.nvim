-- Shared harness for the e2e tests.
--
-- Each test runs in a fresh nvim with isolated XDG dirs, a real lazy.nvim, a
-- real aegis binary and file:// git repos built from tests/fixtures. Nothing
-- is mocked: if a gate does not actually stop lazy, the test fails.
local H = {}

H.root = assert(os.getenv("AEGIS_TEST_ROOT"), "AEGIS_TEST_ROOT not set")
H.plugin_root = assert(os.getenv("AEGIS_TEST_PLUGIN"), "AEGIS_TEST_PLUGIN not set")
H.fixtures = H.plugin_root .. "/tests/fixtures"

local failures = 0
local checks = 0

function H.ok(cond, msg)
  checks = checks + 1
  if cond then
    io.write("  ok   " .. msg .. "\n")
  else
    failures = failures + 1
    io.write("  FAIL " .. msg .. "\n")
  end
  return cond
end

function H.eq(got, want, msg)
  return H.ok(
    got == want,
    ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want))
  )
end

function H.done(name)
  io.write(("%s: %d checks, %d failures\n"):format(name, checks, failures))
  vim.cmd("cq " .. (failures > 0 and 1 or 0))
end

function H.git(dir, args)
  local cmd = vim.list_extend({ "git", "-C", dir }, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    error(("git %s failed in %s: %s"):format(table.concat(args, " "), dir, res.stderr))
  end
  return vim.trim(res.stdout or "")
end

--- Build a throwaway git repo from a fixture directory.
---@return string path
function H.make_repo(name, fixture)
  local repo = H.root .. "/repos/" .. name
  if vim.fn.isdirectory(repo) == 1 then return repo end
  vim.fn.mkdir(repo, "p")
  vim.fn.system({ "cp", "-r", H.fixtures .. "/" .. fixture .. "/lua", repo .. "/lua" })

  H.git(repo, { "init", "-q", "-b", "main" })
  H.git(repo, { "config", "user.email", "test@aegis.invalid" })
  H.git(repo, { "config", "user.name", "aegis test" })
  H.git(repo, { "add", "lua" })
  H.git(repo, { "commit", "-qm", "initial" })
  return repo
end

--- Replace a repo's contents with another fixture and commit. Simulates a
--- plugin that goes bad in an update.
function H.mutate_repo(repo, fixture)
  vim.fn.delete(repo .. "/lua", "rf")
  vim.fn.system({ "cp", "-r", H.fixtures .. "/" .. fixture .. "/lua", repo .. "/lua" })
  H.git(repo, { "add", "lua" })
  H.git(repo, { "commit", "-qm", "compromised" })
  return H.git(repo, { "rev-parse", "HEAD" })
end

function H.url(repo) return "file://" .. repo end

--- Put lazy.nvim and aegis.nvim on the runtimepath.
function H.bootstrap()
  local lazypath = os.getenv("AEGIS_TEST_LAZY")
  assert(
    lazypath and vim.fn.isdirectory(lazypath) == 1,
    "AEGIS_TEST_LAZY must point at a lazy.nvim checkout"
  )
  vim.opt.rtp:prepend(lazypath)
  vim.opt.rtp:prepend(H.plugin_root)
end

--- setup aegis + lazy with a spec, then return the lazy module.
---@param spec table
---@param aegis_opts? table
---@param lazy_opts? table
function H.setup(spec, aegis_opts, lazy_opts)
  H.bootstrap()

  local Aegis = require("aegis")
  Aegis.setup(vim.tbl_deep_extend("force", {
    notify = false,
    -- file:// remotes are the whole point of the fixtures
    harden = { require_https = false },
  }, aegis_opts or {}))

  local opts = vim.tbl_deep_extend("force", {
    root = H.root .. "/plugins",
    lockfile = H.root .. "/lazy-lock.json",
    state = H.root .. "/state.json",
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    performance = { reset_packpath = false, rtp = { reset = false } },
    headless = { log = false, task = false, colors = false, process = false },
  }, lazy_opts or {})

  require("lazy").setup(spec, Aegis.lazy_opts(opts))
  return require("lazy")
end

function H.installed(name) return vim.fn.isdirectory(H.root .. "/plugins/" .. name) == 1 end

return H
