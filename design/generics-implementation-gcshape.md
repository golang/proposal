# Generics implementation - GC Shape Stenciling

This document describes a method to implement the [Go generics proposal](https://go.googlesource.com/proposal/+/refs/heads/master/design/go2draft-type-parameters.md) by stenciling the code for each different *GC shape* of the instantiated types, and using a *dictionary* to handle differing behaviors of types that have the same shape.

This proposal is middle ground between the [Generics Implementation - Stenciling](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-stenciling.md) and [Generics Implementation - Dictionaries](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-dictionaries.md) proposals.

The _GC shape_ of a type means how that type appears to the allocator / garbage collector.  It is determined by its size, its required alignment, and which parts of the type contain a pointer.


When we generate code for a generic function, we will generate a single chunk of assembly for each unique GC shape used by any instantiation. Each chunk of assembly will take as an argument a _dictionary_, which is a set of information describing the particular concrete types that the parameterized types take on. It includes the concrete types themselves, of course, but also derived information as we will see below.

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

The dictionary will contain a few additional fields beyond the instantiated types themselves, depending on what the implementation of f needs. Note that we must look inside the implementation of f to determine what is required. This means that the compiler will need to summarize what fields are necessary in the dictionary of the function, so that callers can compute that information and put it in the dictionary when it knows what the instantiated types are. (Note this implies that we can’t instantiate a generic function knowing only its signature - we need its implementation at compile time also. So implemented-in-assembly and cross-shared-object-boundary instantiations are not possible.)

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

For this proposal (unlike the pure dictionaries proposal), nothing special for stack layout is required. Because we are stenciling for each GC shape, the layout of the stack frame, including where all the pointers are, is determined. Stack frames are constant sized, argument and locals pointer maps are computable at compile time, outargs offsets are constant, etc.

## End of Dictionary


```
type dictionary struct {
    ...
    // That's it.
}
```


## The Proto-Dictionary

Callers of `f` require a bunch of information about `f` so that they can assemble an appropriate dictionary. We’ll call this information a proto-dictionary. Each entry in the proto-dictionary is conceptually a function from the concrete types used to instantiate the generic function, to the contents of the dictionary entry. At each callsite at compile time, the proto-dictionary is evaluated with the concrete type parameters to produce a real dictionary. (Or, if the callsite uses some generic types as type arguments, partially evaluate the proto-dictionary to produce a new proto-dictionary that represents some sub-dictionary of a higher-level dictionary.) There are two main features of the proto-dictionary. The first is that the functions described above must be computable at compile time. The second is that the proto-dictionary must be serializable, as we need to write it to an object file and read it back from an object file (for cases where the call to the generic function is in a different package than the generic function being called).

The proto-dictionary includes information for all the sections listed above:

*   Derived types. Each derived type is a “skeleton” type with slots to put some of `f`’s type parameters.
*   Any sub-proto-dictionaries for callsites in `f`. (Note: any callsites in `f` which use only concrete type parameters do not need to be in the dictionary of `f`, because they can be generated at that callsite. Only callsites in `f` which use one or more of `f`’s type parameters need to be a subdictionary of `f`’s dictionary.)
*   Helper methods, if needed, for all types+operations that need them.


## Closures

Suppose f creates a closure?


```
func f[T any](x interface{}, y T) {
    c := func() {
        x = y
    }
    c()
}
```

We need to pass a dictionary to the anonymous function as part of the closure, so it knows how to do things like assign a value of generic type to an `interface{}`. When building the dictionary for `f`, one of the subdictionaries needs to be the dictionary required for the anonymous function, which `f` can then use as part of constructing the closure.


## Generic Types

This document has so far just considered generic functions. But we also need to handle generic types. These should be straightforward to stencil just like we do for derived types within functions.


## Generating instantiations

We need to generate at least one instantiation of each generic function for each instantiation GC shape.


Note that the number of instantiations could be exponential in the number of type parameters. Hopefully there won't be too many type parameters for a single function.

For functions that have a type list constraining each one of their type parameters, we can generate all possible instantiations using the types in the type list. (Because type lists operate on underlying types, we couldn't do this with a fully stenciled implementation. But types with the same underlying type must have the same GC shape, so that's not a problem in this proposal.) This instantiation can happen at the point of declaration. (If there are too many elements in the type list, or too many in the cross product of all the type lists of all the type parameters, we could decide to use the callsite-instantiation scheme instead.)

Otherwise, instantiating at the point of declaration is not possible. We then instead instantiate at each callsite. This can lead to duplicated work, as the same instantiation may be generated at multiple call sites. Within a compilation unit, we can avoid recomputing the same instantiation more than once. Across compilation units, however, it is more difficult. For starters we might allow multiple instantiations to be generated and then deduped by the linker. A more aggressive scheme would allow the `go build` tool to record which instantiations have already been generated and pass that list to the compiler so it wouldn't have to do duplicate work. It can be tricky to make building deterministic under such a scheme (which is probably required to make the build cache work properly).

TODO: generating instantiations when some type parameters are themselves generic.

## Naming instantiations

To get easy linker deduplication, we should name instantiations using some encoding of their GC shape. We could add a size and alignment to a function name easily enough. Adding ptr/nonptr bits is a bit trickier because such an encoding could become large.


## Deduplication

Code for the instantiation of a specific generic function with a particular GC shape of its type parameters should be deduplicated by the linker. This deduplication will be done by name.

We should name dictionaries appropriately, so deduplication of dictionaries happens automatically. For instance, two different packages instantiating `f` using the same concrete types should use the same dictionary in the final binary. Deduplication should work fine using just names as is done currently in the compiler for, e.g., `runtime._type` structures.

Then the worst case space usage is one dictionary per instantiation. Note that some subdictionaries might be equivalent to a top-level dictionary for that same function.


## Other Issues

Recursion - can a dictionary ever reference itself? How do we build it, and the corresponding proto-dictionaries, then? I haven’t wrapped my head around the cases in which this could come up.

Dictionary layout. Because the dictionary is completely compile time and read only, it does not need to adhere to any particular structure. It’s just an array of bytes. The compiler assigns meanings to the fields as needed, including any ordering or packing. We would, of course, keep some sort of ordering just for our sanity.

We probably need a way for the runtime to get access to the dictionary itself, which could be done by always making it the first argument, and storing it in a known place. The runtime could use the dictionary to disambiguate the type parameters in stack tracebacks, for example.


## Risks

As this is a hybrid of the Stenciling and Dictionaries methods, it has a mix of benefits and drawbacks of both.

*   How much do we save in code size relative to fully stenciled? How much, if at all, are we still worse than the dictionary approach?

*   How much slower would the GC shape stenciling be, than just stenciling everything? The assembly code will in most cases be the same in the GC stenciled and fully stenciled implementations, as all the code for manipulating items of generic type are straightforward once we know the GC shape. The one exception is that method calls won't be fully resolvable at compile time.  That could be problematic is escape analysis - any methods called on the generic type will need to be analyzed conservatively which could lead to more heap allocation than a fully stenciled implementation. Similarly, inlining won't happen in situations where it could happen with a fully stenciled implementation.

## TODO

Register calling convention. In ABI0, argument passing is completely determined by GC shape. In the register convention, though, it isn't quite. For instance, `struct {x, y int}` and `[2]int` get allocated to registers differently. That makes figuring out where function inputs appear, and where callout arguments should go, dependent on the instantiated types. We could fix this by either including additional type info into the GC shape, or modifying the calling convention to handle arrays just like structs. I'm leaning towards the former. We might need to distinguish arrays anyway to ensure succinct names for the instantiations.
