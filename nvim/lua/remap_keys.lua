local keymap = vim.keymap

-- Increment/decrement
keymap.set('n', '+', '<C-a>')
keymap.set('n', '-', '<C-x>')

-- New Tab
keymap.set('n', 'te', ':tabedit')
-- New Terminal
keymap.set('n', 't', ':FloatermNew')
