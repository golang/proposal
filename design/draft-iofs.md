# File System Interfaces for Go — Draft Design

Russ Cox\
Rob Pike\
July 2020

This is a **Draft Design**, not a formal Go proposal,
because it describes a potential
[large change](https://research.swtch.com/proposals-large#checklist),
with integration changes needed in multiple packages in the standard library
as well potentially in third-party packages.
The goal of circulating this draft design is to collect feedback
to shape an intended eventual proposal.

We are using this change to experiment with new ways to
[scale discussions](https://research.swtch.com/proposals-discuss)
about large changes.
For this change, we will use
[a Go Reddit thread](https://golang.org/s/draft-iofs-reddit)
to manage Q&A, since Reddit's threading support
can easily match questions with answers
and keep separate lines of discussion separate.

There is a [video presentation](https://golang.org/s/draft-iofs-video) of this draft design.

The [prototype code](https://golang.org/s/draft-iofs-code) is available for trying out.

See also the related [embedded files draft design](https://golang.org/s/draft-embed-design), which builds on this design.

## Abstract

We present a possible design for a new Go standard library package `io/fs`
that defines an interface for read-only file trees.
We also present changes to integrate the new package into the standard library.

This package is motivated in part by wanting to add support for
embedded files to the `go` command.
See the [draft design for embedded files](https://golang.org/s/draft-embed-design).

## Background

A hierarchical tree of named files serves as a convenient, useful abstraction
for a wide variety of resources, as demonstrated by Unix, Plan 9, and the HTTP REST idiom.
Even when limited to abstracting disk blocks, file trees come in many forms:
local operating-system files, files stored on other computers,
files in memory, files in other files like ZIP archives.

Go benefits from good abstractions for the data in a single file, such as the
`io.Reader`, `io.Writer`, and related interfaces.
These have been widely implemented and used in the Go ecosystem.
A particular `Reader` or `Writer` might be an operating system file,
a network connection, an in-memory buffer,
a file in a ZIP archive, an HTTP response body,
a file stored on a cloud server, or many other things.
The common, agreed-upon interfaces enable the
creation of useful, general operations like
compression, encryption, hashing, merging, splitting,
and duplication that apply to all these different resources.

Go would also benefit from a good abstraction for a file system tree.
Common, agreed-upon interfaces would help connect the many different
resources that might be presented as file systems
with the many useful generic operations that could be
implemented atop the abstraction.

We started exploring the idea of a file system abstraction years ago,
with an [internal abstraction used in godoc](https://golang.org/cl/4572065).
That code was later extracted as
[golang.org/x/tools/godoc/vfs](https://pkg.go.dev/golang.org/x/tools/godoc/vfs?tab=doc)
and inspired a handful of similar packages.
That interface and its successors seemed too complex to be the
right common abstraction, but they helped us learn more about
what a design might look like.
In the intervening years we've also learned more about
how to use interfaces to model more complex resources.

There have been past discussions about file system interfaces
on [issue 5636](https://golang.org/issue/5636) and [issue 14106](https://golang.org/issue/14106).

This draft design presents a possible official abstraction for a file system tree.

## Design

The core of this design is a new package `io/fs` defining a file system abstraction.
Although the initial interface is limited to read-only file systems,
the design can be extended to support write operations later,
even from third-party packages.

This design also contemplates minor adjustments to the
`archive/zip`,
`html/template`,
`net/http`,
`os`,
and
`text/template`
packages to better implement or consume the file system abstractions.

### The FS interface

The new package `io/fs` defines an `FS` type representing a file system:

	type FS interface {
		Open(name string) (File, error)
	}

The `FS` interface defines the _minimum_ requirement for an implementation:
just an `Open` method.
As we will see, an `FS` implementation may also provide other
methods to optimize operations or add new functionality,
but only `Open` is required.

(Because the package name is `fs`, we need to establish a different
typical variable name for a generic file system.
The prototype code uses `fsys`, as do the examples in this draft design.
The need for such a generic name only arises in code manipulating arbitrary file systems;
most client code will use a meaningful name based on what the file system
contains, such as  `styles` for a file system containing CSS files.)

### File name syntax

All `FS` implementations use the same name syntax:
paths are unrooted, slash-separated sequences of path elements,
like Unix paths without the leading slash,
or like URLs without the leading `http://host/`.
Also like in URLs, the separator is a forward slash on all systems, even Windows.
These names can be manipulated using the `path` package.
`FS` path names never contain a ‘`.`’ or ‘`..`’ element except for the
special case that the root directory of a given `FS` file tree is named ‘`.`’.
Paths may be case-sensitive or not, depending on the implementation, so
clients should typically not depend on one behavior or the other.

The use of unrooted names—`x/y/z.jpg` instead of `/x/y/z.jpg`—is
meant to make clear that the name is only meaningful when
interpreted relative to a particular file system root, which is not specified
in the name.
Put another way, the lack of a leading slash makes clear these are
not host file system paths, nor identifiers in some other global name space.


### The File interface

The `io/fs` package also defines a `File` interface representing an open file:

	type File interface {
		Stat() (os.FileInfo, error)
		Read([]byte) (int, error)
		Close() error
	}

The `File` interface defines the _minimum_ requirements for an implementation.
For `File`, those requirements are
`Stat`, `Read`, and `Close`, with the same meanings as for an `*os.File`.
A `File` implementation may also provide other methods to optimize operations
or add new functionality—for example, an `*os.File` is a valid `File` implementation—but
only these three are required.

If a `File` represents a directory, then just like an `*os.File`,
the `FileInfo` returned by `Stat` will return `true` from `IsDir()` (and from `Mode().IsDir()`).
In this case, the `File` must also implement the `ReadDirFile` interface,
which adds a `ReadDir` method.
The `ReadDir` method has the same semantics as the `*os.File` `Readdir` method,
and (later) this design adds `ReadDir` with a capital D to `*os.File`.)

	// A ReadDirFile is a File that implements the ReadDir method for directory reading.
	type ReadDirFile interface {
		File
		ReadDir(n int) ([]os.FileInfo, error)
	}

### Extension interfaces and the extension pattern

This `ReadDirFile` interface is an example of an old Go pattern
that we’ve never named before but that we suggest calling
an _extension interface_.
An extension interface embeds a base interface and adds one or more extra methods,
as a way of specifying optional functionality that may be
provided by an instance of the base interface.

An extension interface is named by prefixing the base interface name
with the new method: a `File` with `ReadDir` is a `ReadDirFile`.
Note that this convention can be viewed as a generalization of existing names
like `io.ReadWriter` and `io.ReadWriteCloser`.
That is, an `io.ReadWriter` is an `io.Writer` that also has a `Read` method,
just like a `ReadDirFile` is a `File` that also has a `ReadDir` method.

The `io/fs` package does not define extensions like `ReadAtFile`, `ReadSeekFile`, and so on,
to avoid duplication with the `io` package.
Clients are expected to use the `io` interfaces directly for such operations.

An extension interface can provide access to new functionality not available in a base interface,
or an extension interface can also provide access to a more efficient implementation
of functionality already available, using additional method calls, using the base interface.
Either way, it can be helpful to pair an extension interface with a helper function
that uses the optimized implementation if available and
falls back to what is possible in the base interface otherwise.

An early example of this _extension pattern_—an extension interface paired with a helper
function—is the `io.StringWriter` interface and the `io.WriteString` helper function,
which have been present since Go 1:

	package io

	// StringWriter is the interface that wraps the WriteString method.
	type StringWriter interface {
		WriteString(s string) (n int, err error)
	}

	// WriteString writes the contents of the string s to w, which accepts a slice of bytes.
	// If w implements StringWriter, its WriteString method is invoked directly.
	// Otherwise, w.Write is called exactly once.
	func WriteString(w Writer, s string) (n int, err error) {
		if sw, ok := w.(StringWriter); ok {
			return sw.WriteString(s)
		}
		return w.Write([]byte(s))
	}

This example deviates from the discussion above in that `StringWriter` is not quite an extension interface:
it does not embed `io.Writer`.
For a single-method interface where the extension method replaces
the original one, not repeating the original method can make sense, as here.
But in general we do embed the original interface, so that code that
tests for the new interface can access the original and new methods using
a single variable.
(In this case, `StringWriter` not embedding `io.Writer` means that `WriteString` cannot call `sw.Write`.
That's fine in this case, but consider instead if `io.ReadSeeker` did not exist:
code would have to test for `io.Seeker` and use separate variables for the `Read` and `Seek` operations.)

### Extensions to FS

`File` had just one extension interface,
in part to avoid duplication with the existing interfaces in `io`.
But `FS` has a handful.

#### ReadFile

One common operation is reading an entire file,
as `ioutil.ReadFile` does for operating system files.
The `io/fs` package provides this functionality using the extension pattern,
defining a `ReadFile` helper function supported by
an optional `ReadFileFS` interface:

	func ReadFile(fsys FS, name string) ([]byte, error)

The general implementation of `ReadFile` can call `fs.Open` to obtain a `file` of type `File`,
followed by calls to `file.Read` and a final call to `file.Close`.
But if an `FS` implementation can provide file contents
more efficiently in a single call, it can implement the
`ReadFileFS` interface:

	type ReadFileFS interface {
		FS
		ReadFile(name string) ([]byte, error)
	}

The top-level `func ReadFile` first checks to see if its argument `fs` implements `ReadFileFS`.
If so, `func ReadFile` calls `fs.ReadFile`.
Otherwise it falls back to the `Open`, `Read`, `Close` sequence.

For concreteness, here is a complete implementation of `func ReadFile`:

	func ReadFile(fsys FS, name string) ([]byte, error) {
		if fsys, ok := fsys.(ReadFileFS); ok {
			return fsys.ReadFile(name)
		}

		file, err := fsys.Open(name)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		return io.ReadAll(file)
	}

(This assumes `io.ReadAll` exists; see [issue 40025](https://golang.org/issue/40025).)

#### Stat

We can use the extension pattern again for `Stat` (analogous to `os.Stat`):

	type StatFS interface {
		FS
		Stat(name string) (os.FileInfo, error)
	}

	func Stat(fsys FS, name string) (os.FileInfo, error) {
		if fsys, ok := fsys.(StatFS); ok {
			return fsys.Stat(name)
		}

		file, err := fsys.Open(name)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		return file.Stat()
	}

#### ReadDir

And we can use the extension pattern again for `ReadDir` (analogous to `ioutil.ReadDir`):

	type ReadDirFS interface {
		FS
		ReadDir(name string) ([]os.FileInfo, error)
	}

	func ReadDir(fsys FS, name string) ([]os.FileInfo, error)

The implementation follows the pattern,
but the fallback case is slightly more complex:
it must handle the case where the named file
does not implement `ReadDirFile` by creating an appropriate error to return.

#### Walk

The `io/fs` package provides a top-level `func Walk` (analogous to `filepath.Walk`)
built using `func ReadDir`,
but there is _not_ an analogous extension interface.

The semantics of `Walk` are such that the only significant
optimization would be to have access to a fast `ReadDir` function.
An `FS` implementation can provide that by implementing `ReadDirFS`.
The semantics of `Walk` are also quite subtle: it is better
to have a single correct implementation than buggy custom ones,
especially if a custom one cannot provide any significant
optimization.

This can still be seen as a kind of extension pattern,
but without the one-to-one match:
instead of `Walk` using `WalkFS`, we have `Walk` reusing `ReadDirFS`.

#### Glob

Another convenience function is `Glob`, analogous to `filepath.Glob`:

	type GlobFS interface {
		FS
		Glob(pattern string) ([]string, error)
	}

	func Glob(fsys FS, pattern string) ([]string, error)

The fallback case here is not a trivial single call
but instead most of a copy of `filepath.Glob`: it must
decide which directories to read, read them, and look
for matches.

Although `Glob` is like `Walk` in that its implementation
is a non-trivial amount of somewhat subtle code,
`Glob` differs from `Walk` in that a custom implementation
can deliver a significant speedup.
For example, suppose the pattern is `*/gopher.jpg`.
The general implementation has to call `ReadDir(".")`
and then `Stat(dir+"/gopher.jpg")` for every directory
in the list returned by `ReadDir`.
If the `FS` is being accessed over a network and `*`
matches many directories, this sequence requires
many round trips.
In this case, the `FS` could implement a `Glob` method
that answered the call in a single round trip,
sending only the pattern and receiving only the matches,
avoiding all the directories that don't contain `gopher.jpg`.

### Possible future or third-party extensions

This design is limited to the above operations,
which provide basic, convenient, read-only access to a file system.
However, the extension pattern can be applied to add
any new operations we might want in the future.
Even third-party packages can use it; not every
possible file system operation needs to be contemplated in `io/fs`.

For example, the `FS` in this design provides no support
for renaming files.
But it could be added easily, using code like:

	type RenameFS interface {
		FS
		Rename(oldpath, newpath string) error
	}

	func Rename(fsys FS, oldpath, newpath string) error {
		if fsys, ok := fsys.(RenameFS); ok {
			return fsys.Rename(oldpath, newpath)
		}

		return fmt.Errorf("rename %s %s: operation not supported", oldpath, newpath)
	}

Note that this code does nothing
that requires being in the `io/fs` package.
A third-party package can define its own `FS` helpers
and extension interfaces.

The `FS` in this design also provides no way to
open a file for writing.
Again, this could be done with the extension pattern,
even from a different package.
If done from a different package, the code might look like:

	type OpenFileFS interface {
		fs.FS
		OpenFile(name string, flag int, perm os.FileMode) (fs.File, error)
	}

	func OpenFile(fsys FS, name string, flag int, perm os.FileMode) (fs.File, error) {
		if fsys, ok := fsys.(OpenFileFS); ok {
			return fsys.OpenFile(name, flag, perm)
		}

		if flag == os.O_RDONLY {
			return fs.Open(name)
		}
		return fmt.Errorf("open %s: operation not supported", name)
	}

Note that even if this pattern were implemented in multiple
other packages, they would still all interoperate
(provided the method signatures matched,
which is likely, since package `os` has already defined
the canonical names and signatures).
The interoperation results from the implementations
all agreeing on the shared file system type and file type:
`fs.FS` and `fs.File`.

The extension pattern can be applied to any missing operation:
`Chmod`, `Chtimes`, `Mkdir`, `MkdirAll`, `Sync`, and so on.
Instead of putting them all in `io/fs`,
the design starts small, with read-only operations.

### Adjustments to os

As presented above, the `io/fs` package needs to import `os`
for the `os.FileInfo` interface and the `os.FileMode` type.
These types do not really belong in `os`,
but we had no better home for them when they were introduced.
Now, `io/fs` is a better home,
and they should move there.

This design moves `os.FileInfo` and `os.FileMode` into `io/fs`,
redefining the names in `os` as aliases for the definitions in `io/fs`.
The `FileMode` constants, such as `ModeDir`, would move as well,
redefining the names in `os` as constants copying the `io/fs` values.
No user code will need updating, but the move will make it possible
to implement an `fs.FS` by importing only `io/fs`, not `os`.
This is analogous to `io` not depending on `os`.
(For more about why `io` should not depend on `os`, see
“[Codebase Refactoring (with help from Go)](https://talks.golang.org/2016/refactor.article)”,
especially section 3.)

For the same reason, the type `os.PathError` should move to `io/fs`,
with a forwarding type alias left behind.

The general file system errors `ErrInvalid`, `ErrPermission`,
`ErrExist`, `ErrNotExist`, and `ErrClosed` should also move to `io/fs`.
In this case, those are variables, not types, so no aliases are needed.
The definitions left behind in package `os` would be:

	package os

	import "io/fs"

	var (
		ErrInvalid    = fs.ErrInvalid
		ErrPermission = fs.ErrPermission
		...
	)

To match `fs.ReadDirFile` and fix casing, the design adds new `os.File` methods
`ReadDir` and `ReadDirNames`, equivalent to the existing `Readdir` and `Readdirnames`.
The old casings should have been corrected long ago;
correcting them now in `os.File` is better than requiring all
implementations of `fs.File` to use the wrong names.
(Adding `ReadDirNames` is not strictly necessary, but we might
as well fix them both at the same time.)

Finally, as code starts to be written that expects an `fs.FS` interface,
it will be natural to want an `fs.FS` backed by an operating system directory.
This design adds a new function `os.DirFS`:

	package os

	// DirFS returns an fs.FS implementation that
	// presents the files in the subtree rooted at dir.
	func DirFS(dir string) fs.FS

Note that this function can only be written once the `FileInfo`
type moves into `io/fs`, so that `os` can import `io/fs`
instead of the other way around.

### Adjustments to html/template and text/template

The `html/template` and `text/template` packages each provide
a pair of methods reading from the operating system's file system:

	func (t *Template) ParseFiles(filenames ...string) (*Template, error)
	func (t *Template) ParseGlob(pattern string) (*Template, error)

The design adds one new method:

	func (t *template) ParseFS(fsys fs.FS, patterns ...string) (*Template, error)

Nearly all file names are glob patterns matching only themselves,
so a single call should suffice instead of having to introduce both `ParseFilesFS` and `ParseGlobFS`.

TODO mention top-level calls

### Adjustments to net/http

The `net/http` package defines its own `FileSystem` and `File` types,
used by `http.FileServer`:

	type FileSystem interface {
		Open(name string) (File, error)
	}

	type File interface {
		io.Closer
		io.Reader
		io.Seeker
		Readdir(count int) ([]os.FileInfo, error)
		Stat() (os.FileInfo, error)
	}

	func FileServer(root FileSystem) Handler

If `io/fs` had come before `net/http`, this code could use `io/fs` directly,
removing the need to define those interfaces.
Since they already exist,
they must be left for compatibility.

The design adds an equivalent to `FileServer` but for an `fs.FS`:

	func HandlerFS(fsys fs.FS) Handler

The `HandlerFS` requires of its file system that the opened files support `Seek`.
This is an additional requirement made by HTTP, to support range requests.
Not all file systems need to implement `Seek`.

### Adjustments to archive/zip

Any Go type that represents a tree of files should implement `fs.FS`.

The current `zip.Reader` has no `Open` method,
so this design adds one, with the signature needed
to implement `fs.FS`.
Note that the opened files are streams of bytes decompressed on the fly.
They can be read, but not seeked.
This means a `zip.Reader` now implements `fs.FS` and therefore
can be used as a source of templates passed to `html/template`.
While the same `zip.Reader` can also be passed to
`net/http` using `http.HandlerFS`—that is, such a program would type-check—the
HTTP server would not be able to serve range requests on those files,
for lack of a `Seek` method.

On the other hand, for a small set of files, it might make sense to define
file system middleware that cached copies of the underlying files in memory,
providing seekability and perhaps increased performance, in exchange for
higher memory usage. Such middleware—some kind of `CachingFS`—could be provided
in a third-party package and then used to connect the `zip.Reader` to an `http.HandlerFS`.
Indeed, enabling that kind of middleware is a key goal for this draft design.
Another example might be transparent decryption of the underlying files.

### Adjustments to archive/tar (none)

The design does not include changes to `archive/tar`,
because that format cannot easily support random access:
the first call to `Open` would have to read the entire
archive to find all its files, caching the list for future calls.
And that's only even possible if the underlying `io.Reader`
supports `Seek` or `ReadAt`.
That's a lot of work for an implementation that would be fairly inefficient;
adding it to the standard library would be setting a performance trap.
If needed, the functionality could be provided by a third-party package instead.

## Rationale

### Why now?

The rationale for the specific design decisions is given along with those decisions above.
But there have been discussions about a file system interface for many years, with no progress. Why now?

Two things have changed since those early discussions.

First, we have a direct need for the functionality in the standard library,
and necessity remains the mother of invention.
The [embedded files draft design](https://golang.org/s/draft-embed-design)
aims to add direct support for embedded files to the `go` command,
which raises the question of how to integrate them with the rest of the
standard library.
For example, a common use for embedded files is to parse them as templates
or serve them directly over HTTP.
Without this design, we'd need to define specific methods in those packages
for accepting embedded files.
Defining a file system interface lets us instead add general new methods that will
apply not just to embedded files but also ZIP files and any other kind of resource
presented as an `FS` implementation.

Second, we have more experience with how to use optional interfaces well.
Previous attempts at file system interfaces floundered in the complexity of
defining a complete set of operations.
The results were unwieldy to implement.
This design reduces the necessary implementation to an absolute minimum,
with the extension pattern allowing the provision of new functionality,
even by third-party packages.

### Why not http.FileServer?

The `http.FileServer` and `http.File` interfaces are clearly one of the inspirations
for the new `fs.FS` and `fs.File`, and they have been used beyond HTTP.
But they are not quite right:
every `File` need not be required to implement `Seek` and `Readdir`.
As noted earlier, `text/template` and `html/template` are perfectly happy
reading from a collection of non-seekable files (for example, a ZIP archive).
It doesn't make sense to impose HTTP's requirements on all file systems.

If we are to encourage use of a general interface well beyond HTTP,
it is worth getting right; the cost is only minimal adaptation of
existing `http.FileServer` implementations.
It should also be easy to write general adapters in both directions.

### Why not in golang.org/x?

New API sometimes starts in `golang.org/x`; for example, `context` was originally `golang.org/x/net/context`.
That's not an option here, because one of the key parts of the design
is to define good integrations with the standard library,
and those APIs can't expose references to`golang.org/x`.
(At that point, the APIs might as well be in the standard library.)

## Compatibility

This is all new API.
There are no conflicts with the [compatibility guidelines](https://golang.org/doc/go1compat).

If we'd had `io/fs` before Go 1, some API might have been avoided.

## Implementation

A [prototype implementation](https://golang.org/s/draft-iofs-code) is available.
