# Proposal: Generic parameterization of array sizes

Author(s): Andrew Werner

Last updated: March 16th, 2021

## Abstract

With the type parameters generics proposal has been accepted, though not yet
fully specified or implemented, we can begin to talk about extension. [That
proposal][type parameters] lists the following omission:

> No parameterization on non-type values such as constants. This arises most
obviously for arrays, where it might sometimes be convenient to write type
`Matrix[n int] [n][n]float64`. It might also sometimes be useful to specify
significant values for a container type, such as a default value for elements.

This proposal seeks to resolve this limitation by (a) specifying when `len` can
be used as a compile-time constant and (b) adding syntax to specify constraints
for all arrays of a given type in type lists.

## Background

An important property of the generics proposal is that it enables the creation
of libraries of specialized container data structures. The existence of such
libraries will help developers write more efficient code as these data
structures will be able to allocate fewer object and provide greater access
locality. [This Google blog post][block based data structures] about block-based
C++ data drives home the point.

The justification is laid out in the omission of the type parameter proposal.
The motivation that I've stumbled upon is in trying to implement a B-Tree
and allowing the client to dictate the degree of the node.

One initial idea would be to allow the client to provide the actual array
which will be backing the data inside the node as a type parameter. This might
actually be okay in some data structure user cases but in a B-Tree it's bad
because we still would like to instantiate an array for the pointers and that
array needs to have a size that is a function of the data array.

The proposal here seeks to make it possible for clients to provide default
values for array sizes of generic data structures in a way that is minimally
invasive to the concepts which go already has. The shorthand comment stated
in the Omission of the Type Parameter Proposal waves its hand at what feels
like a number of new and complex concepts for the language.

## Proposal

This proposals attempts to side-step questions of how one might provide a
scalar value in a type constraint by not ever providing a scalar directly.
This proposal recognizes that constants can be used to specify array lengths.
It also notes that the value of `len()` can be computed as a compile-time
constant in some cases. Lastly, it observes that type lists could be extended
minimally to indicate a constraint that a type is an array of a given type
without constraining the length of the array.

### The vanilla generic B-Tree

Let's explore the example of a generic B-Tree with a fixed-size buffer. Find
such an example [here][vanilla btree].

```go
// These constants are the wart.
const (
	degree   = 16
	maxItems = 2*degree - 1
	minItems = degree - 1
)

func NewBTree[K, V any](cmp LessFn[K]) OrderedMap[K, V] {
	return &btree[K, V]{cmp: cmp}
}

type btree[K, V any] struct {
	cmp  LessFn[K]
	root *node[K, V]
}

// ...

type node[K, V any] struct {
	count    int16
	leaf     bool
	keys     [maxItems]K
	vals     [maxItems]V
	children [maxItems + 1]*node[K, V]
}
```

### Parameterized nodes

Then we allow parameterization on the node type within the btree implementation
so that different node concrete types with different memory layouts may be
used. Find an example of this generalization
[here][parameterized node btree].

```go
type nodeI[K, V, N any] interface {
	type *N
	find(K, LessFn[K]) (idx int, found bool)
	insert(K, V, LessFn[K]) (replaced bool)
	remove(K, LessFn[K]) (K, V, bool)
	len() int16
	at(idx int16) (K, V)
	child(idx int16) *N
	isLeaf() bool
}

func NewBTree[K, V any](cmp LessFn[K]) OrderedMap[K, V] {
	type N = node[K, V]
	return &btree[K, V, N, *N]{
		cmp: cmp,
		newNode: func(isLeaf bool) *N {
			return &N{leaf: isLeaf}
		},
	}
}

type btree[K, V, N any, NP nodeI[K, V, N]] struct {
	len     int
	cmp     LessFn[K]
	root    NP
	newNode func(isLeaf bool) NP
}

type node[K, V any] struct {
	count    int16
	leaf     bool
	keys     [maxItems]K
	vals     [maxItems]V
	children [maxItems + 1]*node[K, V]
}
```

This still ends up using constants and there's no really easy
way around that. You might want to parameterize the arrays into the node like
in [this example][bad parameterization btree]. This still
doesn't tell a story about how to relate the children array to the items.

### The proposal to parameterize the arrays

Instead, we'd like to find a way to express the idea that there's a size
constant which can be used in the type definitions. The proposal would
result in an implementation that looked like
[this][proposal btree].

```go

// StructArr is a constraint that says that a type is an array of empty
// structs of any length.
type StructArr interface {
	type [...]struct{}
}

type btree[K, V, N any, NP nodeI[K, V, N]] struct {
	len     int
	cmp     LessFn[K]
	root    NP
	newNode func(isLeaf bool) NP
}

// NewBTree constructs a generic BTree-backed map with degree 16.
func NewBTree[K, V any](cmp LessFn[K]) OrderedMap[K, V] {
	const defaultDegree = 16
	return NewBTreeWithDegree[K, V, [defaultDegree]struct{}](cmp)
}

// NewBTreeWithDegree constructs a generic BTree-backed map with degree equal
// to the length of the array used as type parameter A.
func NewBTreeWithDegree[K, V any, A StructArr](cmp LessFn[K]) OrderedMap[K, V] {
	type N = node[K, V, A]
	return &btree[K, V, N, *N]{
		cmp: cmp,
		newNode: func(isLeaf bool) *N {
			return &N{leaf: isLeaf}
		},
	}
}

type node[K, V any, A StructArr] struct {
	count    int16
	leaf     bool
	keys     [2*len(A) - 1]K
	values   [2*len(A) - 1]V
	children [2 * len(A)]*node[K, V, A]
}
```
### The Matrix example

The example of the omission in type parameter proposal could be achieved in
the following way:

```go
type Dim interface {
    type [...]struct{}
}

type SquareFloatMatrix2D[D Dim] [len(D)][len(D)]float64
```

### Summary

1) Support type list constraints to express that a type is an array


```go
// Array expresses a constraint that a type is an array of T of any
// size.
type Array[T any] interface {
    type [...]T
}
```

2)  Support a compile-time constant expression for `len([...]T)`

This handy syntax would permit parameterization of arrays relative to other
array types. Note that the constant expression `len` function on array types
could actually be implemented today using `unsafe.Sizeof` by a parameterization
over an array whose members have non-zero size. For example `len` could be
written as `unsafe.Sizeof([...]T)/unsafe.Sizeof(T)` so long as
`unsafe.Sizeof(T) > 0`.

## Rationale

This approach is simpler than generally providing a constant scalar expression
parameterization of generic types. Of the two elements of the proposal, neither
feels particularly out of line with the design of the language or its concepts.
The `[...]T` syntax exists in the language to imply length inference for array
literals and is not a hard to imagine concept. It is the deeper requirement to
make this proposal work.

One potential downside of this proposal is that we're not really using the
array for anything other than its size which may feel awkward. For that reason
I've opted to use a constraint which forces the array to use `struct{}` values
to indicate that the structure of the elements isn't relevant. This awkwardness
feels justified to side-step introduces scalars to type parameters.

## Compatibility

This proposal is fully backwards compatible with all of the language and also
the now accepted type parameters proposal.

## Implementation

Neither of the two features of this proposal feel particularly onerous to
implement. My guess is that the `[...]T` type list constraint would be extremely
straightforward given an implementation of type parameters. The `len`
implementation is also likely to be straightforward given the existence of
both compile-time evaluation of `len` expressions on array types which exist
in the language and the constant nature of `unsafe.Sizeof`. Maybe there'd be
some pain in deferring the expression evaluation until after type checking.

[type parameters]: https://go.googlesource.com/proposal/+/refs/heads/master/design/go2draft-type-parameters.md
[block based data structures]: https://opensource.googleblog.com/2013/01/c-containers-that-save-memory-and-time.html
[vanilla btree]: https://go2goplay.golang.org/p/A5auAIdW2ZR
[parameterized node btree]: https://go2goplay.golang.org/p/TFn9BujIlc3
[bad parameterization btree]: https://go2goplay.golang.org/p/JGgyabtu_9F
[proposal btree]: https://go2goplay.golang.org/p/4o36RLxF73C