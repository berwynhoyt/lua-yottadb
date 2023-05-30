ydb = require('yottadb')
gref1 = ydb.key('^BCAT')('lvd')('')
function f() cnt = 0; for x in gref1:subscripts() do  cnt=cnt+1  end  return cnt end
print("total of " .. f() .. " records")
