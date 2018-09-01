# Contracts — Draft Design

Ian Lance Taylor\
Robert Griesemer\
August 27, 2018

## Abstract

We suggest extending the Go language to add optional type parameters
to types and functions.
Type parameters may be constrained by contracts: they may be used as
ordinary types that only support the operations described by the
contracts.
Type inference via a unification algorithm is supported to permit
omitting type arguments from function calls in many cases.
Depending on a detail, the design can be fully backward compatible
with Go 1.

For more context, see the [generics problem overview](go2draft-generics-overview.md).

## Background

There have been many [requests to add additional support for generic
programming](https://golang.org/wiki/ExperienceReports#generics)
in Go.
There has been extensive discussion on
[the issue tracker](https://golang.org/issue/15292) and on
[a living document](https://docs.google.com/document/d/1vrAy9gMpMoS3uaVphB32uVXX4pi-HnNjkMEgyAHX4N4/view).

There have been several proposals for adding type parameters, which
can be found by looking through the links above.
Many of the ideas presented here have appeared before.
The main new features described here are the syntax and the careful
examination of contracts.

This draft design suggests extending the Go language to add a form of
parametric polymorphism, where the type parameters are bounded not by
a subtyping relationship but by explicitly defined structural
constraints.
Among other languages that support parametric polymorphism this
design is perhaps most similar to CLU or Ada, although the syntax is
completely different.
Contracts also somewhat resemble C++ concepts.

This design does not support template metaprogramming or any other
form of compile-time programming.

As the term _generic_ is widely used in the Go community, we will
use it below as a shorthand to mean a function or type that takes type
parameters.
Don’t confuse the term generic as used in this design with the same
term in other languages like C++, C#, Java, or Rust; they have
similarities but are not always the same.

## Design

We will describe the complete design in stages based on examples.

### Type parameters

Generic code is code that is written using types that will be
specified later.
Each unspecified type is called a _type parameter_.
When the code is used the type parameter is set to a _type argument_.

Here is a function that prints out each element of a slice, where the
element type of the slice, here called `T`, is unknown.
This is a trivial example of the kind of function we want to permit in
order to support generic programming.

```Go
// Print prints the elements of a slice.
// It should be possible to call this with any slice value.
func Print(s []T) { // Just an example, not the suggested syntax.
	for _, v := range s {
		fmt.Println(v)
	}
}
```

As you can see, the first decision to make is: how should the type
parameter `T` be declared?
In a language like Go, we expect every identifier to be declared in
some way.

Here we make a design decision: type parameters are similar to
ordinary non-type function parameters, and as such should be listed
along with other parameters.
However, type parameters are not the same as non-type parameters, so
although they appear in the parameters we want to distinguish them.
That leads to our next design decision: we define an additional,
optional, parameter list, describing type parameters.
This parameter list appears before the regular parameters.
It starts with the keyword `type` and lists type parameters.

```Go
func Print(type T)(s []T) {
	// same as above
}
```

This says that within the function `Print` the identifier `T` is a
type parameter, a type that is currently unknown but that will be
known when the function is called.

Since `Print` has a type parameter, when we call it we must pass a
type argument.
Type arguments are passed much like type parameters are declared: as a
separate list of arguments.
At the call site, the `type` keyword is not used.

```Go
	Print(int)([]int{1, 2, 3})
```

### Type contracts

Let’s make our example slightly more complicated.
Let’s turn it into a function that converts a slice of any type into a
`[]string` by calling a `String` method on each element.

```Go
func Stringify(type T)(s []T) (ret []string) {
	for _, v := range s {
		ret = append(ret, v.String()) // INVALID
	}
	return ret
}
```

This might seem OK at first glance, but in this example, `v` has type
`T`, and we don’t know anything about `T`.
In particular, we don’t know that `T` has a `String` method.
So the call `v.String()` is invalid.

Naturally, the same issue arises in other languages that support
generic programming.
In C++, for example, a generic function (in C++ terms, a function
template) can call any method on a value of generic type.
That is, in the C++ approach, calling `v.String()` is fine.
If the function is called with a type that does not have a `String`
method, the error is reported at the point of the function call.
These errors can be lengthy, as there may be several layers of generic
function calls before the error occurs, all of which must be reported
for complete clarity.

The C++ approach would be a poor choice for Go.
One reason is the style of the language.
In Go we don’t refer to names, such as, in this case, `String`, and
hope that they exist.
Go resolves all names to their declarations when they are seen.

Another reason is that Go is designed to support programming at
scale.
We must consider the case in which the generic function definition
(`Stringify`, above) and the call to the generic function (not shown,
but perhaps in some other package) are far apart.
In general, all generic code has a contract that type arguments need
to implement.
In this case, the contract is pretty obvious: the type has to have a
`String() string` method.
In other cases it may be much less obvious.
We don’t want to derive the contract from whatever `Stringify` happens
to do.
If we did, a minor change to `Stringify` might change the contract.
That would mean that a minor change could cause code far away, that
calls the function, to unexpectedly break.
It’s fine for `Stringify` to deliberately change its contract, and
force users to change.
What we want to avoid is `Stringify` changing its contract
accidentally.

This is an important rule that we believe should apply to any attempt
to define generic programming in Go: there should be an explicit
contract between the generic code and calling code.

### Contract syntax

In this design, a contract has the same general form as a function.
The function body is never executed.
Instead, it describes, by example, a set of types.

For the `Stringify` example, we need to write a contract that says
that the type has a `String` method that takes no arguments and
returns a value of type `string`.
Here is one way to write that:

```Go
contract stringer(x T) {
	var s string = x.String()
}
```

A contract is introduced with a new keyword `contract`.
The definition of a contract looks like the definition of a function,
except that the parameter types must be simple identifiers.

### Using a contract to verify type arguments

A contract serves two purposes.
First, contracts are used to validate a set of type arguments.
As shown above, when a function with type parameters is called, it
will be called with a set of type arguments.
When the compiler sees the function call, it will use the contract to
validate the type arguments.
If the type arguments are invalid, the compiler will report a type
error: the call is using types that the function’s contract does not
permit.

To validate the type arguments, each of the contract’s parameter types
is replaced with the corresponding type argument (there must be
exactly as many type arguments as there are parameter types; contracts
may not be variadic).
The body of the contract is then type checked as though it were an
ordinary function.
If the type checking succeeds, the type arguments are valid.

In the example of the `stringer` contract seen earlier, we can see
that the type argument used for `T` must have a `String` method (or it
must be a struct with a `String` field of function type).
The `String` method must not take any arguments, and it must return a
value of a type that is assignable to `string`. (As it happens, the
only type assignable to `string` is, in fact, `string`.)
If any of those statements about the type argument are not true, the
contract body will fail when it is type checked.

### The party of the second part

A contract is not used only at the call site.
It is also used to describe what the function using the contract, the
function with type parameters, is permitted to do with those type
parameters.

In a function with type parameters that does not use a contract, such
as the `Print` example shown earlier, the function is only permitted
to use those type parameters in ways that any type may be used in Go.
That is, operations like:

* declare variables of those types
* assign other values of the same type to those variables
* pass those variables to functions or return them from functions
* take the address of those variables
* define and use other types that use those types, such as a slice of
  that type

If the function wants to take any more specific action with the type
parameter, or a value of the type parameter, the contract must permit
it.
Basically, if the contract body uses a type in a certain way, the
actual function is permitted to use the type in the same way.
This is described in more detail later.
For now, look at the `stringer` contract example above.
The single statement in the contract body shows that given a value of
type `T`, the function using the `stringer` contract is permitted to
call a method of type `String`, passing no arguments, to get a value
of type `string`.
That is, naturally, exactly the operation that the `Stringify`
function needs.

### Using a contract

We’ve seen how the `stringer` contract can be used to verify that a
type argument is suitable for the `Stringify` function, and we’ve seen
how the contract permits the `Stringify` function to call the `String`
method that it needs.
The final step is showing how the `Stringify` function uses the
`stringer` contract.
This is done by naming the contract at the end of the list of type
parameters.

```Go
func Stringify(type T stringer)(s []T) (ret []string) {
	for _, v := range s {
		ret = append(ret, v.String()) // now valid
	}
	return ret
}
```

The list of type parameters (in this case, a list of one element) is
followed by an optional contract name.
The contract must have the same number of parameters as the function
has type parameters; when validating the contract, the type parameters
are passed to the function in the order in which they appear in the
function definition.

### Contract syntactic details

Before we continue, let’s cover a few details of the contract syntax.

#### Passing explicit types to a contract

Although the normal case is for a function to validate the contract
with its exact list of type parameters, the contract can also be used
with a different set of types.

For example, this simple contract says that a value of type `From` may
be converted to the type `To`.

```Go
contract convertible(_ To, f From) {
	To(f)
}
```

Note that this contract body is quite simple.
It is a single statement expression that consists of a conversion
expression.
Since the contract body is never executed, it doesn’t matter that the
result of the conversion is not assigned to anything.
All that matters is whether the conversion expressed can be type
checked.

For example, this contract would permit the type arguments `(int64,
int32)` but would forbid the type arguments `([]int, complex64)`.

Given this contract, we can write this function, which may be invoked
with any type that can be converted to `uint64`.

```Go
func FormatUnsigned(type T convertible(uint64, T))(v T) string {
	return strconv.FormatUint(uint64(v), 10)
}
```

This could be called as, for example,

```Go
	s := FormatUnsigned(rune)('a')
```

This isn’t too useful with what we’ve described so far, but it will be
a bit more convenient when we get to type inference.

#### Restrictions on contract bodies

Although a contract looks like a function body, contracts may not
themselves have type parameters.
Contracts may also not have result parameters, and it follows that
they may not use a `return` statement to return values.

The body of a contract may not refer to any name defined in the
current package.
This rule is intended to make it harder to accidentally change the
meaning of a contract.
As a compromise, a contract is permitted to refer to names imported
from other packages, permitting a contract to easily say things like
"this type must support the `io.Reader` interface:"

```Go
contract Readable(r T) {
	io.Reader(r)
}
```

It is likely that this rule will have to be adjusted as we gain more
experience with this design.
For example, perhaps we should permit contracts to refer to exported
names defined in the same package, but not unexported names.
Or maybe we should have no such restriction and just rely on
correct programming supported by tooling.

As contract bodies are not executed, there are no restrictions about
unreachable statements, or `goto` statements across declarations, or
anything along those lines.

Of course, it is completely pointless to use a `goto` statement, or a
`break`, `continue`, or `fallthrough` statement, in a contract body,
as these statements do not say anything about the type arguments.

#### The contract keyword

Contracts may only appear at the top level of a package.

While contracts could be defined to work within the body of a
function, it’s hard to think of realistic examples in which they would
be useful.
We see this as similar to the way that methods can not be defined
within the body of a function.
A minor point is that only permitting contracts at the top level
permits the design to be Go 1 compatible.

There are a few ways to handle the syntax:

* We could make `contract` be a keyword only at the start of a
  top-level declaration, and otherwise be a normal identifier.
* We could declare that if you use `contract` at the start of a
  top-level declaration, then it becomes a keyword for the duration of
  that package.
* We could make `contract` always be a keyword, albeit one that can
  only appear in one place, in which case this design is not Go 1
  compatible.

#### Exported contracts

Like other top level declarations, a contract is exported if its name
starts with an upper-case letter.
An exported contract may be used by functions, types, or contracts in other
packages.

### Multiple type parameters

Although the examples shown so far only use a single type parameter,
naturally functions may have multiple type parameters.

```Go
func Print2(type T1, T2)(s1 []T1, s2 []T2) { ... }
```

Compare this to

```Go
func Print2Same(type T1)(s1 []T1, s2 []T1) { ... }
```

In `Print2` `s1` and `s2` may be slices of different types.
In `Print2Same` `s1` and `s2` must be slices of the same element
type.

Although functions may have multiple type parameters, they may only
have a single contract.

```Go
contract viaStrings(t To, f From) {
	var x string = f.String()
	t.Set(string("")) // could also use t.Set(x)
}

func SetViaStrings(type To, From viaStrings)(s []From) []To {
	r := make([]To, len(s))
	for i, v := range s {
		r[i].Set(v.String())
	}
	return r
}
```

### Parameterized types

We want more than just generic functions: we also want generic types.
We suggest that types be extended to take type parameters.

```Go
type Vector(type Element) []Element
```

A type’s parameters are just like a function’s type parameters.

Within the type definition, the type parameters may be used like any
other type.

To use a parameterized type, you must supply type arguments.
This looks like a function call, except that the function in this case
is actually a type.
This is called _instantiation_.

```Go
var v Vector(int)
```

Parameterized types can have methods.
The receiver type of a method must list the type parameters.
They are listed without the `type` keyword or any contract.

```Go
func (v *Vector(Element)) Push(x Element) { *v = append(*v, x) }
```

A parameterized type can refer to itself in cases where a type can
ordinarily refer to itself, but when it does so the type arguments
must be the type parameters.
This restriction avoids an infinite recursion of type instantiation.

```Go
// This is OK.
type List(type Element) struct {
	next *List(Element)
	val  Element
}

// This is INVALID.
type P(type Element1, Element2) struct {
	F *P(Element2, Element1) // INVALID; must be (Element1, Element2)
}
```

(Note: with more understanding of how people want to write code, it
may be possible to relax the reference rule to permit some cases that
use different type arguments.)

When a parameterized type is a struct, and the type parameter is
embedded as a field in the struct, the name of the field is the name
of the type parameter, not the name of the type argument.

```Go
type Lockable(type T) struct {
	T
	mu sync.Mutex
}

func (l *Lockable(T)) Get() T {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.T
}
```

(Note: this works poorly if you write `Lockable(X)` in the method
declaration: should the method return `l.T` or `l.X`?
Perhaps we should simply ban embedding a type parameter in a struct.)

### Parameterized type aliases

Type aliases may have parameters.

```Go
type Ptr(type Target) = *Target
```

Type aliases may refer to parameterized types, in which case any uses
of the type alias (other than in another type alias declaration) must
provide type arguments.

```Go
type V = Vector
var v2 V(int)
```

Type aliases may refer to instantiated types.

```Go
type VectorInt = Vector(int)
```

### Methods may not take additional type arguments

Although methods of a parameterized type may use the type’s
parameters, methods may not themselves have (additional) type
parameters.
Where it would be useful to add type arguments to a method, people
will have to write a top-level function.

Making this decision avoids having to specify the details of exactly
when a method with type arguments implements an interface.
(This is a feature that can perhaps be added later if it proves
necessary.)

### Contract embedding

A contract may embed another contract, by listing it in the
contract body with type arguments.
This will look like a function call in the contract body, but since
the call is to a contract it is handled as if the called contract’s
body were embedded in the calling contract, with the called contract’s
type parameters replaced by the type arguments provided in the
contract call.

This contract embeds the contract `stringer` defined earlier.

```Go
contract PrintStringer(x X) {
	stringer(X)
	x.Print()
}
```

This is roughly equivalent to

```Go
contract PrintStringer(x X) {
	var s string = x.String()
	x.Print()
}
```

It’s not exactly equivalent: the contract can’t refer to the variable
`s` after embedding `stringer(X)`.

### Using types that refer to themselves in contracts

Although this is implied by what has already been discussed, it’s
worth pointing out explicitly that a contract may require a method to
have an argument whose type is one of the contract’s type parameters.

```Go
package comparable

// The equal contract describes types that have an Equal method for
// the same type.
contract equal(v T) {
	// All that matters is type checking, so reusing v as the argument
	// means that the type argument must have a Equal method such that
	// the type argument itself is assignable to the Equal method’s
	// parameter type.
	var x bool = v.Equal(v)
}

// Index returns the index of e in s, or -1.
func Index(type T equal)(s []T, e T) int {
	for i, v := range s {
		// Both e and v are type T, so it’s OK to call e.Equal(v).
		if e.Equal(v) {
			return i
		}
	}
	return -1
}
```

This function can be used with any type that has an `Equal` method
whose single parameter type is the type itself.

```Go
import "comparable"

type EqualInt int

// The Equal method lets EqualInt implement the comparable.equal contract.
func (a EqualInt) Equal(b EqualInt) bool { return a == b }

func Index(s []EqualInt, e EqualInt) int {
	return comparable.Index(EqualInt)(s, e)
}
```

In this example, when we pass `EqualInt` to `comparable.Index`, we
check whether `EqualInt` satisfies the contract `comparable.equal`.
We replace `T` in the body of `comparable.equal` with `EqualInt`, and
see whether the result type checks.
`EqualInt` has a method `Equal` that accepts a parameter of type
`EqualInt`, so all is well, and the compilation succeeds.

### Mutually referential type parameters

Within a contract body, expressions may arbitrarily combine values of
any type parameter.

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

contract G(n Node, e Edge) {
	var _ []Edge = n.Edges()
	var from, to Node = e.Nodes()
}

type Graph(type Node, Edge G) struct { ... }
func New(type Node, Edge G)(nodes []Node) *Graph(Node, Edge) { ... }
func (*Graph(Node, Edge)) ShortestPath(from, to Node) []Edge { ... }
```

At first glance it might be hard to see how this differs from similar
code using interface types.
The difference is that although `Node` and `Edge` have specific
methods, they are not interface types.
In order to use `graph.Graph`, the type arguments used for `Node` and
`Edge` have to define methods that follow a certain pattern, but they
don’t have to actually use interface types to do so.

For example, consider these type definitions in some other package:

```Go
type Vertex struct { ... }
func (v *Vertex) Edges() []*FromTo { ... }
type FromTo struct { ... }
type (ft *FromTo) Nodes() (*Vertex, *Vertex) { ... }
```

There are no interface types here, but we can instantiate
`graph.Graph` using the type arguments `*Vertex` and `*FromTo`:

```Go
var g = graph.New(*Vertex, *FromTo)([]*Vertex{ ... })
```

`*Vertex` and `*FromTo` are not interface types, but when used
together they define methods that implement the contract `graph.G`.
Because of the way that the contract is written, we could also use the
non-pointer types `Vertex` and `FromTo`; the contract implies that the
function body will always be able to take the address of the argument
if necessary, and so will always be able to call the pointer method.

Although `Node` and `Edge` do not have to be instantiated with
interface types, it is also OK to use interface types if you like.

```Go
type NodeInterface interface { Edges() []EdgeInterface }
type EdgeInterface interface { Nodes() (NodeInterface, NodeInterface) }
```

We could instantiate `graph.Graph` with the types `NodeInterface` and
`EdgeInterface`, since they implement the `graph.G` contract.
There isn’t much reason to instantiate a type this way, but it is
permitted.

This ability for type parameters to refer to other type parameters
illustrates an important point: it should be a requirement for any
attempt to add generics to Go that it be possible to instantiate
generic code with multiple type arguments that refer to each other in
ways that the compiler can check.

### Values of type parameters are not boxed

In the current implementations of Go, interface values always hold
pointers.
Putting a non-pointer value in an interface variable causes the value
to be _boxed_.
That means that the actual value is stored somewhere else, on the heap
or stack, and the interface value holds a pointer to that location.

In contrast to interface values, values of instantiated polymorphic types are not boxed.
For example, let’s consider a function that works for any type `T`
with a `Set(string)` method that initializes the value based on a
string, and uses it to convert a slice of `string` to a slice of `T`.

```Go
package from

contract setter(x T) {
	var _ error = x.Set(string)
}

func Strings(type T setter)(s []string) ([]T, error) {
	ret := make([]T, len(s))
	for i, v := range s {
		if err := ret[i].Set(v); err != nil {
			return nil, err
		}
	}
	return ret, nil
}
```

Now let’s see some code in a different package.

```Go
type Settable int

func (p *Settable) Set(s string) (err error) {
	*p, err = strconv.Atoi(s)
	return err
}

func F() {
	// The type of nums is []Settable.
	nums, err := from.Strings(Settable)([]string{"1", "2"})
	// Settable can be converted directly to int.
	// This will set first to 1.
	first := int(nums[0])
	...
}
```

When we call `from.Strings` with the type `Settable` we get back a
`[]Settable` (and an error).
The values in that slice will be `Settable` values, which is to say,
they will be integers.
They will not be boxed as pointers, even though they were created and
set by a generic function.

Similarly, when a parameterized type is instantiated it will have the
expected types as fields.

```Go
package pair

type Pair(type carT, cdrT) struct {
	f1 carT
	f2 cdrT
}
```

When this is instantiated, the fields will not be boxed, and no
unexpected memory allocations will occur.
The type `pair.Pair(int, string)` is convertible to `struct { f1 int;
f2 string }`.

### Function argument type inference

In many cases, when calling a function with type parameters, we can
use type inference to avoid having to explicitly write out the type
arguments.

Go back to the example of a call to our simple `Print` function:

```Go
	Print(int)([]int{1, 2, 3})
```

The type argument `int` in the function call can be inferred from the
type of the non-type argument.

This can only be done when all the function’s type parameters are used
for the types of the function’s (non-type) input parameters.
If there are some type parameters that are used only for the
function’s result parameter types, or only in the body of the
function, then it is not possible to infer the type arguments for the
function.
For example, when calling `from.Strings` as defined earlier, the type
parameters cannot be inferred because the function’s type parameter
`T` is not used for an input parameter, only for a result.

When the function’s type arguments can be inferred, the language uses
type unification.
On the caller side we have the list of types of the actual (non-type)
arguments, which for the `Print` example here is simply `[]int`.
On the function side is the list of the types of the function’s
non-type parameters, which here is `[]T`.
In the lists, we discard arguments for which the function side does
not use a type parameter.
We must then unify the remaining argument types.

Type unification is a two pass algorithm.
In the first pass, untyped constants on the caller side, and their
corresponding types in the function definition, are ignored.

Corresponding types in the lists are compared.
Their structure must be identical, except that type parameters on the
function side match the type that appears on the caller side at the
point where the type parameter occurs.
If the same type parameter appears more than once on the function
side, it will match multiple argument types on the caller side.
Those caller types must be identical, or type unification fails, and
we report an error.

After the first pass, check any untyped constants on the caller side.
If there are no untyped constants, or if the type parameters in the
corresponding function types have matched other input types, then
type unification is complete.

Otherwise, for the second pass, for any untyped constants whose
corresponding function types are not yet set, determine the default
type of the untyped constant in [the usual
way](https://golang.org/ref/spec#Constants).
Then run the type unification algorithm again, this time with no
untyped constants.

In this example

```Go
	s1 := []int{1, 2, 3}
	Print(s1)
```

we compare `[]int` with `[]T`, match `T` with `int`, and we are done.
The single type parameter `T` is `int`, so we infer that the call
to `Print` is really a call to `Print(int)`.

For a more complex example, consider

```Go
package transform

func Slice(type From, To)(s []From, f func(From) To) []To {
	r := make([]To, len(s))
	for i, v := range s {
		r[i] = f(v)
	}
	return r
}
```

The two type parameters `From` and `To` are both used for input
parameters, so type inference is possible.
In the call

```Go
	strs := transform.Slice([]int{1, 2, 3}, strconv.Itoa)
```

we unify `[]int` with `[]From`, matching `From` with `int`.
We unify the type of `strconv.Itoa`, which is `func(int) string`,
with `func(From) To`, matching `From` with `int` and `To` with
`string`.
`From` is matched twice, both times with `int`.
Unification succeeds, changing the call from `transform.Slice` to
`transform.Slice(int, string)`.

To see the untyped constant rule in effect, consider

```Go
package pair

func New(type T)(f1, f2 T) *Pair(T) { ... }
```

In the call `pair.New(1, 2)` both arguments are untyped constants, so
both are ignored in the first pass.
There is nothing to unify.
We still have two untyped constants after the first pass.
Both are set to their default type, `int`.
The second run of the type unification pass unifies `T` with `int`,
so the final call is `pair.New(int)(1, 2)`.

In the call `pair.New(1, int64(2))` the first argument is an untyped
constant, so we ignore it in the first pass.
We then unify `int64` with `T`.
At this point the type parameter corresponding to the untyped constant
is fully determined, so the final call is `pair.New(int64)(1, int64(2))`.

In the call `pair.New(1, 2.5)` both arguments are untyped constants,
so we move on the second pass.
This time we set the first constant to `int` and the second to
`float64`.
We then try to unify `T` with both `int` and `float64`, so
unification fails, and we report a compilation error.

Note that type inference is done without regard to contracts.
First we use type inference to determine the type arguments to use for
the package, and then, if that succeeds, we check whether those type
arguments implement the contract.

Note that after successful type inference, the compiler must still
check that the arguments can be assigned to the parameters, as for any
function call.
This need not be the case when untyped constants are involved.

(Note: Type inference is a convenience feature.
Although we think it is an important feature, it does not add any
functionality to the design, only convenience in using it.
It would be possible to omit it from the initial implementation, and
see whether it seems to be needed.
That said, this feature doesn’t require additional syntax, and is
likely to significantly reduce the stutter of repeated type arguments
in code.)

(Note: We could also consider supporting type inference in composite
literals.

```Go
type Pair(type T) struct { f1, f2 T }
var V = Pair{1, 2} // inferred as Pair(int){1, 2}
```

It’s not clear how often this will arise in real code.)

### Instantiating a function

Go normally permits you to refer to a function without passing any
arguments, producing a value of function type.
You may not do this with a function that has type parameters; all type
arguments must be known at compile time.
However, you can instantiate the function, by passing type arguments,
without passing any non-type arguments.
This will produce an ordinary function value with no type parameters.

```Go
// PrintInts will have type func([]int).
var PrintInts = Print(int)
```

### Type assertions and switches

A useful function with type parameters will support any type argument
that implements the contract.
Sometimes, though, it’s possible to use a more efficient
implementation for some type arguments.
The language already has mechanisms for code to find out what type it
is working with: type assertions and type switches.
Those are normally only permitted with interface types.
In this design, functions are also permitted to use them with values
whose types are type parameters, or based on type parameters.

This doesn’t add any functionality, as the function could get the same
information using the reflect package.
It’s merely occasionally convenient, and it may result in more
efficient code.

For example, this code is permitted even if it is called with a type
argument that is not an interface type.

```Go
contract byteReader(x T) {
	// This expression says that x is convertible to io.Reader, or,
	// in other words, that x has a method Read([]byte) (int, error).
	io.Reader(x)
}

func ReadByte(type T byteReader)(r T) (byte, error) {
	if br, ok := r.(io.ByteReader); ok {
		return br.ReadByte()
	}
	var b [1]byte
	_, err := r.Read(b[:])
	return b[0], err
}
```

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
a parameterized type that we are instantiating with the type argument
`v2`.
The ambiguity is at the point where we see the parenthesis: at that
point the parser doesn’t know whether it is seeing a type conversion
or something like a composite literal.

To avoid this ambiguity, we require that type instantiations at the
end of a type literal be parenthesized.
In other words, we always parse `[]T(v1)` as a type conversion, not as
a potential instantiation of `T`.
To write a type literal that is a slice of a type instantiation, you
must write `[](T(v1))`.
This only applies to slice, array, map, chan, and func type literals
ending in a type name.
Of course it is always possible to use a separate type declaration to
give a name to the instantiated type, and to use that.
This is only an issue when the type is instantiated in place.

### Reflection

We do not propose to change the reflect package in any way.
When a type or function is instantiated, all of the type parameters
will become ordinary non-generic types.
The `String` method of a `reflect.Type` value of an instantiated type
will return the name with the type arguments in parentheses.
For example, `List(int)`.

It’s impossible for non-generic code to refer to generic code without
instantiating it, so there is no reflection information for
uninstantiated generic types or functions.

### Contracts details

Let’s take a deeper look at contracts.

Operations on values whose type is a type parameter must be permitted
by the type parameter’s contract.
This means that the power of generic functions is tied precisely to
the interpretation of the contract body.
It also means that the language requires a precise definition of the
operations that are permitted by a given contract.

The general guideline is straightforward: if a statement appears in a
contract, then that same statement may appear in a function using that
contract.
However, that guideline is clearly too limiting; it essentially
requires that the function body be copied into the contract body,
which makes the contract pointless.
Therefore, what needs to be clearly spelled out is the ways in which a
statement in a contract body can permit other kinds of expressions or
statements in the function body.
We don’t need to explain the meaning of every statement that can
appear in a contract body, only the ones that permit operations other
than an exact copy of the statement.

#### Methods

All the contracts we’ve seen so far show only method calls and type
conversions in the contract body.
If a method call appears in the contract body, that method may be
called on an addressable value in any statement or expression in the
function body.
It will take argument and result types as shown in the contract body.

The examples above use `var` declarations to specify the types of the
result parameters.
While it is valid to use a short declaration like `s := x.String()` in
a contract body, such a declaration says nothing about the result
type.
This would match a type argument with a `String` method that returns a
single result of any type.
It would not permit the function using the contract to use the result
of `x.String()`, since the type would not be known.

There are a few aspects to a method call that can not be shown in a
simple assignment statement like the ones shown above.

* There is no way to specify that a method does not return any
  values.
* There is no way to specify that a method takes variadic arguments.
* There is no way to distinguish a method call from a call of a struct
  field with function type.

When a contract needs to describe one of these cases, it can use a
type conversion to an interface type.
The interface type permits the method to be precisely described.
If the conversion to the interface type passes the type checker, then
the type argument must have a method of that exact type.

An explicit method call, or a conversion to an interface type, can not
be used to distinguish a pointer method from a value method.
When the function body calls a method on an addressable value, this
doesn’t matter; since all value methods are part of the pointer type’s
method set, an addressable value can call either pointer methods or
value methods.

However, it is possible to write a function body that can only call
a value method, not a pointer method.  For example:

```Go
contract adjustable(x T) {
	var _ T = x.Adjust()
	x.Apply()
}

func Apply(type T adjustable)(v T) {
	v.Adjust().Apply() // INVALID
}
```

In this example, the `Apply` method is not called on an addressable
value.
This can only work if the `Apply` method is a value method.
But writing `x.Apply()` in the contract permits a pointer method.

In order to use a value method in the function body, the contract must
express that the type has a value method rather than a pointer
method.
That can be done like this:

```Go
contract adjustable(x T) {
	var _ T = x.Adjust()
	var f func() T
	f().Apply()
}
```

The rule is that if the contract body contains a method call on a
non-addressable value, then the function body may call the method on a
non-addressable value.

#### Operators

Method calls are not sufficient for everything we want to express.
Consider this simple function that reports whether a parameterized
slice contains an element.

```Go
func Contains(type T)(s []T, e T) bool {
	for _, v := range s {
		if v == e { // INVALID
			return true
		}
	}
	return false
}
```

Any reasonable generics implementation should let you write this
function.
The problem is the expression `v == e`.
That assumes that `T` supports the `==` operator, but there is no
contract requiring that.
Without a contract the function body can only use operations that are
available for all types, but not all Go types support `==` (you can
not use `==` to compare values of slice, map, or function type).

This is easy to address using a contract.

```Go
contract comparable(x T) {
	x == x
}

func Contains(type T comparable)(s []T, e T) bool {
	for _, v := range s {
		if v == e { // now valid
			return true
		}
	}
	return false
}
```

In general, using an operator in the contract body permits using the
same operator with the same types anywhere in the function body.

For convenience, some operators also permit additional operations.

Using a binary operator in the contract body permits not only using
that operator by itself, but also the assignment version with `=`
appended if that exists.
That is, an expression like `x * x` in a contract body means that
generic code, given variables `a` and `b` of the type of `x`, may
write `a * b` and may also write `a *= b`.

Using the `==` operator with values of some type as both the left and
right operands means that the type must be comparable, and implies
that both `==` and `!=` may be used with values of that type.
Similarly, `!=` permits `==`.

Using the `<` operator with values of some type as both the left and
right operators means that the type must ordered, and implies that all
of `==`, `!=`, `<`, `<=`, `>=`, and `>` may be used with values of
that type.
Similarly for `<=`, `>=`, and `>`.

These additional operations permit a little more freedom when writing
the body of a function with type parameters: one can convert from `a =
a * b` to `a *= b`, or make the other changes listed above, without
having to modify the contract.

#### Type conversions

As already shown, the contract body may contain type conversions.
A type conversion in the contract body means that the function body
may use the same type conversion in any expression.

Here is an example that implements a checked conversion between
numeric types:

```Go
package check

contract convert(t To, f From) {
	To(f)
	From(t)
	f == f
}

func Convert(type To, From convert)(from From) To {
	to := To(from)
	if From(to) != from {
		panic("conversion out of range")
	}
	return to
}
```

Note that the contract needs to explicitly permit both converting `To`
to `From` and converting `From` to `To`.
The ability to convert one way doesn’t necessarily imply being able to
convert the other way; consider `check.Convert(int, interface{})(0, 0)`.

#### Untyped constants

Some functions are most naturally written using untyped constants.
The contract body needs ways to say that it is possible to convert an
untyped constant to some type.
This is most naturally written as an assignment from an untyped
constant.

```Go
contract untyped(x T) {
	x = 0
}
```

A contract of this form must be used in order to write code like `var
v T = 0`.

If a contract body has assignments with string (`x = ""`) or bool (`x
= false`) untyped constants, the function body is permitted to use any
untyped `string` or `bool` constant, respectively, with values of the
type.

For numeric types, the use of a single untyped constant only permits
using the exact specified value.
Using two untyped constant assignments for a type permits using those
constants and any value in between.
For complex untyped constants, the real and imaginary values may vary
to any values between the two constants.

Here is an example that adds 1000 to each element of a slice.
If the contract did not say `x = 1000`, the expression `v + 1000` would be
invalid.

```Go
contract add1K(x T) {
	x = 1000
	x + x
}

func Add1K(type T add1K)(s []T) {
	for i, v := range s {
		s[i] = v + 1000
	}
}
```

These untyped constant rules are not strictly required.
A type conversion expression such as `T(int)` permits converting any
`int` value to the type `T`, so it would permit code like `var x T =
T(1000)`.
What the untyped constant expressions permit is `var x T = 1000`,
without the explicit type conversion.
(Note that `int8` satisfies the `untyped` contract but not `add1K`,
since 1000 is out of range for `int8`.)

#### Booleans

In order to use a value of a type parameter as a condition in an `if`
or `for` statement, write an `if` or `for` statement in the contract
body: `if T {}` or `for T {}`.
This is only useful to instantiate a type parameter with a named
boolean type, and as such is unlikely to arise much in practice.

#### Sequences

Some simple operations in the contract body make it easier for the
function body to work on various sorts of sequences.

Using an index expression `x[y]` in a contract body permits using an
index expression with those types anywhere in the function body.
For anything other than a map type, the type of `y` will normally be
`int`; that case may also be written as `x[0]`.
Naturally, `z = x[y]` permits an index expression yielding the
specified type.

A statement like `x[y] = z` in the contract body permits the function
body to assign to an index element using the given types.
Again `x[0] = z` permits assignment using any `int` index.

A statement like `for x, y = range z {}` in the contract body permits
using either a one-element or a two-element `range` clause in a `for`
statement in the function body.

Using an expression like `len(x)` or `cap(x)` in the contract body
permits those builtin functions to be used with values of that type
anywhere in the function body.

Using contracts of this sort can permit operations on generic sequence
types.
For example, here is a version of `Join` that may be instantiated with
either `[]byte` or `string`.
This example is imperfect in that in the `string` case it will do some
unnecessary conversions to `[]byte` in order to call `append` and
`copy`, but perhaps the compiler can eliminate those.

```Go
contract strseq(x T) {
	[]byte(x)
	T([]byte{})
	len(x)
}

func Join(type T strseq)(a []T, sep T) (ret T) {
	if len(a) == 0 {
		// Use the result parameter as a zero value;
		// see discussion of zero value below.
		return ret
	}
	if len(a) == 1 {
		return T(append([]byte(nil), []byte(a[0])...))
	}
	n := len(sep) * (len(a) - 1)
	for i := 0; i < len(a); i++ {
		n += len(a[i])
	}

	b := make([]byte, n)
	bp := copy(b, []byte(a[0]))
	for _, s := range a[1:] {
		bp += copy(b[bp:], []byte(sep))
		bp += copy(b[bp:], []byte(s))
	}
	return T(b)
}
```

#### Fields

Using `x.f` in a contract body permits referring to the field in any
expression in the function body.
The contract body can use `var y = x.f` to describe the field’s type.

```Go
package move

contract counter(x T) {
	var _ int = x.Count
}

contract counters(T1, T2) { // as with a func, parameter names may be omitted.
	// Use contract embedding to say that both types must have a
	// Count field of type int.
	counter(T1)
	counter(T2)
}

func Corresponding(type T1, T2 counters)(p1 *T1, p2 *T2) {
	p1.Count = p2.Count
}
```

The function `move.Corresponding` will copy the `Count` field from one
struct to the other.
The structs may be entirely different types, as long as they both have
a `Count` field with type `int`.

A field reference in a contract body also permits using a keyed
composite literal in the function body, as in `T1{Count: 0}`.

#### Impossible contracts

It is possible to write a contract body that cannot be implemented by
any Go type.
This is not forbidden.
An error will be reported not when the contract or function or type is
compiled, but on any attempt to instantiate it.
This eliminates the need for the language spec to provide an
exhaustive set of rules describing when a contract body cannot be
satisfied.

It may be appropriate to add a vet check for this, if possible.

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

While this design is long and detailed, it reduces to a few major
points.

* Functions and types can have type parameters, which are defined
  using optional contracts.
* Contracts describe the operations permitted for a type parameter
  and required for a type argument.
* Type inference can sometimes permit omitting type arguments when
  calling functions with type parameters.

This design is completely backward compatible, in that any valid Go 1
program will still be valid if this design is adopted (assuming
`contract` is treated as a pseudo-keyword that is only meaningful at
top level).

We believe that this design addresses people’s needs for generic
programming in Go, without making the language any more complex than
necessary.

We can’t truly know the impact on the language without years of
experience with this design.
That said, here are some speculations.

#### Complexity

One of the great aspects of Go is its simplicity.
Clearly this design makes the language more complex.

We believe that the increased complexity is minor for people reading
generic code, rather than writing it.
Naturally people must learn the new syntax for declaring type
parameters.
The code within a generic function reads like ordinary Go code, as can
be seen in the examples below.
It is an easy shift to go from `[]int` to `[]T`.
Type parameter contracts serve effectively as documentation,
describing the type.

We expect that most people will not write generic code themselves, but
many people are likely to write packages that use generic code written
by others.
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

People using generic types will have to pass explicit type arguments.
The syntax for this is familiar.
The only change is passing arguments to types rather than only to
functions.

For the minority of people writing generic packages, we expect that
the most complicated part will be writing correct contract bodies.
Good compiler error messages will be essential, and they seem entirely
feasible.
We can’t deny the additional complexity here, but we believe that the
design avoids confusing cases and provides the facilities that
people need to write whatever generic code is desired.

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

Packages like `container/list` and `container/ring`, and types like
`sync.Map`, will be updated to be compile-time type-safe.

The `math` package will be extended to provide a set of simple
standard algorithms for all numeric types, such as the ever popular
`Min` and `Max` functions.

It is likely that new special purpose compile-time type-safe container
types will be developed, and some may become widely used.

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
That will optimize compile time, in that the package is only compiled
once, but there will be some run-time cost.

Generic types may most naturally be compiled multiple times for each
set of type arguments.
This will clearly carry a compile time cost, but there shouldn’t be
any run-time cost.
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
  that are designed to work with specific type arguments (other than
  using type assertions or type switches).
* No metaprogramming.
  There is no way to write code that is executed at compile time to
  generate code to be executed at run time.
* No higher-level abstraction.
  There is no way to speak about a function with type arguments other
  than to call it or instantiate it.
  There is no way to speak about a parameterized type other than to
  instantiate it.
* No covariance or contravariance.
* No operator methods.
  You can write a generic container that is compile-time type-safe,
  but you can only access it with ordinary methods, not with syntax
  like `c[k]`.
  Similarly, there is no way to use `range` with a generic container
  type.
* No currying.
  There is no way to specify only some of the type arguments, other
  than by using a type alias or a helper function.
* No adaptors.
  There is no way for a contract to define adaptors that could be used
  to support type arguments that do not already satisfy the contract,
  such as, for example, defining an `==` operator in terms of an
  `Equal` method.
* No parameterization on non-type values.
  This arises most obviously for arrays, where it might sometimes be
  convenient to write `type Matrix(type n int) [n][n]float64`.
  It might also sometimes be useful to specify significant values for
  a container type, such as a default value for elements.

#### Issues

There are some issues with this design that deserve a more detailed
discussion.
We think these issues are relatively minor compared with the design
as a whole, but they still deserve a complete hearing and discussion.

##### The zero value

This design has no simple expression for the zero value of a type
parameter.
For example, consider this implementation of optional values by using
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
It would be nice to be able to write `return nil`, but that wouldn’t
work if `T` is, say, `int`; in that case we would have to write
`return 0`.

Some approaches to this are:

* Use `var zero T`, as above, which works with the existing design
  but requires an extra statement.
* Use `*new(T)`, which is ugly but works with the existing design.
* Extend the design to permit using `nil` as the zero value of any
  generic type (but see [issue 22729](https://golang.org/issue/22729)).
* Extend the design to permit using `T{}`, where `T` is a type
  parameter, to indicate the zero value of the type.
* Change the language to permit using `_` on the right hand of an
  assignment (including `return` or a function call) as proposed in
  [issue 19642](https://golang.org/issue/19642).

We feel that more experience with this design is needed before
deciding what, if anything, to do here.

##### Lots of irritating silly parentheses

Calling a function with type parameters requires an additional list of
type arguments if the type arguments can not be inferred.
If the function returns a function, and we call that, we get still
more parentheses.

```Go
	F(int, float64)(x, y)(s)
```

We experimented with other syntaxes, such as using a colon to separate
the type arguments from the regular arguments.
The current design seems to be the best, but perhaps something
better is possible.

##### What does := mean in a contract body?

If a contract body uses a short declaration, such as

```Go
	s := x.String()
```

this does not provide any information about the result parameter of
the `String` method.
This contract body would match any type with a `String` method that
returns a single result of any type.
It’s less clear what it permits in the function using this contract.
For example, does it permit the function to call the `String` method
and assign the result to a variable of empty interface type?

##### Pointer vs. value methods in contracts

It seems that the natural ways to write a contract calling for certain
methods to exist will accept either a pointer method or a value
method.
That may be confusing, in that it will prevent writing a function body
that requires a value method.
We will have to judge from experience how much this confuses people in
practice.

##### Copying the function body into the contract body

The simplest way to ensure that a function only performs the
operations permitted by its contract is to simply copy the function
body into the contract body.
In other words, to make the function body be its own contract, much as
C++ does.
If people take this path, then this design in effect creates a lot of
additional complexity for no benefit.

We think this is unlikely because we believe that most people will not
write generic function, and we believe that most generic functions
will have only non-existent or trivial requirements on their type
parameters.
More experience will be needed to see whether this is a problem.

#### Discarded ideas

This design is not perfect, and it will be changed as we gain
experience with it.
That said, there are many ideas that we’ve already considered in
detail.
This section lists some of those ideas in the hopes that it will help
to reduce repetitive discussion.
The ideas are presented in the form of a FAQ.

##### Why not use interfaces instead of contracts?

_The interface method syntax is familiar._
_Writing contract bodies with `x + x` is ordinary Go syntax, but it_
_is stylized, repetitive, and looks weird._

It is unclear how to represent operators using interface methods.
We considered syntaxes like `+(T, T) T`, but that is confusing and
repetitive.
Also, a minor point, but `==(T, T) bool` does not correspond to the
`==` operator, which returns an untyped boolean value, not `bool`.
We also considered writing simply `+` or `==`.
That seems to work but unfortunately the semicolon insertion rules
require writing a semicolon after each operator at the end of a line.
Using contracts that look like functions gives us a familiar syntax at
the cost of some repetition.
These are not fatal problems, but they are difficulties.

##### Why not put type parameters on packages?

We investigated this extensively.
It becomes problematic when you want to write a `list` package, and
you want that package to include a `Transform` function that converts
a `List` of one element type to a `List` of another element type.
It’s very awkward for a function in one instantiation of a package to
return a type that requires a different instantiation of the package.

It also confuses package boundaries with type definitions.
There is no particular reason to think that the uses of parameterized
types will break down neatly into packages.
Sometimes they will, sometimes they won’t.

##### Why not use `F<T>` like C++ and Java?

When parsing code within a function, such as `v := F<T>`, at the point
of seeing the `<` it’s ambiguous whether we are seeing a type
instantiation or an expression using the `<` operator.
Resolving that requires effectively unbounded lookahead.
In general we strive to keep the Go parser simple.

##### Why not use `F[T]`?

When parsing a type declaration `type A [T] int` it’s ambiguous
whether this is a parameterized type defined (uselessly) as `int` or
whether it is an array type with `T` elements.

##### Why not use `F«T»`?

We considered it but we couldn’t bring ourselves to require
non-ASCII.

##### Why not define contracts in a standard package?

_Instead of writing out contracts, use names like_
_`contracts.Arithmetic` and `contracts.Comparable`._

Listing all the possible combinations of types gets rather lengthy.
It also introduces a new set of names that not only the writer of
generic code, but, more importantly, the reader, must remember.
One of the driving goals of this design is to not introduce new
names.
Instead we introduce one new keyword and some new syntax.

We expect that if people find such names useful, we can introduce a
package `contracts` that defines the useful names in the form of
contracts that can be used by other types and functions and embedded
in other contracts.

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
This design avoids these problems through explicit contracts.

C++ supports template metaprogramming, which can be thought of as
ordinary programming done at compile time using a syntax that is
completely different than that of non-template C++.
This design has no similar feature.
This saves considerable complexity while losing some power and
run-time efficiency.

### Examples

The following sections are examples of how this design could be used.
This is intended to address specific areas where people have created
user experience reports concerned with Go’s lack of generics.

#### sort

Before the introduction of `sort.Slice`, a common complaint was the
need for boilerplate definitions in order to use `sort.Sort`.
With this design, we can add to the sort package as follows:

```Go
contract ordered(e Ele) { e < e }

type orderedSlice(type Ele ordered) []Ele

func (s orderedSlice(Ele)) Len() int           { return len(s) }
func (s orderedSlice(Ele)) Less(i, j int) bool { return s[i] < s[j] }
func (s orderedSlice(Ele)) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }

// OrderedSlice sorts the slice s in ascending order.
// The elements of s must be ordered using the < operator.
func OrderedSlice(type Ele ordered)(s []Ele) {
	sort.Sort(orderedSlice(Ele)(s))
}
```

Now we can write:

```Go
	sort.OrderedSlice(int32)([]int32{3, 5, 2})
```

We can rely on type inference to omit the type argument list:

```Go
	sort.OrderedSlice([]string{"a", "c", "b"})
```

Along the same lines, we can add a function for sorting using a
comparison function, similar to `sort.Slice` but writing the function
to take values rather than slice indexes.

```Go
type sliceFn(type Ele) struct {
	s []Ele
	f func(Ele, Ele) bool
}

func (s sliceFn(Ele)) Len() int           { return len(s.s) }
func (s sliceFn(Ele)) Less(i, j int) bool { return s.f(s.s[i], s.s[j]) }
func (s sliceFn(Ele)) Swap(i, j int)      { s.s[i], s.s[j] = s.s[j], s.s[i] }

// SliceFn sorts the slice s according to the function f.
func SliceFn(type Ele)(s []Ele, f func(Ele, Ele) bool) {
	Sort(sliceFn(Ele){s, f})
}
```

An example of calling this might be:

```Go
	var s []*Person
	// ...
	sort.SliceFn(s, func(p1, p2 *Person) bool { return p1.Name < p2.Name })
```

#### map keys

Here is how to get a slice of the keys of any map.

```Go
package maps

contract mappable(k K, _ V) { k == k }

func Keys(type K, V mappable)(m map[K]V) []K {
	r := make([]K, 0, len(m))
	for k := range m {
		r = append(r, k)
	}
	return r
}
```

In typical use the types will be inferred.

```Go
	k := maps.Keys(map[int]int{1:2, 2:4}) // sets k to []int{1, 2} (or {2, 1})
```

#### map/reduce/filter

Here is an example of how to write map, reduce, and filter functions
for slices.
These functions are intended to correspond to the similar functions in
Lisp, Python, Java, and so forth.

```Go
// Package slices implements various slice algorithms.
package slices

// Map turns a []T1 to a []T2 using a mapping function.
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

Example calls:

```Go
	s := []int{1, 2, 3}
	floats := slices.Map(s, func(i int) float64 { return float64(i) })
	sum := slices.Reduce(s, 0, func(i, j int) int { return i + j })
	evens := slices.Filter(s, func(i int) bool { return i%2 == 0 })
```

#### sets

Many people have asked for Go’s builtin map type to be extended, or
rather reduced, to support a set type.
Here is a type-safe implementation of a set type, albeit one that uses
methods rather than operators like `[]`.

```Go
// Package set implements sets of any type.
package set

contract comparable(Ele) { Ele == Ele }

type Set(type Ele comparable) map[Ele]struct{}

func Make(type Ele comparable)() Set(Ele) {
	return make(Set(Ele))
}

func (s Set(Ele)) Add(v Ele) {
	s[v] = struct{}{}
}

func (s Set(Ele)) Delete(v Ele) {
	delete(s, v)
}

func (s Set(Ele)) Contains(v Ele) bool {
	_, ok := s[v]
	return ok
}

func (s Set(Ele)) Len() int {
	return len(s)
}

func (s Set(Ele)) Iterate(f func(Ele)) {
	for v := range s {
		f(v)
	}
}
```

Example use:

```Go
	s := set.Make(int)
	s.Add(1)
	if s.Contains(2) { panic("unexpected 2") }
```

This example, like the sort examples above, shows how to use this
design to provide a compile-time type-safe wrapper around an
existing API.

#### channels

Many simple general purpose channel functions are never written,
because they must be written using reflection and the caller must type
assert the results.
With this design they become easy to write.

```Go
package chans

import "runtime"

// Ranger returns a Sender and a Receiver. The Receiver provides a
// Next method to retrieve values. The Sender provides a Send method
// to send values and a Close method to stop sending values. The Next
// method indicates when the Sender has been closed, and the Send
// method indicates when the Receiver has been freed.
//
// This is a convenient way to exit a goroutine sending values when
// the receiver stops reading them.
func Ranger(type T)() (*Sender(T), *Receiver(T)) {
	c := make(chan T)
	d := make(chan bool)
	s := &Sender(T){values: c, done: d}
	r := &Receiver(T){values: c, done: d}
	runtime.SetFinalizer(r, (*Receiver(T)).finalize)
	return s, r
}

// A sender is used to send values to a Receiver.
type Sender(type T) struct {
	values chan<- T
	done <-chan bool
}

// Send sends a value to the receiver. It reports whether any more
// values may be sent; if it returns false the value was not sent.
func (s *Sender(T)) Send(v T) bool {
	select {
	case s.values <- v:
		return true
	case <-s.done:
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
	done chan<- bool
}

// Next returns the next value from the channel. The bool result
// indicates whether the value is valid, or whether the Sender has
// been closed and no more values will be received.
func (r *Receiver(T)) Next() (T, bool) {
	v, ok := <-r.values
	return v, ok
}

// finalize is a finalizer for the receiver.
func (r *Receiver(T)) finalize() {
	close(r.done)
}
```

There is an example of using this function in the next section.

#### containers

One of the frequent requests for generics in Go is the ability to
write compile-time type-safe containers.
This design makes it easy to write a compile-time type-safe wrapper
around an existing container; we won’t write out an example for that.
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
	key         K
	val         V
	left, right *node(K, V)
}

// New returns a new map.
func New(type K, V)(compare func(K, K) int) *Map(K, V) {
	return &Map(K, V){compare: compare}
}

// find looks up key in the map, and returns either a pointer
// to the node holding key, or a pointer to the location where
// such a node would go.
func (m *Map(K, V)) find(key K) **node(K, V) {
	pn := &m.root
	for *pn != nil {
		switch cmp := m.compare(key, (*pn).key); {
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
// Returns true if this is a new key, false if already present.
func (m *Map(K, V)) Insert(key K, val V) bool {
	pn := m.find(key)
	if *pn != nil {
		(*pn).val = val
		return false
	}
	*pn = &node(K, V){key: key, val: val}
	return true
}

// Find returns the value associated with a key, or zero if not present.
// The found result reports whether the key was found.
func (m *Map(K, V)) Find(key K) (V, bool) {
	pn := m.find(key)
	if *pn == nil {
		var zero V // see the discussion of zero values, above
		return zero, false
	}
	return (*pn).val, true
}

// keyValue is a pair of key and value used when iterating.
type keyValue(type K, V) struct {
	key K
	val V
}

// InOrder returns an iterator that does an in-order traversal of the map.
func (m *Map(K, V)) InOrder() *Iterator(K, V) {
	sender, receiver := chans.Ranger(keyValue(K, V))()
	var f func(*node(K, V)) bool
	f = func(n *node(K, V)) bool {
		if n == nil {
			return true
		}
		// Stop sending values if sender.Send returns false,
		// meaning that nothing is listening at the receiver end.
		return f(n.left) &&
			sender.Send(keyValue(K, V){n.key, n.val}) &&
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

// Next returns the next key and value pair, and a boolean indicating
// whether they are valid or whether we have reached the end.
func (it *Iterator(K, V)) Next() (K, V, bool) {
	keyval, ok := it.r.Next()
	if !ok {
		var zerok K
		var zerov V
		return zerok, zerov, false
	}
	return keyval.key, keyval.val, true
}
```

This is what it looks like to use this package:

```Go
import "container/orderedmap"

var m = orderedmap.New(string, string)(strings.Compare)

func Add(a, b string) {
	m.Insert(a, b)
}
```

#### append

The predeclared `append` function exists to replace the boilerplate
otherwise required to grow a slice.
Before `append` was added to the language, there was a function `Add`
in the bytes package with the signature

```Go
func Add(s, t []byte) []byte
```

that appended two `[]byte` values together, returning a new slice.
That was fine for `[]byte`, but if you had a slice of some other
type, you had to write essentially the same code to append more
values.
If this design were available back then, perhaps we would not have
added `append` to the language.
Instead, we could write something like this:

```Go
package slices

// Append adds values to the end of a slice, returning a new slice.
func Append(type T)(s []T, t ...T) []T {
	lens := len(s)
	tot := lens + len(t)
	if tot <= cap(s) {
		s = s[:tot]
	} else {
		news := make([]T, tot, tot + tot/2)
		copy(news, s)
		s = news
	}
	copy(s[lens:tot], t)
	return s
}
```

That example uses the predeclared `copy` function, but that’s OK, we
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
	slices.Copy(s[3:], []int{7, 8, 9})
```

This code doesn’t implement the special case of appending or copying a
`string` to a `[]byte`, and it’s unlikely to be as efficient as the
implementation of the predeclared function.
Still, this example shows that using this design would permit append
and copy to be written generically, once, without requiring any
additional special language features.

#### metrics

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
package metrics

import "sync"

contract comparable(v T)  {
	v == v
}

contract cmp1(T) {
	comparable(T) // contract embedding
}

type Metric1(type T cmp1) struct {
	mu sync.Mutex
	m  map[T]int
}

func (m *Metric1(T)) Add(v T) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.m == nil {
		m.m = make(map[T]int)
	}
	m[v]++
}

contract cmp2(T1, T2) {
	comparable(T1)
	comparable(T2)
}

type key2(type T1, T2 cmp2) struct {
	f1 T1
	f2 T2
}

type Metric2(type T1, T2 cmp2) struct {
	mu sync.Mutex
	m  map[key2(T1, T2)]int
}

func (m *Metric2(T1, T2)) Add(v1 T1, v2 T2) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.m == nil {
		m.m = make(map[key2(T1, T2)]int)
	}
	m[key(T1, T2){v1, v2}]++
}

contract cmp3(T1, T2, T3) {
	comparable(T1)
	comparable(T2)
	comparable(T3)
}

type key3(type T1, T2, T3 cmp3) struct {
	f1 T1
	f2 T2
	f3 T3
}

type Metric3(type T1, T2, T3 cmp3) struct {
	mu sync.Mutex
	m  map[key3(T1, T2, T3)]int
}

func (m *Metric3(T1, T2, T3)) Add(v1 T1, v2 T2, v3 T3) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.m == nil {
		m.m = make(map[key3]int)
	}
	m[key(T1, T2, T3){v1, v2, v3}]++
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

This package implementation does have a certain amount of repetition
due to the lack of support for variadic package type parameters.
Using the package, though, is easy and type safe.

#### list transform

While slices are efficient and easy to use, there are occasional cases
where a linked list is appropriate.
This example primarily shows transforming a linked list of one type to
another type, as an example of using different instantiations of the
same parameterized type.

```Go
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

// Transform runs a transform function on a list, returning a new list.
func Transform(type T1, T2)(lst *List(T1), f func(T1) T2) *List(T2) {
	ret := &List(T2){}
	it := lst.Range()
	for {
		if v, ok := it.Val(); ok {
			ret.Push(f(v))
		}
		it.Next()
	}
	return ret
}
```

#### context

The standard "context" package provides a `Context.Value` method to
fetch a value from a context.
The method returns `interface{}`, so using it normally requires a type
assertion to the correct type.
Here is an example of how we can add type parameters to the "context"
package to provide a type-safe wrapper around `Context.Value`.

```Go
// Key is a key that can be used with Context.Value.
// Rather than calling Context.Value directly, use Key.Load.
//
// The zero value of Key is not ready for use; use NewKey.
type Key(type V) struct {
	name string
}

// NewKey returns a key used to store values of type V in a Context.
// Every Key returned is unique, even if the name is reused.
func NewKey(type V)(name string) *Key {
	return &Key(V){name: name}
}

// WithValue returns a new context with v associated with k.
func (k *Key(V)) WithValue(parent Context, v V) Context {
	return WithValue(parent, k, v)
}

// Value loads the value associated with k from ctx and reports
//whether it was successful.
func (k *Key(V)) Value(ctx Context) (V, bool) {
	v, present := ctx.Value(k).(V)
	return v.(V), present
}

// String returns the name and expected value type.
func (k *Key(V)) String() string {
	var v V
	return fmt.Sprintf("%s(%T)", k.name, v)
}
```

To see how this might be used, consider the net/http package’s
`ServerContextKey`:

```Go
var ServerContextKey = &contextKey{"http-server"}

	// used as:
	ctx := context.Value(ServerContextKey, srv)
	s, present := ctx.Value(ServerContextKey).(*Server)
```

This could be written instead as

```Go
var ServerContextKey = context.NewKey(*Server)("http_server")

	// used as:
	ctx := ServerContextKey.WithValue(ctx, srv)
	s, present := ServerContextKey.Value(ctx)
```

Code that uses `Key.WithValue` and `Key.Value` instead of
`context.WithValue` and `context.Value` does not need any type
assertions and is compile-time type-safe.
