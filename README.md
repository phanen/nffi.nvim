"libnvim" (from neovim's testsuite).

## usage

```lua
-- vim.env.NVIM_ROOT = '/usr/src/debug/neovim-git/neovim/'
vim.env.NVIM_ROOT = '/path/to/neovim-src'
local ffi = require('ffi')
api.nvim_create_autocmd({ 'FileType' }, {
  pattern = 'fzf',
  callback = function()
    local nffi = require('nffi')
    nffi.load_cache()
    nffi.cimport('src/nvim/terminal.c')
    nffi.dump_cache()
    local term = ffi.C.find_buffer_by_handle(fn.bufnr(), ffi.new('Error')).terminal
    if nffi.ptr2addr(term) ~= 0 then
      ffi.C.vterm_screen_enable_reflow(term.vts, false)
    end
  end,
})
```

## credits
* https://github.com/neovim/neovim/blob/93526754a9e98a835d58e8ee7ba87d8410c064cf/test/unit/testutil.lua#L898
