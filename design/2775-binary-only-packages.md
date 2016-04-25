# Proposal: Binary-Only Packages

Author: Russ Cox

Last updated: April 24, 2016

Discussion at [golang.org/issue/2775](https://golang.org/issue/2775).

## Abstract

We propose a way to incorporate binary-only packages (without complete source code) into a cmd/go workspace.

## Background

It is common in C for a code author to provide a C header file and the compiled form of a library
but not the complete source code.
The go command has never supported this officially.


In very early versions of Go, it was possible to arrange for a binary-only package simply by
removing the source code after compiling.
But that state looks the same as when the package source code has been deleted 
because the package itself is no longer available, in which case the compiled form
should not continue to be used.
For the past many years the Go command has assumed the latter.

Then it was possible to arrange for a binary-only package by replacing the source code
after compiling, while keeping the modification time of the source code older than
the modification time of the compiled form.
But in normal usage, removing an individual source file is cause for recompilation
even though that cannot be seen in the modification times.
To detect that situation, 
Go 1.5 started using the full set of source file names that went into
a package as one input to a hash that produced the package's ``build ID''.
If the go command's expected build ID does not match the compiled package's
build ID, the compiled package is out of date, even if the modification times suggest
otherwise (see [golang.org/cl/9154](https://golang.org/cl/9154)).

From Go 1.5 then, to arrange for a binary-only package,
it has been necessary to replace the source code after compiling
but keep the same set of file names and also keep the source
modification times older than the compiled package's.

In the future we may experiment with including the source code itself
in the hash that produces the build ID, which would completely
defeat any attempt at binary-only packages.

Fundamentally, as time goes on the go command gets better and better at detecting
mismatches between the source code and the compiled form,
yet in some cases it is explicitly desired that the source code not match
the compiled form (specifically, that the source code not be included at all).
If this usage is to keep working, it must be explicitly supported.

## Proposal

We propose to add official support for binary-only packages to the cmd/go toolchain,
by introduction of a new `//go:binary-only-package` comment.

The go/build package's type Package will contain a new field `IncompleteSources bool`  indicating
whether the `//go:binary-only-package` comment is present.

The go command will refuse to recompile a package containing the comment.
If a suitable binary form of the package is already installed, the go command will use it.
Otherwise the go command will report that the binary form is missing and cannot be built.

Users must install the package binary into the correct location in the $GOPATH/pkg tree
themselves. Distributors of binary-only packages might distribute
them as .zip files to be unpacked in the root of a $GOPATH, including files in both the src/ and pkg/
tree.

The “go get” command will still require complete source code and will not
recognize or otherwise enable the distribution of binary-only packages. 

## Rationale

Various users have reported working with companies that want to provide them with
binary but not source forms of purchased packages. 
We want to define an explicit way to do that instead of fielding bug reports
each time the go command gets smarter about detecting source-vs-binary mismatches.

The package source code itself must be present in some form,
or else we can't tell if the package was deleted entirely (see background above).
The implication is that it will simply not be the actual source code for the package.
A special comment is a natural way to signal this situation,
especially since the go command is already reading the source code
for package name, import information, and build tag comments.
Having a “fake” version of the source code also provides a way to supply
documentation compatible with “go doc” and “godoc”
even though the complete source code is missing.

The compiled form of the package does contain information about the source code,
for example source file names, type definitions for data structures used in the 
public API, and inlined function bodies. It is assumed that the distributors of
binary-only packages understand that they include this information.

## Compatibility

There are no problems raised by the 
[compatibility guidelines](https://golang.org/doc/go1compat).
If anything, the explicit support will help keep such binary-only packages
working better than they have in the past.

To the extent that tools process source code and not compiled packages,
those tools will not work with binary-only packages.
The compiler and linker will continue to enforce that all packages be compiled
with the same version of the toolchain: a binary-only package built with Go 1.4
will not work with Go 1.5.
Authors and users of binary-only packages must live with these implications.

## Implementation

The implementation is essentially as described in the proposal section above.

One additional detail is that the go command must load the build ID for the package
in question from the compiled binary form directly, instead of deriving it from the
source files.

I will implement this change for Go 1.7.
