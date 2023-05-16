# Proposal: Adding tool dependencies to go.mod

Author(s): Conrad Irwin

Last updated: 2024-07-18

Discussion at https://golang.org/issue/48429.

## Abstract

Authors of Go modules frequently use tools that are written in Go and distributed as Go modules.
Although Go has good support for managing dependencies imported into their programs,
the support for tools used during development is comparatively weak.

To make it easier for Go developers to use tools written in Go
`go.mod` should gain a new directive that lets module authors define which tools are needed.

## Background

Programs written in Go are often developed using tooling written in Go.
There are several examples of these, for example:
[golang.org/x/tools/cmd/stringer](https://pkg.go.dev/golang.org/x/tools/cmd/stringer) or
[github.com/kyleconroy/sqlc](https://github.com/kyleconroy/sqlc).

It is desirable that all collaborators on a given project use the same version of
tools to avoid the output changing slightly on different people’s machines.
This comes up particularly with tools like linters
(where changes over time may change whether or not the code is considered acceptable)
and code generation (where the generated code must be assumed to match the
version of the library that is linked).

The currently recommended approach to this is to create a file called `tools.go`
that imports the package containing the tools to make the dependencies visible
to the module graph.
To hide this file from the compiler, it is necessary to exclude it from builds
by adding an unused build tag such as `//go:build tools`.
To hide this file from other packages that depend on your module, it must be put
in its own package inside your module.

This approach is quite fiddly to use correctly, and still has a few downsides:

1. It is hard to type `go run golang.org/x/tools/cmd/stringer`, and so projects
   often contain wrapper scripts.
2. `go run` relinks tools every time they are run, which may be noticeably slow.

People work around this by either globally installing tools, which may lead to version skew,
or by installing and using third party tooling (like [accio](https://github.com/mcandre/accio))
to manage their tools instead.

## Proposal

### New syntax in go.mod

`go.mod` gains a new directive: `tool path/to/package`.

This acts exactly as though you had a correctly set up `tools.go` that contains `import "path/to/package"`.

As with other directives, multiple `tool` directives can be factored into a block:

```
go 1.24

tool (
    golang.org/x/tools/cmd/stringer
    ./cmd/migrate
)
```

Is equivalent to:

```
go 1.24

tool golang.org/x/tools/cmd/stringer
tool ./cmd/migrate
```

To allow automated changes `go mod edit` will gain two new parameters:
`-tool path/to/package` and `-droptool path/to/package` that add and
remove `tool` directives respectively.

### New behavior for `go get`

To allow users to easily add new tools, `go get` will gain a new parameter: `-tool`.

When `go get` is run with the `-tool` parameter, then it will download the specified
package and add it to the module graph as it does today.
Additionally it will add a new `tool` directive to the current module’s `go.mod`.

If you combine the `-tool` flag with the `@none` version,
then it will also remove the `tool` directive from your `go.mod`.

### New behavior for `go tool`

When `go tool` is run in module mode with an argument that does not match a go builtin tool,
it will search the current `go.mod` for a tool directive that matches the last
path segment and compile and run that tool similarly to `go run`.

For example if your go.mod contains:

```
tool golang.org/x/tools/cmd/stringer
require golang.org/x/tools v0.9.0
```

Then `go tool stringer` will act similarly to `go run golang.org/x/tools/cmd/stringer@v0.9.0`,
and `go tool` with no arguments will also list `stringer` as a known tool.

In the case that two tool directives end in the same path segment, `go tool X` will error.
In the case that a tool directive ends in a path segment that corresponds to a builtin Go tool,
the builtin tool will be run.
In both cases you can use `go tool path/to/package` to specify what you want unconditionally.

The only difference from `go run` is that `go tool` will cache the built binary
in `$GOCACHE/tool/<current-module-path>/<TOOLNAME>`.
Subsequent runs of `go tool X` will then check that the built binary is up to date,
and only rebuild it if necessary to speed up re-using tools.

When the Go cache is trimmed, any tools that haven't been used in the last five days will be deleted.
Five days was chosen arbitrarily as it matches the expiry used for existing artifacts.
Running `go clean -cache` will also remove all of these binaries.

### A tools metapackage

We will add a new metapackage `tools` that contains all of the tools in the current modules `go.mod`.

This would allow for the following operations:

```
# Install all tools in GOBIN
go install tools

# Build and cache tools so `go tool X` is fast:
go build tools

# Update all tools to their latest versions.
go get tools

# Install all tools in the bin/ directory
go build -o bin/ tools
```

## Rationale

This proposal tries to improve the workflow of Go developers who use tools
packaged as Go modules while developing Go modules.
It deliberately does not try and solve the problem of versioning arbitrary binaries:
anything not distributed as a Go module is out of scope.

There were a few choices that needed to be made, explained below:

1. We need a mechanism to specify an exact version of a tool to use in a given module.
   Re-using the `require` directives in `go.mod` allows us to do this without introducing
   a separate dependency tree or resolution path.
   This also means that you can use `require` and `replace` directives to control the
   dependencies used when building your tools.
2. We need a way to easily run a tool at the correct version.
   Adding `go tool X` allows Go to handle versioning for you, unlike installing binaries to your path.
3. We need a way to improve the speed of running tools (compared to `go run` today)
   as tools are likely to be reused.
   Reusing the existing Go cache and expiry allows us to do this in a best-effort
   way without filling up the users’ disk if they develop many modules with a large number of tools.
4. `go tool X` always defaults to the tool that ships with the Go distribution in case of conflict,
   so that it always acts as you expect.

## Compatibility

There’s no language change, however we are changing the syntax of `go.mod`.
This should be ok, as the file-format was designed with forward compatibility in mind.

If Go adds tools to the distribution in the future that conflict with tools added
to projects’ `go.mod` files, this may cause compatibility issues in the future.
I think this is likely not a big problem in practice, as I expect new tools to be rare.
Experience from using `$PATH` as a shared namespace for executables suggests that
name conflicts in binaries can be easily avoided in practice.

## Implementation

I plan to work on this for go1.24.

## Open questions

### How should this work with Workspaces?

This should probably not do anything special with workspaces.
Because tools must be present in the `require` directives of a module,
there is no easy way to make them work at a workspace level instead of a module level.

It might be possible to try and union all tools in all modules in the workspace,
but I suggest we defer this to future work if it’s desired.
