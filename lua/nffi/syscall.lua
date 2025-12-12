---@diagnostic disable: need-check-nil, undefined-field
local sc = {}

local ffi = require('ffi')
local to_cstr = require('nffi').to_cstr
local libnvim = ffi.C

require('nffi').cimport('./test/unit/fixtures/posix.h')
function sc.fork()
  return tonumber(libnvim.fork())
end

function sc.pipe()
  local ret = ffi.new('int[2]', { -1, -1 })
  local _ = ffi.errno(0)
  local res = libnvim.pipe(ret)
  if res ~= 0 then
    local err = ffi.errno(0)
    assert(res == 0, ('pipe() error: %u: %s'):format(err, ffi.string(libnvim.strerror(err))))
  end
  assert(ret[0] ~= -1 and ret[1] ~= -1)
  return ret[0], ret[1]
end

--- @return string
function sc.read(rd, len)
  local ret = ffi.new('char[?]', len, { 0 })
  local total_bytes_read = 0
  local _ = ffi.errno(0)
  while total_bytes_read < len do
    local bytes_read =
      tonumber(libnvim.read(rd, ffi.cast('void*', ret + total_bytes_read), len - total_bytes_read))
    if bytes_read == -1 then
      local err = ffi.errno(0)
      if err ~= libnvim.kPOSIXErrnoEINTR then
        assert(false, ('read() error: %u: %s'):format(err, ffi.string(libnvim.strerror(err))))
      end
    elseif bytes_read == 0 then
      break
    else ---@diagnostic disable-next-line: assign-type-mismatch
      total_bytes_read = total_bytes_read + bytes_read
    end
  end
  return ffi.string(ret, total_bytes_read)
end

function sc.write(wr, s)
  local wbuf = to_cstr(s)
  local total_bytes_written = 0
  local _ = ffi.errno(0)
  while total_bytes_written < #s do
    local bytes_written = tonumber(
      libnvim.write(wr, ffi.cast('void*', wbuf + total_bytes_written), #s - total_bytes_written)
    )
    if bytes_written == -1 then
      local err = ffi.errno(0)
      if err ~= libnvim.kPOSIXErrnoEINTR then
        assert(
          false,
          ("write() error: %u: %s ('%s')"):format(err, ffi.string(libnvim.strerror(err)), s)
        )
      end
    elseif bytes_written == 0 then
      break
    else ---@diagnostic disable-next-line: assign-type-mismatch
      total_bytes_written = total_bytes_written + bytes_written
    end
  end
  return total_bytes_written
end

sc.close = libnvim.close

--- @param pid integer
--- @return integer
function sc.wait(pid)
  local _ = ffi.errno(0)
  local stat_loc = ffi.new('int[1]', { 0 })
  while true do
    local r = libnvim.waitpid(pid, stat_loc, libnvim.kPOSIXWaitWUNTRACED)
    if r == -1 then
      local err = ffi.errno(0)
      if err == libnvim.kPOSIXErrnoECHILD then
        break
      elseif err ~= libnvim.kPOSIXErrnoEINTR then
        assert(false, ('waitpid() error: %u: %s'):format(err, ffi.string(libnvim.strerror(err))))
      end
    else
      assert(r == pid)
    end
  end
  return stat_loc[0]
end

sc.exit = libnvim._exit
