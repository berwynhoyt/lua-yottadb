ydb = require('yottadb')
local gref1 = ydb.key('^BCAT')("lvd")("")
local cnt = 0

--for x in gref1:subscripts() do cnt = cnt + 1 end
_yottadb = require('_yottadb')
var, subs = '^BCAT', {"lvd", ""}
cachearray = _yottadb.cachearray_create(var, subs)
cachearray = _yottadb.cachearray_tomutable(cachearray)
next = ""
repeat
  _yottadb.cachearray_subst(cachearray, next)
  next = _yottadb.subscript_next(cachearray)
  cnt = cnt + 1
until not next

print("total of " .. cnt .. " records")
