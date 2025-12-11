local uv = vim.uv
local Paths = require('nffi.paths')

--- Functions executing in the context of the test runner (not the current nvim test session).
--- @class test.testutil
local M = {
  paths = Paths,
}

---@vararg cmd string[]
---@return string?
function M.run(cmd)
  local obj = vim.system(cmd):wait()
  return obj.code == 0 and obj.stdout or nil
end

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
