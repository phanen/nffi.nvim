"libnvim" (from neovim's testsuite).

## usage

```lua
vim.env.NVIM_ROOT = '/home/phan/b/neovim'
local globals = require('nffi.cimport').cimport('src/nvim/globals.h')
```
