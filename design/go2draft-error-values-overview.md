# Error Values — Problem Overview

Russ Cox\
August 27, 2018

## Introduction

This overview and the accompanying
detailed draft designs
are part of a collection of [Go 2 draft design documents](go2draft.md).
The overall goal of the Go 2 effort is to address
the most significant ways that Go fails to scale
to large code bases and large developer efforts.

One way that Go programs fail to scale well is in the capability of typical errors.
A variety of popular helper packages add functionality
beyond the standard error interface,
but they do so in incompatible ways.
As part of Go 2, we are considering whether to standardize any
"optional interfaces" for errors,
to allow helper packages to interoperate
and ideally to reduce the need for them.

As part of Go 2, we are also considering,
as a separate concern,
more convenient [syntax for error checks and handling](go2draft-error-handling-overview.md).

## Problem

Large programs must be able to test for
and react to errors programmatically and also report them well.

Because an error value is any value implementing the [`error` interface](https://golang.org/ref/spec#Errors),
there are four ways that Go programs conventionally test for specific errors.
First, programs can test for equality with sentinel errors like `io.EOF`.
Second, programs can check for an error implementation type using a [type assertion](https://golang.org/ref/spec#Type_assertions) or [type switch](https://golang.org/ref/spec#Type_switches).
Third, ad-hoc checks like
[`os.IsNotExist`](https://golang.org/pkg/os/#IsNotExist)
check for a specific kind of error,
doing limited unwrapping.
Fourth, because neither of these approaches works in general when the error has been wrapped in additional context,
programs often do substring searches in the error text reported by `err.Error()`.
Obviously this last approach is the least desirable,
and it would be better to support the first three checks even in the presence of arbitrary wrapping.

The most common kind of wrapping is use of fmt.Errorf, as in

	if err != nil {
		return fmt.Errorf("write users database: %v", err)
	}

Wrapping in an error type is more work but more useful for programmatic tests, like in:

	if err != nil {
		return &WriteError{Database: "users", Err: err}
	}

Either way, if the original `err` is a known sentinel or known error implementation type,
then wrapping, whether by `fmt.Errorf` or a new type like `WriteError`,
breaks both equality checks and type assertions looking for the original error.
This discourages wrapping, leading to less useful errors.

In a complex program, the most useful description of an error
would include information about all the different operations leading to the error.
For example, suppose that the error writing to the database
earlier was due to an RPC call.
Its implementation called `net.Dial` of `"myserver"`,
which in turn read `/etc/resolv.conf`, which maybe today was accidentally unreadable.
The resulting error’s `Error` method might return this string (split onto two lines for this document):

	write users database: call myserver.Method: \
	    dial myserver:3333: open /etc/resolv.conf: permission denied

The implementation of this error is five different levels (four wrappings):

  1. A `WriteError`, which provides `"write users database: "` and wraps
  2. an `RPCError`, which provides `"call myserver.Method: "` and wraps
  3. a `net.OpError`, which provides `"dial myserver:3333: "` and wraps
  4. an `os.PathError`, which provides `"open /etc/resolv.conf: "` and wraps
  5. `syscall.EPERM`, which provides `"permission denied"`

There are many questions you might want to ask programmatically of err,
including:
(i) is it an RPCError?
(ii) is it a net.OpError?
(iii) does it satisfy the net.Error interface?
(iv) is it an os.PathError?
(v) is it a permission error?

The first problem is that it is too hard to ask these kinds of questions.
The functions [`os.IsExist`](https://golang.org/pkg/os/#IsExist),
[`os.IsNotExist`](https://golang.org/pkg/os/#IsNotExist),
[`os.IsPermission`](https://golang.org/pkg/os/#IsPermission),
and
[`os.IsTimeout`](https://golang.org/pkg/os/#IsTimeout)
are symptomatic of the problem.
They lack generality in two different ways:
first, each function tests for only one specific kind of error,
and second, each understands only a very limited number of wrapping types.
In particular, these functions understand a few wrapping errors,
notably [`os.PathError`](https://golang.org/pkg/os/#PathError), but
not custom implementations like our hypothetical `WriteError`.

The second problem is less critical but still important:
the reporting of deeply nested errors is too difficult to read
and leaves no room for additional detail,
like relevant file positions in the program.

Popular helper packages exist to address these problems,
but they disagree on the solutions and in general do not interoperate.

## Goals

There are two goals, corresponding to the two main problems.
First, we want to make error inspection by programs easier
and less error-prone, to improve the error handling and
robustness of real programs.
Second, we want to make it possible to print errors
with additional detail, in a standard form.

Any solutions must keep existing code working
and fit with existing source trees.
In particular, the concepts of comparing for equality with error sentinels
like `io.ErrUnexpectedEOF` and testing for errors of a particular type must be preserved.
Existing error sentinels must continue to be supported,
and existing code will not change to return different error types.
That said, it would be okay to expand functions like
[`os.IsPermission`](https://golang.org/pkg/os/#IsPermission) to understand arbitrary wrappings instead of a fixed set.

When considering solutions for printing additional error detail,
we prefer solutions that make it possible—or at least avoid making it impossible—to
localize and translate errors using
[golang.org/x/text/message](https://godoc.org/golang.org/x/text/message).

Packages must continue to be able to define their own error types easily.
It would be unacceptable to define a new, generalized "one true error implementation"
and require all code to use that implementation.
It would be equally unacceptable to add so many additional requirements
on error implementations that only a few packages would bother.

Errors must also remain efficient to create.
Errors are not exceptional.
It is common for errors to be generated, handled, and discarded,
over and over again, as a program executes.

As a cautionary tale, years ago at Google a program written
in an exception-based language was found to be spending
all its time generating exceptions.
It turned out that a function on a deeply-nested stack was
attempting to open each of a fixed list of file paths,
to find a configuration file.
Each failed open operation threw an exception;
the generation of that exception spent a lot of time recording
the very deep execution stack;
and then the caller discarded all that work and continued around its loop.
The generation of an error in Go code must remain a fixed cost,
regardless of stack depth or other context.
(In a panic, deferred handlers run _before_ stack unwinding
for the same reason: so that handlers that do care about
the stack context can inspect the live stack,
without an expensive snapshot operation.)

## Draft Design

The two main problems—error inspection and error formatting—are
addressed by different draft designs.
The constraints of keeping interoperation with existing code
and allowing packages to continue to define their own error types
point strongly in the direction of defining
optional interfaces that an error implementation can satisfy.
Each of the two draft designs adds one such interface.

### Error inspection

For error inspection, the draft design follows the lead of existing packages
like [github.com/pkg/errors](https://github.com/pkg/errors)
and defines an optional interface for an error to return the next error
in the chain of error wrappings:

	package errors

	type Wrapper interface {
		Unwrap() error
	}

For example, our hypothetical `WriteError` above would need to implement:

	func (e *WriteError) Unwrap() error { return e.Err }

Using this method, the draft design adds two new functions to package errors:

	// Is reports whether err or any of the errors in its chain is equal to target.
	func Is(err, target error) bool

	// As checks whether err or any of the errors in its chain is a value of type E.
	// If so, it returns the discovered value of type E, with ok set to true.
	// If not, it returns the zero value of type E, with ok set to false.
	func As(type E)(err error) (e E, ok bool)

Note that the second function has a type parameter, using the
[contracts draft design](go2draft-generics-overview.md).
Both functions would be implemented as a loop first testing
`err`, then `err.Unwrap()`, and so on, to the end of the chain.

Existing checks would be rewritten as needed to be "wrapping-aware":

	errors.Is(err, io.ErrUnexpectedEOF)     // was err == io.ErrUnexpectedEOF
	pe, ok := errors.As(*os.PathError)(err) // was pe, ok := err.(*os.PathError)

For details, see the [error inspection draft design](go2draft-error-inspection.md).

### Error formatting

For error formatting, the draft design defines an optional interface implemented by errors:

	package errors

	type Formatter interface {
		Format(p Printer) (next error)
	}

The argument to `Format` is a `Printer`, provided by the package formatting the error
(usually [`fmt`](https://golang.org/pkg/fmt), but possibly a localization package like
[`golang.org/x/text/message`](https://godoc.org/golang.org/x/text/message) instead).
The `Printer` provides methods `Print` and `Printf`, which emit output,
and `Detail`, which reports whether extra detail should be printed.

The `fmt` package would be adjusted to format errors printed using `%+v` in a multiline format,
with additional detail.

For example, our database `WriteError` might implement the new `Format` method and the old `Error` method as:

	func (e *WriteError) Format(p errors.Printer) (next error) {
		p.Printf("write %s database", e.Database)
		if p.Detail() {
			p.Printf("more detail here")
		}
		return e.Err
	}

	func (e *WriteError) Error() string { return fmt.Sprint(e) }

And then printing the original database error using `%+v` would look like:


	write users database:
	    more detail here
	--- call myserver.Method:
	--- dial myserver:3333:
	--- open /etc/resolv.conf:
	--- permission denied

The errors package might also provide a convenient implementation
for recording the line number of the code creating the error and printing it back when `p.Detail` returns true.
If all the wrappings involved included that line number information, the `%+v` output would look like:

	write users database:
	    more detail here
	    /path/to/database.go:111
	--- call myserver.Method:
	    /path/to/grpc.go:222
	--- dial myserver:3333:
	    /path/to/net/dial.go:333
	--- open /etc/resolv.conf:
	    /path/to/os/open.go:444
	--- permission denied

For details, see the [error printing draft design](go2draft-error-printing.md).

## Discussion and Open Questions

These draft designs are meant only as a starting point for community discussion.
We fully expect the details to be revised based on feedback and especially experience reports.
This section outlines some of the questions that remain to be answered.

**fmt.Errorf**.
If `fmt.Errorf` is invoked with a format ending in `": %v"` or `": %s"`
and with a final argument implementing the error interface,
then `fmt.Errorf` could return a special implementation
that implements both `Wrapper` and `Formatter`.
Should it? We think definitely yes to `Formatter`.
Perhaps also yes to `Wrapper`, or perhaps we should
introduce `fmt.WrapErrorf`.

Adapting `fmt.Errorf` would make nearly all existing code
using `fmt.Errorf` play nicely with `errors.Is`, `errors.As`,
and multiline error formatting.
Not adapting `fmt.Errorf` would instead require adding
some other API that did play nicely,
for use when only textual context needs to be added.

**Source lines**.
Many error implementations will want to record source lines
to be printed as part of error detail.
We should probably provide some kind of embedding helper
in [package `errors`](https://golang.org/pkg/errors)
and then also use that helper in `fmt.Errorf`.
Another question is whether `fmt.Errorf` should by default
record the file and line number of its caller, for display in the
detailed error format.

Microbenchmarks suggest that recording the caller’s file and line
number for printing in detailed displays would roughly double the
cost of `fmt.Errorf`, from about 250ns to about 500ns.

**Is versus Last**.
Instead of defining `errors.Is`,
we could define a function `errors.Last`
that returns the final error in the chain.
Then code would write `errors.Last(err) == io.ErrUnexpectedEOF`
instead of `errors.Is(err, io.ErrUnexpectedEOF)`

The draft design avoids this approach for a few reasons.
First, `errors.Is` seems a clearer statement of intent.
Second, the higher-level `errors.Is` leaves room for future adaptation,
instead of being locked into the single equality check.
Even today, the draft design’s implementation tests for equality with each error in the chain,
which would allow testing for a sentinel value
that was itself a wrapper (presumably of another sentinel)
as opposed to only testing the end of the error chain.
A possible future expansion might be to allow individual error implementations
to define their own optional `Is(error) bool` methods
and have `errors.Is` prefer that method over the default equality check.
In contrast, using the lower-level idiom
`errors.Last(err) == io.ErrUnexpectedEOF`
eliminates all these possibilities.

Providing `errors.Last(err)` might also encourage type checks
against the result, instead of using `errors.As`.
Those type checks would of course not test against
any of the wrapper types, producing a different result and
introducing confusion.

**Unwrap**. It is unclear if `Unwrap` is the right name for the method
returning the next error in the error chain.
Dave Cheney’s [`github.com/pkg/errors`](https://golang.org/pkg/errors) has popularized `Cause` for the method name,
but it also uses `Cause` for the function that returns the last error in the chain.
At least a few people we talked to
did not at first understand the subtle semantic difference between method and function.
An early draft of our design used `Next`, but all our explanations
referred to wrapping and unwrapping,
so we changed the method name to match.

**Feedback**. The most useful general feedback would be
examples of interesting uses that are enabled or disallowed
by the draft design.
We’d also welcome feedback about the points above,
especially based on experience
with complex or buggy error inspection or printing in real programs.

We are collecting links to feedback at
[golang.org/wiki/Go2ErrorValuesFeedback](https://golang.org/wiki/Go2ErrorValuesFeedback).

## Other Go Designs

### Prehistoric Go

The original representation of an error in Go was `*os.Error`, a pointer to this struct:

	// Error is a structure wrapping a string describing an error.
	// Errors are singleton structures, created by NewError, so their addresses can
	// be compared to test for equality. A nil Error pointer means ``no error''.
	// Use the String() method to get the contents; it handles the nil case.
	// The Error type is intended for use by any package that wishes to define
	// error strings.
	type Error struct {
		s string
	}

	func NewError(s string) *Error

In April 2009, we changed `os.Error` to be an interface:

	// An Error can represent any printable error condition.
	type Error interface {
		String() string
	}

This was the definition of errors in the initial public release,
and programmers learned to use equality tests and type checks to inspect them.

In November 2011, as part of the lead-up to Go 1,
and in response to feedback from Roger Peppe and others in the Go community,
we lifted the interface out of the standard library and into [the language itself](https://golang.org/ref/spec#Errors),
producing the now-ubiquitous error interface:

	type error interface {
		Error() string
	}

The names changed but the basic operations remained the name: equality tests and type checks.

### github.com/spacemonkeygo/errors

[github.com/spacemonkeygo/errors](https://godoc.org/github.com/spacemonkeygo/errors) (July 2013)
was written to support
[porting a large Python codebase to Go](https://medium.com/space-monkey-engineering/go-space-monkey-5f43744bffaa).
It provides error class hierarchies, automatic logging and stack traces, and arbitrary associated key-value pairs.

For error inspection,
it can test whether an error belongs to a particular class, optionally considering wrapped errors,
and considering entire hierarchies.

The `Error` type’s `Error` method returns a string giving the error class name,
message, stack trace if present, and other data.
There is also a `Message` method that returns just the message,
but there is no support for custom formatting.

### github.com/juju/errgo

[github.com/juju/errgo](https://github.com/juju/errgo) (February 2014)
was written to support Juju, a large Go program developed at Canonical.
When you wrap an error, you can choose whether to
adopt the cause of an underlying error or hide it.
Either way the underlying error is available to printing routines.

The package’s `Cause` helper function returns an error intended for the program to act upon,
but it only unwraps one layer,
in contrast to
[`github.com/pkg/errors`](https://godoc.org/github.com/pkg/errors)'s `Cause`
function, which returns the final error in the chain.

The custom error implementation’s `Error` method concatenates the messages of the errors
along the wrapping chain.
There is also a `Details` function that returns a JSON-like string
with both messages and location information.

### gopkg.in/errgo.v1 and gopkg.in/errgo.v2

[`gopkg.in/errgo.v1`](https://godoc.org/gopkg.in/errgo.v1) (July 2014)
is a slight variation of `github.com/juju/errgo`.
[`gopkg.in/errgo.v2`](https://godoc.org/gopkg.in/errgo.v2)
has the same concepts but a simpler API.

### github.com/hashicorp/errwrap

[`github.com/hashicorp/errwrap`](https://godoc.org/github.com/hashicorp/errwrap) (October 2014)
allows wrapping more than one error, resulting in a general tree of errors.
It has a general `Walk` method that invokes a function on every error in the tree,
as well as convenience functions for matching by type and message string.
It provides no special support for displaying error details.

### github.com/pkg/errors

[`github.com/pkg/errors`](https://godoc.org/github.com/pkg/errors) (December 2015)
provides error wrapping and stack trace capture.
It introduced `%+v` to format errors with additional detail.
The package assumes that only the last error of the chain is of interest,
so it provides a helper `errors.Cause` to retrieve that last error.
It does not provide any functions that consider the entire chain when looking for a match.

### upspin.io/error

[`upspin.io/errors`](https://godoc.org/upspin.io/errors)
is an error package customized for [Upspin](https://upspin.io),
documented in Rob Pike and Andrew Gerrand’s December 2017 blog post
“[Error handling in Upspin](https://commandcenter.blogspot.com/2017/12/error-handling-in-upspin.html).”

This package is a good reminder of the impact that a custom errors package
can have on a project, and that it must remain easy to implement bespoke
error implementations.
It introduced the idea of `errors.Is`, although the one in the draft design
differs in detail from Upspin’s.
We considered for a while whether it was possible to adopt
something like Upspin’s `errors.Match`, perhaps even to generalize
both the draft design’s `errors.Is` and `errors.As` into a single
primitive `errors.Match`.
In the end we could not.

## Designs in Other Languages

Most languages do not allow entirely user-defined error implementations.
Instead they define an exception base class that users extend;
the base class provides a common place to hang functionality
and would enable answering these questions in quite a different way.
But of course Go has no inheritance or base classes.

Rust is similar to Go in that it defines an error as anything
implementing a particular interface.
In Rust, that interface is three methods:
`Display` `fmt`, to print the display form of the error;
`Debug` `fmt`, to print the debug form of the error,
typically a dump of the data structure itself,
and `cause`, which returns the “lower-level cause of this error,”
analogous to `Unwrap`.

Rust does not appear to provide analogues to the draft design’s
`errors.Is` or `errors.As`, or any other helpers that walk the
error cause chain.
Of course, in Rust, the `cause` method is required, not optional.
