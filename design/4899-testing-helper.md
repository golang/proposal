# Proposal: testing: better support test helper functions with TB.Helper

Author: Caleb Spare, based on previous work by Josh Bleecher Snyder

Last updated: 2016-12-27

Discussion at https://golang.org/issue/4899.

## Abstract

This proposal is about fixing the long-standing issue
[#4899](https://golang.org/issue/4899).

When a test calls a helper function that invokes, for instance,
`"*testing.T".Error`, the line number that is printed for the test failure
indicates the `Error` call site as inside the helper method.
This is almost always unhelpful for pinpointing the actual failure.

We propose to add a new `testing.TB` method, `Helper`,
which marks the calling function as a test helper.
When logging test messages, package testing ignores frames
that are inside marked helper functions.
It prints the first stack position inside a non-helper function.

## Background

In Go tests, it is common to use a helper function to perform some repeated
non-trivial check.
These are often of the form

    func helper(t *testing.T, other, args)

though other variants exist.
Such helper functions may be local to the test package or may come from external packages.
There are many examples of such helper functions in the standard library tests.
Some are listed below.

When a helper function calls `t.Error`, `t.Fatal`, or a related method,
the error message includes file:lineno output that indicates the location of the failure.
The failure location is currently considered inside the helper method, which is unhelpful.

The misplaced failure location also inhibits useful IDE features like
automatically jumping to the failure position.

There are a variety of workarounds to which people have resorted.

### 1. Ignore the problem, making it harder to debug test failures

This is a common approach.

If the helper is only called once from the `Test*` function,
then the problem is less severe:
the test failure prints the name of the `Test*` function that failed,
and by locating the only call to the helper within that function,
the user knows the failure site.
This is just an annoyance.

When the helper is called more than once, it can be impossible to locate the
source of the failure without further debugging.

A few examples of this pattern in the standard library:

- cmd/cover: `func run(c *exec.Cmd, t *testing.T)`
- cmd/go: the methods of `testgo`
- compress/flate: `writeToType(t *testing.T, ttype string, bw *huffmanBitWriter, tok []token, input []byte)`
- crypto/aes: `func mustPanic(t *testing.T, msg string, f func())`
- database/sql: `func numPrepares(t *testing.T, db *DB) int`
- encoding/json: `func diff(t *testing.T, a, b []byte)`
- fmt: `func presentInMap(s string, a []string, t *testing.T)`, `func check(t *testing.T, got, want string)`
- html/template: the methods of `testCase`
- image/gif: `func try(t *testing.T, b []byte, want string)`
- net/http: `func checker(t *testing.T) func(string, error)`
- os: `func touch(t *testing.T, name string)`
- reflect: `func assert(t *testing.T, s, want string)`
- sync/atomic: `func shouldPanic(t *testing.T, name string, f func())`
- text/scanner: `func checkPos(t *testing.T, got, want Position)` and some of its callers

### 2. Pass around more context to be printed as part of the error message

This approach adds enough information to the failure message to pinpoint the
source of failure, at the cost of greater burden on the test writer.
The result still isn't entirely satisfactory for the test invoker:
if the user only looks at the file:lineno in the failure message,
they are still led astray until they examine the full message.

Some standard library examples:

- bytes: `func check(t *testing.T, testname string, buf *Buffer, s string)`
- context: `func testDeadline(c Context, name string, failAfter time.Duration, t testingT)`
- debug/gosym: `func testDeadline(c Context, name string, failAfter time.Duration, t testingT)`
- mime/multipart: `func expectEq(t *testing.T, expected, actual, what string)`
- strings: `func equal(m string, s1, s2 string, t *testing.T) bool`
- text/scanner: `func checkTok(t *testing.T, s *Scanner, line int, got, want rune, text string)`

### 3. Use the \r workaround

This technique is used by test helper packages in the wild.
The idea is to print a carriage return from inside the test helper
in order to hide the file:lineno printed by the testing package.
Then the helper can print its own file:lineno and message.

One example is
[github.com/stretchr/testify](https://github.com/stretchr/testify/blob/2402e8e7a02fc811447d11f881aa9746cdc57983/assert/assertions.go#L226).

## Proposal

We propose to add two methods in package testing:

    // Helper marks the current function as a test helper function.
    // When printing file and line information
    // from methods such as t.Error, t.Fatal, and t.Log,
    // the current function will be skipped.
    func (t *T) Helper()

    // same doc comment
    func (b *B) Helper()

When package testing prints file:lineno, it walks up the stack,
skipping helper functions, and chooses the first entry in a non-helper function.

We also propose to add `Helper()` to the `testing.TB` interface.

## Rationale

### Alternative 1: allow the user to specify how many stack frames to skip

An alternative fix is to give the user control over the number of stack frames to skip.
This is similar to what package log already provides:

    func Output(calldepth int, s string) error
    func (l *Logger) Output(calldepth int, s string) error

For instance, in https://golang.org/cl/12405043 @robpike writes

>     // Up returns a *T object whose error reports identify the line n callers
>     // up the frame.
>     func (t *T) Up(n) *t { .... }
>
> Then you could write
>
>     t.Up(1).Error("this would be tagged with the caller's line number")

@bradfitz mentions similar APIs in [#4899](https://golang.org/issue/4899) and
[#14128](https://golang.org/issue/14128).

`Helper` is easier to use, because the user doesn't have to think about stack frames,
and it does not break when refactoring.

Also, it is not always easy to decide how many frames to skip.
A helper may be called through multiple paths, so it may be a variable depth
from the desired logging site.
For example, in the cmd/go tests, the `"*testgoData".must` helper is called directly
by some tests, but is also called by other helpers such as `"*testgoData".cd`.
Manual stack control would require the user to pass state into this method
in order to know whether to skip one or two frames.
Using the `Helper` API, the user would simply mark both `must` and `cd` as helpers.

### Alternative 2: use a special Logf/Errorf/Fatalf sentinel

Another approach given by @bradfitz in
[#14128](https://github.com/golang/go/issues/14128#issuecomment-176254702)
is to provide a magic format value:

     t.Logf("some value = %v", val, testing.NoDecorate)

This seems roughly equivalent in power to our proposal, but it has downsides:

* It breaks usual `printf` conventions (@adg [points out that vet would have to
  be aware of it](https://github.com/golang/go/issues/14128#issuecomment-176456878)).
* The mechanism is unusual -- it lacks precedent in the standard library.
* `NoDecorate` is less obvious in godoc than a TB method.
* Every `testing.T` method in a helper method must be decorated.
* It is not clear how to handle nested helpers other than by manually specifying
  the number of stack frames to skip, inheriting the problems of alternative 1.

## Compatibility

Adding a method to `*testing.T` and `*testing.B` raises no compatibility issues.

We will also add the method to the `testing.TB` interface.
Normally changing interface method sets is verboten,
but in this case it is be fine because `TB` has a private method
specifically to prevent other implementations:

    // A private method to prevent users implementing the
    // interface and so future additions to it will not
    // violate Go 1 compatibility.
    private()

## Implementation

@cespare will send a CL implementing `"testing.TB".Helper` based on
@josharian's previous work in https://golang.org/cl/79890043.

The CL will be sent before April 30, 2017 in order to make the 1.9 release cycle.

## Open issues

This change directly solves [#4899](https://golang.org/issue/4899).
