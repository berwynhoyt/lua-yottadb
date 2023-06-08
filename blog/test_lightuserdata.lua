-- Test whether __gc method gets called on light userdata (it doesn't)

object_creation_c = require 'object_creation_c'

function test(...)  print("test", ...)  end
function collect(...)  print("collect", ...)  end
function __index(self, k)  print("index", self, k) return test  end
mt={test=test, __gc=collect, __index=__index}

local light_ud = object_creation_c.lightuserdata()
print(type(light_ud))

ud_mt = getmetatable(light_ud)
print(ud_mt)
ud_mt = ud_mt or mt
debug.setmetatable(light_ud, mt)

light_ud:test(3, 4)

-- Test whether __gc method gets called on light userdata (it doesn't)
light_ud = nil
collectgarbage()
collectgarbage()
-- If the above prints "collect" __gc is called on light userdata
