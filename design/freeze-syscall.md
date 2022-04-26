# The syscall package

Author: Rob Pike
Date: 2014

Status: this proposal was [adopted for the Go 1.4 release]
(https://go.dev/doc/go1.4#major_library_changes).

## Problem

The `syscall` package as it stands today has several problems:

1. Bloat. It contains definitions of many system calls and constants
   for a large and growing set of architectures and operating systems.
2. Testing. Little of the interface has explicit tests, and
   cross-platform testing is impossible.
3. Curation. Many change lists arrive, in support of wide-ranging
   packages and systems. The merit of these changes is hard to judge,
   so essentially anything goes. The package is the worst maintained,
   worst tested, and worst documented package in the standard
   repository, and continues to worsen.
4. Documentation. The single package, called `syscall`, is different
   for every system, but godoc only shows the variant for its own
   native environment. Moreover, the documentation is sorely lacking
   anyway. Most functions have no doc comment at all.
5. Compatibility. Despite best intentions, the package does not meet
   the Go 1 compatibility guarantee because operating systems change
   in ways that are beyond our control. The recent changes to FreeBSD
   are one example.

This proposal is an attempt to ameliorate these issues.

## Proposal

The proposal has several components. In no particular order:

1. The Go 1 compatibility rules mean that we cannot fix the problem
   outright, say by making the package internal. We therefore propose
   to freeze the package as of Go 1.3, which will mean backing out
   some changes that have gone in since then.
2. Any changes to the system call interface necessary to support
   future versions of Go will be done through the internal package
   mechanism proposed for Go 1.4.
3. The `syscall` package will not be updated in future releases, not
   even to keep pace with changes in operating systems it
   references. For example, if the value of a kernel constant changes
   in a future NetBSD release, package `syscall` will not be updated
   to reflect that.
4. A new subrepository, `go.sys`, will be created.
5. Inside `go.sys`, there will be three packages, independent of
   syscall, called `plan9`, `unix`, and `windows`, and the current
   `syscall` package's contents will be broken apart as appropriate
   and installed in those packages. (This split expresses the
   fundamental interface differences between the systems, permitting
   some source-level portability, but within the packages build tags
   will still be needed to separate out architectures and variants
   (darwin, linux)). These are the packages we expect all external Go
   packages to migrate to when they need support for system
   calls. Because they are distinct, they are easier to curate, easier
   to examine with godoc, and may be easier to keep well
   documented. This layout also makes it clearer how to write
   cross-platform code: by separating system-dependent elements into
   separately imported components.
6. The `go.sys` repositories will be updated as operating systems
   evolve.
7. The documentation for the standard `syscall` package will direct
   users to the new repository. Although the `syscall` package will
   continue to exist and work as well as feasible, all new public
   development will occur in `go.sys`.
8. The core repository will not depend on the `go.sys` packages,
   although it is likely some of the subrepositories, such as
   `go.net`, will.
9. As with any standard repository, the `go.sys` repository will be
   curated by the Go team.  Separating it out of the main repository
   makes it more practical to automate some of the maintenance, for
   example to create packages automatically by exhaustive processing
   of system include files.
10. Any non-essential changes at tip that have occurred in the
    `syscall` package since 1.3 will be migrated to the `go.sys`
    subrepository.

Note that we cannot clean up the existing `syscall` package to any
meaningful extent because of the compatibility guarantee. We can
freeze and, in effect, deprecate it, however.

## Timeline

We propose to complete these changes before the September 1, 2014
deadline for Go 1.4.
