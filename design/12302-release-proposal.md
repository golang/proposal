# Proposal: A minimal release process for Go projects

Author: Dave Cheney &lt;dave@cheney.net&gt;

Last updated: 2 September 2015

## Abstract

In the same way that gofmt defines a single recommended way to format Go source
code, this proposal establishes a single recommended procedure for releasing
Go projects.

This is intended to be a light weight process to facilitate tools that automate
the creation and consumption of released versions of Go projects.

## Background

Releasing software is useful. It separates the every day cut and thrust of
software development, patch review, and bug triage, from the consumers of the
software, a majority of whom are not developers of your software and only wish
to be concerned with the versions that you tell them are appropriate to use.

For example, the Go project itself offers a higher level of support to users
who report bugs against our released versions.
In fact we specifically recommend against people using unreleased versions in
production.

A key differentiator between released and unreleased software is the version
number.
Version numbers create a distinct identifier that increments at its own pace
and under different drivers to the internal identifier of the version control
system (VCS) or development team.

## Proposal

This proposal describes a minimal procedure for releasing Go projects by
tagging the repository which holds the project's source.

### Release process

This proposal recommends that Go projects adopt the
[Semantic Versioning 2.0 standard](http://SemVer.org/spec/v2.0.0.html) (SemVer)
for their numbering scheme.

Go projects are released by tagging (eg. `git tag`) the project's VCS repository
with a string representing the SemVer compatible version number of that release.

This proposal is not restricted to git, any project stored in a VCS that has
the facility to assign a tag like entity to a revision is supported.

A tag, and thus a version number, once assigned must not be reused.

### Tag format

The format of the VCS tag is as follows:

```
v<SemVer>
```

That is, the character `v`, U+0075, followed directly by a string which is
compliant with the
[Semantic Versioning 2.0 standard](http://SemVer.org/spec/v2.0.0.html).

When inspecting a project's repository, tags which do not fit the format
described above must be ignored for the purpose of determining which versions
of a Go project are released.

## Rationale

Go projects do not have version numbers in the way it is commonly understood
by our counterparts in other languages communities.
This is because there is no formalised notion of releasing a Go project.
There is no recognised process of taking an arbitrary VCS commit hash and
assigning it a version number that is meaningful for both humans and machines.

Additionally, operating system distributors such as Debian and Ubuntu strongly
prefer to package released versions of a project, and are currently reduced to
[doing things like this](https://ftp-master.debian.org/new/golang-github-odeke-em-command_0.0~git20150727.0.cf17ee2-1.html).

In the spirit of doing less and enabling more, this proposal establishes a the
minimum required by humans and tools to identify released versions of Go
projects by inspecting their source code repositories.
It is informed by the broad support for semantic versioning across our
contemporaries like node.js (npm), rust (cargo), javascript (bower), and ruby
(rubygems), thereby allowing Go programmers to benefit from the experiences of
these other communities' dependency management ecosystems.

### Who benefits from adopting this proposal ?

This proposal will immediately benefit the downstream consumers of Go projects.
For example:

- The large ecosystem of tools like godeps, glide, govendor, gb, the
  vendor-spec proposal and dozens more, that can use this information to
  provide, for example, a command that will let users upgrade between minor
  versions, or update to the latest patch released of their dependencies rather
  than just the latest HEAD of the project.
- Operating system distributions such as Debian, Fedora, Ubuntu, Homebrew, rely
  on released versions of software for their packaging policies.
  They don't want to pull random git hashes into their archives, they want to
  pull released versions of the code and have release numbers that give them a
  sense of how compatible new versions are with the current version.
  For example, Ubuntu have a policy that we only accept patch releases into our
  LTS distribution, no major version changes, no minor version changes that
  include new features, only bug fixes.
- godoc.org could show users the documentation for the version of the package
  they were using, not just whatever is at HEAD.

That `go get` cannot consume this version information today should not be an
argument against enabling other tools to do so.

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

### Why not allow the v prefix to be optional ?

The recommendation to include the `v` prefix is for compatibility with the
three largest Go projects, Docker, Kubernetes, and CoreOS, who have already
adopted this form.

Permitting the `v` prefix to be optional would mean some projects adopt it, and
others do not, which is a poor position for a standard.
In the spirit of gofmt, mandating the `v` prefix across the board means there
is exactly one tag form for implementations to parse, and outweighs the
personal choice of an optional prefix.

## Compatibility

There is no impact on the
[compatibility guidelines](https://golang.org/doc/go1compat) from this proposal.

## Implementation

A summary of this proposal, along with examples and a link to this proposal,
will be added to the [How to write Go Code)(http://golang.org/doc/code.html#remote)
section of the [golang.org](https://golang.org) website.

Authors of Go projects who wish to release of their projects must tag their
software using a tag in the form described above. An example would be:
```
% git tag -a v1.0.0 -m "release version 1.0.0"
% git push --tags
```
Projects are not prohibited from using other methods of releasing their
software, but should be aware that if those methods do not conform to the
format described above, those releases may be invisible to tools confirming to
this proposal.

There is no impact on the Go release cycle, this proposal is not bound by a
deliverable in the current release cycle.

## Out of scope

The following items are out of scope of this proposal:

- How Go projects can declare the version numbers or ranges for projects they
  depend on.
- How go get may be changed to consume this version information.

Additionally, this proposal not seek to change the release process, or version
numbering scheme for the Go (https://golang.org) distribution itself.
