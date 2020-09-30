# Generics implementation - Dictionaries

This document describes a method to implement the [Go generics proposal](https://go.googlesource.com/proposal/+/refs/heads/master/design/go2draft-type-parameters.md) using compile-time instantiated dictionaries. Dictionaries will be stenciled per instantiation of a generic function.

When we generate code for a generic function, we will generate only a single chunk of assembly for that function. It will take as an argument a _dictionary_, which is a set of information describing the concrete types that the parameterized types take on. It includes the concrete types themselves, of course, but also derived information as we will see below.

A counter-proposal would generate a different chunk of assembly for each instantiation and not require dictionaries - see the [Generics Implementation - Stenciling](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-stenciling.md) proposal. The [Generics Implementation - GC Shape Stenciling](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-gcshape.md) proposal is a hybrid of that proposal and this one.

The most important feature of a dictionary is that it is compile-time computeable. All dictionaries will reside in the read-only data section, and will be passed around by reference. Anything they reference (types, other dictionaries, etc.) must also be in the read-only or code data sections.

A running example of a generic function:


```
func f [T1, T2 any](x int, y T1) T2 {
    ...
}
```


With a callsite:


```
f[int, float64](7, 3.5)
```


The implementation of f will have an additional argument which is the pointer to the dictionary structure. We could put the additional argument first or last, or in its own register. Reserving a register for it seems overkill. Putting it first is similar to how receivers are passed (speaking of which, would the receiver or the dictionary come first?). Putting it last means less argument shuffling in the case where wrappers are required (not sure where those might be yet).

The dictionary will contain lots of fields of various types, depending on what the implementation of f needs. Note that we must look inside the implementation of f to determine what is required. This means that the compiler will need to summarize what fields are necessary in the dictionary of the function, so that callers can compute that information and put it in the dictionary when it knows what the instantiated types are. (Note this implies that we can’t instantiate a generic function knowing only its signature - we need its implementation at compile time also. So implemented-in-assembly and cross-shared-object-boundary instantiations are not possible.)

The dictionary will contain the following items:


## Instantiated types

The first thing that the dictionary will contain is a reference to the `runtime._type` for each parameterized type.


```
type dictionary struct {
    T1 *runtime._type
    T2 *runtime._type
    ...
}
```


We should probably include these values unconditionally, even if the implementation doesn’t need them (for printing in tracebacks, for example).


## Derived types

The code in f may declare new types which are derived from the generic parameter types. For instance:


```
    type X struct { x int; y T1 }
    m := map[string]T1{}
```


The dictionary needs to contain a `*runtime._type` for each of the types mentioned in the body of f which are derived from the generic parameter types.


```
type dictionary struct {
    ...
    D1 *runtime._type // struct { x int; y T1 }
    D2 *runtime._type // map[string]T1
    ...
}
```


How will the caller know what derived types the body of f needs? This is a very important question, and will be discussed at length later (see the proto-dictionary section). For now, just assume that there will be summary information for each function which lets the callsite know what derived types are needed.


## Subdictionaries

If f calls other functions, it needs a dictionary for those calls. For example,


```
func g[T](g T) { ... }
```


Then in f,


```
    g[T1](y)
```


The call to g needs a dictionary. At the callsite to g from f, f has no way to know what dictionary it should use, because the type parameterizing the instantiation of g is a generic type. So the caller of f must provide that dictionary.


```
type dictionary struct {
    ...
    S1 *dictionary // SubDictionary for call to g
    S2 *dictionary // SubDictionary for some other call
    ...
}
```



## Helper methods

The dictionary should contain methods that operate on the generic types. For instance, if f has the code:


```
    y2 := y + 1
    if y2 > y { … }
```


(assuming here that `T1` has a type list that allows `+` and `>`), then the dictionary must contain methods that implement `+` and `>`.


```
type dictionary struct {
    ...
    plus func(z, x, y *T1)      // does *z = *x+*y
    greater func(x, y *T1) bool // computes *x>*y
    ...
}
```


There’s some choice available here as to what methods to include. For `new(T1)` we could include in the dictionary a method that returns a `*T1`, or we could call `runtime.newobject` directly with the `T1` field of the dictionary. Similarly for many other tasks (`+`, `>`, ...), we could use runtime helpers instead of dictionary methods, passing the appropriate `*runtime._type` arguments so the runtime could switch on the type and do the appropriate computation.


## Stack layout

`f` needs to allocate stack space for any temporary variables it needs. Some of those variables would be of generic type, so `f` doesn’t know how big they are. It is up to the dictionary to tell it that.


```
type dictionary struct {
    ...
    frameSize uintptr
    ...
}
```


The caller knows the types of all the temporary variables, so it can compute the stack size required. (Note that this depends a lot on the implementation of `f`. I’ll get to that later.)

Stack scanning and copying also need to know about the stack objects in `f`. The dictionary can provide that information


```
type dictionary struct {
    ...
    stackObjects []stackObject
    ...
}
type stackObject struct {
    offset uintptr
    typ *runtime._type
}
```


All values of generic type, as well as derived types that have bare generic types in them (e.g. `struct {x int; y T1}` or `[4]T1`, but not reference types with generic bases, like `[]T1` or `map[T1]T2`), must be stack objects. `f` will operate on such types using pointers to these stack objects. Preamble code in `f` will set up local variables as pointers to each of the stack objects (along with zeroing locals and return values?). All accesses to generic typed values will be by reference from these pointers.

There might also be non-generic stack objects in `f`. Maybe we list them separately, or combine the lists in the dictionary (so we only have to look in one place for the list).

The outargs section also needs some help. Marshaling arguments to a call, and copying back results from a call, are challenging because the offsets from SP are not known to `f` (if any argument has a type with a bare generic type in it). We could marshal/unmarshal arguments one at a time, keeping track of an argument pointer while doing so. If `f` calls `h`:


```
func f[T1, T2 any](x int, y T1, h func(x T1, y int, z T2) int) T2 {
    var z T2
    ....
    r := h(y, x, z)
}
```


then we would compile that to:


```
argPtr = SP
memmove(argPtr, &y, dictionary.T1.size)
argPtr += T1.size
argPtr = roundUp(argPtr, alignof(int))
*(*int)argPtr = x
argPtr += sizeof(int)
memmove(argPtr, &z, dictionary.T2.size)
argPtr += T2.size
call h
argPtr = roundUp(argPtr, 8) // alignment of return value start
r = *(*int)argPtr
```


Another option is to include in the dictionary the offset needed for every argument/return value of every function call in `f`. That would make life simpler, but it’s a lot of information. Something like:


```
memmove(SP + dictionary.callsite1.arg1offset, &y, dictionary.T1.size)
*(*int)(SP + dictionary.callsite1.arg2offset) = x
memmove(SP + dictionary.callsite1.arg3offset, &z, dictionary.T2.size)
call h
r = *(*int)(SP + dictionary.callsite1.ret1offset)
```


We could share information for identically-shaped callsites. And maybe keep the offset arrays as separate global symbols and keep references to them in the dictionary (one more indirection for each argument marshal, but may use less space).

We need to reserve enough space in the outargs section for all the marshaled arguments, across all callsites. The `frameSize` field of the dictionary should include this space.

Another option in this space is to change the calling convention to pass all values of generic type by pointer. This will simplify the layout problem for the arguments sections. But it requires implementing wrapper functions for calls from generic code to non-generic code or vice-versa. It is not entirely clear what the rules would be for where those wrappers get generated and instantiated.

The outargs plan will get extra complicated when we move to a [register-based calling convention](https://github.com/golang/go/issues/40724). Possibly calls out from generic code will remain on ABI0.


## Pointer maps

Each stack frame needs to tell the runtime where all of its pointers are.

Because all arguments and local variables of generic type will be stack objects, we don’t need special pointer maps for them. Each variable of generic type will be referenced by a local pointer variable, and those local pointer variables will have their liveness tracked as usual (similar to how moved-to-heap variables are handled today).

Arguments of generic type will be stack objects, but that leaves the problem of how to scan those arguments before the function starts - we need a pointer map at function entry, before stack objects can be set up.

For the function entry problem, we can add a pointer bitmap to the dictionary. This will be used when the function needs to call morestack, or when the function is used in a `go` or `defer` statement and hasn’t started running yet.


```
type dictionary struct {
    ...
    argPointerMap bitMap // arg size and ptr/nonptr bitmap
    ...
}
```


We may be able to derive the pointer bitmap from the list of stack objects, if that list made it easy to distinguish arguments (args+returns are distinguished because the former are positive offsets from FP and the latter are negative offsets from FP. Distinguishing args vs returns might also be doable using a retoffset field in funcdata).


## End of Dictionary


```
type dictionary struct {
    ...
    // That's all?
}
```



## The Proto-Dictionary

There’s a lot of information we need to record about a function `f`, so that callers of `f` can assemble an appropriate dictionary. We’ll call this information a proto-dictionary. Each entry in the proto-dictionary is conceptually a function from the concrete types used to instantiate the generic function, to the contents of the dictionary entry. At each callsite at compile time, the proto-dictionary is evaluated with the concrete type parameters to produce a real dictionary. (Or, if the callsite uses some generic types as type arguments, partially evaluate the proto-dictionary to produce a new proto-dictionary that represents some sub-dictionary of a higher-level dictionary.) There are two main features of the proto-dictionary. The first is that the functions described above must be computable at compile time. The second is that the proto-dictionary must be serializable, as we need to write it to an object file and read it back from an object file (for cases where the call to the generic function is in a different package than the generic function being called).

The proto-dictionary includes information for all the sections listed above:



*   Derived types. Each derived type is a “skeleton” type with slots to put some of `f`’s type parameters.
*   Any sub-proto-dictionaries for callsites in `f`. (Note: any callsites in `f` which use only concrete type parameters do not need to be in the dictionary of `f`, because they can be generated at that callsite. Only callsites in `f` which use one or more of `f`’s type parameters need to be a subdictionary of `f`’s dictionary.)
*   Helper methods, if needed, for all types+operations that need them.
*   Stack layout information. The proto-dictionary needs a list of all of the stack objects and their types (which could be one of the derived types, above), and all callsites and their types (maybe one representative for each arg/result shape). Converting from a proto-dictionary to a dictionary would involve listing all the stack objects and their types, computing all the outargs section offsets, and adding up all the pieces of the frame to come up with an overall frame size.
*   Pointer maps. The proto-dictionary needs a list of argument/return values and their types, so that it can compute the argument layout and derive a pointer bitmap from that. We also need liveness bits for each argument/return value at each safepoint, so we can compute pointer maps once we know the argument/return value types.


## Closures

Suppose f creates a closure?


```
func f[T any](x T, y T) {
    c := func() {
        x = y
    }
    c()
}
```


We need to pass a dictionary to the anonymous function as part of the closure, so it knows how to do things like copy values of generic type. When building the dictionary for `f`, one of the subdictionaries needs to be the dictionary required for the anonymous function, which `f` can then use as part of constructing the closure.


## Generic Types

This document has so far just considered generic functions. But we also need to handle generic types. These should be straightforward to stencil just like we do for derived types within functions.


## Deduplication

We should name the dictionaries appropriately, so deduplication happens automatically. For instance, two different packages instantiating `f` using the same concrete types should use the same dictionary in the final binary. Deduplication should work fine using just names as is done currently in the compiler for, e.g., `runtime._type` structures.

Then the worst case space usage is one dictionary per instantiation. Note that some subdictionaries might be equivalent to a top-level dictionary for that same function.


## Other Issues

Recursion - can a dictionary ever reference itself? How do we build it, and the corresponding proto-dictionaries, then? I haven’t wrapped my head around the cases in which this could come up.

Computing the proto-dictionary for a function probably requires compiling the function, so we know how many of each temporary of generic type is required. For other global passes like escape analysis, we don’t actually need the compiled code to compute the summary. An early pass over the source code is enough. It’s possible we could avoid the need to compile the function if we were ok with being conservative about the locals needed.

Dictionary layout. Because the dictionary is completely compile time and read only, it does not need to adhere to any particular structure. It’s just an array of bytes. The compiler assigns meanings to the fields as needed, including any ordering or packing. We would, of course, keep some sort of ordering just for our sanity.

The exception to the above is that the runtime needs access to a few of the dictionary fields. Those include the stackObjects slice and the pointer maps. So we should put these fields first in the dictionary. We also need a way for the runtime to get access to the dictionary itself, which could be done by always making it the first argument, and storing it in a known place (or reading out the stack object slice and pointer maps, and storing those in a known place in the stack frame).

Register calling convention: argument stack objects? Use ABI0? If arguments come in registers, and those registers contain data for a generic type, it could be complicated to get that data into a memory location so we can take the address of it.

Mentioned above, for the same reason we might want to use ABI0 for calling out (at least if any argument type is generic).

TODO: calling methods on generic types


## Risks



*   Is it all worth it? Are we wasting so much space on these dictionaries that we might as well just stencil the code?

    At the very least, the dictionaries won’t take up code space. We’re in effect trading data cache misses for instruction cache misses (and associated instruction cache things, like branch predictor entries).

*   How much slower would this dictionary implementation be, than just stenciling everything? This design is pretty careful to produce no more allocations than a fully stenciled implementation, but there are a lot of other costs to operating in a generic fashion which are harder to measure. For example, if the concrete type is an `int`, a fully stenciled implementation can do `x = y` with a single load and store (or even just a register-register copy), whereas the dictionary implementation must call `memmove`.
