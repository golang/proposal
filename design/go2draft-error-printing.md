# Error Printing — Draft Design

Marcel van Lohuizen\
August 27, 2018

## Abstract

This document is a draft design for additions to the errors package
to define defaults for formatting error messages,
with the aim of making formatting of different error message implementations interoperable.
This includes the printing of detailed information,
stack traces or other position information, localization, and limitations of ordering.

For more context, see the [error values problem overview](go2draft-error-values-overview.md).

## Background

It is common in Go to build your own error type.
Applications can define their own local types or use
one of the many packages that are available for defining errors.

Broadly speaking, errors serve several audiences:
programs, users, and diagnosers.
Programs may need to make decisions based on the value of errors.
This need is addressed in [the error values draft designs](go2draft-error-values-overview.md).
Users need a general idea of what went wrong.
Diagnosers may require more detailed information.
This draft design focuses on providing legible error printing
to be read by people—users and diagnosers—not programs.

When wrapping one error in context to produce a new error,
some error packages distinguish between opaque and transparent
wrappings, which affect whether error inspection is allowed to
see the original error.
This is a valid distinction.
Even if the original error is hidden from programs, however,
it should typically still be shown to people.
Error printing therefore must use an interface method
distinct from the common “next in error chain” methods
like `Cause`, `Reason`, or the error inspection draft design’s `Unwrap`.

There are several packages that have attempted to provide common error interfaces.
These packages typically do not interoperate well with each other or with bespoke error implementations.
Although the interfaces they define are similar, there are implicit assumptions that lead to poor interoperability.

## Design

This design focuses on printing errors legibly, for people to read.
This includes possible stack trace information,
a consistent ordering,
and consistent handling of formatting verbs.

### Error detail

The design allows for an error message to include additional detail
printed upon request, by using special formatting verb `%+v`.
This detail may include stack traces or other detailed information
that would be reasonable to elide in a shorter display.
Of course, many existing error implementations only have
a short display, and we don’t expect them to change.
But implementations that do track additional detail
will now have a standard way to present it.

### Printing API

The error printing API should allow

- consistent formatting and ordering,
- detailed information that is only printed when requested (such as stack traces),
- defining a chain of errors (possibly different from "reasons" or a programmatic chain),
- localization of error messages, and
- a formatting method that is easy for new error implementations to implement.

The design presented here introduces two interfaces
to satisfy these requirements: `Formatter` and `Printer`,
both defined in the [`errors` package](https://golang.org/pkg/errors).

An error that wants to provide additional detail implements the
`errors.Formatter` interface’s `Format` method.

The `Format` method is passed an `errors.Printer`,
which itself has `Print` and `Printf` methods.

	package errors

	// A Formatter formats error messages.
	type Formatter interface {
		// Format is implemented by errors to print a single error message.
		// It should return the next error in the error chain, if any.
		Format(p Printer) (next error)
	}

	// A Printer creates formatted error messages. It enforces that
	// detailed information is written last.
	//
	// Printer is implemented by fmt. Localization packages may provide
	// their own implementation to support localized error messages
	// (see for instance golang.org/x/text/message).
	type Printer interface {
		// Print appends args to the message output.
		// String arguments are not localized, even within a localized context.
		Print(args ...interface{})

		// Printf writes a formatted string.
		Printf(format string, args ...interface{})

		// Detail reports whether error detail is requested.
		// After the first call to Detail, all text written to the Printer
		// is formatted as additional detail, or ignored when
		// detail has not been requested.
		// If Detail returns false, the caller can avoid printing the detail at all.
		Detail() bool
	}

The `Printer` interface is designed to allow localization.
The `Printer` implementation will typically be supplied by the
[`fmt` package](https://golang.org/pkg/fmt)
but can also be provided by localization frameworks such as
[`golang.org/x/text/message`](https://golang.org/x/text/message).
If instead a `Formatter` wrote to an `io.Writer`,
localization with such packages would not be possible.

In this example, `myAddrError` implements `Formatter`:
Example:

	type myAddrError struct {
		address string
		detail  string
		err     error
	}

	func (e *myAddrError) Error() string {
		return fmt.Sprint(e) // delegate to Format
	}

	func (e *myAddrError) Format(p errors.Printer) error {
		p.Printf("address %s", e.address)
		if p.Detail() {
			p.Print(e.detail)
		}
		return e.err
	}

This design assumes that the
[`fmt` package](https://golang.org/pkg/fmt)
and localization frameworks will add code to recognize
errors that additionally implement `Formatter`
and use that method for `%+v`.
These packages already recognize `error`; recognizing `Formatter` is only a little more work.

Advantages of this API:

- This API clearly distinguishes informative detail from a causal error chain, giving less rise to confusion.
- Consistency between different error implementations:
  - interpretation of formatting flags
  - ordering of the error chain
  - formatting and indentation
- Less boilerplate for custom error types to implement:
  - only one interface to implement besides error
  - no need to implement `fmt.Formatter`.
- Flexible: no assumption about the kind of detail information an error implementation might want to print.
- Localizable: packages like golang.org/x/text/message can provide their own implementation of `errors.Printer` to allow translation of messages.
- Detail information is more verbose and somewhat discouraged.
- Performance: a single buffer can be used to print an error.
- Users can implement `errors.Printer` to produce formats.

### Format

Consider an error that returned by `foo` calling `bar` calling `baz`. An idiomatic Go error string would be:

	foo: bar(nameserver 139): baz flopped

We suggest the following format for messages with diagnostics detail,
assuming that each layer of wrapping adds additional diagnostics information.

	foo:
	    file.go:123 main.main+0x123
	--- bar(nameserver 139):
	    some detail only text
	    file.go:456
	--- baz flopped:
	    file.go:789

This output is somewhat akin to that of subtests.
The first message is printed as formatted,
but with the detail indented with 4 spaces.
All subsequent messages are indented 4 spaces
and prefixed with `---` and a space at the start of the message.

Indenting the detail of the first message
avoids ambiguity when multiple multiline errors
are printed one after the other.

### Formatting verbs

Today, `fmt.Printf` already prints errors using these verbs:

- `%s`: `err.Error()` as a string
- `%q`: `err.Error()` as a quoted string
- `%+q`: `err.Error()` as an ASCII-only quoted string
- `%v`: `err.Error()` as a string
- `%#v`: `err` as a Go value, in Go syntax

This design defines `%+v` to print the error in the detailed, multi-line format.

### Interaction with source line information

The following API shows how printing stack traces,
either top of the stack or full stacks per error,
could interoperate with this package
(only showing the parts of the API relevant to this discussion).

	package errstack

	type Stack struct { ... }

	// Format writes the stack information to p, but only
	// if detailed printing is requested.
	func (s *Stack) Format(p errors.Printer) {
		if p.Detail() {
			p.Printf(...)
		}
	}

This package would be used by adding a `Stack` to each error implementation
that wanted to record one:

	import ".../errstack"

	type myError struct {
		msg        string
		stack      errstack.Stack
		underlying error
	}

	func (e *myError) Format(p errors.Printer) error {
		p.Printf(e.msg)
		e.stack.Format(p)
		return e.underlying
	}

	func newError(msg string, underlying error) error {
		return &myError{
			msg:   msg,
			stack: errstack.New(),
		}
	}

### Localized errors

The [`golang.org/x/text/message` package](https://golang.org/x/text/message)
currently has its own
implementation of `fmt`-style formatting.
It would need to recognize `errors.Formatter` and
provide its own implementation of `errors.Printer`
with a translating `Printf` and localizing `Print`.

	import "golang.org/x/text/message"

	p := message.NewPrinter(language.Dutch)
	p.Printf("Error: %v", err)

Any error passed to `%v` that implements `errors.Formatter`
would use the localization machinery.
Only format strings passed to `Printf` would be translated,
although all values would be localized.
Alternatively, since errors are always text,
we could attempt to translate any error message,
or at least to have `gotext` do static analysis
similarly to what it does now for regular Go code.

To facilitate localization, `golang.org/x/text/message` could implement
an `Errorf` equivalent which delays the substitution of arguments
until it is printed so that it can be properly localized.

The `gotext` tool would have to be modified
to extract error string formats from code.
It should be easy to modify the analysis to pick up static error messages
or error messages that are formatted using an `errors.Printer`'s `Printf` method.
However, calls to `fmt.Errorf` will be problematic,
as it substitutes the arguments prematurely.
We may be able to change `fmt.Errorf` to evaluate and save its arguments
but delay the final formatting.

### Error trees

So far we have assumed that there is a single chain of errors.
To implement formatting a tree of errors, an error list type
could print itself as a new error chain,
returning this single error with the entire chain as detail.
Error list types occur fairly frequently,
so it may be beneficial to standardize on an error list type to ensure consistency.

The default output might look something like this:

	foo: bar: baz flopped (and 2 more errors)

The detailed listing would show all the errors:

	foo:
	--- multiple errors:
	    bar1
	    --- baz flopped
	    bar2
	    bar3

## Alternate designs

We considered defining multiple optional methods,
to provide fine-grained information such as the underlying error, detailed message, etc.
This had many drawbacks:

- Implementations needed to implement `fmt.Formatter` to correctly handle print verbs,
  which was cumbersome and led to inconsistencies and incompatibilities.
- It required having two different methods returning the “next error” in the wrapping chain:
  one to report the next for error inspection and one to report the next for printing.
  It was difficult to remember which was which.
- Error implementations needed too many methods.
- Most such approaches were incompatible with localization.

We also considered hiding the `Formatter` interface in the `fmt.State` implementation.
This was clumsy to implement and it shared the drawback of requiring error implementation authors
to understand how to implement all the relevant formatting verbs.

## Migration

Packages that currently do their own formatting will have to be rewritten
to use the new interfaces to maximize their utility.
In experimental conversions of
[`github.com/pkg/errors`](https://godoc.org/github.com/pkg/errors),
[`gopkg.in/errgo.v2`](https://godoc.org/gopkg.in/errgo.v2),
and
[`upspin.io/errors`](https://upspin.io/errors),
we found that implementing `Formatter` simplified printing logic considerably,
with the simultaneous benefit of making chains of these errors
interoperable.

This design’s detailed, multiline form is always an expansion of the single-line form,
proceeding through in the same order, outermost to innermost.
Other packages, like [`github.com/pkg/errors`](https://godoc.org/github.com/pkg/errors),
conventionally print detailed errors in the opposite order, contradicting the single-line form.
Users used to reading those errors will need to learn to read the new format.

## Disadvantages

The approach presented here does not provide any standard to programmatically
extract the information that is to be displayed in the messages.
It seems, though, there is no need for this.
The goal of this approach is interoperability and standardization, not providing structured access.

As noted in the previous section, existing error packages that
print detail will need to update their formatting implementations,
and some will find that the reporting order of errors has changed.

This approach does not specify a standard for printing trees.
Providing a standard error list type could help with this.
