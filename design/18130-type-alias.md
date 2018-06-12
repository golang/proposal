# Proposal: Type Aliases

Authors: Russ Cox, Robert Griesemer

Last updated: December 16, 2016

Discussion at https://golang.org/issue/18130.

## Abstract

We propose to add to the Go language a type alias declaration, which introduces an alternate name for an existing type. The primary motivation is to enable gradual code repair during large-scale refactorings, in particular moving a type from one package to another in such a way that code referring to the old name interoperates with code referring to the new name. Type aliases may also be useful for allowing large packages to be split into multiple implementation packages with a single top-level exported API, and for experimenting with extended versions of existing packages.

## Background

The article [Codebase Refactoring (with help from Go)](https://talks.golang.org/2016/refactor.article) presents the background for this change in detail.

In short, one of Go's goals is to scale well to large codebases. In those codebases, it's important to be able to refactor the overall structure of the codebase, including changing which APIs are in which packages. In those large refactorings, it is important to support a transition period in which the API is available from both the old and new locations and references to old and new can be mixed and interoperate. Go provides workable mechanisms for this kind of change when the API is a const, func, or var, but not when the API is a type. There is today no way to arrange that oldpkg.OldType and newpkg.NewType are identical and that code referring to the old name interoperates with code referring to the new name. Type aliases provide that mechanism.

This proposal is a replacement for the [generalized alias proposal](https://golang.org/design/16339-alias-decls) originally targeted for, but held back from, Go 1.8.

## Proposal

The new type declaration syntax `type T1 = T2` declares `T1` as a _type alias_ for `T2`. After such a declaration, T1 and T2 are [identical types](https://golang.org/ref/spec#Type_identity). In effect, `T1` is merely an alternate spelling for `T2`.

The language grammar changes by modifying the current definition of TypeSpec from

    TypeSpec     = identifier Type .

to

    TypeSpec     = identifier [ "=" ] Type .

Like in any declaration, T1 must be an [identifier](https://golang.org/ref/spec#Identifiers). If T1 is an [exported identifier](https://golang.org/ref/spec#Exported_identifiers), then T1 is exported for use by importing packages. There are no restrictions on the form of `T2`: it may be [any type](https://golang.org/ref/spec#Type), including but not limited to types imported from other packages. Anywhere a TypeSpec is allowed today, a TypeSpec introducing a type alias is valid, including inside function bodies.

Note that because T1 is an alternate spelling for T2, nearly all analysis of code involving T1 proceeds by first expanding T1 to T2. In particular, T1 is not necessarily a [named type](https://golang.org/ref/spec#Types) for purposes such as evaluating [assignability](https://golang.org/ref/spec#Assignability). 

To make the point about named types concrete, consider:

	type Name1 map[string]string
	type Name2 map[string]string
	type Alias = map[string]string

According to [Go assignability](https://golang.org/ref/spec#Assignability), a value of type Name1  is assignable to map[string]string (because the latter is not a named type) but a value of type Name1 is not assignable to Name2 (because both are named types, and the names differ). In this example, because Alias is an alternate spelling for map[string]string, a value of type Name1 is assignable to Alias (because Alias is the same as map[string]string, which is not a named type).

Note: It’s possible that due to aliases, the spec term “named type” should be clarified or reworded in some way, or a new term should replace it, like “declared type”. This proposal uses words like “written” or “spelled” when describing aliases to avoid the term “named”. We could also use a better pair of names than “type declaration” and “type alias declaration”.

### Comparison of type declarations and type aliases

Go already has a [type declaration](https://golang.org/ref/spec#Type_declarations) `type Tnamed Tunderlying`. That declaration defines a new type Tnamed, different from (not identical to) Tunderlying. Because Tnamed is different from all other types, notably Tunderlying, composite types built from Tnamed and Tunderlying are different. For example, these pairs are all different types:


 - *Tnamed and *Tunderlying
 - chan Tnamed and chan Tunderlying
 - func(Tnamed) and func(Tunderlying)
 - interface{ M() Tnamed } and interface{ M() Tunderlying }

Because Tnamed and Tunderlying are different types, a Tunderlying stored in an interface value x does not match a type assertion `x.(Tnamed)` and does not match a type switch `case Tnamed`; similarly, a Tnamed does not match `x.(Tunderlying)` nor `case Tunderlying`.

Tnamed, being a named type, can have [method declarations](https://golang.org/ref/spec#Method_declarations) associated with it.

In contrast, the new type alias declaration `type T1 = T2` defines T1 as an alternate way to write T2. The two _are_ identical, and so these pairs are all identical types:

 - *T1 and *T2
 - chan T1 and chan T2
 - func(T1) and func(T2)
 - interface{ M() T1 } and interface{ M() T2 }

Because T1 and T2 are identical types, a T2 stored in an interface value x does match a type assertion `x.(T1)` and does match a type switch `case T1`; similarly a T1 does match `x.(T2)` and `case T2`.

Because T1 and T2 are identical types, it is not valid to list both as different cases in a type switch, just as it is not valid to list T1 twice or T2 twice. (The spec already says, “[The types listed in the cases of a type switch must all be different.](https://golang.org/ref/spec#Type_switches)”)

Since T1 is just another way to write T2, it does not have its own set of method declarations. Instead, T1’s method set is the same as T2’s. At least for the initial trial, there is no restriction against method declarations using T1 as a receiver type, provided using T2 in the same declaration would be valid.
Note that if T1 is an alias for a type T2 defined in an imported package, method declarations using T1 as a receiver type are invalid, just as method declarations using T2 as a receiver type are invalid.

### Type cycles

In a type alias declaration, in contrast to a type declaration, T2 must never refer, directly or indirectly, to T1. For example `type T = *T` and `type T = struct { next *T }` are not valid type alias declarations. In contrast, if the equals signs were dropped, those would become valid ordinary type declarations. The distinction is that ordinary type declarations introduce formal names that provide a way to describe the recursion. In contrast, aliases must be possible to “expand out”, and there is no way to expand out an alias like `type T = *T`.

### Relationship to byte and rune

The language specification already defines `byte` as an alias for `uint8` and similarly `rune` as an alias for `int32`, using the word alias as an informal term. It is a goal that the new type declaration semantics not introduce a different meaning for alias. That is, it should be possible to describe the existing meanings of `byte` and `uint8` by saying that they behave as if predefined by:

    type byte = uint8
    type rune = int32

### Effect on embedding

Although T1 and T2 may be identical types, they are written differently. The distinction is important in an [embedded field](https://golang.org/ref/spec#Struct_types) within a struct. In this case, the effective name of the embedded field depends on how the type was written: in the struct

    type MyStruct struct {
        T1
    }

the field always has name T1 (and only T1), even when T1 is an alias for T2. This choice avoids needing to understand how T1 is defined in order to understand the struct definition. Only if (or when) MyStruct's definition changes from using T1 to using T2 would the field name change. Also, T2 may not be a named type at all: consider embedding a MyMap defined by `type MyMap = map[string]interface{}`.

Similarly, because an embedded T1 must be accessed using the name T1, not T2, it is valid to embed both T1 and T2 (assuming T2 is a named type):

    type MyStruct struct {
        T1
        T2
    }

References to myStruct.T1 or myStruct.T2 resolve to the corresponding fields. (Of course, this situation is unlikely to arise, and if T1 (= T2) is a struct type, then any fields within the struct would be inaccessible by direct access due to the usual [selector ambiguity rules](https://golang.org/ref/spec#Selectors).

These choices also match the current meaning today of the byte and rune aliases. For example, it is valid today to write

    type MyStruct struct {
        byte
        uint8
    }

Because neither type has methods, that declaration is essentially equivalent to

    type MyStruct struct {
        byte  byte
        uint8 uint8
    }

## Rationale

An alternate approach would be [generalized aliases](https://golang.org/design/16339-alias-decls), as discussed during the Go 1.8 cycle. However, generalized aliases overlap with and complicate other declaration forms, and the only form where the need is keenly felt is types. In contrast, this proposal limits the change in the language to types, and there is still plenty to do; see the Implementation section.

The implementation changes for type aliases are smaller than for generalized aliases, because while there is new syntax there is no need for a new AST type (the new syntax is still represented as an ast.TypeSpec, matching the grammar). With generalized aliases, any program processing ASTs needed updates for the new forms. With type aliases, most programs processing ASTs care only that they are holding a TypeSpec and can treat type alias declarations and regular type declarations the same, with no code changes. For example, we expect that cmd/vet and cmd/doc may need no changes for type aliases; in contrast, they both crashed and needed updates when generalized aliases were tried.

The question of the meaning of an embedded type alias was identified as [issue 17746](https://github.com/golang/go/issues/17746), during the exploration of general aliases. The rationale for the decision above is given inline with the decision. A key property is that it matches the current handling of byte and rune, so that the language need not have two different classes of type alias (predefined vs user-defined) with different semantics.

The syntax and distinction between type declarations and type alias declarations ends up being nearly identical to that of [Pascal](https://www.freepascal.org/docs-html/ref/refse19.html). The alias syntax itself is also the same as in later languages like [Rust](https://doc.rust-lang.org/book/type-aliases.html).

## Compatibility

This is a new language feature; existing code continues to compile, in keeping
with the [compatibility guidelines](https://golang.org/doc/go1compat).

In the libraries, there is a new field in go/ast's TypeSpec, and there is a new type in go/types, namely types.Alias (details in the Implementation section below). These are both permitted changes at the library level. Code that cares about the semantics of Go types may need updating to handle aliases. This affects programming tools and is unavoidable with nearly any language change.

## Implementation

Since this is a language change, the implementation affects many pieces of the
Go distribution and subrepositories.
The goal is to have basic functionality ready and checked in at the start of the Go 1.9 development cycle, to enable exploration and experimentation by users during the 
entire three month development cycle.

The implementation work is split out below, with owners and target dates listed (Feb 1 is beginning of Go 1.9).

### cmd/compile

The gc compiler needs to be updated to parse the new syntax, to apply the type checking rules appropriately, and to include appropriate information in its export format. 

Minor compiler changes will also be needed to generate proper reflect information for embedded fields, but that is a current bug in the handling of byte and rune. Those will be handled as part of the reflect changes.

Owner: gri, mdempsky, by Jan 31

### gccgo

Gccgo needs to be updated to parse the new syntax, to apply the type checking rules appropriately, and to include appropriate information in its export format.

It may also need the same reflect fix.

Owner: iant, by Jan 31

### go/ast

Reflecting the expansion of the grammar rule, ast.TypeSpec will need some additional field to declare that a type specifier defines a type alias. The likely choice is `EqualsPos token.Pos`, with a zero pos meaning there is no equals sign (an ordinary type declaration).

Owner: gri, by Jan 31

### go/doc

Because go/doc only works with go/ast, not go/types, it may need no updates.

Owner: rsc, by Jan 31

### go/parser

The parser needs to be updated to recognize the new TypeSpec grammar including an equals sign and to generate the appropriate ast.TypeSpec. There should be no user-visible API changes to the package.

Owner: gri, by Jan 31

### go/printer

The printer needs to be updated to print an ast.TypeSpec with an equal sign when present, including lining up equal signs in adjacent type alias specifiers.

Owner: gri, by Jan 31

### go/types

The types.Type interface is implemented by a set of concrete implementations, one for each kind of type. Most likely, a new concrete implementation \*types.Alias will need to be defined. 
The \*types.Alias form will need a new method `Defn() type.Type` that gives the definition of the alias.

The types.Type interface defines a method `Underlying() types.Type`. A \*types.Alias will implement Underlying as Defn().Underlying(), so that code calling Underlying finds its way through both aliases and named types to the underlying form.

Any clients of this package that attempt an exhaustive type switch over types.Type possibilities will need to be updated; clients that type switch over typ.Underlying() may not need updates.

Note that code (like in the subrepos) that needs to compile with Go 1.8 will not be able to use the new API in go/types directly. Instead, there should probably be a new subrepo package, say golang.org/x/tools/go/types/typealias, that contains pre-Go 1.9 and Go 1.9 implementations of a combined type check vs destructure:

    func IsAlias(t types.Type) (name *types.TypeName, defn types.Type, ok bool)

Code in the subrepos can import this package and use this function any time it needs to consider the possibility of an alias type.

Owner: gri, adonovan, by Jan 31

### go/importer

The go/importer’s underlying import data decoders must be updated so they can understand export data containing alias information. This should be done more or less simultaneously with the compiler changes.

Owner: gri, by Jan 31 (for go/internal/gcimporter)
Owner: gri, by Jan 31 (for go/internal/gccgoimporter)

### reflect

Type aliases are mostly invisible at runtime. In particular, since reflect uses reflect.Type equality as type identity, aliases must in general not appear in the reflect runtime data or API.

An exception is the names of embedded fields. To date, package reflect has assumed that the name can be inferred from the type of the field. Aliases make that not true. Embedding type T1 = map[string]interface{} will show up as an embedded field of type map[string]interface{}, which has no name. Embedding type T1 = T2 will show up as an embedded field of type T2, but it has name T1.

Reflect already gets this [wrong for the existing aliases byte and rune](https://github.com/golang/go/issues/17766). The fix for byte and rune should work unchanged for general type aliases as well.

The reflect.StructField already contains an `Anonymous bool` separate from `Name string`. Fixing the problem should be a matter of emitting the right information in the compiler and populating StructField.Name correctly. 

There should be no API changes that affect clients of reflect.

Owner: rsc, by Jan 31

### cmd/api

The API checker cmd/api contains a type switch over implementations of types.Type. It will need to be updated to handle types.Alias.

Owner: bradfitz, by Jan 31

### cmd/doc

Both godoc and cmd/doc (invoked as 'go doc') need to be able to display type aliases. 

If possible, the changes to go/ast, go/doc, go/parser, and go/printer should be engineered so that godoc and 'go doc' need no changes at all, other than compiling against the newer versions of these packages. In particular, having no new go/ast type means that type switches need not be updated, and existing code processing TypeSpec is likely to continue to work for type alias-declaring TypeSpecs.

(It would be nice to have the same property for go/types, but that doesn't seem possible: go/types must expose the new concept of alias.)

Owner: rsc, by Jan 31

### cmd/gofmt

Gofmt should need no updating beyond compiling with the new underlying packages.

Owner: gri, by Jan 31

### cmd/vet

Vet uses go/types but does not appear to have any exhaustive switches on types.Type. It may need no updating.

Owner: rsc, by Jan 31

### golang.org/x/tools/cmd/goimports

Goimports should need no updating beyond compiling with the new underlying packages. Goimports does care about the set of exported symbols from a package, but it already handles exported type definitions as represented by TypeSpecs; the same code should work unmodified for aliases.

Owner: bradfitz, by Jan 31

### golang.org/x/tools/cmd/godex

May not need much updating. printer.writeTypeInternal has a switch on types.Type with a default that does p.print(t.String()). This may be right for aliases and may just work, or may need to be updated.

Owner: gri, by Apr 30.

### golang.org/x/tools/cmd/guru

Various switches on types.Type that may need updating.

Owner: adonovan, by Feb 28.

### golang.org/x/tools/go/callgraph/rta

Has type switches on types.Type.

Owner: adonovan, by Apr 30.

### golang.org/x/tools/go/gcexportdata

Implemented in terms of golang.org/x/tools/go/gcimporter15, which contains type switches on types.Type. Must also update to understand aliases in export data. golang.org/x/tools/go/gcimporter15 contains mostly modified copies of the code under go/internal/gcimporter. They should be updated simultaneously.

Owner: gri, by Jan 31.

### golang.org/x/tools/go/internal/gccgoimporter

Must update to understand aliases in export data. This code is mostly a modified copy of the code under go/internal/gccgoimporter. They should be updated simultaneously.

Owner: gri, by Apr 30.

### golang.org/x/tools/go/pointer

Semantically, type aliases should have very little effect. May not need significant updates, but there are a few type switches on types.Type.

Owner: adonovan, matloob, by Apr 30.

### golang.org/x/tools/go/ssa

Semantically, type aliases should have very little effect. May not need significant updates, but there are a few type switches on types.Type.

Owner: adonovan, matloob, by Apr 30.

### golang.org/x/tools/go/types/typeutil

Contains an exhaustive type switch on types.Type in Hasher.hashFor. Will need to be updated for types.Alias.

Owner: gri, adonovan, by Apr 30.

### golang.org/x/tools/godoc/analysis

Contains mentions of types.Named, but apparently no code with a type switch on types.Type (`case *types.Named` never appears). It is possible that no updates are needed.

Owner: adonovan, gri, by Jan 31.

### golang.org/x/tools/refactor

Has a switch on a types.Type of an embedded field to look for the type of the field and checks for \*types.Pointer pointing at \*types.Named and also \*types.Named. Will need to allow \*types.Alias in both places as well.

Owner: adonovan, matloob, by Apr 30.

## Open issues (if applicable)

As noted above, the language specification term “named type” may need to be rephrased in some places. This proposal is clear on the semantics, but alternate phrasing may help make the specification clearer.

The [discussion summary](https://github.com/golang/go/issues/18130#issue-192757828) includes a list of possible restrictions and concerns for abuse. While it is likely that many concerns will not in practice have the severity to merit restrictions, we may need to work out agreed-upon guidance for uses of type aliases. In general this is similar to any other language feature: the first response to potential for abuse is education, not restrictions.


