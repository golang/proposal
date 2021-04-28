# Proposal: Multi-Module Workspaces in `cmd/go`

Author(s): Michael Matloob

Last updated: 2021-04-22

Discussion at https://golang.org/issue/45713.

## Abstract

This proposal describes a new _workspace_ mode in the `go` command for editing
multiple modules. The presence of a `go.work` file in the working directory or a
containing directory will put the `go` command into workspace mode. The
`go.work` file specifies a set of local modules that comprise a workspace. When
invoked in workspace mode, the `go` command will always select these modules and
a consistent set of dependencies.

## Glossary

These terms are used often in this document. The
[Go Modules Reference](https://golang.org/ref/mod) and its
[Glossary](https://golang.org/ref/mod#glossary) provide more detail.

*   ***Main*** **modules**: The module the user is working in. Before this
    proposal, this is the single module containing the directory where the `go`
    command is invoked. This module is used as the starting point when running
    MVS. This proposal proposes allowing multiple main modules.
*   ***Module version***: From the perspective of the go command, a module
    version is a particular instance of a module. This can be a released version
    or pseudo version of a module, or a directory with a go.mod file.
*   ***Build list***: The _build list_ is the list of _module versions_ used for
    a build command such as go build, go list, or go test. The build list is
    determined from the main module's go.mod file and go.mod files in
    transitively required modules using minimal version selection. The build
    list contains versions for all modules in the module graph, not just those
    relevant to a specific command.
*   ***MVS*** **or** ***Minimal Version Selection***: The algorithm used to determine
    the versions of all modules that will be used in a build. See the
    [Minimal Version Selection](https://golang.org/ref/mod#minimal-version-selection)
    section in the Go Modules Reference for more information.
*   ***mode***: This document references module _mode_ and workspace _mode_. The
    modes are the different ways the `go` command determines which modules and
    packages it's building and how dependencies are resolved. For example the
    `-mod=readonly` mode uses the versions of the modules listed in the `go.mod`
    file and fails if it would need to add in a new module dependency, and the
    `-mod=vendor` mode uses the modules in the `vendor` directory.

## Background

Users often want to make changes across multiple modules: for instance, to
introduce a new interface in a package in one module along with a usage of that
interface in another module. Normally, the `go` command recognizes a single
"main" module the user can edit. Other modules are read-only and are loaded from
the module cache. The `replace` directive is the exception: it allows users to
replace the resolved version of a module with a working version on disk. But
working with the replace directive can often be awkward: each module developer
might have working versions at different location on disk, so having the
directive in a file that needs to be distributed with the module isn't a good
fit for all use cases.

[`gopls`](https://golang.org/s/gopls) offers users a convenient way to make
changes across modules without needing to manipulate replacements. When multiple
modules are opened in a `gopls` workspace, it synthesizes a single go.mod file,
called a _supermodule_ that pulls in each of the modules being worked on.
The supermodule results in a single build list allowing the tooling to surface
changes made in a dependency module to a dependent module. But this means that
`gopls` is building with a different set of versions than an invocation of the
`go` command from the command line, potentially producing different results.
Users would have a better experience if they could create a configuration that
could be used by `gopls` as well as their direct invocations of `cmd/go` and
other tools. See the
[Multi-project gopls workspaces](37720-gopls-workspaces.md) document and
proposal issues [#37720](https://golang.org/issue/37720) and
[#32394](https://golang.org/issue/32394).

### Scope

This proposal specifically tries to improve the experience in the `go` command
(and the tools using it) for working in multi-module workspaces. That means the
following are out of scope:

#### Tagging and releasing new versions of a module

This proposal does not address the problem of tagging and releasing new versions
of modules so that new versions of dependent modules depend on new versions of
the dependency modules. But these sorts of features don't belong in the `go`
command. Even so, the workspace file can be useful for a future tool or feature
that solves the tagging and releasing problem: the workspace would help the tool
know the set of modules the user is working on, and together with the module
dependency graph, the tool would be able to determine versions for the new
modules.

#### Building and testing a module with the user's configuration

It would be useful for module developers to build and test their modules with
the same build list seen by users of their modules. Unfortunately, there are
many such build lists because those build lists depend on the set of modules the
user's module requires, and the user needs to know what those modules are. So
this proposal doesn't try to solve that problem. But this proposal can make it
easier to switch between multiple configurations, which opens the door for other
tools for testing modules in different configurations.

## Proposal

### The `-workfile` flag

The new `-workfile` flag will be accepted by module-aware build commands and
most `go mod` subcommands. The following is a table of which commands can
operate in workspace mode and which can operate in module mode. Commands that
can operate in workspace mode will accept `-workfile` and follow the workspace
resolution steps below.

`go mod download`, `go mod graph`, `go mod verify` and `go mod why` all have
meanings based on the build list, so they will all work in workspace mode
according to the build list.
`go mod edit`, `go mod init` `go mod tidy` and `go mod vendor` only make sense
in a single module context, so they will ignore the workspace.
`go get` could make sense in workspace mode but not in all contexts, so it
will also ignore the workspace.

| Subcommand     | Module | Workspace  |
|----------------|--------|------------|
| `mod init`     |  o     |            |
| `mod initwork` |        |  o         |
| `mod download` |  o     |  o         |
| `mod graph`    |  o     |  o         |
| `mod verify`   |  o     |  o         |
| `mod why`      |  o     |  o         |
| `mod edit`     |  o     |            |
| `mod tidy`     |  o     |            |
|` mod vendor`   |  o     |            |
| `get`          |  o     |            |
| `install`      |  o     |            |
| `list`         |  o     |  o         |
| `build`        |  o     |  o         |
| `test `        |  o     |  o         |

If `-workfile` is set to `off`, workspace mode will
be disabled. If it is `auto` (the default), workspace mode will be enabled if a
file named `go.work` is found in the current directory (or any of its parent
directories), and disabled otherwise. If `-workfile` names a path to an existing
file that ends in `.work`, workspace mode will be enabled. Any other value is an
error.

If workspace mode is on, `-mod=readonly` must be specified either implictly or
explicitly. Otherwise, the `go` command will return an error. If `-mod` is not
explicitly set and `go.work` file is found, `-mod=readonly` is set. (That is, it
takes precedence over the existence of a vendor/module.txt which would normally
imply `-mod=vendor`.)

If workspace mode is on, the `go.work` file (either named by `-workfile` or the
nearest one found when `-workfile` is `auto`) will be parsed to determine the
three parameters for workspace mode: a Go version, a list of directories, and a
list of replacements.

If workspace mode is on, the selected workspace file will show up in the `go
env` variable `GOWORK`. When not in workspace mode, `GOWORK` will be `off`.

### The `go.work` file

The following is an example of a valid `go.work` file:

```
go 1.17

directory (
    ./baz // foo.org/bar/baz
    ./tools // golang.org/x/tools
)

replace golang.org/x/net => example.com/fork/net v1.4.5
```

The `go.work` file will have a similar syntax as the `go.mod` file. Restrictions
in [`go.mod` lexical elements](https://golang.org/ref/mod#go-mod-file-lexical)
still apply to the `go.work` file

The `go.work` file has three directives: the `go` directive, the `directory`
directive, and the `replace` directive.

#### The `go` Directive

The `go.work` file requires a `go` directive. The `go` directive accepts a
version just as it does in a `go.mod` file. The `go` directive is used to allow
adding new semantics to the `go.work` files without breaking previous users. It
does not override go versions in invididual modules.

Example:

```
go 1.17
```

#### The `directory` directive

The `directory` directive takes an absolute or relative path to a directory
containing a `go.mod` file as an argument. The syntax of the path is the same as
directory replacements in `replace` directives. The path must be to a module
directory containing a `go.mod` file. The `go.work` file must contain at least
one `directory` directive. The `go` command may optionally edit the comments on
the `directory` directive when doing any operation in workspace mode to add the
module path from the directory's `go.mod` file.

Note that the `directory` directive has no restriction on where the directory
is located: module directories listed in `go.work` file can be located outside
the directory the `go.work` file itself is in.

Example:

```
directory (
    ./tools // golang.org/x/tools
    ./mod   // golang.org/x/mod
)
```

Each directory listed (in this example `./tools` and `./mod`) refers to a single
module: the module specified by the `go.mod` file in that directory. It does
not refer to any other modules specified by `go.mod` files in subdirectories of
that directory.

The modules specified by `directory` directives in the `go.work` file are the
_workspace modules_. The workspace modules will collectively be the main modules
when doing a build in workspace mode. These modules are always selected by MVS
with the version `""`, and their `replace` and `exclude` directives are applied.

#### The `replace` directive

The `replace` directive has the same syntax and semantics as the replace
directive in a `go.mod` file.

Example:

```
replace (
    golang.org/x/tools => ../tools
    golang.org/x/mod v0.4.1  => example.com/mymod v0.5
)
```

The `replace` directives in the `go.work` are applied in addition to and with
higher precedence than `replaces` in the workspace modules. A `replace`
directive in the `go.work` file overrides replace directives in workspace
modules applying to the same module or module version. If two or more workspace
modules replace the same module or module version with different module versions
or directories, and there is not an overriding `replace` in the `go.work` file,
the `go` command will report an error. The `go` command will report errors for
replacements of workspace modules that don't refer to the same directory as the
workspace module. If any of those exist in a workspace module replacing another
workspace module, the user will have to explicitly replace that workspace module
with its path on disk.

### Semantics of workspace mode

If workspace mode is on and the `go.work` file has valid syntax, the Go version
provided by the `go.work` file is used to control the exact behavior of
workspace mode. For the first version of Go supporting workspace mode and unless
changes are made in following versions the following semantics apply:

When doing a build operation under workspace mode the `go` command will try to
find a `go.mod` file. If a `go.mod` file is found, its containing directory must
be declared with a `directory` directive in the `go.work` file. Because the
build list is determined by the workspace rather than a `go.mod` file, outside
of a module, the `go` command will proceed as normal to build any non-relative
package paths or patterns. Outside of a module, a package composed of `.go`
files listed on the command line resolves its imports according to the
workspace, and the package's imports will be resolved according to the
workspace's build list.

The `all` pattern in workspace mode resolves to the union of `all` for over the
set of workspace modules. `all` is the set of packages needed to build and test
packages in the workspace modules.

To construct the build list, each of the workspace modules are main modules and
are selected by MVS and their `replace` and `exclude` directives will be
applied. `replace` directives in the `go.work` file override the `replaces` in
the workspace modules. Similar to a single main module in module mode, each of
the main modules will have version `""`, but MVS will traverse other versions of
the main modules that are depended on by transitive module dependencies. For the
purposes of lazy loading, we load the explicit dependencies of each workspace
module when doing the deepening scan.

Module vendor directories are ignored in workspace mode because of the
requirement of `-mod=readonly`.

### Creating and editing go.work files

Two new subcommands will be added to go mod: `go mod initwork` and `go mod
editwork`.

`go mod initwork` will take as arguments a (potentially empty) list of
directories it will use to write out a `go.work` file in the working directory
with a `go` statement and a `directory` statement listing each of the
directories. `go mod initwork` will take an optional `-o` flag to specify a
different output file path, which can be used to create workspace files for
other configurations.

`go mod editwork` will work similarly to `go mod edit` and take the following
flags:

*   `-fmt` will reformat the `go.work` file
*   `-go=version` will set the file's `go` directive to `version`
*   `-directory=path` and `-dropdirectory=path` will add and drop a directory
    directive for the given path
*   `-replace` and `-dropreplace` will work exactly as they do for `go mod edit`

## Rationale

This proposal addresses these workflows among others:

### Workflows

#### A change in one module that requires a change in another module

One common workflow is when a user wants to add a feature in an upstream module
and make use of the feature in their own module. Currently, they might open the
two modules in their editor through gopls, which will create a supermodule
requiring and replacing both of the modules, and creating a single build list
used for both of the modules. The editor tooling and builds done through the
editor will use that build list, but the user will not have access to the
'supermodule' outside their editor: go command invocations run in their terminal
outside the editor will use a different build list. The user can change their
go.mod to add a replace, which will be reflected in both the editor and their go
command invocations, but this is a change they will need to remember to revert
before submitting.

When these changes are done often, for example because a project's code base is
split among several modules, a user might want to have a consistent
configuration used to join the modules together. In that case the user will want
to configure their editor and the `go` command to always use a single build list
when working in those modules. One way to do this is to work in a top level
module that transitively requires the others, if it exists, and replace the
dependencies. But they then need to remember to not check in the replace and
always need to run their go commands from that designated module.

##### Example

As an example, the `gopls` code base in `golang.org/x/tools/internal/lsp` might
want to add a new function to `golang.org/x/mod/modfile` package and start using
it. If the user has the `golang.org/x/mod` and `golang.org/x/tools` repos in the
same directory they might run:

```
go mod initwork ./mod ./tools
```

which will produce this file:

```
go 1.17

directory (
    ./mod // golang.org/x/mod
    ./tools // golang.org/x/tools
)
```

Then they could work on the new function in `golang.org/x/mod/modfile` and its
usage in `golang.org/x/tools/internal/lsp` and when run from any directory in
the workspace the `go` command would present a consistent build list. When they
were satisfied with their change, they could release a new version of
`golang.org/x/mod`, update `golang.org/x/tools`'s `go.mod` to require the new
vesion of `golang.org/x/mod`, and then turn off workspace mode with
`-workfile=off` to make sure the change behaves as expected.

#### Multiple modules in the same repository that depend on each other

A further variant of the above is a module that depends on another module in the
same repository. In this case checking in go.mod files that require and replace
each other is not as much of a problem, but especially as the number of modules
grows keeping them in sync becomes more difficult. If a user wants to keep the
same build list as they move between directories so that they can continue to
test against the same configuration, they will need to make sure all the modules
replace each other, which is error prone. It would be far more convenient to
have a single configuration linking all the modules together. Of course, this
use case has the additional problem of updating the requirements on the replaced
modules in the repository. This is a case of the problem of updating version
requirements on released modules which is out of scope for this proposal.

Our goal is that when there are several tightly coupled modules in the same
repository, users would choose to create `go.work` files defining the workspace
using the modules in those repositories instead of adding `replaces` in the
`go.mod` files. Perhaps the creation of the file can be automated by an external
tool that scans for all the `go.mod` files recursively contained in a directory.
These `go.work` files should not be checked into the
repositories so that they don't override the workspaces users explicitly define.
Checking in `go.work` files could also lead to CI/CD systems not testing the
actual set of version requirements on a module and that version requirements
among the repository's modules are properly incremented to use changes in the
modules. And of course, if a repository contains only a single module, or
unrelated modules, there's not much utility to adding a `go.work` file because
each user may have a different directory structure on their computer outside of
that repository.

##### Example

As a simple example the `gopls` binary is in the module
`golang.org/x/tools/gopls` which depends on other packages in the
`golang.org/x/tools` module. Currently, building and testing the top level
`gopls` code is done by entering the directory of the `golang.org/x/tools/gopls`
module which replaces its usage of the `golang.org/tools/module`:

```
module golang.org/x/tools/gopls

go 1.12

require (
    ...
    golang.org/x/tools v0.1.0
    ...
)

replace golang.org/x/tools  => ../
```

This `replace` can be removed and replaced with a `go.work` file that includes
both modules in the directory above the checkout of the `golang.org/x/tools`
```
// golang.org/x/tools/go.work
go 1.17

directory (
    ./tools
    ./tools/gopls
)
```

This allows any of the tests in either module to be run from anywhere in the
repo. Of course, to release the modules, the `golang.org/x/tools` module needs
to be tagged and released, and then the `golang.org/x/gopls` module needs to
require that new release.

#### Switching between multiple configurations

Users might want to easily be able to test their modules with different
configurations of dependencies. For instance, they might want to test their
module using the development versions of the dependencies, using the build list
determined using the module as a single main module, and using a build list with
alternate versions of dependencies that are commonly used. By making a workspace
with the development versions of the dependencies and another adding the
alternative versions of the dependencies with replaces, it's easy to switch
between the three configurations.

Users who want to test using a subset of the workspace modules can also easily
comment out some of the directory directives in their workspace file instead of
making separate workspace files with the appropriate subset of workspace
modules, if that works better for their workflows.

#### Workspaces in `gopls`

With this change, users will be able to configure `gopls` to use `go.work` files
describing their workspace. `gopls` can pass the workspace to the `go` command
in its invocations if it's running a version of Go that supports workspaces, or
can easily rewrite the workspace file into a supermodule for earlier versions.
The semantics of workspace mode are not quite the same as for a supermodule in
general (for instance `...` and `all` have different meanings) but are the same
or close enough for the cases that matter.

#### A `GOPATH`-like setup

While this proposal does not aim to completely recreate all `GOPATH` workflows,
it can be used to create a setup that shares some aspects of the `GOPATH` setup:
A user who is working with a set of modules in `GOPATH`, but in `GOPATH` mode
so that all dependencies are resolved from the `GOPATH` tree can add a `go.work`
file to the base of a `GOPATH` directory that lists all the modules in that
`GOPATH` (and even those in other `GOPATH` directories, if their path has
multiple elements). Then all their dependencies that are under that `GOPATH`
directory will continue to be resolved from those locations.

Of course there are caveats to this workflow: `GOPATH` packages that are not
contained in a module can't be added to the workspace, and the `go.work` file
needs to be manually maintained to add modules instead of walking a directory
tree like `GOPATH` mode does. And opting into workspace mode piecemeal by adding
modules one by one can be frustrating because the modules outside of the new
workspace will require `-modfile` to be set to `off` or another `go.work` file
that includes it. But even with these differences, used this way, `go.work` can
recreate some of the convenience of `GOPATH` while still providing the benefits
of modules.

### The `workfile` flag

One alternative that was considered for disabling module mode would be to have
module mode be an option for the `-mod` flag. `-mod=work` would be the default
and users could set any other value to turn off workspace mode. This removes the
redundant knob that exists in this proposal where workspace mode is set
independently of the `-mod` flag, but only `-mod=readonly` is allowed. The
reason this alternative was adopted for this proposal is that it could be
unintuitive and hard for users to remember to set `-mod=readonly` to turn
workspace mode off. Users might think to set `-mod=mod` to turn workspace mode
off even though they don't intend to modify their `go.mod` file.

This also avoids conflicting defaults: the existence of a `go.work` file implies
workspace mode, but the existence of `vendor/module.txt` implies `-mod=vendor`.
Separating the configurations makes it clear that the `go.work` file takes
precedence.

But regardless of the above, it's useful to have a way to specify the path to a
different `go.work` file similar to the `-modfile` flag for the same reasons
that `-modfile` exists. Given that `-workfile` exists it's natural to add a
`-workfile=off` option to turn off workspace mode.

### The `go.work` file

The configuration of multi-module workspaces is put in a file rather than being
passed through an environment variable or flag because there are multiple
parameters for configuration that would be difficult to put into a single flag
or environment variable and unwieldy to put into multiple.

The `go` command locates `go.work` files the same way it locates `go.mod` files
to make it easy for users already familiar with modules to learn the rules for
whether their current directory is in a workspace and which one.

`go.work` files allow users to operate in directories outside of any modules but
still use the workspace build list. This makes it easy for users to have a
`GOPATH`-like user experience by placing a `go.work` file in their home
directory linking their modules together.

Like the `go.mod` file, we want the format of the configuration for multi-module
workspaces to be machine writable and human readable. Though there are other
popular configuration formats such as yaml and json, they can often be confusing
or annoying to write. The format used by the `go.mod` file is already familar to
Go programmers, and is easy for both humans and computers to read and write.

Modules are listed by the directory containing the module's `go.mod` file rather
than listing the paths to the `go.mod` files themselves to avoid the redundant
basename in every path. Alternatively, if the `go.mod` files were listed
directly it would be more clear that directories aren't being searched for all
modules contained under them but rather refer to a single module. Modules are
required to be listed explicitly instead of allowing for patterns that match
all modules under a directory because those entries would require slow directory
walks each time the `go` command would need to load a workspace. Because
a module's path is not always clear from its directory name, we will allow the
go command add comments on the `directory` directive with the module path.

Requiring the directories listed in the `go.work` file to have `go.mod` files
means that projects without `go.mod` files can't be added to a workspace even
though they can be required as implicit modules in `go.mod` files. To support
these we would have to add to the `go.work` file some way of associating the
directories with `go.mod` files. But these projects are already getting more
rare and the missing `go.mod` can be worked around by adding a temporary
`go.mod` file to the project's directory.

The naming of the `go` and `replace` directives is straightforward: they are the
same as in `go.mod`. The `directory` directive is called `directory` because
that is its argument. Using `module` to list the module directories could be
confusing because there is already a module directive in `go.mod` that has a
different meaning. On the other hand, names like `modvers` and `moddir` are
awkward.

`go.work` files should not be checked into version control repos containing
modules so that the `go.work` file in a module does not end up overriding
the configuration a user created themselves outside of the module. The `go.work`
documentation should contain clear warnings about this.

### Semantics of workspace mode

A single build list is constructed from the set of workspace modules to give
developers consistent results wherever they are in their workspace. Further, the
single build list allows tooling to present a consistent view of the workspace,
so that editor operations and information doesn't change in surprising ways when
moving between files.

`replace` directives are respected when building the build list because many
modules already have many `replace`s in them that are necessary to properly
build them. Not respecting them would break users unnessesarily. `replace`
directives exist in the workspace file to allow for resolving conflicts between
`replace`s in workspace modules. Because all workspace modules exist as
co-equals in the workspace, there is no clear and intuitive way to resolve
`replace` conflicts without explicit input from the user. One alternative is
to add special syntax for overriding replaces to make the overriding behavior
more explicit, and an additional option is to add an option to add syntax to
nullify replaces without overriding them.

Working in modules not listed in the workspace file is disallowed to avoid what
could become a common source of confusion: if the `go` command stayed in
workspace mode, it's possible that a command line query could resolve to a
different version of the module the directory contains. Users could be confused
about a `go build` or `go list` command completing successfully but not
respecting changes made in the current module. On the other hand, a user could
be confused about the go command implicitly ignoring the workspace if they
intended the current module to be in the workspace. It is better to make the
situation clear to the user to allow them either to add the current module to
the workspace or explicitly turn workspace mode off according to their
preference.

Module vendoring is ignored in workspace mode because it is not clear which
modules' vendor directories should be respected if there are multiple workpace
modules with vendor directories containing the same dependencies. Worse, if
module A vendors example.com/foo/pkg@A and module B vendors
example.com/foo/sub/pkg@v0.2.0, then a workspace that combines A and B would
select example.com/foo v0.2.0 in the overall build list, but would not have any
vendored copy of example.com/foo/pkg for that version. As the modules spec says,
"Vendoring may be used to allow interoperation with older versions of Go, or to
ensure that all files used for a build are stored in a single file tree.".
Because developers in workspace mode are necessarily not using an older version
of Go, and the build list used by the workspace is different than that used in
the module, vendoring is not as useful for workspaces as it is for individual
modules.

### `go.work.sum` files

The `go` command will use the collective set of `go.sum` files that exist across
the workspace modules to verify dependency modules, but there are cases where
the `go.sum` files in the workspace modules collectively do not contain all sums
needed to verify the build: The simpler case is if the workspace go.mod files
themselves are incomplete, the `go` command will add missing sums to the
workspace's `go.work.sum` file rather than to the module's `go.sum`. But even
if all workspace `go.sum` files are complete, they may still not contain all
necessary sums:

> If the workspace includes modules `X` and `Y`, and `X` imports a package from
> `example.com/foo@v1.0.0`, and `Y` has a transitive requirement on
> `example.com/foo@v1.1.0` (but does not import any packages from it), then
> `X/go.sum` will contain a checksum only for `v1.0.0/go.sum` and `v1.0.0`, and
> `Y` will contain a checksum only for `v1.1.0/go.sum`. No individual module
> will have a checksum for the source code for `v1.1.0`, because no module in
> isolation actually uses that source code.

### Creating and editing `go.work` files

The `go mod initwork` and `go mod editwork` subcommands are being added for the
same reasons that the go `go mod init` and `go mod edit` commands exist: they
make it more convenient to create and edit `go.work` files. The names are
awkward, but it's not clear that it would be worth making the commands named `go
work init` and `go work edit` if `go work` would only have two subcommands.

## Compatibility

Tools based on the go command, either directly through `go list` or via
`golang.org/x/tools/go/packages` will work without changes with workspaces.

This change does not affect the Go language or its core libraries. But we would
like to maintain the semantics of a `go.work` file across versions of Go to
avoid causing unnecessary churn and surprise for users.

This is why all valid `go.work` files provide a Go version. Newer versions of Go
will continue to respect the workspace semantics of the version of Go listed in
the `go.work` file. This will make it possible (if necessary) to make changes in
the of workspace files in future versions of Go for users who create new
workspaces or explicitly increase the Go version of their `go.work` file.

## Implementation

The implementation for this would all be in the `go` command. It would need to
be able to read `go.work` files, which we could easily implement reusing parts
of the `go.mod` parser. We would need to add the new `-workfile flag` to the Go
command and modify the `go` command to look for the `go.work` file to determine
if it's in workspace mode. The most substantial part of the implementation would
be to modify the module loader to be able to accept multiple main modules rather
than a single main module, and run MVS with the multiple main modules when it is
in workspace mode.

To avoid issues with the release cycle, if the implementation is not finished
before a release, the behavior to look for a `go.work` file and to turn on
workspace mode can be guarded behind a `GOEXPERIMENT`. Without the experiment
turned on it will be possible to work on the implementation even if it can't be
completed in time because it will never be active in the release. We could also
set the `-workfile` flag's default to `off` in the first version and change it
to its automatic behavior later.

## Related issues

### [#32394](https://golang.org/issue/32394) x/tools/gopls: support multi-module workspaces

Issue [#32394](https://golang.org/issue/32394) is about `gopls`' support for
multi-module workspaces. `gopls` currently allows users to provide a "workspace
root" which is a directory it searches for `go.mod` files to build a supermodule
from. Alternatively, users can create a `gopls.mod` file in their workspace root
that `gopls` will use as its supermodule. This proposal creates a concept
of a workspace that is similar to that `gopls` that is understood by the `go`
command so that users can have a consistent configuration across their editor
and direct invocations of the `go` command.

### [#44347](https://golang.org/issue/44347) proposal: cmd/go: support local experiments with interdependent modules; then retire GOPATH

Issue [#44347](https://golang.org/issue/44347) proposes adding a `GOTINKER`
mode to the `go` command. Under the proposal, if `GOTINKER` is set to a
directory, the `go` command will resolve import paths and  dependencies in
modules by looking first in a `GOPATH`-structured tree under the `GOTINKER`
directory before looking at the module cache. This would allow users who want
to have a `GOPATH` like workflow to build a `GOPATH` at `GOTINKER`, but still
resolve most of their dependencies (those not in the `GOTINKER` tree) using
the standard module resolution system. It also provides for a multi-module
workflow for users who put their modules under `GOTINKER` and work in those
modules.

This proposal also tries to provide some aspects of the `GOPATH` workflow and
to help with multi-module workflows. A user could put the modules that they
would put under `GOTINKER` in that proposal into their `go.work` files to get
a similar experience to the one they'd get under the `GOTINKER` proposal. A
major difference between the proposals is that in `GOTINKER` modules would be
found by their paths under the `GOTINKER` tree instead of being explicitly
listed in the `go.work` file. But both proposals provide for a set of replaced
module directories that take precedence over the module versions that would
normally be resolved by MVS, when working in any of those modules.

### [#26640](https://golang.org/issue/26640) cmd/go: allow go.mod.local to contain replace/exclude lines

The issue of maintaining user-specific replaces in `go.mod` files was brought up
in [#26640](https://golang.org/issue/26640). It proposes an alternative
`go.mod.local` file so that local changes to the go.mod file could be made
adding replaces without needing to risk local changes being committed in
`go.mod` itself. The `go.work` file provides users a place to put many of the
local changes that would be put in the proposed `go.mod.local` file.

### [#39005](https://github.com/golang/go/issues/39005) proposal: cmd/go: introduce a build configurations file

Issue [#39005](https://github.com/golang/go/issues/39005) proposes to add a
mechanism to specify configurations for builds, such as build tags. This issue
is similar in that it is a proposal for additional configuration outside the
`go.mod` file. This proposal does not advocate for adding this type of
information to `go.work` and is focused on making changes across multiple
modules.

## Open issues

### The name of the `directory` directive

The name `directory` could lead people to believe that all modules under the
directory are included rather than just one. It might be better to use another
name. One alternative that has been suggested is `include`.

### Clearing `replace`s

We might want to add a mechanism to ignore all replaces of a module or module
version.

For example one module in the workspace could have `replace example.com/foo =>
example.com/foo v0.3.4` because v0.4.0 would be selected otherwise and they
think it's broken. Another module in the workspace could have
`require example.com/foo v0.5.0` which fixes the incompatibilities and also adds
some features that are necessary.

In that case, the user might just want to knock the replacements away, but they
might not want to remove the existing replacements for policy reasons (or
because the replacement is actually in a separate repo).

### Preventing `go.work` files from being checked in to repositories

`go.work` files that checked into repositories would cause confusion for Go
users because they change the build configuration without the user explicitly
opting in. Because of this they should be strongly discouraged. Though it's
not clear that the Go tool should enforce this, other tools that vet
repositories and releases should output warnings or errors for repositories
containing `go.work` files. There may also be other mechanisms not yet
considered in this document to discourage checked-in `go.work` files.

### Setting the `GOWORK` environment variable instead of `-workfile`

`GOWORK` can't be set by users because we don't want there to be ambiguity about
how to enter workspace mode, but an alternative could be to use an environment
variable instead of the `-workfile` flag to change the location of the workspace
file. Note that with the proposal as is, `-workfile` may be set in `GOFLAGS`,
and that may be persisted with `go env -w`. Developers won't need to type it out
every time.

### Patterns and Anti-Patterns

If this proposal is accepted, before it is released the documentation should
specify a set of patterns and anti-patterns and how to achieve certain workflows
using workspaces. For instance, it should mention that single-module
repositories should rarely contain `go.work` files.

## Future work

### Versioning and releasing dependent modules

As mentioned above, this proposal does not try to solve the problem of
versioning and releasing modules so that new versions of dependent modules
depend on new versions of the dependency modules. A tool built in the future can
use the current workspace as well as the set of dependencies in the module graph
to automate this work.

### Pushing down dependencies from the build list back to the workspace modules

Even though it's out of scope to update the dependencies between workspace
modules because that requires a release, it might be useful to make dependency
versions consistent. One idea could be to push the module versions of dependency
modules back into the go.mod files of the dependency modules. But this could
lead to confusion because while the dependency versions will be consistent, the
dependencies between the workspace modules will still need to be updated
separately.

### Listing the module versions in the workspace

While modules have a single file listing all their root dependencies, the set of
workspaces' root dependencies is split among many files, and the same is true
of the set of replaces. It may be helpful to add a command to list the effective
set of root dependencies and replaces and which go.mod file each of them comes
from.

Perhaps there could be a command named `go mod workstatus` that gives an
overview of the status of the modules in the workspace.
