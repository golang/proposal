# Go 2 Draft Designs

As part of the Go 2 design process, we’ve
[published these draft designs](https://blog.golang.org/go2draft)
to start community discussions about three topics:
generics, error handling, and error value semantics.

These draft designs are not proposals in the sense of the [Go proposal process](https://golang.org/s/proposal).
They are starting points for discussion,
with an eventual goal of producing designs good enough to be turned into actual proposals.

Each of the draft designs is accompanied by a “problem overview” (think “cover letter”).
The problem overview is meant to provide context;
to set the stage for the actual design docs,
which of course present the design details;
and to help frame and guide discussion about the designs.
It presents background, goals, non-goals, design constraints,
a brief summary of the design,
a short discussion of what areas we think most need attention,
and comparison with previous approaches.

Again, these are draft designs, not official proposals. There are not associated proposal issues.
We hope all Go users will help us improve them and turn them into Go proposals.
We have established a wiki page to collect and organize feedback about each topic.
Please help us keep those pages up to date, including by adding links to your own feedback.

**Error handling**:

 - [overview](go2draft-error-handling-overview.md)
 - [draft design](go2draft-error-handling.md)
 - [wiki feedback page](https://golang.org/wiki/Go2ErrorHandlingFeedback)

**Error values**:

 - [overview](go2draft-error-values-overview.md)
 - [draft design for error inspection](go2draft-error-inspection.md)
 - [draft design for error printing](go2draft-error-printing.md)
 - [wiki feedback page](https://golang.org/wiki/Go2ErrorValuesFeedback)

**Generics**:

 - [overview](go2draft-generics-overview.md)
 - [draft design](go2draft-contracts.md)
 - [wiki feedback page](https://golang.org/wiki/Go2GenericsFeedback)

