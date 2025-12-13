---@diagnostic disable: need-check-nil
local ffi = require('ffi')
local formatc = require('nffi.formatc')
local Set = require('nffi.set')
local Preprocess = require('nffi.preprocess')
local utils = require('nffi.util')
local paths = utils.paths

local trim = vim.trim

local is_headless = #vim.api.nvim_list_uis() == 0
local inspect = function(x)
  return type(x) == 'string' and x or vim.inspect(x)
end
local p = function(...)
  print(unpack(vim.tbl_map(inspect, { ... })))
  if is_headless then
    print('\n')
  end
end

-- add some standard header locations
for _, p in ipairs(paths.include_paths) do
  Preprocess.add_to_include_path(p)
end

local __FILE__ = debug.getinfo(1, 'S').source:gsub('^@', '')

local function patch_includes()
  local p = vim.fs.joinpath(vim.fn.fnamemodify(__FILE__, ':h:h:h:p'), 'patch')
  local ps = {
    ('%s/src/nvim'):format(p),
    ('%s/src'):format(p),
    ('%s/build/src/nvim/auto'):format(p),
    ('%s/build/include'):format(p),
    ('%s'):format(p),
  }
  Preprocess.add_to_include_path(unpack(ps))
end

-- add some nonstandard header locations
if paths.apple_sysroot ~= '' then
  Preprocess.add_apple_sysroot(paths.apple_sysroot)
end

local libnvim = ffi.C

local lib = setmetatable({}, {
  __index = function(_, idx)
    return libnvim[idx]
  end,
  __newindex = function(_, idx, val)
    libnvim[idx] = val
  end,
})

-- a Set that keeps around the lines we've already seen
local cdefs = Set:new()
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
        line:find('(^)', 1, true) ~= nil
        or line:find('_ISwupper', 1, true)
        or line:find('_Float')
        or line:find('__s128')
        or line:find('__u128')
        or line:find('msgpack_zone_push_finalizer')
        or line:find('msgpack_unpacker_reserve_buffer')
        or line:find('value_init_')
        or line:find('UUID_NULL') -- static const uuid_t UUID_NULL = {...}
        or line:find('inline _Bool')
        -- used by musl libc headers on 32-bit arches via __REDIR marco
        or line:find('__typeof__')
        -- used by macOS headers
        or line:find('typedef enum : ')
        or line:find('mach_vm_range_recipe')
        or line:find('struct timespec')
        or line:find('^%s+static%s+')
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

local previous_defines = [[
typedef struct { char bytes[16]; } __attribute__((aligned(16))) __uint128_t;
typedef struct { char bytes[16]; } __attribute__((aligned(16))) __float128;
]]

local preprocess_cache = {} --- @type table<string,string>

--- @param path string
--- @param body string
local function cimportstr(path, body)
  if imported:contains(path) or body == '' then
    return
  end
  local ok, emsg = pcall(cdef, body)
  -- assert(ok or emsg:match('redefine'))
  assert(ok, emsg)
  imported:add(path)
  return
end

---@param path string
---@return string
local function preprocess(path)
  local body --- @type string
  body, previous_defines = Preprocess.preprocess(previous_defines, path)
  -- format it (so that the lines are "unique" statements), also filter out
  -- Objective-C blocks
  -- stylua: ignore
  if os.getenv('NVIM_TEST_PRINT_I') == '1' then local lnum = 0 for line in body:gmatch('[^\n]+') do lnum = lnum + 1 p(lnum, line) end end
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
  -- stylua: ignore
  if os.getenv('NVIM_TEST_PRINT_CDEF') == '1' then for lnum, line in ipairs(new_lines) do p(lnum, line) end end
  return table.concat(new_lines, '\n')
end

local _init ---@type fun()?

-- use this helper to import C files, you can pass multiple paths at once,
-- this helper will return the C namespace of the nvim library.
local function cimport(...)
  if _init then
    _init()
  end
  for _, path in ipairs({ ... }) do
    local pathkey = vim.fs.normalize(vim.fs.joinpath(paths.root, path))
    preprocess_cache[pathkey] = preprocess_cache[path] or preprocess(path)
    cimportstr(path, preprocess_cache[pathkey])
  end
  return lib
end

_init = function()
  _init = nil
  return cimport(
    'src/nvim/types_defs.h',
    'src/nvim/main.h',
    'src/nvim/os/time.h',
    'src/nvim/os/fs.h'
  )
end

local function get_progpath_mtime()
  -- Get file stat for vim.v.progpath
  local stat = vim.uv.fs_stat(vim.v.progpath)
  return stat and stat.mtime.sec or 0
end

local function get_cache_path()
  local cache_dir = vim.fn.stdpath('cache') .. '/ffi_cdef'
  local mtime = get_progpath_mtime()
  vim.fn.mkdir(cache_dir, 'p')
  return string.format('%s/nffi_cdef_cache_%d.lua', cache_dir, mtime)
end

local function dump_cache()
  local cache_path = get_cache_path()
  vim.fn.mkdir(vim.fs.dirname(cache_path), 'p')
  local f = assert(loadstring('return ' .. vim.inspect(preprocess_cache)))
  assert(io.open(cache_path, 'w')):write(string.dump(f))
end

local function load_cache()
  local cache_path = get_cache_path()
  local f = loadfile(cache_path)
  if f then
    preprocess_cache = f()
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

local function cppimport(path)
  return cimport(paths.test_source_path .. '/test/includes/pre/' .. path)
end

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

local function ptr2addr(ptr)
  return tonumber(ffi.cast('intptr_t', ffi.cast('void *', ptr)))
end

---@type ffi.cdata*
local s = ffi.new('char[64]', { 0 })

local function ptr2key(ptr)
  libnvim.snprintf(s, ffi.sizeof(s), '%p', ffi.cast('void *', ptr))
  return ffi.string(s)
end

local sc = setmetatable({}, {
  __index = function(_, k)
    return require('nffi.syscall')[k]
  end,
})

return {
  patch_includes = patch_includes,
  cimport = cimport,
  dump_cache = dump_cache,
  load_cache = load_cache,
  cppimport = cppimport,
  internalize = internalize,
  ffi = ffi,
  lib = lib,
  cstr = cstr,
  to_cstr = to_cstr,
  NULL = ffi.cast('void*', 0),
  OK = 1,
  FAIL = 0,
  sc = sc,
  conv_enum = conv_enum,
  array_size = array_size,
  kvi_destroy = kvi_destroy,
  kvi_size = kvi_size,
  kvi_init = kvi_init,
  kvi_new = kvi_new,
  ptr2addr = ptr2addr,
  ptr2key = ptr2key,
}
