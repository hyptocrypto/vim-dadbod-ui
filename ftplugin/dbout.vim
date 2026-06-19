nnoremap <silent><buffer> <Plug>(DBUI_JumpToForeignKey) :call db_ui#dbout#jump_to_foreign_table()<CR>
nnoremap <silent><buffer> <Plug>(DBUI_YankCellValue) :call db_ui#dbout#get_cell_value()<CR>
nnoremap <silent><buffer> <Plug>(DBUI_YankHeader) :call db_ui#dbout#yank_header()<CR>
nnoremap <silent><buffer> <Plug>(DBUI_ToggleResultLayout) :call db_ui#dbout#toggle_layout()<CR>
nnoremap <silent><buffer> <Plug>(DBUI_EditMode) :call db_ui#edit#enter_edit_mode()<CR>
omap <silent><buffer> ic :call db_ui#dbout#get_cell_value()<CR>

setlocal foldmethod=expr foldexpr=db_ui#dbout#foldexpr(v:lnum) | silent! normal!zo
setlocal foldmethod=manual
setlocal synmaxcol=200
setlocal nowrap
setlocal norelativenumber
setlocal nocursorline

if get(g:, 'db_ui_disable_mappings', 0) || get(g:, 'db_ui_disable_mappings_dbout', 0)
  finish
endif

call db_ui#utils#set_mapping('<C-]>', '<Plug>(DBUI_JumpToForeignKey)')
call db_ui#utils#set_mapping('vic', '<Plug>(DBUI_YankCellValue)')
call db_ui#utils#set_mapping('yh', '<Plug>(DBUI_YankHeader)')
call db_ui#utils#set_mapping('<Leader>R', '<Plug>(DBUI_ToggleResultLayout)')
call db_ui#utils#set_mapping('e', '<Plug>(DBUI_EditMode)')
