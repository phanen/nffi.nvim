local M = {}

local root = assert(vim.env.NVIM_ROOT, '$NVIM_ROOT is not set')
M.root = root

M.include_paths = {
  ('%s/.deps/usr/include/luajit-2.1'):format(root),
  ('%s/.deps/usr/include'):format(root),
  ('%s/build/src/nvim/auto'):format(root),
  ('%s/build/include'):format(root),
  ('%s/build/cmake.config'):format(root),
  ('%s/src'):format(root),
  ('%s'):format(root),
  '/usr/include',
}

M.apple_sysroot = ''

M.translations_enabled = 'OFF' == 'ON'
M.is_asan = 'OFF' == 'ON'
M.is_zig_build = false
M.vterm_test_file = ('%s/build/test/vterm_test_output'):format(root)
M.test_build_dir = ('%s/build'):format(root)
M.test_source_path = root
M.test_lua_prg = ('%s/.deps/usr/bin/luajit'):format(root)
M.test_luajit_prg = ''
if M.test_luajit_prg == '' then
  if M.test_lua_prg:sub(-6) == 'luajit' then
    M.test_luajit_prg = M.test_lua_prg
  else
    M.test_luajit_prg = nil
  end
end
table.insert(M.include_paths, ('%s/build/include'):format(root))
table.insert(M.include_paths, ('%s/build/src/nvim/auto'):format(root))

return M
