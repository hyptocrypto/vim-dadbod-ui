nnoremap <silent><buffer> <Plug>(DBUI_ExecuteMeta) :call db_ui#meta#run()<CR>

if get(g:, 'db_ui_disable_mappings', 0) || get(g:, 'db_ui_disable_mappings_sql', 0)
  finish
endif

call db_ui#utils#set_mapping('<Leader>W', '<Plug>(DBUI_SaveQuery)')
call db_ui#utils#set_mapping('<Leader>E', '<Plug>(DBUI_EditBindParameters)')
call db_ui#utils#set_mapping('<Leader>S', '<Plug>(DBUI_ExecuteQuery)')
call db_ui#utils#set_mapping('<Leader>S', '<Plug>(DBUI_ExecuteQuery)', 'v')
call db_ui#utils#set_mapping('<CR>', '<Plug>(DBUI_ExecuteMeta)')
