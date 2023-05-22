obj = {}

function obj:__index(k)
    return setmetatable({_=k, p=self}, obj)
end

function Obj(k)
    return setmetatable({_=k, p=false}, obj)
end

function f()
    for i=1, 100000 do
        o = Obj('a').b.c.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z
    end
end

f()

--~ o = Obj('a').b.c.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z
--~ print(o.__name)
--~ print(o.__parent.__name)
