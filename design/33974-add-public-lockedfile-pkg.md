# Proposal: make the internal [lockedfile](https://godoc.org/github.com/golang/go/src/cmd/go/internal/lockedfile/) package public

Author(s): [Adrien Delorme]

Last updated: 2019-10-15

Discussion at https://golang.org/issue/33974.

## Abstract

Move already existing code residing golang/go/src/cmd/go/internal/lockedfile to
`x/exp`. At `x/exp/lockedfile`.

## Background

A few open source Go projects are implementing file locking mechanisms but they
do not seem to be maintained anymore:
 https://github.com/gofrs/flock : This repo has accepted PRs as recently as
   this March, so this implementation may be maintained — but it is not (yet?)
   portable to as many platforms as the implementation in the Go project, and
   we could argue that our `lockedfile` package API is more ergonomic anyway.
 https://github.com/juju/fslock : Note that this implementation is both
   unmaintained and LGPL-licensed, so even folks who would like to use it might
   not be able to. Also not that this repo [was selected for removal in
   2017](https://github.com/juju/fslock/issues/4) 


As a result some major projects are doing
their own version of it; ex:
[terraform](https://github.com/hashicorp/terraform/blob/1ff9a540202b8c36e33db950374bbb4495737d8f/states/statemgr/filesystem_lock_unix.go),
[boltdb](https://github.com/boltdb/bolt/search?q=flock&unscoped_q=flock). After
some researches it seemed to us that the already existing and maintained
[lockedfile](https://godoc.org/github.com/golang/go/src/cmd/go/internal/lockedfile/)
package is the best 'open source' version.

File-locking interacts pretty deeply with the `os` package and the system call
library in `x/sys`, so it makes sense for (a subset of) the same owners to
consider the evolution of those packages together.
We think it would benefit the mass to make such a package public: since it's
already being part of the go code and therefore being maintained; it should be
made public.

## Proposal

We propose to copy the golang/go/src/cmd/go/internal/lockedfile to `x/exp`. To
make it public. Not changing any of the named types for now.

Exported names and comments as can be currently found in
[07b4abd](https://github.com/golang/go/tree/07b4abd62e450f19c47266b3a526df49c01ba425/src/cmd/go/internal/lockedfile):

```
// Package lockedfile creates and manipulates files whose contents should only
// change atomically.
package lockedfile

// Read opens the named file with a read-lock and returns its contents.
func Read(name string) ([]byte, error)

// Write opens the named file (creating it with the given permissions if
// needed), then write-locks it and overwrites it with the given content.
func Write(name string, content io.Reader, perm os.FileMode) (err error)

// A File is a locked *os.File.
//
// Closing the file releases the lock.
//
// If the program exits while a file is locked, the operating system releases
// the lock but may not do so promptly: callers must ensure that all locked
// files are closed before exiting.
type File struct {
    // contains filtered or unexported fields
}

// Create is like os.Create, but returns a write-locked file.
func Create(name string) (*File, error)

// Edit creates the named file with mode 0666 (before umask),
// but does not truncate existing contents.
//
// If Edit succeeds, methods on the returned File can be used for I/O.
// The associated file descriptor has mode O_RDWR and the file is write-locked.
func Edit(name string) (*File, error)

// Open is like os.Open, but returns a read-locked file.
func Open(name string) (*File, error)

// OpenFile is like os.OpenFile, but returns a locked file.
// If flag includes os.O_WRONLY or os.O_RDWR, the file is write-locked;
// otherwise, it is read-locked.
func OpenFile(name string, flag int, perm os.FileMode) (*File, error)

// Close unlocks and closes the underlying file.
//
// Close may be called multiple times; all calls after the first will return a
// non-nil error.
func (f *File) Close() error

// A Mutex provides mutual exclusion within and across processes by locking a
// well-known file. Such a file generally guards some other part of the
// filesystem: for example, a Mutex file in a directory might guard access to
// the entire tree rooted in that directory.
//
// Mutex does not implement sync.Locker: unlike a sync.Mutex, a lockedfile.Mutex
// can fail to lock (e.g. if there is a permission error in the filesystem).
//
// Like a sync.Mutex, a Mutex may be included as a field of a larger struct but
// must not be copied after first use. The Path field must be set before first
// use and must not be change thereafter.
type Mutex struct {
    Path string // The path to the well-known lock file. Must be non-empty.
    // contains filtered or unexported fields
}

// MutexAt returns a new Mutex with Path set to the given non-empty path.
func MutexAt(path string) *Mutex

// Lock attempts to lock the Mutex.
//
// If successful, Lock returns a non-nil unlock function: it is provided as a
// return-value instead of a separate method to remind the caller to check the
// accompanying error. (See https://golang.org/issue/20803.)
func (mu *Mutex) Lock() (unlock func(), err error)

// String returns a string containing the path of the mutex.
func (mu *Mutex) String() string
```

## Rationale

The golang/go/src/cmd/go/internal/lockedfile already exists but has untrusted &
unmaintained alternatives.

Making this package public will make it more used. A tiny surge of issues
  might come in the beginning; at the benefits of everyone. ( Unless it's
  bug free !! ).

There exists a https://godoc.org/github.com/rogpeppe/go-internal package that
  exports a lot of internal packages from the go repo. But if go-internal
  became wildly popular; in order to have a bug fixed or a feature introduced
  in; a user would still need to open a PR on the go repo; then the author of
  go-internal would need to update the package.

## Compatibility

There are no compatibility issues. Since this will be a code addition.

## Implementation

Adrien Delorme plans to do copy the internal/lockedfile package from cmd/go to
`x/exp`.