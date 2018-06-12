# Type Parameters in Go

This is a proposal for adding generics to Go, written by Ian Lance
Taylor in December, 2013.
This proposal will not be adopted.
It is being presented as an example for what a complete generics
proposal must cover.

## Introduction

This document describes a possible implementation of type parameters
in Go.
We permit top-level types and functions to use type parameters: types
that are not known at compile time.
Types and functions that use parameters are called parameterized, as
in "a parameterized function."

Some goals, borrowed from [Garcia et al](https://web.archive.org/web/20170812055356/http://www.crest.iu.edu/publications/prints/2003/comparing_generic_programming03.pdf):

* Do not require an explicit relationship between a definition of a parameterized function and its use. The function should be callable with any suitable type.
* Permit interfaces to express relationships between types of methods, as in a comparison method that takes two values of the same parameterized type.
* Given a type parameter, make it possible to use related types, such as a slice of that type.
* Do not require explicit instantiation of parameterized functions.
* Permit type aliasing of parameterized types.

## Background

My earlier proposal for generalized types had some flaws.

This document is similar to my October 2013 proposal, but with a
different terminology and syntax, and many more details on
implementation.

People expect parameterized functions to be fast.
They do not want a reflection based implementation in all cases.
The question is how to support that without excessively slowing down
the compiler.

People want to be able to write simple parameterized functions like
`Sum(v []T) T`, a function that returns the sum of the values in the
slice `v`.
They are prepared to assume that `T` is a numeric type.
They don’t want to have to write a set of methods simply to implement
Sum or the many other similar functions for every numeric type,
including their own named numeric types.

People want to be able to write the same function to work on both
`[]byte` and `string`, without requiring the bytes to be copied to a
new buffer.

People want to parameterize functions on types that support simple
operations like comparisons.
That is, they want to write a function that uses a type parameter and
compares a value of that type to another value of the same type.
That was awkward in my earlier proposal: it required using a form of
the curiously recurring template pattern.

Go’s use of structural typing means that a program can use any type to
meet an interface without an explicit declaration.
Type parameters should work similarly.

## Proposal

We permit package-level type and func declarations to use type
parameters.
There are no restrictions on how these parameters may be used within
their scope.
At compile time each actual use of a parameterized type or function is
instantiated by replacing each type parameter with an ordinary type,
called a type argument.
A type or function may be instantiated multiple times with different
type arguments.
A particular type argument is only permitted if all the operations
used with the corresponding type parameter are permitted for the type
argument.
How to implement this efficiently is discussed below.

## Syntax

Any package-scope type or func may be followed by one or more type
parameter names in square brackets.

```
type [T] List struct { element T; next *List[T] }
```

This defines `T` as a type parameter for the parameterized type `List`.

Every use of a parameterized type must provide specific type arguments
to use for the type parameters.
This is done using square brackets following the type name.
In `List`, the `next` field is a pointer to a `List` instantiated with
the same type parameter `T`.

Examples in this document typically use names like `T` and `T1` for
type parameters, but the names can be any identifier.
The scope of the type parameter name is only the body of the type or
func declaration.
Type parameter names are not exported.
It is valid, but normally useless, to write a parameterized type or
function that does not actually use the type parameter;
the effect is that every instantiation is the same.

Some more syntax examples:

```
type ListInt List[int]
var v1 List[int]
var v2 List[float]
type (
[T1, T2] MyMap map[T1]T2
[T3] MyChan chan T3
)
var v3 MyMap[int, string]
```

Using a type parameter with a function is similar.

```
func [T] Push(l *List[T], e T) *List[T] {
	return &List[T]{e, l}
}
```

As with parameterized types, we must specify the type arguments when
we refer to a parameterized function (but see the section on type
deduction, below).

```
var PushInt = Push[int] // Type is func(*List[int], int) *List[int]
```

A parameterized type can have methods.

```
func [T] (v *List[T]) Push(e T) {
	*v = &List[T]{e, v}
}
```

A method of a parameterized type must use the same number of type
parameters as the type itself.
When a parameterized type is instantiated, all of its methods are
automatically instantiated too, with the same type arguments.

We do not permit a parameterized method for a non-parameterized type.
We do not permit a parameterized method to a non-parameterized
interface type.

### A note on syntax

The use of square brackets to mark type parameters and the type
arguments to use in instantiations is new to Go.
We considered a number of different approaches:

* Use angle brackets, as in `Vector<int>`. This has the advantage of being familiar to C++ and Java programmers. Unfortunately, it means that `f<T>(true)` can be parsed as either a call to function `f<T>` or a comparison of `f<T` (an expression that tests whether `f` is less than `T`) with `(true)`. While it may be possible to construct complex resolution rules, the Go syntax avoids that sort of ambiguity for good reason.
* Overload the dot operator again, as in `Vector.int` or `Map.(int, string)`. This becomes confusing when we see `Vector.(int)`, which could be a type assertion.
* We considered using dot but putting the type first, as in `int.Vector` or `(int, string).Map`. It might be possible to make that work without ambiguity, but putting the types first seems to make the code harder to read.
* An earlier version of this proposal used parentheses for names after types, as in `Vector(int)`. However, that proposal was flawed because there was no way to specify types for parameterized functions, and extending the parentheses syntax led to `MakePair(int, string)(1, "")` which seems less than ideal.
* We considered various different characters, such as backslash, dollar sign, at-sign or sharp.  The square brackets grouped the parameters nicely and provide an acceptable visual appearance.
* We considered a new keyword, `gen`, with parenthetical grouping of parameterized types and functions within the scope of a single `gen`. The grouping seemed un-Go-like and made indentation confusing. The current syntax is a bit more repetitive for methods of parameterized types, but is easier to understand.

## Semantics

There are no restrictions on how parameterized types may be used in a
parameterized function.
However, the function can only be instantiated with type arguments
that support the uses.
In some cases the compiler will give an error for a parameterized
function that can not be instantiated by any type argument, as
described below.

Consider this example, which provides the boilerplate for sorting any
slice type with a `Less` method.

```
type [T] SortableSlice []T
func [T] (v SortableSlice[T]) Len() int { return len(v) }
func [T] (v SortableSlice[T]) Swap(i, j int) {
	v[i], v[j] = v[j], v[i]
}
func [T] (v SortableSlice[T]) Less(i, j int) bool {
	return v[i].Less(v[j])
}
func [T] (v SortableSlice[T]) Sort() {
	sort.Sort(v)
}
```

We don’t have to declare anywhere that the type parameter `T` has a
method `Less`.
However, the call of the `Less` method tells the compiler that the type
argument to `SortableSlice` must have a `Less` method.
This means that trying to use `SortableSlice[int]` would be a
compile-time error, since `int` does not have a `Less` method.

We can sort types that implement the `<` operator, like `int`, with a
different vector type:

```
type [T] PSortableSlice []T
func [T] (v PSortableSlice[T]) Len() int { return len(v) }
func [T] (v PSortableSlice[T]) Swap(i, j int) {
	v[i], v[j] = v[j], v[i]
}
func [T] (v PSortableSlice[T]) Less(i, j int) bool {
	return v[i] < v[j]
}
func [T] (v PSortableSlice[T]) Sort() {
	sort.Sort(v)
}
```

The `PSortableSlice` type may only be instantiated with types that can
be used with the `<` operator: numeric or string types.  It may not be
instantiated with a struct type, even if the struct type has a `Less`
method.

Can we merge SortableSlice and PSortableSlice to have the best of both
worlds?
Not quite;
there is no way to write a parameterized function that supports either
a type with a `Less` method or a builtin type.
The problem is that `SortableSlice.Less` can not be instantiated for a
type without a `Less` method, and there is no way to only instantiate a
method for some types but not others.

(Technical aside: it may seem that we could merge `SortableSlice` and
`PSortableSlice` by having some mechanism to only instantiate a method
for some type arguments but not others.
However, the result would be to sacrifice compile-time type safety, as
using the wrong type would lead to a runtime panic.
In Go one can already use interface types and methods and type
assertions to select behavior at runtime.
There is no need to provide another way to do this using type
parameters.)

All that said, one can at least write this:

```
type [T] Lessable T
func [T] (a Lessable[T]) Less(b T) bool {
	return a < b
}
```

Now one can use `SortableSlice` with a slice v of some builtin type by
writing

```
	SortableSlice([]Lessable(v))
```

Note that although `Lessable` looks sort of like an interface, it is
really a parameterized type.
It may be instantiated by any type for which `Lessable.Less` can be
compiled.
In other words, one can write `[]Lessable(v)` for a slice of any type
that supports the `<` operator.

As mentioned above parameterized types can be used just like any other
type.
In fact, there is a minor enhancement.
Ordinarily type assertions and type switches are only permitted for
interface types.
When writing a parameterized function, type assertions and type
switches are permitted for type parameters.
This is true even if the function is instantiated with a type argument
that is not an interface type.
Also, a type switch is permitted to have multiple parameterized type
cases even if some of them are the same type after instantiation.
The first matching case is used.

### Cycles

The instantiation of a parameterized function may not require the
instantiation of the same parameterized function with different type
parameters.
This means that a parameterized function may call itself recursively
with the same type parameters, but it may not call itself recursively
with different type parameters.
This rule applies to both direct and indirect recursion.

For example, the following is invalid.
If it were valid, it would require the construction of a type at
runtime.

```
type [T] S struct { f T }
func [T] L(n int, e T) interface{} {
	if n == 0 {
		return e
	}
	return L(n-1, S[T]{e})
}
```

## Type Deduction

When calling a parameterized function, as opposed to referring to it
without calling it, the specific types to use may be omitted in some
cases.
A function call may omit the type arguments when every type parameter
is used for a regular parameter, or, in other words, there are no type
parameters that are used only for results.
When a call is made to a parameterized function without specifying the
type arguments, the compiler will walk through the arguments from left
to right, comparing the actual type of the argument `A` with the type
of the parameter `P`.
If `P` contains type parameters, then `A` and `P` must be identical.
The first time we see a type parameter in `P`, it will be set to the
appropriate portion of `A`.
If the type parameter appears again, it must be identical to the
actual type at that point.

Note that at compile time the type argument may itself be a
parameterized type, when one parameterized function calls another.
The type deduction algorithm is the same.
A type parameter of `P` may match a type parameter of `A`.
Once this match is made, then every subsequent instance of the `P` type
parameter must match the same `A` type parameter.

When doing type deduction with an argument that is an untyped
constant, the constant does not determine anything about the type
argument.
The deduction proceeds with the remaining function arguments.
If at the end of the deduction the type argument has not been
determined, the constants that correspond to unknown type arguments
are re-examined and given the type `int`, `rune`, `float64`, or
`complex128` as usual.
Type deduction does not support passing an untyped `nil` constant;
`nil` may only be used with an explicit type conversion (or, of
course, the type arguments may be written explicitly).

When passing a parameterized function `F1` to a non-parameterized
function `F2`, type deduction runs the other way around: the type of the
corresponding argument of `F2` is used to deduce the type of `F1`.

When passing a parameterized function `F1` to a parameterized function
`F2`, the type of `F1` is compared to the type of the corresponding
argument of `F2`.
This may yield specific types for `F1` and/or `F2` type parameters,
for which the compiler proceeds as usual.
If any of the type arguments of `F1` are not determined, type
deduction proceeds with the remaining arguments.
At the end of the deduction, the compiler reconsiders `F1` with the
final set of types.
At that point it is an error if all the type parameters of `F1` are
not determined.
This is not an iterative algorithm;
the compiler only reconsiders `F1` once, it does not build a stack of
retries if multiple parameterized functions are passed.

Type deduction also applies to composite literals, in which the type
arguments for a parameterized composite type are deduced from the
types of the literals.

Type deduction also applies to type conversions to a parameterized
type.
The type arguments for the type are deduced from the type of the
expression being converted.

Examples:

```
func [T] Sum(a, b T) T { return a + b }
var v1 = Sum[int](0, 0)
var v2 = Sum(0, 0)			// [int] deduced
type [T] Cons struct { car, cdr T }
var v3 = Cons{0, 0}			// [int] deduced
type [T] Opaque T
func [T] (a Opaque[T]) String() string {
	return "opaque"
}
var v4 = []Opaque([]int{1})	// Opaque[int] deduced

var i int
var m1 = Sum(i, 0)		// i causes T to be deduced as int, 0 is
				// passed as int.
var m2 = Sum(0, i)		// 0 ignored on first pass, i causes T
				// to be deduced as int, 0 passed as int.
var m3 = Sum(1, 2.5)		// 1 and 2.5 ignored on first pass. On
				// second pass 1 causes T to be deduced as
				// int. Passing 2.5 is an error.
var m4 = Sum(2.5, 1)		// 2.5 and 1 ignored on first pass. On
				// second pass 2.5 causes T to be deduced
				// as float64. 1 converted to float64.

func [T1, T2] Transform(s []T1, f func(T1) T2) []T2
var s1 = []int{0, 1, 2}
	// Below, []int matches []T1 deducing T1 as int.
	// strconv.Itoa matches T1 as int as required,
	// T2 deduced as string. Type of s2 is []string.
var s2 = Transform(s1, strconv.Itoa)

func [T1, T2] Apply(f func(T1) T2, v T1) T2 { return f(v) }
func [T] Ident(v T) T { return v }
	// Below, Ident matches func(T1) T2, but neither T1 nor T2
	// are known. The compiler continues. Next i, type int,
	// matches T1, so T1 is int. The compiler returns to Ident.
	// T matches T1, which is int, so T is int. Then T matches
	// T2, so T2 is int. All type arguments are deduced.
func F(i int) int { return Apply(Ident, i) }
```

Note that type deduction requires types to be identical.
This is stronger than the usual requirement when calling a function,
namely that the types are assignable.

```
func [T] Find(s []T, e T) bool
type E interface{}
var f1 = 0
	// Below does not compile.  The first argument means that T is
	// deduced as E. f1 is type int, not E. f1 is assignable to
	// E, but not identical to it.
var f2 = Find([]E{f1}, f1)
	// Below does compile. Explicit type specification for Find
	// means that type deduction is not performed.
var f3 = Find[E]([]E{f1}, f1)
```

Requiring identity rather than assignability is to avoid any possible
confusion about the deduced type.
If different types are required when calling a function it is always
possible to specify the types explicitly using the square bracket
notation.

## Examples

A hash table.

```
package hashmap

type [K, V] bucket struct {
	next *bucket
	key K
	val V
}

type [K] Hashfn func(K) uint
type [K] Eqfn func(K, K) bool

type [K, V] Hashmap struct {
	hashfn Hashfn[K]
	eqfn Eqfn[K]
	buckets []bucket[K, V]
	entries int
}

// This function must be called with explicit type arguments, as
// there is no way to deduce the value type.  For example,
// h := hashmap.New[int, string](hashfn, eqfn)
func [K, V] New(hashfn Hashfn[K], eqfn Eqfn[K]) *Hashmap[K, V] {
	// Type parameters of Hashmap deduced as [K, V].
	return &Hashmap{hashfn, eqfn, make([]bucket[K, V], 16), 0}
}

func [K, V] (p *Hashmap[K, V]) Lookup(key K) (val V, found bool) {
	h := p.hashfn(key) % len(p.buckets)
	for b := p.buckets[h]; b != nil; b = b.next {
		if p.eqfn(key, b.key) {
			return b.val, true
		}
	}
	return
}

func [K, V] (p *Hashmap[K, V]) Insert(key K, val V) (inserted bool) {
	// Implementation omitted.
}
```

Using the hash table.

```
package sample

import (
	"fmt"
	"hashmap"
	"os"
)

func hashint(i int) uint {
	return uint(i)
}

func eqint(i, j int) bool {
	return i == j
}

var v = hashmap.New[int, string](hashint, eqint)

func Add(id int, name string) {
	if !v.Insert(id, name) {
		fmt.Println(“duplicate id”, id)
		os.Exit(1)
	}
}

func Find(id int) string {
	val, found := v.Lookup(id)
	if !found {
		fmt.Println(“missing id”, id)
		os.Exit(1)
	}
	return val
}
```

Sorting a slice given a comparison function.

```
func [T] SortSlice(s []T, less func(T, T) bool) {
	sort.Sort(&sorter{s, less})
}

type [T] sorter struct {
	s []T
	less func(T, T) bool
}

func [T] (s *sorter[T]) Len() int { return len(s.s) }
func [T] (s *sorter[T]) Less(i, j int) bool {
	return s.less(s[i], s[j])
}
func [T] (s *sorter[T]) Swap(i, j int) {
	s.s[i], s.s[j] = s.s[j], s.s[i]
}
```

Sorting a numeric slice (also works for string).

```
// This can be successfully instantiated for any type T that can be
// used with <.
func [T] SortNumericSlice(s []T) {
	SortSlice(s, func(a, b T) bool { return a < b })
}
```

Merging two channels into one.

```
func [T] Merge(a, b <-chan T) <-chan T {
	c := make(chan T)
	go func() {
		for a != nil && b != nil {
			select {
			case v, ok := <-a:
				if ok {
					c <- v
				} else {
					a = nil
				}
			case v, ok := <-b:
				if ok {
					c <- v
				} else {
					b = nil
				}
			}
		}
		close(c)
	}()
	return c
}
```

Summing a slice.

```
// Works with any type that supports +.
func [T] Sum(a []T) T {
	var s T
	for _, v := range a {
		s += v
	}
	return s
}
```

A generic interface.

```
type [T] Equaler interface {
	Equal(T) bool
}

// Return the index in s of v1, or -1 if not found.
func [T] Find(s []T, v1 T) int {
	eq, eqok := v1.(Equaler[T])
	for i, v2 := range s {
		if eqok {
			if eq.Equal(v2) {
				return i
			}
		} else if reflect.DeepEqual(v1, v2) {
			return i
		}
	}
	return -1
}

type S []int

// Slice equality that treats nil and S{} as equal.
func (s1 S) Equal(s2 S) bool {
	if len(s1) != len(s2) {
		return false
	}
	for i, v1 := range s1 {
		if v1 != s2[i] {
			return false
		}
	}
	return true
}

var i = Find([]S{S{1, 2}}, S{1, 2})
```

Joining sequences;
works for any `T` that supports `len`, `copy` to `[]byte`, and
conversion from `[]byte`;
in other words, works for `[]byte` and `string`.

```
func [T] Join(a []T, sep T) T {
	if len(a) == 0 {
		return T([]byte{})
	}
	if len(a) == 1 {
		return a[0]
	}
	n := len(sep) * (len(a) - 1)
	for _, v := range a {
		n += len(v)
	}
	b := make([]byte, n)
	bp := copy(b, a[0])
	for _, v := range a[1:] {
		bp += copy(b[bp:], sep)
		bp += copy(b[bp:], v)
	}
	return T(b)
}
```

## Syntax/Semantics Summary

That completes the description of the language changes.
We now turn to implementation details.
When considering this language proposal, consider it in two parts.
First, make sure the syntax and semantics are clean, useful,
orthogonal, and in the spirit of Go.
Second, make sure that the implementation is doable and acceptably
efficient.
I want to stress the two different parts because the implementation
proposal is complex.
Do not let the complexity of the implementation influence your view of
the syntax and semantics.
Most users of Go will not need to understand the implementation.

## Comparison to other languages

### C

Type parameters in C are implemented via preprocessor macros.
The system described here can be seen as a macro system.
However, unlike in C, each parameterized function must be complete and
compilable by itself.
The result is in some ways less powerful than C preprocessor macros,
but does not suffer from problems of namespace conflict and does not
require a completely separate language (the preprocessor language) for
implementation.

### C++

The system described here can be seen as a subset of C++ templates.
Go’s very simple name lookup rules mean that there is none of the
confusion of dependent vs. non-dependent names.
Go’s lack of function overloading removes any concern over just which
instance of a name is being used.
Together these permit the explicit accumulation of constraints when
compiling a generalized function, whereas in C++ where it’s nearly
impossible to determine whether a type may be used to instantiate a
template without effectively compiling the instantiated template and
looking for errors (or using concepts, proposed for later addition to
the language).
Also, since instantiating a parameterized types always instantiates
all methods, there can’t be any surprises as can arise in C++ when
code separate from both the template and the instantiation calls a
previously uncalled method.

C++ template metaprogramming uses template specialization, non-type
template parameters, variadic templates, and SFINAE to implement a
Turing complete language accessible at compile time.
This is very powerful but at the same time has significant
complexities: the template metaprogramming language has a baroque
syntax, no variables or non-recursive loops, and is in general
completely different from non-template C++.
The system described here does not support anything similar to
template metaprogramming for Go.
I believe this is a feature.
I think the right way to implement such features in Go would be to add
support in the go tool for writing Go code to generate Go code, most
likely using the go/ast package and friends, which is in turn compiled
into the final program.
This would mean that the metaprogramming language in Go is itself Go.

### Java

I believe this system is slightly more powerful than Java generics, in
that it permits direct operations on basic types without requiring
explicit methods (that is, the methods are in effect generated
automatically).
This system also does not use type erasure.
Type boxing is minimized.
On the other hand there is of course no function overloading, and
there is nothing like covariant return types.

## Type Checking

A parameterized type is valid if there is at least one set of type
arguments that can instantiate the parameterized type into a valid
non-parameterized type.
This means that type checking a parameterized type is the same as type
checking a non-parameterized type, but the type parameters are assumed
to be valid.

```
type [T] M1 map[T][]byte		// Valid.
type [T] M2 map[[]byte]T		// Invalid.  Slices can not
					// be map keys.
```

A parameterized function is valid if the values of parameterized types
are used consistently.
Here we describe consistency checking that may be performed while
compiling the parameterized function.
Further type checking will occur when the function is instantiated.

It is not necessary to understand the details of these type checking
rules in order to use parameterized functions.
The basic idea is simple: a parameterized function can be used by
replacing all the type parameters with type arguments.
I originally thought it would be useful to describe an exact set of
rules so that all compilers would be consistent in rejecting
parameterized functions that can never be instantiated by any type
argument.
However, I now think this becomes too strict.
We don’t want to say that a future, smarter, compiler must accept a
parameterized function that can never be instantiated even if this set
of rules permits it.
I don’t think complete consistency of handling of invalid programs is
essential.

These rules are still useful as a guide to compiler writers.

Each parameterized function will use a set of types unknown at compile
time.
The initial set of those types will be the type parameters.
Analyzing the function will add new unknown types.
Each unknown type will be annotated to indicate how it is determined
from the type parameters.

In the following discussion an unknown type will start with `U`, a
known type with `K`, either known or unknown with `T`, a variable or
expression of unknown type will start with `v`, an expression with
either known or unknown type will start with `e`.

Type literals that use unknown types produce unknown types.
Each identical type literal produces the same unknown type, different
type literals produce different unknown types.

The new unknown types will be given the obvious annotation: `[]U` is
the type of a slice of the already identified type `U`, and so forth.
Each unknown type may have one or more restrictions, listed below.

* `[]U`
  * _indexable with value type `U`_
  * _sliceable with result type `U`_
* `[N]U` (for some constant expression `N`)
  * _indexable with value type `U`_
  * _sliceable with result type `[]U`_ (`[]U` is a new unknown type)
* `*U`
  * _points to type `U`_
* `map[T1]T2` (assuming either `T1` or `T2` is unknown)
  * _indexable with value type `T2`_
  * _map type with value type `T2`_
* `struct { ... f U ... }`
  * _has field or method `f` of type `U`_
  * _composite_
* `interface { ... F(anything) U ... }`
* `func ( ... U ... )` (anything) or `func (anything) ( ... U ...)`
  * _callable_
* chan `U`
  * _chan of type `U`_

Each use of an unknown type as the type of a composite literal adds
the restriction _composite_.

Each expression using a value `v` of unknown type `U` may produce a value
of some known type, some previously seen unknown type, or a new
unknown type.
A use of a value that produces a value of a new unknown type may add a
restriction to `U`.

* `v.F`, `U.F`
  * If `U` has the restriction _has field or method `F` of type `U2`_ then the type of this expression is `U2`.
  * Otherwise a new unknown type `U2` is created annotated as the type of `U.F`, `U` gets the restriction _has field or method `F` of type `U2`_, and the type of the expression is `U2`.
* `v[e]`
  * If `U` has the restriction _indexable with value type `U2`_, then the type of the expression is `U2`.
  * If the type of `e` is known, and it is not integer, then a new unknown type `U2` is created, `U` gets the restrictions _indexable with value type `U2`_ and _map type with value type `U2`_ and the type of the result is `U2`.
  * Otherwise a new unknown type `U2` is created annotated as the element type of `U`, `U` gets the restriction _indexable with value type `U2`_, and the type of the result is `U2`.
* `e[v]` (where the type of `e` is known)
  * If the type of `e` is slice, string, array, or pointer to array, then `U` gets the restriction _integral_.
  * If the type of `e` is a map type, then `U` gets the restriction _comparable_.
  * Otherwise this is an error, as usual.
* `v[e1:e2]` or `v[e1:e2:e3]`
  * If any of the index expressions have unknown type, those unknown types get the restriction _integral_.
  * If `U` has the restriction _sliceable with result type `U2`_, then the type of the result is `U2`.
  * Otherwise a new unknown type `U2` is created annotated as the slice type of `U`, `U` gets the restriction _sliceable with result type `U2`_, and the type of the result is `U2`. (In many cases `U2` is the same as `U`, but not if `U` is an array type.)
* `v.(T)`
  * Does not introduce any restrictions; type of value is T.
* `v1(e2)`
  * This is a function call, not a type conversion.
  * `U1` gets the restriction _callable_.
  * Does not introduce any restrictions on the arguments.
  * If necessary, new unknown types are introduced for the result types, annotated as the type of the corresponding result parameter.
* `e1(v2)`
  * This is a function call, not a type conversion.
  * If `e1` is known to be a parameterized function, and any of the arguments have unknown type, then any restrictions on `e1`’s type parameters are copied to the unknown types of the corresponding arguments.
* `e1(v2...)`
  * This is the case with an actual ellipsis in the source code.
  * `e1` is handled as though the ellipsis were not present.
  * If `U2` does not already have the restriction _sliceable_, a new unknown type `U3` is created, annotated as the element type of `U2`, and `U2` gets the restriction _sliceable with result type `U3`_.
* `v1 + e2`, `e2 + v1`
  * `U1` gets the restriction _addable_.
  * As usual, the type of the expression is the type of the first operand.
* `v1 {-,*,/} e2`, `e2 {-,*,/} v1`
  * `U1` gets the restriction _numeric_.
  * Type of expression is type of first operand.
* `v1 {%,&,|,^,&^,<<,>>} e2`, `e2 {%,&,|,^,&^,<<,>>} v1`
  * `U1` gets the restriction _integral_.
  * Type of expression is type of first operand.
* `v1 {==,!=} e2`, `e2 {==,!=} v`1
  * `U1` gets the restriction _comparable_; expression has untyped boolean value.
* `v1 {<,<=,>,>=} e2`, `e2 {<,<=,>,>=} v1`
  * `U1` gets the restriction _ordered_; expression has untyped boolean value.
* `v1 {&&,||} e2`, `e2 {&&,||} v1`
  * `U1` gets the restriction _boolean_; type of expression is type of first operand.
* `!v`
  * `U` gets the restriction _boolean_; type of expression is `U`.
* &v
  * Does not introduce any restrictions on `U`.
  * Type of expression is new unknown type as for type literal `*U`.
* `*v`
  * If `U` has the restriction _points to type `U2`_, then the type of the expression is `U2`.
  * Otherwise a new unknown type `U2` is created annotated as the element type of `U`, `U` gets the restriction _points to type `U2`_, and the type of the result is `U2`.
* `<-v`
  * If `U` has the restriction _chan of type `U2`_, then the type of the expression is `U2`.
  * Otherwise a new unknown type `U2` is created annotated as the element type of `U`, `U` gets the restriction _chan of type `U2`_, and the type of the result is `U2`.
* `U(e)`
  * This is a type conversion, not a function call.
  * If `e` has a known type `K`, `U` gets the restriction _convertible from `K`_.
  * The type of the expression is `U`.
* `T(v)`
  * This is a type conversion, not a function call.
  * If `T` is a known type, `U` gets the restriction _convertible to `T`_.
  * The type of the expression is `T`.

Some statements introduce restrictions on the types of the expressions
that appear in them.

* `v <- e`
  * If `U` does not already have a restriction _chan of type `U2`_, then a new type `U2` is created, annotated as the element type of `U`, and `U` gets the restriction _chan of type `U2`_.
* `v++`, `v--`
  * `U` gets the restriction numeric.
* `v = e` (may be part of tuple assignment)
  * If `e` has a known type `K`, `U` gets the restriction _assignable from `K`_.
* `e = v` (may be part of tuple assignment)
  * If `e` has a known type `K`, `U` gets the restriction _assignable to `K`_.
* `e1 op= e2`
  * Treated as `e1 = e1 op e2`.
* return e
  * If return type is known, treated as an assignment to a value of the return type.

The goal of the restrictions listed above is not to try to handle
every possible case.
It is to provide a reasonable and consistent approach to type checking
of parameterized functions and preliminary type checking of types used
to instantiate those functions.

It’s possible that future compilers will become more restrictive;
a parameterized function that can not be instantiated by any type
argument is invalid even if it is never instantiated, but we do not
require that every compiler diagnose it.
In other words, it’s possible that even if a package compiles
successfully today, it may fail to compile in the future if it defines
an invalid parameterized function.

The complete list of possible restrictions is:

* _addable_
* _integral_
* _numeric_
* _boolean_
* _comparable_
* _ordered_
* _callable_
* _composite_
* _points to type `U`_
* _indexable with value type `U`_
* _sliceable with value type `U`_
* _map type with value type `U`_
* _has field or method `F` of type `U`_
* _chan of type `U`_
* _convertible from `U`_
* _convertible to `U`_
* _assignable from `U`_
* _assignable to `U`_

Some restrictions may not appear on the same type.
If some unknown type has an invalid pair of restrictions, the
parameterized function is invalid.

* _addable_, _integral_, _numeric_ are invalid if combined with any of
  * _boolean_, _callable_, _composite_, _points to_, _indexable_, _sliceable_, _map type_, _chan of_.
* boolean is invalid if combined with any of
  * _comparable_, _ordered_, _callable_, _composite_, _points to_, _indexable_, _sliceable_, _map type_, _chan of_.
* _comparable_ is invalid if combined with _callable_.
* _ordered_ is invalid if combined with any of
  * _callable_, _composite_, _points to_, _map type_, _chan of_.
* _callable_ is invalid if combined with any of
  * _composite_, _points to_, _indexable_, _sliceable_, _map type_, _chan of_.
* _composite_ is invalid if combined with any of
  * _points to_, _chan of_.
* _points to_ is invalid if combined with any of
  * _indexable_, _sliceable_, _map type_, _chan of_.
* _indexable_, _sliceable_, _map type_ are invalid if combined with _chan of_.

If one of the type parameters, not some generated unknown type, has
the restriction assignable from `T` or assignable to `T`, where `T` is a
known named type, then the parameterized function is invalid.
This restriction is intended to catch simple errors, since in general
there will be only one possible type argument.
If necessary such code can be written using a type assertion.

As mentioned earlier, type checking an instantiation of a
parameterized function is conceptually straightforward: replace all
the type parameters with the type arguments and make sure that the
result type checks correctly.
That said, the set of restrictions computed for the type parameters
can be used to produce more informative error messages at
instantiation time.
In fact, not all the restrictions are used when compiling the
parameterized function, but they will still be useful at instantiation
time.

## Implementation

This section describes a possible implementation that yields a good
balance between compilation time and execution time.
The proposal in this section is only a suggestion.

In general there are various possible implementations that yield the
same syntax and semantics.
For example, it is always possible to implement parameterized
functions by generating a new copy of the function for each
instantiation, where the new function is created by replacing the type
parameters with the type arguments.
This approach would yield the most efficient execution time at the
cost of considerable extra compile time and increased code size.
It’s likely to be a good choice for parameterized functions that are
small enough to inline, but it would be a poor tradeoff in most other
cases.
This section describes one possible implementation with better
tradeoffs.

Type checking a parameterized function produces a list of unknown
types, as described above.
Create a new interface type for each unknown type.
For each use of a value of that unknown type, add a method to the
interface, and rewrite the use to be a call to the method.
Compile the resulting function.

Callers of the function will see a list of unknown types with
corresponding interfaces, with a description for each method.
The unknown types will all be annotated to indicate how they are
derived from the type arguments.
Given the type arguments used to instantiate the function, the
annotations are sufficient to determine the real type corresponding to
each unknown type.

For each unknown type, the caller will construct a new copy of the
type argument.
For each method description for that unknown type, the caller will
compile a method for the new type.
The resulting type will satisfy the interface type that corresponds to
the unknown type.

If the type argument is itself an interface type, the new copy of the
type will be a struct type with a single member that is the type
argument, so that the new copy can have its own methods.
(This will require slight but obvious adjustments in the instantiation
templates shown below.)
If the type argument is a pointer type, we grant a special exception
to permit its copy to have methods.

The call to the parameterized function will be compiled as a
conversion from the arguments to the corresponding new types, and a
type assertion of the results from the interface types to the type
arguments.

We will call the unknown types `Un`, the interface types created while
compiling the parameterized function `In`, the type arguments used in
the instantiation `An`, and the newly created corresponding types
`Bn`.  Each `Bn` will be created as though the compiler saw `type Bn An`
followed by appropriate method definitions (modified as described
above for interface and pointer types).

To show that this approach will work, we need to show the following:

* Each operation using a value of unknown type can be implemented as a call to a method `M` on an interface type `I`.
* We can describe each `M` for each `I` in such a way that we can instantiate the methods for any valid type argument; for simplicity we can describe these methods as templates in the form of Go code, and we call them _instantiation templates_.
* All valid type arguments will yield valid method implementations.
* All invalid type arguments will yield some invalid method implementation, thus causing an appropriate compilation error. (Frankly this description does not really show that; I’d be happy to see counter-examples.)

### Simple expressions

Simple expressions turn out to be easy.
For example, consider the expression `v.F` where `v` has some unknown
type `U1`, and the expression has the unknown type `U2`.
Compiling the original function will generate interface types `I1` and `I2`.

Add a method `$FieldF` to `I1` (here I’m using `$` to indicate that
this is not a user-callable method;
the actual name will be generated by the compiler and never seen by the user).
Compile `v.F` as `v.$FieldF()` (while compiling the code, `v` has type
`I1`).
Write out an instantiation template like this:

```
func (b1 *B1) $FieldF() I2 { return B2(A1(*b1).F) }
```

When the compiler instantiates the parameterized function, it knows
the type arguments that correspond to `U1` and `U2`.
It has defined new names for those type arguments, `B1` and `B2`, so
that it has something to attach methods to.
The instantiation template is used to define the method `$FieldF` by
simply compiling the method in a scope such that `A1`, `B1`, and `B2`
refer to the appropriate types.

The conversion of `*b1` (type `B1`) will always succeed, as `B1` is
simply a new name for `A1`.

The reference to field (or method) `F` will succeed exactly when `B1`
has a field (or method) `F`;
that is the correct semantics for the expression `v.F` in the original
parameterized function.
The conversion to type `B2` will succeed when `F` has the type `A2`.
The conversion of the return value from type `B2` to type `I2` will always
succeed, as `B2` implements `I2` by construction.

Returning to the parameterized function, the type of `v.$FieldF()` is
`I2`, which is correct since all references to the unknown type `U2` are
compiled to use the interface type `I2`.

An expression that uses two operands will take the second operand as a
parameter of the appropriate interface type.
The instantiation template will use a type assertion to convert the
interface type to the appropriate type argument.
For example, `v1[v2]`, where both expressions have unknown type, will
be converted to `v1.$Index(v2)` and the instantiation template will be

```
func (b1 *B1) $Index(i2 I2) I3 { return B3(A1(*b1)[A2(*i2.(*B2))]) }
```

The type conversions get admittedly messy, but the basic idea is as
above: convert the `Bn` values to the type arguments `An`, perform the
operation, convert back to `Bn`, and finally return as type `In`.
The method takes an argument of type `I2` as that is what the
parameterized function will use;
the type assertion to `*B2` will always succeed.

This same general procedure works for all simple expressions: index
expressions, slice expressions, relational operators, arithmetic
operators, indirection expressions, channel receives, method
expressions, method values, conversions.

To be clear, each expression is handled independently, regardless of
how it appears in the original source code.
That is, `a + b - c` will be translated into two method calls, something
like `a.$Plus(b).$Minus(c)` and each method will have its own
instantiation template.

### Untyped constants

Expressions involving untyped constants may be implemented by creating
a specific method for the specific constants.
That is, we can compile `v + 10` as `v.$Add10()`, with an instantiation
template

```
func (b1 *B1) $Add10() I1 { return B1(A1(*b1) + 10) }
```

Another possibility would be to compile it as `v.$AddX(10)` and

```
func (b1 *B1) $AddX(x int64) { return B1(A1(*b1) + A1(x)) }
```

However, this approach in general will require adding some checks in
the instantiation template so that code like `v + 1.5` is rejected if
the type argument of `v` is not a floating point or complex type.

### Logical operators

The logical operators `&&` and `||` will have to be expanded in the
compiled form of the parameterized function so that the operands will
be evaluated only when appropriate.
That is, we can not simply replace `&&` and `||` of values of unknown
types with method calls, but must expand them into if statements while
retaining the correct order of evaluation for the rest of the
expression.
In the compiler this can be done by rewriting them using a
compiler-internal version of the C `?:` ternary operator.

### Address operator

The address operator requires some additional attention.
It must be combined with the expression whose address is being taken.
For example, if the parameterized function has the expression `&v[i]`,
the compiler must generate a `$AddrI` method, with an instantiation
template like

```
func (b1 *B1) $AddrI(i2 I2) I3 { return B3(&A1(*b1)[A2(i2.(*B2))]) }
```

### Type assertions

Type assertions are conceptually simple, but as they are permitted for
values of unknown type they require some additional attention in the
instantiation template.
Code like `v.(K)`, where `K` is a known type, will be compiled to a
method call with no parameters, and the instantiation template will
look like

```
func (b1 B1) $ConvK() K {
	a1 := A1(b1)
	var e interface{} = a1
	return e.(K)
}
```

Introducing `e` avoids an invalid type assertion of a non-interface type.

For `v.(U2)` where `U2` is an unknown type, the instantiation template
will be similar:

```
func (b1 B1) $ConvU() I2 {
	a1 := A1(b1)
	var e interface{} = a1
	return B2(e.(A2))
}
```

This will behave correctly whether `A2` is an interface or a
non-interface type.

### Function calls

A call to a function of known type requires adding implicit
conversions from the unknown types to the known types.
Those conversions will be implemented by method calls as described above.
Only conversions valid for function calls should be accepted;
these are the set of conversions valid for assignment statements,
described below.

A call to a function of unknown type can be implemented as a method
call on the interface type holding the function value.
Multiple methods may be required if the function is called multiple
times with different unknown types, or with different numbers of
arguments for a variadic function.
In each case the instantiation template will simply be a call of the
function, with the appropriate conversions to the type arguments of
the arguments of unknown type.

A function call of the form `F1(F2())` where neither function is known
may need a method all by itself, since there is no way to know how
many results `F2` returns.

### Composite literals

A composite literal of a known type with values of an unknown type can
be handled by inserting implicit type conversions to the appropriate
known type.

A composite literal of an unknown type can not be handled using the
mechanisms described above.
The problem is that there is no interface type where we can attach a
method to create the composite literal.
We need some value of type `Bn` with a method for us to call, but in the
general case there may not be any such value.

To implement this we require that the instantiation place a value of
an appropriate interface type in the function’s closure.
This can always be done as generalized functions only occur at
top-level, so they do not have any other closure (function literals
are discussed below).
We compile the code to refer to a value `$imaker` in the closure, with
type `Imaker`.
The instantiation will place a value with the appropriate type `Bmaker`
in the function instantiation's closure.
The value is irrelevant as long as it has the right type.
The methods of `Bmaker` will, of course, be those of `Imaker`.
Each different composite literal in the parameterized function will be
a method of `Imaker`.

A composite literal of an unknown type without keys can then be
implemented as a method of `Imaker` whose instantiation template simply
returns the composite literal, as though it were an operator with a
large number of operands.

A composite literal of an unknown type with keys is trickier.
The compiler must examine all the keys.

* If any of the keys are expressions or constants rather than simple names, this can not be a struct literal. We can generate a method that passes all the keys and values, and the instantiation template can be the composite literal using those keys and values. In this case if one of the keys is an undefined name, we can give an error while compiling the parameterized function.
* Otherwise, if any of the names are not defined, this must be a struct literal. We can generate a method that passes the values, and the instantiation template can be the composite literal with the literal names and the value arguments.
* Otherwise, we call a method passing all the keys and values. The instantiation template is the composite literal with the key and value arguments. If the type argument is a struct, the generated method will ignore the key values passed in.

For example, if the parameterized function uses the composite literal
`U{f: g}` and there is a local variable named `f`, this is compiled
into `imaker.$CompLit1(f, g)`, and the instantiation template is

```
func (bm Bmaker) $CompLit1(f I1, g I2) I3 {
	return bm.$CompLit2(A1(f.(B1)), A2(g.(B2)))
}
func (Bmaker) $CompLit2(f A1, g A2) I3 { return B3(A3{f: g}) }
```

If `A3`, the type argument for `U`, is a struct, then the parameter `f` is
unused and the `f` in the composite literal refers to the field `f` of
`A3` (it is an error if no such field exists).
If `A3` is not a struct, then `f` must be an appropriate key type for `A3`
and the value is used.

### Function literals

A function literal of known type may be compiled just like any other
parameterized function.
If a maker variable is required for constructs like composite
literals, it may be passed from the enclosing function’s closure to
the function literal’s closure.

A function literal of unknown type requires that the function have a
maker variable, as for composite literals, above.
The function literal is compiled as a parameterized function, and
parameters of unknown type are received as interface types as we are
describing.
The type of the function literal will itself be an unknown type, and
will have corresponding real and interface types just like any other
unknown type.
Creating the function literal value requires calling a method on the
maker variable.
That method will create a function literal of known type that simply
calls the compiled form of the function literal.

For example:

```
func [T] Counter() func() T {
	var c T
	return func() T {
		c++
		return c
	}
}
```

This is compiled using a maker variable in the closure.
The unknown type `T` will get an interface type, called here `I1`;
the unknown type `func() T` will get the interface type `I2`.
The compiled form of the function will call a method on the maker
variable, passing a closure, something along the lines of

```
type CounterTClosure struct { c *I1 }
func CounterT() I2 {
	var c I1
	closure := CounterTClosure{&c}
	return $bmaker.$fnlit1(closure)
}
```

The function literal will get its own compiled form along the lines of

```
func fnlit1(closure CounterTClosure) I1 {
	(*closure.c).$Inc()
	return *closure.c
}
```

The compiled form of the function literal does not have to correspond
to any particular function signature, so it’s fine to pass the closure
as an ordinary parameter.

The compiler will also generate instantiation templates for callers of
`Counter`.

```
func (Bmaker) $fnlit1(closure struct { c *I1}) I2 {
	return func() A1 {
		i1 := fnlit1(closure)
		b1 := i1.(B1)
		return A1(b1)
	}
}

func (b1 *B1) $Inc() {
	a1 := A1(*b1)
	a1++
	*b1 = B1(a1)
}
```

This instantiation template will be compiled with the type argument `A1`
and its method-bearing copy `B1`.
The call to `Counter` will use an automatically inserted type assertion
to convert from `I2` to the type argument `B2` aka `func() A1`.
This gives us a function literal of the required type, and tracing
through the calls above shows that the function literal behaves as it
should.

### Statements

Many statements require no special attention when compiling a
parameterized function.
A send statement is compiled as a method on the channel, much like a
receive expression.
An increment or decrement statement is compiled as a method on the
value, as shown above.
A switch statement may require calling a method for equality
comparison, just like the `==` operator.

#### Assignment statements

Assignment statements are straightforward to implement but require a
bit of care to implement the proper type checking.
When compiling the parameterized function it's impossible to know
which types may be assigned to any specific unknown type.
The type checking could be done using annotations of the form _`U1`
must be assignable to `U2`_, but here I’ll outline a method that
requires only instantiation templates.

Assignment from a value of one unknown type to the same unknown type
is just an ordinary interface assignment.

Otherwise assignment is a method on the left-hand-side value (which
must of course be addressable), where the method is specific to the
type on the right hand side.

```
func (b1 *B1) $AssignI2(i2 I2) {
	var a1 A1 = A2(i2.(B2))
	*b1 = B1(a1)
}
```

The idea here is to convert the unknown type on the right hand side
back to its type argument `A2`, and then assign it to a variable of the
type argument `A1`.
If that assignment is not valid, the instantiation template can not be
compiled with the type arguments, and the compiler will give an error.
Otherwise the assignment is made.

Return statements are implemented similarly, assigning values to
result parameters.
The code that calls the parameterized function will handle the type
conversions at the point of the call.

#### Range clauses

A for statement with a range clause may not know anything about the
type over which it is ranging.
This means that range clauses must in general be implemented using
compiler built-in functions that are not accessible to ordinary
programs.
These will be similar to the runtime functions that the compiler
already uses.
A statement:

```
	for v1 := range v2 {}
```

could be compiled as something like:
```
	for v1, it, f := v2.$init(); !f; v1, f = v2.$next(it) {}
```

with instantiation templates that invoke compiler built-in functions:

```
func (b2 B2) $init() (I1, I3, bool) {
	return $iterinit(A2(b2))
}
func (b2 B2) $next(I3) (I1, bool) {
	return $iternext(A2(b2), I3.(A3))
}
```

Here I’ve introduced another unknown type `I3` to represent the
current iteration state.

If the compiler knows something specific about the unknown type, then
more efficient techniques can be used.  For example, a range over a
slice could be written using `$Len` and `$Index` methods.

#### Type switches

Type switches, like type assertions, require some attention because
the value being switched on may have a non-interface type argument.
The instantiation method will implement the type switch proper, and
pass back the index of the select case.
The parameterized function will do a switch on that index to choose
the code to execute.

```
func [T] Classify(v T) string {
	switch v.(type) {
	case []byte:
		return “slice”
	case string:
		return “string”
	default:
		return “unknown”
	}
}
```

The parameterized function is compiled as

```
func ClassifyT(v I1) string {
	switch v.$Type1() {
	case 0:
		return “slice”
	case 1:
		return “string”
	case 2:
		return “unknown”
	}
}
```

The instantiation template will be

```
func (b1 B1) $Type1() int {
	var e interface{} = A1(b1)
	switch e.(type) {
	case []byte:
		return 0
	case string
		return 1
	default
		return 2
	}
}
```

The instantiation template will have to be compiled in an unusual way:
it will have to permit duplicate types.
That is because a type switch that uses unknown types in the cases may
wind up with the same type in multiple cases.
If that happens the first matching case should be used.

#### Select statements

Select statements will be implemented much like type switches.
The select statement proper will be in the instantiation template.
It will accept channels and values to send as required.
It will return an index indicating which case was chosen, and a
receive value (an empty interface) and a `bool` value.
The effect will be fairly similar to `reflect.Select`.

### Built-in functions

Most built-in functions when called with unknown types are simply
methods on their first argument: `append`, `cap`, `close`, `complex`,
`copy`, `delete`, `imag`, `len`, `real`.
Other built-in functions require no special handling for parameterized
functions: `panic`, `print`, `println`, `recover`.

The built-in functions `make` and `new` will be implemented as methods
on a special maker variable, as described above under composite
literals.

### Methods of parameterized types

A parameterized type may have methods, and those methods may have
arguments and results of unknown type.
Any instantiation of the parameterized type must have methods with the
appropriate type arguments.
That means that the compiler must generate instantiation templates
that will serve as the methods of the type instantiation.
Those templates will call the compiled form of the method with the
appropriate interface types.

```
type [T] Vector []T
func [T] (v Vector[T]) Len() int { return len(v) }
func [T] (v Vector[T]) Index(i int) T { return v[i] }

type Readers interface {
	Len() int
	Index(i int) io.Reader
}

type VectorReader struct { Vector[io.Reader] }
var _ = VectorReader{}.(Readers)
```

In this example, the type `VectorReader` inherits the methods of the
embedded field `Vector[io.Reader]` and therefore implements the
non-parameterized interface type `Readers`.
When implementing this, the compiler will assign interface types for
the unknown types `T` and `[]T`;
here those types will be `I1` and `I2`, respectively.
The methods of the parameterized type Vector will be compiled as
ordinary functions:

```
func $VectorLen(i2 I2) int { return i2.$len() }
func $VectorIndex(i2 I2, i int) I1 { return i2.$index(i) }
```

The compiler will generate instantiation templates for the methods:

```
func (v Vector) Len() int { return $VectorLen(I2(v)) }
func (v Vector) Index(i int) A1 {
return A1($VectorIndex(I2(v), i).(B1))
}
```

The compiler will also generate instantiation templates for the
methods of the type `B2` that corresponds to the unknown type `[]T`.

```
func (b2 B2) $len() int { return len(A2(b2)) }
func (b2 B2) $index(i int) I1 { return B1(A2(b2)[i]) }
```

With an example this simple there is a lot of effort for no real gain,
but this does show how the compiler can use the instantiation
templates to define methods of the correct instantiated type while the
bulk of the work is still done by the parameterized code using
interface types.

### Implementation summary

I believe that covers all aspects of the language and shows how they
may be implemented in a manner that is reasonably efficient both in
compile time and execution time.
There will be code bloat in that instantiation templates may be
compiled multiple times for the same type, but the templates are, in
general, small.
Most are only a few instructions.
There will be run time cost in that many operations will require a
method call rather than be done inline.
This cost will normally be small.
Where it is significant, it will always be possible to manually
instantiate the function for the desired type argument.

While the implementation technique described here is general and
covers all cases, real compilers are likely to implement a blend of
techniques.
Small parameterized functions will simply be inlined whenever they are
called.
Parameterized functions that only permit a few types, such as the `Sum`
or `Join` examples above, may simply be compiled once for each possible
type in the package where they are defined, with callers being
compiled to simply call the appropriate instantiation.

Implementing type parameters using interface methods shows that type
parameters can be viewed as implicit interfaces.
Rather than explicitly defining the methods of a type and then calling
those methods, type parameters implicitly define an interface by the
way in which values of that type are used.

In order to get good stack tracebacks and a less confusing
implementation of `runtime.Caller`, it will probably be desirable to,
by default, ignore the methods generated from instantiation templates
when unwinding the stack.
However, it might be best if they could influence the reporting of the
parameterized function in a stack backtrace, so that it could indicate
that types being used.
I don’t yet know if that would be helpful or feasible.

## Deployment

This proposal is backward compatible with Go 1, in that all Go 1
programs will continue to compile and run identically if this proposal
is adopted.  That leads to the following proposal.

* Add support for type parameters to a future Go release 1.n, but require a command line option to use them. This will let people experiment with the new facility.
* Add easy support for that command line option to the go tool.
* Add a `// +build` constraint for the command line option.
* Try out modified versions of standard packages where it seems useful, putting the new versions under the exp directory.
* Decide whether to keep the facility for Go 2, in which the standard packages would be updated.

In the standard library, the most obvious place where type parameters
would be used is to introduce compile-time-type-safe containers, like
`container/list` but with the type of the elements known at compile
time.
It would also be natural to add to the `sort` package to make it easier
to sort slices with less boilerplate.
Other new packages would be `algorithms` (find the max/min/average of a
collection, transform a collection using a function), `channels` (merge
channels into one, multiplex one channel into many), `maps` (copy a
map).

Type parameters could be used to partially unify the `bytes` and
`strings` packages.
However, the implementation would be based on using an unknown type
that could be either `[]byte` or `string`.
Values of unknown type are passed as interface values.
Neither `[]byte` nor `string` fits in an interface value, so the
values would have be passed by taking their address.
Most of the functions in the package are fairly simple;
one would only want to unify them if they could be inlined, or if
escape analysis were smart enough to avoid pushing the values into the
heap, or if the compiler were smart enough to see that only two types
would work and to compile both separately.

Similar considerations apply to supporting a parameterized `Writer`
interface that accepts either `[]byte` or `string`.
On the other hand, if the compiler has the appropriate optimizations,
it would be convenient to write unified implementations for `Write` and
`WriteString` methods.

The perhaps surprising conclusion is that type parameters permit new
kinds of packages, but need not lead to significant changes in
existing packages.
Go does after all already support generalized programming, using
interfaces, and the existing packages were designed around that fact.
In general they already work well.
Adding type parameters does not change that.
It opens up the ability to write new kinds of packages, ones that have
not been written to date because they are not well supported by
interfaces.

## Summary

I think this is the best proposal so far.
However, it will not be adopted.

The syntax still needs work.
A type is defined as `type [T] Vector []T` but is used as `Vector[int]`,
which means that the brackets are on the left in the definition but on
the right in the use.
It would be much nicer to write `type Vector[T] []T`, but that is
ambiguous with an array declaration.
That suggests the possibility of using double square brackets, as in
`Vector[[int]]`, or perhaps some other character(s).

The type deduction rules are too complex.
We want people to be able to easily use a `Transform` function, but
the rules required to make that work without explicitly specifying type
parameters are very complex.
The rules for untyped constants are also rather hard to follow.
We need type deduction rules that are clear and obvious, so that
there is no confusion as to which type is being used.

The implementation description is interesting but very complicated.
Is any compiler really going to implement all that?
It seems likely that any initial implementation would just use macro
expansion, and unclear whether it would ever move beyond that.
The result would be increased compile times and code bloat.
