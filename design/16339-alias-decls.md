# Proposal: Alias declarations for Go

Authors: Robert Griesemer & Rob Pike.
Last updated: June 31, 2016

Discussion at https://golang.org/issue/16339.

## Abstract
We propose to add alias declarations to the Go language. An alias declaration
introduces an alternative name for an object (type, function, etc.) declared
elsewhere. Aliases simplify splitting up packages because clients can be
updated incrementally, which is crucial for large-scale refactoring.

## 1. Motivation
Suppose we have a library package L and a client package C that depends on L.
During refactoring of code, some functionality of L is moved into a new
package L1, which in turn may require updates to C. If there are multiple
clients C1, C2, ..., many of these clients may need to be updated
simultaneously for the system to build. Failing to do so will lead to build
breakages in a continuous build environment.

This is a real issue in large-scale systems such as we find at Google because
the number of dependencies can go into the hundreds if not thousands. Client
packages may be under control of different teams and evolve at different
speeds. Updating a large number of client packages simultaneously may be close
to impossible. This is an effective barrier to system evolution and maintenance.

If client packages can be updated incrementally, one package (or a small batch
of packages) at a time, the problem is avoided. For instance, after moving
functionality from L into L1, if it is possible for clients to continue to
refer to L in order to get the features in L1, clients don’t need to be
updated at once.

Go packages export constants, types (incl. associated methods), variables, and
functions. If a constant X is moved from a package L to L1, L may trivially
depend on L1 and re-export X with the same value as in L1.

```
package L
import "L1"
const X = L1.X  // X is effectively an alias for L1.X
```

Client packages may use L1.X or continue to refer to L.X and still build
without issues. A similar work-around exists for functions: Package L may
provide wrapper functions that simply invoke the corresponding functions
in L1. Alternatively, L may define variables of function type which are
initialized to the functions which moved from L to L1:

```
package L
import "L1"
var F = L1.F  // F is a function variable referring to L1.F
func G(args…) Result { return L1.G(args…) }
```

It gets more complicated for variables: An incremental approach still exists
but it requires multiple steps. Let’s assume we want to move a variable V
from L to L1. In a first step, we declare a pointer variable Vptr in L1
pointing to L.V:

```
package L1
import "L"
var Vptr = &L.V
```

Now we can incrementally update clients referring to L.V such that they use
(\*L1.Vptr) instead. This will give them full access to the same variable.
Once all references to L.V have been changed, L.V can move to L1; this step
doesn’t require any changes to clients of L1 (though it may require additional
internal changes in L and L1):

```
package L1
import "L"
var Vptr = &V
var V T = ...
```

Finally, clients may be incrementally updated again to use L1.V directly after
which we can get rid of Vptr.

There is no work-around for types, nor is possible to define a named type T in
L1 and re-export it in L and have L.T mean the exact same type as L1.T.

Discussion: The multi-step approach to factor out exported variables requires
careful planning. For instance, if we want to move both a function F and a
variable V from L to L1, we cannot do so at the same time: The forwarder F
left in L requires L to import L1, and the pointer variable Vptr introduced
in L1 requires L1 to import L. The consequence would be a forbidden import
cycle. Furthermore, if a moved function F requires access to a yet unmoved V,
it would also cause a cyclic import. Thus, variables will have to be moved
first in such a scenario, requiring multiple steps to enable incremental
client updates, followed by another round of incremental updates to move
everything else.

## 2. Alias declarations
To address these issues with a single, unified mechanism, we propose a new
form of declaration in Go, called an alias declaration. As the name suggests,
an alias declaration introduces an alternative name for a given object that
has been declared elsewhere, possibly in a different package.

An alias declaration in package L makes it possible to move the original
declaration of an object X (a constant, type, variable, or function) from
package L to L1, while continuing to define and export the name X in L.
Both L.X and L1.X denote the exact same object (L1.X).

Note that the two predeclared types byte and rune are aliases for the
predeclared types uint8 and int32. Alias declarations will enable users
to define their own aliases, and byte and rune can then be defined
internally using this general language mechanism rather than rely on
built-in “magic” only available to the implementation.

## 3. Notation
The existing declaration syntax for constants effectively permits
constant aliases:

```
const C = L1.C  // C is effectively an alias for L1.C
```

Ideally we would like to extend this syntax to other declarations
and give it alias semantics:

```
type T = L1.T  // T is an alias for L1.T
func F = L1.F  // F is an alias for L1.F
```

Unfortunately, this notation breaks down for variables, because it already
has a given (and different) meaning in variable declarations:

```
var V = L1.V  // V is initialized to L1.V
```

Instead of "=" we propose the new alias operator  "->"  to solve the
syntactic issue:

```
const C -> L1.C  // for regularity only, same effect as const C = L1.C
type  T -> L1.T  // T is an alias for type L1.T
var   V -> L1.V  // V is an alias for variable L1.V
func  F -> L1.F  // F is an alias for function L1.F
```

With that, a general alias specification is of the form:

AliasSpec = identifier "->" [ PackageName "." ] identifier .

An alias declaration may refer to another alias, as in:

```
type T1 -> L1.T  // T1 is an alias for L1.T
type T2 -> T1    // T2 is an alias for L1.T
```

The lhs identifier (T1, T2 in the example above) in an alias declaration is
called the alias name (or alias for short). For each alias name there is an
original name (or original for short), which is the non-alias name declared
for a given object (here L1.T).

Some more examples:

```
import "math"
import "oldp"

var v -> oldp.V  // local alias, not exported

type (
	T1 -> oldp.T1  // original for T1 is oldp.T1
	T2 -> T1       // original for T2 is oldp.T1
)

var (
	V1 -> oldp.V1
	V2 T2  // same effect as: var V2 oldp.T1
)

func myF -> oldp.F  // local alias, not exported
func G   -> oldp.G

func f() {
	type T -> muchTooLongATypeName
	x := T{}  // same effect as: x := muchTooLongATypeName{}
	...
}
```

The respective syntactic changes in the language spec are small and
concentrated. Each declaration specification (ConstSpec, TypeSpec, etc.)
gets a new alternative which is an alias specification (AliasSpec).
Grouping is possible as before, except for functions (as before).
See Appendix A1 for details.

The short variable declaration form (using ":=") cannot be used to
declare an alias.

Discussion: Introducing a new operator ("->") has the advantage of not
needing to introduce a new keyword (such as "alias"), which we can't really
do without violating the Go 1 promise (though r@golang and rsc@golang observe
that it would be possible to recognize "alias" as a keyword at the package-
level only, when in const/type/var/func position, and as an identifier
otherwise, and probably not break existing code). As proposed, it also means
that an alias declaration must specify what kind of object the alias refers
to (const, type, var, or func), which we think is an advantage: It makes it
clear to a user what the alias denotes (as with existing declarations); and
it also makes it possible to report an error at the type of the alias
declaration if the aliased object changes (e.g., from being a constant to a
variable) rather than only at where the alias is used.

On the other hand, mdempsky@golang points out that using a keyword would
permit making changes in a package L1, say change a function F into a type F,
and not require a respective update of any alias declarations referring to
L1.F, which in turn might simplify refactoring. Specifically, one could
generalize import declarations so that they can be used to import and rename
specific objects. For instance:

```
	import Printf = fmt.Printf
```

or

```
	import Printf fmt.Printf
```

One might even permit the form

```
	import context.Context
```

as a shorthand for

```
	import Context context.Context
```

analogously to the renaming feature available to imports already. One of the
issues to consider here is that imported packages end up in the file scope and
are only visible in one file. Furthermore, currently they cannot be
re-exported. It is crucial for aliases to be re-exportable. Thus alias imports
would need to end up in package scope. (It would be odd if they ended up in
file scope: the same alias may have to be imported in multiple files of the
same package, possibly with different names.)

The choice of symbol ("->") is somewhat arbitrary, but both "A -> B" and
"A => B" conjure up the image of a reference or forwarding from A to B.
Furthermore, "->" is also used in Unix directory listings for symbolic links,
where the lhs is another name (an alias) for the file mentioned on the rhs.

dneil@golang and r@golang observe that if "->" is written "in reverse" by
mistake, a declaration "var X -> p.X" meant to be an alias declaration is
close to a regular variable declaration "var X <-p.X" (with a missing "=");
though it wouldn’t compile.

adonovan@golang points out that we could permit aliases only to imported
(explicitly package-qualified or dot-imported) identifiers to start with.
This would solve the immediate problem at hand and still allow the more
general form eventually. It may also mean less work during declaration cycle
detection.

## 3. Semantics and rules
An alias declaration declares an alternative name, the alias, for a constant,
type, variable, or function, referred to by the rhs of the alias declaration.
The rhs must be a (possibly package-qualified) identifier; it may itself be an
alias, or it may the original name for the aliased object.

An alias denotes the aliased object, and the effect of using an alias is
indistinguishable from the effect of using the original; the only difference
is the name.

The same scope and export rules (capitalization for export) apply as for all
other identifiers.

An alias declaration may be used wherever it is valid to have a keyword-based
constant, type, variable, or function declaration. In particular, alias
declarations may be grouped and aliases may refer to locally declared objects.

The scope of an alias identifier at the top-level (outside any function) is
the package block (as is the case now for an identifier denoting a constant,
type, variable, or function). The scope of an alias identifier inside a
function begins at the end of the alias specification and ends at the end of
the innermost block (analogous to what is the case now for local declarations).

An alias declaration may refer to any predeclared type including
unsafe.Pointer, but not to any other predeclared object in the Universe scope
(true, false, nil, iota, or any of the predeclared functions) nor any function
of package unsafe (unsafe.Alignof, unsafe.Offsetof, unsafe.Sizeof).

An alias may refer to another alias, but cycles are forbidden. The existing
lexical rules for cycle detection will serve for aliases as well.

A variable “used” via an alias is considered “used” as if it were accessed by
its original name.

Discussion: The main reason for permitting aliases to predeclared types is
regularity - we already implement byte and rune type aliases and the
mechanisms for it exist already. There is no inherent difficulty in permitting
aliases for the predeclared values nil, true, and false. However, due to the
special meaning of nil it seems unwise to permit aliases to nil. The same is
true for iota. The values true and false are constants, so aliases (as unwise
as they may be) are already possible with constant declarations. Predeclared
functions such as new or append (and others) are not regular functions; new
takes a type argument, and append has a generic signature. These function
types cannot be expressed via ordinary function signatures. If an alias to
such a function were exported it would require a new mechanism to export these
functions. Extra machinery for a questionable use case does not seem
justifiable.

For purposes of implementation, unsafe.Pointer and the functions in package
unsafe are treated like any of the other predeclared objects. It is already
possible to declare a new type P with unsafe.Pointer as its underlying type,
export P, and then use that P in another package to convert any pointer type
to P, which then further can be converted to an uintptr. Thus restricting
aliases in some way for unsafe.Pointer is not a meaningful restriction.

## 4. Impact on other libraries and tools
Alias declarations are a source-level and compile-time feature, with no
observable impact at run time. Thus, libraries and tools operating at the
source level or involved in type checking and compilation are expected to
need adjustments.

reflect package
The reflect package permits access to values and their types at run-time.
There’s no mechanism to make a new reflect.Value from a type name, only from
a reflect.Type. The predeclared aliases byte and rune are mapped to uint8 and
int32 already, and we would expect the same to be true for general aliases.
For instance:

```
fmt.Printf("%T", rune(0))
```

prints the original type name int32, not rune. Thus, we expect no API or
semantic changes to package reflect.

go/\* std lib packages
The packages under the go/\* std library tree which deal with source code will
need to be adjusted. Specifically, the packages go/token, go/scanner, go/ast,
go/parser, go/doc, and go/printer will need the necessary API extensions and
changes to cope with the new syntax. These changes should be straightforward.

Package go/types will need to understand how to type-check alias declarations.
It may also require an extension to its API (to be explored).

We don’t expect any changes to the go/build package.

go doc
The go doc implementation will need to be adjusted: It relies on package go/doc
which now exposes alias declarations. Thus, godoc needs to have a meaningful
way to show those as well. This may be a simple extension of the existing
machinery to include alias declarations.

Other tools operating on source code
A variety of other tools operate or inspect source code such as go vet,
go lint, goimport, and others. What adjustments need to be made needs to be
decided on a case-by-case basis.

## 5. Implementation
There are many open questions that need to be answered by an implementation.
To mention a few of them:

Are aliases represented somehow as “first-class” citizens in a compiler and
go/types, or are they immediately “resolved” internally to the original names?
For go/types specifically, adonovan@golang points out that a first-class
representation may have an impact on the go/types API and potentially affect
many tools. For instance, type switches assuming only the kinds of objects now
in existence in go/types would need to be extended to handle aliases, should
they show up in the public API. The go/types’ Info.Uses map, which currently
mapes identifiers to objects, will require especial attention: Should it record
the alias to object references, or only the original names?

At first glance, since an alias is simply another name for an object, it would
seem that an implementation should resolve them immediately, making aliases
virtually invisible to the API (we may keep track of them internally only for
better error messages). On the other hand, they need to be exported and might
need to show up in go/types’ Info.Uses map (or some additional variant thereof)
so that tools such as guru have access to the alias names.

To be prototyped.

# Appendix

## A1. Syntax changes
The syntax changes necessary to accommodate alias declarations are limited
and concentrated. There is a new declaration specification called AliasSpec:

```
AliasSpec = identifier "->" [ PackageName "." ] identifier .
```

An AliasSpec binds an identifier, the alias name, to the object (constant,
type, variable, or function) the alias refers to. The object must be specified
via a (possibly qualified) identifier. The aliased object must be a constant,
type, variable, or function, depending on whether the AliasSpec is within a
constant, type, variable, of function declaration.

Alias specifications may be used with any of the existing constant, type,
variable, or function declarations. The respective syntax productions are
extended as follows, with the extensions marked in red:

```
ConstDecl = "const" ( ConstSpec | "(" { ConstSpec ";" } ")" ) .
ConstSpec = IdentifierList [ [ Type ] "=" ExprList ] | AliasSpec .

TypeDecl  = "type" ( TypeSpec | "(" { TypeSpec ";" } ")" ) .
TypeSpec  = identifier Type | AliasSpec .

VarDecl   = "var" ( VarSpec | "(" { VarSpec ";" } ")" ) .
VarSpec   = IdentList ( Type [ "=" ExprList ] | "=" ExprList ) |
            AliasSpec .

FuncDecl  = "func" FunctionName ( Function | Signature ) |
            "func" AliasSpec .
```

## A2. Alternatives to this proposal
For completeness, we mention several alternatives.

1) Do nothing (wait for Go 2). The easiest solution, but it does not address
the problem.

2) Permit alias declarations for types only, use the existing work-arounds
otherwise. This would be a “minimal” solution for the problem. It would
require the use of work-arounds for all other objects (constants, variables,
and functions). Except for variables, those work-arounds would not be too
onerous. Finally, this would not require the introduction of a new operator
since "=" could be used.

3) Permit re-export of imports, or generalize imports. One might come up with
a notation to re-export all objects of an imported package wholesale,
accessible under the importing package name. Such a mechanism would address
the incremental refactoring problem and also permit the easy construction of
some sort of “super-package” (or component), the API of which would be the sum
of all the re-exported package APIs. This would be an “all-or-nothing” approach
that would not permit control over which objects are re-exported or under what
name. Alternatively, a generalized import scheme (discussed earlier in this
document) may provide a more fine-grained solution.
