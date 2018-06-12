# Proposal: Go should have generics

Author: [Ian Lance Taylor](iant@golang.org)

Created: January 2011

Last updated: April 2016

Discussion at https://golang.org/issue/15292

## Abstract

Go should support some form of generic programming.
Generic programming enables the representation of algorithms and data
structures in a generic form, with concrete elements of the code
(such as types) factored out.
It means the ability to express algorithms with minimal assumptions
about data structures, and vice-versa
(paraphrasing [Jazayeri, et al](https://www.dagstuhl.de/en/program/calendar/semhp/?semnr=98171)).

## Background

### Generic arguments in favor of generics

People can write code once, saving coding time.
People can fix a bug in one instance without having to remember to fix it
in others.
Generics avoid boilerplate: less coding by copying and editing.

Generics save time testing code: they increase the amount of code
that can be type checked at compile time rather than at run time.

Every statically typed language in current use has generics in one
form or another (even C has generics, where they are called preprocessor macros;
[example](https://gcc.gnu.org/viewcvs/gcc/trunk/gcc/vec.h?revision=165314&view=markup&pathrev=165314)).

### Existing support for generic programming in Go

Go already supports a form of generic programming via interfaces.
People can write an abstract algorithm that works with any type that
implements the interface.
However, interfaces are limited because the methods must use specific types.
There is no way to write an interface with a method that takes an
argument of type T, for any T, and returns a value of the same type.
There is no way to write an interface with a method that compares two
values of the same type T, for any T.
The assumptions that interfaces require about the types that satisfy
them are not minimal.

Interfaces are not simply types; they are also values.
There is no way to use interface types without using interface values,
and interface values aren’t always efficient.
There is no way to create a slice of the dynamic type of an interface.
That is, there is no way to avoid boxing.

### Specific arguments in favor of generics in Go

Generics permit type-safe polymorphic containers.
Go currently has a very limited set of such containers: slices, and
maps of most but not all types.
Not every program can be written using a slice or map.

Look at the functions `SortInts`, `SortFloats`, `SortStrings` in the
sort package.
Or `SearchInts`, `SearchFloats`, `SearchStrings`.
Or the `Len`, `Less`, and `Swap` methods of `byName` in package io/ioutil.
Pure boilerplate copying.

The `copy` and `append` functions exist because they make slices much
more useful.
Generics would mean that these functions are unnecessary.
Generics would make it possible to write similar functions for maps
and channels, not to mention user created data types.
Granted, slices are the most important composite data type, and that’s why
these functions were needed, but other data types are still useful.

It would be nice to be able to make a copy of a map.
Right now that function can only be written for a specific map type,
but, except for types, the same code works for any map type.
Similarly, it would be nice to be able to multiplex one channel onto
two, without having to rewrite the function for each channel type.
One can imagine a range of simple channel manipulators, but they can
not be written because the type of the channel must be specified
explicitly.

Generics let people express the relationship between function parameters
and results.
Consider the simple Transform function that calls a function on every
element of a slice, returning a new slice.
We want to write something like
```
func Transform(s []T, f func(T) U) []U
```
but this can not be expressed in current Go.

In many Go programs, people only have to write explicit types in function
signatures.
Without generics, they also have to write them in another place: in the
type assertion needed to convert from an interface type back to the
real type.
The lack of static type checking provided by generics makes the code
heavier.

### What we want from generics in Go

Any implementation of generics in Go should support the following.

* Define generic types based on types that are not known until they are instantiated.
* Write algorithms to operate on values of these types.
* Name generic types and name specific instantiations of generic types.
* Use types derived from generic types, as in making a slice of a generic type,
  or conversely, given a generic type known to be a slice, defining a variable
  with the slice’s element type.
* Restrict the set of types that may be used to instantiate a generic type, to
  ensure that the generic type is only instantiated with types that support the
  required operations.
* Do not require an explicit relationship between the definition of a generic
  type or function and its use.  That is, programs should not have to
  explicitly say *type T implements generic G*.
* Write interfaces that describe explicit relationships between generic types,
  as in a method that takes two parameters that must both be the same unknown type.
* Do not require explicit instantiation of generic types or functions; they
  should be instantiated as needed.

### The downsides of generics

Generics affect the whole language.
It is necessary to evaluate every single language construct to see how
it will work with generics.

Generics affect the whole standard library.
It is desirable to have the standard library make effective use of generics.
Every existing package should be reconsidered to see whether it would benefit
from using generics.

It becomes tempting to build generics into the standard library at a
very low level, as in C++ `std::basic_string<char, std::char_traits<char>, std::allocator<char> >`.
This has its benefits&mdash;otherwise nobody would do it&mdash;but it has
wide-ranging and sometimes surprising effects, as in incomprehensible
C++ error messages.

As [Russ pointed out](https://research.swtch.com/generic), generics are
a trade off between programmer time, compilation time, and execution
time.

Go is currently optimizing compilation time and execution time at the
expense of programmer time.
Compilation time is a significant benefit of Go.
Can we retain compilation time benefits without sacrificing too much
execution time?

Unless we choose to optimize execution time, operations that appear
cheap may be more expensive if they use values of generic type.
This may be subtly confusing for programmers.
I think this is less important for Go than for some other languages,
as some operations in Go already have hidden costs such as array
bounds checks.
Still, it would be essential to ensure that the extra cost of using
values of generic type is tightly bounded.

Go has a lightweight type system.
Adding generic types inevitably makes the type system more complex.
It is essential that the result remain lightweight.

The upsides of the downsides are that Go is a relatively small
language, and it really is possible to consider every aspect of the
language when adding generics.
At least the following sections of the spec would need to be extended:
Types, Type Identity, Assignability, Type assertions, Calls, Type
switches, For statements with range clauses.

Only a relatively small number of packages will need to be
reconsidered in light of generics: container/*, sort, flag, perhaps
bytes.
Packages that currently work in terms of interfaces will generally be
able to continue doing so.

### Conclusion

Generics will make the language safer, more efficient to use, and more
powerful.
These advantages are harder to quantify than the disadvantages, but
they are real.

## Examples of potential uses of generics in Go

* Containers
  * User-written hash tables that are compile-time type-safe, rather than
    converting slice keys to string and using maps
  * Sorted maps (red-black tree or similar)
  * Double-ended queues, circular buffers
  * A simpler Heap
  * `Keys(map[K]V) []K`, `Values(map[K]V) []V`
  * Caches
  * Compile-time type-safe `sync.Pool`
* Generic algorithms that work with these containers in a type-safe way.
  * Union/Intersection
  * Sort, StableSort, Find
  * Copy (a generic container, and also copy a map)
  * Transform a container by applying a function--LISP `mapcar` and friends
* math and math/cmplx
* testing/quick.{`Check`,`CheckEqual`}
* Mixins
  * like `ioutil.NopCloser`, but preserving other methods instead of
    restricting to the passed-in interface (see the `ReadFoo` variants of
    `bytes.Buffer`)
* protobuf `proto.Clone`
* Eliminate boilerplate when calling sort function
* Generic diff: `func [T] Diff(x, y []T) []range`
* Channel operations
  * Merge N channels onto one
  * Multiplex one channel onto N
  * The [worker-pool pattern](https://play.golang.org/p/b5XRHnxzZF)
* Graph algorithms, for example immediate dominator computation
* Multi-dimensional arrays (not slices) of different lengths
* Many of the packages in go.text could benefit from it to avoid duplicate
  implementation or APIs for `string` and `[]byte` variants; many points that
  could benefit need high performance, though, and generics should provide that
  benefit

## Proposal

I won’t discuss a specific implementation proposal here: my hope is
that this document helps show people that generics are worth having
provided the downsides can be kept under control.

The following documents are my previous generics proposals,
presented for historic reference. All are flawed in various ways.

* [Type functions](15292/2010-06-type-functions.md) (June 2010)
* [Generalized types](15292/2011-03-gen.md) (March 2011)
* [Generalized types](15292/2013-10-gen.md) (October 2013)
* [Type parameters](15292/2013-12-type-params.md) (December 2013)
