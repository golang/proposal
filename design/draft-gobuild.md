# Bug-resistant build constraints — Draft Design

Russ Cox\
June 30, 2020

This is a **Draft Design**, not a formal Go proposal,
because it describes
a potential [large change](https://research.swtch.com/proposals-large).
The goal of circulating this draft design is to collect feedback
to shape an intended eventual proposal.

We are using this change to experiment with new ways to
[scale discussions](https://research.swtch.com/proposals-discuss)
about large changes.

For this change, we will use
[a Go Reddit thread](https://golang.org/s/go-build-reddit)
to manage Q&A, since Reddit's threading support
can easily match questions with answers
and keep separate lines of discussion separate.

There is also a [video presentation](https://golang.org/s/go-build-video) of this draft design.

The [prototype code](https://golang.org/s/go-build-code) is also available for trying out.

## Abstract

We present a possible plan to
transition from the current `// +build` lines for build tag selection
to new `//go:build` lines that use standard boolean expression syntax.
The plan includes relaxing the possible placement of `//go:build` lines
compared to `// +build` lines, as well as rejecting misplaced `//go:build` lines.
These changes should make build constraints easier to use
and reduce time spent debugging mistakes.
The plan also includes a graceful transition from `// +build` to `//go:build`
syntax that avoids breaking the Go ecosystem.

This design draft is based on a preliminary discussion on
[golang.org/issue/25348](https://golang.org/issue/25348),
but discussion of this design draft should happen on
[the Go Reddit thread](https://golang.org/s/go-build-reddit).


## Background

It can be necessary to write different Go code for different compilation contexts.
Go’s solution to this problem is conditional compilation at the file level:
each file is either in the build or not.
(Compared with the C preprocessor’s conditional selection of individual lines,
selection of individual files is easier to understand and requires no special support
in tools that parse single source files.)

Go refers to the current operating system as `$GOOS`
and the current architecture as `$GOARCH`.
This section uses the generic names GOOS and GOARCH
to stand in for any of the specific names (windows, linux, 386, amd64, and so on).

When the `go/build` package was written in August 2011,
it added explicit support for the convention that files
named `*_GOOS.*`, `*_GOARCH.*`, or `*_GOOS_GOARCH.*`
only compiled on those specific systems.
Until then, the convention was only a manual one,
maintained by hand in the package Makefiles.

For more complex situations, such as files that applied
to multiple operating systems (but not all),
build constraints were introduced in September 2011.

### Syntax

Originally, the arguments to a build constraint
were a list of alternatives, each of which took
one of three possible forms:
an operating system name (GOOS),
an architecture (GOARCH),
or both separated by a slash (GOOS/GOARCH).

[CL 5018044](https://golang.org/cl/5018044)
used a `//build` prefix,
but a followup discussion on
[CL 5011046](https://codereview.appspot.com/5011046)
while updating the tree to use the comments
led to the syntax changing to `// +build`
in [CL 5015051](https://golang.org/cl/5015051).

For example, this line indicated that the file should build
on Linux for any architecture, or on Windows only for 386:

	// +build linux windows/386

That is, each line listed a set of OR’ed conditions.
Because each line applied independently, multiple lines
were in effect AND’ed together.

For example,

	// +build linux windows
	// +build amd64

and

	// +build linux/amd64 windows/amd64

were equivalent.

In December 2011, [CL 5489100](https://golang.org/cl/5489100)
added the `cgo` and `nocgo` build tags.
It also generalized slash syntax to mean AND of arbitrary tags,
not just GOOS and GOARCH, as in `// +build nocgo/linux`.

In January 2012, [CL 5554079](https://golang.org/cl/5554079)
added support for custom build tags (such as `appengine`),
changed slash to comma, and introduced `!` for negation.

In March 2013, [CL 7794043](https://golang.org/cl/7794043) added the `go1.1` build tag,
enabling release-specific file selection.
The syntax changed to allow dots in tag names.

Although each of these steps makes sense in isolation,
we have arrived at a non-standard boolean expression syntax
capable of expressing ANDs of ORs of ANDs of potential NOTs of tags.
It is difficult for developers to remember the syntax.
For example, two of these three mean the same thing, but which two?

	// +build linux,386

	// +build linux 386

	// +build linux
	// +build 386

The simple form worked well in the original context,
but it has not evolved gracefully.
The current richness of expression would be better served
by a more familiar syntax.

Surveying the public Go ecosystem for `// +build` lines in March 2020
turned up a few illustrative apparent bugs that had so far eluded
detection. These bugs might have been avoided entirely
if developers been working with more familiar syntax.

 - [github.com/streamsets/datacollector-edge](https://github.com/streamsets/datacollector-edge/issues/8)

       // +build 386 windows,amd64 windows

   Confused AND and OR: simplifies to “`386` OR `windows`”.\
   Apparently intended `// +build 386,windows amd64,windows`.

 - [github.com/zchee/xxhash3](https://github.com/zchee/xxhash3/issues/1)

       // +build 386 !gccgo,amd64 !gccgo,amd64p32 !gccgo

   Confused AND and OR: simplifies to “`386` OR NOT `gccgo`”.\
   Apparently intended:

       // +build 386 amd64 amd64p32
       // +build !gccgo


 - [github.com/gopherjs/vecty](https://github.com/gopherjs/vecty/issues/261)

       // +build go1.12,wasm,js js

   Intended meaning unclear; simplifies to just “`js`”.

 - [gitlab.com/aquachain/aquachain](https://gitlab.com/aquachain/aquachain/-/issues/2)

       // +build windows,solaris,nacl nacl solaris windows

   Intended (but at least equivalent to) `// +build nacl solaris windows`.

 - [github.com/katzenpost/core](https://github.com/katzenpost/core/issues/97)

       // +build linux,!amd64
       // +build linux,amd64,noasm
       // +build !go1.9

   Unsatisfiable (`!amd64` and `amd64` can’t both be true).\
   Apparently intended `// +build linux,!amd64 linux,amd64,noasm !go1.9`.

 - [gitlab.com/aquachain/aquachain](https://gitlab.com/aquachain/aquachain/-/issues/2)

       // +build windows,solaris,nacl nacl solaris windows

   Intended (but at least equivalent to) `// +build nacl solaris windows`.

Later, in June 2020, Alan Donovan wrote some 64-bit specific code that he annotated with:

	//+build linux darwin
	//+build amd64 arm64 mips64x ppc64x

For the file implementing the generic fallback, he needed the negation of that condition and wrote:

	//+build !linux,!darwin
	//+build !amd64,!arm64,!mips64x,!ppc64x

This is subtly wrong. He correctly negated each line, but repeated lines apply constraints independently,
meaning they are ANDed together. To negate the overall meaning, the two lines in the fallback need
to be ORed together, meaning they need to be a single line:

	//+build !linux,!darwin !amd64,!arm64,!mips64x,!ppc64x

Alan has written a very good book about Go—he is certainly an experienced developer—and [still got this wrong](https://github.com/google/starlark-go/pull/280).
It's all clearly too subtle.
Getting ahead of ourselves just a little, if we used a standard boolean syntax,
then the first file would have used:

	(linux || darwin) && (amd64 || arm64 || mips64x || ppc64x)

and the negation in the fallback would have been easy:

	!((linux || darwin) && (amd64 || arm64 || mips64x || ppc64x))

### Placement

In addition to confusion about syntax, there is also confusion
about placement. The documentation (in `go doc go/build`) explains:

> “Constraints may appear in any kind of source file (not just Go),
> but they must appear near the top of the file, preceded only by blank lines
> and other line comments. These rules mean that in Go files a build
> constraint must appear before the package clause.
>
> To distinguish build constraints from package documentation, a series of
> build constraints must be followed by a blank line.”

Because the search for build constraints stops
at the first non-`//`, non-blank line (usually the Go `package` statement),
this is an ignored build constraint:

	package main

	// +build linux

The syntax even excludes
C-style `/* */` comments, so this is an ignored build constraint:

	/*
	Copyright ...
	*/

	// +build linux

	package main

Furthermore, to avoid confusion with doc comments,
the search stops stops at the last blank line before the
non-`//`, non-blank line, so this is an ignored build constraint
(and a doc comment):

	// +build linux
	package main

This is also an ignored build constraint, in an assembly file:

	// +build 386 amd64
	#include "textflag.h"

Surveying the public Go ecosystem for `// +build` lines in March 2020
turned up

 - 98 ignored build constraints after `/* */` comments,
   usually copyright notices;
 - 50 ignored build constraints in doc comments;
 - and 11 ignored build constraints after the `package` declaration.

These are small numbers compared to the 110,000 unique files found
that contained build constraints,
but these are only the ones that slipped through, unnoticed,
into the latest public commits.
We should expect that there are many more such mistakes
corrected in earlier commits
or that lead to head-scratching debugging sessions
but avoid being committed.

## Design

The core idea of the design is
to replace the current `// +build` lines for build tag selection
with new `//go:build` lines that use more familiar boolean expressions.
For example, the old syntax

	// +build linux
	// +build 386

would be replaced by the new syntax

	//go:build linux && 386

The design also admits `//go:build` lines in more locations
and rejects misplaced `//go:build` lines.

The key to the design is a smooth transition that avoids
breaking Go code.

The next three sections explain these three parts of the design in detail.

### Syntax

The new syntax is given by this grammar, using the [notation of the Go spec](https://golang.org/ref/spec#Notation):

	BuildLine      = "//go:build" Expr
	Expr           = OrExpr
	OrExpr         = AndExpr   { "||" AndExpr }
	AndExpr        = UnaryExpr { "&&" UnaryExpr }
	UnaryExpr      = "!" UnaryExpr | "(" Expr ")" | tag
	tag            = tag_letter { tag_letter }
	tag_letter     = unicode_letter | unicode_digit | "_" | "."

That is, the syntax of build tags is unchanged from its current form,
but the combination of build tags is now done with
Go’s `||`, `&&`, and `!` operators and parentheses.
(Note that build tags are not always valid Go expressions,
even though they share the operators,
because the tags are not always valid identifiers.
For example: “`go1.1`”.)

It is an error for a file to have more than one `//go:build` line,
to eliminate confusion about whether multiple lines are
implicitly ANDed or ORed together.

### Placement

The current search for build constraints can be explained concisely,
but it has unexpected behaviors that are difficult to understand,
as discussed in the Background section.

It remains useful for both people and programs like the `go` command
not to need to read the entire file to find any build constraints,
so this design still ends the search for build constraints
at the first non-comment text in the file.
However, this design allows placing `//go:build` constraints
after `/* */` comments or in doc comments.
([Proposal issue 37974](https://golang.org/issue/37974),
which will ship in Go 1.15,
strips those `//go:` lines out of the doc comments.)

The new rule would be:

> “Constraints may appear in any kind of source file (not just Go),
> but they must appear near the top of the file, preceded only by blank lines
> and other `//` and `/* */` comments. These rules mean that in Go files a build
> constraint must appear before the package clause.”

In addition to this more relaxed rule,
the design would change `gofmt` to move misplaced
build constraints
to valid locations,
and it would change the Go compiler and assembler
reject misplaced build constraints.
This will correct most misplaced constraints automatically
and report the others; no misplaced constraint should go unnoticed.
(The next section describes the tool changes in more detail.)

### Transition

A smooth transition is critical for a successful rollout.
By the [Go release policy](https://golang.org/doc/devel/release.html#policy),
the release of Go 1.N
ends support for Go 1.(N-2), but most users will still want to be
able to write code that works with both Go 1.(N−1) and Go 1.N.
If Go 1.N introduces support for `//go:build` lines,
code that needs to build with the past two releases can’t fully adopt
the new syntax until Go 1.(N+1) is released.
Publishers of popular dependencies may not realize this,
which may lead to breakage in the Go ecosystem.
We must make accidental breakage unlikely.

To help with the transition, we envision a plan
carried out over three Go releases.
For concreteness, we call them Go 1.(N−1), Go 1.N, and Go 1.(N+1).
The bulk of the work happens in Go 1.N,
with minor preparation in Go 1.(N−1) and minor cleanup in Go 1.(N+1).

**Go 1.(N−1)** would prepare for the transition with minimal changes.
In Go 1.(N−1):

 - Builds will fail when a Go source file
   contains `//go:build` lines without `// +build` lines.
 - Builds will _not_ otherwise look at `//go:build` lines
   for file selection.
 - Users will not be encouraged to use `//go:build` lines yet.

At this point:

 - Packages will build in Go 1.(N−1) using the same files as in Go 1.(N-2), always.
 - Go 1.(N−1) release notes will not mention `//go:build` at all.

**Go 1.N** would start the transition. In Go 1.N:

 - Builds will start preferring `//go:build` lines for file selection.
   If there is no `//go:build` in a file, then any `// +build` lines
   still apply.
 - Builds will no longer fail if a Go file contains `//go:build`
   without `// +build`.
 - Builds will fail if a Go or assembly file contains `//go:build` too late in the file.
 - `Gofmt` will move misplaced `//go:build` and `// +build`
   lines to their proper location in the file.
 - `Gofmt` will format the expressions in `//go:build` lines
   using the same rules as for other Go boolean expressions
   (spaces around all `&&` and `||` operators).
 - If a file contains only `// +build` lines,
   `gofmt` will add an equivalent `//go:build` line above them.
 - If a file contains both `//go:build` and `// +build` lines,
   `gofmt` will consider the `//go:build` the source of truth
   and update the `// +build` lines to match,
   preserving compatibility with earlier versions of Go.
   `Gofmt` will also reject `//go:build` lines that are deemed
   too complex to convert into `// +build` format,
   although this situation will be rare.
   (Note the “If” at the start of this bullet.
   `Gofmt` will _not_ add `// +build` lines to a file
   that only has `//go:build`.)
 - The `buildtags` check in `go vet` will add support for `//go:build` constraints.
   It will fail when a Go source file contains
   `//go:build` and `// +build` lines with different meanings.
   If the check fails, one can run `gofmt` `-w`.
 - Release notes will explain `//go:build` and the transition.

At this point:

 - Go 1.(N-2) is now unsupported, per the [Go release policy](https://golang.org/doc/devel/release.html#policy).
 - Packages will build in Go 1.N using the same files as in Go 1.(N−1),
   provided they pass Go 1.N `go vet`.
 - Packages that contain conflicting `//go:build` and `// +build` lines
   will fail Go 1.N `go vet`.
 - Anyone using `gofmt` on save will not fail `go vet`.
 - Packages that contain only `//go:build` lines will work fine when
   using only Go 1.N.
   If such packages are built using Go 1.(N−1), the build will fail, loud and clear.

**Go 1.(N+1)** would complete the transition. In Go 1.(N+1):

 - A new fix in `go fix` will remove `// +build` stanzas,
   making sure to leave behind equivalent `//go:build` lines.
   The removal only happens when `go fix` is being run in a module
   with a `go 1.N` (or later) line, which is taken as an explicit signal
   that the developer no longer needs compatibility with Go 1.(N−1).
   The removal is never done in GOPATH mode, which lacks
   any such explicit signal.
 - Release notes will explain that the transition is complete.

At this point:

 - Go 1.(N−1) is now unsupported, per the Go release policy.
 - Packages will build in Go 1.(N+1) using the same file as in Go 1.N, always.
 - Running `go fix` will remove all `// +build` lines from the source tree,
   leaving behind equivalent, easier-to-read `//go:build` lines,
   but only on modules that have set a base requirement of Go 1.N.

## Rationale

The motivation is laid out in the Background section above.

The rationale for using Go syntax is that Go developers already
understand one boolean expression syntax.
It makes more sense to reuse that one
than to maintain a second one.
No other syntaxes were considered: any other syntax would be
a second (well, a third) syntax to learn.

As Michael Munday noted in 2018, these lines are difficult to test,
so we would be well served to make them as straightforward as possible
to understand.
This observation is reinforced by the examples in the introduction.

Tooling will need to keep supporting `// +build` lines indefinitely,
in order to continue to build old code.
Similarly, the `go vet` check that `//go:build` and `// +build` lines
match when both are present will be kept indefinitely.
But the `go fix` should at least help us remove `// +build` lines
from new versions of code, so that most developers stop seeing them
or needing to edit them.

The rationale for disallowing multiple `//go:build` lines
is that the entire goal of this design is to replace
implicit AND and OR with explicit `&&` and `||` operators.
Allowing multiple lines reintroduces an implicit operator.

The rationale for the transition is laid out in that section.
We don’t want to break Go developers unnecessarily,
nor to make it easy for dependency authors to break
their dependents.

The rationale for using `//go:build` as the new prefix is that
it matches our now-established convention of using `//go:`
prefixes for directives to the build system or compilers
(see also `//go:generate`, `//go:noinline`, and so on).

The rationale for introducing a new prefix (instead of reusing `// +build`)
is that the new prefix makes it possible to write files that
contain both syntaxes, enabling a smooth transition.

The main alternative to this design is to do nothing at all
and simply stick with the current syntax.
That is an attractive option, since it avoids going through
a transition.
On the other hand, the benefit of the clearer syntax will only grow as we get
more and more Go developers and more and more Go code,
and the transition should be fairly smooth and low-cost.

## Compatibility

Go code that builds today will keep building indefinitely,
without any changes.

The transition aims to make it difficult
to cause new incompatibilities accidentally,
with `gofmt` and `go vet` working to keep old and
new syntaxes in sync during the transition.

Compatibility is also the reason for not providing the `go` `fix`
that removes `// +build` lines until Go 1.(N+1) is released:
that way, the automated tool that breaks Go 1.(N−1) users
is not even available until Go 1.(N−1) is no longer supported.
