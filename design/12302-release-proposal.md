# Proposal: A minimal release process for Go projects

Author: Dave Cheney &lt;dave@cheney.net&gt;

Last updated: 1 September 2015

## Abstract

In the same way that gofmt defines a single recommended way to format Go source
code, this proposal aims to establish a single recommended procedure for
releasing Go projects.

This process is intended to be light weight to facilitate future tools that
automate the creation and consumption of released versions of Go projects.

## Background

Releasing software is useful. It separates the every day cut and thrust of
software development, patch review, bug triage, CI, from the consumers of this
software, a majority of whom are not developers of your software and only wish
to be concerned with the versions that you tell them are appropriate to use.

As a practical example, immediately following the Go 1.5 release and the
resumption of coding it is discovered that Go 1.4.2 was unable to compile the
golang.org/x/tools/go/types package.
This is the very essence of the problem; everyone pulling from head prevents
code that worked yesterday from working today, and developers must scramble to
make amends for a situation that they never intended to create.

A key differentiation between released and unreleased software is the version
number.
Version numbers create a distinct identifier that increments at its own pace
and under different drivers to the internal identifier of the version control
system (VCS) system or development team.

The colloquialism "to bless" a VCS revision as the released version
idiosyncratically, but accurately, captures the nature of act.
A revision, tracked by the development team's VCS software, will be chosen as
the single copy than best meets the requirements the team have set for
themselves and will be chosen, blessed, or more correctly tagged, with a
version number.

This proposal is concerned with only the minimal steps that are necessary to
separate released software, from unreleased software which is the domain of the
development teams themselves.

## Proposal

This proposal describes a minimal procedure for releasing Go projects by
tagging the repository which holds the project's source.

### Definitions

- *Project*: A Go project is a collection of one or more Go packages whose
  source is tracked together in a VCS repository.
- *Repository root*: A repository root, as defined by
  [cmd/go](https://golang.org/cmd/go/#hdr-Remote_import_paths), identifies both
  the unique import path prefix for the Go project, and the VCS repository that
  holds the project's source.
- *Version number*: A number derived from a scheme that uniquely identifies a
  particular release of a Go project.

### Release process

Go projects are released by tagging the project's repository root with a string
representing the chosen version number for that release.

This proposal recommends that Go projects adopt the
[Semantic Versioning 2.0 standard](http://SemVer.org/spec/v2.0.0.html) (SemVer)
for their version numbering scheme.

A tag, and thus a version number, once assigned must not be reused.

### Tag format

The format of the VCS tag is as follows:

```
v<SemVer>
```

That is, the character `v`, U+0075, followed directly by a string which is
compliant with the
[Semantic Versioning 2.0 standard](http://SemVer.org/spec/v2.0.0.html).

For compatibility existing projects may elide the `v` prefix. New projects
should include the `v` prefix in their tags.

Tags which do not fit the format described above should be ignored for the
purpose of determining which versions of a Go project are released.

## Rationale

Go projects do not have version numbers in the way it is commonly understood
by our counterparts in other languages communities.
This is because there is no formalised notion of releasing a Go project.
There is no recognised process of taking an arbitrary VCS commit hash and
assigning it a version number that is both meaningful for humans and machines.

Additionally, operating system distributors such as Debian and Ubuntu strongly
prefer to package released versions of a project, and are currently reduced to
[doing things like this](https://ftp-master.debian.org/new/golang-github-odeke-em-command_0.0~git20150727.0.cf17ee2-1.html).

This proposal establishes a the bare minimum required by humans and tools to
identify released versions of Go projects.
It is informed by the broad support for semantic versioning across our
contemporaries like node.js (npm), rust (cargo), javascript (bower), and ruby
(rubygems).
This proposal allows Go programmers to benefit from the experiences of these
other communities' dependency management ecosystems.

### Why recommend SemVer ?

Applying an opaque release tag is not sufficient, the tag has to contain enough
semantic meaning for humans and tools to compare two version numbers and infer
the degree of compatibility, or incompatibility between them.
This is the goal of semantic versioning.

To cut to the chase, SemVer is not a magic bullet, it cannot force developers
to not do the wrong thing, only incentivise them to do the right thing.
This property would hold true no matter what version numbering methodology
was proposed, SemVer or something of our own concoction.

There is a lot to gain from working from a position of assuming Go programmers
want to do the right thing, not engineer a straight jacket process which
prevents them from doing the wrong thing.
The ubiquity of gofmt'd code, in spite of the fact the compiler allows a much
looser syntax, is evidence of this.

Adherence to a commonly accepted ideal of what constitutes a major, minor and
patch release is informed by the same social pressures that drive Go
programmers to gofmt their code.

### Why allow the tag to contain an optional v prefix ?

The recommendation to include the `v` prefix is for compatibility with the
three largest Go projects, Docker, Kubernetes, and CoreOS.
Additionally the use of a `v` prefix is prevalent in other languages'
repositories.

With that said, the `v` itself carries no unique information itself and a
number of examples in Go projects that do use SemVer can be found with tags
that are just the bare SemVer form.

As the goal of this proposal is to establish a release process for Go projects,
not fight a needless battle over one character, this proposal makes the `v`
prefix optional for existing projects, and encourages new projects to adopt it.

## Out of scope

The following items are out of scope of this proposal:

- How Go projects can declare the version numbers or ranges for projects they
  depend on.
- How go get may be changed to consume this version information.

Additionally, this proposal not seek to change the release process, or version
numbering scheme for the Go (https://golang.org) distribution itself.

## Compatibility

There is no impact on the
[compatibility guidelines](https://golang.org/doc/go1compat) from this proposal.

## Implementation

This proposal or a summary should be posted on the
[golang.org](https://golang.org) website.

Future proposals should be compatible with this proposal's recommendations for
version numbering and release tag format.

There is no impact on the Go release cycle, this proposal is not bound by a
deliverable in the current release cycle.
