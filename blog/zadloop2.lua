ydb = require('yottadb')
local gref1 = ydb.key('^BCAT')("lvd")("")
local cnt = 0

--for x in gref1:subscripts() do cnt = cnt + 1 end
_yottadb = require('_yottadb')
var, subs = '^BCAT', {"lvd", ""}
next = ""
repeat
  subs[#subs] = next
  ok, next = pcall(_yottadb.subscript_next, var, subs)
  cnt = cnt + 1
until not ok

print("total of " .. cnt .. " records")