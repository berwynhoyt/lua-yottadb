# Making Lua–MUMPS Fast

I had recently released [MLua](https://github.com/anet-be/mlua), a tool to let MUMPS code call Lua. Then in Oct 2022, I got my first user: [Alain Descamps](https://github.com/AlainDsc), of the Antwerp University Library, (sponsors of MLua), and heavy users of MUMPS. An actual user. Oh, the Euphoria!

But it didn't last long. Mere hours later, I got Alain's first benchmark: Lua was 4 times slower than M (MUMPS) at simply counting database records on our dev server. Even worse, when on my local PC's database, Lua was **7 times slower**. Grrr…  So I embarked on what I thought would be a 5-day pursuit of efficiency … but it took 25 days! However, I did get the dev server's Lua time down from 4x to 1.3x the speed of M. A very nice result.

**TLDR:** This blog article is about how we improved [lua-yottadb](https://github.com/anet-be/lua-yottadb) to go ~4x faster when looping through database records, and a stunning 47x faster creating Lua objects for database nodes, and other improvements ([results here](https://github.com/anet-be/mlua/tree/master/benchmarks#lua-yottadb-v12-compared-with-v21)). There were some low-hanging fruit, but the biggest improvement was caching the node's path subscript list in the database node object. But it sure took a rather wending path to get us there.

## What was the problem?

Alain's Lua benchmark script was pretty simple. Akin to this:

```lua
ydb = require('yottadb')
gref1 = ydb.key('^BCAT')('lvd')('')
cnt = 0  for x in gref1:subscripts() do  cnt=cnt+1  end
print("total of " .. cnt .. " records")
```

> If you're new to M, to understand what's going on, you need to know that M database nodes are represented by a series of 'subscript' strings, just like a file-system path. Whereas a path might be `root/var/log/file`, an M node would be `root("var","log","nodename")` or `root.var.log.nodename`. Just like for a directory, each node can have a bit of data or further sub-nodes.

The program above, simply loops through a sequence of 4,640,621 database nodes with subscripts `^BCAT.lvd.<n>` like so:

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

Next, I built some [benchmarks tests](https://github.com/anet-be/mlua/tree/master/benchmarks) to track our improvement, then got stuck in to improving things.[^1] We could avoid (1) and maybe (2) by checking them just once at the start of the loop. This was fairly quickly done, with mild improvements as follows:

- 25% for more efficient function-parameter type checking: check valid parameter types use table lookup rather than a for loop to find valid types
- … etc.

But what if we wanted to improve every single database operation, not just iteration? The benchmarks showed that there were two tasks that were slow, and critical to every single database operation: converting the subscript list to C, and creating new Lua nodes.

As an example of the latter, let's create a Lua-database object:

```lua
guy = ydb.node('demographics').country.person.3
```

We can do all kinds of database activities on that node, for example: `node:lock_incr()   node:set('Fred')  node:lock_decr()` or even set create subnodes:

```lua
guy.gender:set('male')
guy.genetics.chomozome:set('X')
```

Each '.' above creates a new Lua subnode object, `genetics` and then `chromozome`, before you can finally set it to 'X'. You can imagine that a Lua programmer will be doing a lot of this, so it's a critical task that we need to optimise.

To achieve this we needed to find the 'Holy Grail': ***fast creation*** of ***cached C arrays***. That would extend these benefits to *every* database function.

My early wins made it feel like I was about half way there. I told my 'boss' the efficiency task would take 5 days. By this time I'd use up about half of that, and I thought I was on track. All that was left was to cache the subscript list. I mean, how hard can it be to cache something? You just have to store the C array when the node is first created, and use it again each time the node is accessed, right? Little did I know.

## Caching subscripts: a surprisingly daunting task

Achieving these two goals together proved to be so difficult that it took me four rewrites to get right.

Each node already held all its subscripts in Lua; just not in C. The node object looks like this:

```lua
node = {
    __varname = "demographics"
    __subsarray = {"country", "person", "3", "gender"}
}
```

Be aware that creating a table is quite slow (compared to a C array): it requires a malloc, linkage into the Lua garbage collector, a hashtable, and creation of a numerical array portion. And here we need *two* of them (one for the node object itself, and another for the subsarray). So its slow.

### Iteration 1: Beware the garbage collector

In the first 3 iterations I simply stored the C cachearray as a userdata field within the regular node object:

```lua
node.__cachearray = cachearray_create("country", "person", "3", "gender")
```

So `cachearray_create()` just had to malloc(n*pointers) and point them to the strings *already existing in Lua*. But this would necessitate keeping Lua references to those strings, to prevent the from being garbage collected while in use by C. So I'd still have to keep the `__subsarray` table to reference these strings. And simply adding __cachearray to the node could only slow down node creation time.

Instead, I 'cleverly' noticed that each child node repeats all its parent's subscripts. So I could save both memory and time, with all child node objects containing only their own rightmost subscript `__name` and `__parent`. This way I avoid having to create the whole `__subsarray` table for each node. And my syntax should remain fast.

That was the design for iteration 1. But the `__parent` thing made it a little complicated, and hid a nasty segfault that I couldn't find for a long time. You know the kind of C pointer bug where the symptom occurs nowhere near the cause. (I should have used `valgrind myprog` to help find it, but I hadn't used [valgrind](https://valgrind.org/) before, and I didn't realise how dead simple it was to use. I eventually needed it again, though. It's true bliss.) Anyway, the bug ended up being that I did `malloc(sizeof(ydb_buffer_t*) * n_subscripts)`, except I left out the first asterisk.

I wrote this and debugged all this, but it wasn't that much faster.



Sections:

1. malloc C-array and point to Lua strings. Faster iteration but slower node creation due to extra stuff to create & still table
   Implementing cachearray_subst()
   Version using userdata() instead of malloc.
2. ?re-used cachearray?
3. Version with cachearray and depth
4. Version with dereferenced cachearray – reduce time by a whole table creation.
5. One thing I'd still love to try is completely avoiding dereferenced arrays: is copying really so slow? I imagine it is, due to CPU caching, but I haven't actually tried it. For that I need to implement it and use it comparatively on a few different real-world applications.

[^1]: Alain's benchmark was skewed by a curiously slow build of Lua that he used. His sysadmin tells me he has now compiled it differently, which has demonstrably doubled the speed. I haven't fully understood the build improvements, but that brought a 2x win right there. However, I didn't comprehend this fact until much later because it was masked by my own local Lua/database combination also running at roughly half the speed of Alain's mainframe setup. The benchmark results given are from my local machine; the mainframe's database setup is faster.

