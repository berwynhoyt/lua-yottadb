class Obj:
    __slots__ = ('_name', '_parent')
    def __init__(self, k, parent=None):
        self._name = k
        self._parent = parent

    def __getattribute__(self, k):
        return Obj(k, self)

def f():
    for i in range(100000):
        o = Obj('a').b.c.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z

f()

#~ o = Obj('a').b.c.e.f.g.h.i.j.k.l.m.n.o.p.q.r.s.t.u.v.w.x.y.z
#~ print(o._name)
#~ print(o._parent._name)
