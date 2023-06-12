# Making Lua–MUMPS Fast

**TLDR:** This blog article is about how we improved [lua-yottadb](https://github.com/anet-be/lua-yottadb) to go ~4x as fast when looping through database records, and a stunning 47x as fast when creating Lua objects for database nodes, plus other improvements ([results here](https://github.com/anet-be/mlua/tree/master/benchmarks#lua-yottadb-v12-compared-with-v21)). There were some low-hanging fruit, but the biggest (and trickiest) improvement was caching the node's subscript array in the Lua object that references a specific database node. Finally, [porting to other language wrappers](#portability-python-etc) is discussed, as well as a tentative thought on how YDB might support an [even faster API](#ydb-api-overhead-a-suggestion). Along the way we [learned numerous things](#lessons) that might help someone port these efficiencies to other languages.

---

I had recently released [MLua](https://github.com/anet-be/mlua), a tool to let MUMPS (M) code call Lua. Then in Oct 2022, I got my first user: [Alain Descamps](https://github.com/AlainDsc), of the Antwerp University Library (sponsors of MLua), and a heavy user of MUMPS. An actual user. Brilliant!

But the euphoria didn't last long. Mere hours later, I got Alain's first benchmark: Lua was 4 times slower than M at simply traversing (counting) database records on our dev server. Even worse, when run on my local PC's database, Lua was [8 times slower than M](https://github.com/anet-be/mlua/tree/master/benchmarks#comparison-with-m). Grrr…  So I embarked on what I thought would be a 5-day pursuit of efficiency … but it took 25 days! Nevertheless, I did get the dev server's Lua time down from 4x to 1.3x the speed of M. A very nice result.

## What was the problem?

Alain's Lua benchmark script was simple – akin to this:

```lua
ydb = require('yottadb')
gref1 = ydb.key('^BCAT')('lvd')('')
cnt = 0  for x in gref1:subscripts() do  cnt=cnt+1  end
print("total of " .. cnt .. " records")
```

> If you're new to M, to understand what's going on, you need to know that M database nodes are represented by a series of 'subscript' strings, just like a file-system path. Whereas a path might be `root/var/log/file`, an M node would be `root("var","log","nodename")` or `root.var.log.nodename`. Each node can hold a bit of data, further sub-nodes (similar to directories in a file-system), or both.

The program above simply loops through a sequence of 5 million database nodes with subscripts `^BCAT.lvd.<n>` like so:

```lua
^BCAT("lvd")("")
^BCAT("lvd")(1)
^BCAT("lvd")(2)
^BCAT("lvd")(3) ...
```

To do so took 20 seconds in Lua, and 5 seconds [in M](https://github.com/berwynhoyt/lua-yottadb/blob/blog_efficiency/blog/zadloop.m). A quick code review of [lua-yottadb](https://github.com/anet-be/lua-yottadb) (the database access layer of MLua) found a number of low-hanging fruit in the `gref1:subscripts()` method above. The issues were that for every loop iteration, `gref1:subscripts()` did this:

1. Checked each subscript in the node's 'path' at the Lua level to make sure it was a valid string.
2. Checked each subscript again at the C level.
3. Converted the subscript array into a C array of string pointers (for calling the M API), then discarded the C array.

Yep. That all happened at every iteration.

Next, I built some [benchmarks tests](https://github.com/anet-be/mlua/tree/master/benchmarks) to track our improvement, then got stuck into improving things.[^luabuild] Avoiding number (3) would require caching of the C array. But we could avoid (1) and maybe (2) by checking them just once at the start of the loop. This was fairly quickly done, with respectable improvements to iteration speed, including:

- [25% faster type checking](https://github.com/anet-be/lua-yottadb/pull/23/commits/774018fe522c8d1f3c097370f1e7850db84b9c1d) of function parameters using table-lookup rather than a for-loop to find valid types
- [50% faster by not re-checking subscripts](https://github.com/anet-be/lua-yottadb/pull/23/commits/aa2496ef75e4840d650a9af7e5f5096921f49ba2) at the Lua level every iteration

But what if we wanted to improve every single database operation, not just iteration? The benchmarks showed that there were two slow tasks critical to every single database operation: a) converting the subscript list to C, and b) creating new Lua nodes.

As an example of the latter, let's create a Lua-database object:

```lua
guy = ydb.node('demographics').country.person[3]
```

We can do all kinds of database activities on that node, for example:

```lua
node:lock_incr()
node:set('Fred')
node:lock_decr()
```

or even set create subnodes:

```lua
guy.gender:set('male')
guy.genetics.chomosome:set('X')
```

Each '.' above creates a new Lua subnode object (in this case, `genetics` and then `chromosome`) before you can finally set it to 'X'. You can imagine that a Lua programmer will be doing a lot of this, so it's a critical task: we need to optimise node creation.

To achieve this we needed to find the 'Holy Grail': **fast creation** of **cached C arrays**. That would extend these benefits to *every* database function.

My early wins made it feel like I was about half way there. I'd told my employer the efficiency task would take 5 days. By this time I'd use up about half of that, and I thought I was on track. All that was left was to cache the subscript list. I mean, how hard can it be to cache something? You just have to store the C array when the node is first created, and use it again each time the node is accessed, right? Little did I know.

## Caching subscripts: a surprisingly daunting task

Achieving these two goals together proved to be so difficult that it took me three rewrites.

At the outset, each node already held all its subscripts – but in Lua, rather than C. The node object looked like this:

```lua
node = {
    __varname = "demographics"
    __subsarray = {"country", "person", "3", "gender"}
}
```

Be aware that creating a table in Lua is slow compared to a C array: it requires a malloc, linkage into the Lua garbage collector, a hash table, and creation of a numerical array portion. And here we need *two* of them (one for the node object itself, and another for the `__subsarray`). So it's relatively slow. But at this point I didn't know that this was the speed hog.

### Iteration 1: An array of strings

In the first 2 iterations, I simply stored the C cache-array as a `userdata` field within the regular node object as follows (`userdata` is a Lua type that represents a chunk of memory allocated by Lua for a C program):

```lua
node.__cachearray = cachearray_create("demographics", "country", "person", "3", "gender")
```

Since Lua already referenced the strings in `__subsarray` (presented previously), my function `cachearray_create()` just had to allocate space for it: `malloc(depth * string_pointers)`, and point them to the strings *already existing in Lua*. But this would mean I had to retain the `__subsarray` table to reference these strings and prevent Lua from garbage-collecting them while in use by C.

Although this caching would speed up node re-use, adding `__cachearray` to the node would actually *slow down* node creation time. To prevent the slow-down, I noticed that each child node repeats all its parent's subscripts. So I saved both memory and time, by making each child node object contain only its own rightmost subscript `__name` and point to `__parent` for the rest:

```lua
node = {
    __varname = "demographics"
    __name = "gender"
    __parent = parent_node      -- in this case, "3"
}
```

This way I avoid having to create the whole Lua `__subsarray` table for each node. So each node contains a linked list to its `__parents`: `gender -> 3 -> person -> country`.

If you're **getting bored** at this point, I suggest you skip to [iteration 3](#iteration-3-a-breakthrough---the-complete-object-in-C).

#### Segfaults and Valgrind

That was the design for iteration 1. But the `__parent` thing made it a little complicated, because you had to create the cache-array by recursing backwards into all the node's ancestors. This complexity hid a nasty segfault that I couldn't find for a long time. You know the kind of C pointer bug where the symptom occurs nowhere near the cause? (I should have used `valgrind myprog` to help find it, but I hadn't used [Valgrind](https://valgrind.org/) before, and I didn't realise how dead simple it was to use. Later, I needed it again, and discovered that using it is true bliss.)

Anyway, the bug ended up being a case of playing "where's Wally" except with hidden asterisks. The code was: `malloc(n_subscripts * sizeof(ydb_buffer_t*))`, except I shouldn't have included the final `*` because the YDB API uses an array of buffer structs, not pointers to structs. In the end I found the bug by manually running Lua's `collectgarbage()` – which often makes memory errors occur sooner rather than later.

#### Fast traversal: 'mutable' nodes

Finally, we had a node with cache – for fast access to the database. But we still didn't have fast node traversal, like in Alain's tests. This is because each time you iterate Alain's `for` loop, you have to create a new node: `^BCAT("lvd",1)  ^BCAT("lvd",2)`, etc.  So I made the function `cachearray_subst()` re-use the same array, altering just the last subscript.

But changing a node's subscripts is dodgy. It makes the same node object in Lua refer to a different database node than it used to. Imagine that you're the programmer and have stored that Lua object for use later (e.g., when scanning through to find the highest value node: `maxnode = thisnode`).[^mutable] You'll still be expecting the stored maxnode to point to the maximum node.

Enter the concept of a 'mutable' node, which the programmer explicitly expects to change. Lua iterators like the pairs() can now return specifically mutable nodes. The programmer can convert this to an immutable node if he wants to store it for use after the loop, or he can test for mutability using the `ismutable()` method.

Well, it worked. Now we have a lightning-fast iterator, and in most cases the programmer doesn't have to worry about mutability.

#### Garbage collection & Lua versions

All that remained was to tell Lua's garbage collector about my mallocs. In Lua 5.4 this would have been easy: just add node method `__gc = cachearray_free` to the object. But `__gc` doesn't work in Lua 5.1 on tables (which is what our node object is), and we wanted lua-yottadb to support Lua 5.1 since LuaJIT is stuck on the Lua 5.1 interface – so some people still use Lua 5.1. Instead of simply setting `__gc = cachearray_free`, I had to allocate memory using Lua's "full userdata" type, which is slower than malloc, but at least it provides memory that is managed by Lua's garbage collector.[^5.1garbage]

Lastly, I made some unit tests, and I thought I'd be done. But node creation wasn't really any faster.

### Iteration 2: A shared array of strings

At this stage I'd already spent 12 days: over twice as long as I'd anticipated. That's not too outrageous for a new concept design. Strictly, I should have told my employer that I was over-budget, so they could make the call on further development. But I was embarrassed that my node creation benchmark was not really faster than the original. We had fast iteration now, but I had anticipated that everything would be faster. Something was wrong, and I decided to just knuckle down and find it.

At this point I made a mistaken judgment-call that cost development time. I guessed (incorrectly) that the speed issues were because each node creation had to copy its parent's array of string pointers. Instead of verifying my theory, I implemented a fix, adding complexity as follows.

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

### Iteration 3: A breakthrough - the complete object in C

Up to this point I had been assuming I needed a Lua table to create a Lua object. After all, it seemed so efficient to make C just point to the existing Lua strings; and for that I needed Lua to reference those strings: hence a Lua table.

But now I finally did some more benchmarking and showed Lua table creation to be the speed hog. Remember: it does a malloc, links to the Lua garbage collector, creates a hash table, and a numerical array portion. Plus, we're adding three hashed fields, which are not exactly instant: `__parent`, `__cachearray`, and `__depth`.

It sure would be much faster if we could store all this data inside a C struct. So I read the manual again and discovered that the `userdata` type can *be* a Lua object all by itself. I should have guessed this from the start. You can assign a metatable to a `userdata` – which means that you can give it object methods – which means it can actually *be* the node object, all by itself. No need to create a Lua table for a C object at all.

Implementing this, my `userdata` C struct now looks something like this:

```C
typedef struct cachearray_t {
  int subsdata_alloc;   // size allocated for strings (last element)
  short depth_alloc;    // number of pre-allocated array items
  short depth_used;     // number of used items in array
  ydb_buffer_t subs_array[]; // struct reallocated if this exceeded
  char subsdata[];
} cachearray_t;
```

I pre-allocated space for extra slots (5, by default, before needing reallocation). Thus, when you create `ydb.node("demographics")` you can follow that up with `.country.person[3].female` and all these subsequent subscripts get stored in the same, previously allocated C-array.

Notice that this struct contains two expanding sections (it's really two separate structs): the array of string pointers `subs_array` and the actual string characters `subsdata`. It would be better to keep these in a single array of structs, and thus have just one expanding section. But we cannot do that because we need an array of `ydb_buffer_t` to pass to the YDB API. These two expanding sections adds complexity to the code, but don't slow it down. It would be simpler to allocate two `userdata` sections: one for each section – but that *would* slow it down.

Also notice that since `subsdata` now stores subscript strings in my C `userdata`, I don't need to keep a Lua table that references their Lua copies, which are now set free.

Anyway, this cache-array can now hold subscripts for several nodes. But I still need to store the depth of each particular node somewhere. For this, I have a 'dereference' struct which points to a cache-array and remembers the depth of this particular node.

```C
typedef struct cachearray_dereferenced {
  struct cachearray_t *dereference; // merely points to a cachearray
  short depth; // number of items in this array
} cachearray_dereferenced;
```

For the root node, I store both the cache-array and this dereference struct in the same `userdata`. Child nodes only need the dereference struct.[^lua_dereference] This dereferencing does add some complexity, but it's worth it to avoid proliferating duplicate cache-arrays, which would fill up CPU cache and slow things down.

Finally, all subscript strings are cached all in C, and I only need to create a `userdata` for each node, not a table. The irony is that the iteration1's original motivation to re-use Lua strings was a false economy. It turns out that it's just as fast to copy the strings into C as it is in Lua to do the necessary check that all subscripts are strings. And it doesn't even waste any memory, because the Lua strings can then be garbage collected instead of held by reference.

By now, I've taken 25 days to implement this thing. I'm going to have some serious explaining to do to my employer. That, in fact, is how this article began.

### Iteration 4: The gauntlet challenge - cheap node creation

Instant subnode creation is possible if `light userdata` were used for it. However, these nodes could never be freed since `__gc` finalizer methods do not work on `light userdata` in Lua. Can anyone think of a workaround?

Consider a Lua object for database node `demographics`. Subnodes can be accessed using dot notation: `demographics.country.person`. Even with our latest design, subnodes still have the overhead of allocating a full `userdata`. But Lua has a cheaper type called a `light userdata`: which is nothing more than a C pointer, and free to create. We just need to pre-allocate space for several dereferenced subnodes within the parent node's `userdata`, and child nodes could simply point into it:

```C
typedef struct cachearray_t {
    cachearray_dereferenced[5];
    <regular node contents>...
```

This will finally make full use of that mistaken judgment-call I made early on, and re-use pre-allocation to ultimate effect.

But there's a gotcha. Since a `light userdata` object has no storage, Lua doesn't know what type of data it is, and therefore what metatable (i.e. object methods) to associate with it. So there's a single global metatable for all `light userdata` objects. No matter: we can still hook the global metatable, and then double-check ourselves that it points to a cache-array, before running cache-array class methods on it. Should work fine.

Node creation time in lua-yottadb v2.1 is already 47x as fast as v1.2, but I'm anticipating this improvement will increase that to 200x, making dot notation virtually free. This will also keep all allocated memory together in one place: also better for CPU caching.

This hack would actually work … except for one problem: it can't collect garbage. Tragically, Lua ignores the `__gc` method on `light userdata`. This means we'll never be able to remove the `light userdata's` reference to its root node. Which creates a memory leak. Here's an example to explain:

```lua
x = ydb.node("root").subnode
x = nil
```

First the `root` node is created; then `subnode` references `root`; then Lua assigns `subnode` to `x` so that `x` now references `subnode`. Finally, `x` is deleted. The problem is that when `x` is garbage-collected, Lua does not collect light userdata `subnode` (which is still referencing root). So root is not collected: a memory leak.

Can any of my readers can see a solution to this puzzle? I'm throwing down the gauntlet. Find a way to work around Lua's lack of garbage collection on light userdata, then [post it here](https://github.com/anet-be/lua-yottadb/discussions/28), and I'll make you famous on this blog. :wink:

## Portability: Python, etc.

In theory, my final `cachearray.c` is the best version to port to another language without a compete re-write because it now keeps its strings entirely in C – which means it's fairly self-contained and portable. Having said that, it will need changes in how it receives function parameters: which is from the Lua stack. The Python/etc. portion of the wrapper will also need extensions to support cache-arrays.

A quick look at Python's YDBPython, for example, shows that its C code has the same design as the original lua-yottadb – and is probably slow. Every time it accesses the database, it has to verify your subscript list, and copy each string to C. Unlike lua-yottadb, YDBPython also does an additional malloc for each individual subscript string. Caching the subscript array could provide a significant speedup, just as it did for Lua.

The Python code to create an object also has the same low-hanging fruit as lua-yottadb. But YDBPython has an additional easy one-line win by using `__slots__`, a [Python feature](https://wiki.python.org/moin/UsingSlots) not available in Lua. A [quick benchmark](https://github.com/berwynhoyt/lua-yottadb/blob/blog_efficiency/blog/object_creation.py) tells me that using `__slots__` makes python bare object creation 20% faster (though it needs another 25% to be as fast as [Lua's object creation](https://github.com/berwynhoyt/lua-yottadb/blob/blog_efficiency/blog/object_creation.lua) using `userdata`).

At this stage I do not know much about Python's C API: neither about Python's alternatives to `userdata` objects, nor whether Python has a faster way of implementing dot notation without creating intermediate nodes.

## YDB API overhead: a suggestion

After all this work, why is M still faster? I suspect that lua-yottadb is now about as fast as it can get. So why is database traversal in Lua still 30% slower than M (on our server), when a basic for-loop in [Lua](https://github.com/berwynhoyt/lua-yottadb/blob/blog_efficiency/blog/forloop.lua) is 17x as fast as [M](https://github.com/berwynhoyt/lua-yottadb/blob/blog_efficiency/blog/forloop.m)? My hunch was that there are subscript conversion overheads on the M side of the M-C API, that M doesn't need to incur since it's a built-in language. I had a chat to [Bhaskar](https://gitlab.com/ksbhaskar), founder of YottaDB, and he was able to confirm my hunch, as follows.

YDB keeps its values in what it calls 'mvals'. This is a C struct that can store multiple representations of the same value (number and string), with a bitfield that tells the system which representations are stored. When a value is needed in a new representation, it is converted and stored in the mval. This prevents repeated conversion between representations. However, since the C API does not expose mvals, conversion can add overhead to both the call and the return.

YottaDB also manages its own garbage collection that knows about mvals. So when data is passed to YottaDB, it needs to be copied into memory that is owned by YDB. Thus, mvals could only be shared with Lua if there were tight integration of memory management, that was strictly enforced. To do otherwise would risk database commits using incorrect data.

My work on this project suggests a possible avenue for a YDB API enhancement that may be worth considering. Given that languages like Lua and Python access data through node objects, one possibly way to improve performance would be for YDB to expose a function to **cache** a subscript array, storing it as mvals within M:

```c
handle = ydb_cachearray("demographics", "country", "person", "3", "gender")
```

This would return a handle to that cache-array, which could then be supplied to subsequent YDB API calls as the root operating node, instead of the GLVN, `varname`. This would allow rapid access to the same database node, or rapid iteration through subnodes, without having to re-convert all 5 subscripts on every call.

Of course, this is just a theory. Profiling would first be needed to check whether this conversion process is the actual cause of the speed differential, and how much this solution would typically help.

## Lessons

Perhaps most significantly, this article raises some of the significant issues that efficiency improvements in any language will have to work through. Hopefully, this will allow someone to implement it in iteration 1, rather than iteration 3.

Here are a few other take-homes from this experience:

- Always test your theories about what's causing the slow-down before implementing a complete fix.
- Communicate with your employer early, even if it's embarrassing: even the reporting process might expose your assumptions. (I knew this already, but pride got in the way :flushed:).
- Useful details about implementing a Lua library in C: speedy userdata, light userdata, and Valgrind for emergencies.

I sure did learn a lot through this process, and I hope you've learned something, too.



[^luabuild]: Alain's benchmark was skewed by a curiously slow build of Lua that he used. His sysadmin tells me it was compiled with -O0. He has now compiled it with -O3, which has demonstrably doubled the speed. In any case, the benchmark comparisons I've supplied are all from my laptop (the mainframe's database setup is faster).

[^mutable]: Worse, when we later introduce cache-array shared with parent nodes, if you create a sub-node out of it and store that, then your sub-node's parent subscript will get changed, since it uses the same cache-array.
[^5.1garbage]: Incidentally, this should have been a clue to use the `userdata` type for the object itself *instead of* a Lua table, because `__gc` *does* work on `userdata`, in Lua 5.1. But I didn't get there until iteration 3. At this stage, since Lua 5.1 `userdata` cannot reference Lua values, I was locked into thinking we still needed a Lua table to store Lua references to the subscript strings. Ironically, iteration 3 also required me to implement my own mechanism for `userdata` to reference Lua values so that the dereferenced 
[^closure_trial]: At this point I tried to store the `__depth` in C by using what Lua calls a 'C closure'. What I didn't realise is that although a normal Lua closure can have Lua locals for each instance of a function, a C closure is different: it can only store one set of locals for the entire C library. This didn't let me store `__depth` against each node object at all. So that was a wasted attempt.
[^lua_dereference]: Child nodes also need to Lua-reference their parent to avoid it being garbage collected while they're pointing to it. Ironically, iteration 3 thus required me to implement what I avoided in iteration 1: a way for Lua 5.1 `userdata` to reference Lua values.

