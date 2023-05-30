# Making Lua–MUMPS Fast

I had recently released [MLua](https://github.com/anet-be/mlua), a tool to let MUMPS code call Lua. Then in Oct 2022, I got my first user: [Alain Descamps](https://github.com/AlainDsc), of the Antwerp University Library, (sponsors of MLua), and heavy users of MUMPS. An actual user. Oh, the Euphoria!

But it didn't last long. Mere hours later, I got Alain's first benchmark: Lua was 4 times slower than M (MUMPS) at simply counting database records. Grrr…  So I embarked on what I thought would be a 5-day pursuit of efficiency … and it took over a month!

**TLDR:** This blog article is about how we improved [lua-yottadb](https://github.com/anet-be/lua-yottadb) to go 9x faster when looping through database records, and a stunning 47x faster creating Lua objects for database nodes ([benchmark results here](https://github.com/anet-be/mlua/tree/master/benchmarks#lua-yottadb-v12-compared-with-v21)). There were some low-hanging fruit, but the biggest improvement was caching the node path (subscript array) in the database node object. But it sure took a rather wending path to get us there.

## What was the problem?

Alain's Lua script was pretty simple. Akin to this:

```lua
ydb = require('yottadb')
gref1 = ydb.key('^BCAT')('lvd')('')
cnt = 0  for x in gref1:subscripts() do  cnt=cnt+1  end
print("total of " .. cnt .. " records")
```

> If you're new to M, to understand what's going on, you need to know that M database nodes are represented by a series of 'subscript' strings, just like a file-system path. Whereas a path might be `root/var/log/file`, an M node would be `root("var", "log", "name")`. Just like for a directory, each node can have a bit of data or further sub-nodes.

The program above, simply loops through a sequence of 4,640,621 database nodes with subscripts that look like this:

```lua
^BCAT("lvd")("")
^BCAT("lvd")(1)
^BCAT("lvd")(2)
^BCAT("lvd")(3) ...
```

To do so, took 20 seconds in Lua, and 5 seconds in M. A quick code review of [lua-yottadb](https://github.com/anet-be/lua-yottadb) (the database access layer of MLua) found a number of low-hanging fruit in the `gref1:subscripts()` method above. The issues were that for ***every*** loop iteration, `gref1:subscripts()` did this:

1. Checked each subscript in the node's 'path' at the Lua level to make sure it was a valid string.
2. Checked each subscript again at the C level.
3. Converted the subscript array into a C array of string pointers (for calling the M API), then discarded the C array.

I built some [benchmarks](https://github.com/anet-be/mlua/tree/master/benchmarks) to track our improvement, then got stuck in. We could avoid (1) and maybe (2) by checking them just once at the start of the loop. This was fairly quickly done, with mild improvements. But the Holy Grail was to cache the C-array in the node's object. That would extend these benefits to every database function that used node objects.

I told my 'boss' the efficiency task would take 5 days. By this time I've use up about half of it. I thought I was on track. I mean, how hard can it be to cache something? You just have to store the C array when the node is first created, and use it again each time the node is accessed, right? Little did I know.

## Caching Subscripts: a surprisingly daunting task

Caching the C array proved to be difficult, it took me four rewrites.


