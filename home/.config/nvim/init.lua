-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")

-- Strong clipboard setup for X11 + WezTerm
vim.opt.clipboard = "unnamedplus"

-- Force xclip as clipboard provider (very reliable with WezTerm)
vim.g.clipboard = {
  name = 'xclip',
  copy = {
    ['+'] = 'xclip -i -selection clipboard',
    ['*'] = 'xclip -i -selection primary',
  },
  paste = {
    ['+'] = 'xclip -o -selection clipboard',
    ['*'] = 'xclip -o -selection primary',
  },
  cache_enabled = 0,
}
