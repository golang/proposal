## Proposal: `go install` should install executables in module mode outside a module

Authors: Jay Conrod, Daniel Martí

Last Updated: 2020-09-29

Discussion at https://golang.org/issue/40276.

## Abstract

Authors of executables need a simple, reliable, consistent way for users to
build and install exectuables in module mode without updating module
requirements in the current module's `go.mod` file.

## Background

`go get` is used to download and install executables, but it's also responsible
for managing dependencies in `go.mod` files. This causes confusion and
unintended side effects: for example, the command
`go get golang.org/x/tools/gopls` builds and installs `gopls`. If there's a
`go.mod` file in the current directory or any parent, this command also adds a
requirement on the module `golang.org/x/tools/gopls`, which is usually not
intended. When `GO111MODULE` is not set, `go get` will also run in GOPATH mode
when invoked outside a module.

These problems lead authors to write complex installation commands such as:

```
(cd $(mktemp -d); GO111MODULE=on go get golang.org/x/tools/gopls)
```

## Proposal

We propose augmenting the `go install` command to build and install packages
at specific versions, regardless of the current module context.

```
go install golang.org/x/tools/gopls@v0.4.4
```

To eliminate redundancy and confusion, we also propose deprecating and removing
`go get` functionality for building and installing packages.

### Details

The new `go install` behavior will be enabled when an argument has a version
suffix like `@latest` or `@v1.5.2`. Currently, `go install` does not allow
version suffixes. When a version suffix is used:

* `go install` runs in module mode, regardless of whether a `go.mod` file is
  present. If `GO111MODULE=off`, `go install`  reports an error, similar to
  what `go mod download` and other module commands do.
* `go install` acts as if no `go.mod` file is present in the current directory
  or parent directory.
* No module will be considered the "main" module.
* Errors are reported in some cases to ensure that consistent versions of
  dependencies are used by users and module authors. See Rationale below.
  * Command line arguments must not be meta-patterns (`all`, `std`, `cmd`)
    or local directories (`./foo`, `/tmp/bar`).
  * Command line arguments must refer to main packages (executables). If a
    argument has a wildcard (`...`), it will only match main packages.
  * Command line arguments must refer to packages in one module at a specific
    version. All version suffixes must be identical. The versions of the
    installed packages' dependencies are determined by that module's `go.mod`
    file (if it has one).
  * If that module has a `go.mod` file, it must not contain directives that
    would cause it to be interpreted differently if the module were the main
    module. In particular, it must not contain `replace` or `exclude`
    directives.

If `go install` has arguments without version suffixes, its behavior will not
change. It will operate in the context of the main module. If run in module mode
outside of a module, `go install` will report an error.

With these restrictions, users can install executables using consistent commands.
Authors can provide simple installation instructions without worrying about
the user's working directory.

With this change, `go install` would overlap with `go get` even more, so we also
propose deprecating and removing the ability for `go get` to install packages.

* In Go 1.16, when `go get` is invoked outside a module or when `go get` is
  invoked without the `-d` flag with arguments matching one or more main
  packages, `go get` would print a deprecation warning recommending an
  equivalent `go install` command.
* In a later release (likely Go 1.17), `go get` would no longer build or install
  packages. The `-d` flag would be enabled by default. Setting `-d=false` would
  be an error. If `go get` is invoked outside a module, it would print an error
  recommending an equivalent `go install` command.

### Examples

```
# Install a single executable at the latest version
$ go install example.com/cmd/tool@latest

# Install multiple executables at the latest version
$ go install example.com/cmd/...@latest

# Install at a specific version
$ go install example.com/cmd/tool@v1.4.2
```

## Current `go install` and `go get` functionality

`go install` is used for building and installing packages within the context of
the main module. `go install` reports an error when invoked outside of a module
or when given arguments with version queries like `@latest`.

`go get` is used both for updating module dependencies in `go.mod` and for
building and installing executables. `go get` also works differently depending
on whether it's invoked inside or outside of a module.

These overlapping responsibilities lead to confusion. Ideally, we would have one
command (`go install`) for installing executables and one command (`go get`) for
changing dependencies.

Currently, when `go get` is invoked outside a module in module mode (with
`GO111MODULE=on`), its primary purpose is to build and install executables. In
this configuration, there is no main module, even if only one module provides
packages named on the command line. The build list (the set of module versions
used in the build) is calculated from requirements in `go.mod` files of modules
providing packages named on the command line. `replace` or `exclude` directives
from all modules are ignored. Vendor directories are also ignored.

When `go get` is invoked inside a module, its primary purpose is to update
requirements in `go.mod`. The `-d` flag is often used, which instructs `go get`
not to build or install packages. Explicit `go build` or `go install` commands
are often better for installing tools when dependency versions are specified in
`go.mod` and no update is desired. Like other build commands, `go get` loads the
build list from the main module's `go.mod` file, applying any `replace` or
`exclude` directives it finds there. `replace` and `exclude` directives in other
modules' `go.mod` files are never applied. Vendor directories in the main module
and in other modules are ignored; the `-mod=vendor` flag is not allowed.

The motivation for the current `go get` behavior was to make usage in module
mode similar to usage in GOPATH mode. In GOPATH mode, `go get` would download
repositories for any missing packages into `$GOPATH/src`, then build and install
those packages into `$GOPATH/bin` or `$GOPATH/pkg`. `go get -u` would update
repositories to their latest versions. `go get -d` would download repositories
without building packages. In module mode, `go get` works with requirements in
`go.mod` instead of repositories in `$GOPATH/src`.

## Rationale

### Why can't `go get` clone a git repository and build from there?

In module mode, the `go` command typically fetches dependencies from a
proxy. Modules are distributed as zip files that contain sources for specific
module versions. Even when `go` connects directly to a repository instead of a
proxy, it still generates zip files so that builds work consistently no matter
how modules are fetched. Those zip files don't contain nested modules or vendor
directories.

If `go get` cloned repositories, it would work very differently from other build
commands. That causes several problems:

* It adds complication (and bugs!) to the `go` command to support a new build
  mode.
* It creates work for authors, who would need to ensure their programs can be
  built with both `go get` and `go install`.
* It reduces speed and reliability for users. Modules may be available on a
  proxy when the original repository is unavailable. Fetching modules from a
  proxy is roughly 5-7x faster than cloning git repositories.

### Why can't vendor directories be used?

Vendor directories are not included in module zip files. Since they're not
present when a module is downloaded, there's no way to build with them.

We don't plan to include vendor directories in zip files in the future
either. Changing the set of files included in module zip files would break
`go.sum` hashes.

### Why can't directory `replace` directives be used?

For example:

```
replace example.com/sibling => ../sibling
```

`replace` directives with a directory path on the right side can't be used
because the directory must be outside the module. These directories can't be
present when the module is downloaded, so there's no way to build with them.

### Why can't module `replace` directives be used?

For example:

```
replace example.com/mod v1.0.0 => example.com/fork v1.0.1-bugfix
```

It is technically possible to apply these directives. If we did this, we would
still want some restrictions. First, an error would be reported if more than one
module provided packages named on the command line: we must be able to identify
a main module. Second, an error would be reported if any directory `replace`
directives were present: we don't want to introduce a new configuration where
some `replace` directives are applied but others are silently ignored.

However, there are two reasons to avoid applying `replace` directives at all.

First, applying `replace` directives would create inconsistency for users inside
and outside a module. When a package is built within a module with `go build` or
`go install`, only `replace` directives from the main module are applied, not
the module providing the package. When a package is built outside a module with
`go get`, no `replace` directives are applied. If `go install` applied `replace`
directives from the module providing the package, it would not be consistent
with the current behavior of any other build command. To eliminate confusion
about whether `replace` directives are applied, we propose that `go install`
reports errors when encountering them.

Second, if `go install` applied `replace` directives, it would take power away
from developers that depend on modules that provide tools. For example, suppose
the author of a popular code generation tool `gogen` forks a dependency
`genutil` to add a feature. They add a `replace` directive pointing to their
fork of `genutil` while waiting for a PR to merge. A user of `gogen` wants to
track the version they use in their `go.mod` file to ensure everyone on their
team uses a consistent version. Unfortunately, they can no longer build `gogen`
with `go install` because the `replace` is ignored. The author of `gogen` might
instruct their users to build with `go install`, but then users can't track the
dependency in their `go.mod` file, and they can't apply their own `require` and
`replace` directives to upgrade or fix other transitive dependencies. The author
of `gogen` could also instruct their users to copy the `replace` directive, but
this may conflict with other `require` and `replace` directives, and it may
cause similar problems for users further downstream.

### Why report errors instead of ignoring `replace`?

If `go install` ignored `replace` directives, it would be consistent with the
current behavior of `go get` when invoked outside a module. However, in
[#30515](https://golang.org/issue/30515) and related discussions, we found that
many developers are surprised by that behavior.

It seems better to be explicit that `replace` directives are only applied
locally within a module during development and not when users build packages
from outside the module. We'd like to encourage module authors to release
versions of their modules that don't rely on `replace` directives so that users
in other modules may depend on them easily.

If this behavior turns out not to be suitable (for example, authors prefer to
keep `replace` directives in `go.mod` at release versions and understand that
they won't affect users), then we could start ignoring `replace` directives in
the future, matching current `go get` behavior.

### Should `go.sum` files be checked?

Because there is no main module, `go install` will not use a `go.sum` file to
authenticate any downloaded module or `go.mod` file. The `go` command will still
use the checksum database ([sum.golang.org](https://sum.golang.org)) to
authenticate downloads, subject to privacy settings. This is consistent with the
current behavior of `go get`: when invoked outside a module, no `go.sum` file is
used.

The new `go install` command requires that only one module may provide packages
named on the command line, so it may be logical to use that module's `go.sum`
file to verify downloads. This avoids a problem in
[#28802](https://golang.org/issue/28802), a related proposal to verify downloads
against all `go.sum` files in dependencies: the build can't be broken by one bad
`go.sum` file in a dependency.

However, using the `go.sum` from the module named on the command line only
provides a marginal security benefit: it lets us authenticate private module
dependencies (those not available to the checksum database) when the module on
the command line is public. If the module named on the command line is private
or if the checksum database isn't used, then we can't authenticate the download
of its content (including the `go.sum` file), and we must trust the proxy. If
all dependencies are public, we can authenticate all downloads without `go.sum`.

### Why require a version suffix when outside a module?

If no version suffix were required when `go install` is invoked outside a
module, then the meaning of the command would depend on whether the user's
working directory is inside a module. For example:

```
go install golang.org/x/tools/gopls
```

When invoked outside of a module, this command would run in `GOPATH` mode,
unless `GO111MODULE=on` is set. In module mode, it would install the latest
version of the executable.

When invoked inside a module, this command would use the main module's `go.mod`
file to determine the versions of the modules needed to build the package.

We currently have a similar problem with `go get`. Requiring the version suffix
makes the meaning of a `go install` command unambiguous.

### Why not a `-g` flag instead of `@latest`?

To install the latest version of an executable, the two commands below would be
equivalent:

```
go install -g golang.org/x/tools/gopls
go install golang.org/x/tools/gopls@latest
```

The `-g` flag has the advantage of being shorter for a common use case. However,
it would only be useful when installing the latest version of a package, since
`-g` would be implied by any version suffix.

The `@latest` suffix is clearer, and it implies that the command is
time-dependent and not reproducible. We prefer it for those reasons.

## Compatibility

The `go install` part of this proposal only applies to commands with version
suffixes on each argument. `go install` reports an error for these, and this
proposal does not recommend changing other functionality of `go install`, so
that part of the proposal is backward compatible.

The `go get` part of this proposal recommends deprecating and removing
functionality, so it's certainly not backward compatible. `go get -d` commands
will continue to work without modification though, and eventually, the `-d` flag
can be dropped.

Parts of this proposal are more strict than is technically necessary (for
example, requiring one module, forbidding `replace` directives). We could relax
these restrictions without breaking compatibility in the future if it seems
expedient. It would be much harder to add restrictions later.

## Implementation

An initial implementation of this feature was merged in
[CL 254365](https://go-review.googlesource.com/c/go/+/254365). Please try it
out!

## Future directions

The behavior with respect to `replace` directives was discussed extensively
before this proposal was written. There are three potential behaviors:

1. Ignore `replace` directives in all modules. This would be consistent with
   other module-aware commands, which only apply `replace` directives from the
   main module (defined in the current directory or a parent directory).
   `go install pkg@version` ignores the current directory and any `go.mod`
   file that might be present, so there is no main module.
2. Ensure only one module provides packages named on the command line, and
   treat that module as the main module, applying its module `replace`
   directives from it. Report errors for directory `replace` directives. This
   is feasible, but it may have wider ecosystem effects; see "Why can't module
   `replace` directives be used?" above.
3. Ensure only one module provides packages named on the command line, and
   report errors for any `replace` directives it contains. This is the behavior
   currently proposed.

Most people involved in this discussion have advocated for either (1) or (2).
The behavior in (3) is a compromise. If we find that the behavior in (1) is
strictly better than (2) or vice versa, we can switch to that behavior from
(3) without an incompatible change. Additionally, (3) eliminates
ambiguity about whether `replace` directives are applied for users and module
authors.

Note that applying directory `replace` directives is not considered here for
the reasons in "Why can't directory `replace` directives be used?".

## Appendix: FAQ

### Why not apply `replace` directives from all modules?

In short, `replace` directives from different modules would conflict, and
that would make dependency management harder for most users.

For example, consider a case where two dependencies replace the same module
with different forks.

```
// in example.com/mod/a
replace example.com/mod/c => example.com/fork-a/c v1.0.0

// in example.com/mod/b
replace example.com/mod/c => example.com/fork-b/c v1.0.0
```

Another conflict would occur where two dependencies pin different versions
of the same module.

```
// in example.com/mod/a
replace example.com/mod/c => example.com/mod/c v1.1.0

// in example.com/mod/b
replace example.com/mod/c => example.com/mod/c v1.2.0
```

To avoid the possibility of conflict, the `go` command ignores `replace`
directives in modules other than the main module.

Modules are intended to scale to a large ecosystem, and in order for upgrades
to be safe, fast, and predictable, some rules must be followed, like semantic
versioning and [import compatibility](https://research.swtch.com/vgo-import).
Not relying on `replace` is one of these rules.

### How can module authors avoid `replace`?

`replace` is useful in several situations for local or short-term development,
for example:

* Changing multiple modules concurrently.
* Using a short-term fork of a dependency until a change is merged upstream.
* Using an old version of a dependency because a new version is broken.
* Working around migration problems, like `golang.org/x/lint` imported as
  `github.com/golang/lint`. Many of these problems should be fixed by lazy
  module loading ([#36460](https://golang.org/issue/36460)).

`replace` is safe to use in a module that is not depended on by other modules.
It's also safe to use in revisions that aren't depended on by other modules.

* If a `replace` directive is just meant for temporary local development by one
  person, avoid checking it in. The `-modfile` flag may be used to build with
  an alternative `go.mod` file. See also
  [#26640](https://golang.org/issue/26640) a feature request for a
  `go.mod.local` file containing replacements and other local modifications.
* If a `replace` directive must be checked in to fix a short-term problem,
  ensure at least one release or pre-release version is tagged before checking
  it in. Don't tag a new release version with `replace` checked in (pre-release
  versions may be okay, depending on how they're used). When the `go` command
  looks for a new version of a module (for example, when running `go get` with
  no version specified), it will prefer release versions. Tagging versions lets
  you continue development on the main branch without worrying about users
  fetching arbitrary commits.
* If a `replace` directive must be checked in to solve a long-term problem,
  consider solutions that won't cause issues for dependent modules. If possible,
  tag versions on a release branch with `replace` directives removed.

### When would `go install` be reproducible?

The new `go install` command will build an executable with the same set of
module versions on every invocation if both the following conditions are true:

* A specific version is requested in the command line argument, for example,
  `go install example.com/cmd/foo@v1.0.0`.
* Every package needed to build the executable is provided by a module required
  directly or indirectly by the `go.mod` file of the module providing the
  executable. If the executable only imports standard library packages or
  packages from its own module, no `go.mod` file is necessary.

An executable may not be bit-for-bit reproducible for other reasons. Debugging
information will include system paths (unless `-trimpath` is used). A package
may import different packages on different platforms (or may not build at all).
The installed Go version and the C toolchain may also affect binary
reproducibility.

### What happens if a module depends on a newer version of itself?

`go install` will report an error, as `go get` already does.

This sometimes happens when two modules depend on each other, and releases
are not tagged on the main branch. A command like `go get example.com/m@master`
will resolve `@master` to a pseudo-version lower than any release version.
The `go.mod` file at that pseudo-version may transitively depend on a newer
release version.

`go get` reports an error in this situation. In general, `go get` reports
an error when command line arguments different versions of the same module,
directly or indirectly. `go install` doesn't support this yet, but this should
be one of the conditions checked when running with version suffix arguments.

## Appendix: usage of replace directives

In this proposal, `go install` would report errors for `replace` directives in
the module providing packages named on the command line. `go get` ignores these,
but the behavior may still surprise module authors and users. I've tried to
estimate the impact on the existing set of open source modules.

* I started with a list of 359,040 `main` packages that Russ Cox built during an
earlier study.
* I excluded packages with paths that indicate they were homework, examples,
  tests, or experiments. 187,805 packages remained.
* Of these, I took a random sample of 19,000 packages (about 10%).
* These belonged to 13,874 modules. For each module, I downloaded the "latest"
  version `go get` would fetch.
* I discarded repositories that were forks or couldn't be retrieved. 10,618
  modules were left.
* I discarded modules that didn't have a `go.mod` file. 4,519 were left.
* Of these:
  * 3982 (88%) don't use `replace` at all.
  * 71 (2%) use directory `replace` only.
  * 439 (9%) use module `replace` only.
  * 27 (1%) use both.
  * In the set of 439 `go.mod` files using module `replace` only, I tried to
    classify why `replace` was used. A module may have multiple `replace`
    directives and multiple classifications, so the percentages below don't add
    to 100%.
  * 165 used `replace` as a soft fork, for example, to point to a bug fix PR
    instead of the original module.
  * 242 used `replace` to pin a specific version of a dependency (the module
    path is the same on both sides).
  * 77 used `replace` to rename a dependency that was imported with another
    name, for example, replacing `github.com/golang/lint` with the correct path,
    `golang.org/x/lint`.
  * 30 used `replace` to rename `golang.org/x` repos with their
    `github.com/golang` mirrors.
  * 11 used `replace` to bypass semantic import versioning.
  * 167 used `replace` with `k8s.io` modules. Kubernetes has used `replace` to
    bypass MVS, and dependent modules have been forced to do the same.
  * 111 modules contained `replace` directives I couldn't automatically
    classify. The ones I looked at seemed to mostly be forks or pins.

The modules I'm most concerned about are those that use `replace` as a soft fork
while submitting a bug fix to an upstream module; other problems have other
solutions that I don't think we need to design for here. Modules using soft fork
replacements are about 4% of the the modules with `go.mod` files I sampled (165
/ 4519). This is a small enough set that I think we should move forward with the
proposal above.
