# Go 2 language change template

Authors: Ian Lance Taylor, Robert Griesemer, Brad Fitzpatrick

Last updated: January, 2020

## Introduction

We get more language change proposals than we have time to review
thoroughly.
Changing the language has serious consequences that could affect the
entire Go ecosystem, so many factors come into consideration.

If you just have an idea for a language change, and would like help
turning it into a complete proposal, we ask that you not open an
issue, but instead discuss the idea on a forum such as [the
golang-nuts mailing
list](https://groups.google.com/forum/#!forum/golang-nuts).

Before proceeding with a full proposal, please review the requirements
listed in the Go blog article [Go 2, here we
come!](https://blog.golang.org/go2-here-we-come): Each language change
proposal must:

1. address an important issue for many people,
1. have minimal impact on everybody else, and
1. come with a clear and well-understood solution.

If you believe that your proposal meets these criteria and wish to
proceed, then in order to help with review we ask that you place your
proposal in context by answering the questions below as best you can.
You do not have to answer every question but please do your best.

## Template

- Would you consider yourself a novice, intermediate, or experienced Go programmer?
- What other languages do you have experience with?
- Would this change make Go easier or harder to learn, and why?
- Has this idea, or one like it, been proposed before?
  - If so, how does this proposal differ?
- Who does this proposal help, and why?
- What is the proposed change?
  - Please describe as precisely as possible the change to the language.
  - What would change in the [language spec](https://golang.org/ref/spec)?
  - Please also describe the change informally, as in a class teaching Go.
- Is this change backward compatible?
  - Breaking the [Go 1 compatibility guarantee](https://golang.org/doc/go1compat) is a large cost and requires a large benefit.
- Show example code before and after the change.
- What is the cost of this proposal? (Every language change has a cost).
  - How many tools (such as vet, gopls, gofmt, goimports, etc.) would be affected?
  - What is the compile time cost?
  - What is the run time cost?
- Can you describe a possible implementation?
  - Do you have a prototype? (This is not required.)
- How would the language spec change?
- Orthogonality: how does this change interact or overlap with existing features?
- Is the goal of this change a performance improvement?
  - If so, what quantifiable improvement should we expect?
  - How would we measure it?
- Does this affect error handling?
  - If so, how does this differ from [previous error handling proposals](https://github.com/golang/go/issues?utf8=%E2%9C%93&q=label%3Aerror-handling)?
- Is this about generics?
  - If so, how does this differ from the [the current design
    draft](https://go.googlesource.com/proposal/+/master/design/go2draft-contracts.md)
    and the [previous generics proposals](https://github.com/golang/go/issues?utf8=%E2%9C%93&q=label%3Agenerics)?

## What to avoid

If you are unable to answer many of these questions, perhaps your
change has some of these characteristics:

- Your proposal simply changes syntax from X to Y because you prefer Y.
- You believe that Go needs feature X because other languages have it.
- You have an idea for a new feature but it is very difficult to implement.
- Your proposal states a problem rather than a solution.

Such proposals are likely to be rejected quickly.

## Thanks

We believe that following this template will save reviewer time when
considering language change proposals.
