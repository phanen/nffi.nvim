"libnvim" (from neovim's testsuite).

## usage

```lua
-- pacman -S neovim-git-debug (or cloned src)
vim.env.NVIM_ROOT = '/usr/src/debug/neovim-git/neovim/'
_G.nffi = require('nffi')
nffi.cimport(
  'src/nvim/globals.h',
  'src/nvim/buffer_defs.h',
  'src/nvim/vterm/vterm.h',
  'src/nvim/terminal.h',
  'src/nvim/grid.h',
  'src/nvim/mbyte.h',
  'src/nvim/vterm/encoding.h',
  'src/nvim/vterm/keyboard.h',
  'src/nvim/vterm/mouse.h',
  'src/nvim/vterm/parser.h',
  'src/nvim/vterm/pen.h',
  'src/nvim/vterm/screen.h',
  'src/nvim/vterm/state.h',
  'src/nvim/vterm/vterm.h',
  'src/nvim/vterm/vterm_internal_defs.h'
)
ffi.cdef [[
  typedef struct {
    size_t cols;
    VTermScreenCell cells[];
  } ScrollbackLine;
  struct terminal {
    TerminalOptions opts;  // options passed to terminal_open
    VTerm *vt;
    VTermScreen *vts;
    // buffer used to:
    //  - convert VTermScreen cell arrays into utf8 strings
    //  - receive data from libvterm as a result of key presses.
    char textbuf[0x1fff];

    ScrollbackLine **sb_buffer;       // Scrollback storage.
    size_t sb_current;                // Lines stored in sb_buffer.
    size_t sb_size;                   // Capacity of sb_buffer.
    // "virtual index" that points to the first sb_buffer row that we need to
    // push to the terminal buffer when refreshing the scrollback. When negative,
    // it actually points to entries that are no longer in sb_buffer (because the
    // window height has increased) and must be deleted from the terminal buffer
    int sb_pending;

    char *title;     // VTermStringFragment buffer
    size_t title_len;    // number of rows pushed to sb_buffer
    size_t title_size;   // sb_buffer size

    // buf_T instance that acts as a "drawing surface" for libvterm
    // we can't store a direct reference to the buffer because the
    // refresh_timer_cb may be called after the buffer was freed, and there's
    // no way to know if the memory was reused.
    handle_T buf_handle;
    // program exited
    bool closed;
    // when true, the terminal's destruction is already enqueued.
    bool destroy;

    // some vterm properties
    bool forward_mouse;
    int invalid_start, invalid_end;   // invalid rows in libvterm screen
    struct {
      int row, col;
      int shape;
      bool visible;  ///< Terminal wants to show cursor.
      ///< `TerminalState.cursor_visible` indicates whether it is actually shown.
      bool blink;
    } cursor;

    struct {
      bool resize;          ///< pending width/height
      bool cursor;          ///< pending cursor shape or blink change
      StringBuilder *send;  ///< When there is a pending TermRequest autocommand, block and store input.
      MultiQueue *events;   ///< Events waiting for refresh.
    } pending;

    bool theme_updates;  ///< Send a theme update notification when 'bg' changes

    bool color_set[16];

    char *selection_buffer;  ///< libvterm selection buffer
    StringBuilder selection;  ///< Growable array containing full selection data

    StringBuilder termrequest_buffer;  ///< Growable array containing unfinished request sequence

    size_t refcount;                  // reference count
  };
  ]]
api.nvim_create_autocmd({ 'FileType' }, {
  pattern = 'fzf',
  callback = function()
    local term = ffi.C.find_buffer_by_handle(fn.bufnr(), ffi.new('Error')).terminal
    if nffi.ptr2addr(term) == 0 then
      return
    end
    ffi.C.vterm_screen_enable_reflow(term.vts, false)
  end,
})
```
