-- Git reads that must not spawn a subprocess.
--
-- The load gate runs inside lazy's spec resolve, on the main loop, once per
-- plugin, every startup. A `git rev-parse` fork there costs ~2ms x N plugins.
-- Reading .git/HEAD costs ~20us, so HEAD resolution is done by hand.
local M = {}

local function read(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local body = fd:read("*a")
  fd:close()
  return body
end

-- Resolve a ref name (refs/heads/main) to a sha via loose ref then packed-refs.
local function resolve_ref(gitdir, ref)
  local loose = read(vim.fs.joinpath(gitdir, ref))
  if loose then return vim.trim(loose) end

  local packed = read(vim.fs.joinpath(gitdir, "packed-refs"))
  if not packed then return nil end
  for line in packed:gmatch("[^\r\n]+") do
    local sha, name = line:match("^(%x+)%s+(%S+)$")
    if sha and name == ref then return sha end
  end
  return nil
end

-- Path to the git dir for a worktree. Handles the `gitdir: ...` file that
-- worktrees and submodules use instead of a real .git directory.
function M.gitdir(dir)
  local dot = vim.fs.joinpath(dir, ".git")
  local st = vim.uv.fs_stat(dot)
  if not st then return nil end
  if st.type == "directory" then return dot end

  local body = read(dot)
  local target = body and body:match("^gitdir:%s*(.-)%s*$")
  if not target then return nil end
  if not vim.startswith(target, "/") then target = vim.fs.joinpath(dir, target) end
  return vim.fs.normalize(target)
end

-- Current commit of the worktree at `dir`, or nil. No subprocess.
function M.head_sha(dir)
  local gitdir = M.gitdir(dir)
  if not gitdir then return nil end

  local head = read(vim.fs.joinpath(gitdir, "HEAD"))
  if not head then return nil end
  head = vim.trim(head)

  local ref = head:match("^ref:%s*(%S+)$")
  if not ref then
    -- detached HEAD, already a sha
    return head:match("^%x+$") and head or nil
  end
  return resolve_ref(gitdir, ref)
end

function M.short(sha) return sha and sha:sub(1, 8) or "unknown" end

-- Host and scheme of a git remote. Mirrors pakku's policy.host_of.
function M.host_of(url)
  if not url then return nil, nil end
  local scheme, host = url:match("^(%w+)://([^/]+)")
  if scheme then return host:gsub("^.*@", ""), scheme end
  local ssh = url:match("^git@([^:]+):")
  if ssh then return ssh, "ssh" end
  return nil, nil
end

return M
