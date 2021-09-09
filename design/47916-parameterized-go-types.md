# Additions to go/types to support type parameters

Authors: Rob Findley, Robert Griesemer

Last updated: 2021-08-17

## Abstract

This document proposes changes to `go/types` to expose the additional type information introduced by the type parameters proposal ([#43651](https://golang.org/issues/43651)), including the amendment for type sets ([#45346](https://golang.org/issues/45346)).

The goal of these changes is to make it possible for authors to write tools that understand parameterized functions and types, while staying compatible and consistent with the existing `go/types` API.

This proposal assumes familiarity with the existing `go/types` API.

## Extensions to the type system

The [type parameters proposal] has a nice synopsis of the proposed language changes; here is a brief description of the extensions to the type system:

- Defined types may be _parameterized_: they may have one or more type parameters in their declaration: `type N[T any] ...`.
- Methods on parameterized types have _receiver type parameters_, which parallel the type parameters from the receiver type declaration: `func (r N[T]) m(...)`.
- Non-method functions may be parameterized, meaning they can have one or more type parameters in their declaration: `func f[T any](...)`.
- Each type parameter has a _type constraint_, which is an interface type: `type N[T interface{ m() }] ...`.
- Interface types that are used only as constraints are permitted new embedded elements that restrict the set of types that may implement them: `type N[T interface{ ~int|string }] ...`.
- A new predeclared interface type `comparable` is implemented by all types for which the `==`  and `!=` operators may be used.
- A new predeclared interface type `any` may be used in constraint position, and is a type alias for `interface{}`.
- A parameterized (defined) type may be _instantiated_ by providing type arguments: `type S N[int]; var x N[string]`.
- A parameterized function may be instantiated by providing explicit type arguments, or via type inference.

## Proposal

The sections below describe new types and functions to be added, as well as how they interact with existing `go/types` APIs.

### Type parameters and the `types.TypeParam` Type

```go
func NewTypeParam(obj *TypeName, constraint Type) *TypeParam

func (*TypeParam) Constraint() Type
func (*TypeParam) SetConstraint(Type)
func (*TypeParam) Obj() *TypeName

// Underlying and String implement Type.
func (*TypeParam) Underlying() Type
func (*TypeParam) String() string
```

Within type and function declarations, type parameters names denote type parameter types, represented by the new `TypeParam` type. It is a `Type` with two additional methods: `Constraint`, which returns its type constraint (which may be a `*Named` or `*Interface`), and `SetConstraint` which may be used to set its type constraint. The `SetConstraint` method is necessary to break cycles in situations where the constraint type references the type parameter itself.

For a `*TypeParam`, `Underlying` is the identity method, and `String` returns its name.

Type parameter names are represented by a `*TypeName` with a `*TypeParam`-valued `Type()`. They are declared by type parameter lists, or by type parameters on method receivers. Type parameters are scoped to the type or function declaration on which they are defined. Notably, this introduces a new `*Scope` for parameterized type declarations (for parameterized function declarations the scope is the function scope). The `Obj()` method returns the `*TypeName` corresponding to the type parameter (its receiver).

The `NewTypeParam` constructor creates a new type parameter with a given `*TypeName` and type constraint.

For a method on a parameterized type, each receiver type parameter in the method declaration also defines a new `*TypeParam`, with a `*TypeName` object scoped to the function. The number of receiver type parameters and their constraints matches the type parameters on the receiver type declaration.

Just as with any other `Object`, definitions and uses of type parameter names are recorded in `Info.Defs` and `Info.Uses`.

Type parameters are considered identical (as reported by the `Identical` function) if and only if they satisfy pointer equality. However, see the section on `Signature` below for some discussion of identical type parameter lists.

### Type parameter and type argument lists

```go
type TypeParamList struct { /* ... */ }

func (*TypeParamList) Len() int
func (*TypeParamList) At(i int) *TypeParam

type TypeList struct { /* ... */ }

func (*TypeList) Len() int
func (*TypeList) At(i int) Type
```

A `TypeParamList` type is added to represent lists of type parameters.  Similarly, a `TypeList` type is added to represent lists of type arguments. Both types have a `Len` and `At` methods, with the only difference between them being the type returned by `At`.

### Changes to `types.Named`

```go
func (*Named) TypeParams() *TypeParamList
func (*Named) SetTypeParams([]*TypeParam)
func (*Named) TypeArgs() *TypeList
func (*Named) Orig() *Named
```

The `TypeParams` and `SetTypeParams` methods are added to `*Named` to get and set type parameters. Once a type parameter has been passed to `SetTypeParams`, it is considered _bound_ and must not be used in any subsequent calls to `Named.SetTypeParams` or `Signature.SetTypeParams`; doing so will panic. For non-parameterized types, `TypeParams` returns nil.

When a `*Named` type is instantiated (see [instantiation](#instantiation) below), the result is another `*Named` type which retains the original type parameters but gains type arguments. These type arguments are substituted in the underlying type of the original type to produce a new underlying type. Similarly, type arguments are substituted for the corresponding receiver type parameter in method declarations to produce a new method type.

These type arguments can be accessed via the `TypeArgs` method. For non-instantiated types, `TypeArgs` returns nil.

For instantiated types, the `Orig` method returns the parameterized type that was used to create the instance. For non-instantiated types, `Orig` returns the receiver.

For an instantiated type `t`, `t.Obj()` is equivalent to `t.Orig().Obj()`.

As an example, consider the following code:

```go
type N[T any] struct { t T }

func (N[T]) m()

type _ = N[int]
```

After type checking, the type `N[int]` is a `*Named` type with the same type parameters as `N`, but with type arguments of `{int}`. `Underlying()` of `N[int]` is `struct { t int }`, and `Method(0)` of `N[int]` is a new `*Func`: `func (N[int]) m()`.

Parameterized named types continue to be considered identical (as reported by the `Identical` function) if they satisfy pointer equality. Instantiated named types are considered identical if their original types are identical and their type arguments are pairwise identical. Instantiating twice with the same original type and type arguments _may_ result in pointer-identical `*Named` instances, but this is not guaranteed. There is further discussion of this in the [instantiation](#instantiation) section below.

### Changes to `types.Signature`

```go
func (*Signature) TypeParams() *TypeParamList
func (*Signature) SetTypeParams([]*TypeParam)

func (*Signature) RecvTypeParams() *TypeParamList
func (*Signature) SetRecvTypeParams([]*TypeParam)
```

The `TypeParams` and `SetTypeParams` methods are added to `*Signature` to get and set type parameters. As described in the section on `*Named` types, passing a type parameter more than once to either `Named.SetTypeParams` or `Signature.SetTypeParams` will panic.

The `RecvTypeParams` and `SetRecvTypeParams` methods allow getting and setting receiver type parameters. Signatures cannot have both type parameters and receiver type parameters. For a given receiver `t`, once `t.SetTypeParams` has been called with a non-empty slice, calling `t.SetRecvTypeParams` with a non-empty slice will panic, and vice-versa.

For `Signatures` to be identical (as reported by `Identical`), they must be identical ignoring type parameters, have the same number of type parameters, and have pairwise identical type parameter constraints.

### Changes to `types.Interface`

```go
func (*Interface) IsComparable() bool
func (*Interface) IsConstraint() bool
```

The `*Interface` type gains two methods to answer questions about its type set:

- `IsComparable` reports whether every element of its type set is comparable, which could be the case if the interface is explicitly restricted to comparable types, or if it embeds the special interface `comparable`.
- `IsConstraint` reports whether the interface may only be used as a constraint; that is to say, whether it embeds any type restricting elements that are not just methods. `IsConstraint` returns false if the interface is defined entirely by its method set.

To understand the specific type restrictions of an interface, users may access embedded elements via the existing `EmbeddedType` API, along with the new `Union` type below. Notably, this means that `EmbeddedType` may now return any kind of `Type`.

Interfaces are identical if their type sets are identical. See the [draft spec](https://golang.org/cl/294469) for details on type sets.

The existing `Interface.Empty` method returns true if the interface has no type restrictions and has an empty method set (alternatively: if its type set is the set of all types).

### The `Union` type

```go
type Union struct { /* ... */ }

func NewUnion([]*Term) *Union

func (*Union) Len() int
func (*Union) Term(int) *Term

// Underlying and String implement Type.
func (*Union) Underlying() Type
func (*Union) String() string

type Term struct { /* ... */ }

func NewTerm(bool, Type) *Term

func (*Term) Tilde() bool
func (*Term) Type() Type

func (*Term) String() string
```

A new `Union` type is introduced to represent the type expression `T1 | T2 | ... | Tn`, where `Ti` is a tilde term (`T` or `~T`, for type `T`).  A new `Term` type represents the tilde terms `Ti`, with a `Type` method to access the term type and a `Tilde` method to report if a tilde was present.

The `Len` and `Term` methods may be used to access terms in the union. Unions represent their type expression syntactically: after type checking the union terms will correspond 1:1 to the term expressions in the source, though their order is not guaranteed to be the same. Unions should only appear as embedded elements in interfaces; this is the only place they will appear after type checking, and their behavior when used elsewhere is undefined.

Unions are identical if they describe the same type set. For example `~int | string` is identical to both `string | int` and `int | string | ~int`.

### Instantiation

```go
func Instantiate(env *Environment, orig Type, targs []Type, verify bool) (Type, error)

type ArgumentError struct { /* ... */ }

func (ArgumentError) Error() string
func (ArgumentError) Index() int

type Environment struct { /* ... */ }

func NewEnvironment() *Environment

type Config struct {
  // ...
  Environment *Environment
}
```

A new `Instantiate` function is added to allow the creation of type and function instances. The `orig` argument supplies the parameterized `*Named` or `*Signature` type being instantiated, and the `targs` argument supplies the type arguments to be substituted for type parameters. It is an error to call `Instantiate` with anything other than a `*Named` or `*Signature` type for `orig`, or with a `targs` value that has length different from the number of type parameters on the parameterized type; doing so will result in a non-nil error being returned.

If `verify` is true, `Instantiate` will verify that type arguments satisfy their corresponding type parameter constraint. If they do not, the returned error will be non-nil and may be of type dynamic type `ArgumentError`. `ArgumentError` is a new type used to represent an error associated with a specific argument index.

If `orig` is a `*Named` or `*Signature` type, the length of `targs` matches the number of type parameters, and `verify` is false, `Instantiate` will return a nil error.

An `Environment` type is introduced to represent an opaque type checking environment. This environment may be passed as the first argument to `Instantiate`, or as a field on `Checker`. When a single non-nil `env` argument is used for subsequent calls to `Instantiate`, identical instantiations may re-use existing type instances. Similarly, passing a non-nil `Environment` to `Config` may result in type instances being re-used during the type checking pass. This is purely a memory optimization, and callers may not rely on pointer identity for instances: they must still use `Identical` when comparing instantiated types.

### Instance information

```go
type Info struct {
  // ...

  Instances map[*ast.Ident]Instance`
}

type Instance struct {
  TypeArgs *TypeList
  Type     Type
}
```

Whenever a type or function is instantiated (via explicit instantiation or type inference), we record information about the instantiation in a new `Instances` map on the `Info` struct. This maps the identifier denoting the parameterized function or type in an instantiation expression to the type arguments used in instantiation and resulting instantiated `*Named` or `*Signature` type. For example:

- In the explicit type instantiation `T[int, string]`, `Instances` maps the identifier for `T` to the type arguments `int, string` and resulting `*Named` type.
- Given a parameterized function declaration `func F(P any) (P)` and a call expression `F(int(1))`, `Instances` would map the identifier for `F` in the call expression to the type argument `int`, and resulting `*Signature` type.

Notably, instantiating `Uses[id].Type()` with `Instances[id].TypeArgs` results in a type that is identical to `Instances[id].Type`.

The `Instances` map serves several purposes:

- Providing a mechanism for finding all instances. This could be useful for applications like code generation or go/ssa.
- Mapping an instance back to positions where it occurs, for the purpose of e.g. presenting diagnostics.
- Finding inferred type arguments.

### `comparable` and `any`

The new predeclared interfaces `comparable` and `any` are declared in the `Universe` scope.

[type parameters proposal]: https://go.googlesource.com/proposal/+/refs/heads/master/design/43651-type-parameters.md
[type set proposal]: https://golang.org/issues/45346
