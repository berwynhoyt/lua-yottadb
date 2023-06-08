class = {}

-- Test table-object creation time

function class:__index(k)
    return setmetatable({_=k, p=self}, class)
end

function Obj(k)
    return setmetatable({_=k, p=false}, class)
end

function f()
    for i=1, 100000 do
        o = Obj('a').b.c.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z
    end
end

-- Test userdata-object creation time

object_creation_c = require 'object_creation_c'

class2 = {}
function class2:__index(k)
    return debug.setmetatable(object_creation_c.userdata(#k), class2)
end

function Obj2(k)
    return debug.setmetatable(object_creation_c.userdata(#k), class2)
end

function g()
    for i=1, 100000 do
        o = Obj2('a').b.c.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z
    end
end

-- Run the test we want
--f()
g()
