# Generics implementation - Stenciling

This document describes a method to implement the [Go generics proposal](https://go.googlesource.com/proposal/+/refs/heads/master/design/go2draft-type-parameters.md). This method generates multiple implementations of a generic function by instantiating the body of that generic function for each set of types with which it is instantiated. By “implementation” here, I mean a blob of assembly code and associated descriptors (pcln tables, etc.). This proposal stands in opposition to the [Generics Implementation - Dictionaries](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-dictionaries.md) proposal, where we generate a single implementation of a generic function that handles all possible instantiated types. The [Generics Implementation - GC Shape Stenciling](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-gcshape.md) proposal is a hybrid of that proposal and this one.

Suppose we have the following generic function


```
func f[T1, T2 any](x int, y T1) T2 {
    ...
}
```


And we have two call sites of `f`


```
var a float64 = f[int, float64](7, 8.0)
var b struct{f int} = f[complex128, struct{f int}](3, 1+1i)
```


Then we generate two versions of `f`, compiling each one into its own implementation:


```
func f1(x int, y int) float64 {
    ... identical bodies ...
}
func f2(x int, y complex128) struct{f int} {
    ... identical bodies ...
}
```


This design doc walks through the details of how this compilation strategy would work.


## Naming

The binary will now have potentially multiple instances of a function in it. How will those functions be named? In the example above, just calling them `f1` and `f2` won’t work.

At least for the linker, we need names that will unambiguously indicate which implementation we’re talking about. This doc proposes to decorate the function name with each type parameter name, in brackets:


```
f[int, float64]
f[complex, struct{f int}]
```


The exact syntax doesn’t really matter, but it must be unambiguous. The type names will be formatted using cmd/compile/internal/types/Type.ShortString (as is used elsewhere, e.g. for type descriptors).

Should we show these names to users? For panic tracebacks, it is probably ok, since knowing the type parameters could be useful (as are regular parameters, which we also show). But what about CPU profiles? Should we unify profiles of differently-instantiated versions of the same function? Or keep them separate?


## Instantiation

Because we don’t know what types `f` will be instantiated with when we compile `f` itself (but see the section on type lists below), we can’t generate the implementations at the definition of `f`. We must generate the implementations at the callsites of `f`.

At each callsite of `f` where type parameters are provided, we must generate a new implementation of `f`. To generate an implementation, the compiler must have access to the body of `f`. To facilitate that, the object file must contain the body of any generic functions, so that the compiler can compile them again, with possibly different type parameters, during compilation of the calling package (this mechanism already exists for inlining, so there is maybe not much work to do here).

 \
It isn’t obvious at some callsites what the concrete type parameters are. For instance, consider `g`:


```
func [T any] g(x T) float64 {
    return f[T, float64](5, x)
}
```


The callsite of `f` in `g` doesn’t know what all of its type parameters to `f` are. We won’t be able to generate an implementation of `f` until the point where `g` is instantiated. So implementing a function at a callsite might require recursively implementing callees at callsites in its body. (TODO: where would the caller of `g` get the body of `f` from? Is that also in the object file somewhere?)

How do we generate implementations in cases of general recursion?


```
func r1[X, Y, Z any]() {
    r2[X, Y, Z]()
}
func r2[X, Y, Z any]() {
    r1[Y, Z, X]()
}
r1[int8, int16, int32]()
```


What implementations does this generate? I think the answer is clear, but we need to make sure our build system comes up with that answer without hanging the compiler in an infinite recursion. We’d need to record the existence of an instantiation (which we probably want to do anyway, to avoid generating `f[int, float64]` twice in one compilation unit) before generating code for that instantiation.


## Type lists

If a generic function has a type parameter that has a type constraint which contains a type list, then we could implement that function at its definition, with each element of that type list. Then we wouldn’t have to generate an implementation at each call site. This strategy is fragile, though. Type lists are understood as listing underlying types (under the generics proposal as of this writing), so the set of possible instantiating types is still infinite. But maybe we generate an instantiation for each unnamed type (and see the deduplication section for when it could be reused for a named type with the same underlying type).


## Deduplication

The compiler will be responsible for generating only one implementation for a given particular instantiation (function + concrete types used for instantiation). For instance, if you do:


```
f[int, float64](3, 5)
f[int, float64](4, 6)
```


If both of these calls are in the same package, the compiler can detect the duplication and generate the implementation `f[int, float64]` only once.

If the two calls to `f` are in different packages, though, then things aren’t so simple. The two compiler invocations will not know about each other. The linker will be responsible for deduplicating implementations resulting from instantiating the same function multiple times. In the example above, the linker will end up seeing two `f[int, float64]` symbols, each one generated by a different compiler invocation. The functions will be marked as DUPOK so the linker will be able to throw one of them away. (Note: due to the relaxed semantics of Go’s function equality, the deduplication is not required; it is just an optimization.)

Note that the build system already deals with deduplicating code. For example, the generated equality and hash functions are deduplicated for similar reasons.


## Risks

There are two main risks with this implementation, which are related.



1. This strategy requires more compile time, as we end up compiling the same instantiation multiple times in multiple packages.
2. This strategy requires more code space, as there will be one copy of `f` for each distinct set of type parameters it is instantiated with. This can lead to large binaries and possibly poor performance (icache misses, branch mispredictions, etc.).

For the first point, there are some possible mitigations. We could enlist the go tool to keep track of the implementations that a particular compiler run generated (recorded in the export data somewhere), and pass the name of those implementations along to subsequent compiler invocations. Those subsequent invocations could avoid generating that same implementation again. This mitigation wouldn’t work for compilations that were started in parallel from the go tool, however. Another option is to have the compiler report back to the go tool the implementations it needs. The go tool can then deduplicate that list and invoke the compiler again to actually generate code for that deduped list. This mitigation would add complexity, and possibly compile time, because we’d end up calling the compiler multiple times for each package. In any case, we can’t reduce the number of compilations beyond that needed for each unique instantiation, which still might be a lot. Which leads to point 2...

For the second point, we could try to deduplicate implementations which have different instantiated types, but different in ways that don’t matter to the generated code. For instance, if we have


```
type myInt int
f[int, bool](3, 4)
f[myInt, bool](5, 6)
```


Do we really need multiple implementations of `f`? It might be required, if for example `f` assigns its second argument to an `interface{}`-typed variable. But maybe `f` only depends on the underlying type of its second argument (adds values of that type together and then compares them, say), in which case the implementations could share code.

I suspect there will be lots of cases where sharing is possible, if the underlying types are indistinguishable w.r.t. the garbage collector (same size and ptr/nonptr layout). We’d need to detect the tricky cases somehow, maybe using summary information about what properties of each generic parameter a function uses (including things it calls with those same parameters, which makes it tricky when recursion is involved).

If we deduplicate in this fashion, it complicates naming. How do we name the two implementations of `f` shown above? (They would be named `f[int, bool]` and `f[myInt, bool]` by default.) Which do we pick? Or do we name it `f[underlying[int], bool]`? Or can we give one implementation multiple names? Which name do we show in backtraces, debuggers, profilers?

Another option here is to have the linker do content-based deduplication. Only if the assembly code of two functions is identical, will the implementations be merged. (In fact, this might be a desirable feature independent of generics.) This strategy nicely sidesteps the problem of how to decide whether two implementations can share the same code - we compile both and see. (Comparing assembly for identical behavior is nontrivial, as we would need to recursively compare any symbols referenced by relocations, but the linker already has some ability to do this.)

Idea: can we generate a content hash for each implementation, so the linker can dedup implementations without even loading the implementation into memory?

