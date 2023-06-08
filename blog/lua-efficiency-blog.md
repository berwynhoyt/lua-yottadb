# Making Lua–MUMPS Fast

I had recently released [MLua](https://github.com/anet-be/mlua), a tool to let MUMPS code call Lua. Then in Oct 2022, I got my first user: [Alain Descamps](https://github.com/AlainDsc), of the Antwerp University Library, (sponsors of MLua), and heavy users of MUMPS. An actual user. Brilliant!

But it didn't last long. Mere hours later, I got Alain's first benchmark: Lua was 4 times slower than M (MUMPS) at simply traversing (counting) database records on our dev server. Even worse, when on my local PC's database, Lua was [8 times slower than M](https://github.com/anet-be/mlua/tree/master/benchmarks#comparison-with-m). Grrr…  So I embarked on what I thought would be a 5-day pursuit of efficiency … but it took 25 days! However, I did get the dev server's Lua time down from 4x to 1.3x the speed of M. A very nice result.

**TLDR:** This blog article is about how we improved [lua-yottadb](https://github.com/anet-be/lua-yottadb) to go ~4x faster when looping through database records, and a stunning 47x faster creating Lua objects for database nodes, and other improvements ([results here](https://github.com/anet-be/mlua/tree/master/benchmarks#lua-yottadb-v12-compared-with-v21)). There were some low-hanging fruit, but the biggest improvement was caching the node's path subscript list in the database node object. Along the way we [learned numerous things](#learnings), helpful to port these efficiencies to other languages.

## What was the problem?

Alain's Lua benchmark script was simple – akin to this:

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

To do so, took 20 seconds in Lua, and 5 seconds [in M](https://github.com/berwynhoyt/lua-yottadb/blob/blog/blog/zadloop.m). A quick code review of [lua-yottadb](https://github.com/anet-be/lua-yottadb) (the database access layer of MLua) found a number of low-hanging fruit in the `gref1:subscripts()` method above. The issues were that for ***every*** loop iteration, `gref1:subscripts()` did this:

1. Checked each subscript in the node's 'path' at the Lua level to make sure it was a valid string.
2. Checked each subscript again at the C level.
3. Converted the subscript array into a C array of string pointers (for calling the M API), then discarded the C array.

Next, I built some [benchmarks tests](https://github.com/anet-be/mlua/tree/master/benchmarks) to track our improvement, then got stuck into improving things.[^luabuild] Number (3) would require caching of the C array. But we could avoid (1) and maybe (2) by checking them just once at the start of the loop. This was fairly quickly done, with respectable improvements to iteration speed, including:

- 25% faster type checking of function parameters using table-lookup rather than a for-loop to find valid types
- 50% faster by not re-checking subscripts at the Lua level every iteration

But what if we wanted to improve every single database operation, not just iteration? The benchmarks showed that there were two slow tasks that critical to every single database operation: converting the subscript list to C, and creating new Lua nodes.

As an example of the latter, let's create a Lua-database object:

```lua
guy = ydb.node('demographics').country.person.3
```

We can do all kinds of database activities on that node, for example: `node:lock_incr()   node:set('Fred')  node:lock_decr()` or even set create subnodes:

```lua
guy.gender:set('male')
guy.genetics.chomozome:set('X')
```

Each '.' above creates a new Lua subnode object, `genetics` and then `chromozome`, before you can finally set it to 'X'. You can imagine that a Lua programmer will be doing a lot of this, so it's a critical task: we need to optimise node creation.

To achieve this we needed to find the 'Holy Grail': ***fast creation*** of ***cached C arrays***. That would extend these benefits to *every* database function.

My early wins made it feel like I was about half way there. I told my employer the efficiency task would take 5 days. By this time I'd use up about half of that, and I thought I was on track. All that was left was to cache the subscript list. I mean, how hard can it be to cache something? You just have to store the C array when the node is first created, and use it again each time the node is accessed, right? Little did I know.

## Caching subscripts: a surprisingly daunting task

Achieving these two goals together proved to be so difficult that it took me four rewrites.

At the outset, each node already held all its subscripts, but in Lua rather than C. The node object looked like this:

```lua
node = {
    __varname = "demographics"
    __subsarray = {"country", "person", "3", "gender"}
}
```

Be aware that creating a table in Lua is slow compared to a C array: it requires a malloc, linkage into the Lua garbage collector, a hash table, and creation of a numerical array portion. And here we need *two* of them (one for the node object itself, and another for the subsarray). So its relatively slow. But at this point I didn't know that this was the speed hog.

### Iteration 1: An array of strings

In the first 3 iterations, I simply stored the C cache-array as a `userdata` field within the regular node object (the `userdata` type is a chunk of memory allocated by Lua for a C program), as follows:

```lua
node.__cachearray = cachearray_create("demographics", "country", "person", "3", "gender")
```

Since Lua already referenced the strings in `__subsarray`, my function `cachearray_create()` just had to malloc(depth * string_pointers) and point them to the strings *already existing in Lua*. But this would mean I had to keep the `__subsarray` table to reference these strings and prevent Lua from garbage-collecting them while in use by C. This would speed up node re-use, but adding `__cachearray` to the node would *slow down* node creation time.

Instead, I noticed that each child node repeats all its parent's subscripts. So I saved both memory and time, by making each child node object containing only their own rightmost subscript `__name` and `__parent`. This way I avoid having to create the whole Lua `__subsarray` table for each node. So `demographics.country.person[3].gender` would create a child node with a linked list to its `__parents` in Lua: `gender -> 3 -> person -> country`.

#### Segfaults and Valgrind

That was the design for iteration 1. But the `__parent` thing made it a little complicated, because you had to create the cache-array by recursing backwards into all the node's ancestors. This complexity hid a nasty segfault that I couldn't find for a long time. You know the kind of C pointer bug where the symptom occurs nowhere near the cause? (I should have used `valgrind myprog` to help find it, but I hadn't used [Valgrind](https://valgrind.org/) before, and I didn't realise how dead simple it was to use. Later, needed it again, and discovered that using it is true bliss.) Anyway, the bug ended up being a case of playing "where's Wally" with hidden asterisks: `malloc(n_subscripts * sizeof(ydb_buffer_t*))`, except I shouldn't have included the final `*` because the YDB API requires an array of buffer structs, not pointers to structs. In the end I found the bug by manually running Lua's `collectgarbage()` – which often makes memory errors occur sooner rather than later.

#### Fast traversal: 'mutable' nodes

Now we had a node with cache, for fast access to the database. But we still didn't have fast node traversal, like in Alain's tests. Because each time you iterate Alain's `for` loop, you have to create a new node: `^BCAT("lvd",1)  ^BCAT("lvd",2)`, etc.  I made a way to re-use the same array and change just the last subscript: `cachearray_subst()`.

But changing a node's subscripts is dodgy. It makes the same node object in Lua refer to a different database node. But if you've stored that Lua object for use later (e.g., when scanning through to find the highest value node: `maxnode = thisnode`).[^mutable] The programmer doesn't expect that.

Enter the concept of a 'mutable' node, which the programmer explicitly expects to change. Iterators like the pairs() can now return mutable nodes. The programmer can test for mutability using the `ismutable()` method. This provides sufficient warning to the programmer that the object should be converted to a non-mutable node, in case he wants to store it for use after the loop.

It worked! Now we have a lightning-fast iterator, and in most cases the programmer doesn't have to think about it.

#### Garbage collection & Lua versions (perhaps put in a footnote)

Now I just had to tell Lua's garbage collector about my mallocs. In Lua 5.4 this would have been easy: just add node method `__gc = c_collector_function` to the object. But this doesn't work on tables in Lua 5.1, and we wanted lua-yottadb to support Lua 5.1 since LuaJIT is stuck on the Lua 5.1 interface – so some people still use Lua 5.1. Instead, I was forced to allocate memory using Lua's "full userdata" type, which is slower than malloc, but at least it provides memory that is managed by Lua's garbage collector.

[Incidentally, this should have been a clue to me to use the full userdata type as the object *instead of* a Lua table because that would save creating a whole Lua table. But at this stage, since Lua 5.1 userdata doesn't store Lua values, I was locked into thinking we still needed the Lua table to store Lua references to the strings. Later I would have to revisit this and effectively *create* a way for Lua 5.1 userdata to store Lua values.]

Lastly, I made some unit tests, and I thought I'd be done. But node creation wasn't really any faster.

### Iteration 2: A shared array of strings

At this stage I'd already spent 12 days: over twice as long as I'd anticipated. That's not too outrageous for a new concept design. Strictly, I should have told my employer that I was over-budget, so they could make the call on further development. But I was embarrassed that my node creation benchmark was not really faster than the original. We had fast iteration now, but I had anticipated that everything would be faster. Something was wrong, and I decided to just knuckle down and find it.

At this point I made a mistaken judgement-call that cost development time. I guessed (incorrectly) that the speed issues were because each node creation had to copy its parent's array of string pointers. Instead of verifying my theory, I implemented a fix, adding complexity as follows.

Each child node retained a duplicate copy of the entire C array of string-pointer structs. But this seemed unnecessary since each child added only one subscript string at the end. Let's keep just one copy of the C array and have **each child** node reference the same array but keep its specific **depth** as follows:

```lua
array = cachearray("demographics", "country", "person", "3", "gender")
root_node   = {__cachearray=array, __depth=1}
country_node= {__cachearray=array, __depth=2}
person_node = {__cachearray=array, __depth=3}
id_node     = {__cachearray=array, __depth=4}
gender_node = {__cachearray=array, __depth=5}
```

This works, but adds some complexity, because if you create alternate subscript paths like: `root.person.3.male` and then `person.4.female`. Then the code has to detect that the cache array is full at numeric id_node, and create a duplicate cache-array after all. It also complicates the Lua code because the C code now has to return a depth as well as the array.

Although it does speed up node creation, it's still not as much as expected, because it's also slowing down node creation simply by adding the __depth field to the object.[^closure_trial]

[^closure_trial]: At this point I tried to store the `__depth` in C by using what Lua calls a 'C closure'. What I didn't realise is that although a normal Lua closure can have Lua locals for each instance of a function a C closure is different: it can only store one set of locals for the entire C library. This didn't let me store `__depth` against each node object at all. So that was a wasted attempt.

### Iteration 3: A breakthrough - the complete object in C

Up to this point I had been assuming I needed a Lua table to create a Lua object. After all, it seemed so efficient to make C just point to the existing Lua strings; and for that I needed Lua to reference those strings: hence a Lua table.

But now I finally did some more benchmarking and showed Lua table creation to be the speed hog. Remember: it does a malloc, links to the Lua garbage collector, creates a hash table, and a numerical array portion. Plus, we're adding three hashed fields, which are not exactly instant: `__parent`, `__cachearray`, and `__depth`.

It sure would be much faster if we could store all this data inside a C struct. So I read the manual again and discovered that the `userdata` type can *be* a Lua object all by itself. I should have guessed this from the start. You can assign a metatable to a `userdata` – which means that you can give it object methods – which means it can actually *be* the node object, all by itself. No need to create a Lua table for a C object at all.

Implementing this, my `userdata` C struct now looks something like this:

```C
typedef struct cachearray_t {
  int subsdata_alloc;   // size allocated for subscript strings after subs_array
  short depth_alloc;    // number of array items space was pre-allocated for
  short depth_used;     // number of used items in array
  ydb_buffer_t subs_array[]; // subs stored here, then reallocated if it grows too much
  char subsdata[];
} cachearray_t;
```

I pre-allocated space for extra slots (5, by default, before needing reallocation). Thus, when you create `ydb.node("demographics")` you can follow that up with `.country.person[3].female` and all these subsequent subscripts get stored in the same, previously allocated C-array.

Notice that this struct contains two expanding sections (it's really two separate structs): the array of string pointers `subs_array` and the actual string characters `subsdata`. It would better to keep these in a single array of structs, and thus have just one expanding section. But we cannot do that because we need an array of ydb_buffer_t to pass to the YDB API. These two expanding sections adds complexity to the code, but don't slow it down. It would be simpler to allocate two `userdata` sections: one for each section – but that *would* slow it down.

Also notice that since `subsdata` now stores subscript strings in my C `userdata`, I don't need to keep a Lua table that references their Lua copies, which are now set free.

Anyway, this cache-array can now hold subscripts for several nodes. But I still need to store the depth of each particular node somewhere. For this, I have a 'dereference' struct which points to a cache-array and remembers the depth of this particular node.

```C
typedef struct cachearray_dereferenced {
  struct cachearray_t *dereference; // merely points to a cachearray
  short depth; // number of items in this array
} cachearray_dereferenced;
```

For the root node, I store both the cache-array and this dereference struct in the same `userdata`. Child nodes only need the dereference struct. This dereferencing does add some complexity, but it's worth it to avoid proliferating duplicate cache-arrays, which would fill up CPU cache and slow things down.

Finally, all subscript strings are cached all in C, and I only need to create a `userdata` for each node, not a table. The irony is that the iteration1's original motivation to re-use Lua strings was a false economy. It turns out that it's just as fast to copy the strings into C as it is in Lua to do the necessary check that all subscripts are strings. And it doesn't even waste any memory, because the Lua strings can then be garbage collected instead of held by reference.

### Iteration 4: The future  –  instant node creation

There's one more improvement that will provide virtually instant node creation when using dot notation like `demographics.country.person[3].female`. 

You'll notice that each node creation still has the overhead of allocating a `userdata` to reference the cache-array. Well, Lua has another type called a `light userdata`: which is nothing more than a C pointer. There's no memory allocated to it. If I were to pre-allocate space for a depth-array within the main cache-array then the root node can be a `full userdata`, but child nodes can be `light userdata`: complete free to create. We just need to pre-allocate an array of dereferenced cache-arrays at the start of the cache-array struct:

```C
typedef struct cachearray_t {
    cachearray_dereferenced[5];
    ...
```

This will finally make full use of that mistaken judgement-call I made early on, and re-use pre-allocation to ultimate effect.

The only gotcha is that since a `light userdata` object has no storage, Lua doesn't know what metatable is associated with it. There's only one global metatable for all `light userdata` objects. No matter: we can hook the global metatable and then store an ID number in the dereferenced cache-array to identify it as a cache-array.

Node creation time in lua-yottadb v2.1 is already 47x faster than v1.2. I'm anticipating this improvement will increase that to 200x, making dot notation virtually free. This will also keep all allocated memory together in one place: better for CPU caching.

But by now I've taken 25 days to implement this thing. I don't dare ask my employer for another day to implement this nicety. I'll probably do it in my own time, just for closure…

## Further improvement?

IMHO, lua-yottadb is now about as fast as it can get. Why is it still 1.3 times slower than M when a basic for loop is 17x faster in Lua than in M? My suspicion is that 



I had a chat to [Bhaskar](https://gitlab.com/ksbhaskar), co-author of Yottadb about whether there are additional conversions on the YDB-side of the API that might slow things down.

## Portability: Python, etc.

In theory, the final version of `cachearray.c` is the best version to port to another language without a compete re-write. Now that it keeps its strings entirely in C, it's fairly self-contained. Having said that, it will need substantial changes, for example, in how it receives function parameters: from the Lua stack. The other language's wrapper will obviously also need to support cache-arrays.

A quick look at Python's YDBPython, for example, shows that its C code has the same design as the original lua-yottadb, and is probably slow. Every time it accesses the database, it has to verify your subscript list, and copy each string to C. Unlike lua-yottadb, YDBPython also does an additional malloc for each individual subscript string. Caching the subscript array could provide a significant speedup.

The Python code to create an object also has the same low-hanging fruit as lua-yottadb. But YDBPython has an additional easy win by using `__slots__`, a [Python feature](https://wiki.python.org/moin/UsingSlots) not available in Lua. A [quick benchmark](https://github.com/berwynhoyt/lua-yottadb/blob/blog/blog/object_creation.py) tells me that using a single `__slots__` line of code makes python bare object creation 20% faster: almost as fast as [Lua's object creation](https://github.com/berwynhoyt/lua-yottadb/blob/blog/blog/object_creation.lua) using `userdata`.

At this stage I do not know much about Python's C API: neither about Python's alternatives to `userdata` objects, nor whether Python has a faster way of implementing dot notation without creating intermediate nodes.

## Learnings

Perhaps most significantly, this article raises some of the significant issues that efficiency improvements in any language will have to work through. Hopefully, this will allow someone to implement it in iteration 1, rather than iteration 4.

Here are a few other take-homes from these experiences:

- Always test your theories about what's causing the slow-down before implementing a complete fix.
- Communicate with your employer early, even if its embarrassing: even the reporting process might expose your assumptions. I knew this already, but pride got in the way:flushed:.
- Useful details about implementing a Lua library in C: speedy userdata, light userdata, and Valgrind for emergencies.

I learned a lot through this process, and I hope you learned something, too.

[^luabuild]: Alain's benchmark was skewed by a curiously slow build of Lua that he used. His sysadmin tells me it was compiled with -O0. He has now compiled it with -O3, which has demonstrably doubled the speed. In any case, the benchmark comparisons I've supplied are all from my laptop (the mainframe's database setup is faster).

[^mutable]: Worse, when we later introduce cache-array shared with parent nodes, if you create a sub-node out of it and store that, then your sub-node's parent subscript will get changed, since it uses the same cache-array.
