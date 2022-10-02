local status, floaterm =  pcall(require, 'floaterm')

if not status then
    return
end

floaterm.setup {}

vim.keymap.set('n', '<leader>t', '<CMD>:<FloatermNewCR>')
vim.keymap.set('t', '<Esc>', '<C-\\><C-n><CMD>lua require("floaterm").toggle()<CR>')
