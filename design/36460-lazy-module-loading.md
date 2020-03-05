# Proposal: Lazy Module Loading

Author: Bryan C. Mills (with substantial input from Russ Cox, Jay Conrod, and
Michael Matloob)

Last updated: 2020-02-20

Discussion at https://golang.org/issue/36460.

## Abstract

We propose to change `cmd/go` to avoid loading transitive module dependencies
that have no observable effect on the packages to be built.

The key insights that lead to this approach are:

1.  If _no_ package in a given dependency module is ever (even transitively)
    imported by any package loaded by an invocation of the `go` command, then an
    incompatibility between any package in that dependency and any other package
    has no observable effect in the resulting program(s). Therefore, we can
    safely ignore the (transitive) requirements of any module that does not
    contribute any package to the build.

2.  We can use the explicit requirements of the main module as a coarse filter
    on the set of modules relevant to the main module and to previous
    invocations of the `go` command.

Based on those insights, we propose to change the `go` command to retain more
transitive dependencies in `go.mod` files and to avoid loading `go.mod` files
for “irrelevant” modules, while still maintaining high reproducibility for build
and test operations.

## Background

In the initial implementation of modules, we attempted to make `go mod tidy`
prune out of the `go.mod` file any module that did not provide a transitive
import of the main module. However, that did not always preserve the remaining
build list: a module that provided no packages might still raise the minimum
requirement on some _other_ module that _did_ provide a package.

We addressed that problem in [CL 121304] by explicitly retaining requirements on
all modules that provide _directly-imported_ packages, _as well as_ a minimal
set of module requirement roots needed to retain the selected versions of
transitively-imported packages.

In [#29773] and [#31248], we realized that, due to the fact that the `go.mod`
file is pruned to remove indirect dependencies already implied by other
requirements, we must load the `go.mod` file for all versions of dependencies,
even if we know that they will not be selected — even including the main module
itself!

In [#30831] and [#34016], we learned that following deep history makes
problematic dependencies very difficult to completely eliminate. If the
repository containing a module is no longer available and the module is not
cached in a module mirror, then we will encounter an error when loading any
module — even a very old, irrelevant one! — that required it.

In [#26904], [#32058], [#33370], and [#34417], we found that the need to
consider every version of a module separately, rather than only the selected
version, makes the `replace` directive difficult to understand, difficult to use
correctly, and generally more complex than we would like it to be.

In addition, users have repeatedly expressed the desire to avoid the cognitive
overhead of seeing “irrelevant” transitive dependencies ([#26955], [#27900],
[#32380]), reasoning about older-than-selected transitive dependencies
([#36369]), and fetching large numbers of `go.mod` files ([#33669], [#29935]).

### Properties

In this proposal, we aim to achieve a property that we call <dfn>lazy
loading</dfn>:

*   In the steady state, an invocation of the `go` command should not load any
    `go.mod` file or source code for a module (other than the main module) that
    provides no _packages_ loaded by that invocation.

    *   In particular, if the selected version of a module is not changed by a
        `go` command, the `go` command should not load a `go.mod` file or source
        code for any _other_ version of that module.

We also want to preserve <dfn>reproducibility</dfn> of `go` command invocations:

*   An invocation of the `go` command should either load the same version of
    each package as every other invocation since the last edit to the `go.mod`
    file, or should edit the `go.mod` file in a way that causes the next
    invocation on any subset of the same packages to use the same versions.

## Proposal

### Invariants

We propose that, when the main module's `go.mod` file specifies `go 1.15` or
higher, every invocation of the `go` command should update the `go.mod` file to
maintain three invariants.

1.  (The <dfn>import invariant</dfn>.) The main module's `go.mod` file
    explicitly requires the selected version of every module that contains one
    or more packages that were transitively imported by any package in the main
    module.

2.  (The <dfn>argument invariant<dfn>.) The main module's `go.mod` file
    explicitly requires the selected version of every module that contains one
    or more packages that matched an explicit [package pattern] argument.

3.  (The <dfn>completeness invariant</dfn>.) The version of every module that
    contributed any package to the build is recorded in the `go.mod` file of
    either the main module itself or one of modules it requires explicitly.

The _completeness invariant_ alone is sufficient to ensure _reproducibility_ and
_lazy loading_. However, it is under-constrained: there are potentially many
_minimal_ sets of requirements that satisfy the completeness invariant, and even
more _valid_ solutions. The _import_ and _argument_ invariants guide us toward a
_specific_ solution that is simple and intuitive to explain in terms of the `go`
commands invoked by the user.

If the main module satisfies the _import_ and _argument_ invariants, and all
explicit module dependencies also satisfy the import invariant, then the
_completeness_ invariant is also trivially satisfied. Given those, the
completeness invariant exists only in order to tolerate _incomplete_
dependencies.

If the import invariant or argument invariant holds at the start of a `go`
invocation, we can trivially preserve that invariant (without loading any
additional packages or modules) at the end of the invocation by updating the
`go.mod` file with explicit versions for all module paths that were already
present, in addition to any new main-module imports or package arguments found
during the invocation.

### Module loading procedure

At the start of each operation, we load all of the explicit requirements from
the main module's `go.mod` file.

If we encounter an import from any module that is not already _explicitly_
required by the main module, we perform a <dfn>deepening scan</dfn>. To perform
a deepening scan, we read the `go.mod` file for each module explicitly required
by the main module, and add its requirements to the build list. If any
explicitly-required module uses `go 1.14` or earlier, we also read the `go.mod`
files for all of that module's (transitive) module dependencies.

(The deepening scan allows us to detect changes to the import graph without
loading the whole graph explicitly: if we encounter a new import from within a
previously-irrelevant package, the deepening scan will re-read the requirements
of the module containing that package, and will ensure that the selected version
of that import is compatible with all other relevant packages.)

As we load each imported package, we also read the `go.mod` file for the module
containing that package and add its requirements to the build list — even if
that version of the module was already explicitly required by the main module.

(This step is theoretically redundant: the requirements of the main module will
already reflect any relevant dependencies, and the _deepening scan_ will catch
any previously-irrelevant dependencies that subsequently _become_ relevant.
However, reading the `go.mod` file for each imported package makes the `go`
command much more robust to inconsistencies in the `go.mod` file — including
manual edits, erroneous version-control merge resolutions, incomplete
dependencies, and changes in `replace` directives and replacement directory
contents.)

If, after the _deepening scan,_ the package to be imported is still not found in
any module in the build list, we resolve the `latest` version of a module
containing that package and add it to the build list (following the same search
procedure as in Go 1.14), then perform another deepening scan (this time
including the newly added-module) to ensure consistency.

### The `all` pattern and `mod` subcommands

#### In Go 1.11–1.14

In module mode in Go 1.11–1.14, the `all` package pattern matches each package
reachable by following imports _and tests of imported packages_ recursively,
starting from the packages in the main module. (It is equivalent to the set of
packages obtained by iterating `go list -deps -test ./...` over its own output
until it reaches a fixed point.)

`go mod tidy` adjusts the `go.mod` and `go.sum` files so that the main module
transitively requires a set of modules that provide every package matching the
`all` package pattern, independent of build tags. After `go mod tidy`, every
package matching the `all` _package_ pattern is provided by some module matching
the `all` _module_ pattern.

`go mod tidy` also updates a set of `// indirect` comments indicating versions
added or upgraded beyond what is implied by transitive dependencies.

`go mod download` downloads all modules matching the `all` _module_ pattern,
which normally includes a module providing every package in the `all` _package_
pattern.

In contrast, `go mod vendor` copies in only the subset of packages transitively
_imported by_ the packages and tests _in the main module_: it does not scan the
imports of tests outside of the main module, even if those tests are for
imported packages. (That is: `go mod vendor` only covers the packages directly
reported by `go list -deps -test ./...`.)

As a result, when using `-mod=vendor` the `all` and `...` patterns may match
substantially fewer packages than when using `-mod=mod` (the default) or
`-mod=readonly`.

<!-- Note: the behavior of `go mod vendor` was changed to its current form
during the `vgo` prototype, in https://golang.org/cl/122256. -->

#### The `all` package pattern and `go mod tidy`

We would like to preserve the property that, after `go mod tidy`, invocations of
the `go` command — including `go test` — are _reproducible_ (without changing
the `go.mod` file) for every package matching the `all` package pattern. The
_completeness invariant_ is what ensures reproducibility, so `go mod tidy` must
ensure that it holds.

Unfortunately, even if the _import invariant_ holds for all of the dependencies
of the main module, the current definition of the `all` pattern includes
_dependencies of tests of dependencies_, recursively. In order to establish the
_completeness invariant_ for distant test-of-test dependencies, `go mod tidy`
would sometimes need to record a substantial number of dependencies of tests
found outside of the main module in the main module's `go.mod` file.

Fortunately, we can omit those distant dependencies a different way: by changing
the definition of the `all` pattern itself, so that test-of-test dependencies
are no longer included. Feedback from users (in [#29935], [#26955], [#32380],
[#32419], [#33669], and perhaps others) has consistently favored omitting those
dependencies, and narrowing the `all` pattern would also establish a nice _new_
property: after running `go mod vendor`, the `all` package pattern with
`-mod=vendor` would now match the `all` pattern with `-mod=mod`.

Taking those considerations into account, we propose that the `all` package
pattern in module mode should match only the packages transitively _imported by_
packages and tests in the main module: that is, exactly the set of packages
preserved by `go mod vendor`. Since the `all` pattern is based on package
imports (more-or-less independent of module dependencies), this change should be
independent of the `go` version specified in the `go.mod` file.

The behavior of `go mod tidy` should change depending on the `go` version. In a
module that specifies `go 1.15` or later, `go mod tidy` should scan the packages
matching the new definition of `all`, ignoring build tags. In a module that
specifies `go 1.14` or earlier, it should continue to scan the packages matching
the _old_ definition (still ignoring build tags). (Note that both of those sets
are supersets of the new `all` pattern.)

#### The `all` and `...` module patterns and `go mod download`

In Go 1.11–1.14, the `all` module pattern matches each module reachable by
following module requirements recursively, starting with the main module and
visiting every version of every module encountered. The module pattern `...` has
the same behavior.

The `all` module pattern is important primarily because it is the default set of
modules downloaded by the `go mod download` subcommand, which sets up the local
cache for offline use. However, it (along with `...`) is also currently used by
a few other tools (such as `go doc`) to locate “modules of interest” for other
purposes.

Unfortunately, these patterns as defined in Go 1.11–1.14 are _not compatible
with lazy loading:_ they examine transitive `go.mod` files without loading any
packages. Therefore, in order to achieve lazy loading we must change their
behavior.

Since we want to compute the list of modules without loading any packages or
irrelevant `go.mod` files, we propose that when the main module's `go.mod` file
specifies `go 1.15` or higher, the `all` and wildcard module patterns should
match only those modules found in a _deepening scan_ of the main module's
dependencies. That definition includes every module whose version is
reproducible due to the _completeness invariant,_ including modules needed by
tests of transitive imports.

With this redefinition of the `all` module pattern, and the above redefinition
of the `all` package pattern, we again have the property that, after `go mod
tidy && go mod download all`, invoking `go test` on any package within `all`
does not need to download any new dependencies.

Since the `all` pattern includes every module encountered in the deepening scan,
rather than only those that provide imported packages, `go mod download` may
continue to download more source code than is strictly necessary to build the
packages in `all`. However, as is the case today, users may download only that
narrower set as a side effect of invoking `go list all`.

### Effect on `go.mod` size

Under this approach, the set of modules recorded in the `go.mod` file would in
most cases increase beyond the set recorded in Go 1.14. However, the set of
modules recorded in the `go.sum` file would decrease: irrelevant modules would
no longer be included.

-   The modules recorded in `go.mod` under this proposal would be a strict
    subset of the set of modules recorded in `go.sum` in Go 1.14.

    -   The set of recorded modules would more closely resemble a “lock” file as
        used in other dependency-management systems. (However, the `go` command
        would still not require a separate “manifest” file, and unlike a lock
        file, the `go.mod` file would still be updated automatically to reflect
        new requirements discovered during package loading.)

-   For modules with _few_ test-of-test dependencies, the `go.mod` file after
    running `go mod tidy` will typically be larger than in Go 1.14. For modules
    with _many_ test-of-test dependencies, it may be substantially smaller.

-   For modules that are _tidy:_

    -   The module versions recorded in the `go.mod` file would be exactly those
        listed in `vendor/modules.txt`, if present.

    -   The module versions recorded in `vendor/modules.txt` would be the same
        as under Go 1.14, although the `## explicit` annotations could perhaps
        be removed (because _all_ relevant dependencies would be recorded
        explicitly).

    -   The module versions recorded in the `go.sum` file would be exactly those
        listed in the `go.mod` file.

## Compatibility

The `go.mod` file syntax and semantics proposed here are backward compatible
with previous Go releases: all `go.mod` files for existing `go` versions would
retain their current meaning.

Under this proposal, a `go.mod` file that specifies `go 1.15` or higher will
cause the `go` command to lazily load the `go.mod` files for its requirements.
When reading a `go 1.15` file, previous versions of the `go` command (which do
not prune irrelevant dependencies) may select _higher_ versions than those
selected under this proposal, by following otherwise-irrelevant dependency
edges. However, because the `require` directive continues to specify a minimum
version for the required dependency, a previous version of the `go` command will
never select a _lower_ version of any dependency.

Moreover, any strategy that prunes out a dependency as interpreted by a previous
`go` version will continue to prune out that dependency as interpreted under
this proposal: module maintainers will not be forced to break users on new `go`
versions in order to support users on older versions (or vice-versa).

Versions of the `go` command before 1.14 do not preserve the proposed invariants
for the main module: if `go` command from before 1.14 is run in a `go 1.15`
module, it may automatically remove requirements that are now needed. However,
as a result of [CL 204878], `go` version 1.14 does preserve those invariants in
all subcommands except for `go mod tidy`: Go 1.14 users will be able to work (in
a limited fashion) within a Go 1.15 main module without disrupting its
invariants.

## Implementation

`bcmills` is working on a prototype of this design for `cmd/go` in Go 1.15.

At this time, we do not believe that any other tooling changes will be needed.

## Open issues

Because `go mod tidy` will now preserve seemingly-redundant requirements, we may
find that we want to expand or update the `// indirect` comments that it
currently manages. For example, we may want to indicate “indirect dependencies
at implied versions” separately from “upgraded or potentially-unused indirect
dependencies”, and we may want to indicate “direct or indirect dependencies of
tests” separately from “direct or indirect dependencies of non-tests”.

Since these comments do not have a semantic effect, we can fine-tune them after
implementation (based on user feedback) without breaking existing modules.

## Examples

The following examples illustrate the proposed behavior using the `cmd/go`
[script test] format. For local testing and exploration, the test files can be
extracted using the [`txtar`] tool.

### Importing a new package from an existing module dependency

```txtar
cp go.mod go.mod.old
go mod tidy
cmp go.mod go.mod.old

# Before adding a new import, the go.mod file should
# enumerate modules for all packages already imported.

go list all
cmp go.mod go.mod.old

# When a new import is found, we should perform a deepening scan of the existing
# dependencies and add a requirement on the version required by those
# dependencies — not re-resolve 'latest'.

cp lazy.go.new lazy.go
go list all
cmp go.mod go.mod.new

-- go.mod --
module example.com/lazy

go 1.15

require (
    example.com/a v0.1.0
    example.com/b v0.1.0 // indirect
)

replace (
    example.com/a v0.1.0 => ./a
    example.com/b v0.1.0 => ./b
    example.com/c v0.1.0 => ./c1
    example.com/c v0.2.0 => ./c2
)
-- lazy.go --
package lazy

import (
    _ "example.com/a/x"
)
-- lazy.go.new --
package lazy

import (
    _ "example.com/a/x"
    _ "example.com/a/y"
)
-- go.mod.new --
module example.com/lazy

go 1.15

require (
    example.com/a v0.1.0
    example.com/b v0.1.0 // indirect
    example.com/c v0.1.0 // indirect
)

replace (
    example.com/a v0.1.0 => ./a
    example.com/b v0.1.0 => ./b
    example.com/c v0.1.0 => ./c1
    example.com/c v0.2.0 => ./c2
)
-- a/go.mod --
module example.com/a

go 1.15

require (
    example.com/b v0.1.0
    example.com/c v0.1.0
)
-- a/x/x.go --
package x
import _ "example.com/b"
-- a/y/y.go --
package y
import _ "example.com/c"
-- b/go.mod --
module example.com/b

go 1.15
-- b/b.go --
package b
-- c1/go.mod --
module example.com/c

go 1.15
-- c1/c.go --
package c
-- c2/go.mod --
module example.com/c

go 1.15
-- c2/c.go --
package c
```

### Testing an imported package found in another module

```txtar
cp go.mod go.mod.old
go mod tidy
cmp go.mod go.mod.old

# 'go list -m all' should include modules that cover the test dependencies of
# the packages imported by the main module, found via a deepening scan.

go list -m all
stdout 'example.com/b v0.1.0'
! stdout example.com/c
cmp go.mod go.mod.old

# 'go test' of any package in 'all' should use its existing dependencies without
# updating the go.mod file.

go list all
stdout example.com/a/x

go test example.com/a/x
cmp go.mod go.mod.old

-- go.mod --
module example.com/lazy

go 1.15

require example.com/a v0.1.0

replace (
    example.com/a v0.1.0 => ./a
    example.com/b v0.1.0 => ./b1
    example.com/b v0.2.0 => ./b2
    example.com/c v0.1.0 => ./c
)
-- lazy.go --
package lazy

import (
    _ "example.com/a/x"
)
-- a/go.mod --
module example.com/a

go 1.15

require example.com/b v0.1.0
-- a/x/x.go --
package x
-- a/x/x_test.go --
package x

import (
    "testing"

    _ "example.com/b"
)

func TestUsingB(t *testing.T) {
    // …
}
-- b1/go.mod --
module example.com/b

go 1.15

require example.com/c v0.1.0
-- b1/b.go --
package b
-- b1/b_test.go --
package b

import _ "example.com/c"
-- b2/go.mod --
module example.com/b

go 1.15

require example.com/c v0.1.0
-- b2/b.go --
package b
-- b2/b_test.go --
package b

import _ "example.com/c"
-- c/go.mod --
module example.com/c

go 1.15
-- c/c.go --
package c
```

### Testing an unimported package found in an existing module dependency

```txtar
cp go.mod go.mod.old
go mod tidy
cmp go.mod go.mod.old

# 'go list -m all' should include modules that cover the test dependencies of
# the packages imported by the main module, found via a deepening scan.

go list -m all
stdout 'example.com/b v0.1.0'
cmp go.mod go.mod.old

# 'go test all' should use those existing dependencies without updating the
# go.mod file.

go test all
cmp go.mod go.mod.old

-- go.mod --
module example.com/lazy

go 1.15

require (
    example.com/a v0.1.0
)

replace (
    example.com/a v0.1.0 => ./a
    example.com/b v0.1.0 => ./b1
    example.com/b v0.2.0 => ./b2
    example.com/c v0.1.0 => ./c
)
-- lazy.go --
package lazy

import (
    _ "example.com/a/x"
)
-- a/go.mod --
module example.com/a

go 1.15

require (
    example.com/b v0.1.0
)
-- a/x/x.go --
package x
-- a/x/x_test.go --
package x

import _ "example.com/b"

func TestUsingB(t *testing.T) {
    // …
}
-- b1/go.mod --
module example.com/b

go 1.15
-- b1/b.go --
package b
-- b1/b_test.go --
package b

import _ "example.com/c"
-- b2/go.mod --
module example.com/b

go 1.15

require (
    example.com/c v0.1.0
)
-- b2/b.go --
package b
-- b2/b_test.go --
package b

import _ "example.com/c"
-- c/go.mod --
module example.com/c

go 1.15
-- c/c.go --
package c
```

### Testing a package imported from a `go 1.14` dependency

```txtar
cp go.mod go.mod.old
go mod tidy
cmp go.mod go.mod.old

# 'go list -m all' should include modules that cover the test dependencies of
# the packages imported by the main module, found via a deepening scan.

go list -m all
stdout 'example.com/b v0.1.0'
stdout 'example.com/c v0.1.0'
cmp go.mod go.mod.old

# 'go test' of any package in 'all' should use its existing dependencies without
# updating the go.mod file.
#
# In order to satisfy reproducibility for the loaded packages, the deepening
# scan must follow the transitive module dependencies of 'go 1.14' modules.

go list all
stdout example.com/a/x

go test example.com/a/x
cmp go.mod go.mod.old

-- go.mod --
module example.com/lazy

go 1.15

require example.com/a v0.1.0

replace (
    example.com/a v0.1.0 => ./a
    example.com/b v0.1.0 => ./b
    example.com/c v0.1.0 => ./c1
    example.com/c v0.2.0 => ./c2
)
-- lazy.go --
package lazy

import (
    _ "example.com/a/x"
)
-- a/go.mod --
module example.com/a

go 1.14

require example.com/b v0.1.0
-- a/x/x.go --
package x
-- a/x/x_test.go --
package x

import (
    "testing"

    _ "example.com/b"
)

func TestUsingB(t *testing.T) {
    // …
}
-- b/go.mod --
module example.com/b

go 1.14

require example.com/c v0.1.0
-- b/b.go --
package b

import _ "example.com/c"
-- c1/go.mod --
module example.com/c

go 1.14
-- c1/c.go --
package c
-- c2/go.mod --
module example.com/c

go 1.14
-- c2/c.go --
package c
```

<!-- References -->

[package pattern]: https://tip.golang.org/cmd/go/#hdr-Package_lists_and_patterns
    "go — Package lists and patterns"
[script test]: https://go.googlesource.com/go/+/refs/heads/master/src/cmd/go/testdata/script/README
    "src/cmd/go/testdata/script/README"
[`txtar`]: https://pkg.go.dev/golang.org/x/exp/cmd/txtar
    "golang.org/x/exp/cmd/txtar"
[CL 121304]: https://golang.org/cl/121304
    "cmd/go/internal/vgo: track directly-used vs indirectly-used modules"
[CL 122256]: https://golang.org/cl/122256
    "cmd/go/internal/modcmd: drop test sources and data from mod -vendor"
[CL 204878]: https://golang.org/cl/204878
    "cmd/go: make commands other than 'tidy' prune go.mod less aggressively"
[#26904]: https://golang.org/issue/26904
    "cmd/go: allow replacement modules to alias other active modules"
[#27900]: https://golang.org/issue/27900
    "cmd/go: 'go mod why' should have an answer for every module in 'go list -m all'"
[#29773]: https://golang.org/issue/29773
    "cmd/go: 'go list -m' fails to follow dependencies through older versions of the main module"
[#29935]: https://golang.org/issue/29935
    "x/build: reconsider the large number of third-party dependencies"
[#26955]: https://golang.org/issue/26955
    "cmd/go: provide straightforward way to see non-test dependencies"
[#30831]: https://golang.org/issue/30831
    "cmd/go: 'get -u' stumbles over repos imported via non-canonical paths"
[#31248]: https://golang.org/issue/31248
    "cmd/go: mod tidy removes lines that build seems to need"
[#32058]: https://golang.org/issue/32058
    "cmd/go: replace directives are not thoroughly documented"
[#32380]: https://golang.org/issue/32380
    "cmd/go: don't add dependencies of external tests"
[#32419]: https://golang.org/issue/32419
    "proposal: cmd/go: conditional/optional dependency for go mod"
[#33370]: https://golang.org/issue/33370
    "cmd/go: treat pseudo-version 'vX.0.0-00010101000000-000000000000' as equivalent to an empty commit"
[#33669]: https://golang.org/issue/33669
    "cmd/go: fetching dependencies can be very aggressive when going via an HTTP proxy"
[#34016]: https://golang.org/issue/34016
    "cmd/go: 'go list -m all' hangs for git.apache.org"
[#34417]: https://golang.org/issue/34417
    "cmd/go: do not allow the main module to replace (to or from) itself"
[#34822]: https://golang.org/issue/34822
    "cmd/go: do not update 'go.mod' automatically if the changes are only cosmetic"
[#36369]: https://golang.org/issue/36369
    "cmd/go: dependencies in go.mod of older versions of modules in require cycles affect the current version's build"
