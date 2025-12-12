"libnvim" (from neovim's testsuite).

## usage

```lua
-- pacman -S neovim-git-debug (or cloned src)
vim.env.NVIM_ROOT = '/usr/src/debug/neovim-git/neovim/'
local nffi = require('nffi')
nffi.cimport('src/nvim/terminal.c')
api.nvim_create_autocmd({ 'FileType' }, {
  pattern = 'fzf',
  callback = function()
    local term = C.find_buffer_by_handle(fn.bufnr(), ffi.new('Error')).terminal
    if nffi.ptr2addr(term) ~= 0 then
      C.vterm_screen_enable_reflow(term.vts, false)
    end
  end,
})
```
