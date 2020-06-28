# Type Parameters - Draft Design

Ian Lance Taylor\
Robert Griesemer\
June 16, 2020

## Abstract

We suggest extending the Go language to add optional type parameters
to types and functions.
Type parameters may be constrained by interface types.
We also suggest extending interface types, when used as type
constraints, to permit listing the set of types that may be assigned
to them.
Type inference via a unification algorithm is supported to permit
omitting type arguments from function calls in many cases.
The design is fully backward compatible with Go 1.

## How to read this design draft

This document is long.
Here is some guidance on how to read it.

* We start with a high level overview, describing the concepts very
  briefly.
* We then explain the full design starting from scratch, introducing
  the details as we need them, with simple examples.
* After the design is completely described, we discuss implementation,
  some issues with the design, and a comparison with other approaches
  to generics.
* We then present several complete examples of how this design would
  be used in practice.
* Following the examples some minor details are discussed in an
  appendix.

## Very high level overview

This section explains the changes suggested by the design draft very
briefly.
This section is intended for people who are already familiar with how
generics would work in a language like Go.
These concepts will be explained in detail in the following sections.

* Functions can have an additional type parameter list introduced by
  the keyword `type`: `func F(type T)(p T) { ... }`.
* These type parameters can be used by the regular parameters and in
  the function body.
* Types can also have a type parameter list: `type M(type T) []T`.
* Each type parameter can have an optional type constraint: `func
  F(type T Constraint)(p T) { ... }`
* Type constraints are interface types.
* Interface types used as type constraints can have a list of
  predeclared types; only types whose underlying type is one of those
  types can implement the interface.
* Using a generic function or type requires passing type arguments.
* Type inference permits omitting the type arguments in common cases.
* If a type parameter has a type constraint its type argument must
  implement the interface.
* Generic functions may only use operations permitted by the type
  constraint.

In the following sections we work through each of these language
changes in great detail.
You may prefer to skip ahead to the [examples](#Examples) to see what
generic code written to this design draft will look like in practice.

## Background

This version of the design draft has many similarities to the one
presented on July 31, 2019, but contracts have been removed and
replaced by interface types.

There have been many [requests to add additional support for generic
programming](https://github.com/golang/go/wiki/ExperienceReports#generics)
in Go.
There has been extensive discussion on
[the issue tracker](https://golang.org/issue/15292) and on
[a living document](https://docs.google.com/document/d/1vrAy9gMpMoS3uaVphB32uVXX4pi-HnNjkMEgyAHX4N4/view).

There have been several proposals for adding type parameters, which
can be found through the links above.
Many of the ideas presented here have appeared before.
The main new features described here are the syntax and the careful
examination of interface types as constraints.

This design draft suggests extending the Go language to add a form of
parametric polymorphism, where the type parameters are bounded not by
a declared subtyping relationship (as in some object oriented
languages) but by explicitly defined structural constraints.

This design does not support template metaprogramming or any other
form of compile time programming.

As the term _generic_ is widely used in the Go community, we will
use it below as a shorthand to mean a function or type that takes type
parameters.
Don't confuse the term generic as used in this design with the same
term in other languages like C++, C#, Java, or Rust; they have
similarities but are not the same.

## Design

We will describe the complete design in stages based on simple
examples.

### Type parameters

Generic code is code that is written using types that will be
specified later.
An unspecified type is called a _type parameter_.
When running the generic code, the type parameter will be set to a
_type argument_.

Here is a function that prints out each element of a slice, where the
element type of the slice, here called `T`, is unknown.
This is a trivial example of the kind of function we want to permit in
order to support generic programming.
(Later we'll also discuss [generic types](#Generic-types)).

```Go
// Print prints the elements of a slice.
// It should be possible to call this with any slice value.
func Print(s []T) { // Just an example, not the suggested syntax.
	for _, v := range s {
		fmt.Println(v)
	}
}
```

With this approach, the first decision to make is: how should the type
parameter `T` be declared?
In a language like Go, we expect every identifier to be declared in
some way.

Here we make a design decision: type parameters are similar to
ordinary non-type function parameters, and as such should be listed
along with other parameters.
However, type parameters are not the same as non-type parameters, so
although they appear in the list of parameters we want to distinguish
them.
That leads to our next design decision: we define an additional,
optional, parameter list, describing type parameters.
This parameter list appears before the regular parameters.
It starts with the keyword `type`, and lists type parameters.

```Go
// Print prints the elements of any slice.
// Print has a type parameter T, and has a single (non-type)
// parameter s which is a slice of that type parameter.
func Print(type T)(s []T) {
	// same as above
}
```

This says that within the function `Print` the identifier `T` is a
type parameter, a type that is currently unknown but that will be
known when the function is called.
As seen above, the type parameter may be used as a type when
describing the ordinary non-type parameters.
It may also be used within the body of the function.

Since `Print` has a type parameter, any call of `Print` must provide a
type argument.
Later we will see how this type argument can usually be deduced from
the non-type argument, by using [function argument type
inference](#Function-argument-type-inference).
For now, we'll pass the type argument explicitly.
Type arguments are passed much like type parameters are declared: as a
separate list of arguments.
At the call site, the `type` keyword is not used.

```Go
	// Call Print with a []int.
	// Print has a type parameter T, and we want to pass a []int,
	// so we pass a type argument of int by writing Print(int).
	// The function Print(int) expects a []int as an argument.

	Print(int)([]int{1, 2, 3})

	// This will print:
	// 1
	// 2
	// 3
```

### Constraints

Let's make our example slightly more complicated.
Let's turn it into a function that converts a slice of any type into a
`[]string` by calling a `String` method on each element.

```Go
// This function is INVALID.
func Stringify(type T)(s []T) (ret []string) {
	for _, v := range s {
		ret = append(ret, v.String()) // INVALID
	}
	return ret
}
```

This might seem OK at first glance, but in this example `v` has type
`T`, and we don't know anything about `T`.
In particular, we don't know that `T` has a `String` method.
So the call to `v.String()` is invalid.

Naturally, the same issue arises in other languages that support
generic programming.
In C++, for example, a generic function (in C++ terms, a function
template) can call any method on a value of generic type.
That is, in the C++ approach, calling `v.String()` is fine.
If the function is called with a type argument that does not have a
`String` method, the error is reported when compiling the call to
`v.String` with that type argument.
These errors can be lengthy, as there may be several layers of generic
function calls before the error occurs, all of which must be reported
to understand what went wrong.

The C++ approach would be a poor choice for Go.
One reason is the style of the language.
In Go we don't refer to names, such as, in this case, `String`, and
hope that they exist.
Go resolves all names to their declarations when they are seen.

Another reason is that Go is designed to support programming at
scale.
We must consider the case in which the generic function definition
(`Stringify`, above) and the call to the generic function (not shown,
but perhaps in some other package) are far apart.
In general, all generic code expects the type arguments to meet
certain requirements.
We refer to these requirements as _constraints_ (other languages have
similar ideas known as type bounds or trait bounds or concepts).
In this case, the constraint is pretty obvious: the type has to have a
`String() string` method.
In other cases it may be much less obvious.

We don't want to derive the constraints from whatever `Stringify`
happens to do (in this case, call the `String` method).
If we did, a minor change to `Stringify` might change the
constraints.
That would mean that a minor change could cause code far away, that
calls the function, to unexpectedly break.
It's fine for `Stringify` to deliberately change its constraints, and
force users to change.
What we want to avoid is `Stringify` changing its constraints
accidentally.

This means that the constraints must set limits on both the type
arguments passed by the caller and the code in the generic function.
The caller may only pass type arguments that satisfy the constraints.
The generic function may only use those values in ways that are
permitted by the constraints.
This is an important rule that we believe should apply to any attempt
to define generic programming in Go: generic code can only use
operations that its type arguments are known to implement.

### Operations permitted for any type

Before we discuss constraints further, let's briefly note what happens
in their absence.
If a generic function does not specify a constraint for a type
parameter, as is the case for the `Print` method above, then any type
argument is permitted for that parameter.
The only operations that the generic function can use with values of
that type parameter are those operations that are permitted for values
of any type.
In the example above, the `Print` function declares a variable `v`
whose type is the type parameter `T`, and it passes that variable to a
function.

The operations permitted for any type are:

* declare variables of those types
* assign other values of the same type to those variables
* pass those variables to functions or return them from functions
* take the address of those variables
* convert or assign values of those types to the type `interface{}`
* convert a value of type `T` to type `T` (permitted but useless)
* use a type assertion to convert an interface value to the type
* use the type as a case in a type switch
* define and use composite types that use those types, such as a slice
  of that type
* pass the type to some builtin functions such as `new`

It's possible that future language changes will add other such
operations, though none are currently anticipated.

### Defining constraints

Go already has a construct that is close to what we need for a
constraint: an interface type.
An interface type is a set of methods.
The only values that can be assigned to a variable of interface type
are those whose types implement the same methods.
The only operations that can be done with a value of interface type,
other than operations permitted for any type, are to call the
methods.

Calling a generic function with a type argument is similar to
assigning to a variable of interface type: the type argument must
implement the constraints of the type parameter.
Writing a generic function is like using values of interface type: the
generic code can only use the operations permitted by the constraint
(or operations that are permitted for any type).

In this design, constraints are simply interface types.
Implementing a constraint is simply implementing the interface type.
(Later we'll see how to define constraints for operations other than
method calls, such as [binary operators](#Operators)).

For the `Stringify` example, we need an interface type with a `String`
method that takes no arguments and returns a value of type `string`.

```Go
// Stringer is a type constraint that requires the type argument to have
// a String method and permits the generic function to call String.
// The String method should return a string representation of the value.
type Stringer interface {
	String() string
}
```

(It doesn't matter for this discussion, but this defines the same
interface as the standard library's `fmt.Stringer` type, and  real
code would likely simply use `fmt.Stringer`.)

### Using a constraint

For a generic function, a constraint can be thought of as the type of
the type argument: a meta-type.
So, although generic functions are not required to use constraints,
when they do they are listed in the type parameter list as the
meta-type of a type parameter.

```Go
// Stringify calls the String method on each element of s,
// and returns the results.
func Stringify(type T Stringer)(s []T) (ret []string) {
	for _, v := range s {
		ret = append(ret, v.String())
	}
	return ret
}
```

The single type parameter `T` is followed by the constraint that
applies to `T`, in this case `Stringer`.

### Multiple type parameters

Although the `Stringify` example uses only a single type parameter,
functions may have multiple type parameters.

```Go
// Print2 has two type parameters and two non-type parameters.
func Print2(type T1, T2)(s1 []T1, s2 []T2) { ... }
```

Compare this to

```Go
// Print2Same has one type parameter and two non-type parameters.
func Print2Same(type T)(s1 []T, s2 []T) { ... }
```

In `Print2` `s1` and `s2` may be slices of different types.
In `Print2Same` `s1` and `s2` must be slices of the same element
type.

Each type parameter may have its own constraint.

```Go
// Stringer is a type constraint that requires a String method.
// The String method should return a string representation of the value.
type Stringer interface {
	String() string
}

// Plusser is a type constraint that requires a Plus method.
// The Plus method is expected to add the argument to an internal
// string and return the result.
type Plusser interface {
	Plus(string) string
}

// ConcatTo takes a slice of elements with a String method and a slice
// of elements with a Plus method. The slices should have the same
// number of elements. This will convert each element of s to a string,
// pass it to the Plus method of the corresponding element of p,
// and return a slice of the resulting strings.
func ConcatTo(type S Stringer, P Plusser)(s []S, p []P) []string {
	r := make([]string, len(s))
	for i, v := range s {
		r[i] = p[i].Plus(v.String())
	}
	return r
}
```

If a constraint is specified for any type parameter, every type
parameter must have a constraint.
If some type parameters need a constraint and some do not, those that
do not should have a constraint of `interface{}`.

```Go
// StrAndPrint takes a slice of labels, which can be any type,
// and a slice of values, which must have a String method,
// converts the values to strings, and prints the labelled strings.
func StrAndPrint(type L interface{}, T Stringer)(labels []L, vals []T) {
	// Stringify was defined above. It returns a []string.
	for i, s := range Stringify(vals) {
		fmt.Println(labels[i], s)
	}
}
```

A single constraint can be used for multiple type parameters, just as
a single type can be used for multiple non-type function parameters.
The constraint applies to each type parameter separately.

```Go
// Stringify2 converts two slices of different types to strings,
// and returns the concatenation of all the strings.
func Stringify2(type T1, T2 Stringer)(s1 []T1, s2 []T2) string {
	r := ""
	for _, v1 := range s1 {
		r += v1.String()
	}
	for _, v2 := range s2 {
		r += v2.String()
	}
	return r
}
```

### Generic types

We want more than just generic functions: we also want generic types.
We suggest that types be extended to take type parameters.

```Go
// Vector is a name for a slice of any element type.
type Vector(type T) []T
```

A type's parameters are just like a function's type parameters.

Within the type definition, the type parameters may be used like any
other type.

To use a generic type, you must supply type arguments.
This looks like a function call, except that the function in this case
is actually a type.
This is called _instantiation_.
When we instantiate a type by supplying type arguments for the type
parameters, we produce a type in which each use of a type parameter in
the type definition is replaced by the corresponding type argument.

```Go
// v is a Vector of int values.
//
// This is similar to pretending that "Vector(int)" is a valid identifier,
// and writing
//   type "Vector(int)" []int
//   var v "Vector(int)"
// All uses of Vector(int) will refer to the same "Vector(int)" type.
//
var v Vector(int)
```

Generic types can have methods.
The receiver type of a method must declare the same number of type
parameters as are declared in the receiver type's definition.
They are declared without the `type` keyword or any constraint.

```Go
// Push adds a value to the end of a vector.
func (v *Vector(T)) Push(x T) { *v = append(*v, x) }
```

The type parameters listed in a method declaration need not have the
same names as the type parameters in the type declaration.
In particular, if they are not used by the method, they can be `_`.

A generic type can refer to itself in cases where a type can
ordinarily refer to itself, but when it does so the type arguments
must be the type parameters, listed in the same order.
This restriction prevents infinite recursion of type instantiation.

```Go
// List is a linked list of values of type T.
type List(type T) struct {
	next *List(T) // this reference to List(T) is OK
	val  T
}

// This type is INVALID.
type P(type T1, T2) struct {
	F *P(T2, T1) // INVALID; must be (T1, T2)
}
```

This restriction applies to both direct and indirect references.

```Go
// ListHead is the head of a linked list.
type ListHead(type T) struct {
	head *ListElement(T)
}

// ListElement is an element in a linked list with a head.
// Each element points back to the head.
type ListElement(type T) struct {
	next *ListElement(T)
	val  T
	// Using ListHead(T) here is OK.
	// ListHead(T) refers to ListElement(T) refers to ListHead(T).
	// Using ListHead(int) would not be OK, as ListHead(T)
	// would have an indirect reference to ListHead(int).
	head *ListHead(T)
}
```

(Note: with more understanding of how people want to write code, it
may be possible to relax this rule to permit some cases that use
different type arguments.)

The type parameter of a generic type may have constraints.

```Go
// StringableVector is a slice of some type, where the type
// must have a String method.
type StringableVector(type T Stringer) []T

func (s StringableVector(T)) String() string {
	var sb strings.Builder
	for i, v := range s {
		if i > 0 {
			sb.WriteString(", ")
		}
		// It's OK to call v.String here because v is of type T
		// and T's constraint is Stringer.
		sb.WriteString(v.String())
	}
	return sb.String()
}
```

### Methods may not take additional type arguments

Although methods of a generic type may use the type's parameters,
methods may not themselves have additional type parameters.
Where it would be useful to add type arguments to a method, people
will have to write a suitably parameterized top-level function.

There is more discussion of this in [the issues
section](#No-parameterized-methods).

### Operators

As we've seen, we are using interface types as constraints.
Interface types provide a set of methods, and nothing else.
This means that with what we've seen so far, the only thing that
generic functions can do with values of type parameters, other than
operations that are permitted for any type, is call methods.

However, method calls are not sufficient for everything we want to
express.
Consider this simple function that returns the smallest element of a
slice of values, where the slice is assumed to be non-empty.

```Go
// This function is INVALID.
func Smallest(type T)(s []T) T {
	r := s[0] // panic if slice is empty
	for _, v := range s[1:] {
		if v < r { // INVALID
			r = v
		}
	}
	return r
}
```

Any reasonable generics implementation should let you write this
function.
The problem is the expression `v < r`.
This assumes that `T` supports the `<` operator, but `T` has no
constraint.
Without a constraint the function `Smallest` can only use operations
that are available for all types, but not all Go types support `<`.
Unfortunately, since `<` is not a method, there is no obvious way to
write a constraint&mdash;an interface type&mdash;that permits `<`.

We need a way to write a constraint that accepts only types that
support `<`.
In order to do that, we observe that, aside from two exceptions that
we will discuss later, all the arithmetic, comparison, and logical
operators defined by the language may only be used with types that are
predeclared by the language, or with defined types whose underlying
type is one of those predeclared types.
That is, the operator `<` can only be used with a predeclared type
such as `int` or `float64`, or a defined type whose underlying type is
one of those types.
Go does not permit using `<` with a composite type or with an
arbitrary defined type.

This means that rather than try to write a constraint for `<`, we can
approach this the other way around: instead of saying which operators
a constraint should support, we can say which (underlying) types a
constraint should accept.

#### Type lists in constraints

An interface type used as a constraint may list explicit types that
may be used as type arguments.
This is done using the `type` keyword followed by a comma-separated
list of types.

For example:

```Go
// SignedInteger is a type constraint that permits any
// signed integer type.
type SignedInteger interface {
	type int, int8, int16, int32, int64
}
```

The `SignedInteger` constraint specifies that the type argument
must be one of the listed types.
More precisely, the underlying type of the type argument must be
identical to the underlying type of one of the types in the type
list.
This means that `SignedInteger` will accept the listed integer types,
and will also accept any type that is defined as one of those types.

When a generic function uses a type parameter with one of these
constraints, it may use any operation that is permitted by all of the
listed types.
This can be an operation like `<`, `range`, `<-`, and so forth.
If the function can be compiled successfully using each type listed in
the constraint, then the operation is permitted.

A constraint may only have one type list.

For the `Smallest` example shown earlier, we could use a constraint
like this:

```Go
package constraints

// Ordered is a type constraint that matches any ordered type.
// An ordered type is one that supports the <, <=, >, and >= operators.
type Ordered interface {
	type int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64,
		string
}
```

In practice this constraint would likely be defined and exported in a
new standard library package, `constraints`, so that it could be used
by function and type definitions.

Given that constraint, we can write this function, now valid:

```Go
// Smallest returns the smallest element in a slice.
// It panics if the slice is empty.
func Smallest(type T constraints.Ordered)(s []T) T {
	r := s[0] // panics if slice is empty
	for _, v := range s[1:] {
		if v < r {
			r = v
		}
	}
	return r
}
```

#### Comparable types in constraints

Earlier we mentioned that there are two exceptions to the rule that
operators may only be used with types that are predeclared by the
language.
The exceptions are `==` and `!=`, which are permitted for struct,
array, and interface types.
These are useful enough that we want to be able to write a constraint
that accepts any comparable type.

To do this we introduce a new predeclared type constraint:
`comparable`.
A type parameter with the `comparable` constraint accepts as a type
argument any comparable type.
It permits the use of `==` and `!=` with values of that type parameter.

For example, this function may be instantiated with any comparable
type:

```Go
// Index returns the index of x in s, or -1 if not found.
func Index(type T comparable)(s []T, x T) int {
	for i, v := range s {
		// v and x are type T, which has the comparable
		// constraint, so we can use == here.
		if v == x {
			return i
		}
	}
	return -1
}
```

Since `comparable`, like all constraints, is an interface type, it can
be embedded in another interface type used as a constraint:

```Go
// ComparableHasher is a type constraint that matches all
// comparable types with a Hash method.
type ComparableHasher interface {
	comparable
	Hash() uintptr
}
```

The constraint `ComparableHasher` is implemented by any type that is
comparable and also has a `Hash() uintptr` method.
A generic function that uses `ComparableHasher` as a constraint can
compare values of that type and can call the `Hash` method.

#### Type lists in interface types

Interface types with type lists may only be used as constraints on
type parameters.
They may not be used as ordinary interface types.
The same is true of the predeclared interface type `comparable`.

This restriction may be lifted in future language versions.
An interface type with a type list may be useful as a form of sum
type, albeit one that can have the value `nil`.
Some alternative syntax would likely be required to match on identical
types rather than on underlying types; perhaps `type ==`.
For now, this is not permitted.

### Function argument type inference

In many cases, when calling a function with type parameters, we can
use type inference to avoid having to explicitly write out the type
arguments.

Go back to [the example](#Type-parameters) of a call to the simple
`Print` function:

```Go
	Print(int)([]int{1, 2, 3})
```

The type argument `int` in the function call can be inferred from the
type of the non-type argument.

This can only be done when all the function's type parameters are used
for the types of the function's (non-type) input parameters.
If there are some type parameters that are used only for the
function's result parameter types, or only in the body of the
function, then our algorithm does not infer the type arguments for the
function, since there is no value from which to infer the types.

When the function's type arguments can be inferred, the language uses
type unification.
On the caller side we have the list of types of the actual (non-type)
arguments, which for the `Print` example is simply `[]int`.
On the function side is the list of the types of the function's
non-type parameters, which for `Print` is `[]T`.
In the lists, we discard respective arguments for which the function
side does not use a type parameter.
We must then unify the remaining argument types.

Type unification is a two-pass algorithm.
In the first pass, we ignore untyped constants on the caller side and
their corresponding types in the function definition.

We compare corresponding types in the lists.
Their structure must be identical, except that type parameters on the
function side match the type that appears on the caller side at the
point where the type parameter occurs.
If the same type parameter appears more than once on the function
side, it will match multiple argument types on the caller side.
Those caller types must be identical, or type unification fails, and
we report an error.

After the first pass, we check any untyped constants on the caller
side.
If there are no untyped constants, or if the type parameters in the
corresponding function types have matched other input types, then
type unification is complete.

Otherwise, for the second pass, for any untyped constants whose
corresponding function types are not yet set, we determine the default
type of the untyped constant in [the usual
way](https://golang.org/ref/spec#Constants).
Then we run the type unification algorithm again, this time with no
untyped constants.

In this example

```Go
	s1 := []int{1, 2, 3}
	Print(s1)
```

we compare `[]int` with `[]T`, match `T` with `int`, and we are done.
The single type parameter `T` is `int`, so we infer that the call to
`Print` is really a call to `Print(int)`.

For a more complex example, consider

```Go
// Map calls the function f on every element of the slice s,
// returning a new slice of the results.
func Map(type F, T)(s []F, f func(F) T) []T {
	r := make([]T, len(s))
	for i, v := range s {
		r[i] = f(v)
	}
	return r
}
```

The two type parameters `F` and `T` are both used for input
parameters, so type inference is possible.
In the call

```Go
	strs := Map([]int{1, 2, 3}, strconv.Itoa)
```

we unify `[]int` with `[]F`, matching `F` with `int`.
We unify the type of `strconv.Itoa`, which is `func(int) string`,
with `func(F) T`, matching `F` with `int` and `T` with `string`.
The type parameter `F` is matched twice, both times with `int`.
Unification succeeds, so the call written as `Map` is a call of
`Map(int, string)`.

To see the untyped constant rule in effect, consider:

```Go
// NewPair returns a pair of values of the same type.
func NewPair(type F)(f1, f2 F) *Pair(F) { ... }
```

In the call `NewPair(1, 2)` both arguments are untyped constants, so
both are ignored in the first pass.
There is nothing to unify.
We still have two untyped constants after the first pass.
Both are set to their default type, `int`.
The second run of the type unification pass unifies `F` with
`int`, so the final call is `NewPair(int)(1, 2)`.

In the call `NewPair(1, int64(2))` the first argument is an untyped
constant, so we ignore it in the first pass.
We then unify `int64` with `F`.
At this point the type parameter corresponding to the untyped constant
is fully determined, so the final call is `NewPair(int64)(1,
int64(2))`.

In the call `NewPair(1, 2.5)` both arguments are untyped constants,
so we move on the second pass.
This time we set the first constant to `int` and the second to
`float64`.
We then try to unify `F` with both `int` and `float64`, so unification
fails, and we report a compilation error.

Note that type inference is done without regard to constraints.
First we use type inference to determine the type arguments to use for
the function, and then, if that succeeds, we check whether those type
arguments implement the constraints (if any).

Note that after successful type inference, the compiler must still
check that the arguments can be assigned to the parameters, as for any
function call.

(Note: type inference is a convenience feature.
Although we think it is an important feature, it does not add any
functionality to the design, only convenience in using it.
It would be possible to omit it from the initial implementation, and
see whether it seems to be needed.
That said, this feature doesn't require additional syntax, and
produces more readable code.)

### Using types that refer to themselves in constraints

It can be useful for a generic function to require a type argument
with a method whose argument is the type itself.
For example, this arises naturally in comparison methods.
(Note that we are talking about methods here, not operators.)
Suppose we want to write an `Index` method that uses an `Equal` method
to check whether it has found the desired value.
We would like to write that like this:

```Go
// Index returns the index of e in s, or -1 if not found.
func Index(type T Equaler)(s []T, e T) int {
	for i, v := range s {
		if e.Equal(v) {
			return i
		}
	}
	return -1
}
```

In order to write the `Equaler` constraint, we have to write a
constraint that can refer to the type argument being passed in.
There is no way to do that directly, but what we can do is write an
interface type that use a type parameter.

```Go
// Equaler is a type constraint for types with an Equal method.
type Equaler(type T) interface {
	Equal(T) bool
}
```

To make this work, `Index` will pass `T` as the type argument to
`Equaler`.
The rule is that if a type contraint has a single type parameter, and
it is used in a function's type parameter list without an explicit
type argument, then the type argument is the type parameter being
constrained.
In other words, in the definition of `Index` above, the constraint
`Equaler` is treated as `Equaler(T)`.

This version of `Index` would be used with a type like `equalInt`
defined here:

```Go
// equalInt is a version of int that implements Equaler.
type equalInt int

// The Equal method lets equalInt implement the Equaler constraint.
func (a equalInt) Equal(b equalInt) bool { return a == b }

// indexEqualInts returns the index of e in s, or -1 if not found.
func indexEqualInt(s []equalInt, e equalInt) int {
	return Index(equalInt)(s, e)
}
```

In this example, when we pass `equalInt` to `Index`, we check whether
`equalInt` implements the constraint `Equaler`.
Since `Equaler` has a type parameter, we pass the type argument of
`Index`, which is `equalInt`, as the type argument to `Equaler`.
The constraint is, then, `Equaler(equalInt)`, which is satisfied
by any type with a method `Equal(equalInt) bool`.
The `equalInt` type has a method `Equal` that accepts a parameter of
type `equalInt`, so all is well, and the compilation succeeds.

### Mutually referencing type parameters

Within a single type parameter list, constraints may refer to any of
the other type parameters, even ones that are declared later in the
same list.
(The scope of a type parameter starts at the `type` keyword of the
parameter list and extends to the end of the enclosing function or
type declaration.)

For example, consider a generic graph package that contains generic
algorithms that work with graphs.
The algorithms use two types, `Node` and `Edge`.
`Node` is expected to have a method `Edges() []Edge`.
`Edge` is expected to have a method `Nodes() (Node, Node)`.
A graph can be represented as a `[]Node`.

This simple representation is enough to implement graph algorithms
like finding the shortest path.

```Go
package graph

// NodeConstraint is the type constraint for graph nodes:
// they must have an Edges method that returns the Edge's
// that connect to this Node.
type NodeConstraint(type Edge) interface {
	Edges() []Edge
}

// EdgeConstraint is the type constraint for graph edges:
// they must have a Nodes method that returns the two Nodes
// that this edge connects.
type EdgeConstraint(type Node) interface {
	Nodes() (from, to Node)
}

// Graph is a graph composed of nodes and edges.
type Graph(type Node NodeConstraint(Edge), Edge EdgeConstraint(Node)) struct { ... }

// New returns a new graph given a list of nodes.
func New(
	type Node NodeConstraint(Edge), Edge EdgeConstraint(Node)) (
	nodes []Node) *Graph(Node, Edge) {
	...
}

// ShortestPath returns the shortest path between two nodes,
// as a list of edges.
func (g *Graph(Node, Edge)) ShortestPath(from, to Node) []Edge { ... }
```

There are a lot of type arguments and instantiations here.
In the constraint on `Node` in `Graph`, the `Edge` being passed to the
type constraint `NodeConstraint` is the second type parameter of
`Graph`.
This instantiates `NodeConstraint` with the type parameter `Edge`, so
we see that `Node` must have a method `Edges` that returns a slice of
`Edge`, which is what we want.
The same applies to the constraint on `Edge`, and the same type
parameters and constraints are repeated for the function `New`.
We aren't claiming that this is simple, but we are claiming that it is
possible.

It's worth noting that while at first glance this may look like a
typical use of interface types, `Node` and `Edge` are non-interface
types with specific methods.
In order to use `graph.Graph`, the type arguments used for `Node` and
`Edge` have to define methods that follow a certain pattern, but they
don't have to actually use interface types to do so.
In particular, the methods do not return interface types.

For example, consider these type definitions in some other package:

```Go
// Vertex is a node in a graph.
type Vertex struct { ... }

// Edges returns the edges connected to v.
func (v *Vertex) Edges() []*FromTo { ... }

// FromTo is an edge in a graph.
type FromTo struct { ... }

// Nodes returns the nodes that ft connects.
func (ft *FromTo) Nodes() (*Vertex, *Vertex) { ... }
```

There are no interface types here, but we can instantiate
`graph.Graph` using the type arguments `*Vertex` and `*FromTo`.

```Go
var g = graph.New(*Vertex, *FromTo)([]*Vertex{ ... })
```

`*Vertex` and `*FromTo` are not interface types, but when used
together they define methods that implement the constraints of
`graph.Graph`.
Note that we couldn't pass plain `Vertex` or `FromTo` to `graph.New`,
since `Vertex` and `FromTo` do not implement the constraints.
The `Edges` and `Nodes` methods are defined on the pointer types
`*Vertex` and `*FromTo`; the types `Vertex` and `FromTo` do not have
any methods.

When we use a generic interface type as a constraint, we first
instantiate the type with the type argument(s) supplied in the type
parameter list, and then compare the corresponding type argument
against the instantiated constraint.
In this example, the `Node` type argument to `graph.New` has a
constraint `NodeConstraint(Edge)`.
When we call `graph.New` with a `Node` type argument of `*Vertex` and
a `Edge` type argument of `*FromTo`, in order to check the constraint
on `Node` the compiler instantiates `NodeConstraint` with the type
argument `*FromTo`.
That produces an instantiated constraint, in this case a requirement
that `Node` have a method `Edges() []*FromTo`, and the compiler
verifies that `*Vertex` satisfies that constraint.

Although `Node` and `Edge` do not have to be instantiated with
interface types, it is also OK to use interface types if you like.

```Go
type NodeInterface interface { Edges() []EdgeInterface }
type EdgeInterface interface { Nodes() (NodeInterface, NodeInterface) }
```

We could instantiate `graph.Graph` with the types `NodeInterface` and
`EdgeInterface`, since they implement the type constraints.
There isn't much reason to instantiate a type this way, but it is
permitted.

This ability for type parameters to refer to other type parameters
illustrates an important point: it should be a requirement for any
attempt to add generics to Go that it be possible to instantiate
generic code with multiple type arguments that refer to each other in
ways that the compiler can check.

### Pointer methods

There are cases where a generic function will only work as expected if
a type argument `A` has methods defined on the pointer type `*A`.
This happens when writing a generic function that expects to call a
method that modifies a value.

Consider this example of a function that expects a type `T` that has a
`Set(string)` method that initializes the value based on a string.

```Go
// Setter is a type constraint that requires that the type
// implement a Set method that sets the value from a string.
type Setter interface {
	Set(string)
}

// FromStrings takes a slice of strings and returns a slice of T,
// calling the Set method to set each returned value.
//
// Note that because T is only used for a result parameter,
// type inference does not work when calling this function.
// The type argument must be passed explicitly at the call site.
//
// This example compiles but is unlikely to work as desired.
func FromStrings(type T Setter)(s []string) []T {
	result := make([]T, len(s))
	for i, v := range s {
		result[i].Set(v)
	}
	return result
}
```

Now let's see some code in a different package (this example is
invalid).

```Go
// Settable is a integer type that can be set from a string.
type Settable int

// Set sets the value of *p from a string.
func (p *Settable) Set(s string) {
	i, _ := strconv.Atoi(s) // real code should not ignore the error
	*p = Settable(i)
}

func F() {
	// INVALID
	nums := FromStrings(Settable)([]string{"1", "2"})
	// Here we want nums to be []Settable{1, 2}.
	...
}
```

The goal is to use `FromStrings` to get a slice of type `[]Settable`.
Unfortunately, this example is not valid and will not compile.

The problem is that `FromStrings` requires a type that has a
`Set(string)` method.
The function `F` is trying to instantiate `FromStrings` with
`Settable`, but `Settable` does not have a `Set` method.
The type that has a `Set` method is `*Settable`.

So let's rewrite `F` to use `*Settable` instead.

```Go
func F() {
	// Compiles but does not work as desired.
	// This will panic at run time when calling the Set method.
	nums := FromStrings(*Settable)([]string{"1", "2"})
	...
}
```

This compiles but unfortunately it will panic at run time.
The problem is that `FromStrings` creates a slice of type `[]T`.
When instantiated with `*Settable`, that means a slice of type
`[]*Settable`.
When `FromStrings` calls `result[i].Set(v)`, that passes the pointer
stored in `result[i]` to the `Set` method.
That pointer is `nil`.
The `Settable.Set` method will be invoked with a `nil` receiver,
and will raise a panic due to a `nil` dereference error.

What we need is a way to write `FromStrings` such that it can take
the type `Settable` as an argument but invoke a pointer method.
To repeat, we can't use `Settable` because it doesn't have a `Set`
method, and we can't use `*Settable` because then we can't create a
slice of type `Settable`.

One approach that could work would be to use two different type
parameters: both `Settable` and `*Settable`.

```Go
package from

// Setter2 is a type constraint that requires that the type
// implement a Set method that sets the value from a string,
// and also requires that the type be a pointer to its type parameter.
type Setter2(type B) interface {
	Set(string)
	type *B
}

// FromStrings2 takes a slice of strings and returns a slice of T,
// calling the Set method to set each returned value.
//
// We use two different type parameters so that we can return
// a slice of type T but call methods on *T.
// The Setter2 constraint ensures that PT is a pointer to T.
func FromStrings2(type T interface{}, PT Setter2(T))(s []string) []T {
	result := make([]T, len(s))
	for i, v := range s {
		// The type of &result[i] is *T which is in the type list
		// of Setter2, so we can convert it to PT.
		p := PT(&result[i])
		// PT has a Set method.
		p.Set(v)
	}
	return result
}
```

We would call `FromStrings2` like this:

```Go
func F2() {
	// FromStrings2 takes two type parameters.
	// The second parameter must be a pointer to the first.
	// Settable is as above.
	nums := FromStrings2(Settable, *Settable)([]string{"1", "2"})
	// Now nums is []Settable{1, 2}.
	...
}
```

This approach works as expected, but it is awkward.
It forces `F2` to work around a problem in `FromStrings2` by passing
two type arguments.
The second type argument is required to be a pointer to the first type
argument.
This is a complex requirement for what seems like it ought to be a
reasonably simple case.

Another approach would be to pass in a function rather than calling a
method.

```Go
// FromStrings3 takes a slice of strings and returns a slice of T,
// calling the set function to set each returned value.
func FromStrings3(type T)(s []string, set func(*T, string)) []T {
	results := make([]T, len(s))
	for i, v := range s {
		set(&results[i], v)
	}
	return results
}
```

We would call `Strings3` like this:

```Go
func F3() {
	// FromStrings3 takes a function to set the value.
	// Settable is as above.
	nums := FromStrings3(Settable)([]string{"1", "2"},
		func(p *Settable, s string) { p.Set(s) })
	// Now nums is []Settable{1, 2}.
}
```

This approach also works as expected, but it is also awkward.
The caller has to pass in a function just to call the `Set` method.
This is the kind of boilerplate code that we would hope to avoid when
using generics.

Although these approaches are awkward, they do work.
That said, we suggest another feature to address this kind of issue: a
way to express constraints on the pointer to the type parameter,
rather than on the type parameter itself.
The way to do this is to write the type parameter as though it were a
pointer type: `(type *T Constraint)`.

Writing `*T` instead of `T` in a type parameter list changes two
things.
Let's assume that the type argument at the call site is `A`, and the
constraint is `Constraint` (this syntax may be used without a
constraint, but there is no reason to do so).

The first thing that changes is that `Constraint` is applied to `*A`
rather than `A`.
That is, `*A` must implement `Constraint`.
It's OK if `A` implements `Constraint`, but the requirement is that
`*A` implement it.
Note that if `Constraint` has any methods, this implies that `A` must
not be a pointer type: if `A` is a pointer type, then `*A` is a
pointer to a pointer, and such types never have any methods.

The second thing that changes is that within the body of the function,
any methods in `Constraint` are treated as though they were pointer
methods.
They may only be invoked on values of type `*T` or addressable values
of type `T`.

```Go
// FromStrings takes a slice of strings and returns a slice of T,
// calling the Set method to set each returned value.
//
// We write *T, meaning that given a type argument A,
// the pointer type *A must implement Setter.
//
// Note that because T is only used for a result parameter,
// type inference does not work when calling this function.
// The type argument must be passed explicitly at the call site.
func FromStrings(type *T Setter)(s []string) []T {
	result := make([]T, len(s))
	for i, v := range s {
		// result[i] is an addressable value of type T,
		// so it's OK to call Set.
		result[i].Set(v)
	}
	return result
}
```

Again, using `*T` here means that given a type argument `A`, the type
`*A` must implement the constraint `Setter`.
In this case, `Set` must be in the method set of `*A`.
Within `FromStrings`, using `*T` means that the `Set` method may only
be called on an addressable value of type `T`.

We can now use this as

```Go
func F() {
	// With the rewritten FromStrings, this is now OK.
	// *Settable implements Setter.
	nums := from.Strings(Settable)([]string{"1", "2"})
	// Here nums is []Settable{1, 2}.
	...
}
```

To be clear, using `type *T Setter` does not mean that the `Set`
method must only be a pointer method.
`Set` could still be a value method.
That would be OK because all value methods are also in the pointer
type's method set.
In this example that only makes sense if `Set` can be written as a
value method, which might be the case when defining the method on a
struct that contains pointer fields.

### Using generic types as unnamed function parameter types

When parsing an instantiated type as an unnamed function parameter
type, there is a parsing ambiguity.

```Go
var f func(x(T))
```

In this example we don't know whether the function has a single
unnamed parameter of the instantiated type `x(T)`, or whether this is
a named parameter `x` of the type `(T)` (written with parentheses).

We would prefer that this mean the former: an unnamed parameter of the
instantiated type `x(T)`.
This is not actually backward compatible with the current language,
where it means the latter.
However, the gofmt program currently rewrites `func(x(T))` to `func(x
T)`, so `func(x(T))` is very unusual in plain Go code.

Therefore, we propose that the language change so that `func(x(T))`
now means a single parameter of type `x(T)`.
This will potentially break some existing programs, but the fix will
be to simply run gofmt.
This will potentially change the meaning of programs that write
`func(x(T))`, that don't use gofmt, and that choose to introduce a
generic type `x` with the same name as a function parameter with a
parenthesized type.
We believe that such programs will be exceedingly rare.

Still, this is a risk, and if the risk seems too large we can avoid
making this change.

### Values of type parameters are not boxed

In the current implementations of Go, interface values always hold
pointers.
Putting a non-pointer value in an interface variable causes the value
to be _boxed_.
That means that the actual value is stored somewhere else, on the heap
or stack, and the interface value holds a pointer to that location.

In this design, values of generic types are not boxed.
For example, let's look back at our earlier example of
`from.Strings`.
When it is instantiated with type `Settable`, it returns a value of
type `[]Settable`.
For example, we can write

```Go
// Settable is an integer type that can be set from a string.
type Settable int

// Set sets the value of *p from a string.
func (p *Settable) Set(s string) (err error) {
	// same as above
}

func F() {
	// The type of nums is []Settable.
	nums, err := from.Strings(Settable)([]string{"1", "2"})
	if err != nil { ... }
	// Settable can be converted directly to int.
	// This will set first to 1.
	first := int(nums[0])
	...
}
```

When we call `from.Strings` with the type `Settable` we get back a
`[]Settable` (and an error).
The elements of that slice will be `Settable` values, which is to say,
they will be integers.
They will not be boxed, even though they were created and set by a
generic function.

Similarly, when a generic type is instantiated it will have the
expected types as components.

```Go
type Pair(type F1, F2) struct {
	first  F1
	second F2
}
```

When this is instantiated, the fields will not be boxed, and no
unexpected memory allocations will occur.
The type `Pair(int, string)` is convertible to `struct { first int;
second string }`.

### More on type lists

Let's return now to type lists to cover some less important details
that are still worth noting.
These are not additional rules or concepts, but are consequences of
how type lists work.

#### Both type lists and methods in constraints

A constraint may use both type lists and methods.

```Go
// StringableSignedInteger is a type constraint that matches any
// type that is both 1) defined as a signed integer type;
// 2) has a String method.
type StringableSignedInteger interface {
	type int, int8, int16, int32, int64
	String() string
}
```

This constraint permits any type whose underlying type is one of the
listed types, provided it also has a `String() string` method.
It's worth noting that although the `StringableSignedInteger`
constraint explicitly lists `int`, the type `int` will not itself be
permitted as a type argument, since `int` does not have a `String`
method.
An example of a type argument that would be permitted is `MyInt`,
defined as:

```Go
// MyInt is a stringable int.
type MyInt int

// The String method returns a string representation of mi.
func (mi MyInt) String() string {
	return fmt.Sprintf("MyInt(%d)", mi)
}
```

#### Composite types in constraints

A type in a constraint may be a type literal.

```Go
type byteseq interface {
	type string, []byte
}
```

The usual rules apply: the type argument for this constraint may be
`string` or `[]byte` or a type defined as one of those types; a
generic function with this constraint may use any operation permitted
by both `string` and `[]byte`.

The `byteseq` constraint permits writing generic functions that work
for either `string` or `[]byte` types.

```Go
// Join concatenates the elements of its first argument to create a
// single value. sep is placed between elements in the result.
// Join works for string and []byte types.
func Join(type T byteseq)(a []T, sep T) (ret T) {
	if len(a) == 0 {
		// Use the result parameter as a zero value;
		// see discussion of zero value in the Issues section.
		return ret
	}
	if len(a) == 1 {
		// We know that a[0] is either a string or a []byte.
		// We can append either a string or a []byte to a []byte,
		// producing a []byte. We can convert that []byte to
		// either a []byte (a no-op conversion) or a string.
		return T(append([]byte(nil), a[0]...))
	}
	// We can call len on sep because we can call len
	// on both string and []byte.
	n := len(sep) * (len(a) - 1)
	for _, v := range a {
		// Another case where we call len on string or []byte.
		n += len(v)
	}

	b := make([]byte, n)
	// We can call copy to a []byte with an argument of
	// either string or []byte.
	bp := copy(b, a[0])
	for _, s := range a[1:] {
		bp += copy(b[bp:], sep)
		bp += copy(b[bp:], s)
	}
	// As above, we can convert b to either []byte or string.
	return T(b)
}
```

#### Type parameters in type lists

A type literal in a constraint can refer to type parameters of the
constraint.
In this example, the generic function `Map` takes two type parameters.
The first type parameter is required to have an underlying type that
is a slice of the second type parameter.
There are no constraints on the second slice parameter.

```Go
// SliceConstraint is a type constraint that matches a slice of
// the type parameter.
type SliceConstraint(type T) interface {
	type []T
}

// Map takes a slice of some element type and a transformation function,
// and returns a slice of the function applied to each element.
// Map returns a slice that is the same type as its slice argument,
// even if that is a defined type.
func Map(type S SliceConstraint(E), E interface{})(s S, f func(E) E) S {
	r := make(S, len(s))
	for i, v := range s {
		r[i] = f(v)
	}
	return r
}

// MySlice is a simple defined type.
type MySlice []int

// DoubleMySlice takes a value of type MySlice and returns a new
// MySlice value with each element doubled in value.
func DoubleMySlice(s MySlice) MySlice {
	v := Map(MySlice, int)(s, func(e int) int { return 2 * e })
	// Here v has type MySlice, not type []int.
	return v
}
```

#### Type conversions

In a function with two type parameters `From` and `To`, a value of
type `From` may be converted to a value of type `To` if all the
types accepted by `From`'s constraint can be converted to all the
types accepted by `To`'s constraint.
If either type parameter does not accept types, then type conversions
are not permitted.

This is a consequence of the general rule that a generic function may
use any operation that is permitted by all types listed in the type
list.

For example:

```Go
type integer interface {
	type int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr
}

func Convert(type To, From integer)(from From) To {
	to := To(from)
	if From(to) != from {
		panic("conversion out of range")
	}
	return to
}
```

The type conversions in `Convert` are permitted because Go permits
every integer type to be converted to every other integer type.

#### Untyped constants

Some functions use untyped constants.
An untyped constant is permitted with a value of some type parameter
if it is permitted with every type accepted by the type parameter's
constraint.

As with type conversions, this is a consequence of the general rule
that a generic function may use any operation that is permitted by all
types listed in the type list.

```Go
type integer interface {
	type int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr
}

func Add10(type T integer)(s []T) {
	for i, v := range s {
		s[i] = v + 10 // OK: 10 can convert to any integer type
	}
}

// This function is INVALID.
func Add1024(type T integer)(s []T) {
	for i, v := range s {
		s[i] = v + 1024 // INVALID: 1024 not permitted by int8/uint8
	}
}
```

#### Notes on composite types in type lists

It's not clear that we fully understand the use of composite types in
type lists.
For example, consider

```Go
type structField interface {
	type struct { a int; x int },
		struct { b int; x float64 },
		struct { c int; x uint64 }
}

func IncrementX(type T structField)(p *T) {
	v := p.x
	v++
	p.x = v
}
```

This constraint on the type parameter of `IncrementX` is such that
every valid type argument is a struct with a field `x` of some numeric
type.
Therefore, it is tempting to say that `IncrementX` is a valid
function.
This would mean that the type of `v` is a type based on a type
parameter, with an implicit constraint of `interface { type int,
float64, uint64 }`.
This could get fairly complex, and there may be details here that we
don't understand.

The initial implementation may not support composite types in type
lists at all, although that would make the `Join` example shown
earlier invalid.

#### Type lists in embedded constraints

When a constraint embeds another constraint, the type list of the
final constraint is the intersection of all the type lists involved.
If there are multiple embedded types, intersection preserves the
property that any  type argument must satisfy the requirements of all
embedded types.

```Go
// Addable is types that support the + operator.
type Addable interface {
	type int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64, complex64, complex128,
		string
}

// Byteseq is a byte sequence: either string or []byte.
type Byteseq interface {
	type string, []byte
}

// AddableByteseq is a byte sequence that supports +.
// This is every type is that is both Addable and Byteseq.
// In other words, just the type string.
type AddableByteseq interface {
	Addable
	Byteseq
}
```

#### General notes on type lists

It may seem awkward to explicitly list types in a constraint, but it
is clear both as to which type arguments are permitted at the call
site, and which operations are permitted by the generic function.

If the language later changes to support operator methods (there are
no such plans at present), then constraints will handle them as they
do any other kind of method.

There will always be a limited number of predeclared types, and a
limited number of operators that those types support.
Future language changes will not fundamentally change those facts, so
this approach will continue to be useful.

This approach does not attempt to handle every possible operator.
It's not clear that it works well for composite types.
The expectation is that those will be handled using composite types in
generic function and type declarations, rather than requiring
composite types as a type argument.
For example, we expect functions that want to index into a slice to be
parameterized on the slice element type `T`, and to use parameters or
variables of type `[]T`.

As shown in the `DoubleMySlice` example above, this approach makes it
awkward to declare generic functions that accept and return a
composite type and want to return the same result type as their
argument type.
Defined composite types are not common, but they do arise.
This awkwardness is a weakness of this approach.

### Reflection

We do not propose to change the reflect package in any way.
When a type or function is instantiated, all of the type parameters
will become ordinary non-generic types.
The `String` method of a `reflect.Type` value of an instantiated type
will return the name with the type arguments in parentheses.
For example, `List(int)`.

It's impossible for non-generic code to refer to generic code without
instantiating it, so there is no reflection information for
uninstantiated generic types or functions.

### Implementation

Russ Cox [famously observed](https://research.swtch.com/generic) that
generics require choosing among slow programmers, slow compilers, or
slow execution times.

We believe that this design permits different implementation choices.
Code may be compiled separately for each set of type arguments, or it
may be compiled as though each type argument is handled similarly to
an interface type with method calls, or there may be some combination
of the two.

In other words, this design permits people to stop choosing slow
programmers, and permits the implementation to decide between slow
compilers (compile each set of type arguments separately) or slow
execution times (use method calls for each operation on a value of a
type argument).

### Summary

While this document is long and detailed, the actual design reduces to
a few major points.

* Functions and types can have type parameters, which are defined
  using optional constraints, which are interface types.
* Constraints describe the methods required and the types permitted
  for a type argument.
* Constraints describe the methods and operations permitted for a type
  parameter.
* Type inference will often permit omitting type arguments when
  calling functions with type parameters.

This design is completely backward compatible, except for a suggested
change in the meaning of `func F(x(T))`.

We believe that this design addresses people's needs for generic
programming in Go, without making the language any more complex than
necessary.

We can't truly know the impact on the language without years of
experience with this design.
That said, here are some speculations.

#### Complexity

One of the great aspects of Go is its simplicity.
Clearly this design makes the language more complex.

We believe that the increased complexity is small for people reading
well written generic code, rather than writing it.
Naturally people must learn the new syntax for declaring type
parameters.
This new syntax, and the new support for type lists in interfaces, are
the only new syntactic constructs in this design.
The code within a generic function reads like ordinary Go code, as can
be seen in the examples below.
It is an easy shift to go from `[]int` to `[]T`.
Type parameter constraints serve effectively as documentation,
describing the type.

We expect that most packages will not define generic types or
functions, but many packages are likely to use generic types or
functions defined elsewhere.
In the common case, generic functions work exactly like non-generic
functions: you simply call them.
Type inference means that you do not have to write out the type
arguments explicitly.
The type inference rules are designed to be unsurprising: either the
type arguments are deduced correctly, or the call fails and requires
explicit type parameters.
Type inference uses type identity, with no attempt to resolve two
types that are similar but not identical, which removes significant
complexity.

Packages using generic types will have to pass explicit type
arguments.
The syntax for this is familiar.
The only change is passing arguments to types rather than only to
functions.

In general, we have tried to avoid surprises in the design.
Only time will tell whether we succeeded.

#### Pervasiveness

We expect that a few new packages will be added to the standard
library.
A new `slices` packages will be similar to the existing bytes and
strings packages, operating on slices of any element type.
New `maps` and `chans` packages will provide simple algorithms that
are currently duplicated for each element type.
A `set` package may be added.

A new `constraints` package will provide standard constraints, such as
constraints that permit all integer types or all numeric types.

Packages like `container/list` and `container/ring`, and types like
`sync.Map` and `sync/atomic.Value`, will be updated to be compile-time
type-safe, either using new names or new versions of the packages.

The `math` package will be extended to provide a set of simple
standard algorithms for all numeric types, such as the ever popular
`Min` and `Max` functions.

We may add generic variants to the `sort` package.

It is likely that new special purpose compile-time type-safe container
types will be developed.

We do not expect approaches like the C++ STL iterator types to become
widely used.
In Go that sort of idea is more naturally expressed using an interface
type.
In C++ terms, using an interface type for an iterator can be seen as
carrying an abstraction penalty, in that run-time efficiency will be
less than C++ approaches that in effect inline all code; we believe
that Go programmers will continue to find that sort of penalty to be
acceptable.

As we get more container types, we may develop a standard `Iterator`
interface.
That may in turn lead to pressure to modify the language to add some
mechanism for using an `Iterator` with the `range` clause.
That is very speculative, though.

#### Efficiency

It is not clear what sort of efficiency people expect from generic
code.

Generic functions, rather than generic types, can probably be compiled
using an interface-based approach.
That will optimize compile time, in that the function is only compiled
once, but there will be some run time cost.

Generic types may most naturally be compiled multiple times for each
set of type arguments.
This will clearly carry a compile time cost, but there shouldn't be
any run time cost.
Compilers can also choose to implement generic types similarly to
interface types, using special purpose methods to access each element
that depends on a type parameter.

Only experience will show what people expect in this area.

#### Omissions

We believe that this design covers the basic requirements for
generic programming.
However, there are a number of programming constructs that are not
supported.

* No specialization.
  There is no way to write multiple versions of a generic function
  that are designed to work with specific type arguments.
* No metaprogramming.
  There is no way to write code that is executed at compile time to
  generate code to be executed at run time.
* No higher level abstraction.
  There is no way to speak about a function with type arguments other
  than to call it or instantiate it.
  There is no way to speak about a generic type other than to
  instantiate it.
* No general type description.
  In order to use operators in a generic function, constraints list
  specific types, rather than describing the characteristics that a
  type must have.
  This is easy to understand but may be limiting at times.
* No covariance or contravariance of function parameters.
* No operator methods.
  You can write a generic container that is compile-time type-safe,
  but you can only access it with ordinary methods, not with syntax
  like `c[k]`.
* No currying.
  There is no way to specify only some of the type arguments, other
  than by using a helper function or a wrapper type.
* No variadic type parameters.
  There is no support for variadic type parameters, which would permit
  writing a single generic function that takes different numbers of
  both type parameters and regular parameters.
* No adaptors.
  There is no way for a constraint to define adaptors that could be
  used to support type arguments that do not already implement the
  constraint, such as, for example, defining an `==` operator in terms
  of an `Equal` method, or vice-versa.
* No parameterization on non-type values such as constants.
  This arises most obviously for arrays, where it might sometimes be
  convenient to write `type Matrix(type n int) [n][n]float64`.
  It might also sometimes be useful to specify significant values for
  a container type, such as a default value for elements.

#### Issues

There are some issues with this design that deserve a more detailed
discussion.
We think these issues are relatively minor compared to the design as a
whole, but they still deserve a complete hearing and discussion.

##### The zero value

This design has no simple expression for the zero value of a type
parameter.
For example, consider this implementation of optional values that uses
pointers:

```Go
type Optional(type T) struct {
	p *T
}

func (o Optional(T)) Val() T {
	if o.p != nil {
		return *o.p
	}
	var zero T
	return zero
}
```

In the case where `o.p == nil`, we want to return the zero value of
`T`, but we have no way to write that.
It would be nice to be able to write `return nil`, but that wouldn't
work if `T` is, say, `int`; in that case we would have to write
`return 0`.
And, of course, there is no way to write a constraint to support
either `return nil` or `return 0`.

Some approaches to this are:

* Use `var zero T`, as above, which works with the existing design
  but requires an extra statement.
* Use `*new(T)`, which is cryptic but works with the existing
  design.
* For results only, name the result parameter `_`, and use a naked
  `return` statement to return the zero value.
* Extend the design to permit using `nil` as the zero value of any
  generic type (but see [issue 22729](https://golang.org/issue/22729)).
* Extend the design to permit using `T{}`, where `T` is a type
  parameter, to indicate the zero value of the type.
* Change the language to permit using `_` on the right hand of an
  assignment (including `return` or a function call) as proposed in
  [issue 19642](https://golang.org/issue/19642).
* Change the language to permit `return ...` to return zero values of
  the result types, as proposed in
  [issue 21182](https://golang.org/issue/21182).

We feel that more experience with this design is needed before
deciding what, if anything, to do here.

##### Lots of Irritating Silly Parentheses

Calling a function with type parameters requires an additional list of
type arguments if the type arguments can not be inferred.
If the function returns a function, and we call that, we get still
more parentheses.

```Go
	F(int, float64)(x, y)(s)
```

We experimented with other syntaxes, such as using a colon to separate
the type arguments from the regular arguments.
The current design seems to us to be the nicest, but perhaps something
better is possible.

##### Defined composite types

As [discussed above](#Type-parameters-in-type-lists), an extra type
parameter is required for a function to take, as an argument, a
defined type whose underlying type is a composite type, and to return
the same defined type as a result.

For example, this function will map a function across a slice.

```Go
// Map applies f to each element of s, returning a new slice
// holding the results.
func Map(type T)(s []T, f func(T) T) []T {
	r := make([]T, len(s))
	for i, v := range s {
		r[i] = f(v)
	}
	return r
}
```

However, when called on a defined type, it will return a slice of the
element type of that type, rather than the defined type itself.

```Go
// MySlice is a defined type.
type MySlice []int

// DoubleMySlice returns a new MySlice whose elements are twice
// that of the corresponding elements of s.
func DoubleMySlice(s MySlice) MySlice {
	s2 := Map(s, func(e int) int { return 2 * e })
	// Here s2 is type []int, not type MySlice.
	return MySlice(s2)
}
```

As [discussed above](#Type-parameters-in-type-lists), this can be
avoided by using an extra type parameter for `Map`, and using
constraints that describe the required relationship between the slice
and element types.
This works but is awkward.

##### Identifying the matched predeclared type

The design doesn't provide any way to test the underlying type matched
by a type argument.
Code can test the actual type argument through the somewhat awkward
approach of converting to an empty interface type and using a type
assertion or a type switch.
But that lets code test the actual type argument, which is not the
same as the underlying type.

Here is an example that shows the difference.

```Go
type Float interface {
	type float32, float64
}

func NewtonSqrt(type T Float)(v T) T {
	var iterations int
	switch (interface{})(v).(type) {
	case float32:
		iterations = 4
	case float64:
		iterations = 5
	default:
		panic(fmt.Sprintf("unexpected type %T", v))
	}
	// Code omitted.
}

type MyFloat float32

var G = NewtonSqrt(MyFloat(64))
```

This code will panic when initializing `G`, because the type of `v` in
the `NewtonSqrt` function will be `MyFloat`, not `float32` or
`float64`.
What this function actually wants to test is not the type of `v`, but
the type that `v` matched in the constraint.

One way to handle this would be to permit type switches on the type
`T`, with the proviso that the type `T` would always match a type
defined in the constraint.
This kind of type switch would only be permitted if the constraint
lists explicit types, and only types listed in the constraint would be
permitted as cases.

##### No way to express convertibility

The design has no way to express convertibility between two different
type parameters.
For example, there is no way to write this function:

```Go
// Copy copies values from src to dst, converting them as they go.
// It returns the number of items copied, which is the minimum of
// the lengths of dst and src.
// This implementation is INVALID.
func Copy(type T1, T2)(dst []T1, src []T2) int {
	for i, x := range src {
		if i > len(dst) {
			return i
		}
		dst[i] = T1(x) // INVALID
	}
	return len(src)
}
```

The conversion from type `T2` to type `T1` is invalid, as there is no
constraint on either type that permits the conversion.
Worse, there is no way to write such a constraint in general.
In the particular case that both `T1` and `T2` can require some type
list, then this function can be written as described earlier when
discussing [type conversions using type lists](#Type-conversions).
But, for example, there is no way to write a constraint for the case
in which `T1` is an interface type and `T2` is a type that implements
that interface.

It's worth noting that if `T1` is an interface type then this can be
written using a conversion to the empty interface type and a type
assertion, but this is, of course, not compile-time type-safe.

```Go
// Copy copies values from src to dst, converting them as they go.
// It returns the number of items copied, which is the minimum of
// the lengths of dst and src.
func Copy(type T1, T2)(dst []T1, src []T2) int {
	for i, x := range src {
		if i > len(dst) {
			return i
		}
		dst[i] = (interface{})(x).(T1)
	}
	return len(src)
}
```

##### No parameterized methods

This design draft does not permit methods to declare type parameters
that are specific to the method.
The receiver may have type parameters, but the method not add any type
parameters.

In Go, one of the main roles of methods is to permit types to
implement interfaces.
It is not clear whether it is reasonably possible to permit
parameterized methods to implement interfaces.
For example, consider this code, which uses the obvious syntax for
parameterized methods.
This code uses multiple packages to make the problem clearer.

```Go
package p1

// S is a type with a parameterized method M.
type S struct{}

// Identity is a simple identity method that works for any type.
func (S) Identity(type T)(v T) T { return v }

package p2

// HasIdentity is an interface that matches any type with a
// parameterized Identity method.
type HasIdentity interface {
	Identity(type T)(T) T
}

package p3

import "p2"

// CheckIdentity checks the Identity method if it exists.
// Note that although this function calls a parameterized method,
// this function is not itself parameterized.
func CheckIdentity(v interface{}) {
	if vi, ok := v.(p2.HasIdentity); ok {
		if got := vi.Identity(int)(0); got != 0 {
			panic(got)
		}
	}
}

package p4

import (
	"p1"
	"p3"
)

// CheckSIdentity passes an S value to CheckIdentity.
func CheckSIdentity() {
	p3.CheckIdentity(p1.S{})
}
```

In this example, we have a type `S` with a parameterized method and a
type `HasIdentity` that also has a parameterized method.
`S` implements `HasIdentity`.
Therefore, the function `p3.CheckIdentity` can call `vi.Identity` with
an `int` argument, which in this example will be a call to
`S.Identity(int)`.
But package p3 does not know anything about the type `p1.S`.
There may be no other call to `S.Identity` elsewhere in the program.
We need to instantiate `S.Identity(int)` somewhere, but how?

We could instantiate it at link time, but in the general case that
requires the linker to traverse the complete call graph of the program
to determine the set of types that might be passed to `CheckIdentity`.
And even that traversal is not sufficient in the general case when
type reflection gets involved, as reflection might look up methods
based on strings input by the user.
So in general instantiating parameterized methods in the linker might
require instantiating every parameterized method for every possible
type argument, which seems untenable.

Or, we could instantiate it run time.
In general this means using some sort of JIT, or compiling the code to
use some sort of reflection based approach.
Either approach would be very complex to implement, and would be
surprisingly slow at run time.

Or, we could decide that parameterized methods do not, in fact,
implement interfaces, but then it's much less clear why we need
methods at all.
If we disregard interfaces, any parameterized method can be
implemented as a parameterized function.

So while parameterized methods seem clearly useful at first glance, we
would have to decide what they mean and how to implement that.

#### Discarded ideas

This design is not perfect, and it will be further refined as we gain
experience with it.
That said, there are many ideas that we've already considered in
detail.
This section lists some of those ideas in the hopes that it will help
to reduce repetitive discussion.
The ideas are presented in the form of a FAQ.

##### What happened to contracts?

An earlier draft design of generics implemented constraints using a
new language construct called contracts.
Type lists appeared only in contracts, rather than on interface
types.
However, many people had a hard time understanding the difference
between contracts and interface types.
It also turned out that contracts could be represented as a set of
corresponding interfaces; thus there was no loss in expressive power
without contracts.
We decided to simplify the approach to use only interface types.

##### Why not use methods instead of type lists?

_Type lists are weird._
_Why not write methods for all operators?_

It is possible to permit operator tokens as method names, leading to
methods such as `+(T) T`.
Unfortunately, that is not sufficient.
We would need some mechanism to describe a type that matches any
integer type, for operations such as shifts `<<(integer) T` and
indexing `[](integer) T` which are not restricted to a single int
type.
We would need an untyped boolean type for operations such as `==(T)
untyped bool`.
We would need to introduce new notation for operations such as
conversions, or to express that one may range over a type, which would
likely require some new syntax.
We would need some mechanism to describe valid values of untyped
constants.
We would have to consider whether support for `<(T) bool` means that a
generic function can also use `<=`, and similarly whether support for
`+(T) T` means that a function can also use `++`.
It might be possible to make this approach work but it's not
straightforward.
The approach used in this design seems simpler and relies on only one
new syntactic construct (type lists) and one new name (`comparable`).

##### Why not put type parameters on packages?

We investigated this extensively.
It becomes problematic when you want to write a `list` package, and
you want that package to include a `Transform` function that converts
a `List` of one element type to a `List` of another element type.
It's very awkward for a function in one instantiation of a package to
return a type that requires a different instantiation of the same
package.

It also confuses package boundaries with type definitions.
There is no particular reason to think that the uses of generic types
will break down neatly into packages.
Sometimes they will, sometimes they won't.

##### Why not use the syntax `F<T>` like C++ and Java?

When parsing code within a function, such as `v := F<T>`, at the point
of seeing the `<` it's ambiguous whether we are seeing a type
instantiation or an expression using the `<` operator.
Resolving that requires effectively unbounded lookahead.
In general we strive to keep the Go parser efficient.

##### Why not use the syntax `F[T]`?

When parsing a type declaration `type A [T] int` it's ambiguous
whether this is a generic type defined (uselessly) as `int` or whether
it is an array type with `T` elements.
However, this could be addressed by requiring `type A [type T] int`
for a generic type.

Parsing declarations like `func f(A[T]int)` (a single parameter of
type `[T]int`) and `func f(A[T], int)` (two parameters, one of type
`A[T]` and one of type `int`) show that some additional parsing
lookahead is required.
This is solvable but adds parsing complexity.

The language generally permits a trailing comma in a comma-separated
list, so `A[T,]` should be permitted if `A` is a generic type, but
normally would not be permitted for an index expression.
However, the parser can't know whether `A` is a generic type or a
value of slice, array, or map type, so this parse error can not be
reported until after type checking is complete.
Again, solvable but complicated.

More generally, we felt that the square brackets were too intrusive on
the page and that parentheses were more Go like.
We will reevaluate this decision as we gain more experience.

##### Why not use `F«T»`?

We considered it but we couldn't bring ourselves to require
non-ASCII.

##### Why not define constraints in a builtin package?

_Instead of writing out type lists, use names like_
_`constraints.Arithmetic` and `constraints.Comparable`._

Listing all the possible combinations of types gets rather lengthy.
It also introduces a new set of names that not only the writer of
generic code, but, more importantly, the reader, must remember.
One of the driving goals of this design is to introduce as few new
names as possible.
In this design we introduce only one new predeclared name.

We expect that if people find such names useful, we can introduce a
package `constraints` that defines the useful names in the form of
constraints that can be used by other types and functions and embedded
in other constraints.
That will define the most useful names in the standard library while
giving programmers the flexibility to use other combinations of types
where appropriate.

##### Why not permit type assertions on values whose type is a type parameter?

In an earlier version of this design, we permitted using type
assertions and type switches on variables whose type was a type
parameter, or whose type was based on a type parameter.
We removed this facility because it is always possible to convert a
value of any type to the empty interface type, and then use a type
assertion or type switch on that.
Also, it was sometimes confusing that in a constraint with a type
list, a type assertion or type switch would use the actual type
argument, not the underlying type of the type argument (the difference
is explained in the section on [identifying the matched predeclared
type](#Identifying-the-matched-predeclared-type)).

#### Comparison with Java

Most complaints about Java generics center around type erasure.
This design does not have type erasure.
The reflection information for a generic type will include the full
compile-time type information.

In Java type wildcards (`List<? extends Number>`, `List<? super
Number>`) implement covariance and contravariance.
These concepts are missing from Go, which makes generic types much
simpler.

#### Comparison with C++

C++ templates do not enforce any constraints on the type arguments
(unless the concept proposal is adopted).
This means that changing template code can accidentally break far-off
instantiations.
It also means that error messages are reported only at instantiation
time, and can be deeply nested and difficult to understand.
This design avoids these problems through explicit required
constraints.

C++ supports template metaprogramming, which can be thought of as
ordinary programming done at compile time using a syntax that is
completely different than that of non-template C++.
This design has no similar feature.
This saves considerable complexity while losing some power and run
time efficiency.

C++ uses two-phase name lookup, in which some names are looked up in
the context of the template definition, and some names are looked up
in the context of the template instantiation.
In this design all names are looked up at the point where they are
written.

In practice, all C++ compilers compile each template at the point
where it is instantiated.
This can slow down compilation time.
This design offers flexibility as to how to handle the compilation of
generic functions.

#### Comparison with Rust

The generics described in this design are similar to generics in
Rust.

One difference is that in Rust the association between a trait bound
and a type must be defined explicitly, either in the crate that
defines the trait bound or the crate that defines the type.
In Go terms, this would mean that we would have to declare somewhere
whether a type satisfied a constraint.
Just as Go types can satisfy Go interfaces without an explicit
declaration, in this design Go type arguments can satisfy a constraint
without an explicit declaration.

Where this design uses type lists, the Rust standard library defines
standard traits for operations like comparison.
These standard traits are automatically implemented by Rust's
primitive types, and can be implemented by user defined types as
well.
Rust provides a fairly extensive list of traits, at least 34, covering
all of the operators.

Rust supports type parameters on methods, which this design does not.

## Examples

The following sections are examples of how this design could be used.
This is intended to address specific areas where people have created
user experience reports concerned with Go's lack of generics.

### Map/Reduce/Filter

Here is an example of how to write map, reduce, and filter functions
for slices.
These functions are intended to correspond to the similar functions in
Lisp, Python, Java, and so forth.

```Go
// Package slices implements various slice algorithms.
package slices

// Map turns a []T1 to a []T2 using a mapping function.
// This function has two type parameters, T1 and T2.
// There are no constraints on the type parameters,
// so this works with slices of any type.
func Map(type T1, T2)(s []T1, f func(T1) T2) []T2 {
	r := make([]T2, len(s))
	for i, v := range s {
		r[i] = f(v)
	}
	return r
}

// Reduce reduces a []T1 to a single value using a reduction function.
func Reduce(type T1, T2)(s []T1, initializer T2, f func(T2, T1) T2) T2 {
	r := initializer
	for _, v := range s {
		r = f(r, v)
	}
	return r
}

// Filter filters values from a slice using a filter function.
// It returns a new slice with only the elements of s
// for which f returned true.
func Filter(type T)(s []T, f func(T) bool) []T {
	var r []T
	for _, v := range s {
		if f(v) {
			r = append(r, v)
		}
	}
	return r
}
```

Here are some example calls of these functions.
Type inference is used to determine the type arguments based on the
types of the non-type arguments.

```Go
	s := []int{1, 2, 3}

	floats := slices.Map(s, func(i int) float64 { return float64(i) })
	// Now floats is []float64{1.0, 2.0, 3.0}.

	sum := slices.Reduce(s, 0, func(i, j int) int { return i + j })
	// Now sum is 6.

	evens := slices.Filter(s, func(i int) bool { return i%2 == 0 })
	// Now evens is []int{2}.
```

### Map keys

Here is how to get a slice of the keys of any map.

```Go
// Package maps provides general functions that work for all map types.
package maps

// Keys returns the keys of the map m in a slice.
// The keys will be returned in an unpredictable order.
// This function has two type parameters, K and V.
// Map keys must be comparable, so key has the predeclared
// constraint comparable. Map values can be any type;
// the empty interface type imposes no constraints.
func Keys(type K comparable, V interface{})(m map[K]V) []K {
	r := make([]K, 0, len(m))
	for k := range m {
		r = append(r, k)
	}
	return r
}
```

In typical use the map key and val types will be inferred.

```Go
	k := maps.Keys(map[int]int{1:2, 2:4})
	// Now k is either []int{1, 2} or []int{2, 1}.
```

### Sets

Many people have asked for Go's builtin map type to be extended, or
rather reduced, to support a set type.
Here is a type-safe implementation of a set type, albeit one that uses
methods rather than operators like `[]`.

```Go
// Package set implements sets of any comparable type.
package set

// Set is a set of values.
type Set(type T comparable) map[T]struct{}

// Make returns a set of some element type.
func Make(type T comparable)() Set(T) {
	return make(Set(T))
}

// Add adds v to the set s.
// If v is already in s this has no effect.
func (s Set(T)) Add(v T) {
	s[v] = struct{}{}
}

// Delete removes v from the set s.
// If v is not in s this has no effect.
func (s Set(T)) Delete(v T) {
	delete(s, v)
}

// Contains reports whether v is in s.
func (s Set(T)) Contains(v T) bool {
	_, ok := s[v]
	return ok
}

// Len reports the number of elements in s.
func (s Set(T)) Len() int {
	return len(s)
}

// Iterate invokes f on each element of s.
// It's OK for f to call the Delete method.
func (s Set(T)) Iterate(f func(T)) {
	for v := range s {
		f(v)
	}
}
```

Example use:

```Go
	// Create a set of ints.
	// We pass (int) as a type argument.
	// Then we write () because Make does not take any non-type arguments.
	// We have to pass an explicit type argument to Make.
	// Type inference doesn't work because the type argument
	// to Make is only used for a result parameter type.
	s := set.Make(int)()

	// Add the value 1 to the set s.
	s.Add(1)

	// Check that s does not contain the value 2.
	if s.Contains(2) { panic("unexpected 2") }
```

This example shows how to use this design to provide a compile-time
type-safe wrapper around an existing API.

### Sort

Before the introduction of `sort.Slice`, a common complaint was the
need for boilerplate definitions in order to use `sort.Sort`.
With this design, we can add to the sort package as follows:

```Go
// Ordered is a type constraint that matches all ordered types.
// (An ordered type is one that supports the < <= >= > operators.)
// In practice this type constraint would likely be defined in
// a standard library package.
type Ordered interface {
	type int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64,
		string
}

// orderedSlice is an internal type that implements sort.Interface.
// The Less method uses the < operator. The Ordered type constraint
// ensures that T has a < operator.
type orderedSlice(type T Ordered) []T

func (s orderedSlice(T)) Len() int           { return len(s) }
func (s orderedSlice(T)) Less(i, j int) bool { return s[i] < s[j] }
func (s orderedSlice(T)) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }

// OrderedSlice sorts the slice s in ascending order.
// The elements of s must be ordered using the < operator.
func OrderedSlice(type T Ordered)(s []T) {
	// Convert s to the type orderedSlice(T).
	// As s is []T, and orderedSlice(T) is defined as []T,
	// this conversion is permitted.
	// orderedSlice(T) implements sort.Interface,
	// so can pass the result to sort.Sort.
	// The elements will be sorted using the < operator.
	sort.Sort(orderedSlice(T)(s))
}
```

Now we can write:

```Go
	s1 := []int32{3, 5, 2}
	sort.OrderedSlice(s1)
	// Now s1 is []int32{2, 3, 5}

	s2 := []string{"a", "c", "b"})
	sort.OrderedSlice(s2)
	// Now s2 is []string{"a", "b", "c"}
```

Along the same lines, we can add a function for sorting using a
comparison function, similar to `sort.Slice` but writing the function
to take values rather than slice indexes.

```Go
// sliceFn is an internal type that implements sort.Interface.
// The Less method calls the cmp field.
type sliceFn(type T) struct {
	s   []T
	cmp func(T, T) bool
}

func (s sliceFn(T)) Len() int           { return len(s.s) }
func (s sliceFn(T)) Less(i, j int) bool { return s.cmp(s.s[i], s.s[j]) }
func (s sliceFn(T)) Swap(i, j int)      { s.s[i], s.s[j] = s.s[j], s.s[i] }

// SliceFn sorts the slice s according to the function cmp.
func SliceFn(type T)(s []T, cmp func(T, T) bool) {
	Sort(sliceFn(E){s, cmp})
}
```

An example of calling this might be:

```Go
	var s []*Person
	// ...
	sort.SliceFn(s, func(p1, p2 *Person) bool { return p1.Name < p2.Name })
```

### Channels

Many simple general purpose channel functions are never written,
because they must be written using reflection and the caller must type
assert the results.
With this design they become straightforward to write.

```Go
// Package chans implements various channel algorithms.
package chans

import "runtime"

// Ranger provides a convenient way to exit a goroutine sending values
// when the receiver stops reading them.
//
// Ranger returns a Sender and a Receiver. The Receiver provides a
// Next method to retrieve values. The Sender provides a Send method
// to send values and a Close method to stop sending values. The Next
// method indicates when the Sender has been closed, and the Send
// method indicates when the Receiver has been freed.
func Ranger(type T)() (*Sender(T), *Receiver(T)) {
	c := make(chan T)
	d := make(chan bool)
	s := &Sender(T){values: c, done: d}
	r := &Receiver(T){values: c, done: d}
	// The finalizer on the receiver will tell the sender
	// if the receiver stops listening.
	runtime.SetFinalizer(r, r.finalize)
	return s, r
}

// A Sender is used to send values to a Receiver.
type Sender(type T) struct {
	values chan<- T
	done   <-chan bool
}

// Send sends a value to the receiver. It reports whether any more
// values may be sent; if it returns false the value was not sent.
func (s *Sender(T)) Send(v T) bool {
	select {
	case s.values <- v:
		return true
	case <-s.done:
		// The receiver has stopped listening.
		return false
	}
}

// Close tells the receiver that no more values will arrive.
// After Close is called, the Sender may no longer be used.
func (s *Sender(T)) Close() {
	close(s.values)
}

// A Receiver receives values from a Sender.
type Receiver(type T) struct {
	values <-chan T
	done  chan<- bool
}

// Next returns the next value from the channel. The bool result
// reports whether the value is valid. If the value is not valid, the
// Sender has been closed and no more values will be received.
func (r *Receiver(T)) Next() (T, bool) {
	v, ok := <-r.values
	return v, ok
}

// finalize is a finalizer for the receiver.
// It tells the sender that the receiver has stopped listening.
func (r *Receiver(T)) finalize() {
	close(r.done)
}
```

There is an example of using this function in the next section.

### Containers

One of the frequent requests for generics in Go is the ability to
write compile-time type-safe containers.
This design makes it easy to write a compile-time type-safe wrapper
around an existing container; we won't write out an example for that.
This design also makes it easy to write a compile-time type-safe
container that does not use boxing.

Here is an example of an ordered map implemented as a binary tree.
The details of how it works are not too important.
The important points are:

* The code is written in a natural Go style, using the key and value
  types where needed.
* The keys and values are stored directly in the nodes of the tree,
  not using pointers and not boxed as interface values.

```Go
// Package orderedmap provides an ordered map, implemented as a binary tree.
package orderedmap

import "chans"

// Map is an ordered map.
type Map(type K, V) struct {
	root    *node(K, V)
	compare func(K, K) int
}

// node is the type of a node in the binary tree.
type node(type K, V) struct {
	k           K
	v           V
	left, right *node(K, V)
}

// New returns a new map.
// Since the type parameter V is only used for the result,
// type inference does not work, and calls to New must always
// pass explicit type arguments.
func New(type K, V)(compare func(K, K) int) *Map(K, V) {
	return &Map(K, V){compare: compare}
}

// find looks up k in the map, and returns either a pointer
// to the node holding k, or a pointer to the location where
// such a node would go.
func (m *Map(K, V)) find(k K) **node(K, V) {
	pn := &m.root
	for *pn != nil {
		switch cmp := m.compare(k, (*pn).k); {
		case cmp < 0:
			pn = &(*pn).left
		case cmp > 0:
			pn = &(*pn).right
		default:
			return pn
		}
	}
	return pn
}

// Insert inserts a new key/value into the map.
// If the key is already present, the value is replaced.
// Reports whether this is a new key.
func (m *Map(K, V)) Insert(k K, v V) bool {
	pn := m.find(k)
	if *pn != nil {
		(*pn).v = v
		return false
	}
	*pn = &node(K, V){k: k, v: v}
	return true
}

// Find returns the value associated with a key, or zero if not present.
// The bool result reports whether the key was found.
func (m *Map(K, V)) Find(k K) (V, bool) {
	pn := m.find(k)
	if *pn == nil {
		var zero V // see the discussion of zero values, above
		return zero, false
	}
	return (*pn).v, true
}

// keyValue is a pair of key and value used when iterating.
type keyValue(type K, V) struct {
	k K
	v V
}

// InOrder returns an iterator that does an in-order traversal of the map.
func (m *Map(K, V)) InOrder() *Iterator(K, V) {
	type kv = keyValue(K, V) // convenient shorthand
	sender, receiver := chans.Ranger(kv)()
	var f func(*node(K, V)) bool
	f = func(n *node(K, V)) bool {
		if n == nil {
			return true
		}
		// Stop sending values if sender.Send returns false,
		// meaning that nothing is listening at the receiver end.
		return f(n.left) &&
			sender.Send(kv{n.k, n.v}) &&
			f(n.right)
	}
	go func() {
		f(m.root)
		sender.Close()
	}()
	return &Iterator{receiver}
}

// Iterator is used to iterate over the map.
type Iterator(type K, V) struct {
	r *chans.Receiver(keyValue(K, V))
}

// Next returns the next key and value pair. The bool result reports
// whether the values are valid. If the values are not valid, we have
// reached the end.
func (it *Iterator(K, V)) Next() (K, V, bool) {
	kv, ok := it.r.Next()
	return kv.k, kv.v, ok
}
```

This is what it looks like to use this package:

```Go
import "container/orderedmap"

// Set m to an ordered map from string to string,
// using strings.Compare as the comparison function.
var m = orderedmap.New(string, string)(strings.Compare)

// Add adds the pair a, b to m.
func Add(a, b string) {
	m.Insert(a, b)
}
```

### Append

The predeclared `append` function exists to replace the boilerplate
otherwise required to grow a slice.
Before `append` was added to the language, there was a function `Add`
in the bytes package:

```Go
// Add appends the contents of t to the end of s and returns the result.
// If s has enough capacity, it is extended in place; otherwise a
// new array is allocated and returned.
func Add(s, t []byte) []byte
```

`Add` appended two `[]byte` values together, returning a new slice.
That was fine for `[]byte`, but if you had a slice of some other
type, you had to write essentially the same code to append more
values.
If this design were available back then, perhaps we would not have
added `append` to the language.
Instead, we could write something like this:

```Go
// Package slices implements various slice algorithms.
package slices

// Append appends the contents of t to the end of s and returns the result.
// If s has enough capacity, it is extended in place; otherwise a
// new array is allocated and returned.
func Append(type T)(s []T, t ...T) []T {
	lens := len(s)
	tot := lens + len(t)
	if tot < 0 {
		panic("Append: cap out of range")
	}
	if tot > cap(s) {
		news := make([]T, tot, tot + tot/2)
		copy(news, s)
		s = news
	}
	s = s[:tot]
	copy(s[lens:], t)
	return s
}
```

That example uses the predeclared `copy` function, but that's OK, we
can write that one too:

```Go
// Copy copies values from t to s, stopping when either slice is
// full, returning the number of values copied.
func Copy(type T)(s, t []T) int {
	i := 0
	for ; i < len(s) && i < len(t); i++ {
		s[i] = t[i]
	}
	return i
}
```

These functions can be used as one would expect:

```Go
	s := slices.Append([]int{1, 2, 3}, 4, 5, 6)
	// Now s is []int{1, 2, 3, 4, 5, 6}.
	slices.Copy(s[3:], []int{7, 8, 9})
	// Now s is []int{1, 2, 3, 7, 8, 9}
```

This code doesn't implement the special case of appending or copying a
`string` to a `[]byte`, and it's unlikely to be as efficient as the
implementation of the predeclared function.
Still, this example shows that using this design would permit `append`
and `copy` to be written generically, once, without requiring any
additional special language features.

### Metrics

In a [Go experience
report](https://medium.com/@sameer_74231/go-experience-report-for-generics-google-metrics-api-b019d597aaa4)
Sameer Ajmani describes a metrics implementation.
Each metric has a value and one or more fields.
The fields have different types.
Defining a metric requires specifying the types of the fields, and
creating a value with an Add method.
The Add method takes the field types as arguments, and records an
instance of that set of fields.
The C++ implementation uses a variadic template.
The Java implementation includes the number of fields in the name of
the type.
Both the C++ and Java implementations provide compile-time type-safe
Add methods.

Here is how to use this design to provide similar functionality in
Go with a compile-time type-safe Add method.
Because there is no support for a variadic number of type arguments,
we must use different names for a different number of arguments, as in
Java.
This implementation only works for comparable types.
A more complex implementation could accept a comparison function to
work with arbitrary types.

```Go
// Package metrics provides a general mechanism for accumulating
// metrics of different values.
package metrics

import "sync"

// Metric1 accumulates metrics of a single value.
type Metric1(type T comparable) struct {
	mu sync.Mutex
	m  map[T]int
}

// Add adds an instance of a value.
func (m *Metric1(T)) Add(v T) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.m == nil {
		m.m = make(map[T]int)
	}
	m.m[v]++
}

// key2 is an internal type used by Metric2.
type key2(type T1, T2 comparable) struct {
	f1 T1
	f2 T2
}

// Metric2 accumulates metrics of pairs of values.
type Metric2(type T1, T2 comparable) struct {
	mu sync.Mutex
	m  map[key2(T1, T2)]int
}

// Add adds an instance of a value pair.
func (m *Metric2(T1, T2)) Add(v1 T1, v2 T2) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.m == nil {
		m.m = make(map[key2(T1, T2)]int)
	}
	m.m[key2(T1, T2){v1, v2}]++
}

// key3 is an internal type used by Metric3.
type key3(type T1, T2, T3 comparable) struct {
	f1 T1
	f2 T2
	f3 T3
}

// Metric3 accumulates metrics of triples of values.
type Metric3(type T1, T2, T3 comparable) struct {
	mu sync.Mutex
	m  map[key3(T1, T2, T3)]int
}

// Add adds an instance of a value triplet.
func (m *Metric3(T1, T2, T3)) Add(v1 T1, v2 T2, v3 T3) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.m == nil {
		m.m = make(map[key3(T1, T2, T3)]int)
	}
	m.m[key3(T1, T2, T3){v1, v2, v3}]++
}

// Repeat for the maximum number of permitted arguments.
```

Using this package looks like this:

```Go
import "metrics"

var m = metrics.Metric2(string, int){}

func F(s string, i int) {
	m.Add(s, i) // this call is type checked at compile time
}
```

This implementation has a certain amount of repetition due to the lack
of support for variadic type parameters.
Using the package, though, is easy and type safe.

### List transform

While slices are efficient and easy to use, there are occasional cases
where a linked list is appropriate.
This example primarily shows transforming a linked list of one type to
another type, as an example of using different instantiations of the
same generic type.

```Go
// Package list provides a linked list of any type.
package list

// List is a linked list.
type List(type T) struct {
	head, tail *element(T)
}

// An element is an entry in a linked list.
type element(type T) struct {
	next *element(T)
	val  T
}

// Push pushes an element to the end of the list.
func (lst *List(T)) Push(v T) {
	if lst.tail == nil {
		lst.head = &element(T){val: v}
		lst.tail = lst.head
	} else {
		lst.tail.next = &element(T){val: v }
		lst.tail = lst.tail.next
	}
}

// Iterator ranges over a list.
type Iterator(type T) struct {
	next **element(T)
}

// Range returns an Iterator starting at the head of the list.
func (lst *List(T)) Range() *Iterator(T) {
	return Iterator(T){next: &lst.head}
}

// Next advances the iterator.
// It reports whether there are more elements.
func (it *Iterator(T)) Next() bool {
	if *it.next == nil {
		return false
	}
	it.next = &(*it.next).next
	return true
}

// Val returns the value of the current element.
// The bool result reports whether the value is valid.
func (it *Iterator(T)) Val() (T, bool) {
	if *it.next == nil {
		var zero T
		return zero, false
	}
	return (*it.next).val, true
}

// Transform runs a transform function on a list returning a new list.
func Transform(type T1, T2)(lst *List(T1), f func(T1) T2) *List(T2) {
	ret := &List(T2){}
	it := lst.Range()
	for {
		if v, ok := it.Val(); ok {
			ret.Push(f(v))
		}
		if !it.Next() {
			break
		}
	}
	return ret
}
```

### Dot product

A generic dot product implementation that works for slices of any
numeric type.

```Go
// Numeric is a constraint that matches any numeric type.
// It would likely be in a constraints package in the standard library.
type Numeric interface {
	type int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64,
		complex64, complex128
}

// DotProduct returns the dot product of two slices.
// This panics if the two slices are not the same length.
func DotProduct(type T Numeric)(s1, s2 []T) T {
	if len(s1) != len(s2) {
		panic("DotProduct: slices of unequal length")
	}
	var r T
	for i := range s1 {
		r += s1[i] * s2[i]
	}
	return r
}
```

(Note: the generics implementation approach may affect whether
`DotProduct` uses FMA, and thus what the exact results are when using
floating point types.
It's not clear how much of a problem this is, or whether there is any
way to fix it.)

### Absolute difference

Compute the absolute difference between two numeric values, by using
an `Abs` method.
This uses the same `Numeric` constraint defined in the last example.

This example uses more machinery than is appropriate for the simple
case of computing the absolute difference.
It is intended to show how the common part of algorithms can be
factored into code that uses methods, where the exact definition of
the methods can vary based on the kind of type being used.

```Go
// NumericAbs matches numeric types with an Abs method.
type NumericAbs(type T) interface {
	Numeric
	Abs() T
}

// AbsDifference computes the absolute value of the difference of
// a and b, where the absolute value is determined by the Abs method.
func AbsDifference(type T NumericAbs)(a, b T) T {
	d := a - b
	return d.Abs()
}
```

We can define an `Abs` method appropriate for different numeric types.

```Go
// OrderedNumeric matches numeric types that support the < operator.
type OrderedNumeric interface {
	type int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64
}

// Complex matches the two complex types, which do not have a < operator.
type Complex interface {
	type complex64, complex128
}

// OrderedAbs is a helper type that defines an Abs method for
// ordered numeric types.
type OrderedAbs(type T OrderedNumeric) T

func (a OrderedAbs(T)) Abs() OrderedAbs(T) {
	if a < 0 {
		return -a
	}
	return a
}

// ComplexAbs is a helper type that defines an Abs method for
// complex types.
type ComplexAbs(type T Complex) T

func (a ComplexAbs(T)) Abs() ComplexAbs(T) {
	d := math.Hypot(float64(real(a)), float64(imag(a)))
	return ComplexAbs(T)(complex(d, 0))
}
```

We can then define functions that do the work for the caller by
converting to and from the types we just defined.

```Go
// OrderedAbsDifference returns the absolute value of the difference
// between a and b, where a and b are of an ordered type.
func OrderedAbsDifference(type T OrderedNumeric)(a, b T) T {
	return T(AbsDifference(OrderedAbs(T)(a), OrderedAbs(T)(b)))
}

// ComplexAbsDifference returns the absolute value of the difference
// between a and b, where a and b are of a complex type.
func ComplexAbsDifference(type T Complex)(a, b T) T {
	return T(AbsDifference(ComplexAbs(T)(a), ComplexAbs(T)(b)))
}
```

It's worth noting that this design is not powerful enough to write
code like the following:

```Go
// This function is INVALID.
func GeneralAbsDifference(type T Numeric)(a, b T) T {
	switch (interface{})(a).(type) {
	case int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64:
		return OrderedAbsDifference(a, b) // INVALID
	case complex64, complex128:
		return ComplexAbsDifference(a, b) // INVALID
	}
}
```

The calls to `OrderedAbsDifference` and `ComplexAbsDifference` are
invalid, because not all the types that implement the `Numeric`
constraint can implement the `OrderedNumeric` or `Complex`
constraints.
Although the type switch means that this code would conceptually work
at run time, there is no support for writing this code at compile
time.
This is another way of expressing one of the omissions listed above:
this design does not provide for specialization.

## Acknowledgements

We'd like to thank many people on the Go team, many contributors to
the Go issue tracker, and all the people who have shared their ideas
and their feedback on earlier design drafts.
We read all of it, and we're grateful.

For this design draft in particular we received detailed feedback from
Josh Bleecher-Snyder, Jon Bodner, Dave Cheney, Jaana Dogan, Kevin
Gillette, Mitchell Hashimoto, Chris Hines, Bill Kennedy, Ayke van
Laethem, Daniel Martí, Elena Morozova, Roger Peppe, and Ronna
Steinberg.

## Appendix

This appendix covers various details of the design that don't seem
significant enough to cover in earlier sections.

### Generic type aliases

A type alias may refer to a generic type, but the type alias may not
have its own parameters.
This restriction exists because it is unclear how to handle a type
alias with type parameters that have constraints.

```Go
type VectorAlias = Vector
```

In this case uses of the type alias will have to provide type
arguments appropriate for the generic type being aliased.

```Go
var v VectorAlias(int)
```

Type aliases may also refer to instantiated types.

```Go
type VectorInt = Vector(int)
```

### Instantiating a function

Go normally permits you to refer to a function without passing any
arguments, producing a value of function type.
You may not do this with a function that has type parameters; all type
arguments must be known at compile time.
That said, you can instantiate the function, by passing type
arguments, but you don't have to call the instantiation.
This will produce a function value with no type parameters.

```Go
// PrintInts is type func([]int).
var PrintInts = Print(int)
```

### Embedded type parameter

When a generic type is a struct, and the type parameter is
embedded as a field in the struct, the name of the field is the name
of the type parameter.

```Go
// A Lockable is a value that may be safely simultaneously accessed
// from multiple goroutines via the Get and Set methods.
type Lockable(type T) struct {
	T
	mu sync.Mutex
}

// Get returns the value stored in a Lockable.
func (l *Lockable(T)) Get() T {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.T
}

// Set sets the value in a Lockable.
func (l *Lockable(T)) Set(v T) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.T = v
}
```

### Inline constraints

As we've seen in examples that use `interface{}` as a type constraint,
it's not necessary for a constraint to use a named interface type.
A type parameter list can use an interface type literal, just as an
ordinary parameter list can use a type literal for a parameter type.

```Go
// Stringify calls the String method on each element of s,
// and returns the results.
func Stringify(type T interface { String() string })(s []T) (ret []string) {
	for _, v := range s {
		ret = append(ret, v.String())
	}
	return ret
}
```

### Type inference for composite literals

This is a feature we are not suggesting now, but could consider for
later versions of the language.

We could also consider supporting type inference for composite
literals of generic types.

```Go
type Pair(type T) struct { f1, f2 T }
var V = Pair{1, 2} // inferred as Pair(int){1, 2}
```

It's not clear how often this will arise in real code.

### Type inference for generic function arguments

This is a feature we are not suggesting now, but could consider for
later versions of the language.

In the following example, consider the call to `Find` in `FindClose`.
Type inference can determine that the type argument to `Find` is `T4`,
and from that we know that the type of the final argument must be
`func(T4, T4) bool`, and from that we could deduce that the type
argument to `IsClose` must also be `T4`.
However, the type inference algorithm described earlier cannot do
that, so we must explicitly write `IsClose(T4)`.

This may seem esoteric at first, but it comes up when passing generic
functions to generic `Map` and `Filter` functions.

```Go
// Differ has a Diff method that returns how different a value is.
type Differ(type T1) interface {
	Diff(T1) int
}

// IsClose returns whether a and b are close together, based on Diff.
func IsClose(type T2 Differ)(a, b T2) bool {
	return a.Diff(b) < 2
}

// Find returns the index of the first element in s that matches e,
// based on the cmp function. It returns -1 if no element matches.
func Find(type T3)(s []T3, e T3, cmp func(a, b T3) bool) int {
	for i, v := range s {
		if cmp(v, e) {
			return i
		}
	}
	return -1
}

// FindClose returns the index of the first element in s that is
// close to e, based on IsClose.
func FindClose(type T4 Differ)(s []T4, e T4) int {
	// With the current type inference algorithm we have to
	// explicitly write IsClose(T4) here, although it
	// is the only type argument we could possibly use.
	return Find(s, e, IsClose(T4))
}
```

### Reflection on type arguments

Although we don't suggest changing the reflect package, one
possibility to consider for the future would be to add two new
methods to `reflect.Type`: `NumTypeArgument() int` would return the
number of type arguments to a type, and `TypeArgument(i) Type` would
return the i'th type argument.
`NumTypeArgument` would return non-zero for an instantiated generic
type.
Similar methods could be defined for `reflect.Value`, for which
`NumTypeArgument` would return non-zero for an instantiated generic
function.
There might be some kind of programs that would care about this
information.

### Instantiating types in type literals

When instantiating a type at the end of a type literal, there is a
parsing ambiguity.

```Go
x1 := []T(v1)
x2 := []T(v2){}
```

In this example, the first case is a type conversion of `v1` to the
type `[]T`.
The second case is a composite literal of type `[]T(v2)`, where `T` is
a generic type that we are instantiating with the type argument `v2`.
The ambiguity is at the point where we see the open parenthesis: at
that point the parser doesn't know whether it is seeing a type
conversion or something like a composite literal.

To avoid this ambiguity, we require that type instantiations at the
end of a type literal be parenthesized.
To write a type literal that is a slice of a type instantiation, you
must write `[](T(v1))`.
Without those parentheses, `[]T(x)` is parsed as `([]T)(x)`, not as
`[](T(x))`.
This only applies to slice, array, map, chan, and func type literals
ending in a type name.
Of course it is always possible to use a separate type declaration to
give a name to the instantiated type, and to use that.

### Embedding an instantiated interface type

There is a parsing ambiguity when embedding an instantiated interface
type in another interface type.

```Go
type I1(type T) interface {
	M(T)
}

type I2 interface {
	I1(int)
}
```

In this example we don't know whether interface `I2` has a single
method named `I1` that takes an argument of type `int`, or whether we
are trying to embed the instantiated type `I1(int)` into `I2`.

For backward compatibility, we treat this as the former case: `I2` has
a method named `I1`.

In order to embed an instantiated interface type, we require
that extra parentheses be used.

```Go
type I2 interface {
	(I1(int))
}
```

This is currently not permitted by the language, and will be a
relaxation of the existing rules.

The same applies to embedding an instantiated type in a struct.

```Go
type S1 struct {
	T(int) // field named T of type int
}

type S2 struct {
	(T(int)) // embedded field of type T(int)
}
```

The field name of an embedded field of type `T(int)` is simply `T`.
