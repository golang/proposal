# Proposal: Algebraic enum types

Author: RestartFU

Last updated: July 2026

Discussion at https://go.dev/issue/19412.

Prototype at https://github.com/goonward/goplus.

Implementation at https://github.com/golang/go/pull/80467.

## Abstract

This proposal adds algebraic enum types to Go.
An enum declares a closed set of variants, and each variant may carry a
different set of fields.
Enum switches match variants, narrow values for field access, and are checked
for exhaustiveness.

The proposal is intended for states and results that are currently represented
by an interface plus several structs and marker methods.
It does not replace integer constants or change ordinary interface types.

## Background

Go can approximate a closed sum type with an interface and concrete structs.
For example:

```go
type Result[T any] interface {
	result()
}

type Ok[T any] struct {
	Value T
}

func (Ok[T]) result() {}

type Err[T any] struct {
	Err error
}

func (Err[T]) result() {}
```

This pattern has several limitations.

* The declaration is spread across unrelated declarations.
* Every variant requires a marker method.
* The compiler does not know the complete set of variants.
* A type switch cannot be checked for exhaustiveness.
* The variant type and its payload must repeat the enum type parameters.
* Adding a type in the declaring package can silently extend the set.
* Users must choose package-level names for all variant types.

These limitations encourage APIs that return a struct with a tag and several
conditionally valid fields, or an interface that requires documentation to
describe its permitted implementations.
Both encodings move invariants out of the type system.

## Proposal

### Declarations

An enum declaration creates a distinct enum type and a fixed set of variants.
Each variant contains zero or more fields.

```go
type Result[T any] enum {
	Ok { Value T }
	Err { Err error }
	None
}
```

The grammar is:

```text
EnumSpec    = identifier [ TypeParameters ] "enum" "{" { EnumVariant ";" } "}" .
EnumVariant = identifier [ "{" { FieldDecl ";" } "}" ] .
```

The identifier `enum` is contextual.
It introduces an enum only in this position and remains a valid identifier in
all existing contexts.
Enum declarations may appear wherever an ordinary type declaration may appear,
including inside functions, but may not appear in grouped type declarations.

Variant names belong to the enum rather than the surrounding package scope.
Different enums in the same package may therefore use the same variant names.
The normal capitalization rule determines whether a variant is exported.

### Values and construction

The values of an enum are `nil` and values constructed by its declared
variants.
The zero value of every enum is `nil`.

A variant with fields is constructed with a composite literal selected from
the enum type:

```go
ok := Result[int].Ok{Value: 42}
failed := Result[int].Err{Err: io.EOF}
none := Result[int].None{}
```

When an enum is the expected type, the enum qualification may be omitted:

```go
var result Result[int] = Ok{Value: 42}

func noResult() Result[int] {
	return None{}
}
```

A variant name is a constructor, not a source-level type name.
It cannot be used in a variable declaration, parameter, conversion, alias,
embedding, or ordinary type-switch case.
This keeps variants in the enum namespace and prevents code from depending on
their implementation types.

Taking the address of a variant literal is permitted, as it is for any
composite literal, but the resulting pointer is not an enum value:

```go
p := &Result[int].Ok{Value: 42} // permitted
var _ Result[int] = p           // compile-time error
```

Only a declared variant value is assignable to its enum.
Embedding a variant or otherwise reproducing its fields does not create another
implementation.
The set is closed even within the declaring package.

Different instantiations of a generic enum are distinct in the usual way.
A variant of `Result[string]` is not assignable to `Result[int]`.

### Enum switches

An expression switch whose expression has enum type is an enum switch.
Cases name variants without qualification and match by variant, independently
of payload contents.
Payload fields therefore need not be comparable.

```go
func printResult(result Result[int]) {
	switch result {
	case Ok:
		fmt.Println(result.Value)
	case Err:
		fmt.Println(result.Err)
	case None, nil:
		fmt.Println("no result")
	}
}
```

When the switch expression is an identifier and a case contains exactly one
variant, that identifier has the variant's concrete type within the case.
This permits direct access to the fields valid for that variant.
A case containing multiple variants retains the enum type and cannot select
variant-specific fields.

If an enum switch has no `default` clause, it must list every variant and
`nil` exactly once.
Omitting a case or repeating one is a compile-time error.
A `default` clause opts out of exhaustiveness checking.
This is useful when a package intentionally wants to tolerate variants added by
a dependency.

`fallthrough` is not permitted in an enum switch because it would invalidate
the narrowed type in the following case.

Type switches on enum values accept the same unqualified variant names and the
same exhaustiveness rules:

```go
func value(result Result[int]) (int, bool) {
	switch result := result.(type) {
	case Ok:
		return result.Value, true
	case Err, None, nil:
		return 0, false
	}
}
```

An unexported variant cannot be named outside its declaring package.
Code in another package must use a `default` clause when switching on an enum
that has unexported variants.

### Methods

Methods may be declared on an enum type:

```go
func (result Result[T]) Or(zero T) T {
	switch result {
	case Ok:
		return result.Value
	case Err, None, nil:
		return zero
	}
}
```

Such methods are conveniences on enum values.
They are not methods of individual variant types and do not cause the enum to
satisfy an unrelated interface.

Every enum and variant has an implicitly declared method:

```go
Variant() string
```

For a variant value, `Variant` returns the identifier used in the declaration.
For example, `Result[int].Ok{Value: 42}.Variant()` returns `"Ok"`.
The method deliberately does not include payload fields.
Calling a method on a nil enum has the same behavior as calling a method through
a nil interface value.

A program may not declare another method named `Variant` on an enum.
An enum method may not have the same name as one of its variants.

### Type identity and reflection

An enum is a named type with an implementation-defined sealed representation.
Each variant is represented by a distinct named type whose underlying type is
the struct described by the variant fields.
Only the compiler-created variant types can satisfy the enum.

The prototype uses an interface-like representation for enum values and marks
variant runtime types so that pointers and types that promote internal marker
methods cannot satisfy the enum through reflection or a runtime assertion.
The representation remains an implementation detail.

The standard syntax and type APIs gain the information needed by tools:

* `go/token` adds `ENUM`.
* `go/ast` adds `EnumDecl` and `EnumVariant` nodes.
* `go/types.Named.EnumType` reports the enum containing a variant.
* `go/types.Named.EnumVariants` reports variants in declaration order.

Parsers, formatters, documentation tools, analyzers, and language servers can
therefore preserve the closed relationship instead of inferring it from marker
methods.

## Rationale

### Why add a distinct language construct?

Interfaces intentionally describe open behavior.
Enums describe closed data alternatives.
Although a private marker method can prevent implementations in other packages,
it cannot tell the compiler which implementations are intended or make switches
exhaustive.

A distinct construct lets the compiler enforce the invariant and lets readers
see the full set of alternatives in one declaration.

### Why reuse `switch`?

Go already uses `switch` to discriminate values and dynamic types.
Extending it for enum variants avoids adding a separate pattern-matching
expression or a second control-flow construct.
The narrowing rule is limited to a single variant case, where the field set is
unambiguous.

### Why is `enum` contextual?

Making `enum` a keyword in every context would break existing programs that use
it as an identifier.
The declaration can be recognized unambiguously after a type name and optional
type parameters, so a contextual use preserves source compatibility.

### Why is the zero value `nil`?

Choosing one variant as the implicit zero value would give declaration order
semantic meaning and would silently zero all of that variant's fields.
For payload variants, that value is often not meaningful.

An explicit `nil` state follows the existing interface representation, does not
privilege a variant, and makes absence visible in exhaustive switches.
Programs that do not permit absence can reject `nil` at their boundaries.

### Why `Variant` instead of `String`?

`String` conventionally formats an entire value and may reasonably include
payload fields.
The generated operation returns only the declared tag.
The name `Variant` states that narrower contract and leaves `String` available
for application-defined formatting.

### Why are variants constructors rather than ordinary types?

The public abstraction is the closed enum, not a family of independently useful
types.
Constructor-only names prevent APIs from accepting one variant while claiming
to accept the enum, avoid leaking the representation, and allow the same short
variant names to be reused by different enums.

The switch narrowing rule provides access to variant fields at the point where
the variant is known.

### Alternatives

Integer constants do not support payloads and do not make invalid tag/payload
combinations unrepresentable.

Interfaces plus structs remain appropriate for extensible behavior, but they
require boilerplate and cannot provide a compiler-known complete set.

Structs containing a tag and optional fields permit contradictory states and
require run-time validation.

General union types or pattern matching would solve a larger problem at a much
larger language and tooling cost.
This proposal is intentionally limited to named, closed alternatives and the
existing `switch` statement.

Using the first declared variant as a default was rejected because declaration
order should not silently choose a semantic state or zero a payload.

Generating `String` was rejected because it suggests formatting semantics that
the enum declaration cannot choose correctly for payloads.

## Compatibility

The change is backward compatible with existing Go source.
`enum` is contextual, so existing identifiers named `enum` retain their current
meaning.
No existing type changes identity, assignability, method sets, or run-time
representation.

The feature is gated by the module's Go language version.
Source using enum declarations requires the first Go release containing the
feature.

The variant set of an exported enum is part of that package's API.
Adding a variant can cause a downstream exhaustive switch to stop compiling.
Callers that need forward compatibility can include a `default` clause, while
callers that want the compiler to identify newly added states can omit it.

Tools that inspect syntax trees must handle the new AST nodes.
This is the normal ecosystem cost of adding a declaration form.

## Implementation

The working implementation is available in Go+ and in the linked Go change.
It covers:

* scanning, parsing, AST traversal, printing, and formatting;
* `go/types` and compiler type checking;
* generic instantiation and export data;
* compiler lowering and method generation;
* runtime interface checks and reflection;
* cgo, vet, and vendored analysis tools; and
* specification, API, release-note, and regression tests.

The prototype represents an enum as a sealed interface-like value and each
variant as a struct-backed concrete value.
This gives enum storage and dispatch costs comparable to the interface-plus-
struct pattern it replaces.
Enum switches compare the variant's dynamic type and do not compare payloads.

The implementation is split across the same compiler and standard-library
components that already support interfaces, structs, generic named types, and
type switches.
It does not require a garbage collector or calling convention change.

If accepted, the implementation would land during the development half of a Go
release cycle behind the corresponding language version.
The `x/tools` and `gopls` changes would be coordinated before the vendored tools
dependency is updated.

## Open issues

### Encoding

This proposal does not add special behavior to `encoding/json`, `encoding/gob`,
or other encoders.
Packages may encode the generated variant name and payload according to their
own wire format.
A standard representation could be proposed separately after experience with
the language feature.

### Reflection API

The prototype exposes enum relationships through `go/types` because source
tools require them.
It does not add public `reflect` methods for enumerating variants.
Whether runtime reflection needs such an API can be evaluated separately.

### Exhaustiveness and API evolution

Exhaustive switches intentionally make newly added variants visible as compile
errors.
Experience with the prototype should determine whether a more explicit opt-in
than omission of `default` would better communicate that compatibility choice.

### Numeric enums

This proposal addresses algebraic enums with optional payloads.
It does not add shorthand for sequences of typed integer constants.
Existing `const` and `iota` declarations remain the mechanism for numeric
enumerations.
