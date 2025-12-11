---@diagnostic disable: need-check-nil, undefined-field
local ffi = require('ffi')
local formatc = require('nffi.formatc')
local Set = require('nffi.set')
local Preprocess = require('nffi.preprocess')
local utils = require('nffi.util')
local paths = utils.paths
-- local say = require('say')

local trim = vim.trim

-- add some standard header locations
for _, p in ipairs(paths.include_paths) do
  Preprocess.add_to_include_path(p)
end

-- add some nonstandard header locations
if paths.apple_sysroot ~= '' then
  Preprocess.add_apple_sysroot(paths.apple_sysroot)
end

local child_pid = 0 --- @type integer?
--- @generic F: function
--- @param func F
--- @return F
local function only_separate(func)
  return function(...)
    if child_pid ~= 0 then
      error('This function must be run in a separate process only')
    end
    return func(...)
  end
end

--- @class ChildCall
--- @field func function
--- @field args any[]

--- @class ChildCallLog
--- @field func string
--- @field args any[]
--- @field ret any?

local child_calls_init = {} --- @type ChildCall[]
local child_calls_mod --- @type ChildCall[]
local child_calls_mod_once --- @type ChildCall[]?

local function child_call(func, ret)
  return function(...)
    local child_calls = child_calls_mod or child_calls_init
    if child_pid ~= 0 then
      child_calls[#child_calls + 1] = { func = func, args = { ... } }
      return ret
    else
      return func(...)
    end
  end
end

-- Run some code at the start of the child process, before running the test
-- itself. Is supposed to be run in `before_each`.
--- @param func function
local function child_call_once(func, ...)
  if child_pid ~= 0 then
    child_calls_mod_once[#child_calls_mod_once + 1] = { func = func, args = { ... } }
  else
    func(...)
  end
end

local child_cleanups_mod_once = nil --- @type ChildCall[]?

-- Run some code at the end of the child process, before exiting. Is supposed to
-- be run in `before_each` because `after_each` is run after child has exited.
local function child_cleanup_once(func, ...)
  local child_cleanups = child_cleanups_mod_once
  if child_pid ~= 0 then
    child_cleanups[#child_cleanups + 1] = { func = func, args = { ... } }
  else
    func(...)
  end
end

-- Unittests are run from debug nvim binary in lua interpreter mode.
local libnvim = ffi.C

local lib = setmetatable({}, {
  __index = only_separate(function(_, idx)
    return libnvim[idx]
  end),
  __newindex = child_call(function(_, idx, val)
    libnvim[idx] = val
  end),
})

-- a Set that keeps around the lines we've already seen
local cdefs_init = Set:new()
local imported = Set:new()
local pragma_pack_id = 1

-- some things are just too complex for the LuaJIT C parser to digest. We
-- usually don't need them anyway.
--- @param body string
local function filter_complex_blocks(body)
  local result = {} --- @type string[]

  for line in body:gmatch('[^\r\n]+') do
    if
      not (
        string.find(line, '(^)', 1, true) ~= nil
        or string.find(line, '_ISwupper', 1, true)
        or string.find(line, '_Float')
        or string.find(line, '__s128')
        or string.find(line, '__u128')
        or string.find(line, 'msgpack_zone_push_finalizer')
        or string.find(line, 'msgpack_unpacker_reserve_buffer')
        or string.find(line, 'value_init_')
        or string.find(line, 'UUID_NULL') -- static const uuid_t UUID_NULL = {...}
        or string.find(line, 'inline _Bool')
        -- used by musl libc headers on 32-bit arches via __REDIR marco
        or string.find(line, '__typeof__')
        -- used by macOS headers
        or string.find(line, 'typedef enum : ')
        or string.find(line, 'mach_vm_range_recipe')
        or string.find(line, 'struct timespec')
      )
    then
      -- Remove GCC's extension keyword which is just used to disable warnings.
      line = string.gsub(line, '__extension__', '')

      -- HACK: remove bitfields from specific structs as luajit can't seem to handle them.
      if line:find('struct VTermState') then
        line = string.gsub(line, 'state : 8;', 'state;')
      end
      if line:find('VTermStringFragment') then
        line = string.gsub(line, 'size_t.*len : 30;', 'size_t len;')
      end
      result[#result + 1] = line
    end
  end

  return table.concat(result, '\n')
end

local cdef = ffi.cdef

--- @param preprocess_cache table<string,string>
--- @param path string
local function cimportstr(preprocess_cache, path)
  if imported:contains(path) then
    return lib
  end
  local body = preprocess_cache[path]
  if body == '' then
    return lib
  end
  -- print(path)
  -- print(body)
  local ok, emsg = pcall(cdef, body)
  -- assert(ok or emsg:match('redefine'))
  assert(ok, emsg)
  imported:add(path)

  return lib
end

local previous_defines_init = [[
typedef struct { char bytes[16]; } __attribute__((aligned(16))) __uint128_t;
typedef struct { char bytes[16]; } __attribute__((aligned(16))) __float128;
]]

local preprocess_cache_init = {} --- @type table<string,string>

-- use this helper to import C files, you can pass multiple paths at once,
-- this helper will return the C namespace of the nvim library.
local function cimport(...)
  local previous_defines --- @type string
  local preprocess_cache --- @type table<string,string>
  local cdefs
  preprocess_cache = preprocess_cache_init
  previous_defines = previous_defines_init
  cdefs = cdefs_init
  for _, path in ipairs({ ... }) do
    if not (path:sub(1, 1) == '/' or path:sub(1, 1) == '.' or path:sub(2, 2) == ':') then
      path = './' .. path
    end
    path = vim.fs.normalize(vim.fs.joinpath(vim.env.NVIM_ROOT, path))
    -- print(path)
    if not preprocess_cache[path] then
      local body --- @type string
      body, previous_defines = Preprocess.preprocess(previous_defines, path)
      -- print(body)
      -- format it (so that the lines are "unique" statements), also filter out
      -- Objective-C blocks
      if os.getenv('NVIM_TEST_PRINT_I') == '1' then
        local lnum = 0
        for line in body:gmatch('[^\n]+') do
          lnum = lnum + 1
          print(lnum, line)
        end
      end
      body = formatc(body)
      body = filter_complex_blocks(body)
      -- add the formatted lines to a set
      local new_cdefs = Set:new()
      for line in body:gmatch('[^\r\n]+') do
        line = trim(line)
        -- give each #pragma pack a unique id, so that they don't get removed
        -- if they are inserted into the set
        -- (they are needed in the right order with the struct definitions,
        -- otherwise luajit has wrong memory layouts for the structs)
        if line:match('#pragma%s+pack') then
          --- @type string
          line = line .. ' // ' .. pragma_pack_id
          pragma_pack_id = pragma_pack_id + 1
        end
        new_cdefs:add(line)
      end

      -- subtract the lines we've already imported from the new lines, then add
      -- the new unique lines to the old lines (so they won't be imported again)
      new_cdefs:diff(cdefs)
      cdefs:union(new_cdefs)
      -- request a sorted version of the new lines (same relative order as the
      -- original preprocessed file) and feed that to the LuaJIT ffi
      local new_lines = new_cdefs:to_table()
      if os.getenv('NVIM_TEST_PRINT_CDEF') == '1' then
        for lnum, line in ipairs(new_lines) do
          print(lnum, line)
        end
      end
      body = table.concat(new_lines, '\n')

      preprocess_cache[path] = body
    end
    cimportstr(preprocess_cache, path)
  end
  return lib
end

local function cimport_immediate(...)
  -- local saved_pid = child_pid
  -- child_pid = 0
  local err, emsg = pcall(cimport, ...)
  -- child_pid = saved_pid
  if not err then
    -- io.stderr:write(tostring(emsg) .. '\n')
    print(tostring(emsg) .. '\n')
  else
    return lib
  end
end

-- take a pointer to a C-allocated string and return an interned
-- version while also freeing the memory
local function internalize(cdata, len)
  ffi.gc(cdata, libnvim.free)
  return ffi.string(cdata, len)
end

local cstr = ffi.typeof('char[?]')
local function to_cstr(string)
  return cstr(#string + 1, string)
end

cimport_immediate('./test/unit/fixtures/posix.h')

local sc = {}

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

--- @param lst string[]
--- @return string
local function format_list(lst)
  local ret = {} --- @type string[]
  for _, v in ipairs(lst) do
    ret[#ret + 1] = assert:format({ v, n = 1 })[1]
  end
  return table.concat(ret, ', ')
end

if os.getenv('NVIM_TEST_PRINT_SYSCALLS') == '1' then
  for k_, v_ in pairs(sc) do
    (function(k, v)
      sc[k] = function(...)
        local rets = { v(...) }
        io.stderr:write(('%s(%s) = %s\n'):format(k, format_list({ ... }), format_list(rets)))
        return unpack(rets)
      end
    end)(k_, v_)
  end
end

-- say:set('assertion.just_fail.positive', '%s')
-- say:set('assertion.just_fail.negative', '%s')
-- assert:register('assertion', 'just_fail', just_fail, 'assertion.just_fail.positive', 'assertion.just_fail.negative')

--- @type function
local _debug_log

local debug_log = only_separate(function(...)
  return _debug_log(...)
end)

local function cppimport(path)
  return cimport(paths.test_source_path .. '/test/includes/pre/' .. path)
end

cimport(
  './src/nvim/types_defs.h',
  './src/nvim/main.h',
  './src/nvim/os/time.h',
  './src/nvim/os/fs.h'
)

local function conv_enum(etab, eval)
  local n = tonumber(eval)
  return etab[n] or n
end

local function array_size(arr)
  return ffi.sizeof(arr) / ffi.sizeof(arr[0])
end

local function kvi_size(kvi)
  return array_size(kvi.init_array)
end

local function kvi_init(kvi)
  kvi.capacity = kvi_size(kvi)
  kvi.items = kvi.init_array
  return kvi
end

local function kvi_destroy(kvi)
  if kvi.items ~= kvi.init_array then
    lib.xfree(kvi.items)
  end
end

local function kvi_new(ct)
  return kvi_init(ffi.new(ct))
end

local function make_enum_conv_tab(m, values, skip_pref, set_cb)
  child_call_once(function()
    local ret = {}
    for _, v in ipairs(values) do
      local str_v = v
      if v:sub(1, #skip_pref) == skip_pref then
        str_v = v:sub(#skip_pref + 1)
      end
      ret[tonumber(m[v])] = str_v
    end
    set_cb(ret)
  end)
end

local function ptr2addr(ptr)
  return tonumber(ffi.cast('intptr_t', ffi.cast('void *', ptr)))
end

---@type ffi.cdata*
local s = ffi.new('char[64]', { 0 })

local function ptr2key(ptr)
  libnvim.snprintf(s, ffi.sizeof(s), '%p', ffi.cast('void *', ptr))
  return ffi.string(s)
end

--- @class test.unit.testutil.module
local M = {
  cimport = cimport,
  cppimport = cppimport,
  internalize = internalize,
  ffi = ffi,
  lib = lib,
  cstr = cstr,
  to_cstr = to_cstr,
  NULL = ffi.cast('void*', 0),
  OK = 1,
  FAIL = 0,
  only_separate = only_separate,
  child_call_once = child_call_once,
  child_cleanup_once = child_cleanup_once,
  sc = sc,
  conv_enum = conv_enum,
  array_size = array_size,
  kvi_destroy = kvi_destroy,
  kvi_size = kvi_size,
  kvi_init = kvi_init,
  kvi_new = kvi_new,
  make_enum_conv_tab = make_enum_conv_tab,
  ptr2addr = ptr2addr,
  ptr2key = ptr2key,
  debug_log = debug_log,
}
--- @class test.unit.testutil: test.unit.testutil.module, test.testutil
M = vim.tbl_extend('error', M, utils)

return M
