-- Minimal LuaJIT FFI wrapper around libsqlite3.
--
-- Used instead of sqlite.lua so the vault has no plugin dependency and so
-- every string is bound verbatim (sqlite.lua skips binding strings that look
-- like `name(...)`, which titles and JSON payloads regularly do).
--
-- The library is looked up in `vim.g.sqlite_clib_path` (same convention as
-- sqlite.lua), then through the system loader.
local ffi = require('ffi')

ffi.cdef([[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3*);
int sqlite3_busy_timeout(sqlite3*, int ms);
const char *sqlite3_errmsg(sqlite3*);
int sqlite3_exec(sqlite3*, const char *sql, void *cb, void *arg, char **errmsg);
void sqlite3_free(void*);
int sqlite3_prepare_v2(sqlite3*, const char *sql, int nbyte, sqlite3_stmt **ppStmt, const char **tail);
int sqlite3_step(sqlite3_stmt*);
int sqlite3_reset(sqlite3_stmt*);
int sqlite3_clear_bindings(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt*);
int sqlite3_bind_parameter_index(sqlite3_stmt*, const char *name);
int sqlite3_bind_null(sqlite3_stmt*, int i);
int sqlite3_bind_int64(sqlite3_stmt*, int i, sqlite3_int64);
int sqlite3_bind_double(sqlite3_stmt*, int i, double);
int sqlite3_bind_text(sqlite3_stmt*, int i, const char*, int n, void(*)(void*));
int sqlite3_column_count(sqlite3_stmt*);
const char *sqlite3_column_name(sqlite3_stmt*, int n);
int sqlite3_column_type(sqlite3_stmt*, int n);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int n);
double sqlite3_column_double(sqlite3_stmt*, int n);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int n);
int sqlite3_column_bytes(sqlite3_stmt*, int n);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3*);
]])

local SQLITE_ROW, SQLITE_DONE = 100, 101
local SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE = 0x2, 0x4
local SQLITE_INTEGER, SQLITE_FLOAT, SQLITE_NULL = 1, 2, 5
local SQLITE_TRANSIENT = ffi.cast('void(*)(void*)', -1)

---@type ffi.namespace*|nil
local lib

---@return ffi.namespace*|nil
---@return string|nil err
local function load_lib()
  if lib then return lib end
  local candidates = {}
  if vim.g.sqlite_clib_path then table.insert(candidates, vim.g.sqlite_clib_path) end
  vim.list_extend(candidates, { 'sqlite3', 'libsqlite3.so.0', 'libsqlite3.dylib', 'sqlite3.dll' })
  for _, name in ipairs(candidates) do
    local ok, loaded = pcall(ffi.load, name)
    if ok then
      lib = loaded
      return lib
    end
  end
  return nil, 'libsqlite3 not found (set vim.g.sqlite_clib_path)'
end

---@class FeyVaultStmt
---@field handle ffi.cdata*
---@field db FeyVaultDb
local Stmt = {}
Stmt.__index = Stmt

---@class FeyVaultDb
---@field conn ffi.cdata*
---@field stmts table<string, FeyVaultStmt>
---@field path string
local Db = {}
Db.__index = Db

---@param path string
---@return FeyVaultDb|nil
---@return string|nil err
function Db.open(path)
  local sqlite, err = load_lib()
  if not sqlite then return nil, err end
  local out = ffi.new('sqlite3*[1]')
  local rc = sqlite.sqlite3_open_v2(path, out, SQLITE_OPEN_READWRITE + SQLITE_OPEN_CREATE, nil)
  if rc ~= 0 then
    local msg = out[0] ~= nil and ffi.string(sqlite.sqlite3_errmsg(out[0])) or ('sqlite error ' .. rc)
    if out[0] ~= nil then sqlite.sqlite3_close_v2(out[0]) end
    return nil, msg
  end
  local self = setmetatable({ conn = out[0], stmts = {}, path = path }, Db)
  sqlite.sqlite3_busy_timeout(self.conn, 3000)
  return self
end

function Db:error() return ffi.string(lib.sqlite3_errmsg(self.conn)) end

---Execute one or more statements without parameters or results
---@param sql string
function Db:exec(sql)
  local errmsg = ffi.new('char*[1]')
  local rc = lib.sqlite3_exec(self.conn, sql, nil, nil, errmsg)
  if rc ~= 0 then
    local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or ('sqlite error ' .. rc)
    if errmsg[0] ~= nil then lib.sqlite3_free(errmsg[0]) end
    error(msg, 2)
  end
end

---@param sql string
---@return FeyVaultStmt
function Db:prepare(sql)
  local cached = self.stmts[sql]
  if cached then return cached end
  local out = ffi.new('sqlite3_stmt*[1]')
  if lib.sqlite3_prepare_v2(self.conn, sql, #sql, out, nil) ~= 0 then
    error(('%s\n%s'):format(self:error(), sql), 3)
  end
  local stmt = setmetatable({ handle = out[0], db = self }, Stmt)
  self.stmts[sql] = stmt
  return stmt
end

---Run a statement (prepared statements are cached by SQL text).
---`params` is a list for `?` placeholders and/or a map for `:name` placeholders.
---@param sql string
---@param params? table
---@return table[] rows
function Db:run(sql, params) return self:prepare(sql):run(params) end

---@return integer
function Db:last_insert_rowid() return tonumber(lib.sqlite3_last_insert_rowid(self.conn)) --[[@as integer]] end

---Run `fn` inside a transaction; rolls back and rethrows on error
---@generic T
---@param fn fun(): T
---@return T
function Db:transaction(fn)
  self:exec('BEGIN')
  local ok, res = pcall(fn)
  if not ok then
    pcall(self.exec, self, 'ROLLBACK')
    error(res, 0)
  end
  self:exec('COMMIT')
  return res
end

function Db:close()
  if not self.conn then return end
  for _, stmt in pairs(self.stmts) do
    lib.sqlite3_finalize(stmt.handle)
  end
  self.stmts = {}
  lib.sqlite3_close_v2(self.conn)
  self.conn = nil
end

---@param params? table
function Stmt:bind(params)
  local h = self.handle
  local function bind_one(i, v)
    local t = type(v)
    if v == nil or v == vim.NIL then
      lib.sqlite3_bind_null(h, i)
    elseif t == 'string' then
      lib.sqlite3_bind_text(h, i, v, #v, SQLITE_TRANSIENT)
    elseif t == 'boolean' then
      lib.sqlite3_bind_int64(h, i, v and 1 or 0)
    elseif t == 'number' then
      if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
        lib.sqlite3_bind_int64(h, i, v)
      else
        lib.sqlite3_bind_double(h, i, v)
      end
    else
      error('unsupported sqlite parameter type: ' .. t, 3)
    end
  end

  for i, v in ipairs(params or {}) do
    bind_one(i, v)
  end
  for k, v in pairs(params or {}) do
    if type(k) == 'string' then
      local idx = lib.sqlite3_bind_parameter_index(h, ':' .. k)
      if idx > 0 then bind_one(idx, v) end
    end
  end
  -- ipairs stops at the first nil, so positional nils must be bound explicitly
  if params and params.n then
    for i = 1, params.n do
      if params[i] == nil then lib.sqlite3_bind_null(h, i) end
    end
  end
end

---@param params? table
---@return table[]
function Stmt:run(params)
  local h = self.handle
  lib.sqlite3_reset(h)
  lib.sqlite3_clear_bindings(h)
  self:bind(params)

  local rows = {}
  local ncol = lib.sqlite3_column_count(h)
  local names = {}
  for i = 0, ncol - 1 do
    names[i] = ffi.string(lib.sqlite3_column_name(h, i))
  end

  while true do
    local rc = lib.sqlite3_step(h)
    if rc == SQLITE_DONE then break end
    if rc ~= SQLITE_ROW then
      local msg = self.db:error()
      lib.sqlite3_reset(h)
      error(msg, 3)
    end
    local row = {}
    for i = 0, ncol - 1 do
      local t = lib.sqlite3_column_type(h, i)
      if t == SQLITE_INTEGER then
        row[names[i]] = tonumber(lib.sqlite3_column_int64(h, i))
      elseif t == SQLITE_FLOAT then
        row[names[i]] = lib.sqlite3_column_double(h, i)
      elseif t ~= SQLITE_NULL then
        row[names[i]] = ffi.string(lib.sqlite3_column_text(h, i), lib.sqlite3_column_bytes(h, i))
      end
    end
    rows[#rows + 1] = row
  end
  lib.sqlite3_reset(h)
  return rows
end

return Db
