# Proposing Changes to Go

## Introduction

The Go project's development process is design-driven.
Significant changes to the language, libraries, or tools must be first
discussed, and sometimes formally documented, before they can be implemented.

This document describes the process for proposing, documenting, and
implementing changes to the Go project.

To learn more about Go's origins and development process, see the talks
[How Go Was Made](http://talks.golang.org/2015/how-go-was-made.slide),
[The Evolution of Go](http://talks.golang.org/2015/gophercon-goevolution.slide),
and [Go, Open Source, Community](http://blog.golang.org/open-source)
from GopherCon 2015.

## The Proposal Process

### Goals

- Make sure that proposals get a proper, fair, timely, recorded evaluation with
  a clear answer.
- Make past proposals easy to find, to avoid duplicated effort.
- If a design doc is needed, make sure contributors know how to write a good one.

### Definitions

- A **proposal** is a suggestion filed as a GitHub issue, identified by having
  the Proposal label.
- A **design doc** is the expanded form of a proposal, written when the
  proposal needs more careful explanation and consideration.

### Scope

The proposal process should be used for any notable change or addition to the
language, libraries and tools.
Since proposals begin (and will often end) with the filing of an issue, even
small changes can go through the proposal process if appropriate.
Deciding what is appropriate is matter of judgment we will refine through
experience.
If in doubt, file a proposal.

#### Compatibility

Programs written for Go version 1.x must continue to compile and work with
future versions of Go 1.
The [Go 1 compatibility document](http://golang.org/doc/go1compat) describes
the promise we have made to Go users for the future of Go 1.x.
Any proposed change must not break this promise.

#### Language changes

Go is a mature language and, as such, significant language changes are unlikely
to be accepted.
A "language change" in this context means a change to the
[Go language specification](https://golang.org/ref/spec).
(See the [release notes](https://golang.org/doc/devel/release.html) for
examples of recent language changes.)

### Process

- [Create an issue](https://golang.org/issue/new) describing the proposal.

- Like any GitHub issue, a Proposal issue is followed by an initial discussion
  about the suggestion. For Proposal issues:
	- The goal of the initial discussion is to reach agreement on the next step:
		(1) accept, (2) decline, or (3) ask for a design doc.
	- The discussion is expected to be resolved in a timely manner.
	- If the author wants to write a design doc, then they can write one.
	- In Go development historically, a lack of agreement means the
	  author should write a design doc.
	- If there is disagreement about whether there is agreement,
	  [adg@](mailto:adg@golang.org) is the arbiter.

- It's always fine to label a suggestion issue with Proposal to opt in to this process.

- It's always fine not to label a suggestion issue with Proposal.
  (If the suggestion needs a design doc or is declined but worth remembering,
  it is trivial to add the label later.)

- If a Proposal issue leads to a design doc:
	- The design doc should be checked in to [the proposal repository](https://github.com/golang/proposal/) as `design/NNNN-shortname.md`,
	  where `NNNN` is the GitHub issue number and `shortname` is a short name
	  (a few dash-separated words at most).
	- The design doc should follow [the template](design/TEMPLATE.md).
	- The design doc should address any specific issues asked for during the
	  initial discussion.
	- It is expected that the design doc may go through multiple checked-in revisions.
	- New design doc authors may be paired with a design doc "shepherd" to help work
	  on the doc.
	- If the author is a committer, each revision can be self-+2'ed.
	- Comments by others can be made on the Gerrit CLs or on the GitHub issue,
	  whatever makes sense.

- Once comments and revisions on the design doc wind down, there is a final
  discussion about the proposal.
	- The goal of the final discussion is to reach agreement on the next step:
		(1) accept or (2) decline.
	- The discussion is expected to be resolved in a timely manner.
	- In Go development historically, a lack of agreement means decline.
	- If there is disagreement about whether there is agreement,
	  [adg@](mailto:adg@golang.org) is the arbiter.

- The author (and/or other contributors) do the work as described by the
  "Implementation" section of the proposal.

#### Quick start for committers

If you're already familiar with writing design docs for the Go project,
the process has not changed much.
The main thing that has changed is where the proposal is published.

In the situation where you'd write and circulate a design doc as a Google doc
before, now you:

- Create a GitHub issue labeled Proposal, to get a number NNNN.
- Check in the Markdown-formatted design doc to
  [the proposal repository](https://github.com/golang/proposal/)
  as `design/NNNN-shortname.md`.
- Mail [golang-dev](https://groups.google.com/group/golang-dev/) as usual.

Worst case, by bypassing the initial discussion you've possibly written an
unnecessary design doc. Not a big deal.

## Help

If you need help with this process, please contact the Go contributors by posting
to the [golang-dev mailing list](https://groups.google.com/group/golang-dev).
(Note that the list is moderated, and that first-time posters should expect a
delay while their message is held for moderation.)

If you want to talk to someone off-list, contact Andrew Gerrand at <adg@golang.org>.

To learn about contributing to Go in general, see the
[contribution guidelines](https://golang.org/doc/contribute.html).
