# Compile-time Functions and First Class Types

This is a proposal for adding compile-time functions and first-class types to
Go, written by Bryan C. Mills in September, 2016.
This proposal will most likely not be adopted.
It is being presented as an example for what a complete generics proposal must
cover.

## Background

This is an alternative to an
[earlier proposal](https://github.com/golang/proposal/blob/master/design/15292/2013-12-type-params.md)
and subsequent drafts by Ian Lance Taylor.

Ian's earlier proposal notes:

>  [T]he right way to implement such features [as template metaprogramming] in
>  Go would be to add support in the go tool for writing Go code to generate Go
>  code […] which is in turn compiled into the final program. This would mean
>  that the metaprogramming language in Go is itself Go.

This proposal is an attempt to drive that observation to its natural conclusion,
by adding explicit support for running Go functions over types at compile-time.
It results in a variant of Go with deep support for parametric types and
functions, despite relatively little addition to the language.

This proposal is intended to be Go 1 compatible.
If any incompatibilities exist, they are likely to be due to the extension of
`TypeName` to include compile-time expressions and/or due to grammar conflicts
with the expanded definition of `Declaration`.

## Proposal

We introduce a new builtin type, `gotype`, which represents a type within Go
program during compilation, and a new token which creates a constant of type
`gotype` from a [`Type`](https://golang.org/ref/spec#Type).

We permit a subset of Go functions to be called at compile-time.
These functions can accept and return values of type `gotype`.
The `gotype` values returned from such functions can appear as types within the
program.

### Syntax

`const`, applied at the start of a
[`FunctionDecl`](https://golang.org/ref/spec#FunctionDecl), indicates a
declaration of a compile-time function.

ℹ There are many reasonable alternatives to the `const` token.
  We could use a currently-invalid token (such as `::` or `<>`), a new builtin
  name (such as `static`), or, in fact, nothing at all!
  In the latter case, any `FunctionDecl` that meets the constraints of a
  compile-time function would result in a function which could be called at
  compile time.

The new builtin type `gotype` represents a Go type at compile-time.

`(type)`, used in place of a
[`FunctionBody`](https://golang.org/ref/spec#FunctionBody),
[`LiteralValue`](https://golang.org/ref/spec#LiteralValue), or the `Expression`
in a [`Conversion`](https://golang.org/ref/spec#Conversion), represents "the
type itself".
It produces a constant of type `gotype`.

The actual syntax for the `(type)` token could be a currently-invalid
token (such as `<>` or `{...}`), an existing keyword that cannot currently occur
in this position (such as an unparenthesized `type`), or a new builtin
non-keyword (such as `itself`, `typeof`, or `gotype`).

The `.(type)` syntax already supported in type switches can be used as a general
expression within compile-time functions.
It returns the `gotype` of the `interface` value to which it is applied.

In order to support defining methods on types within compile-time functions, we
expand the definition of a
[`Declaration`](https://golang.org/ref/spec#Declaration) to include
[`FunctionDecl`](https://golang.org/ref/spec#FunctionDecl) and
[`MethodDecl`](https://golang.org/ref/spec#MethodDecl), with the restriction
that method declarations must occur within the same scope as the corresponding
type declaration and before any values of that type are instantiated.
For uniformity, we also allow these declarations within ordinary
(non-compile-time) functions.

ℹ As a possible future extension, we could allow conditional method declarations
  within a compile-time function before the first use of the type.

Expressions of type `gotype` can appear anywhere a
[`TypeName`](https://golang.org/ref/spec#TypeName) is valid, including in the
parameters or return-values of a compile-time function.
The compiler substitutes the concrete type returned by the function in place of
the `gotype` expression.
`gotype` parameters to a compile-time function may be used in the types of
subsequent parameters.

ℹ In this proposal, functions whose parameter types depend on other parameters
  do not have a well-formed Go type, and hence cannot be passed or stored as
  variables with `func` types.
  It may be possible to add such
  [dependent types](https://en.wikipedia.org/wiki/Dependent_type) in the
  future, but for now it seems prudent to avoid that complexity.

### Semantics

Compile-time functions and expressions cannot depend upon values that are not
available at compile-time.
In particular, they cannot call non-compile-time functions or access variables
at package scope.

ℹ As a possible future extension, we could allow compile-time functions to read
  and manipulate package variables.
  This would enable more `init` functions to be evaluated at compile-time,
  reducing the run-time cost of package initialization (and allowing Go programs
  to load more quickly).
  However, it would potentially remove the useful invariant that all
  compile-time functions are "pure" functions.

The values returned from a call to a compile-time function are
[constants](https://golang.org/ref/spec#Constants) if expressions of the
corresponding types are otherwise valid as constants.

Arguments to compile-time functions can include:

* constants (including constants of type `gotype`)
* calls to other compile-time functions (even if they do not return constants)
* functions declared at package scope
* functions and variables declared locally within other compile-time functions
* [function literals](https://golang.org/ref/spec#Function_literals), provided
  that the body of the literal does not refer to the local variables of a
  run-time function or method

It is an error to write a compile-time expression that depends on a value not
available at compile-time.

Passed-in run-time functions cannot be called directly within the compile-time
function to which they are passed, but they can be called by other (run-time)
functions and/or methods declared within it.

⚠ Can / should we allow compile-time functions to accept and call other
  compile-time functions passed as parameters?

Run-time functions and methods declared within compile-time functions may refer
to local variables of the compile-time function.

Calls to compile-time functions from within run-time functions are evaluated at
compile-time.
(This is a form of
[partial evaluation](https://en.wikipedia.org/wiki/Partial_evaluation).)
Calls to compile-time functions from other compile-time functions are evaluated
when the outer function is called.

⚠ Should we allow compile-time functions that do not involve `gotype` to be
  called at run-time (with parameters computed at run-time)?

Expressions of type `gotype` can only be evaluated at compile-time.

ℹ There is an important distinction between "an expression of type `gotype`" and
  "an expression _whose type is_ an expression of type `gotype`" (a.k.a. "an
  expression whose type is _a_ `gotype`).
  The former is always a compile-time expression; the latter is not.

If an expression's type is a `gotype` but the concrete type represented by
evaluating the `gotype` does not support an operation used in the expression, it
is a compile-time error.
If the expression occurs within a compile-time function and the expression is
not evaluated, there is no error.
`gotype` expressions within type and method declarations are only evaluated if
the block containing the type declaration is evaluated.
(This is analogous to the
[SFINAE rule in C++](https://en.cppreference.com/w/cpp/language/sfinae).)

A [`TypeSwitchStmt`](https://golang.org/ref/spec#TypeSwitchStmt) on an
expression or variable of type `gotype` switches on the concrete type
represented by that `gotype`, not the type `gotype` itself.
As a consequence, a `TypeSwitchStmt` on a `gotype` cannot bind an `identifier`
in the `TypeSwitchGuard`.

⚠ It would be useful in some cases to be able to convert between a `gotype` and
  a `reflect.Type`, or to otherwise implement many of the `reflect.Type` methods
  on the `gotype` type.
  For example, in the `hashmap` example below, the `K` parameter could be
  eliminated by changing the `hashfn` and `eqfn` parameters to `interface{}` and
  reflecting over them to discover the key type.
  Is that worth considering at this point?

#### Type names

The name of a type declared within a function is local to the function.
If a local type is returned (as a `gotype`), it becomes
an [unnamed type](https://golang.org/ref/spec#Types).

ℹ Local types introduce the possibility of unnamed types with methods.

Two unnamed types returned as `gotype` are
[identical](https://golang.org/ref/spec#Type_identity) if they were returned by
calls to the same function with the same parameters.
If the function itself was local to another compile-time function, this applies
to the parameters passed to the outermost function that returns the `gotype`.

### Examples

```go
// AsWriterTo returns reader if it implements io.WriterTo,
// or a wrapper that embeds reader and implements io.WriterTo otherwise.
const func AsWriterTo(reader gotype) gotype {
	switch reader.(type) {
	case io.WriterTo:
		return reader
	default:
		type WriterTo struct {
			reader
		}
		func (t *WriterTo) WriteTo(w io.Writer) (n int64, err error) {
			return io.Copy(w, t.reader)
		}
		return WriterTo (type)
	}
}

const func MakeWriterTo(reader gotype) func(reader) AsWriterTo(reader) {
	switch reader.(type) {
	case io.WriterTo:
		return func(r reader) AsWriterTo(reader) {
			return r
		}
	default:
		return func(r reader) AsWriterTo(reader) {
			return AsWriterTo(reader) { r }
		}
	}
}
```

```go
func redundantButOk(b *bytes.Buffer) io.WriterTo {
	return MakeWriterTo(*bytes.Buffer)(b)  // ok: takes the io.WriterTo case
}

func maybeUseful(r *io.LimitedReader) io.WriterTo {
	return MakeWriterTo(*io.LimitedReader)(r)  // ok: takes the default case
}

const func fused(reader gotype) (writerTo gotype, make func(reader) writerTo) {
	writerTo = AsWriterTo(reader)            // ok: gotype var in a compile-time function
	return writerTo, MakeWriterTo(writerTo)  // ok: call of compile-time function with compile-time var
}

// bad always produces a compile-time error.
func bad(i int) io.WriterTo {
	return MakeWriterTo(int)(i)  // error: 'int' does not implement 'io.Reader'
}

// hiddenError produces a compile-time error only if it is called.
const func hiddenError(i int) io.WriterTo {
	return MakeWriterTo(int)(i)  // error: 'int' does not implement 'io.Reader'
}
```

```go
const func List(T gotype) gotype {
	type List struct {
		element T
		next *List
	}
	return List (type)
}

type ListInt List(int)
var v1 List(int)
var v2 List(float)
const func MyMap(T1, T2 gotype) gotype { return map[T1]T2 (type) }
const func MyChan(T3 gotype) gotype { return chan T3 (type) }
var v3 MyMap(int, string)
```

```go
package hashmap

const func bucket(K, V gotype) gotype {
	type bucket struct {
		next *bucket
		key K
		val V
	}
	return bucket (type)
}

const func Hashfn(K gotype) gotype { return func(K) uint (type) }
const func Eqfn(K gotype) gotype { return func(K, K) bool (type) }

const func Hashmap(K, V gotype, hashfn Hashfn(K), eqfn Eqfn(K)) gotype {
	type Hashmap struct {
		buckets []bucket(K, V)
		entries int
	}

	func(p *Hashmap) Lookup (key K) (val V, found bool) {
		h := hashfn(key) % len(p.buckets)
		for b := p.buckets[h]; b != nil; b = b.next {
			if eqfn(key, b.key) {
				return b.val, true
			}
		}
	}


	func (p *Hashmap) Insert(key K, val V) (inserted bool) {
		// Implementation omitted.
	}

	return Hashmap (type)
}

const func New(K, V gotype, hashfn Hashfn(K), eqfn Eqfn(K)) func()*Hashmap(K, V, hashfn, eqfn) {
	return func () *Hashmap(K, V, hashfn, eqfn) {
		return &Hashmap(K, V, hashfn, eqfn) {
			buckets: make([]bucket(K, V), 16),
			entries: 0,
		}
	}
}
```

```go
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

var v = hashmap.New(int(type), string(type), hashint, eqint)

func Add(id int, name string) {
	if !v.Insert(id, name) {
		log.Fatal("duplicate id", id)
	}
}

func Find(id int) string {
	val, found := v.Lookup(id)
	if !found {
		log.Fatal("missing id", id)
	}
	return val
}
```

### Ambiguities

The extension of `TypeName` to include calls returning a `gotype` introduces
some minor ambiguities in the grammar which must be resolved, particularly when
the argument to the `gotype` function is a named constant rather than a `gotype`
or another call.

The following example illustrates an ambiguity in interface declarations.
If `Z` is a type, it declares a method named `Y` with an argument of type `Z`.
If `Z` is a constant, it embeds the interface type `Y(Z)` in `X`.

```go
interface X {
  Y(Z)
}
```

The compiler can theoretically resolve the ambiguity itself based on the
definition of `Z`, but `go/parser` package currently does not do enough analysis
to determine the correct abstract syntax tree for this case.
To keep the parser relatively simple, we can resolve the ambiguity by requiring
parentheses for embedded types derived from expressions, which can never be
valid method declarations:

```go
interface X {
  (Y(Z))
}
```

ℹ In the above example, `Z` must be a constant or the name of a type, not a
  `gotype` literal: the `(type)` in `Z (type)` would already remove the
  ambiguity.

ℹ This problem and the proposed resolution are analogous to the existing
  ambiguity and workaround for composite literals within `if`, `switch`, and
  `for` statements.
  (Search for "parsing ambiguity" in the Go 1.7 spec.)

The following example illustrates an ambiguity in expressions.
If `Y` is a compile-time function that returns a `gotype`, the expression is a
[`Conversion`](https://golang.org/ref/spec#Conversion) of the expression `w` to
the type `Y(Z)`.
Otherwise, it is a [call](https://golang.org/ref/spec#Calls) to the function
`Y(Z)` with [`Arguments`](https://golang.org/ref/spec#Arguments) `w`.

```go
var x = Y(Z)(w)
```

Fortunately, the [`go/ast` representation](https://play.golang.org/p/C0W4uMy5ek)
for both of these forms is equivalent: a nested `CallExpr`.

ℹ As above, this case is only ambiguous if `Z` is a constant or the name of a
  type.

ℹ This ambiguity already appears in the existing grammar for the simpler case of
  `var x = Y(w)`: whether the subexpression `Y(w)` is parsed as a `Conversion`
  of `w` to `Y` or a `PrimaryExpr` applying a function `Y` to `w` already
  depends upon whether `Y` names a type or a function or variable.

The ambiguities described here are low-risk: the result of misparsing is an
invalid program, not a valid program with unintended behavior.

## Rationale

This proposal provides support for parametricity and metaprogramming using a
language that is already familiar to Go programmers: a subset of Go itself.

The proposed changes to the compiler are extensive (in order to support
compile-time evaluation), but the changes to the language itself and to the
runtime are relatively minimal: extensions of existing declaration syntax to
additional scopes, a token for indicating compile-time functions, a token for
hoisting types into values, and the new built-in type `gotype`.
The programmer needs to think about which parts of the program execute at
compile-time or at run-time, but does not need to learn a whole new language (as
opposed to, say, the extensive surface area of the `reflect` or `go/ast`
packages or the entirely different language of `text/template`).

The potential applications cover a significant fraction of "metaprogramming"
use-cases that are currently well-supported only in languages much more complex
than Go, and that are not addressed by previous proposals that run closer to
conventional "generics" or "templates".
The specific language changes may be somewhat more complex than some
alternatives (particularly when compared to tools that build on top of `go
generate`), but the deployment overhead is substantially lower: instead of
preprocessing source files (and potentially iterating over the outputs many
times to reach a fix-point of code generation), the programmer need only run the
usual `go build` command.
That is: this proposal trades a bit more language complexity for a significant
reduction in tooling complexity for Go users.

With a few additional modest extensions (e.g. compile-time `init` functions),
the same mechanism can be used to make Go program initialization more efficient
and to move detection of more errors from run-time to compile-time.

The principles underlying this proposal are based on existing (if little-used)
designs from programming language research: namely, higher-order types, partial
evaluation[1][][2][], and dependent function types.

[1]: https://www.cs.cmu.edu/~fp/papers/jacm00.pdf
[2]: https://www.cs.cmu.edu/~fp/papers/sope98.pdf

## Caveats

With this style of metaprogramming, it would be difficult (perhaps infeasible)
to add deduction for `gotype` arguments in a subsequent revision of the language
in a way that maintains backward-compatibility.

## Compatibility

This proposal is intended to be compatible with Go 1.
(The author has looked for incompatibilities and not yet found any.)

## Implementation

The implementation of `gotype` is straightforward, especially if we decline to
add conversions to and from `reflect.Type`.
The detection and evaluation of compile-time expressions adds a new algorithm to
the compiler, but it should be a straightforward one (a bottom-up analysis of
expressions) and is closely related to common compiler optimizations
(e.g. constant folding).

The export data format would have to be expanded to include definitions of
compile-time functions (as I assume it does today for inlinable functions).

The bulk of the implementation work is likely to be in support of executing Go
functions at compile time: compile-time functions have similar semantics to
run-time functions, but (because they are executed at compile time and because
they can have dependent types) would need support for a more dynamically-typed
evaluation.
