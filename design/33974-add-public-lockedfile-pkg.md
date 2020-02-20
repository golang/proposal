# Proposal: make the internal [lockedfile](https://godoc.org/github.com/golang/go/src/cmd/go/internal/lockedfile/) package public

Author(s): [Adrien Delorme]

Last updated: 2019-10-15

Discussion at https://golang.org/issue/33974.

## Abstract

Move already existing code residing in
`golang/go/src/cmd/go/internal/lockedfile` to `x/sync`.

## Background

A few open source Go projects are implementing file locking mechanisms but they
do not seem to be maintained anymore:
* https://github.com/gofrs/flock : This repo has lastly accepted PRs in March
   2019, so this implementation may be maintained and we could argue that the 
   `lockedfile` package API is more ergonomic. Incompatibilities with AIX,
   Solaris and Illumos are preventing file locking on both projects, but it
   looks like the go team is addressing for `lockedfile`.
* https://github.com/juju/fslock : Note that this implementation is both
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

// A File is a locked *os.File.
//
// Closing the file releases the lock.
//
// If the program exits while a file is locked, the operating system releases
// the lock but may not do so promptly: callers must ensure that all locked
// files are closed before exiting.
type File struct {
    // contains unexported fields
}

// Create is like os.Create, but returns a write-locked file.
// If the file already exists, it is truncated.
func Create(name string) (*File, error)

// Edit creates the named file with mode 0666 (before umask),
// but does not truncate existing contents.
//
// If Edit succeeds, methods on the returned File can be used for I/O.
// The associated file descriptor has mode O_RDWR and the file is write-locked.
func Edit(name string) (*File, error)

// Transform invokes t with the result of reading the named file, with its lock
// still held.
//
// If t returns a nil error, Transform then writes the returned contents back to
// the file, making a best effort to preserve existing contents on error.
//
// t must not modify the slice passed to it.
func Transform(name string, t func([]byte) ([]byte, error)) (err error)

// Open is like os.Open, but returns a read-locked file.
func Open(name string) (*File, error)

// OpenFile is like os.OpenFile, but returns a locked file.
// If flag implies write access (ie: os.O_TRUNC, os.O_WRONLY or os.O_RDWR), the
// file is write-locked; otherwise, it is read-locked.
func OpenFile(name string, flag int, perm os.FileMode) (*File, error)

// Read reads up to len(b) bytes from the File.
// It returns the number of bytes read and any error encountered.
// At end of file, Read returns 0, io.EOF.
//
// File can be read-locked or write-locked.
func (f *File) Read(b []byte) (n int, err error)

// ReadAt reads len(b) bytes from the File starting at byte offset off.
// It returns the number of bytes read and the error, if any.
// ReadAt always returns a non-nil error when n < len(b).
// At end of file, that error is io.EOF.
//
// File can be read-locked or write-locked.
func (f *File) ReadAt(b []byte, off int64) (n int, err error)

// Write writes len(b) bytes to the File.
// It returns the number of bytes written and an error, if any.
// Write returns a non-nil error when n != len(b).
//
// If File is not write-locked Write returns an error.
func (f *File) Write(b []byte) (n int, err error)

// WriteAt writes len(b) bytes to the File starting at byte offset off.
// It returns the number of bytes written and an error, if any.
// WriteAt returns a non-nil error when n != len(b).
//
// If file was opened with the O_APPEND flag, WriteAt returns an error.
// 
// If File is not write-locked WriteAt returns an error.
func (f *File) WriteAt(b []byte, off int64) (n int, err error)

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
    // Path to the well-known lock file. Must be non-empty.
    //
    // Path must not change on a locked mutex.
    Path string 
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

* The `lockedfile.File` implements a subset of the `os.File` but with file
  locking protection.

* The `lockedfile.Mutex` does not implement `sync.Locker`: unlike a
  `sync.Mutex`, a `lockedfile.Mutex` can fail to lock (e.g. if there is a
  permission error in the filesystem).

* `lockedfile` adds an `Edit` and a `Transform` function; `Edit` is not
  currently part of the `file` package. Edit exists to make it easier to
  implement locked read-modify-write operation. `Transform` simplifies the act
  of reading and then writing to a locked file.
  

* Making this package public will make it more used. A tiny surge of issues
  might come in the beginning; at the benefits of everyone. (Unless it's bug
  free !!).

* There exists a https://godoc.org/github.com/rogpeppe/go-internal package that
  exports a lot of internal packages from the go repo. But if go-internal
  became wildly popular; in order to have a bug fixed or a feature introduced
  in; a user would still need to open a PR on the go repo; then the author of
  go-internal would need to update the package.

## Compatibility

There are no retro-compatibility issues since this will be a code addition but
ideally we don't want to maintain two copies of this package going forward, and
we probably don't want to vendor `x/exp` into the `cmd` module.



Perhaps that implies that this should go in the `x/sys` or `x/sync` repo instead?

## Implementation

Adrien Delorme plans to do copy the exported types in the proposal section from
 `cmd/go/internal/lockedfile` to `x/sync`.

Adrien Delorme plans to change the references to the `lockedfile` package in
`cmd`.