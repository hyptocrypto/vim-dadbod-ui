" Inline cell editing for dbout buffers.
" Supports PostgreSQL (pipe-delimited output) and SQLite (column or pipe mode).
"
" Usage in dbout buffer:
"   e        enter edit mode (make cells editable)
"   :w       commit changes as UPDATE statements, refresh
"   q / Esc  cancel and restore buffer

let s:pg_schemes      = ['postgres', 'postgresql']
let s:sqlite_schemes  = ['sqlite', 'sqlite3']
let s:supported       = s:pg_schemes + s:sqlite_schemes

" ─── Public API ──────────────────────────────────────────────────────────────

function! db_ui#edit#enter_edit_mode() abort
  if get(b:, 'db_ui_edit_mode', 0)
    call db_ui#notifications#info('Already in edit mode — :w to save, q/<Esc> to cancel.')
    return
  endif

  if !exists('b:db') || empty(b:db)
    call db_ui#notifications#error('Edit mode: no database connection on this buffer.')
    return
  endif

  let db_url = type(b:db) ==# type('') ? b:db : get(b:db, 'db_url', '')
  if empty(db_url)
    call db_ui#notifications#error('Edit mode: cannot resolve DB URL.')
    return
  endif

  let parsed      = db#url#parse(db_url)
  let scheme_name = tolower(get(parsed, 'scheme', ''))
  if index(s:supported, scheme_name) < 0
    call db_ui#notifications#error('Edit mode: scheme "'.scheme_name.'" not supported. Supported: '.join(s:supported, ', '))
    return
  endif

  let lines  = getline(1, '$')
  let struct = s:parse_buffer_structure(lines, scheme_name)
  if empty(struct)
    call db_ui#notifications#error('Edit mode: could not parse output table format.')
    return
  endif

  let input_file = type(b:db) ==# type({}) ? get(b:db, 'input', '') : ''
  let sql_info   = s:get_sql_info(input_file)

  if s:is_join_query(sql_info.sql)
    call s:enter_join_edit_mode(db_url, scheme_name, struct, lines, sql_info)
    return
  endif

  if empty(sql_info.table_raw)
    call db_ui#notifications#error('Edit mode: could not detect table name. Only simple SELECT FROM <table> queries support inline editing.')
    return
  endif

  let pk_cols = s:get_pk_columns(db_url, sql_info.table_raw, scheme_name)
  if empty(pk_cols)
    call db_ui#notifications#error('Edit mode: no primary key found for "'.sql_info.table_raw.'".')
    return
  endif

  let pk_visible = filter(copy(pk_cols), 'index(struct.col_names, v:val) >= 0')
  let pk_missing = filter(copy(pk_cols), 'index(struct.col_names, v:val) < 0')

  if !empty(pk_missing) && !empty(pk_visible)
    call db_ui#notifications#error('Edit mode: partial composite PK in result ('
          \ . join(pk_visible, ', ') . ' visible, ' . join(pk_missing, ', ')
          \ . ' missing) — include all PK columns or none.')
    return
  elseif !empty(pk_missing)
    " All PK cols hidden — hidden-PK path (composite PKs not supported here)
    if len(pk_cols) > 1
      call db_ui#notifications#error('Edit mode: composite PK (' . join(pk_cols, ', ')
            \ . ') not in SELECT — use SELECT * or include all PK columns.')
      return
    endif
    let pk_values = s:fetch_pk_values(db_url, sql_info.sql, pk_cols[0], scheme_name)
    if empty(pk_values)
      call db_ui#notifications#error('Edit mode: could not fetch PK values for "'
            \ . pk_cols[0] . '" — make sure the DB is reachable and the table has rows.')
      return
    endif
    let pk_hidden = 1
  else
    let pk_values = []
    let pk_hidden = 0
  endif

  let b:db_ui_edit_mode         = 1
  let b:db_ui_edit_snapshot     = copy(lines)
  let b:db_ui_edit_col_names    = struct.col_names
  let b:db_ui_edit_col_bounds   = struct.col_bounds
  let b:db_ui_edit_pk_cols      = pk_cols
  let b:db_ui_edit_pk_col       = pk_cols[0]
  let b:db_ui_edit_pk_hidden    = pk_hidden
  let b:db_ui_edit_pk_values    = pk_values
  let b:db_ui_edit_table        = sql_info.table_raw
  let b:db_ui_edit_table_sql    = sql_info.table_sql
  let b:db_ui_edit_data_start   = struct.data_start
  let b:db_ui_edit_data_end     = struct.data_end
  let b:db_ui_edit_scheme       = scheme_name
  let b:db_ui_edit_use_pipe     = struct.use_pipe

  augroup db_ui_edit_write
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> call db_ui#edit#save_changes()
  augroup END

  nnoremap <buffer> <nowait> <Esc> :call db_ui#edit#exit_edit_mode()<CR>
  nnoremap <buffer> <nowait> q     :call db_ui#edit#exit_edit_mode()<CR>

  setlocal modifiable
  call db_ui#notifications#info('Edit mode ON — table: '.sql_info.table_raw.' | PK: '.join(pk_cols, ', ').' | :w to save, q/<Esc> to cancel')
endfunction


function! db_ui#edit#save_changes() abort
  if !get(b:, 'db_ui_edit_mode', 0)
    return
  endif

  if get(b:, 'db_ui_edit_join_mode', 0)
    call s:save_join_changes()
    return
  endif

  let col_names  = b:db_ui_edit_col_names
  let col_bounds = b:db_ui_edit_col_bounds
  let pk_cols    = get(b:, 'db_ui_edit_pk_cols', [b:db_ui_edit_pk_col])
  let pk_col     = b:db_ui_edit_pk_col
  let pk_hidden  = b:db_ui_edit_pk_hidden
  let pk_values  = b:db_ui_edit_pk_values
  let table_sql  = b:db_ui_edit_table_sql
  let data_start = b:db_ui_edit_data_start
  let data_end   = b:db_ui_edit_data_end
  let snapshot   = b:db_ui_edit_snapshot
  let use_pipe   = b:db_ui_edit_use_pipe

  " Map each visible PK col to its index in col_names
  let pk_idx_map = {}
  if !pk_hidden
    for pc in pk_cols
      let idx = index(col_names, pc)
      if idx >= 0
        let pk_idx_map[pc] = idx
      endif
    endfor
  endif

  let orig_rows  = s:collect_rows(snapshot,        data_start, data_end, use_pipe, col_bounds)
  let curr_rows  = s:collect_rows(getline(1, '$'), data_start, data_end, use_pipe, col_bounds)

  if len(orig_rows) !=# len(curr_rows)
    call db_ui#notifications#error('Row count changed — only cell edits are supported. Discard changes with q.')
    return
  endif

  let updates = []
  for i in range(len(orig_rows))
    let orig = orig_rows[i]
    let curr = curr_rows[i]
    if orig ==# curr
      continue
    endif

    " Build WHERE clause values for this row.
    if pk_hidden
      if i >= len(pk_values) || empty(pk_values[i])
        call db_ui#notifications#error('Row '.i.': PK value not available — cannot build WHERE clause.')
        continue
      endif
      let where_vals = {pk_col: pk_values[i]}
    else
      let where_vals = {}
      let where_ok   = 1
      for [pc, pidx] in items(pk_idx_map)
        let v = trim(orig[pidx])
        if empty(v)
          call db_ui#notifications#error('Row '.i.': PK "'.pc.'" is NULL — cannot build WHERE clause.')
          let where_ok = 0
          break
        endif
        let where_vals[pc] = v
      endfor
      if !where_ok
        continue
      endif
    endif

    let changes = {}
    for j in range(min([len(orig), len(curr), len(col_names)]))
      if trim(orig[j]) !=# trim(curr[j])
        let changes[col_names[j]] = trim(curr[j])
      endif
    endfor

    if !empty(changes)
      call add(updates, s:build_update(table_sql, where_vals, changes))
    endif
  endfor

  if empty(updates)
    call db_ui#notifications#info('No changes detected.')
    call s:clear_edit_state(0)
    return
  endif

  for sql in updates
    call db_ui#utils#print_debug({'message': 'dbui-edit executing', 'sql': sql})
    try
      exe 'DB ' . sql
    catch /.*/
      call db_ui#notifications#error('UPDATE failed: '.v:exception)
      return
    endtry
  endfor

  " Remove the BufWriteCmd autocmd before refreshing to prevent recursion,
  " but leave the buffer modifiable so dadbod can write fresh results into it.
  augroup db_ui_edit_write
    autocmd! * <buffer>
  augroup END

  let n = len(updates)
  norm R
  " Now lock the buffer (dadbod has already written fresh results above).
  call s:clear_edit_state(0)
  call db_ui#notifications#info(n.' row(s) updated.')
endfunction


function! db_ui#edit#exit_edit_mode() abort
  call s:clear_edit_state(1)
  call db_ui#notifications#info('Edit mode cancelled.')
endfunction


" ─── Private: state management ───────────────────────────────────────────────

function! s:clear_edit_state(restore_snapshot) abort
  augroup db_ui_edit_write
    autocmd! * <buffer>
  augroup END

  silent! nunmap <buffer> <Esc>
  silent! nunmap <buffer> q

  if a:restore_snapshot && exists('b:db_ui_edit_snapshot')
    call setline(1, b:db_ui_edit_snapshot)
    let snap_end = len(b:db_ui_edit_snapshot)
    if snap_end < line('$')
      exe (snap_end + 1).',$delete _'
    endif
  endif

  setlocal nomodifiable nomodified

  unlet! b:db_ui_edit_mode       b:db_ui_edit_snapshot    b:db_ui_edit_col_names
  unlet! b:db_ui_edit_col_bounds b:db_ui_edit_pk_cols     b:db_ui_edit_pk_col
  unlet! b:db_ui_edit_pk_hidden  b:db_ui_edit_pk_values   b:db_ui_edit_table
  unlet! b:db_ui_edit_table_sql  b:db_ui_edit_data_start  b:db_ui_edit_data_end
  unlet! b:db_ui_edit_scheme     b:db_ui_edit_use_pipe
  unlet! b:db_ui_edit_join_mode  b:db_ui_edit_col_table_map  b:db_ui_edit_table_pks
  unlet! b:db_ui_edit_table_pk_values b:db_ui_edit_aliases
endfunction


" ─── Private: buffer parsing ─────────────────────────────────────────────────

" Parse the dbout buffer and return a struct dict, or {} on failure.
" Struct: {col_names, col_bounds, data_start, data_end, use_pipe}
function! s:parse_buffer_structure(lines, scheme_name) abort
  " Find separator line — starts with dashes and contains only [-+ ]
  let sep_idx = -1
  for i in range(len(a:lines))
    let ln = a:lines[i]
    if ln =~# '^-[-+ ]*$' && ln =~# '----'
      let sep_idx = i
      break
    endif
  endfor

  if sep_idx >= 1
    " Standard table format: header / separator / data
    let header_line = a:lines[sep_idx - 1]
    let sep_line    = a:lines[sep_idx]
    let use_pipe    = sep_line =~# '+' ? 1 : 0
    let col_bounds  = s:col_boundaries(sep_line)

    let col_names = use_pipe
          \ ? map(split(header_line, '|'), 'trim(v:val)')
          \ : map(copy(col_bounds), 'trim(a:lines[sep_idx - 1][v:val.from : v:val.to])')
    call filter(col_names, '!empty(v:val)')

    let data_start = sep_idx + 2  " 1-indexed

  elseif !empty(a:lines) && a:lines[0] =~# '|'
    " No separator: pipe-delimited with header on line 1 (SQLite pipe mode)
    let col_names  = map(split(a:lines[0], '|'), 'trim(v:val)')
    call filter(col_names, '!empty(v:val)')
    let data_start = 2
    let use_pipe   = 1
    let col_bounds = []

  else
    return {}
  endif

  if empty(col_names)
    return {}
  endif

  " Find last data row (scan backward, skip footer and blank lines)
  let data_end = 0
  for i in range(len(a:lines) - 1, data_start - 1, -1)
    let ln = trim(a:lines[i])
    if !empty(ln) && ln !~# '^(\d\+ rows\?)'
      let data_end = i + 1  " 1-indexed
      break
    endif
  endfor

  if data_end < data_start
    return {}
  endif

  return {
        \ 'col_names':  col_names,
        \ 'col_bounds': col_bounds,
        \ 'data_start': data_start,
        \ 'data_end':   data_end,
        \ 'use_pipe':   use_pipe,
        \ }
endfunction


" Collect and parse data rows from the given lines array.
" Returns list-of-lists (outer: rows, inner: cell values).
function! s:collect_rows(lines, data_start, data_end, use_pipe, col_bounds) abort
  let rows = []
  for i in range(a:data_start - 1, a:data_end - 1)
    if i >= len(a:lines)
      break
    endif
    let ln = a:lines[i]
    " Skip blank or separator-like lines that crept into the data range
    if empty(trim(ln)) || ln =~# '^-[-+ ]*$'
      continue
    endif
    if a:use_pipe
      call add(rows, split(ln, '|', 1))
    else
      call add(rows, s:parse_positional(ln, a:col_bounds))
    endif
  endfor
  return rows
endfunction


" Extract cell values from a fixed-width line using column boundaries.
function! s:parse_positional(line, bounds) abort
  let values = []
  for b in a:bounds
    let to  = min([b.to, len(a:line) - 1])
    let val = b.from <= to ? a:line[b.from : to] : ''
    call add(values, val)
  endfor
  return values
endfunction


" Return list of {from, to} (0-indexed) for each dash-run in sep_line.
" Works for `----+-------+------` (postgres) and `------  ------` (sqlite).
function! s:col_boundaries(sep_line) abort
  let bounds = []
  let i      = 0
  let start  = -1
  while i < len(a:sep_line)
    if a:sep_line[i] ==# '-'
      if start < 0
        let start = i
      endif
    else
      if start >= 0
        call add(bounds, {'from': start, 'to': i - 1})
        let start = -1
      endif
    endif
    let i += 1
  endwhile
  if start >= 0
    call add(bounds, {'from': start, 'to': len(a:sep_line) - 1})
  endif
  return bounds
endfunction


" ─── Private: table / PK detection ──────────────────────────────────────────

" Parse the FROM clause of a SQL string.
" Returns [table_raw, table_sql] or ['', ''] when not found / subquery.
function! s:parse_from_clause(sql) abort
  let m = matchstr(a:sql, '\c\<FROM\>\s\+\zs\S\+')
  let m = substitute(m, '[;,]\+$', '', '')
  if empty(m) || m[0] ==# '('
    return ['', '']
  endif
  let table_raw = substitute(m, '"', '', 'g')
  let table_sql = join(map(split(table_raw, '\.'), 's:qid(v:val)'), '.')
  return [table_raw, table_sql]
endfunction


" Locate the SQL that produced the current dbout buffer, trying several sources.
" Returns the raw SQL string, or '' on failure.
function! s:find_sql_content(input_file) abort
  " 1. b:db.input — set by dadbod on the dbout buffer (skip .dbout paths)
  if !empty(a:input_file) && a:input_file !~# '\.dbout$' && filereadable(a:input_file)
    let sql = join(readfile(a:input_file), ' ')
    call db_ui#utils#print_debug({'message': 'edit: SQL from b:db.input', 'file': a:input_file})
    if !empty(trim(sql))
      return sql
    endif
  endif

  " 2. Any SQL/DB-filetype buffer visible in the current tab
  let sql_fts = ['sql', 'mysql', 'plsql', 'javascript']
  for win in range(1, winnr('$'))
    let buf = winbufnr(win)
    if buf ==# bufnr('%')
      continue
    endif
    if index(sql_fts, getbufvar(buf, '&filetype', '')) >= 0
      let sql = join(getbufline(buf, 1, '$'), ' ')
      call db_ui#utils#print_debug({'message': 'edit: SQL from visible window', 'win': win})
      if !empty(trim(sql))
        return sql
      endif
    endif
  endfor

  " 3. Any loaded SQL buffer that has a DB connection (cross-tab fallback)
  for buf in filter(range(1, bufnr('$')), 'buflisted(v:val) && bufloaded(v:val)')
    if buf ==# bufnr('%')
      continue
    endif
    if index(sql_fts, getbufvar(buf, '&filetype', '')) < 0
      continue
    endif
    if empty(getbufvar(buf, 'db', ''))
      continue
    endif
    let sql = join(getbufline(buf, 1, '$'), ' ')
    call db_ui#utils#print_debug({'message': 'edit: SQL from loaded buffer', 'buf': buf})
    if !empty(trim(sql))
      return sql
    endif
  endfor

  return ''
endfunction


" Return {table_raw, table_sql, sql} for the query that produced this dbout.
" table_raw / table_sql are '' when the FROM clause cannot be parsed.
function! s:get_sql_info(input_file) abort
  let sql = s:find_sql_content(a:input_file)
  if empty(sql)
    return {'table_raw': '', 'table_sql': '', 'sql': ''}
  endif
  let [table_raw, table_sql] = s:parse_from_clause(sql)
  return {'table_raw': table_raw, 'table_sql': table_sql, 'sql': sql}
endfunction


" Rewrite SELECT … FROM as SELECT pk_col, … FROM so we can fetch PK values.
function! s:prepend_pk_to_select(sql, pk_col) abort
  " Insert pk_col right after SELECT (or SELECT DISTINCT).
  " \zs sets the insertion point, so the replacement string is prepended there.
  return substitute(a:sql,
        \ '\c\<SELECT\>\(\s\+DISTINCT\)\?\s\+\zs',
        \ a:pk_col . ', ', '')
endfunction


" Run the query with the PK column prepended and return the PK value for each row.
" Returns [] on failure.
function! s:fetch_pk_values(db_url, sql, pk_col, scheme_name) abort
  " Build SELECT pk_col FROM <rest of original query> — one column, clean count.
  let from_part = matchstr(a:sql, '\c\<FROM\>.*')
  let from_part = substitute(from_part, ';\s*$', '', '')
  if empty(from_part)
    return []
  endif
  let pk_sql = 'SELECT ' . s:qid(a:pk_col) . ' ' . from_part
  call db_ui#utils#print_debug({'message': 'edit: PK fetch SQL', 'sql': pk_sql})
  if index(s:pg_schemes, a:scheme_name) >= 0
    return s:fetch_pk_values_pg(a:db_url, pk_sql)
  elseif index(s:sqlite_schemes, a:scheme_name) >= 0
    return s:fetch_pk_values_sqlite(a:db_url, pk_sql)
  endif
  return []
endfunction


function! s:fetch_pk_values_pg(db_url, pk_sql) abort
  let scheme = db_ui#schemas#get('postgresql')
  if empty(scheme)
    let scheme = db_ui#schemas#get('postgres')
  endif
  if empty(scheme)
    return []
  endif
  try
    let raw  = db_ui#schemas#query(a:db_url, scheme, a:pk_sql)
    " min_len=1 → flat list of strings, one per row (no column-count filtering)
    let rows = scheme.parse_results(raw, 1)
    call db_ui#utils#print_debug({'message': 'edit: PK fetch rows', 'count': len(rows)})
    return map(rows, 'trim(v:val)')
  catch /.*/
    call db_ui#utils#print_debug({'message': 'edit: PK fetch error', 'error': v:exception})
    return []
  endtry
endfunction


function! s:fetch_pk_values_sqlite(db_url, pk_sql) abort
  let parsed  = db#url#parse(a:db_url)
  let db_path = get(parsed, 'path', '')
  if empty(db_path) || !filereadable(db_path)
    return []
  endif
  let result = systemlist('sqlite3 ' . shellescape(db_path) . ' ' . shellescape(a:pk_sql))
  return map(filter(result, '!empty(trim(v:val))'), 'trim(v:val)')
endfunction


function! s:get_pk_columns(db_url, table_raw, scheme_name) abort
  if index(s:sqlite_schemes, a:scheme_name) >= 0
    return s:pk_sqlite(a:db_url, a:table_raw)
  endif
  if index(s:pg_schemes, a:scheme_name) >= 0
    return s:pk_postgres(a:db_url, a:table_raw)
  endif
  return []
endfunction

" Convenience wrapper returning just the first PK col (used by JOIN path).
function! s:get_pk_column(db_url, table_raw, scheme_name) abort
  let cols = s:get_pk_columns(a:db_url, a:table_raw, a:scheme_name)
  return empty(cols) ? '' : cols[0]
endfunction


function! s:pk_postgres(db_url, table_raw) abort
  let scheme = db_ui#schemas#get('postgresql')
  if empty(scheme)
    let scheme = db_ui#schemas#get('postgres')
  endif
  if empty(scheme)
    return ''
  endif

  " ::regclass resolves schema-qualified names and respects search_path
  let table_for_cast = substitute(a:table_raw, '"', '', 'g')
  let q = "SELECT a.attname"
        \ . " FROM pg_index i"
        \ . " JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)"
        \ . " WHERE i.indrelid = '" . table_for_cast . "'::regclass AND i.indisprimary"
        \ . " ORDER BY a.attnum"

  try
    let raw     = db_ui#schemas#query(a:db_url, scheme, q)
    let results = scheme.parse_results(raw, 1)
    call db_ui#utils#print_debug({'message': 'edit: PK query', 'raw': raw, 'results': results})
    return map(results, 'trim(v:val)')
  catch /.*/
    call db_ui#utils#print_debug({'message': 'edit: PK query error', 'error': v:exception})
  endtry
  return []
endfunction


function! s:pk_sqlite(db_url, table_raw) abort
  " Drop schema prefix — SQLite has no schemas
  let tbl = substitute(a:table_raw, '.*\.', '', '')
  let tbl = substitute(tbl, '"', '', 'g')

  let parsed  = db#url#parse(a:db_url)
  let db_path = get(parsed, 'path', '')
  if empty(db_path) || !filereadable(db_path)
    return ''
  endif

  " PRAGMA table_info outputs: cid|name|type|notnull|dflt_value|pk
  let pragma = 'PRAGMA table_info(' . tbl . ')'
  let result = systemlist('sqlite3 ' . shellescape(db_path) . ' ' . shellescape(pragma))

  let pks = []
  for line in result
    let fields = split(line, '|')
    if len(fields) >= 6 && str2nr(trim(fields[5])) > 0
      call add(pks, trim(fields[1]))
    endif
  endfor
  return pks
endfunction


" ─── Private: SQL generation ─────────────────────────────────────────────────

" Build: UPDATE <table> SET col=val, ... WHERE pk1=v1 AND pk2=v2 ...
" where_vals: {col: val} dict for the WHERE clause (supports composite PKs)
" changes:    {col: val} dict for the SET clause
function! s:build_update(table_sql, where_vals, changes) abort
  let set_parts = []
  for [col, val] in items(a:changes)
    call add(set_parts, s:qid(col) . ' = ' . s:qval(val))
  endfor
  let where_parts = []
  for [col, val] in items(a:where_vals)
    call add(where_parts, s:qid(col) . ' = ' . s:qval(val))
  endfor
  return printf('UPDATE %s SET %s WHERE %s',
        \ a:table_sql,
        \ join(set_parts, ', '),
        \ join(where_parts, ' AND '))
endfunction


" Double-quote an SQL identifier, stripping any existing quotes.
function! s:qid(name) abort
  return '"' . substitute(trim(a:name), '"', '', 'g') . '"'
endfunction


" Single-quote an SQL value. Empty string or literal 'null' → NULL keyword.
function! s:qval(val) abort
  let v = trim(a:val)
  if empty(v) || v =~# '^\cnull$'
    return 'NULL'
  endif
  return "'" . substitute(v, "'", "''", 'g') . "'"
endfunction


" ─── JOIN support ────────────────────────────────────────────────────────────

function! s:is_join_query(sql) abort
  return a:sql =~# '\c\<JOIN\>'
endfunction


" Parse FROM/JOIN clauses → {alias: table_name}.
" Handles: FROM tbl alias, FROM tbl AS alias, JOIN tbl alias, JOIN tbl AS alias.
function! s:parse_aliases(sql) abort
  let aliases  = {}
  let keywords = ['where', 'on', 'set', 'and', 'or', 'limit', 'order', 'group',
        \ 'having', 'inner', 'left', 'right', 'outer', 'cross', 'join',
        \ 'natural', 'full', 'using', 'as', 'select', 'into']
  " Pattern: (FROM|JOIN) <table> [AS] <word>
  let pat = '\c\<\%(FROM\|JOIN\)\>\s\+\(\S\+\)\s\+\%(AS\s\+\)\?\([a-zA-Z_][a-zA-Z0-9_]*\)'
  let pos = 0
  while pos <= len(a:sql)
    let mstart = match(a:sql, pat, pos)
    if mstart < 0
      break
    endif
    let m = matchlist(a:sql, pat, pos)
    if !empty(m)
      let tbl   = substitute(m[1], '[;,(]\+$', '', '')
      let tbl   = substitute(tbl,  '"', '', 'g')
      let alias = m[2]
      if index(keywords, tolower(alias)) < 0 && !empty(tbl) && tbl[0] !=# '('
        let aliases[alias] = tbl
      endif
    endif
    let pos = mstart + 1
  endwhile
  return aliases
endfunction


" For each visible column name, detect an alias.col prefix in the SELECT list.
" Returns {col_name: alias}.
function! s:parse_select_prefixes(sql, col_names) abort
  let sel_part = matchstr(a:sql, '\c\<SELECT\>.\{-}\ze\<FROM\>')
  let result   = {}
  for col in a:col_names
    let m = matchstr(sel_part, '\c\([a-zA-Z_][a-zA-Z0-9_]*\)\.' . col . '\>')
    if !empty(m)
      let result[col] = substitute(m, '\.' . col . '.*$', '', '')
    endif
  endfor
  return result
endfunction


" Query information_schema to map unresolved column names to their table (PG).
function! s:resolve_cols_pg(db_url, unresolved_cols, table_names) abort
  if empty(a:unresolved_cols) || empty(a:table_names)
    return {}
  endif
  let scheme = db_ui#schemas#get('postgresql')
  if empty(scheme)
    let scheme = db_ui#schemas#get('postgres')
  endif
  if empty(scheme)
    return {}
  endif
  let cols_list   = join(map(copy(a:unresolved_cols), 's:qval(v:val)'), ', ')
  let tables_list = join(map(copy(a:table_names),     's:qval(v:val)'), ', ')
  let q = 'SELECT column_name, table_name FROM information_schema.columns'
        \ . ' WHERE column_name IN (' . cols_list . ')'
        \ . ' AND table_name IN (' . tables_list . ')'
  try
    let raw  = db_ui#schemas#query(a:db_url, scheme, q)
    let rows = scheme.parse_results(raw, 2)
    let out  = {}
    for row in rows
      let out[trim(row[0])] = trim(row[1])
    endfor
    return out
  catch /.*/
    return {}
  endtry
endfunction


" Query PRAGMA table_info to map unresolved columns to their table (SQLite).
function! s:resolve_cols_sqlite(db_url, unresolved_cols, table_names) abort
  let parsed  = db#url#parse(a:db_url)
  let db_path = get(parsed, 'path', '')
  if empty(db_path) || !filereadable(db_path)
    return {}
  endif
  let out = {}
  for tbl in a:table_names
    let pragma = 'PRAGMA table_info(' . tbl . ')'
    let lines  = systemlist('sqlite3 ' . shellescape(db_path) . ' ' . shellescape(pragma))
    for line in lines
      let fields = split(line, '|')
      if len(fields) >= 2
        let col = trim(fields[1])
        if index(a:unresolved_cols, col) >= 0 && !has_key(out, col)
          let out[col] = tbl
        endif
      endif
    endfor
  endfor
  return out
endfunction


" Build {col_name: table_name} map for all visible columns.
function! s:build_col_table_map(sql, col_names, aliases, db_url, scheme_name) abort
  let prefixes   = s:parse_select_prefixes(a:sql, a:col_names)
  let col_table  = {}
  let unresolved = []
  for col in a:col_names
    if has_key(prefixes, col) && has_key(a:aliases, prefixes[col])
      let col_table[col] = a:aliases[prefixes[col]]
    else
      call add(unresolved, col)
    endif
  endfor
  if !empty(unresolved)
    let tbl_names = values(a:aliases)
    let resolved  = index(s:pg_schemes, a:scheme_name) >= 0
          \ ? s:resolve_cols_pg(a:db_url, unresolved, tbl_names)
          \ : s:resolve_cols_sqlite(a:db_url, unresolved, tbl_names)
    call extend(col_table, resolved)
  endif
  return col_table
endfunction


" Rewrite SELECT list to prepend alias.pk AS "__pk_alias" for each JOIN table.
" Aliases are sorted so the prepended columns are in deterministic order.
function! s:join_augmented_sql(sql, aliases, table_pks) abort
  let pk_cols = []
  for alias in sort(keys(a:aliases))
    let tbl = a:aliases[alias]
    if has_key(a:table_pks, tbl)
      call add(pk_cols, alias . '.' . a:table_pks[tbl] . ' AS "__pk_' . alias . '"')
    endif
  endfor
  if empty(pk_cols)
    return a:sql
  endif
  return substitute(a:sql,
        \ '\c\<SELECT\>\(\s\+DISTINCT\)\?\s\+\zs',
        \ join(pk_cols, ', ') . ', ', '')
endfunction


" Fetch {table_name: [{pk_col: val, ...} per row]} for a JOIN query.
" table_pks: {tbl: [pk_col, ...]} — supports composite PKs.
function! s:fetch_join_pk_values(db_url, sql, aliases, table_pks, scheme_name) abort
  let sorted_aliases = filter(sort(keys(a:aliases)), 'has_key(a:table_pks, a:aliases[v:val])')
  if empty(sorted_aliases)
    return {}
  endif

  " Build SELECT list and a col_order list for parsing (alias+tbl+col per slot).
  let pk_select = []
  let col_order = []
  for alias in sorted_aliases
    let tbl = a:aliases[alias]
    for pk_col in a:table_pks[tbl]
      call add(pk_select, alias . '.' . pk_col . ' AS "__pk_' . alias . '_' . pk_col . '"')
      call add(col_order, {'tbl': tbl, 'pk_col': pk_col})
    endfor
  endfor

  let from_part = matchstr(a:sql, '\c\<FROM\>.*')
  let from_part = substitute(from_part, ';\s*$', '', '')
  if empty(from_part) || empty(pk_select)
    return {}
  endif
  let pk_sql = 'SELECT ' . join(pk_select, ', ') . ' ' . from_part
  call db_ui#utils#print_debug({'message': 'edit: JOIN PK fetch SQL', 'sql': pk_sql})

  let rows = []

  if index(s:pg_schemes, a:scheme_name) >= 0
    let scheme = db_ui#schemas#get('postgresql')
    if empty(scheme)
      let scheme = db_ui#schemas#get('postgres')
    endif
    if empty(scheme)
      return {}
    endif
    try
      let raw  = db_ui#schemas#query(a:db_url, scheme, pk_sql)
      let flat = scheme.parse_results(raw, 1)
      let rows = map(flat, 'split(v:val, "|")')
    catch /.*/
      call db_ui#utils#print_debug({'message': 'edit: JOIN PK fetch error', 'error': v:exception})
      return {}
    endtry

  elseif index(s:sqlite_schemes, a:scheme_name) >= 0
    let parsed  = db#url#parse(a:db_url)
    let db_path = get(parsed, 'path', '')
    if empty(db_path) || !filereadable(db_path)
      return {}
    endif
    for line in systemlist('sqlite3 ' . shellescape(db_path) . ' ' . shellescape(pk_sql))
      if !empty(trim(line))
        call add(rows, split(line, '|'))
      endif
    endfor

  else
    return {}
  endif

  " result: {tbl: [dict_per_row]} where each dict is {pk_col: val, ...}
  let result = {}
  for alias in sorted_aliases
    let result[a:aliases[alias]] = []
  endfor

  for row in rows
    " Accumulate all PK col values for each table in this row.
    let row_pks = {}
    for i in range(len(col_order))
      let tbl    = col_order[i].tbl
      let pk_col = col_order[i].pk_col
      if !has_key(row_pks, tbl)
        let row_pks[tbl] = {}
      endif
      let row_pks[tbl][pk_col] = i < len(row) ? trim(row[i]) : ''
    endfor
    for [tbl, pk_dict] in items(row_pks)
      call add(result[tbl], pk_dict)
    endfor
  endfor
  return result
endfunction


" Enter edit mode for a JOIN query.
function! s:enter_join_edit_mode(db_url, scheme_name, struct, lines, sql_info) abort
  let aliases = s:parse_aliases(a:sql_info.sql)
  if empty(aliases)
    call db_ui#notifications#error('Edit mode: could not parse table aliases from JOIN query. Make sure each table has an alias (e.g. FROM users u JOIN orders o ...).')
    return
  endif

  let table_pks = {}
  for [alias, tbl] in items(aliases)
    let pks = s:get_pk_columns(a:db_url, tbl, a:scheme_name)
    if !empty(pks)
      let table_pks[tbl] = pks   " list — supports composite PKs
    endif
  endfor

  if empty(table_pks)
    call db_ui#notifications#error('Edit mode: could not find a primary key for any table in the JOIN.')
    return
  endif

  let col_table_map = s:build_col_table_map(
        \ a:sql_info.sql, a:struct.col_names, aliases, a:db_url, a:scheme_name)

  let table_pk_values = s:fetch_join_pk_values(
        \ a:db_url, a:sql_info.sql, aliases, table_pks, a:scheme_name)

  if empty(table_pk_values)
    call db_ui#notifications#error('Edit mode: could not fetch PK values for JOIN tables — check DB connection and that tables have rows.')
    return
  endif

  let b:db_ui_edit_mode            = 1
  let b:db_ui_edit_snapshot        = copy(a:lines)
  let b:db_ui_edit_col_names       = a:struct.col_names
  let b:db_ui_edit_col_bounds      = a:struct.col_bounds
  let b:db_ui_edit_data_start      = a:struct.data_start
  let b:db_ui_edit_data_end        = a:struct.data_end
  let b:db_ui_edit_scheme          = a:scheme_name
  let b:db_ui_edit_use_pipe        = a:struct.use_pipe
  let b:db_ui_edit_join_mode       = 1
  let b:db_ui_edit_aliases         = aliases
  let b:db_ui_edit_col_table_map   = col_table_map
  let b:db_ui_edit_table_pks       = table_pks
  let b:db_ui_edit_table_pk_values = table_pk_values
  " Unused in JOIN mode but kept so clear_edit_state's unlet is safe
  let b:db_ui_edit_pk_cols   = []
  let b:db_ui_edit_pk_col    = ''
  let b:db_ui_edit_pk_hidden = 0
  let b:db_ui_edit_pk_values = []
  let b:db_ui_edit_table     = ''
  let b:db_ui_edit_table_sql = ''

  augroup db_ui_edit_write
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> call db_ui#edit#save_changes()
  augroup END

  nnoremap <buffer> <nowait> <Esc> :call db_ui#edit#exit_edit_mode()<CR>
  nnoremap <buffer> <nowait> q     :call db_ui#edit#exit_edit_mode()<CR>

  setlocal modifiable
  call db_ui#notifications#info('Edit mode ON (JOIN) — tables: '
        \ . join(sort(values(aliases)), ', ')
        \ . ' | :w to save, q/<Esc> to cancel')
endfunction


" Save handler for JOIN mode.
function! s:save_join_changes() abort
  let col_names        = b:db_ui_edit_col_names
  let col_bounds       = b:db_ui_edit_col_bounds
  let col_table_map    = b:db_ui_edit_col_table_map
  let table_pks        = b:db_ui_edit_table_pks
  let table_pk_values  = b:db_ui_edit_table_pk_values
  let data_start       = b:db_ui_edit_data_start
  let data_end         = b:db_ui_edit_data_end
  let snapshot         = b:db_ui_edit_snapshot
  let use_pipe         = b:db_ui_edit_use_pipe

  let orig_rows = s:collect_rows(snapshot,        data_start, data_end, use_pipe, col_bounds)
  let curr_rows = s:collect_rows(getline(1, '$'), data_start, data_end, use_pipe, col_bounds)

  if len(orig_rows) !=# len(curr_rows)
    call db_ui#notifications#error('Row count changed — only cell edits are supported. Discard with q.')
    return
  endif

  let updates = []
  for i in range(len(orig_rows))
    let orig = orig_rows[i]
    let curr = curr_rows[i]
    if orig ==# curr
      continue
    endif

    let changes_by_table = {}
    for j in range(min([len(orig), len(curr), len(col_names)]))
      if trim(orig[j]) ==# trim(curr[j])
        continue
      endif
      let col = col_names[j]
      let tbl = get(col_table_map, col, '')
      if empty(tbl)
        call db_ui#notifications#error('Row '.i.', col "'.col.'": cannot determine which table owns this column — edit skipped.')
        continue
      endif
      if !has_key(changes_by_table, tbl)
        let changes_by_table[tbl] = {}
      endif
      let changes_by_table[tbl][col] = trim(curr[j])
    endfor

    for [tbl, changes] in items(changes_by_table)
      if !has_key(table_pks, tbl) || empty(table_pks[tbl])
        call db_ui#notifications#error('Row '.i.': no PK for "'.tbl.'" — skipped.')
        continue
      endif
      let pk_list = get(table_pk_values, tbl, [])
      if i >= len(pk_list) || empty(pk_list[i])
        call db_ui#notifications#error('Row '.i.': PK values for "'.tbl.'" unavailable — skipped.')
        continue
      endif
      " pk_list[i] is a dict {pk_col: val, ...} — used directly as WHERE clause
      call add(updates, s:build_update(s:qid(tbl), pk_list[i], changes))
    endfor
  endfor

  if empty(updates)
    call db_ui#notifications#info('No changes detected.')
    call s:clear_edit_state(0)
    return
  endif

  for sql in updates
    call db_ui#utils#print_debug({'message': 'dbui-edit JOIN executing', 'sql': sql})
    try
      exe 'DB ' . sql
    catch /.*/
      call db_ui#notifications#error('UPDATE failed: '.v:exception)
      return
    endtry
  endfor

  augroup db_ui_edit_write
    autocmd! * <buffer>
  augroup END

  let n = len(updates)
  norm R
  call s:clear_edit_state(0)
  call db_ui#notifications#info(n.' row(s) updated.')
endfunction
