# Go command support for embedded static assets (files) — Draft Design

Russ Cox\
Brad Fitzpatrick\
July 2020

This is a **Draft Design**, not a formal Go proposal,
because it describes a potential
[large change](https://research.swtch.com/proposals-large#checklist)
that addresses the same need as many third-party packages
and could affect their implementations (hopefully by simplifying them!).
The goal of circulating this draft design is to collect feedback
to shape an intended eventual proposal.

This design builds upon the [file system interfaces draft design](https://golang.org/s/draft-iofs-design).

We are using this change to experiment with new ways to
[scale discussions](https://research.swtch.com/proposals-discuss)
about large changes.
For this change, we will use
[a Go Reddit thread](https://golang.org/s/draft-embed-reddit)
to manage Q&A, since Reddit’s threading support
can easily match questions with answers
and keep separate lines of discussion separate.

There is a [video presentation](https://golang.org/s/draft-embed-video) of this draft design.

The [prototype code](https://golang.org/s/draft-embed-code) is available for trying out.

## Abstract

There are many tools to embed static assets (files) into Go binaries.
All depend on a manual generation step followed by checking in the
generated files to the source code repository.
This draft design eliminates both of these steps by adding support
for embedded static assets to the `go` command itself.

## Background

There are many tools to embed static assets (files) into Go binaries.
One of the earliest and most popular was
[github.com/jteeuwen/go-bindata](https://pkg.go.dev/github.com/jteeuwen/go-bindata)
and its forks, but there are many more, including (but not limited to!):

- [github.com/alecthomas/gobundle](https://pkg.go.dev/github.com/alecthomas/gobundle)
- [github.com/GeertJohan/go.rice](https://pkg.go.dev/github.com/GeertJohan/go.rice)
- [github.com/go-playground/statics](https://pkg.go.dev/github.com/go-playground/statics)
- [github.com/gobuffalo/packr](https://pkg.go.dev/github.com/gobuffalo/packr)
- [github.com/knadh/stuffbin](https://pkg.go.dev/github.com/knadh/stuffbin)
- [github.com/mjibson/esc](https://pkg.go.dev/github.com/mjibson/esc)
- [github.com/omeid/go-resources](https://pkg.go.dev/github.com/omeid/go-resources)
- [github.com/phogolabs/parcello](https://pkg.go.dev/github.com/phogolabs/parcello)
- [github.com/pyros2097/go-embed](https://pkg.go.dev/github.com/pyros2097/go-embed)
- [github.com/rakyll/statik](https://pkg.go.dev/github.com/rakyll/statik)
- [github.com/shurcooL/vfsgen](https://pkg.go.dev/github.com/shurcooL/vfsgen)
- [github.com/UnnoTed/fileb0x](https://pkg.go.dev/github.com/UnnoTed/fileb0x)
- [github.com/wlbr/templify](https://pkg.go.dev/github.com/wlbr/templify)
- [perkeep.org/pkg/fileembed](https://pkg.go.dev/perkeep.org/pkg/fileembed)

Clearly there is a widespread need for this functionality.

The `go` command is the way Go developers build Go programs.
Adding direct support to the `go` command for the basic functionality
of embedding will eliminate the need for some of these tools and
at least simplify the implementation of others.

### Goals

It is an explicit goal to eliminate the need to generate new
Go source files for the assets and commit those source files to version control.

Another explicit goal is to avoid a language change.
To us, embedding static assets seems like a tooling issue,
not a language issue.
Avoiding a language change also means we avoid the need
to update the many tools that process Go code, among them
goimports, gopls, and staticcheck.

It is important to note that as a matter of both design and policy,
the `go` command _never runs user-specified code during a build_.
This improves the reproducibility, scalability, and security of builds.
This is also the reason that `go generate` is a separate manual step
rather than an automatic one.
Any new `go` command support for embedded static assets
is constrained by that design and policy choice.

Another goal is that the solution apply equally well
to the main package and to its dependencies, recursively.
For example, it would not work to require the developer to list
all embeddings on the `go build` command line,
because that would require knowing the embeddings needed by all
of the dependencies of the program being built.

Another goal is to avoid designing novel APIs for accessing files.
The API for accessing embedded files should be as close as possible
to `*os.File,` the existing standard library API for accessing native operating-system files.

## Design

This design adds direct support for embedded static assets into the go command itself,
building on the file system draft design.

That support consists of:

 - A new `//go:embed` comment directive naming the files to embed.
 - A new `embed` package, which defines the type `embed.Files`,
   the public API for a set of embedded files.
   The `embed.Files` implements `fs.FS` from the
   [file system interfaces draft design](https://golang.org/s/draft-iofs-design),
   making it directly usable with packages
   like `net/http` and `html/template`.
 - Go command changes to process the directives.
 - Changes to `go/build` and `golang.org/x/tools/go/packages` to expose
   information about embedded files.

### //go:embed directives

A new package `embed`, described in detail below,
provides the type `embed.Files`.
One or more `//go:embed` directives
above a variable declaration of that type specify which files to embed,
in the form of a glob pattern.
For example:

	package server

	// content holds our static web server content.
	//go:embed image/* template/*
	//go:embed html/index.html
	var content embed.Files

The `go` command will recognize the directives and
arrange for the declared `embed.Files` variable (in this case, `content`)
to be populated with the matching files from the file system.

The `//go:embed` directive accepts multiple space-separated
glob patterns for brevity, but it can also be repeated,
to avoid very long lines when there are many patterns.
The glob patterns are in the syntax of `path.Match`;
they must be unrooted, and they are interpreted
relative to the package directory containing the source file.
The path separator is a forward slash, even on Windows systems.
To allow for naming files with spaces in their names,
patterns can be written as Go double-quoted or back-quoted string literals.

If a pattern names a directory, all files in the subtree rooted
at that directory are embedded (recursively),
so the above example is equivalent to:

	package server

	// content is our static web server content.
	//go:embed image template html/index.html
	var content embed.Files

An `embed.Files` variable can be exported or unexported,
depending on whether the package wants to make the file set
available to other packages.
Similarly, an `embed.Files` variable can be a global or a local variable,
depending on what is more convenient in context.

 - When evaluating patterns, matches for empty directories are ignored
   (because empty directories are never packaged into a module).
 - It is an error for a pattern not to match any file or non-empty directory.
 - It is _not_ an error to repeat a pattern or for multiple patterns to match
   a particular file; such a file will only be embedded once.
 - It is an error for a pattern to contain a `..` path element.
 - It is an error for a pattern to contain a `.` path element
    (to match everything in the current directory, use `*`).
 - It is an error for a pattern to match files outside the current module
   or that cannot be packaged into a module, like `.git/*` or symbolic links
   (or, as noted above, empty directories).
 - It is an error for a `//go:embed` directive to appear except
   before a declaration of an `embed.Files`.
   (More specifically, each `//go:embed` directive must be followed by
   a `var` declaration of a variable of type `embed.Files`, with only blank lines
   and other `//`-comment-only lines between the `//go:embed` and the declaration.)
 - It is an error to use `//go:embed` in a source file that does not import
   `"embed"`
   (the only way to violate this rule involves type alias trickery).
 - It is an error to use `//go:embed` in a module declaring a Go version
   before Go 1._N_, where _N_ is the Go version that adds this support.
 - It is _not_ an error to use `//go:embed` with local variables declared in functions.
 - It is _not_ an error to use `//go:embed` in tests.
 - It is _not_ an error to declare an `embed.Files` without a `//go:embed` directive.
   That variable simply contains no embedded files.

### The embed package

The new package `embed` defines the `Files` type:

	// A Files provides access to a set of files embedded in a package at build time.
	type Files struct { … }

The `Files` type provides an `Open` method that opens an embedded file, as an `fs.File`:

	func (f Files) Open(name string) (fs.File, error)

By providing this method, the `Files` type implements `fs.FS` and can be used with utility functions
such as `fs.ReadFile`, `fs.ReadDir`, `fs.Glob`, and `fs.Walk`.

As a convenience for the most common operation on embedded files, the `Files` type also provides a `ReadFile` method:

	func (f Files) ReadFile(name string) ([]byte, error)

Because `Files` implements `fs.FS`, a set of embedded files can also
be passed to `template.ParseFS`, to parse embedded templates,
and to `http.HandlerFS`, to serve a set of embedded files over HTTP.

### Go command changes

The `go` command will change to process `//go:embed` directives
and pass appropriate information to the compiler and linker
to carry out the embedding.

The `go` command will also add six new fields to the `Package` struct
exposed by `go list`:

	EmbedPatterns      []string
	EmbedFiles         []string
	TestEmbedPatterns  []string
	TestEmbedFiles     []string
	XTestEmbedPatterns []string
	XTestEmbedFiles    []string

The `EmbedPatterns` field lists all the patterns found on `//go:embed` lines
in the package’s non-test source files; `TestEmbedPatterns` and `XTestEmbedPatterns`
list the patterns in the package’s test source files (internal and external tests, respectively).

The `EmbedFiles` field lists all the files, relative to the package directory,
matched by the `EmbedPatterns`; it does not specify which files match which pattern,
although that could be reconstructed using `path.Match`.
Similarly, `TestEmbedFiles` and `XTestEmbedFiles` list the files matched by `TestEmbedPatterns` and `XTestEmbedPatterns`.
These file lists contain only files; if a pattern matches a directory, the file list
includes all the files found in that directory subtree.

### go/build and golang.org/x/tools/go/packages

In the `go/build` package, the `Package` struct adds only
`EmbedPatterns`, `TestEmbedPatterns`, and `XTestEmbedPatterns`,
not `EmbedFiles`, `TestEmbedFiles`, or `XTestEmbedFiles`,
beacuse the `go/build` package does not take on the job of
matching patterns against a file system.

In the `golang.org/x/tools/go/packages` package,
the `Package` struct adds one new field:
`EmbedFiles` lists the embedded files.
(If embedded files were added to `OtherFiles`,
it would not be possible to tell whether a file with a valid
source extension in that list—for example, `x.c`—was
being built or embedded or both.)

## Rationale

As noted above, the Go ecosystem has many tools for embedding static assets,
too many for a direct comparison to each one.
Instead, this section lays out the affirmative rationale in favor of each of the
parts of the design.
Each subsection also addresses the points raised in the helpful preliminary discussion on
golang.org/issue/35950.
(The Appendix at the end of this document makes direct comparisons with a few existing tools
and examines how they might be simplified.)

It is worth repeating the goals and constraints mentioned in the background section:

- No generated Go source files.
- No language change, so no changes to tools processing Go code.
- The `go` command does not run user code during `go build`.
- The solution must apply as well to dependency packages as it does to the main package.
- The APIs for accessing embedded files should be close to those for operating-system files.

### Approach

The core of the design is the new `embed.Files` type
annotated at its use with the new `//go:embed` directive:

	//go:embed *.jpg
	var jpgs embed.Files

This is different from the two approaches mentioned
at the start of the preliminary discussion on golang.org/issue/35950.
In some ways it is a combination of the best parts of each.

The first approach mentioned was a directive along the lines of

	//go:genembed Logo logo.jpg

that would be replaced by a generated `func Logo() []byte` function,
or some similar accessor.

A significant drawback of this approach is that it changes the way
programs are type-checked: you can’t type-check a call to `Logo`
unless you know what that directive turns into.
There is also no obvious place to write the documentation
for the new `Logo` function.
In effect, this new directive ends up being a full language change:
all tools processing Go code have to be updated to understand it.

The second approach mentioned was to have a new importable `embed`
package with standard Go function definitions,
but the functions are in effect executed at compile time, as in:

	var Static = embed.Dir("static")
	var Logo = embed.File("images/logo.jpg")
	var Words = embed.CompressedReader("dict/words")

This approach fixes the type-checking problem—it is not a full
language change—but it still has significant implementation complexity.
The `go` command would need to parse the entire Go source file
to understand which files need to be made available for embedding.
Today it only parses up to the import block, never full Go expressions.
It would also be unclear to users what constraints are placed on the
arguments to these special calls: they look like ordinary Go calls
but they can only take string literals, not strings computed by Go code,
and probably not even named constants (or else the `go` command
would need a full Go expression evaluator).

Much of the preliminary discussion focused on
deciding between these two approaches.
This design combines the two and avoids the drawbacks of each.

The `//go:embed` comment directive follows the established convention
for Go build system and compiler directives.
The directive is easy for the `go` command to find,
and it is clear immediately that the directive can’t refer to
a string computed by a function call, nor to a named constant.

The `embed.Files` type is plain Go code,
defined in a plain Go package `embed`.
All tools that type-check Go code or run other analysis on it
can understand the code without any special handling of the `//go:embed` directive.

The explicit variable declaration provides a clear place
to write documentation:

	// jpgs holds the static images used on the home page.
	//go:embed *.jpg
	var jpgs embed.Files

(As of Go 1.15, the `//go:embed` line is not considered part of the doc comment.)

The explicit variable declaration also provides a clear way to
control whether the `embed.Files` is exported.
A data-only package might do nothing but export embedded files, like:

	package web

	// Styles holds the CSS files shared among all our websites.
	//go:embed style/*.css
	var Styles embed.Files

#### Modules versus packages

In the preliminary discussion, a few people suggested specifying embedded files
using a new directive in `go.mod`.

The design of Go modules, however, is that `go.mod` serves only to describe
information about the module’s version requirements,
not other details of a particular package.
It is not a collection of general-purpose metadata.
For example, compiler flags or build tags would be inappropriate
in `go.mod`.
For the same reason, information about one package’s embedded files
is also inappropriate in `go.mod`:
each package’s individual meaning should be defined by its Go sources.
The `go.mod` is only for deciding which versions of other packages
are used to resolve imports.

Placing the embedding information in the package has benefits
that using `go.mod` would not, including the explicit declaration of
the file set, control over exportedness, and so on.

#### Glob patterns

It is clear that there needs to be some way to give a pattern of files to include,
such as `*.jpg`.
This design adopts glob patterns as the single way to name files for inclusion.
Glob patterns are common to developers from command shells,
and they are already well-defined in Go, in the APIs for `path.Match`, `filepath.Match`,
and `filepath.Glob`.
Nearly all file names are valid glob patterns matching only themselves;
using globs avoids the need for separate `//go:embedfile` and `//go:embedglob`
directives.
(This would not be the case if we used, say, Go regular expressions
as provided by the `regexp` package.)

#### Directories versus \*\* glob patterns

In some systems, the glob pattern `**` is like `*` but can match multiple path elements.
For example `images/**.jpg` matches all `.jpg` files in the directory tree rooted at `images/`.
This syntax is not available in Go’s `path.Match` or in `filepath.Glob`,
and it seems better to use the available syntax than to define a new one.
The rule that matching a directory includes all files in that directory tree
should address most of the need for `**` patterns.
For example, `//go:embed images` instead of `//go:embed images/**.jpg`.
It’s not exactly the same, but hopefully good enough.

If at some point in the future it becomes clear that `**` glob patterns
are needed, the right way to support them would be to add them to
`path.Match` and `filepath.Glob`; then the `//go:embed` directives
would get them for free.

#### Dot-dot, module boundaries, and file name restrictions

In order to build files embedded in a dependency,
the raw files themselves must be included in module zip files.
This implies that any embedded file must be in the module’s own file tree.
It cannot be in a parent directory above the module root (like `../../../etc/passwd`),
it cannot be in a subdirectory that contains a different module,
and it cannot be in a directory that would be left out of the module (like `.git`).
Another implication is that it is not possible to embed two different
files that differ only in the case of their file names,
because those files would not be possible to extract on a
case-insensitive system like Windows or macOS.
So you can’t embed two files with different casings, like this:

    //go:embed README readme`

But `//go:embed dir/README other/readme` is fine.

Because `embed.Files` implements `fs.FS`, it cannot provide access
to files with names beginning with `..`, so files in parent directories
are also disallowed entirely, even when the parent directory named by `..`
does happen to be in the same module.

#### Codecs and other processing

The preliminary discussion raised a large number of possible transformations
that might be applied to files before embedding,
including:
data compression,
JavaScript minification,
TypeScript compilation,
image resizing,
generation of sprite maps,
UTF-8 normalization,
and
CR/LF normalization.

It is not feasible for the `go` command to anticipate or include
all the possible transformations that might be desirable.
The `go` command is also not a general build system;
in particular, remember the design constraint that it never
runs user programs during a build.
These kinds of transformations are best left to an external
build system, such as Make or Bazel,
which can write out the exact bytes that the `go` command
should embed.

A more limited version of this suggestion was to gzip-compress
the embedded data and then make that compressed form available
for direct use in HTTP servers as gzipped response content.
Doing this would force the use of (or at least support for)
gzip and compressed content, making it harder to adjust the
implementation in the future as we learn more about how well it works.
Overall this seems like overfitting to a specific use case.

The simplest approach is for Go’s embedding feature to store
plain files, let build systems or third-party packages take care of preprocessing before the build
or postprocessing at runtime.
That is, the design focuses on providing the core functionality of
embedding raw bytes into the binary for use at run-time,
leaving other tools and packages to build on a solid foundation.

### Compression to reduce binary size

A popular question in the preliminary discussion was whether
the embedded data should be stored in compressed or
uncompressed form in the binary.
This design carefully avoids assuming an answer to that question.
Instead, whether to compress can be left as an implementation detail.

Compression carries the obvious benefit of smaller binaries.
However, it also carries some less obvious costs.
Most compression formats (in particular gzip and zip)
do not support random access to the uncompressed data,
but an `http.File` needs random access (`ReadAt`, `Seek`)
to implement range requests.
Other uses may need random access as well.
For this reason, many of the popular embedding tools
start by decompressing the embedded data at runtime.
This imposes a startup CPU cost and a memory cost.
In contrast, storing the embedded data uncompressed
in the binary supports random access with no startup CPU cost.
It also reduces memory cost:
the file contents are never stored in the garbage-collected heap,
and the operating system efficiently pages in necessary data
from the executable as that data is accessed,
instead of needing to load it all at once.

Most systems have more disk than RAM.
On those systems, it makes very little sense to
make binaries smaller at the cost of using more memory (and more CPU) at run time.

On the other hand, projects like [TinyGo](https://tinygo.org/) and [U-root](https://u-root.org/)
target systems with more RAM than disk or flash.
For those projects, compressing assets and using
incremental decompression at runtime could provide
significant savings.

Again, this design allows compression to be left as an
implementation detail.
The detail is not decided by each package author
but instead could be decided when building the final binary.
Future work might be to add `-embed=compress`
as a `go` build option for use in limited environments.

### Go command changes

Other than support for `//go:embed` itself,
the only user-visible `go` command change
is new fields exposed in `go list` output.

It is important for tools that process Go packages to be able
to understand what files are needed for a build.
The `go list` command is the underlying mechanism
used now, even by `golang.org/x/tools/go/packages`.
Exposing the embedded files as a new field in `Package` struct
used by `go list`
makes them available both for direct use and
for use by higher level APIs.

#### Command-line configuration

In the preliminary discussion, a few people suggested that
the list of embedded files could be specified on the `go build`
command line.
This could potentially work for files embedded in the main package,
perhaps with an appropriate Makefile.
But it would fail badly for dependencies:
if a dependency wanted to add a new embedded file,
all programs built with that dependency would need
to adjust their build command lines.

#### Potential confusion with go:generate

In the preliminary discussion, a few people pointed out that
developers might be confused by the inconsistency that `//go:embed` directives
are processed during builds but `//go:generate` directives are not.

There are other special comment directives as well: `//go:noinline`, `//go:noescape`, `// +build`, `//line`.
All of these are processed during builds.
The exception is `//go:generate`,
because of the design constraint that the `go` command
not run user code during builds.
The `//go:embed` is not the special case, nor does it make
`//go:generate` any more of a special case.

For more about `go generate`,
see the [original proposal](https://docs.google.com/document/d/1V03LUfjSADDooDMhe-_K59EgpTEm3V8uvQRuNMAEnjg/edit)
and [discussion](https://groups.google.com/g/golang-dev/c/ZTD1qtpruA8).

### The embed package

#### Import path

The new `embed` package provides access to embedded files.
Previous additions to the standard library
have been made in `golang.org/x` first, to make them
available to earlier versions of Go.
However, it would not make sense to use `golang.org/x/embed`
instead of `embed`:
the older versions of Go could import `golang.org/x/embed`
but still not be able to embed files without the newer `go` command support.
It is clearer for a program using `embed` to fail to compile
than it would be to compile but not embed any files.

#### File API

Implementing `fs.FS` enables hooking into `net/http`, `text/template`, and `html/template`,
without needing to make those packages aware of `embed`.

Code that wants to change between using operating system files and
embedded files can be written in terms of `fs.FS` and `fs.File`
and then use `os.DirFS` as an `fs.FS` or use a `*os.File` directly as an `fs.File`.

#### Direct access to embedded data

An obvious extension would be to add to `embed.Files`
a `ReadFileString` method that returns the file content as a string.
If the embedded data were stored in the binary uncompressed,
`ReadFileString` would be very efficient: it could return a string
pointing into the in-binary copy of the data.
Callers expecting zero allocation in `ReadFileString`
might well preclude a future `-embed=compress` mode that
trades binary size for access time, which could not provide
the same kind of efficient direct access to raw uncompressed data.
An explicit `ReadFileString` method would also make it more
difficult to convert code using `embed.Files` to use other `fs.FS`
implementations, including operating system files.
For now, it seems best to omit a `ReadFileString` method,
to avoid exposing the underlying representation
and also to avoid diverging from `fs.FS`.

Another extension would be to add to the returned `fs.File` a `WriteTo` method.
All the arguments against `ReadFileString` apply equally well to `WriteTo`.
An additional reason to avoid `WriteTo` is that it would expose the
uncompressed data in a mutable form, `[]byte` instead of `string`.

The price of this flexibility—both the flexibility to
move easily between `embed.Files` and other file systems
and also the flexibility to add `-embed=compress` later
(perhaps that would useful for TinyGo)—is that access to data requires making a copy.
This is at least no less efficient than reading from other file sources.

#### Writing embedded files to disk

In the preliminary discussion, one person asked about making it
easy to write embedded files back to disk at runtime, to make
them available for use with the HTTP server, template parsing, and so on.
While this is certainly possible to do,
we probably should avoid that as the suggested way to use
embedded files:
many programs run with limited or no access to writable disk.
Instead, this design builds on the [file system draft design](https://golang.org/s/draft-iofs-design)
to make the embedded files available to those APIs.

## Compatibility

This is all new API.
There are no conflicts with the [compatibility guidelines](https://golang.org/doc/go1compat).

It is worth noting that, as with all new API, this functionality cannot be adopted
by a Go project until all developers building the project have updated to the
version of Go that supports the API.
This may be a particularly important concern for authors of libraries.
If this functionality ships in Go 1.15, library authors may wish to wait
to adopt it until they are confident that all their users have updated to
Go 1.15.

## Implementation

The implementation details are not user-visible
and do not matter nearly as much as the rest of the design.

A [prototype implementation](https://golang.org/s/draft-iofs-code) is available.

## Appendix: Comparison with other tools

A goal of this design is to eliminate much of the effort involved
in embedding static assets in Go binaries.
It should be able to replace the common uses of most of
the available embedding tools.
Replacing all possible uses is a non-goal.
Replacing all possible embedding tools is also a non-goal.

This section examines a few popular embedding tools
and compares and contrasts them with this design.

### go-bindata

One of the earliest and simplest generators for static assets is
[`github.com/jteeuwen/go-bindata`](https://pkg.go.dev/github.com/jteeuwen/go-bindata?tab=doc).
It is no longer maintained, so now there are many forks and derivatives,
but this section examines the original.

Given an input file `hello.txt` containing the single line `hello, world`,
`go-bindata hello.txt` produces 235 lines of Go code.
The generated code exposes this exported API (in the package where it is run):

```
func Asset(name string) ([]byte, error)
    Asset loads and returns the asset for the given name. It returns an error if
    the asset could not be found or could not be loaded.

func AssetDir(name string) ([]string, error)
    AssetDir returns the file names below a certain directory embedded in the
    file by go-bindata. For example if you run go-bindata on data/... and data
    contains the following hierarchy:

        data/
          foo.txt
          img/
            a.png
            b.png

    then AssetDir("data") would return []string{"foo.txt", "img"}
    AssetDir("data/img") would return []string{"a.png", "b.png"}
    AssetDir("foo.txt") and AssetDir("notexist") would return an error
    AssetDir("") will return []string{"data"}.

func AssetInfo(name string) (os.FileInfo, error)
    AssetInfo loads and returns the asset info for the given name. It returns an
    error if the asset could not be found or could not be loaded.

func AssetNames() []string
    AssetNames returns the names of the assets.

func MustAsset(name string) []byte
    MustAsset is like Asset but panics when Asset would return an error. It
    simplifies safe initialization of global variables.

func RestoreAsset(dir, name string) error
    RestoreAsset restores an asset under the given directory

func RestoreAssets(dir, name string) error
    RestoreAssets restores an asset under the given directory recursively
```

This code and exported API is duplicated in every package using `go-bindata`-generated output.
One benefit of this design is that the access code can be in a single package
shared by all clients.

The registered data is gzipped. It must be decompressed when accessed.

The `embed` API provides all this functionality
except for “restoring” assets back to the local file system.
See the “Writing embedded assets to disk” section above
for more discussion about why it makes sense to leave that out.

### statik

Another venerable asset generator is
[github.com/rakyll/statik](https://pkg.go.dev/github.com/rakyll/statik).
Given an input file `public/hello.txt` containing the single line `hello, world`,
running `statik` generates a subdirectory `statik` containing an
import-only package with a `func init` containing a single call,
to register the data for asset named `"hello.txt"` with
the access package [github.com/rakyll/statik/fs](https://pkg.go.dev/github.com/rakyll/statik).

The use of a single shared registration introduces the possibility
of naming conflicts: what if multiple packages want to embed
different static `hello.txt` assets?
Users can specify a namespace when running `statik`,
but the default is that all assets end up in the same namespace.

This design avoids collisions and explicit namespaces by keeping
each `embed.Files` separate: there is no global state
or registration.

The registered data in any given invocation is a string containing
the bytes of a single zip file holding all the static assets.

Other than registration calls, the `statik/fs` package includes this API:

```
func New() (http.FileSystem, error)
    New creates a new file system with the default registered zip contents data.
    It unzips all files and stores them in an in-memory map.

func NewWithNamespace(assetNamespace string) (http.FileSystem, error)
    NewWithNamespace creates a new file system with the registered zip contents
    data. It unzips all files and stores them in an in-memory map.

func ReadFile(hfs http.FileSystem, name string) ([]byte, error)
    ReadFile reads the contents of the file of hfs specified by name. Just as
    ioutil.ReadFile does.

func Walk(hfs http.FileSystem, root string, walkFn filepath.WalkFunc) error
    Walk walks the file tree rooted at root, calling walkFn for each file or
    directory in the tree, including root. All errors that arise visiting files
    and directories are filtered by walkFn.

    As with filepath.Walk, if the walkFn returns filepath.SkipDir, then the
    directory is skipped.
```

The `embed` API provides all this functionality
(converting to `http.FileSystem`, reading a file, and walking the files).

Note that accessing any single file requires first decompressing
all the embedded files. The decision in this design to avoid
compression is discussed more above, in the
“Compression to reduce binary size” section.

### go.rice

Another venerable asset generator is
[github.com/GeertJohan/go.rice](https://github.com/GeertJohan/go.rice).
It presents a concept called a `rice.Box`
which is like an `embed.Files` filled from a specific file system directory.
Suppose `box/hello.txt` contains `hello world` and `hello.go` is:

	package main

	import rice "github.com/GeertJohan/go.rice"

	func main() {
		rice.FindBox("box")
	}

The command `rice embed-go` generates a 44-line file `rice-box.go` that
calls `embedded.RegisterEmbeddedBox` to registers a box named `box` containing
the single file `hello.txt`.
The data is uncompressed.
The registration means that `go.rice` has the same possible
collisions as `statik`.

The `rice embed-go` command parses the Go source file `hello.go`
to find calls to `rice.FindBox` and then uses the argument as both
the name of the box and the local directory containing its contents.
This approach is similar to the “second approach” identified in the preliminary
discussion, and it demonstrates all the drawbacks suggested above.
In partitcular, only the first of these variants works with the `rice` command:

	rice.FindBox("box")

	rice.FindBox("b" + "o" + "x")

	const box = "box"
	rice.FindBox(box)

	func box() string { return "box" }
	rice.FindBox(box())

As the Go language is defined, these should all do the same thing.
The limitation to the first form is fine in an opt-in tool,
but it would be problematic to impose in the standard toolchain,
because it would break the orthogonality of language concepts.

The API provided by the `rice` package is:

```
type Box struct {
	// Has unexported fields.
}
    Box abstracts a directory for resources/files. It can either load files from
    disk, or from embedded code (when `rice --embed` was ran).

func FindBox(name string) (*Box, error)
    FindBox returns a Box instance for given name. When the given name is a
    relative path, it’s base path will be the calling pkg/cmd’s source root.
    When the given name is absolute, it’s absolute. derp. Make sure the path
    doesn’t contain any sensitive information as it might be placed into
    generated go source (embedded).

func MustFindBox(name string) *Box
    MustFindBox returns a Box instance for given name, like FindBox does. It
    does not return an error, instead it panics when an error occurs.

func (b *Box) Bytes(name string) ([]byte, error)
    Bytes returns the content of the file with given name as []byte.

func (b *Box) HTTPBox() *HTTPBox
    HTTPBox creates a new HTTPBox from an existing Box

func (b *Box) IsAppended() bool
    IsAppended indicates wether this box was appended to the application

func (b *Box) IsEmbedded() bool
    IsEmbedded indicates wether this box was embedded into the application

func (b *Box) MustBytes(name string) []byte
    MustBytes returns the content of the file with given name as []byte. panic’s
    on error.

func (b *Box) MustString(name string) string
    MustString returns the content of the file with given name as string.
    panic’s on error.

func (b *Box) Name() string
    Name returns the name of the box

func (b *Box) Open(name string) (*File, error)
    Open opens a File from the box If there is an error, it will be of type
    *os.PathError.

func (b *Box) String(name string) (string, error)
    String returns the content of the file with given name as string.

func (b *Box) Time() time.Time
    Time returns how actual the box is. When the box is embedded, it’s value is
    saved in the embedding code. When the box is live, this methods returns
    time.Now()

func (b *Box) Walk(path string, walkFn filepath.WalkFunc) error
    Walk is like filepath.Walk() Visit http://golang.org/pkg/path/filepath/#Walk
    for more information
```

```
type File struct {
	// Has unexported fields.
}
    File implements the io.Reader, io.Seeker, io.Closer and http.File interfaces

func (f *File) Close() error
    Close is like (*os.File).Close() Visit http://golang.org/pkg/os/#File.Close
    for more information

func (f *File) Read(bts []byte) (int, error)
    Read is like (*os.File).Read() Visit http://golang.org/pkg/os/#File.Read for
    more information

func (f *File) Readdir(count int) ([]os.FileInfo, error)
    Readdir is like (*os.File).Readdir() Visit
    http://golang.org/pkg/os/#File.Readdir for more information

func (f *File) Readdirnames(count int) ([]string, error)
    Readdirnames is like (*os.File).Readdirnames() Visit
    http://golang.org/pkg/os/#File.Readdirnames for more information

func (f *File) Seek(offset int64, whence int) (int64, error)
    Seek is like (*os.File).Seek() Visit http://golang.org/pkg/os/#File.Seek for
    more information

func (f *File) Stat() (os.FileInfo, error)
    Stat is like (*os.File).Stat() Visit http://golang.org/pkg/os/#File.Stat for
    more information
```

```
type HTTPBox struct {
	*Box
}
    HTTPBox implements http.FileSystem which allows the use of Box with a
    http.FileServer.

        e.g.: http.Handle("/", http.FileServer(rice.MustFindBox("http-files").HTTPBox()))

func (hb *HTTPBox) Open(name string) (http.File, error)
    Open returns a File using the http.File interface
```

As far as public API, `go.rice` is very similar to this design.
The `Box` itself is like `embed.Files`,
and
the `File` is similar to `fs.File`.
This design avoids `HTTPBox` by building on HTTP support for `fs.FS`.

### Bazel

The Bazel build tool includes support for building Go,
and its [`go_embed_data`](https://github.com/bazelbuild/rules_go/blob/master/go/extras.rst#go-embed-data) rule supports embedding a file as data in a Go program.
It is used like:

	go_embed_data(
		name = "rule_name",
		package = "main",
		var = "hello",
		src = "hello.txt",
	)

or

	go_embed_data(
		name = "rule_name",
		package = "main",
		var = "files",
		srcs = [
			"hello.txt",
			"gopher.txt",
		],
	)

The first form generates a file like:

	package main

	var hello = []byte("hello, world\n")

The second form generates a file like:

	package main

	var files = map[string][]byte{
		"hello.txt": []byte("hello, world\n"),
		"gopher.txt": []byte("ʕ◔ϖ◔ʔ\n"),
	}

That’s all. There are configuration knobs to generate `string` instead of `[]byte`,
and to expand zip and tar files into their contents,
but there’s no richer API: just declared data.

Code using this form would likely keep using it: the `embed` API is more complex.

However, it will still be important to support this `//go:embed` design in Bazel.
The way to do that would be to provide a `go tool embed` that generates the
right code and then either adjust the Bazel `go_library` rule to invoke it
or have Gazelle (the tool that reads Go files and generates Bazel rules)
generate appropriate `genrules`.
The details would depend on the eventual Go implementation,
but any Go implementation of `//go:embed` needs to be able to be implemented
in Bazel/Gazelle in some way.
