# Proposal: all, x/build/cmd/relui: automate go directive maintenance in golang.org/x repositories

Author(s): Dmitri Shuralyov
Thanks to: Russ Cox, Michael Pratt, Robert Findley, Hana Kim, Cody Oss, Tim King, Carlos Amedee, and others for input

Last updated: 2024-08-27

Discussion at https://go.dev/issue/69095.

## Abstract

The value of the `go` directive in golang.org/x repositories
is automatically maintained
to be at least 1.(N-1).0,
where Go 1.N is the most recent major Go release,
and Go 1.(N-1) is the previous major Go release.

## Background

In the beginning, there was the GOPATH mode and versions of dependencies
of golang.org/x repositories weren't explicitly tracked.
Go 1.11 introduced the module mode, and over time it became the default mode.
All golang.org/x repositories had an initial go.mod file checked in, and
that file was maintained manually.
This meant that a bug fix or a new feature in one golang.org/x repository
didn't benefit another golang.org/x repository until someone chose to manually
update that dependency.
It also meant that eventual updates sometimes jumped many versions at once
to catch up.
This was resolved in 2022, when an automated monthly relui workflow began to
create tags and update golang.org/x dependencies across all golang.org/x
repositories ([issue 48523](https://go.dev/issue/48523)).

At this point there are upwards of 35 [golang.org/x](https://golang.org/x)
repositories.
Owners of each repository update the "go" directive manually, ad-hoc,
so golang.org/x repositories may receive different levels of "go" directive
maintenance.
For example, owners of the golang.org/x/mod module wished to use the
new-to-Go-1.22 `go/version` package as soon as Go 1.23 came out, and
so its "go" directive was recently updated to "1.22.0".
On the other hand, golang.org/x/image hasn't been updated in a while, and
its "go" directive is currently still at "1.18",
which itself was an upgrade from "1.12" in [CL 526895](https://go.dev/cl/526895)
as part of bringing all golang.org/x repos to use at minimum Go 1.18 language
version ([issue 60268](https://go.dev/issue/48523)).

Leaving go directive maintenance to be done entirely manually creates the
possibility of some repositories staying on an older Go language version longer.
When there's enough of a need to finally upgrade it to a recent Go language
version, this requires a change across multiple major Go releases at once,
which can be harder to review.
Having continuous, smaller incremental upgrades requires creating many CLs for
all of golang.org/x repositories every 6 months, which is toilsome if always
done manually.

## Proposal

I propose that each time that a new major Go release 1.N.0 is made,
the `go` directive in all golang.org/x repos will be upgraded to `go 1.(N-1).0`.
For example,
when Go 1.28.0 is released,
golang.org/x modules would have their `go` directive set to `go 1.27.0`.

This would be done automatically as part of a relui release workflow,
which will generate CLs by running the following sequence at the module root
of applicable repositories:

```
go get go@1.(N-1).0
go mod tidy
go fix ./...
```

Using the go command at version `go1.N.0`.

Modules whose `go` directive at the time is already a higher version will be
skipped rather than downgraded.

If a `toolchain` directive is present and higher than the new go directive,
it will be kept as is.
(The go command does this automatically while updating the go line.)
If a `toolchain` directive isn't present,
these automated CLs will not try to introduce it.

The first two commands in the sequence leave the module in a tidy state.
The `go fix ./...` command will apply high-confidence automated changes,
in case any begin to apply with the updated Go language version.
For example, go fix began to remove the now-obsolete
[`// +build` lines](https://go.dev/doc/go1.18#go-build-lines) once a module
is upgraded to 1.18 or later.
For many new language versions this will be a no-op, but it is expected
that including a `go fix ./...` invocation will be a net positive.
We can decide to stop including it in the generated CLs based on experience.

If a `go.work` file is checked in (rare case), then `go work sync` will also
be run to sync the workspace's build list back to the workspace's modules.

## Rationale

### Why 1.(N-1).0?

N-1 is chosen to align with the
[Go release policy](https://go.dev/doc/devel/release#policy).
The Go release policy states that a given major Go release is supported
until there are two newer major releases.

Picking N-1 makes this a no-op for golang.org/x module users who are using
a supported Go release. If a user is using a pre-release version of the
previous (also supported) major Go release, they'll be upgraded to
the stable major release (e.g., `go1.22rc1` to `go1.22.0`).
For golang.org/x module authors, raising the go directive from a lower value
to N-1 enables taking advantage of newer language features and fixes potentially
sooner than if no one got to updating the module's language version manually.

### Why not 1.(N-0).0?

N-0 would get in the way of one's ability to use the latest versions of
golang.org/x modules with all supported Go releases.
It would be possible to use the latest major Go release,
but not the previous (still supported) major Go release,
at least not without triggering a toolchain upgrade to a newer major Go release.
The Go release policy states we support both releases equally,
and issue bug fixes and security fixes to both,
so this proposal preserves that equality.

### Why not N-2 (or N-3, or N-4, and so on)?

Using older versions gives the impression that those releases
are still supported,
but they are not.

### Why not bump on each minor release?

Another option would be to always use the latest 1.(N-1).X,
updating all the x repos each time a new minor Go release comes out.
That forces everyone to update to that new minor release
in order to incorporate any new x repo changes,
which seems too aggressive.
As much as we try to avoid it, minor Go releases do sometimes contain bugs,
and it should be possible to choose to use older ones if needed.

### Why not bump the toolchain lines too?

The `toolchain` line can only be set to a toolchain the same or newer than
the `go` line, and it only affects people working in the repo itself.
That is, it does not affect users of the x repos.
Therefore it is not as important.
Just as we want to allow users to use the x repos with any supported Go version,
we want to allow users to work in the x repos with any supported Go version, so
leaving the toolchain lines implied by the go line seems like the right choice.

### Future work

There are aspects of this work that have been considered but chosen to be left
out of scope for the initial version.
We may want to refine some of the smaller details down the road,
especially once there's more experience with the proposed mechanism.

#### Nested modules

Nested modules are not in scope of the current tagging,
and not in scope of the initial go directive maintenance either.
There are fewer of them, and they often have custom constraints
or release processes.
They can be left to be managed by their corresponding repo owners for now.
This can be revisited in the future, when it's more worthwhile.

## Compatibility

This proposal takes the [Go 1 Compatibility Promise](https://go.dev/doc/go1compat)
and the [Go Release Policy](https://go.dev/doc/devel/release#policy) into account,
and does not introduce compatibility problems.

## Implementation

This will be implemented as part of [relui](https://golang.org/x/build/cmd/relui),
a service already responsible for Go release automation and
monthly golang.org/x repository tagging.
