-- luacheck config for aegis.nvim
std = "lua51+luajit"

globals = {
  "vim",
}

read_globals = {
  "_G",
}

ignore = {
  "212", -- unused argument
  "631", -- line too long (stylua governs line width)
}

files["tests/"] = {
  ignore = { "111", "112", "113", "121", "122", "131", "143" },
}
