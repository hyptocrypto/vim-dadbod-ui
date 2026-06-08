" psql meta-command translator for PostgreSQL dadbod-ui connections.
"
" In any SQL buffer, press <CR> on a line beginning with \ to execute:
"   \d              list all relations (tables, views, sequences)
"   \d <name>       describe a table / view
"   \dt [pattern]   list tables
"   \dv [pattern]   list views
"   \di [pattern]   list indexes
"   \ds [pattern]   list sequences
"   \dn [pattern]   list schemas
"   \df [pattern]   list functions
"   \l              list databases
"   \z [pattern]    list table privileges  (also \dp)
"
" Patterns support SQL ILIKE wildcards (% or glob *).

let s:pg_schemes = ['postgres', 'postgresql']

" ─── Public ──────────────────────────────────────────────────────────────────

function! db_ui#meta#run() abort
  let line = getline('.')

  " Not a meta-command — fall through to default <CR> behaviour (next line).
  if line !~# '^\s*\\'
    normal! +
    return
  endif

  if !exists('b:db') || empty(b:db)
    call db_ui#notifications#error('Meta: no database connection on this buffer.')
    return
  endif

  let db_url = type(b:db) ==# type('') ? b:db : get(b:db, 'db_url', '')
  if empty(db_url)
    call db_ui#notifications#error('Meta: cannot resolve DB URL.')
    return
  endif

  let parsed = db#url#parse(db_url)
  if index(s:pg_schemes, tolower(get(parsed, 'scheme', ''))) < 0
    call db_ui#notifications#error('Meta: \commands require a PostgreSQL connection (got "'
          \ . get(parsed, 'scheme', '?') . '").')
    return
  endif

  " Parse command token and optional argument.
  let raw = substitute(trim(line), ';\s*$', '', '')
  let cmd = tolower(matchstr(raw, '^\\[a-z+?]*'))
  let arg = substitute(trim(matchstr(raw, '^\\[a-z+?]*\s*\zs.*')), ';\s*$', '', '')

  let sql = s:translate(cmd, arg)
  if empty(sql)
    call db_ui#notifications#error(
          \ 'Meta: unknown command "' . cmd . '". '
          \ . 'Supported: \d, \dt, \dv, \di, \ds, \dn, \df, \l, \z.')
    return
  endif

  exe 'DB ' . sql
endfunction


" ─── Dispatcher ──────────────────────────────────────────────────────────────

function! s:translate(cmd, arg) abort
  let c = a:cmd
  let a = a:arg

  if c ==# '\d' && !empty(a) | return s:describe(a)   | endif
  if c ==# '\d'               | return s:relations('') | endif
  if c ==# '\dt' || c ==# '\t'| return s:tables(a)    | endif
  if c ==# '\dv'              | return s:views(a)      | endif
  if c ==# '\di'              | return s:indexes(a)    | endif
  if c ==# '\ds'              | return s:sequences(a)  | endif
  if c ==# '\dn'              | return s:schemas(a)    | endif
  if c ==# '\df'              | return s:functions(a)  | endif
  if c ==# '\l'               | return s:databases()   | endif
  if c ==# '\z' || c ==# '\dp'| return s:privileges(a) | endif
  return ''
endfunction


" ─── Helpers ─────────────────────────────────────────────────────────────────

" Single-quote-escape a string value.
function! s:q(s) abort
  return substitute(a:s, "'", "''", 'g')
endfunction

" Return " AND <col> ILIKE '<pattern>'" or '' when pattern is empty.
" Converts glob * to SQL %.
function! s:like(col, pattern) abort
  if empty(a:pattern)
    return ''
  endif
  return " AND " . a:col . " ILIKE '" . s:q(substitute(a:pattern, '\*', '%', 'g')) . "'"
endfunction

" Join a list of SQL fragments into a single-line query.
" Empty strings are dropped (useful for conditional clauses).
function! s:j(parts) abort
  return join(filter(copy(a:parts), '!empty(v:val)'), ' ')
endfunction

" Split 'schema.table' → ['schema','table']; 'table' → ['','table'].
function! s:split_name(arg) abort
  if a:arg =~# '\.'
    let parts = split(a:arg, '\.', 1)
    return [parts[0], parts[1]]
  endif
  return ['', a:arg]
endfunction


" ─── SQL generators ──────────────────────────────────────────────────────────

function! s:describe(arg) abort
  let [schema, tbl] = s:split_name(a:arg)
  let tbl_q = s:q(tbl)

  " Schema filter expressions for the outer query (c.) and subquery (tc.).
  if empty(schema)
    let c_filter  = "c.table_schema  NOT IN ('pg_catalog','information_schema')"
    let tc_filter = "tc.table_schema NOT IN ('pg_catalog','information_schema')"
  else
    let c_filter  = "c.table_schema  = '" . s:q(schema) . "'"
    let tc_filter = "tc.table_schema = '" . s:q(schema) . "'"
  endif

  return s:j([
        \ "SELECT",
        \ "  c.column_name AS column,",
        \ "  c.udt_name || COALESCE('(' || c.character_maximum_length::text || ')', '') AS type,",
        \ "  CASE WHEN c.is_nullable = 'NO' THEN 'not null' ELSE 'null' END AS nullable,",
        \ "  c.column_default AS default,",
        \ "  COALESCE(pk.constraint_type, '') AS key",
        \ "FROM information_schema.columns c",
        \ "LEFT JOIN (",
        \ "  SELECT kcu.column_name, tc.constraint_type",
        \ "  FROM information_schema.table_constraints tc",
        \ "  JOIN information_schema.key_column_usage kcu",
        \ "    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema",
        \ "  WHERE tc.constraint_type IN ('PRIMARY KEY','UNIQUE')",
        \ "    AND tc.table_name = '" . tbl_q . "' AND " . tc_filter,
        \ ") pk ON pk.column_name = c.column_name",
        \ "WHERE c.table_name = '" . tbl_q . "' AND " . c_filter,
        \ "ORDER BY c.ordinal_position",
        \ ])
endfunction


function! s:relations(pattern) abort
  return s:j([
        \ "SELECT schemaname AS schema, tablename AS name, 'table' AS type",
        \ "FROM pg_tables",
        \ "WHERE schemaname NOT IN ('pg_catalog','information_schema')" . s:like('tablename', a:pattern),
        \ "UNION ALL",
        \ "SELECT schemaname, viewname, 'view'",
        \ "FROM pg_views",
        \ "WHERE schemaname NOT IN ('pg_catalog','information_schema')" . s:like('viewname', a:pattern),
        \ "UNION ALL",
        \ "SELECT schemaname, sequencename, 'sequence'",
        \ "FROM pg_sequences",
        \ "WHERE schemaname NOT IN ('pg_catalog','information_schema')" . s:like('sequencename', a:pattern),
        \ "ORDER BY schema, type, name",
        \ ])
endfunction


function! s:tables(pattern) abort
  return s:j([
        \ "SELECT schemaname AS schema, tablename AS name, tableowner AS owner",
        \ "FROM pg_tables",
        \ "WHERE schemaname NOT IN ('pg_catalog','information_schema')" . s:like('tablename', a:pattern),
        \ "ORDER BY schemaname, tablename",
        \ ])
endfunction


function! s:views(pattern) abort
  return s:j([
        \ "SELECT schemaname AS schema, viewname AS name, viewowner AS owner",
        \ "FROM pg_views",
        \ "WHERE schemaname NOT IN ('pg_catalog','information_schema')" . s:like('viewname', a:pattern),
        \ "ORDER BY schemaname, viewname",
        \ ])
endfunction


function! s:indexes(pattern) abort
  return s:j([
        \ "SELECT schemaname AS schema, tablename, indexname, indexdef",
        \ "FROM pg_indexes",
        \ "WHERE schemaname NOT IN ('pg_catalog','information_schema')" . s:like('indexname', a:pattern),
        \ "ORDER BY schemaname, tablename, indexname",
        \ ])
endfunction


function! s:sequences(pattern) abort
  return s:j([
        \ "SELECT schemaname AS schema, sequencename AS name, sequenceowner AS owner,",
        \ "  start_value, min_value, max_value, increment_by",
        \ "FROM pg_sequences",
        \ "WHERE schemaname NOT IN ('pg_catalog','information_schema')" . s:like('sequencename', a:pattern),
        \ "ORDER BY schemaname, sequencename",
        \ ])
endfunction


function! s:schemas(pattern) abort
  return s:j([
        \ "SELECT schema_name AS schema, schema_owner AS owner",
        \ "FROM information_schema.schemata",
        \ (empty(a:pattern) ? '' : "WHERE schema_name ILIKE '" . s:q(a:pattern) . "'"),
        \ "ORDER BY schema_name",
        \ ])
endfunction


function! s:functions(pattern) abort
  return s:j([
        \ "SELECT n.nspname AS schema, p.proname AS name,",
        \ "  pg_catalog.pg_get_function_arguments(p.oid) AS arguments,",
        \ "  pg_catalog.format_type(p.prorettype, NULL) AS returns",
        \ "FROM pg_catalog.pg_proc p",
        \ "JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace",
        \ "WHERE n.nspname NOT IN ('pg_catalog','information_schema')" . s:like('p.proname', a:pattern),
        \ "ORDER BY schema, name",
        \ ])
endfunction


function! s:databases() abort
  return s:j([
        \ "SELECT datname AS database,",
        \ "  pg_catalog.pg_get_userbyid(datdba) AS owner,",
        \ "  pg_catalog.pg_encoding_to_char(encoding) AS encoding,",
        \ "  datcollate AS collate",
        \ "FROM pg_catalog.pg_database",
        \ "ORDER BY datname",
        \ ])
endfunction


function! s:privileges(pattern) abort
  return s:j([
        \ "SELECT table_schema AS schema, table_name, grantee, privilege_type, is_grantable",
        \ "FROM information_schema.role_table_grants",
        \ "WHERE table_schema NOT IN ('pg_catalog','information_schema')" . s:like('table_name', a:pattern),
        \ "ORDER BY table_schema, table_name, grantee, privilege_type",
        \ ])
endfunction
