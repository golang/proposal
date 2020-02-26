# Contracts — Draft Design

Ian Lance Taylor\
Robert Griesemer\
July 31, 2019

## Abstract

We suggest extending the Go language to add optional type parameters
to types and functions.
Type parameters may be constrained by contracts: they may be used as
ordinary types that only support the operations permitted by the
contracts.
Type inference via a unification algorithm is supported to permit
omitting type arguments from function calls in many cases.
Depending on a detail, the design can be fully backward compatible
with Go 1.

## Background

This version of the design draft is similar to the one presented on
August 27, 2018, except that the syntax of contracts is completely
different.

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
examination of contracts.

This design draft suggests extending the Go language to add a form of
parametric polymorphism, where the type parameters are bounded not by
a subtyping relationship but by explicitly defined structural
constraints.
Among other languages that support parameteric polymorphism this
design is perhaps most similar to Ada, although the syntax is
completely different.

This design does not support template metaprogramming or any other
form of compile time programming.

As the term _generic_ is widely used in the Go community, we will
use it below as a shorthand to mean a function or type that takes type
parameters.
Don't confuse the term generic as used in this design with the same
term in other languages like C++, C#, Java, or Rust; they have
similarities but are not the same.

## Design

We will describe the complete design in stages based on examples.

### Type parameters

Generic code is code that is written using types that will be
specified later.
Each unspecified type is called a _type parameter_.
When running the generic code, the type parameter will be set to a
_type argument_.

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
At the call site, the `type` keyword is not required.

```Go
	Print(int)([]int{1, 2, 3})
```

### Type contracts

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

This might seem OK at first glance, but in this example, `v` has type
`T`, and we don't know anything about `T`.
In particular, we don't know that `T` has a `String` method.
So the call to `v.String()` is invalid.

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
In Go we don't refer to names, such as, in this case, `String`, and
hope that they exist.
Go resolves all names to their declarations when they are seen.

Another reason is that Go is designed to support programming at
scale.
We must consider the case in which the generic function definition
(`Stringify`, above) and the call to the generic function (not shown,
but perhaps in some other package) are far apart.
In general, all generic code implies a contract that type arguments
need to implement.
In this case, the contract is pretty obvious: the type has to have a
`String() string` method.
In other cases it may be much less obvious.
We don't want to derive the contract from whatever `Stringify` happens
to do.
If we did, a minor change to `Stringify` might change the contract.
That would mean that a minor change could cause code far away, that
calls the function, to unexpectedly break.
It's fine for `Stringify` to deliberately change its contract, and
force users to change.
What we want to avoid is `Stringify` changing its contract
accidentally.

This is an important rule that we believe should apply to any attempt
to define generic programming in Go: there should be an explicit
contract between the generic code and calling code.

### Contract introduction

In this design, a contract describes the requirements of a set of
types.
We'll discuss contracts further later, but for now we'll just say that
one of the things that a contract can do is specify that a type
argument must implement a particular method.

For the `Stringify` example, we need to write a contract that says
that the single type parameter has a `String` method that takes no
arguments and returns a value of type `string`.
We write that like this:

```Go
contract stringer(T) {
	T String() string
}
```

A contract is introduced with a new keyword `contract`, followed by a
name and a list of identifiers.
The identifiers name the types that the contract will specify.
Specifying a required method looks like defining a method in an
interface type, except that the receiver type must be explicitly
provided.

### Using a contract to verify type arguments

A contract serves two purposes.
First, contracts are used to validate a set of type arguments.
As shown above, when a function with type parameters is called, it
will be called with a set of type arguments.
When the compiler sees the function call, it will use the contract to
validate the type arguments.
If the type arguments don't satisfy the requirements specified by the
contract, the compiler will report a type error: the call is using
types that the function's contract does not permit.

The `stringer` contract seen earlier requires that the type argument
used for `T` has a `String` method that takes no arguments and
returns a value of type `string`.

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
parameter, or a value of the type parameter, the contract must
explicitly support that action.
In the `stringer` example seen earlier, the contract provides the
ability to call a method `String` on a value of the type parameter.
That is, naturally, exactly the operation that the `Stringify`
function needs.

### Using a contract

We've seen how the `stringer` contract can be used to verify that a
type argument is suitable for the `Stringify` function, and we've seen
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

The list of type parameters (in this case, a list with the single
element `T`) is followed by an optional contract name.
When just the contract name is listed, as above, the contract must
have the same number of parameters as the function has type
parameters; when validating the contract, the type parameters are
passed to the contract in the order in which they appear in the
function signature.
Later we'll discuss passing explicit type parameters to the contract.

### Multiple type parameters

Although the examples we've seen so far use only a single type
parameter, functions may have multiple type parameters.

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
contract viaStrings(To, From) {
	To   Set(string)
	From String() string
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

A type's parameters are just like a function's type parameters.

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
must be the type parameters, listed in the same order.
This restriction prevents infinite recursion of type instantiation.

```Go
// This is OK.
type List(type Element) struct {
	next *List(Element)
	val  Element
}

// This type is INVALID.
type P(type Element1, Element2) struct {
	F *P(Element2, Element1) // INVALID; must be (Element1, Element2)
}
```

(Note: with more understanding of how people want to write code, it
may be possible to relax this rule to permit some cases that use
different type arguments.)

The type parameter of a parameterized type may have contracts.

```Go
type StringableVector(type T stringer) []T

func (s StringableVector(T)) String() string {
	var sb strings.Builder
	sb.WriteString("[")
	for i, v := range s {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString(v.String())
	}
	sb.WriteString("]")
	return sb.String()
}
```

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

### Parameterized type aliases

Type aliases may not have parameters.
This restriction exists because it is unclear how to handle a type
alias with type parameters that have a contract.

Type aliases may refer to instantiated types.

```Go
type VectorInt = Vector(int)
```

If a type alias refers to a parameterized type, it must provide type
arguments.

### Methods may not take additional type arguments

Although methods of a parameterized type may use the type's
parameters, methods may not themselves have additional type
parameters.
Where it would be useful to add type arguments to a method, people
will have to write a suitably parameterized top-level function.

This restriction avoids having to specify the details of exactly when
a method with type arguments implements an interface.
(This is a feature that can perhaps be added later if it proves
necessary.)

### Contract embedding

A contract may embed another contract, by listing it in the
contract body with type arguments.
This will look a bit like a method definition in the contract body,
but it will be different because there will be no receiver type.
It is handled as if the embedded contract's body were placed into the
calling contract, with the embedded contract's type parameters
replaced by the embedded type arguments.

This contract embeds the contract `stringer` defined earlier.

```Go
contract PrintStringer(X) {
	stringer(X)
	X Print()
}
```

This is equivalent to

```Go
contract PrintStringer(X) {
	X String() string
	X Print()
}
```

### Using types that refer to themselves in contracts

Although this is implied by what has already been discussed, it's
worth pointing out explicitly that a contract may require a method to
have an argument whose type is the same as the method's receiver
type.

```Go
package compare

// The equal contract describes types that have an Equal method with
// an argument of the same type as the receiver type.
contract equal(T) {
	T Equal(T) bool
}

// Index returns the index of e in s, or -1.
func Index(type T equal)(s []T, e T) int {
	for i, v := range s {
		// Both e and v are type T, so it's OK to call e.Equal(v).
		if e.Equal(v) {
			return i
		}
	}
	return -1
}
```

This function can be used with any type that has an `Equal` method
whose single parameter type is the same as the receiver type.

```Go
import "compare"

type EqualInt int

// The Equal method lets EqualInt satisfy the compare.equal contract.
func (a EqualInt) Equal(b EqualInt) bool { return a == b }

func Index(s []EqualInt, e EqualInt) int {
	return compare.Index(EqualInt)(s, e)
}
```

In this example, when we pass `EqualInt` to `compare.Index`, we
check whether `EqualInt` satisfies the contract `compare.equal`.
We replace `T` with `EqualInt` in the declaration of the `Equal`
method in the `equal` contract, and see whether `EqualInt` has a
matching method.
`EqualInt` has a method `Equal` that accepts a parameter of type
`EqualInt`, so all is well, and the compilation succeeds.

### Mutually referencing type parameters

Within a contract, methods may refer to any of the contract's type
parameters.

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

contract G(Node, Edge) {
	Node Edges() []Edge
	Edge Nodes() (from Node, to Node)
}

type Graph(type Node, Edge G) struct { ... }
func New(type Node, Edge G)(nodes []Node) *Graph(Node, Edge) { ... }
func (g *Graph(Node, Edge)) ShortestPath(from, to Node) []Edge { ... }
```

While at first glance this may look like a typical use of interface
types, `Node` and `Edge` are non-interface types with specific
methods.
In order to use `graph.Graph`, the type arguments used for `Node` and
`Edge` have to define methods that follow a certain pattern, but they
don't have to actually use interface types to do so.

For example, consider these type definitions in some other package:

```Go
type Vertex struct { ... }
func (v *Vertex) Edges() []*FromTo { ... }
type FromTo struct { ... }
func (ft *FromTo) Nodes() (*Vertex, *Vertex) { ... }
```

There are no interface types here, but we can instantiate
`graph.Graph` using the type arguments `*Vertex` and `*FromTo`:

```Go
var g = graph.New(*Vertex, *FromTo)([]*Vertex{ ... })
```

`*Vertex` and `*FromTo` are not interface types, but when used
together they define methods that implement the contract `graph.G`.
Note that we couldn't use plain `Vertex` or `FromTo`, since the
required methods are pointer methods, not value methods.

Although `Node` and `Edge` do not have to be instantiated with
interface types, it is also OK to use interface types if you like.

```Go
type NodeInterface interface { Edges() []EdgeInterface }
type EdgeInterface interface { Nodes() (NodeInterface, NodeInterface) }
```

We could instantiate `graph.Graph` with the types `NodeInterface` and
`EdgeInterface`, since they implement the `graph.G` contract.
There isn't much reason to instantiate a type this way, but it is
permitted.

This ability for type parameters to refer to other type parameters
illustrates an important point: it should be a requirement for any
attempt to add generics to Go that it be possible to instantiate
generic code with multiple type arguments that refer to each other in
ways that the compiler can check.

As it is a common observation that contracts share some
characteristics of interface types, it's worth stressing that this
capability is one that contracts provide but interface types do not.

### Passing parameters to a contract

As mentioned earlier, by default the type parameters are passed to the
contract in the order in which they appear in the function signature.
It is also possible to explicitly pass type parameters to a contract
as though they were arguments.
This is useful if the contract and the generic function take type
parameters in a different order, or if only some parameters need a
contract.

In this example the type parameter `E` can be any type, but the type
parameter `M` must implement the `String` method.
The function passes just `M` to the `stringer` contract, leaving `E`
as though it had no constraints.

```Go
func MapAndPrint(type E, M stringer(M))(s []E, f(E) M) []string {
	r := make([]string, len(s))
	for i, v := range s {
		r[i] = f(v).String()
	}
	return r
}
```

### Contract syntactic details

Contracts may only appear at the top level of a package.

While contracts could be defined to work within the body of a
function, it's hard to think of realistic examples in which they would
be useful.
We see this as similar to the way that methods can not be defined
within the body of a function.
A minor point is that only permitting contracts at the top level
permits the design to be Go 1 compatible.

There are a few ways to handle the syntax:

* We could make `contract` be a keyword only at the start of a
  top-level declaration, and otherwise be a normal identifier.
* We could declare that if you use `contract` at the start of a
  top-level declaration, then it becomes a keyword for the entire
  package.
* We could make `contract` always be a keyword, albeit one that can
  only appear in one place, in which case this design is not Go 1
  compatible.

Like other top level declarations, a contract is exported if its name
starts with an uppercase letter.
If exported it may be used by functions, types, or contracts in other
packages.

### Values of type parameters are not boxed

In the current implementations of Go, interface values always hold
pointers.
Putting a non-pointer value in an interface variable causes the value
to be _boxed_.
That means that the actual value is stored somewhere else, on the heap
or stack, and the interface value holds a pointer to that location.

In this design, values of generic types are not boxed.
For example, let's consider a function that works for any type `T`
with a `Set(string)` method that initializes the value based on a
string, and uses it to convert a slice of `string` to a slice of `T`.

```Go
package from

contract setter(T) {
	T Set(string) error
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

Now let's see some code in a different package.

```Go
type Settable int

func (p *Settable) Set(s string) (err error) {
	*p, err = strconv.Atoi(s)
	return err
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
The values in that slice will be `Settable` values, which is to say,
they will be integers.
They will not be boxed as pointers, even though they were created and
set by a generic function.

Similarly, when a parameterized type is instantiated it will have the
expected types as components.

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

This can only be done when all the function's type parameters are used
for the types of the function's (non-type) input parameters.
If there are some type parameters that are used only for the
function's result parameter types, or only in the body of the
function, then it is not possible to infer the type arguments for the
function, since there is no value from which to infer the types.
For example, when calling `from.Strings` as defined earlier, the type
parameters cannot be inferred because the function's type parameter
`T` is not used for an input parameter, only for a result.

When the function's type arguments can be inferred, the language uses
type unification.
On the caller side we have the list of types of the actual (non-type)
arguments, which for the `Print` example here is simply `[]int`.
On the function side is the list of the types of the function's
non-type parameters, which here is `[]T`.
In the lists, we discard respective arguments for which the function
side does not use a type parameter.
We must then unify the remaining argument types.

Type unification is a two pass algorithm.
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
Unification succeeds, so the call written as `transform.Slice` is a
call of `transform.Slice(int, string)`.

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
That said, this feature doesn't require additional syntax, and is
likely to significantly reduce the stutter of repeated type arguments
in code.)

(Note: We could also consider supporting type inference for
composite literals of parameterized types.

```Go
type Pair(type T) struct { f1, f2 T }
var V = Pair{1, 2} // inferred as Pair(int){1, 2}
```

It's not clear how often this will arise in real code.)

### Instantiating a function

Go normally permits you to refer to a function without passing any
arguments, producing a value of function type.
You may not do this with a function that has type parameters; all type
arguments must be known at compile time.
However, you can instantiate the function, by passing type arguments,
without passing any non-type arguments.
This will produce an ordinary function value with no type parameters.

```Go
// PrintInts will be type func([]int).
var PrintInts = Print(int)
```

### Type assertions and switches

A useful function with type parameters will support any type argument
that implements the contract.
Sometimes, though, it's possible to use a more efficient
function implementation for some type arguments.
The language already has mechanisms for code to find out what type it
is working with: type assertions and type switches.
Those are normally only permitted with interface types.
In this design, functions are also permitted to use them with values
whose types are type parameters, or are based on type parameters.

This doesn't add any functionality, as the function could get the same
information using the reflect package.
It's merely occasionally convenient, and it may result in more
efficient code.

For example, this code is permitted even if it is called with a type
argument that is not an interface type.

```Go
contract reader(T) {
	T Read([]byte) (int, error)
}

func ReadByte(type T reader)(r T) (byte, error) {
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
This is only an issue when the type is instantiated in place.

### Using parameterized types as unnamed function parameter types

When parsing a parameterized type as an unnamed function parameter
type, there is a parsing ambiguity.

```Go
var f func(x(T))
```

In this example we don't know whether the function has a single
unnamed parameter of the parameterized type `x(T)`, or whether this is
a named parameter `x` of the type `(T)` (written with parentheses).

For backward compatibility, we treat this as the latter case: `x(T)`
is a parameter `x` of type `(T)`.
In order to describe a function with a single unnamed parameter of
type `x(T)`, either the parameter must be named, or extra parentheses
must be used.

```Go
var f1 func(_ x(T))
var f2 func((x(T)))
```

### Embedding a parameterized type in a struct

There is a parsing ambiguity when embedding a parameterized type
in a struct type.

```Go
type S1(type T) struct {
	f T
}

type S2 struct {
	S1(int)
}
```

In this example we don't know whether struct `S2` has a single
field named `S1` of type `(int)`, or whether we
are trying to embed the instantiated type `S1(int)` into `S2`.

For backward compatibility, we treat this as the former case: `S2` has
a field named `S1`.

In order to embed an instantiated type in a struct, we could require that
extra parentheses be used.

```Go
type S2 struct {
	(S1(int))
}
```

This is currently not supported by the language, so this would suggest
generally extending the language to permit types embedded in structs to
be parenthesized.

### Embedding a parameterized interface type in an interface

There is a parsing ambiguity when embedding a parameterized interface
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

In order to embed an instantiated interface, we could require that
extra parentheses be used.

```Go
type I2 interface {
	(I1(int))
}
```

This is currently not supported by the language, so this would suggest
generally extending the language to permit embedded interface types to
be parenthesized.

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

### Contracts details

Let's take a deeper look at contracts.

Operations on values whose type is a type parameter must be permitted
by the type parameter's contract.
This means that the power of generic functions is tied precisely to
the interpretation of the contract body.
It also means that the language requires a precise definition of the
operations that are permitted by a given contract.

#### Methods

All the contracts we've seen so far show only method calls in the
contract body.
If a method call appears in the contract body, that method may be
called on a value in any statement or expression in the function
body.
It will take argument and result types as specified in the contract
body.

#### Pointer methods

In some cases we need to require that a method be a pointer method.
This will happen when a function needs to declare variables whose
type is the type parameter, and also needs to call methods that are
defined for the pointer to the type parameter.

For example:

```Go
contract setter(T) {
	T Set(string)
}

func Init(type T setter)(s string) T {
	var r T
	r.Set(s)
	return r
}

type MyInt int

func (p *MyInt) Set(s string) {
	v, err := strconv.Atoi(s)
	if err != nil {
		log.Fatal("Init failed", err)
	}
	*p = MyInt(v)
}

// INVALID
// MyInt does not have a Set method, only *MyInt has one.
var Init1 = Init(MyInt)("1")

// DOES NOT WORK
// r in Init is type *MyInt with value nil,
// so the Set method does a nil pointer deference.
var Init2 = Init(*MyInt)("2")
```

The function `Init` cannot be instantiated with the type `MyInt`, as
that type does not have a method `Set`; only `*MyInt` has `Set`.

But instantiating `Init` with `*MyInt` doesn't work either, as then
the local variable `r` in `Init` is a value of type `*MyInt`
initialized to the zero value, which for a pointer is `nil`.
The `Init` function then invokes the `Set` method on a `nil` pointer,
causing a `nil` pointer dereference at the line `*p = MyInt(v)`.

In order to permit this kind of code, contracts permit specifying that
for a type parameter `T` the pointer type `*T` has a method.

```Go
contract setter(T) {
	*T Set(string)
}
```

With this definition of `setter`, instantiating `Init` with `MyInt` is
valid and the code works.
The local variable `r` has type `MyInt`, and the address of `r` is
passed as the receiver of the `Set` pointer method.
Instantiating `Init` with `*MyInt` is now invalid, as the type
`**MyInt` does not have a method `Set`.

Listing a `*T` method in a contract means that the method must be on
the type `*T`, and it means that the parameterized function is only
permitted to call the method on an addressable value of type `T`.

#### Pointer or value methods

If a method is listed in a contract with a plain `T` rather than `*T`,
then it may be either a pointer method or a value method of `T`.
In order to avoid worrying about this distinction, in a generic
function body all method calls will be pointer method calls.
If necessary, the function body will insert temporary variables,
not seen by the user, in order to get an addressable variable to use
to call the method.

For example, this code is valid, even though `LookupAsString` calls
`String` in a context that requires a value method, and `MyInt` only
has a pointer method.

```Go
func LookupAsString(type T stringer)(m map[int]T, k int) string {
	return m[k].String() // Note: calls method on value of type T
}

type MyInt int
func (p *MyInt) String() { return strconv.Itoa(int(*p)) }
func F(m map[int]MyInt) string {
	return LookupAsString(MyInt)(m, 0)
}
```

This makes it easier to understand which types satisfy a contract, and
how a contract may be used.
It has the drawback that in some cases a pointer method that modifies
the value to which the receiver points may be called on a temporary
variable that is discarded after the method completes.
It may be possible to add a vet warning for a case where a generic
function uses a temporary variable for a method call and the function
is instantiated with a type that has only a pointer method, not a
value method.

(Note: we should revisit this decision if it leads to confusion or
incorrect code.)

#### Operators

Method calls are not sufficient for everything we want to express.
Consider this simple function that returns the smallest element of a
slice of values, where the slice is assumed to be non-empty.

```Go
// This function is INVALID.
func Smallest(type T)(s []T) T {
	r := s[0] // panics if slice is empty
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
This assumes that `T` supports the `<` operator, but there is no
contract requiring that.
Without a contract the function body can only use operations that are
available for all types, but not all Go types support `<`.

It follows that we need a way to write a contract that accepts only
types that support `<`.
In order to do that, we observe that, aside from two exceptions that
we will discuss later, all the arithmetic, comparison, and logical
operators defined by the language may only be used with types that are
predeclared by the language, or with defined types whose underlying
type is one of those predeclared types.
That is, the operator `<` can only be used with a predeclared type
such as `int` or `float64`, or a defined type whose underlying type is
one of those types.
Go does not permit using `<` with an aggregate type or with an
arbitrary defined type.

This means that rather than try to write a contract for `<`, we can
approach this the other way around: instead of saying which operators
a contract should support, we can say which (underlying) types a
contract should accept.

#### Types in contracts

A contract may list explicit types that may be used as type
arguments.
These are expressed in the form `type-parameter-name type, type...`.
The `type` must be a predeclared type, such as `int`, or an aggregate
as discussed below.
For example,

```Go
contract SignedInteger(T) {
	T int, int8, int16, int32, int64
}
```

This contract specifies that the type argument must be one of the
listed types (`int`, `int8`, and so forth), or it must be a defined
type whose underlying type is one of the listed types.

When a parameterized function using this contract has a value of type
`T`, it may use any operation that is permitted by all of the listed
types.
This can be an operation like `<`, or for aggregate types an operation
like `range` or `<-`.
If the function can be compiled successfully using each type listed in
the contract, then the operation is permitted.

For the `Smallest` example shown earlier, we could use a contract like
this:

```Go
contract Ordered(T) {
	T int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64,
		string
}
```

(In practice this contract would likely be defined and exported in a
new standard library package, `contracts`, so that it could be used by
function and type and contract definitions.)

Given that contract, we can write this function, now valid:

```Go
func Smallest(type T Ordered)(s []T) T {
	r := s[0] // panics if slice is empty
	for _, v := range s[1:] {
		if v < r {
			r = v
		}
	}
	return r
}
```

#### Conjunction and disjunction in contracts

The use of comma to separate types is a general mechanism.
A contract can be considered as a set of constraints, where the
constraints are either methods or types.
Separating constraints by a semicolon or newline means that the
constraints are a conjunction: each constraint must be satisfied.
Separating constraints by a comma means that the constraints are a
disjunction: at least one of the constraints must be satisified.

With a conjunction of constraints in a contract, a generic function
may use any operation permitted by at least one of the constraints.
With a disjunction, a generic function may use any operation permitted
by all of the constraints.

Syntactically, the type parameter being constrained must be listed for
each individual conjunction constraint, but only once for the
disjunction constraints.

Normally methods will be listed as a conjunction, separated by a
semicolon or newline.

```Go
// PrintStringer1 and PrintStringer2 are equivalent.
contract PrintStringer1(T) {
	T String() string
	T Print()
}

contract PrintStringer2(T) {
	T String() string; T Print()
}
```

Normally builtin types will be listed as a disjunction, separated by
commas.

```Go
contract Float(T) {
	T float32, float64
}
```

However, this is not required.
For example:

```Go
contract IOCloser(S) {
	S Read([]byte) (int, error), // note trailing comma
		Write([]byte) (int, error)
	S Close() error
}
```

This contract accepts any type that has a `Close` method and also has
either a `Read` or a `Write` method (or both).
To put it another way, it accepts any type that implements either
`io.ReadCloser` or `io.WriteCloser` (or both).
In a generic function using this contract permits calling the
`Close` method, but calling the `Read` or `Write` method requires a
type assertion to an interface type.
It's not clear whether this is useful, but it is valid.

Another, pedantic, example:

```Go
contract unsatisfiable(T) {
	T int
	T uint
}
```

This contract permits any type that is both `int` and `uint`.
Since there is no such type, the contract does not permit any type.
This is valid but useless.

#### Both types and methods in contracts

A contract may list both builtin types and methods, typically using
conjunctions and disjunctions as follows:

```Go
contract StringableSignedInteger(T) {
	T int, int8, int16, int32, int64
	T String() string
}
```

This contract permits any type defined as one of the listed types,
provided it also has a `String() string` method.
Although the `StringableSignedInteger` contract explicitly lists
`int`, the type `int` is not permitted as a type argument, since `int`
does not have a `String` method.
An example of a type argument that would be permitted is `MyInt`,
defined as:

```Go
type MyInt int
func (mi MyInt) String() string {
	return fmt.Sprintf("MyInt(%d)", mi)
}
```

#### Aggregate types in contracts

A type in a contract need not be a predeclared type; it can be a type
literal composed of predeclared types.

```Go
contract byteseq(T) {
	T string, []byte
}
```

The same rules apply.
The type argument for this contract may be `string` or `[]byte` or a
type whose underlying type is one of those.
A parameterized function with this contract may use any operation
permitted by both `string` and `[]byte`.

Given these definitions

```Go
type MyByte byte
type MyByteAlias = byte
```

the `byteseq` contract is satisfied by any of `string`, `[]byte`,
`[]MyByte`, `[]MyByteAlias`.

The `byteseq` contract permits writing generic functions that work
for either `string` or `[]byte` types.

```Go
func Join(type T byteseq)(a []T, sep T) (ret T) {
	if len(a) == 0 {
		// Use the result parameter as a zero value;
		// see discussion of zero value below.
		return ret
	}
	if len(a) == 1 {
		return T(append([]byte(nil), a[0]...))
	}
	n := len(sep) * (len(a) - 1)
	for i := 0; i < len(a); i++ {
		n += len(a[i]) // len works for both string and []byte
	}

	b := make([]byte, n)
	bp := copy(b, a[0])
	for _, s := range a[1:] {
		bp += copy(b[bp:], sep)
		bp += copy(b[bp:], s)
	}
	return T(b)
}
```

#### Aggregates of type parameters in contracts

A type literal in a contract can refer not only to predeclared types,
but also to type parameters.
In this example, the `Slice` contract takes two parameters.
The first type parameter is required to be a slice of the second.
There are no constraints on the second type parameter.

```Go
contract Slice(S, Element) {
	S []Element
}
```

We can use the `Slice` contract to define a function that takes an
argument of a slice type and returns a result of that same type.

```Go
func Map(type S, Element Slice)(s S, f func(Element) Element) S {
	r := make(S, len(s))
	for i, v := range s {
		r[i] = f(v)
	}
	return r
}

type MySlice []int

func DoubleMySlice(s MySlice) MySlice {
	v := Map(MySlice, int)(s, func(e int) int { return 2 * e })
	// Here v has type MySlice, not type []int.
	return v
}
```

(Note: the type inference rules described above do not permit
inferring both `MySlice` and `int` when `DoubleMySlice` calls `Map`.
It may be worth extending them, to make it easier to use functions
that are careful to return the same result type as input type.
Similarly, we would consider extending the type inference rules to
permit inferring the type `Edge` from the type `Node` in the
`graph.New` example shown earlier.)

To avoid a parsing ambiguity, when a type literal in a contract refers
to a parameterized type, extra parentheses are required, so that it is
not confused with a method.

```Go
type M(type T) []T

contract C(T) {
	T M(T)   // T must implement the method M with an argument of type T
	T (M(T)) // T must be the type M(T)
}
```

#### Comparable types in contracts

Earlier we mentioned that there are two exceptions to the rule that
operators may only be used with types that are predeclared by the
language.
The exceptions are `==` and `!=`, which are permitted for struct,
array, and interface types.
These are useful enough that we want to be able to write a contract
that accepts any comparable type.

To do this we introduce a new predeclared contract: `comparable`.
The `comparable` contract takes a single type parameter.
It accepts as a type argument any comparable type.
It permits in a parameterized function the use of `==` and `!=` with
values of that type parameter.

As a predeclared contract, `comparable` may be used in a function or
type definition, or it may be embedded in another contract.

For example, this function may be instantiated with any comparable
type:

```Go
func Index(type T comparable)(s []T, x T) int {
	for i, v := range s {
		if v == x {
			return i
		}
	}
	return -1
}
```

#### Observations on types in contracts

It may seem awkward to explicitly list types in a contract, but it is
clear both as to which type arguments are permitted at the call site,
and which operations are permitted by the parameterized function.

If the language later changes to support operator methods (there are
no such plans at present), then contracts will handle them as they do
any other kind of method.

There will always be a limited number of predeclared types, and a
limited number of operators that those types support.
Future language changes will not fundamentally change those facts, so
this approach will continue to be useful.

This approach does not attempt to handle every possible operator.
For example, there is no way to usefully express the struct field
reference `.` or the general index operator `[]`.
The expectation is that those will be handled using aggregate types in
a parameterized function definition, rather than requiring aggregate
types as a type argument.
For example, we expect functions that want to index into a slice to be
parameterized on the slice element type `T`, and to use parameters or
variables of type `[]T`.

As shown in the `DoubleMySlice` example above, this approach makes it
awkward to write generic functions that accept and return an aggregate
type and want to return the same result type as their argument type.
Defined aggregate types are not common, but they do arise.
This awkwardness is a weakness of this approach.

#### Type conversions

In a function with two type parameters `From` and `To`, a value of
type `From` may be converted to a value of type `To` if all the
types accepted by `From`'s contract can be converted to all the
types accepted by `To`'s contract.
If either type parameter does not accept types, then type conversions
are not permitted.

For example:

```Go
contract integer(T) {
	T int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr
}

contract integer2(T1, T2) {
	integer(T1)
	integer(T2)
}

func Convert(type To, From integer2)(from From) To {
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
contract.

```Go
contract integer(T) {
	T int, int8, int16, int32, int64,
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
  using optional contracts.
* Contracts describe the methods required and the builtin types
  permitted for a type argument.
* Contracts describe the methods and operations permitted for a type
  parameter.
* Type inference will often permit omitting type arguments when
  calling functions with type parameters.

This design is completely backward compatible, in that any valid Go 1
program will still be valid if this design is adopted (assuming
`contract` is treated as a pseudo-keyword that is only meaningful at
top level).

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

A new `contracts` packages will provide standard embeddable contracts,
such as contracts that permit all integer types or all numeric types.

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
  that are designed to work with specific type arguments (other than
  using type assertions or type switches).
* No metaprogramming.
  There is no way to write code that is executed at compile time to
  generate code to be executed at run time.
* No higher level abstraction.
  There is no way to speak about a function with type arguments other
  than to call it or instantiate it.
  There is no way to speak about a parameterized type other than to
  instantiate it.
* No general type description.
  For operator support contracts use specific types, rather than
  describing the characteristics that a type must have.
  This is easy to understand but may be limiting at times.
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
  `Equal` method, or vice-versa.
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
And, of course, there is no contract to support either `return nil` or
`return 0`.

Some approaches to this are:

* Use `var zero T`, as above, which works with the existing design
  but requires an extra statement.
* Use `*new(T)`, which is ugly but works with the existing design.
* For results only, name the result parameter `_`, and use a naked
  `return` statement to return the zero value.
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
The current design seems to be the nicest, but perhaps something
better is possible.

##### Pointer vs. value methods in contracts

Contracts do not provide a way to distinguish between pointer and
value methods, so types that provide either will satisfy a contract.
This in turn requires that parameterized functions always permit
either kind of method.
This may be confusing, in that a parameterized function may invoke a
pointer method on a temporary value; if the pointer method changes the
value to which the receiver points, those changes will be lost.
We will have to judge from experience how much this confuses people in
practice.

##### Defined aggregate types

As discussed above, an extra type parameter is required for a function
to take, as an argument, a defined type whose underlying type is an
aggregate type, and to return the same defined type as a result.

For example, this function will map a function across a slice.

```Go
func Map(type Element)(s []Element, f func(Element) Element) []Element {
	r := make([]Element, len(s))
	for i, v := range s {
		r[i] = f(v)
	}
	return r
}
```

However, when called on a defined type, it will return a slice of the
element type of that type, rather than the defined type itself.

```Go
type MySlice []int

func DoubleMySlice(s MySlice) MySlice {
	s2 := Map(s, func(e int) int { return 2 * e })
	// Here s2 is type []int, not type MySlice.
	return MySlice(s2)
}
```

As discussed above with an example, this can be avoided by using an
extra type parameter for `Map`, and using a contract that describes
the required relationship between the slice and element types.
This works but is awkward.

##### Identifying the matched predeclared type

In this design we suggest permitting type assertions and type switches
on values whose types are based on type parameters, but those type
assertions and switches would always test the actual type argument.
The design doesn't provide any way to test the contract type matched
by the type argument.

Here is an example that shows the difference.

```Go
contract Float(F) {
	F float32, float64
}

func NewtonSqrt(type F Float)(v F) F {
	var iterations int
	switch v.(type) {
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
the type that `v` matched in the contract.

One way to handle this would be to permit type switches on the type
`F`, rather than the value `v`, with the proviso that the type `F`
would always match a type defined in the contract.
This kind of type switch would only be permitted if the contract does
list explicit types, and only types listed in the contract would be
permitted as cases.

If we took this approach, we would stop permitting type assertions and
switches on values whose type is based on a type parameter.
Those assertions and switches can always be done by first converting
the value to the empty interface type.

A different approach would be that if a contract specifies any types
for a type parameter, then let type switches and assertions on values
whose type is, or is based on, that type parameter to match only the
types listed in the type parameter's contract.
It is still possible to match the value's actual type by first
converting it to the `interface{}` type and then doing the type
assertion or switch.

#### Discarded ideas

This design is not perfect, and it will be changed as we gain
experience with it.
That said, there are many ideas that we've already considered in
detail.
This section lists some of those ideas in the hopes that it will help
to reduce repetitive discussion.
The ideas are presented in the form of a FAQ.

##### Why not use interfaces instead of contracts?

_The interface method syntax is familiar._
_Why introduce another way to write methods?_

Contracts, unlike interfaces, support multiple types, including
describing ways that the types refer to each other.

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

More seriously, a contract is a relationship between the definition of
a generic function and the callers of that function.
To put it another way, it is a relationship between a set of type
parameters and a set of type arguments.
The contract defines how values of the type parameters may be used,
and defines the requirements on the type arguments.
That is why it is called a contract: because it defines the behavior
on both sides.

An interface is a type, not a relationship between function
definitions and callers.
A program can have a value of an interface type, but it makes no sense
to speak of a value of a contract type.
A value of interface type has both a static type (the interface type)
and a dynamic type (some non-interface type), but there is no similar
concept for contracts.

In other words, contracts are not extensions of interface types.
There are things you can do with a contract that you cannot do with an
interface type, and there are things you can do with an interace type
that you cannot do with a contract.

It is true that a contract that has a single type parameter and that
lists only methods, not builtin types, for that type parameter, looks
similar to an interface type.
But all the similarity amounts to is that both provide a list of
methods.
We could consider permitting using an interface type as a contract
with a single type parameter that lists only methods.
But that should not mislead us into thinking that contracts are
interfaces.

##### Why not permit contracts to describe a type?

_In order to use operators contracts have to explicitly and tediously_
_list types._
_Why not permit them to describe a type?_

There are many different ways that a Go type can be used.
While it is possible to invent notation to describe the various
operations in a contract, it leads to a proliferation of additional
syntactic constructs, making contracts complicated and hard to read.
The approach used in this design is simpler and relies on only a few
new syntactic constructs and names.

##### Why not put type parameters on packages?

We investigated this extensively.
It becomes problematic when you want to write a `list` package, and
you want that package to include a `Transform` function that converts
a `List` of one element type to a `List` of another element type.
It's very awkward for a function in one instantiation of a package to
return a type that requires a different instantiation of the package.

It also confuses package boundaries with type definitions.
There is no particular reason to think that the uses of parameterized
types will break down neatly into packages.
Sometimes they will, sometimes they won't.

##### Why not use the syntax `F<T>` like C++ and Java?

When parsing code within a function, such as `v := F<T>`, at the point
of seeing the `<` it's ambiguous whether we are seeing a type
instantiation or an expression using the `<` operator.
Resolving that requires effectively unbounded lookahead.
In general we strive to keep the Go parser simple.

##### Why not use the syntax `F[T]`?

When parsing a type declaration `type A [T] int` it's ambiguous
whether this is a parameterized type defined (uselessly) as `int` or
whether it is an array type with `T` elements.
However, this would be addressed by requiring `type A [type T] int`
for a parameterized type.

Parsing declarations like `func f(A[T]int)` (a single parameter of
type `[T]int`) and `func f(A[T], int)` (two parameters, one of type
`A[T]` and one of type `int`) show that some additional parsing
lookahead is required.
This is solvable but adds parsing complexity.

The language generally permits a trailing comma in a comma-separated
list, so `A[T,]` should be permitted if `A` is a parameterized type,
but normally would not be permitted for an index expression.
However, the parser can't know whether `A` is a parameterized type or
a value of slice, array, or map type, so this parse error can not be
reported until after type checking is complete.
Again, solvable but complicated.

More generally, we felt that the square brackets were too intrusive on
the page and that parentheses were more Go like.
We will reevaluate this decision as we gain more experience.

##### Why not use `F«T»`?

We considered it but we couldn't bring ourselves to require
non-ASCII.

##### Why not define contracts in a standard package?

_Instead of writing out contracts, use names like_
_`contracts.Arithmetic` and `contracts.Comparable`._

Listing all the possible combinations of types gets rather lengthy.
It also introduces a new set of names that not only the writer of
generic code, but, more importantly, the reader, must remember.
One of the driving goals of this design is to introduce as few new
names as possible.
In this design we introduce one new keyword and one new predefined
name.

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
This saves considerable complexity while losing some power and run
time efficiency.

### Examples

The following sections are examples of how this design could be used.
This is intended to address specific areas where people have created
user experience reports concerned with Go's lack of generics.

#### Sort

Before the introduction of `sort.Slice`, a common complaint was the
need for boilerplate definitions in order to use `sort.Sort`.
With this design, we can add to the sort package as follows:

```Go
type orderedSlice(type Elem Ordered) []Elem

func (s orderedSlice(Elem)) Len() int           { return len(s) }
func (s orderedSlice(Elem)) Less(i, j int) bool { return s[i] < s[j] }
func (s orderedSlice(Elem)) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }

// OrderedSlice sorts the slice s in ascending order.
// The elements of s must be ordered using the < operator.
func OrderedSlice(type Elem Ordered)(s []Elem) {
	sort.Sort(orderedSlice(Elem)(s))
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
type sliceFn(type Elem) struct {
	s []Elem
	f func(Elem, Elem) bool
}

func (s sliceFn(Elem)) Len() int           { return len(s.s) }
func (s sliceFn(Elem)) Less(i, j int) bool { return s.f(s.s[i], s.s[j]) }
func (s sliceFn(Elem)) Swap(i, j int)      { s.s[i], s.s[j] = s.s[j], s.s[i] }

// SliceFn sorts the slice s according to the function f.
func SliceFn(type Elem)(s []Elem, f func(Elem, Elem) bool) {
	Sort(sliceFn(Elem){s, f})
}
```

An example of calling this might be:

```Go
	var s []*Person
	// ...
	sort.SliceFn(s, func(p1, p2 *Person) bool { return p1.Name < p2.Name })
```

#### Map keys

Here is how to get a slice of the keys of any map.

```Go
package maps

// Keys returns the keys of the map m.
// Note that map keys (here called type K) must be comparable.
func Keys(type K, V comparable(K))(m map[K]V) []K {
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

#### Map/Reduce/Filter

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

#### Sets

Many people have asked for Go's builtin map type to be extended, or
rather reduced, to support a set type.
Here is a type-safe implementation of a set type, albeit one that uses
methods rather than operators like `[]`.

```Go
// Package set implements sets of any type.
package set

type Set(type Elem comparable) map[Elem]struct{}

func Make(type Elem comparable)() Set(Elem) {
	return make(Set(Elem))
}

func (s Set(Elem)) Add(v Elem) {
	s[v] = struct{}{}
}

func (s Set(Elem)) Delete(v Elem) {
	delete(s, v)
}

func (s Set(Elem)) Contains(v Elem) bool {
	_, ok := s[v]
	return ok
}

func (s Set(Elem)) Len() int {
	return len(s)
}

func (s Set(Elem)) Iterate(f func(Elem)) {
	for v := range s {
		f(v)
	}
}
```

Example use:

```Go
	s := set.Make(int)()
	s.Add(1)
	if s.Contains(2) { panic("unexpected 2") }
```

This example, like the sort examples above, show how to use this
design to provide a compile-time type-safe wrapper around an
existing API.

#### Channels

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
	runtime.SetFinalizer(r, r.finalize)
	return s, r
}

// A sender is used to send values to a Receiver.
type Sender(type T) struct {
	values chan<- T
	done <-chan bool
}

// Send sends a value to the receiver. It returns whether any more
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

#### Containers

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

#### Append

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
	slices.Copy(s[3:], []int{7, 8, 9})
```

This code doesn't implement the special case of appending or copying a
`string` to a `[]byte`, and it's unlikely to be as efficient as the
implementation of the predeclared function.
Still, this example shows that using this design would permit append
and copy to be written generically, once, without requiring any
additional special language features.

#### Metrics

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

type Metric1(type T comparable) struct {
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

This package implementation has a certain amount of repetition due to
the lack of support for variadic package type parameters.
Using the package, though, is easy and type safe.

#### List transform

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
// It returns whether there are more elements.
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
		it.Next()
	}
	return ret
}
```

#### Context

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

To see how this might be used, consider the net/http package's
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

#### Dot product

A generic dot product implementation that works for slices of any
numeric type.

```Go
// Numeric is a contract that matches any numeric type.
// It would likely be in a contracts package in the standard library.
contract Numeric(T) {
	T int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64,
		complex64, complex128
}

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

#### Absolute difference

Compute the absolute difference between two numeric values, by using
an `Abs` method.
This uses the same `Numeric` contract defined in the last example.

This example uses more machinery than is appropriate for the simple
case of computing the absolute difference.
It is intended to show how the common part of algorithms can be
factored into code that uses methods, where the exact definition of
the methods can very based on the kind of type being used.

```Go
// NumericAbs matches numeric types with an Abs method.
contract NumericAbs(T) {
	Numeric(T)
	T Abs() T
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
contract OrderedNumeric(T) {
	T int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, uintptr,
		float32, float64
}

// Complex matches the two complex types, which do not have a < operator.
contract Complex(T) {
	T complex64, complex128
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

func (a ComplexAbs(T)) Abs() T {
	r := float64(real(a))
	i := float64(imag(a))
	d := math.Sqrt(r * r + i * i)
	return T(complex(d, 0))
}
```

We can then define functions that do the work for the caller by
converting to and from the types we just defined.

```Go
func OrderedAbsDifference(type T OrderedNumeric)(a, b T) T {
	return T(AbsDifference(OrderedAbs(T)(a), OrderedAbs(T)(b)))
}

func ComplexAbsDifference(type T Complex)(a, b T) T {
	return T(AbsDifference(ComplexAbs(T)(a), ComplexAbs(T)(b)))
}
```

It's worth noting that this design is not powerful enough to write
code like the following:

```Go
// This function is INVALID.
func GeneralAbsDifference(type T Numeric)(a, b T) T {
	switch a.(type) {
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
invalid, because not all the types that satisfy the `Numeric` contract
can satisfy the `OrderedNumeric` or `Complex` contracts.
Although the type switch means that this code would conceptually work
at run time, there is no support for writing this code at compile
time.
This another of way of expressing one of the omissions listed above:
this design does not provide for specialization.
