# Proposal: Versioned Go Modules

Author: Russ Cox\
Last Updated: March 20, 2018\
Discussion: https://golang.org/issue/24301

## Abstract

We propose to add awareness of package versions to the Go toolchain, especially the `go` command.

## Background

The first half of the blog post [Go += Package Versioning](https://research.swtch.com/vgo-intro) presents detailed background for this change.
In short, it is long past time to add versions to the working vocabulary of both Go developers and our tools,
and this proposal describes a way to do that.

[Semantic versioning](https://semver.org) is the name given to an established convention for assigning version numbers
to projects. 
In its simplest form, a version number is MAJOR.MINOR.PATCH, where MAJOR, MINOR, and PATCH
are decimal numbers. 
The syntax used in this proposal follows the widespread convention of 
adding a “v” prefix: vMAJOR.MINOR.PATCH.
Incrementing MAJOR indicates an expected breaking change.
Otherwise, a later version is expected to be backwards compatible
with earlier versions within the same MAJOR version sequence.
Incrementing MINOR indicates a significant change or new features.
Incrementing PATCH is meant to be reserved for very small, very safe changes,
such as small bug fixes or critical security patches.

The sequence of [vgo-related blog posts](https://research.swtch.com/vgo) presents more detail
about the proposal.

## Proposal

I propose to add versioning to Go using the following approach.

1. Introduce the concept of a _Go module_, which is a group of
   packages that share a common prefix, the _module path_, and are versioned together as a single unit.
   Most projects will adopt a workflow in which a version-control repository
   corresponds exactly to a single module.
   Larger projects may wish to adopt a workflow in which a
   version-control repository can hold multiple modules.
   Both workflows will be supported.

2. Assign version numbers to modules by tagging specific commits
   with [semantic versions](https://semver.org) such as `v1.2.0`.
   (See
   the [Defining Go Modules](https://research.swtch.com/vgo-module) post
   for details, including how to tag multi-module repositories.)

3. Adopt [semantic import versioning](https://research.swtch.com/vgo-import),
   in which each major version has a distinct import path.
   Specifically, an import path contains a module path, a version number,
   and the the path to a specific package inside the module.
   If the major version is v0 or v1, then the version number element
   must be omitted; otherwise it must be included.
   
   <p style="text-align:center">
   <img width=343 height=167 src="24301/impver.png" srcset="24301/impver.png 1x, 24301/impver@1.5x.png 1.5x, 24301/impver@2x.png 2x, 24301/impver@3x.png 3x, 24301/impver@4x.png 4x">
   </p>
   
   The packages imported as `my/thing/sub/pkg`, `my/thing/v2/sub/pkg`, and `my/thing/v3/sub/pkg`
   come from major versions v1, v2, and v3 of the module `my/thing`,
   but the build treats them simply as three different packages.
   A program that imports all three will have all three linked into the final binary,
   just as if they were `my/red/pkg`, `my/green/pkg`, and `my/blue/pkg`
   or any other set of three different import paths.
   
   Note that only the major version appears in the import path: `my/thing/v1.2/sub/pkg` is not allowed.
   
   
4. Explicitly adopt the “import compatibility rule”:

   > _If an old package and a new package have the same import path,_\
   > _the new package must be backwards compatible with the old package._
   
   The Go project has encouraged this convention from the start
   of the project, but this proposal gives it more teeth:
   upgrades by package users will succeed or fail
   only to the extent that package authors follow the import
   compatibility rule.
   
   The import compatibility rule only applies to tagged
   releases starting at v1.0.0.
   Prerelease (vX.Y.Z-anything) and v0.Y.Z versions
   need not follow compatibility with earlier versions,
   nor do they impose requirements on future versions.
   In contrast, tagging a commit vX.Y.Z for X ≥ 1 explicitly
   indicates “users can expect this module to be stable.”

   In general, users should expect a module to follow
   the [Go 1 compatibility rules](https://golang.org/doc/go1compat#expectations)
   once it reaches v1.0.0,
   unless the module's documentation clearly states exceptions.
   
5. Record each module's path and dependency requirements in a
   [`go.mod` file](XXX) stored in the root of the module's file tree.

6. To decide which module versions to use in a given build,
   apply [minimal version selection](https://research.swtch.com/vgo-mvs):
   gather the transitive closure of all the listed requirements
   and then remove duplicates of a given major version of a module
   by keeping the maximum requested version,
   which is also the minimum version satisfying all listed requirements.
   
   Minimal version selection has two critical properties.
   First, it is trivial to implement and understand.
   Second, it never chooses a module version not listed in some `go.mod` file
   involved in the build: new versions are not incorporated
   simply because they have been published.
   The second property produces [high-fidelity builds](XXX)
   and makes sure that upgrades only happen when 
   developers request them, never unexpectedly.

7. Define a specific zip file structure as the 
   “interchange format” for Go modules.
   The vast majority of developers will work directly with
   version control and never think much about these zip files,
   if at all, but having a single representation
   enables proxies, simplifies analysis sites like godoc.org
   or continuous integration, and likely enables more
   interesting tooling not yet envisioned.

8. Define a URL schema for fetching Go modules from proxies,
   used both for installing modules using custom domain names
   and also when the `$GOPROXY` environment variable is set.
   The latter allows companies and individuals to send all 
   module download requests through a proxy for security,
   availability, or other reasons.

9. Allow running the `go` command in file trees outside GOPATH,
   provided there is a `go.mod` in the current directory or a
   parent directory.
   That `go.mod` file defines the mapping from file system to import path
   as well as the specific module versions used in the build.
   See the [Versioned Go Commands](https://research.swtch.com/vgo-cmd) post for details.

10. Disallow use of `vendor` directories, except in one limited use:
   a `vendor` directory at the top of the file tree of the top-level module
   being built is still applied to the build,
   to continue to allow self-contained application repositories.
   (Ignoring other `vendor` directories ensures that
   Go returns to builds in which each import path has the same
   meaning throughout the build
   and establishes that only one copy of a package with a given import
   path is used in a given build.)

The “[Tour of Versioned Go](https://research.swtch.com/vgo-tour)”
blog post demonstrates how most of this fits together to create a smooth user experience.

## Rationale

Go has struggled with how to incorporate package versions since `goinstall`,
the predecessor to `go get`, was released eight years ago.
This proposal is the result of eight years of experience with `goinstall` and `go get`,
careful examination of how other languages approach the versioning problem,
and lessons learned from Dep, the experimental Go package management tool released in January 2017.

A few people have asked why we should add the concept of versions to our tools at all.
Packages do have versions, whether the tools understand them or not.
Adding explicit support for versions
lets tools and developers communicate more clearly when
specifying a program to be built, run, or analyzed.

At the start of the process that led to this proposal, almost two years ago,
we all believed the answer would be to follow the package versioning approach
exemplified by Ruby's Bundler and then Rust's Cargo:
tagged semantic versions,
a hand-edited dependency constraint file known as a manifest,
a machine-generated transitive dependency description known as a lock file,
a version solver to compute a lock file satisfying the manifest,
and repositories as the unit of versioning.
Dep, the community effort led by Sam Boyer, follows this plan almost exactly
and was originally intended to serve as the model for `go` command
integration.
Dep has been a significant help for Go developers
and a positive step for the Go ecosystem.

Early on, we talked about Dep simply becoming `go dep`,
serving as the prototype of `go` command integration.
However, the more I examined the details of the Bundler/Cargo/Dep
approach and what they would mean for Go, especially built into the `go` command,
a few of the details seemed less and less a good fit.
This proposal adjusts those details in the hope of 
shipping a system that is easier for developers to understand
and to use.

### Semantic versions, constraints, and solvers

Semantic versions are a reasonable convention for
specifying software versions,
and version control tags written as semantic versions
have a clear meaning,
but the [semver spec](https://semver.org/) critically does not
prescribe how to build a system using them.
What tools should do with the version information?
Dave Cheney's 2015 [proposal to adopt semantic versioning](https://golang.org/issue/12302)
was eventually closed exactly because, even though everyone
agreed semantic versions seemed like a good idea,
we didn't know the answer to the question of what to do with them.

The Bundler/Cargo/Dep approach is one answer.
Allow authors to specify arbitrary constraints on their dependencies.
Build a given target by collecting all its dependencies
recursively and finding a configuration satisfying all those
constraints.

Unfortunately, the arbitrary constraints make finding a 
satisfying configuration very difficult.
There may be many satisfying configurations, with no clear way to choose just one.
For example, if the only two ways to build A are by using B 1 and C 2 
or by using B 2 and C 1, which should be preferred, and how should developers remember?
Or there may be no satisfying configuration.
Also, it can be very difficult to tell whether there are many, one, or no
satisfying configurations:
allowing arbitrary constraints makes
version solving problem an NP-complete problem,
[equivalent to solving SAT](https://research.swtch.com/version-sat).
In fact, most package managers now rely on SAT solvers
to decide which packages to install.
But the general problem remains:
there may be many equally good configurations,
with no clear way to choose between them,
there may be a single best configuration,
or there may be no good configurations,
and it can be very expensive to determine
which is the case in a given build.

This proposal's approach is a new answer, in which authors can specify
only limited constraints on dependencies: only the minimum required versions.
Like in Bundler/Cargo/Dep, this proposal builds a given target by
collecting all dependencies recursively and then finding
a configuration satisfying all constraints.
However, unlike in Bundler/Cargo/Dep, the process of finding a
satisfying configuration is trivial.
As explained in the [minimal version selection](https://research.swtch.com/vgo-mvs) post,
a satisfying configuration always exists,
and the set of satisfying configurations forms a lattice with
a unique minimum.
That unique minimum is the configuration that uses exactly the
specified version of each module, resolving multiple constraints
for a given module by selecting the maximum constraint, 
or equivalently the minimum version that satisfies all constraints.
That configuration is trivial to compute and easy for developers
to understand and predict.

### Build Control

A module's dependencies must clearly be given some control over that module's build.
For example, if A uses dependency B, which uses a feature of dependency C introduced in C 1.5,
B must be able to ensure that A's build uses C 1.5 or later.

At the same time, for builds to remain predictable and understandable, 
a build system cannot give dependencies arbitrary, fine-grained control
over the top-level build.
That leads to conflicts and surprises.
For example, suppose B declares that it requires an even version of D, while C declares that it requires a prime version of D.
D is frequently updated and is up to D 1.99.
Using B or C in isolation, it's always possible to use a relatively recent version of D (D 1.98 or D 1.97, respectively).
But when A uses both B and C,
a SAT solver-based build silently selects the much older (and buggier) D 1.2 instead.
To the extent that SAT solver-based build systems actually work,
it is because dependencies don't choose to exercise this level of control.
But then why allow them that control in the first place?

Although the hypothetical about prime and even versions is clearly unlikely, 
real problems do arise.
For example, issue [kubernetes/client-go#325](https://github.com/kubernetes/client-go/issues/325) was filed in November 2017,
complaining that the Kubernetes Go client pinned builds to a specific version of `gopkg.in/yaml.v2` from
September 2015, two years earlier.
When a developer tried to use
a new feature of that YAML library in a program that already
used the Kubernetes Go client,
even after attempting to upgrade to the latest possible version,
code using the new feature failed to compile,
because “latest” had been constrained by the Kubernetes requirement.
In this case, the use of a two-year-old YAML library version may be entirely reasonable within the context of the Kubernetes code base,
and clearly the Kubernetes authors should have complete
control over their own builds,
but that level of control does not make sense to extend to other developers' builds.
The issue was closed after a change in February 2018
to update the specific YAML version pinned to one from July 2017.
But the issue is not really “fixed”:
Kubernetes still pins a specific, increasingly old version of the YAML library.
The fundamental problem is that the build system
allows the Kubernetes Go client to do this at all,
at least when used as a dependency in a larger build.

This proposal aims to balance
allowing dependencies enough control to ensure a successful
build with not allowing them so much control that they break the build.
Minimum requirements combine without conflict,
so it is feasible (even easy) to gather them from all dependencies,
and they make it impossible to pin older versions,
as Kubernetes does.
Minimal version selection gives
the top-level module in the build additional control,
allowing it to exclude specific module versions
or replace others with different code,
but those exclusions and replacements only apply
when found in the top-level module, not when the module
is a dependency in a larger build.

A module author is therefore in complete control of
that module's build when it is the main program being built,
but not in complete control of other users' builds that depend on the module.
I believe this distinction will make this proposal
scale to much larger, more distributed code bases than 
the Bundler/Cargo/Dep approach.

### Ecosystem Fragmentation

Allowing all modules involved in a build to impose arbitrary
constraints on the surrounding build harms not just that build
but the entire language ecosystem.
If the author of popular package P finds that
dependency D 1.5 has introduced a change that
makes P no longer work,
other systems encourage the author of P to issue
a new version that explicitly declares it needs D < 1.5.
Suppose also that popular package Q is eager to take
advantage of a new feature in D 1.5
and issues a new version that explicitly declares it needs D ≥ 1.6.
Now the ecosystem is divided, and programs must choose sides:
are they P-using or Q-using? They cannot be both.

In contrast, being allowed to specify only a minimum required version
for a dependency makes clear that P's author must either
(1) release a new, fixed version of P;
(2) contact D's author to issue a fixed D 1.6 and then release a new P declaring a requirement on D 1.6 or later;
or else (3) start using a fork of D 1.4 with a different import path.
Note the difference between a new P that requires “D before 1.5”
compared to “D 1.6 or later.”
Both avoid D 1.5, but “D before 1.5” explains only which builds fail,
while “D 1.6 or later” explains how to make a build succeed.

### Semantic Import Versions

The example of ecosystem fragmentation in the previous section
is worse when it involves major versions.
Suppose the author of popular package P has used D 1.X as a dependency,
and then popular package Q decides to update to D 2.X because it 
is a nicer API.
If we adopt Dep's semantics,
now the ecosystem is again divided, and programs must again choose sides:
are they P-using (D 1.X-using) or Q-using (D 2.X-using)?
They cannot be both.
Worse,
in this case, because D 1.X and D 2.X are different major versions
with different APIs, it is completely reasonable for the author of P
to continue to use D 1.X, which might even continue to be updated with
features and bug fixes.
That continued usage only prolongs the divide.
The end result is that
a widely-used package like D would in practice either
be practically prohibited from issue version 2 or 
else split the ecosystem in half by doing so.
Neither outcome is desirable.

Rust's Cargo makes a different choice from Dep.
Cargo allows each package to specify whether
a reference to D means D 1.X or D 2.X.
Then, if needed, Cargo links both a D 1.X and a D 2.X into the final binary.
This approach works better than Dep's,
but users can still get stuck.
If P exposes D 1.X in its own API and Q exposes D 2.X in its own API,
then a single client package C cannot use both P and Q,
because it will not be able to refer to both D 1.X (when using P)
and D 2.X (when using Q).
The [dependency story](https://research.swtch.com/vgo-import) in the semantic import versioning post
presents an equivalent scenario in more detail.
In that story, the base package manager starts out being like Dep,
and the `-fmultiverse` flag makes it more like Cargo.

If Cargo is one step away from Dep, semantic import versioning is two steps away.
In addition to allowing different major versions to be used
in a single build,
semantic import versioning gives the different major versions different names,
so that there's never any ambiguity
about which is meant in a given program file.
Making the import paths precise about the expected
semantics of the thing being imported (is it v1 or v2?)
eliminates the possibility of problems like those client C experienced
in the previous example.

More generally, in semantic import versioning,
an import of `my/thing` asks for the semantics of v1.X of `my/thing`.
As long as `my/thing` is following the import compatibility rule,
that's a well-defined set of functionality,
satisfied by the latest v1.X and possibly earlier ones
(as constrained by `go.mod`).
Similarly, an import of `my/thing/v2` asks for the semantics of v2.X of `my/thing`,
satisfied by the latest v2.X and possibly earlier ones
(again constrained by `go.mod`).
The meaning of the imports is clear, to both people and tools,
from reading only the Go source code,
without reference to `go.mod`.
If instead we followed the Cargo approach, both imports would be `my/thing`, and the 
meaning of that import would be ambiguous from the source code alone,
resolved only by reading `go.mod`.

Our article “[About the go command](https://golang.org/doc/articles/go_command.html)” explains:

> An explicit goal for Go from the beginning was to be able to build Go code
> using only the information found in the source itself, not needing to write 
> a makefile or one of the many modern replacements for makefiles.
> If Go needed a configuration file to explain how to build your program,
> then Go would have failed.

It is an explicit goal of this proposal's design to preserve this property,
to avoid making the general semantics of a Go source file change depending on
the contents of `go.mod`. 
With semantic import versioning, if `go.mod` is deleted and
recreated from scratch, the effect is only to possibly update
to newer versions of imported packages, but still ones that are
still expected to work, thanks to import compatibility.
In contrast, if we take the Cargo approach, in which the `go.mod` file
must disambiguate between the arbitrarily different semantics of
v1 and v2 of `my/thing`, then `go.mod` becomes a required configuration file,
violating the original goal.

More generally, the main objection to adding `/v2/` to import paths is that
it's a bit longer, a bit ugly, and it makes explicit a semantically important
detail that other systems abstract away, which in turn induces more work for authors,
compared to other systems, when they change that detail.
But all of these were true when we introduced `goinstall`'s URL-like import paths,
and they've been a clear success.
Before `goinstall`, programmers wrote things like `import "igo/set"`.
To make that import work, you had to know to first check out `github.com/jacobsa/igo` into `$GOPATH/src/igo`.
The abbreviated paths had the benefit that if you preferred
a different version of `igo`, you could check your variant into
`$GOPATH/src/igo` instead, without updating any imports.
But the abbreviated imports also had the very real drawbacks that a build trying to use
both `igo/set` variants could not, and also that the Go source code did not record
anywhere exactly which `igo/set` it meant.
When `goinstall` introduced `import "github.com/jacobsa/igo/set"` instead,
that made the imports a bit longer and a bit ugly, 
but it also made explicit a semantically important detail:
exactly which `igo/set` was meant.
The longer paths created a little more work for authors compared
to systems that stashed that information in a single configuration file.
But eight years later, no one notices the longer import paths,
we've stopped seeing them as ugly,
and we now rely on the benefits of being explicit about
exactly which package is meant by a given import.
I expect that once `/v2/` elements in import paths are
common in Go source files, the same will happen:
we will no longer notice the longer paths,
we will stop seeing them as ugly, and we will rely on the benefits of 
being explicit about exactly which semantics are meant by a given import.

### Update Timing & High-Fidelity Builds

In the Bundler/Cargo/Dep approach, the package manager always prefers
to use the latest version of any dependency.
These systems use the lock file to override that behavior,
holding the updates back.
But lock files only apply to whole-program builds,
not to newly imported libraries.
If you are working on module A, and you add a new requirement on module B, which in turn requires module C,
these systems will fetch the latest of B and then also the latest of C.
In contrast, this proposal still fetches the latest of B (because it is
what you are adding to the project explicitly, and the default is to
take the latest of explicit additions) but then prefers to use the
exact version of C that B requires.
Although newer versions of C should work, it is safest to 
use the one that B did.
Of course, if the build has a different reason to use a newer version of C, it can do that.
For example, if A also imports D, which requires a newer C, then the build should and will use that newer version.
But in the absence of such an overriding requirement,
minimal version selection will build A using the exact version of C requested by B.
If, later, a new version of B is released requesting a newer version of C,
then when A updates to that newer B, 
C will be updated only to the version that the new B requires, not farther.
The [minimal version selection](https://research.swtch.com/vgo-mvs) blog post
refers to this kind of build as a “high-fidelity build.”

Minimal version selection has the key property that a recently-published version of C 
is never used automatically.
It is only used when a developer asks for it explicitly.
For example, the developer of A could ask for all dependencies, including transitive dependencies, to be updated.
Or, less directly, the developer of B could update C and release a new B,
and then the developer of A could update B.
But either way, some developer working on some package in the build must
take an explicit action asking for C to be updated,
and then the update does not take effect in A's build until
a developer working on A updates some dependency leading to C.
Waiting until an update is requested ensures that updates only happen
when developers are ready to test them and deal with the possibility
of breakage.

Many developers recoil at the idea that adding the latest B would not
automatically also add the latest C,
but if C was just released, there's no guarantee it works in this build.
The more conservative position is to avoid using it until the user asks.
For comparison, the Go 1.9 go command does not automatically start using Go 1.10
the day Go 1.10 is released.
Instead, users are expected to update on their own
schedule,
so that they can control when they take on the risk of things breaking.
The reasons not to update automatically to the latest Go release
applies even more to individual packages:
there are more of them,
and most are not tested for backwards compatibility
as extensively as Go releases are.

If a developer does want to update all dependencies to the latest version,
that's easy: `go get -u`. 
We may also add a `go get -p` that updates all dependencies to their
latest patch versions, so that C 1.2.3 might be updated to C 1.2.5 but not to C 1.3.0.
If the Go community as a whole reserved patch versions only for very safe
or security-critical changes, then that `-p` behavior might be useful.

## Compatibility

The work in this proposal is not constrained by 
the [compatibility guidelines](https://golang.org/doc/go1compat) at all.
Those guidelines apply to the language and standard library APIs, not tooling.
Even so, compatibility more generally is a critical concern.
It would be a serious mistake to deploy changes to the `go` command
in a way that breaks all existing Go code or splits the ecosystem into 
module-aware and non-module-aware packages.
On the contrary, we must make the transition as smooth and seamless as possible.

Module-aware builds can import non-module-aware packages
(those outside a tree with a `go.mod` file)
provided they are tagged with a v0 or v1 semantic version.
They can also refer to any specific commit using a “pseudo-version”
of the form v0.0.0-*yyyymmddhhmmss*-*commit*.
The pseudo-version form allows referring to untagged commits
as well as commits that are tagged with semantic versions at v2 or above
but that do not follow the semantic import versioning convention.

Module-aware builds can also consume requirement information
not just from `go.mod` files but also from all known pre-existing
version metadata files in the Go ecosystem:
`GLOCKFILE`, `Godeps/Godeps.json`, `Gopkg.lock`, `dependencies.tsv`,
`glide.lock`, `vendor.conf`, `vendor.yml`, `vendor/manifest`,
and `vendor/vendor.json`.

Existing tools like `dep` should have no trouble consuming
Go modules, simply ignoring the `go.mod` file.
It may also be helpful to add support to `dep` to read `go.mod` files in 
dependencies, so that `dep` users are unaffected as their
dependencies move from `dep` to the new module support.

## Implementation

A prototype of the proposal is implemented in a fork of the `go` command called `vgo`,
available using `go get -u golang.org/x/vgo`.
We will refine this implementation during the Go 1.11 cycle and
merge it back into `cmd/go` in the main repository.

The plan, subject to proposal approval,
is to release module support in Go 1.11
as an optional feature that may still change.
The Go 1.11 release will give users a chance to use modules “for real”
and provide critical feedback.
Even though the details may change, future releases will 
be able to consume Go 1.11-compatible source trees.
For example, Go 1.12 will understand how to consume
the Go 1.11 `go.mod` file syntax, even if by then the
file syntax or even the file name has changed.
In a later release (say, Go 1.12), we will declare the module support completed.
In a later release (say, Go 1.13), we will end support for `go` `get` of non-modules.
Support for working in GOPATH will continue indefinitely.

## Open issues (if applicable)

We have not yet converted large, complex repositories to use modules.
We intend to work with the Kubernetes team and others (perhaps CoreOS, Docker)
to convert their use cases.
It is possible those conversions will turn up reasons for adjustments
to the proposal as described here.

