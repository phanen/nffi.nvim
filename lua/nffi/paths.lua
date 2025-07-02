local M = {}

local root = assert(vim.env.NVIM_ROOT, '$NVIM_ROOT is not set')
M.include_paths = {}
for p in
  (
    '%s/.deps/usr/include/luajit-2.1;%s/.deps/usr/include;%s/build/src/nvim/auto;%s/build/include;%s/build/cmake.config;%s/src;/usr/include'
    .. ';'
  ):format(root, root, root, root, root, root):gmatch('[^;]+')
do
  table.insert(M.include_paths, p)
end
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
