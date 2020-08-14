# Proposal: Multi-project gopls workspaces

Author(s): Heschi Kreinick, Rebecca Stambler

Last updated: [Date]

Discussion at https://golang.org/issue/37720.

## Abstract

We propose a new workspace model for gopls that supports editing multiple
projects at the same time, without compromising editor features.

## Background

`gopls` users may want to edit multiple projects in one editor session.
For example, a microservice might depend on a proprietary infrastructure
library, and a feature might require working across both. In `GOPATH` mode,
that's relatively trivial, because all code exists in the same context. In
module mode, where multiple versions of dependencies are in play, it is much
more difficult.

Consider the following application:

![Diagram of a single application](37720/Fig1.png)
If I `Find References` on an `errors.Wrapf` call in `app1`, I expect to see
references in `lib` as well. This is especially true if I happen to own `lib`,
but even if not I may be looking for usage examples. In this situation,
supporting that is easy.

Now consider a workspace with two applications.

![Diagram of two applications](37720/Fig2.png)

Again, I would expect a `Find References` in either App1 or App2 to find all
`Wrapf` calls, and there's no reason that shouldn't work in this scenario. In
module mode, things can be more difficult. Here's the next step in complexity:

![Diagram of two applications with different lib versions](37720/Fig3.png)

At the level of the type checker, `v1.0.0` and `v1.0.1` of the library are
completely unrelated packages that happen to share a name. We as humans expect
the APIs to match, but they could be completely different. Nonetheless, in this
situation we can simply load both, and if we do a `Find References` on `Wrapf`
there should be no problem finding all of them.
That goes away in the next step:

![Diagram of two applications with different versions of all deps](37720/Fig4.png)

Now there are two versions of `Wrapf`.
Again, at the type-checking level, these packages have nothing to do with each
other. There is no easy way to relate `Wrapf` from `v0.9.1` with its match from
`v0.9.0`. We would have to do a great deal of work to correlate all the
versions of a package together and match them up. (Wrapf is a simple case;
consider how we'd match them if it was a method receiver, or took a complex
struct, or a type from another package.) Worse yet, how would a multi-project
rename work? Would it rename in all versions?

One final case:

![Diagram of an application with dependency fan-out](37720/Fig5.png)
Imagine I start in App1 and `Go To Definition` on a function from the utility
library. So far, no problem: there's only one version of the utility library in
scope. Now I `Go To Definition` on `Wrapf`.
Which version should I go to?
The answer depends on where I came from, but that information can't be
expressed in the filesystem path of the source file, so there's no way for
`gopls` to keep track.

## Proposal

We propose to require all projects in a multi-project workspace use the same
set of dependency versions. For `GOPATH`, this means that all the projects
should have the same `GOPATH` setting. For module mode, it means creating one
super-module that forces all the projects to resolve their dependencies
together. Effectively, this would create an on-the-fly monorepo.
This rules out users working on projects with mutually conflicting
requirements, but that will hopefully be rare.
Hopefully `gopls` can create this super-module automatically.

The super-module would look something like:

```
module gopls-workspace

require (
    example.com/app1 v0.0.0-00010101000000-000000000000
    example.com/app2 v0.0.0-00010101000000-000000000000
)

replace (
    example.com/app1 => /abs/path/to/app1
    example.com/app2 => /abs/path/to/app2

    // Further replace directives included from app1 and app2
)
```

Note the propagation of replace directives from the constituent projects, since
they would otherwise not take effect.

## Rationale

For users to get the experience they expect, with all of the scenarios above
working, the only possible model is one where there's one version of any
dependency in scope at a time.
We don't think there are any realistic alternatives to this model.
We could try to include multiple versions of packages and then correlate them
by name and signature (as discussed above) but that would be error-prone to
implement. And if there were any problems matching things up, features like
`Find References` would silently fail.

## Compatibility

No compatibility issues.

## Implementation

The implementation involves (1) finding all of the modules in the view,
(2) automatically creating the super-module, and (3) adjusting gopls's
[go/packages] queries and `go` command calls to run in the correct modules.

When a view is created, we traverse the view's root folder and search for all
of the existing modules. These modules will then be used to programmatically
create the super-module. Once each view is created, it will load all of its
packages (initial workspace load). As of 2020-08-13, for views in GOPATH or in
a module, the initial workspace load takes the form of a `go list ./...` query.
With the current design, the initial workspace load will need be a query of the
form: `go list example.com/app1/... example.com/app12/...`, within the
super-module. In GOPATH mode, we will not create the super-module.

All [go/packages] queries should be made from the super-module directory. Only
`go mod` commands need to be made from the module to which they refer.

### The super-module's `go.mod` file

As of 2020-08-13, `gopls` relies on the `go` command's `-modfile` flag to avoid
modifying the user's existing `go.mod` file. We will continue to use the
`-modfile` flag when running the `go` command from within a module, but
`-modfile` is no longer necessary when we run the `go` command from the
super-module.

The `go` command does require that its working directory contain a `go.mod`
file, but we want to run commands from the super-module without exposing
super-module's `go.mod` file to the user. To handle this, we will create a
temporary directory containing the super-module's `go.mod` file, to act as the
module root for any [go/packages] queries.

### Configuration

#### `gopls.mod`

We should allow users to provide their own super-module `go.mod` file, for
extra control over the developer experience. This can also be used to mitigate
any issues with the automatic creation of the super-module. We should detect a
`gopls.mod` in the view's root folder and use that as the super-module if
present.

## Additional Considerations

The authors have not yet considered the full implications of this design on:

* Nested modules
  * A workspace pattern of `module`/... will include packages in nested modules
  inside it, whether the user wants them or not.
* Modules with replace directives (mentioned briefly above)
* Views containing a single module within the view's root folder
  * Consider not creating a super-module at all

If any issues are noted during the implementation process, this document will
be updated accordingly.

This design means that there is no longer any need to have multiple views in a
session. The `gopls` team will need to reconsider whether there is value in
offering users a standalone workspace for each workspace folder, rather than
merging all workspace folders into one view.

## Transition

Users have currently been getting support for multiple modules in `gopls` by
adding each module as its own workspace folder. Once the implementation is
complete, we will need to help users transition to this new model--otherwise
they will find that memory consumption rises, as `gopls` will have loaded the
same module into memory multiple times. We will need to detect if a workspace
folder is part of multiple views and alert the user to adjust their workspace.

While the `gopls` team implements this design, the super-module functionality
will be gated behind an opt-in flag.

## Open issues (if applicable)

The `go.mod` editing functionality of `gopls` should continue to work as it
does today, even in multi-project mode. Most likely it should simply continue
to operate in one project at a time.

[go/packages]: https://golang.org/x/tools/go/packages
