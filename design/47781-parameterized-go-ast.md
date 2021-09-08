# Additions to go/ast and go/token to support parameterized functions and types

Authors: Rob Findley, Robert Griesemer

Last Updated: 2021-08-18

## Abstract

This document proposes changes to `go/ast` to store the additional syntactic information necessary for the type parameters proposal ([#43651](https://golang.org/issues/43651)), including the amendment for type sets ([#45346](https://golang.org/issues/45346)). The changes to `go/types` related to type checking are discussed in a [separate proposal](https://golang.org/cl/328610).

## Syntax Changes

See the [type parameters proposal] for a full discussion of the language changes to support parameterized functions and types, but to summarize the changes in syntax:

- Type and function declarations get optional _type parameters_, as in `type  List[T any] ...` or `func f[T1, T2 any]() { ... }`. Type parameters are a [parameter list].
- Parameterized types may be _instantiated_ with one or more _type arguments_, to make them non-parameterized type expressions, as in `l := &List[int]{}` or `type intList List[int]`.  Type arguments are an [expression list].
- Parameterized functions may be instantiated with one or more type arguments when they are called or used as function values, as in `g := f[int]` or `x := f[int]()`. Function type arguments are an [expression list].
- Interface types can have new embedded elements that restrict the set of types that may implement them, for example `interface { ~int64|~float64 }`. Such elements are type expressions of the form `T1 | T2 ... Tn` where each term `Ti` stands for a type or a `~T` where T is a type.

## Proposal

The sections below describe new types and functions to be added, as well as their invariants. For a detailed discussion of these design choices, see the [appendix](#appendix_considerations-for-api-changes-to-go_ast).

### For type parameters in type and function declarations

```go
type TypeSpec struct {
	// ...existing fields

	TypeParams *FieldList
}

type FuncType struct {
	// ...existing fields

	TypeParams *FieldList
}
```

To represent type parameters in type and function declarations, both `ast.TypeSpec` and `ast.FuncType` gain a new `TypeParams *FieldList` field, which will be nil in the case of non-parameterized types and functions.

### For type and function instantiation

To represent both type and function instantiation with type arguments, we introduce a new node type `ast.IndexListExpr`, which is an `Expr` node similar to `ast.IndexExpr`, but with a slice of indices rather than a single index:

```go
type IndexListExpr struct {
	X Expr
	Lbrack token.Pos
	Indices []Expr
	Rbrack token.Pos
}

func (*IndexListExpr) End() token.Pos
func (*IndexListExpr) Pos() token.Pos
```

Type and function instance expressions will be parsed into a single `IndexExpr` if there is only one index, and an `IndexListExpr` if there is more than one index. Specifically, when encountering an expression `f[expr1, ..., exprN]` with `N` argument expressions, we parse as follows:

1. If `N == 1`, as in normal index expressions `f[expr]`, we parse an `IndexExpr`.
2. If `N > 1`, parse an `IndexListExpr` with `Indices` set to the parsed expressions `expr1, …, exprN`
3. If `N == 0`, as in the invalid expression `f[]`, we parse an `IndexExpr` with `BadExpr` for its `Index` (this matches the current behavior for invalid index expressions).

There were several alternatives considered for representing this syntax. At least two of these alternatives were implemented. They are worth discussing:
 - Add a new `ListExpr` node type that holds an expression list, to serve as the `Index` field for an `IndexExpr` when `N >= 2`.  This is an elegant solution, but results in inefficient storage and, more importantly, adds a new node type that exists only to alter the meaning of an existing node. This is inconsistent with the design of other nodes in `go/ast`, where additional nodes are preferred to overloading existing nodes. Compare with `RangeStmt` and `TypeSwitchStmt`, which are distinct nodes in `go/ast`. Having distinct nodes is generally easier to work with, as each node has a more uniform composition.
 - Overload `ast.CallExpr` to have a `Brackets bool` field, so `f[T]` would be analogous to `f(T)`, but with `Brackets` set to `true`. This is roughly equivalent to the `IndexListExpr` node, and allows us to avoid adding a new type. However, it overloads the meaning of `CallExpr` and adds an additional field.
 - Add an `Tail []Expr` field to `IndexExpr` to hold additional type arguments. While this avoids a new node type, it adds an extra field to IndexExpr even when not needed.

### For type restrictions

```go
package token

const TILDE Token = 88
```

The new syntax for type restrictions in interfaces can be represented using existing node types.

We can represent the expression `~T1|T2 |~T3` in `interface { ~T1|T2|~T3 }` as a single embedded expression (i.e. an `*ast.Field` with empty `Names`), consisting of unary and binary expressions. Specifically, we can introduce a new token `token.TILDE`, and represent `~expr` as an `*ast.UnaryExpr` where `Op` is `token.TILDE`. We can represent `expr1|expr2` as an `*ast.BinaryExpr` where `Op` is `token.OR`, as would be done for a value expression involving bitwise-or.

## Appendix: Considerations for API changes to go/ast

This section discusses what makes a change to `go/ast` break compatibility, what impact changes can have on users beyond pure compatibility, and what type of information is available to the parser at the time we choose a representation for syntax.

As described in the go1 [compatibility promise], it is not enough for standard library packages to simply make no breaking API changes: valid programs must continue to both compile *and* run. Or put differently: the API of a library is both the structure and runtime behavior of its exported API.

This matters because the definition of a 'valid program' using `go/ast` is arguably a gray area. In `go/ast`, there is no separation between the interface to AST nodes and the data they contain: the node set consists entirely of pointers to structs where every field is exported. Is it a valid use of `go/ast` to assume that every field is exported (e.g. walk nodes using reflection)? Is it valid to assume that the set of nodes is complete (e.g. by panicking in the default clause of a type switch)? Which fields may be assumed to be non-nil?

For the purpose of this document, I propose the following heuristic:

> A breaking change to `go/ast` (or go/parser) is any change that modifies (1)
> the parsed representation of existing, valid Go code, or (2) the per-node
> _invariants_ that are preserved in the representation of _invalid_ Go code.
> We consider all documented invariants plus any additional invariants that are
> assumed in significant amounts of code.

Of these two clauses, (1) is straightforward and hopefully uncontroversial: code that is valid in Go 1.17 must parse to an equivalent AST in Go 1.18. (2) is more subtle: there is no guarantee that the syntax tree of invalid code will not change. After all, use of type parameters is invalid in go1.17. Rather, the only guarantee is that _if a property of existing fields holds for a node type N in all representations of code, valid or invalid, it should continue to hold_. For example, `ast.Walk` assumes that `ast.IndexExpr.Index` is never nil. This must be preserved if we use `IndexExpr` to represent type instantiation, even for invalid instantiation expressions such as `var l List[]`.

The rationale for this heuristic is pragmatic: there is too much code in the wild that makes assumptions about nodes in AST representations; that code should not break.

Notable edge cases:
 - It makes sense to preserve the property that all fields on Nodes are exported. `cmd/gofmt` makes this assumption, and it is reasonable to assume that other users will have made this assumption as well (and this was the original intent).
 - There is code in the wild that assumes the completeness of node sets, i.e. panicking if an unknown node is encountered. For example, see issue [vscode-go#1551](https://github.com/golang/vscode-go/issues/1551) for x/tools. If we were to consider this a valid use of `go/ast`, that would mean that we could never introduce a new node type. In order to avoid introducing new nodes, we'd have to pack new syntactic constructs into existing nodes, resulting in cumbersome APIs and increased memory usage. Also, from another perspective, assuming the completeness of node types is not so different from assuming the completeness of fields in struct literals, which is explicitly not guaranteed by the [compatibility promise]. We should therefore consider adding a new node type a valid change (and do our best to publicize this change to our users).

Finally, when selecting our representation, keep in mind that the parser has access to only local syntactic information. Therefore, it cannot differentiate between, for example, the representation of `f[T]` in `var f []func(); T := 0; f[T]()` and `func f[S any](){} ... f[T]()`.

[expression list]: https://golang.org/ref/spec#ExpressionList
[type parameters proposal]: https://go.googlesource.com/proposal/+/refs/heads/master/design/43651-type-parameters.md
[parameter list]: https://golang.org/ref/spec#ParameterList
[compatibility promise]: https://golang.org/doc/go1compat
