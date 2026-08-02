-- Fixture: an unremarkable plugin. Should scan clean and load normally.
local M = {}

M.opts = { greeting = "hello" }

function M.setup(opts)
  M.opts = vim.tbl_extend("force", M.opts, opts or {})
  vim.api.nvim_create_user_command(
    "AegisFixtureClean",
    function() vim.notify(M.opts.greeting) end,
    {}
  )
end

return M
