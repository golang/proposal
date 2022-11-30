# Proposal: Extended forwards compatibility in Go

Russ Cox \
December 2022

Earlier discussion at https://go.dev/issue/55092.

Proposal at https://go.dev/issue/57001.

## Abstract

Many people believe the `go` line in the `go.mod` file specifies which Go toolchain to use.
This proposal would correct this widely held misunderstanding by making it reality.
At the same time, the proposal would improve forward compatibility by making sure
that old Go toolchains never try to build newer Go programs.

Define the “work module” as the one containing the directory
where the go command is run. We sometimes call this the “main module”,
but I am using “work module” in this document for clarity.

Updating the `go` line in the `go.mod` of the work module,
or the `go.work` file in the current workspace,
would change the minimum Go toolchain used to run go commands.
A new `toolchain` line would provide finer-grained control over Go toolchain selection.

An environment variable `GOTOOLCHAIN` would control this new behavior.
The default, `GOTOOLCHAIN=auto`, would use the information in `go.mod`.
Setting GOTOOLCHAIN to something else would override the `go.mod`.
For example, to test the package in the current directory with Go 1.17.2:

	GOTOOLCHAIN=go1.17.2 go test

## Background

The meaning of the current `go` line in the `go.mod` file is underdocumented
and widely misunderstood.

- Some people believe it sets the minimum version of Go that can be used to build the code.
  This is not true: any version of Go will try to build the code, but an older one will
  add a note after any compile failure pointing out that perhaps a newer version of Go is needed.

- Some people believe it sets the exact version of Go to use. This is also not true.
  The installed version of go is always what runs today.

These are reasonable beliefs. They are just not true.

Today, the only purpose of the `go` line is to determine the Go language version
that the compiler uses when compiling a particular source file.
If a module's `go.mod` says `go 1.16`, then the compiler makes sure to
provide the Go 1.16 language semantics when compiling source files
inside that module.
For example, Go 1.13 added `0o777` syntax for octal literals.
If `go.mod` says `go 1.12`, then the compiler rejects code containing `0o777`.
If `go.mod` says `go 1.13`, then the compiler accepts `0o777`.

Of course, a `go.mod` that says `go 1.13` might still only use Go 1.12 features.
To improve compatibility and avoid ecosystem fragmentation, Go 1.12 will still
try to compile code marked `go 1.13`. If it succeeds, the `go` command
assumes everything went well.
If it fails
(for example, because the code says `0o777` and the compiler
does not know what that means), then the `go` command prints
a notice about the `go 1.13` line after the actual failure,
in case what the user needs to know is to update to Go 1.13 or later.
These version failures are often mysterious, since the compiler errors
betray the older Go's complete and utter confusion
at the new program,
which in turn confuse the developers running the build.
Printing the version mismatch note at the end is better than not printing it,
but it's still not a great experience.

We can improve this experience by having the older Go version
download and re-exec a newer Go version
when the go.mod file needs one.
In this hypothetical world, the Go 1.12 `go` command would
see that it is too old and then download and use Go 1.13 for the build instead.
To be clear, Go 1.12 didn't work this way and never will.
But I propose that some future version of Go should.

Automatic downloading and use of the version of the Go toolchain
listed in the `go.mod` file
would match the automatic download and use
of the versions of required modules listed in the `go.mod` file.
It would also give code a simple way to declare that it needs a newer Go toolchain,
for example because it depends on a bug fix issued in that toolchain.

[Cloud Native Buildpacks](https://buildpacks.io/) are an example of the
bad effects of misunderstanding the meaning of the `go` line.
Today they actually _do_ use the line to select the Go toolchain:
if you have a module that says `go 1.12`, whether you are
trying to keep compatibility with the Go 1.12 language
or you just started out using Go 1.12 and have not needed
to update the line to access any new language features,
Cloud Native Buildpacks will always _build_ your code with Go 1.12,
even if much newer releases of Go exist.
Specifically, they will use the latest point release of Go 1.12.
This choice is unfortunate for two reasons.
First, people are using older releases of Go than they realize.
Second, this leads to non-repeatable builds.
Despite our being very careful, it can of course happen
that code that worked with Go 1.12.8 does not work with Go 1.12.9:
perhaps the code depended on the bug being fixed.
With Cloud Native Buildpacks, a deployment that works today
may break tomorrow if Go 1.12.9 has been released in the interim,
because the chosen release of Go changes based on details not controlled by
the `go.mod`.
If we accidentally issued a Go 1.12.9 that broke all Go programs running in containers,
then every Cloud Native Buildpack user with a `go 1.12` line
would have get broken builds on their next redeploy
without ever asking to update to Go 1.12.9.
This is a perfect example of a [low-fidelity build](https://research.swtch.com/vgo-mvs).

The GitHub Action `setup-go` does something similar
with its [`go-version-file` directive](https://github.com/actions/setup-go#getting-go-version-from-the-gomod-file).
It has the same problems that Cloud Native Buildpacks do.

On the other hand, we can also take Cloud Native Buildpacks and the `setup-go` GitHub Action as
evidence that people expect that line to select the Go toolchain,
at least in the work module.
After all, when a module says `require golang.org/x/sys v0.0.1`,
we all understand that means any build of the module uses that version or later.
Why does `go 1.12` _not_ mean that?
I propose that it should.
For more fine-grained control, I also propose a new `toolchain` line in `go.mod`.

One final feature of treating the `go` version this way is that
it would provide a way to fix for loop scoping,
as discussed in [discussion #56010](https://github.com/golang/go/discussions/56010).
If we make that change, older Go toolchains must not assume
that they can compile newer Go code successfully just because
there are no compiler errors. So this proposal is a prerequisite
for any proposal to do the loop change.

See also my [talk on this topic at GopherCon](https://www.youtube.com/watch?v=v24wrd3RwGo).

## Proposal

The proposal has five parts:

 - the GOTOOLCHAIN environment and configuration variable,
 - a change to the way the `go` line is interpreted in the work module along with a new `toolchain` line,
 - changes to `go get` to allow updating the `go` toolchain,
 - a special case to allow Go distributions to be downloaded like modules,
 - and changing the `go` command startup procedure.

### The GOTOOLCHAIN environment and configuration variable

The GOTOOLCHAIN environment variable,
configurable as usual with `go env -w`,
will control which toolchain of Go runs when you run `go`.
Specifically, a new enough installed Go toolchain
will know to consult GOTOOLCHAIN and potentially download
and re-exec a different toolchain before proceeding.
This will allow invocations like

	GOTOOLCHAIN=go1.17.2 go test

to test a package with Go 1.17.2. Similarly, to try a release candidate:

	GOTOOLCHAIN=go1.18rc1 go build -o myprog.exe

Setting `GOTOOLCHAIN=local` will mean to use the locally installed Go toolchain,
never downloading a different one; this is the behavior we have today.

Setting `GOTOOLCHAIN=auto` will mean to use the release named in the
in the work module's `go.mod` when it is newer than the locally installed Go toolchain.

The default setting of GOTOOLCHAIN will depend on the Go toolchain.
Standard Go releases will default to `GOTOOLCHAIN=auto`,
delegating control to the `go.mod` file.
This is the behavior essentially all Go user would see as the default.

Development toolchains—what you get by checking out the Go repository
and running `make.bash`—will default to `GOTOOLCHAIN=local`.
This is necessary for developers of Go itself, so that when working on Go
you actually use the copy you're working on and not a different copy of Go.

Once the toolchain is selected, it would still look at the `go` version:
if the `go` version is newer than the toolchain being run,
the toolchain will refuse to build the program:
Go 1.29 would refuse to attempt to build code that declares `go 1.30`.

### The `go` and `toolchain` lines in `go.mod` in the work module

The `go` line in the `go.mod` in the work module selects the Go semantics.
When the locally installed Go toolchain is newer than the `go` line,
it provides the requested older semantics directly, instead of invoking a stale toolchain.
([Proposal #56986](https://go.dev/issue/56986) addresses making the older semantics more accurate.)
But if the `go` line names a newer Go toolchain, then the locally installed
Go toolchain downloads and runs the newer toolchain.

For example, if we are running Go 1.30 and have a `go.mod` that says

	go 1.30.1

then Go 1.30 would download and invoke Go 1.30.1 to complete the command.

On the other hand, if the `go.mod` says

	go 1.20rc1

then Go 1.30 will provide the Go 1.20rc1 semantics itself instead of running the
Go 1.20 rc1 toolchain.

Developers may want to run a newer toolchain but with older language semantics.
To enable this, the `go.mod` file would also support a new `toolchain` line.
If present, the `toolchain` line would specify the toolchain to use,
and the `go` line would only specify the Go version for language semantics.
For example:

	go 1.18
	toolchain go1.20rc1

would select the Go 1.18 semantics for this module but use Go 1.20 rc1 to build
(all still assuming `GOTOOLCHAIN=auto`; the environment variable
overrides the `go.mod` file).
In contrast to the older/newer distinction with the `go` line,
the `toolchain` line always applies: if Go 1.30 sees a `go.mod`
that says `toolchain go1.20rc1`, then it downloads Go 1.20 rc1.

The syntax `toolchain local` would be like setting `GOTOOLCHAIN=local`,
indicating to always use the locally installed toolchain.

### Updating the Go toolchain with `go get`

As part of this proposal, the `go get` command would change
to maintain the `go` and `toolchain` lines.

When updating module requirements during `go get`,
the `go` command would determine the minimum toolchain
required by taking the minimum of all the `go` lines in the
modules in the build graph; call that Go 1.M.
Then the `go` command would make sure the work module's `go.mod`
specifies a toolchain of Go 1.M beta 1 or later.
If so, no change is needed and the `go` and `toolchain` lines
are left as they are.
On the other hand, if a change is needed, the `go` command would edit the `toolchain` line
or add a new one, set to the latest Go 1.M patch release Go 1.M.P.
If Go 1.M is no longer supported, the `go` command
would use the minimum supported major version instead.

The command `go get go@1.20.1` would modify the `go` line to say `go 1.20.1`.
If the `toolchain` line is too old, then the update process just described would apply,
except that since the result would be matching `go` and `toolchain` lines,
the `toolchain` line would just be removed instead.

For direct control of the toolchain, `go get toolchain@go1.20.1` would
update the `toolchain` line. If too old a toolchain is specified, the command fails.
(It does not downgrade module dependencies to find a way to use an older toolchain.)

Updates like `go get go@latest` (or just `go get go`), `go get -p go`, and `go get toolchain@latest`
would work too.

### Downloading distributions

We have a mechanism for downloading verified software archives today:
the Go module system, including the checksum database.
This design would reuse that mechanism for Go distributions.
Each Go release would be treated as a set of module versions,
downloaded like any module, and checked against the checksum database
before being used.
In addition to this mapping, the `go` command would need to
set the execute bit on downloaded binaries.
This would be the first time we set the execute bit in the module cache,
at least on file systems with execute bits.
(On Windows, whether a file is executable depends only on its extension.)
The execute bit would only be set for the specific case of downloading
Go release modules, and only for the tool binaries.

A version like `go 1.18beta2` would map into the module download
machinery as `golang.org/release` version `v1.18.0-beta2.windows.amd64`
on a Windows/AMD64 system.
The version list (the `/@v/list` file) for the module would only list supported releases,
for use by the `go` command in toolchain updates.
Older releases would still be available when fetched directly,
just not listed in the default version list.

### Go command startup

At startup, before doing anything else, the `go` command would
find the `GOTOOLCHAIN` environment or configuration variable
and the `go` and `toolchain` lines from the work module's `go.mod` file
(or the workspace's `go.work` file)
and check whether it needs to use a different toolchain.
If not (for example, if `GOTOOLCHAIN=local` or if `GOTOOLCHAIN=auto`
and `go.mod` says `go 1.28` and the `go` command knows it is
already the Go 1.28 distribution), then the `go` command continues executing.
Otherwise, it looks for the requested Go release in the module cache,
downloading and unpacking it if needed,
and then re-execs the `go` command from that release.

### Effect in Dependencies

In a dependency module, the `go` line will continue to have
its “language semantics selection” effect,
as described earlier.

The Go toolchain will refuse to build a dependency that needs
newer Go semantics than the current toolchain.
For example if the work module says `go 1.27`
but a dependency says `go 1.28` and the toolchain
selection ends up using Go 1.27, Go 1.27 will see the
`go 1.28` line and refuse to build.
This should normally not happen:
the `go get` command that added the dependency
would have noticed the `go 1.28` line and
updated the work module's `toolchain` line to at least go1.28.

## Rationale

The rationale for the overall change was discussed in the background section.
People initially believe that every version listed a module's
`go.mod` is the minimum version used in any build of that module.
This is true except for the `go` line.
Systems such as Cloud Native Buildpacks have made the
`go` line select the Go toolchain, confusing matters further.

Making the `go` line specify a minimum toolchain version
better aligns with user expectations.
It would also align better with systems like Cloud Native Buildpacks,
although they should be updated to match the new semantics exactly.
The easiest way to do that would be for them to run a Go toolchain
that implements the new rules and let it do its default toolchain selection.

There is a potential downside for CI systems without local download caches:
they might download the Go release modules over and over again.
Of course, such systems already download ordinary modules over and over again,
but ordinary modules tend to be smaller.
Go 1.20 removes all `pkg/**.a` files from the Go distribution,
which cuts the distribution size by about a factor of three.
We may be able to cut the size further in Go 1.21.
The best solution is for CI systems to run local caching proxies,
which would speed up their ordinary module downloads too.

Of course, given the choice between
(1) having to wait for a CI system (or a Linux distribution, or a cloud provider)
to update the available version of Go and
(2) being able to use any Go version at the cost of slightly slower builds, I'd definitely choose (2).
And CI systems that insist on never downloading could force GOTOOLCHAIN=local in the environment,
and then the build will break if a newer `go` line slips into `go.mod`.

Some people have raised a concern about pressure on the build cache
because builds using different toolchains cannot share object files.
If this turns out to be a problem in practice, we can definitely adjust
the build cache maintenance algorithms. [Issue #29561](https://go.dev/issue/29561) tracks that.

## Compatibility

This proposal does not violate any existing compatibility requirements.

It can improve compatibility, for example by making sure that code written for Go 1.30
is never built with Go 1.29, even if the build appears to succeed.

## Implementation

Overall the implementation is fairly short and straightforward.
Documentation probably outweighs new code.
Russ Cox, Michael Matloob, and Bryan Millls will do the work.

There is no working sketch of the current design at the moment.
