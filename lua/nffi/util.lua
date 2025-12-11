local uv = vim.uv
local Paths = require('nffi.paths')

--- Functions executing in the context of the test runner (not the current nvim test session).
--- @class test.testutil
local M = {
  paths = Paths,
}

--- @param ... string|string[]
--- @return string[]
function M.argss_to_cmd(...)
  local cmd = {} --- @type string[]
  for i = 1, select('#', ...) do
    local arg = select(i, ...)
    if type(arg) == 'string' then
      cmd[#cmd + 1] = arg
    else
      --- @cast arg string[]
      for _, subarg in ipairs(arg) do
        cmd[#cmd + 1] = subarg
      end
    end
  end
  return cmd
end

local tmpdir = os.getenv('TMPDIR') or os.getenv('TEMP')
local tmpdir_is_local = not not (tmpdir and tmpdir:find('Xtest'))

local function deps_prefix()
  local env = os.getenv('DEPS_PREFIX')
  return (env and env ~= '') and env or '.deps/usr'
end

local tests_skipped = 0

function M.check_cores(app, force) -- luacheck: ignore
  -- Temporary workaround: skip core check as it interferes with CI.
  if true then
    return
  end
  app = app or 'build/bin/nvim' -- luacheck: ignore
  --- @type string, string?, string[]
  local initial_path, re, exc_re
  local gdb_db_cmd =
    'gdb -n -batch -ex "thread apply all bt full" "$_NVIM_TEST_APP" -c "$_NVIM_TEST_CORE"'
  local lldb_db_cmd = 'lldb -Q -o "bt all" -f "$_NVIM_TEST_APP" -c "$_NVIM_TEST_CORE"'
  local random_skip = false
  -- Workspace-local $TMPDIR, scrubbed and pattern-escaped.
  -- "./Xtest-tmpdir/" => "Xtest%-tmpdir"
  local local_tmpdir = nil
  if tmpdir_is_local and tmpdir then
    local_tmpdir =
      vim.pesc(vim.fs.relpath(assert(uv.cwd()), tmpdir):gsub('^[ ./]+', ''):gsub('%/+$', ''))
  end

  local db_cmd --- @type string
  local test_glob_dir = os.getenv('NVIM_TEST_CORE_GLOB_DIRECTORY')
  if test_glob_dir and test_glob_dir ~= '' then
    initial_path = test_glob_dir
    re = os.getenv('NVIM_TEST_CORE_GLOB_RE')
    exc_re = { os.getenv('NVIM_TEST_CORE_EXC_RE'), local_tmpdir }
    db_cmd = os.getenv('NVIM_TEST_CORE_DB_CMD') or gdb_db_cmd
    random_skip = os.getenv('NVIM_TEST_CORE_RANDOM_SKIP') ~= ''
  elseif M.is_os('mac') then
    initial_path = '/cores'
    re = nil
    exc_re = { local_tmpdir }
    db_cmd = lldb_db_cmd
  else
    initial_path = '.'
    if M.is_os('freebsd') then
      re = '/nvim.core$'
    else
      re = '/core[^/]*$'
    end
    exc_re = { '^/%.deps$', '^/%' .. deps_prefix() .. '$', local_tmpdir, '^/%node_modules$' }
    db_cmd = gdb_db_cmd
    random_skip = true
  end
  -- Finding cores takes too much time on linux
  if not force and random_skip and math.random() < 0.9 then
    tests_skipped = tests_skipped + 1
    return
  end
  local cores = M.glob(initial_path, re, exc_re)
  local found_cores = 0
  local out = io.stdout
  for _, core in ipairs(cores) do
    local len = 80 - #core - #'Core file ' - 2
    local esigns = ('='):rep(len / 2)
    out:write(('\n%s Core file %s %s\n'):format(esigns, core, esigns))
    out:flush()
    os.execute(db_cmd:gsub('%$_NVIM_TEST_APP', app):gsub('%$_NVIM_TEST_CORE', core) .. ' 2>&1')
    out:write('\n')
    found_cores = found_cores + 1
    os.remove(core)
  end
  if found_cores ~= 0 then
    out:write(('\nTests covered by this check: %u\n'):format(tests_skipped + 1))
  end
  tests_skipped = 0
  if found_cores > 0 then
    error('crash detected (see above)')
  end
end

--- @return string?
function M.repeated_read_cmd(...)
  local cmd = M.argss_to_cmd(...)
  local data = {}
  local got_code = nil
  local stdout = assert(uv.new_pipe(false))
  local stderr = assert(uv.new_pipe(false))
  local handle = uv.spawn(
    assert(cmd[1]),
    { args = vim.list_slice(cmd, 2), stdio = { nil, stdout, stderr }, hide = true },
    function(code, _signal)
      got_code = code
    end
  )
  stdout:read_start(function(err, chunk)
    if err or chunk == nil then
      stdout:read_stop()
      stdout:close()
    else
      table.insert(data, chunk)
    end
  end)

  local errdata = {}
  stderr:read_start(function(err, chunk)
    if err or chunk == nil then
      stderr:read_stop()
      stderr:close()
    else
      table.insert(errdata, chunk)
      -- print(chunk)
    end
  end)

  while not stdout:is_closing() or got_code == nil do
    uv.run('once')
  end

  if got_code ~= 0 then
    error('command ' .. vim.inspect(cmd) .. 'unexpectedly exited with status ' .. got_code)
  end
  vim.schedule(function()
    -- vim.print(cmd)
    if #errdata > 0 then
      errdata = vim.split(table.concat(errdata), '\n')
      M._errdata = errdata
      -- vim.print(errdata)
      -- vim.cmd.cgete([[luaeval('require("nffi.util")._errdata')]])
      vim.cmd.cadde([[luaeval('require("nffi.util")._errdata')]])
    end
  end)
  handle:close()
  return table.concat(data)
end

--- @param str string
--- @param leave_indent? integer
--- @return string
function M.dedent(str, leave_indent)
  -- Last blank line often has non-matching indent, so remove it.
  str = str:gsub('\n[ ]+$', '\n')
  return (vim.text.indent(leave_indent or 0, str))
end

return M
