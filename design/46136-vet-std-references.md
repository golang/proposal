# Proposal: check references to standard library packages inconsistent with go.mod go version

Author(s): Jay Conrod based on discussion with Daniel Martí, Paul Jolly, Roger
Peppe, Bryan Mills, and others.

Last updated: 2021-05-12

Discussion at https://golang.org/issue/46136.

## Abstract

With this proposal, `go vet` (and `go test`) would report an error if a package
imports a standard library package or references an exported standard library
definition that was introduced in a higher version of Go than the version
declared in the containing module's `go.mod` file.

This makes the meaning of the `go` directive clearer and more consistent. As
part of this proposal, we'll clarify the reference documentation and make a
recommendation to module authors about how the `go` directive should be set.
Specifically, the `go` directive should indicate the minimum version of Go that
a module supports. Authors should set their `go` version to the minimum version
of Go they're willing to support. Clients may or may not see errors when using a
lower version of Go, for example, when importing a module package that imports a
new standard library package or uses a new language feature.

## Background

The `go` directive was introduced in Go 1.12, shortly after modules were
introduced in Go 1.11.

At the time, there were several proposed language changes that seemed like they
might be backward incompatible (collectively, "Go 2"). To avoid an incompatible
split (like Python 2 and 3), we needed a way to declare the language version
used by a set of packages so that Go 1 and Go 2 packages could be mixed together
in the same build, compiled with different syntax and semantics.

We haven't yet made incompatible changes to the language, but we have made some
small compatible changes (binary literals added in 1.13). If a developer using
Go 1.12 or older attempts to build a package with a binary literal (or any other
unknown syntax), and the module containing the package declares Go 1.13 or
higher, the compiler reports an error explaining the problem. The developer also
sees an error in their own package if their `go.mod` file declares `go 1.12` or
lower.

In addition to language changes, the `go` directive has been used to opt in to
new, potentially incompatible module behavior. In Go 1.14, the `go` version was
used to enable automatic vendoring. In 1.17, the `go` version will control lazy
module loading.

One major complication is that access to standard library packages and features
has not been consistently limited. For example, a module author might use
`errors.Is` (added in 1.13) or `io/fs` (added in 1.16) while believing their
module is compatible with a lower version of Go. The author shouldn't be
expected to know this history, but they can't easily determine the lowest
version of Go their module is compatible with.

This complication has made the meaning of the `go` directive very murky.

## Proposal

We propose adding a new `go vet` analysis to report errors in packages that
reference standard library packages and definitions that aren't available
in the version of Go declared in the containing module's `go.mod` file. The
analysis will cover imports, references to exported top-level definitions
(functions, constants, etc.), and references to other exported symbols (fields,
methods).

The analysis should evaluate build constraints in source files (`// +build`
and `//go:build` comments) as if the `go` version in the containing module's
`go.mod` were the actual version of Go used to compile the package. The
analysis should not consider imports and references in files that would only
be built for higher versions of Go.

This analysis should have no false positives, so it may be enabled by default
in `go test`.

Note that both `go vet` and `go test` report findings for packages named on
the command line, but not their dependencies. `go vet all` may be used to check
packages in the main module and everything needed to build them.

The analysis would not report findings for standard library packages.

The analysis would not be enabled in GOPATH mode.

For the purpose of this proposal, modules lacking a `go` directive (including
projects without a `go.mod` file) are assumed to declare Go 1.16.

## Rationale

When writing this proposal, we also considered restrictions in the `go` command
and in the compiler.

The `go` command parses imports and applies build constraints, so it can report
an error if a package in the standard library should not be imported. However,
this may break currently non-compliant builds in a way that module authors
can't easily fix: the error may be in one of their dependencies. We could
disable errors in packages outside the main module, but we still can't easily
re-evaluate build constraints for a lower release version of Go. The `go`
command doesn't type check packages, so it can't easily detect references
to new definitions in standard library packages.

The compiler does perform type checking, but it does not evaluate build
constraints. The `go` command provides the compiler with a list of files to
compile, so the compiler doesn't even know about files excluded by build
constraints.

For these reasons, a vet analysis seems like a better, consistent way to
find these problems.

## Compatibility

The analysis in this proposal may introduce new errors in `go vet` and `go test`
for packages that reference parts of the standard library that aren't available
in the declared `go` version. Module authors can fix these errors by increasing
the `go` version, changing usage (for example, using a polyfill), or guarding
usage with build constraints.

Errors should only be reported in packages named on the command line. Developers
should not see errors in packages outside their control unless they test with
`go test all` or something similar. For those tests, authors may use `-vet=off`
or a narrower set of analyses.

We may want to add this analysis to `go vet` without immediately enabling it by
default in `go test`. While it should be safe to enable in `go test` (no false
positives), we'll need to verify this is actually the case, and we'll need
to understand how common these errors will be.

## Implementation

This proposal is targeted for Go 1.18. Ideally, it should be implemented
at the same time or before generics, since there will be a lot of language
and library changes around that time.

The Go distribution includes files in the `api/` directory that track when
packages and definitions were added to the standard library. These are used to
guard against unintended changes. They're also used in pkgsite documentation.
These files are the source of truth for this proposal. `cmd/vet` will access
these files from `GOROOT`.

The analysis can determine the `go` version for each package by walking up
the file tree and reading the `go.mod` file for the containing module. If the
package is in the module cache, the analysis will use the `.mod` file for the
module version. This file is generated by the `go` command if no `go.mod`
file was present in the original tree.

Each analysis receives a set of parsed and type checked files from `cmd/vet`.
If the proposed analysis detects that one or more source files (including
ignored files) contain build constraints with release tags (like `go1.18`),
the analysis will parse and type check the package again, applying a corrected
set of release tags. The analysis can then look for inappropriate imports
and references.

## Related issues

* [#30639](https://golang.org/issue/30639)
* https://twitter.com/mvdan_/status/1391772223158034434
* https://twitter.com/marcosnils/status/1372966993784152066
* https://twitter.com/empijei/status/1382269202380251137
