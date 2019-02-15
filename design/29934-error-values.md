# Proposal: Go 2 Error Inspection

Jonathan Amsterdam\
Russ Cox\
Marcel van Lohuizen\
Damien Neil

Last updated: January 25, 2019

Discussion at: https://golang.org/issue/29934

Past discussion at:
- https://golang.org/design/go2draft-error-inspection
- https://golang.org/design/go2draft-error-printing
- https://golang.org/wiki/Go2ErrorValuesFeedback

## Abstract

We propose several additions and changes to the standard library’s `errors` and
`fmt` packages, with the goal of making errors more informative for both
programs and people. We codify the common practice of wrapping one error in
another, and provide two convenience functions, `Is` and `As`, for traversing
the chain of wrapped errors.

We enrich error formatting by making it easy for error types to display
additional information when detailed output is requested with the `%+v`
formatting directive.

We add function, file and line information to the errors returned by
`errors.New` and `fmt.Errorf`, and provide a `Frame` type to simplify adding
location information to any error type.

We add support for detail formatting and wrapping to `fmt.Errorf`.

## Background

We provided background and a rationale in our [draft designs for error
inspection](https://go.googlesource.com/proposal/+/master/design/go2draft-error-inspection.md)
and
[printing](https://go.googlesource.com/proposal/+/master/design/go2draft-error-printing.md).
Here we provide a brief summary.

While Go 1’s definition of errors is open-ended, its actual support for errors
is minimal, providing only string messages. Many Go programmers want to provide
additional information with errors, and of course nothing has stopped them from
doing so. But one pattern has become so pervasive that we feel it is worth
enshrining in the standard library: the idea of wrapping one error in another
that provides additional information. Several packages provide wrapping support,
including the popular
[github.com/pkg/errors](https://godoc.org/github.com/pkg/errors).

Others have pointed out that indiscriminate wrapping can expose implementation
details, introducing undesired coupling between packages. As an example, the
[`errgo`](https://godoc.org/gopkg.in/errgo.v2) package lets users control
wrapping to hide details.

Another popular request is for location information in the form of stack frames.
Some advocate for complete stack traces, while others prefer to add location
information only at certain points.

## Proposal

We add a standard way to wrap errors to the standard library, to encourage the
practice and to make it easy to use. We separate error wrapping, designed for
programs, from error formatting, designed for people. This makes it possible to
hide implementation details from programs while displaying them for diagnosis.
We also add location (stack frame) information to standard errors and make it
easy for developers to include location information in their own errors.

All of the API changes are in the `errors` package. We also change the behavior
of parts of the `fmt` package.

### Wrapping

An error that wraps another error should implement `Wrapper` by defining an `Unwrap` method.
```
type Wrapper interface {
        // Unwrap returns the next error in the error chain.
        // If there is no next error, Unwrap returns nil.
        Unwrap() error
}
```
The `Unwrap` function is a convenience for calling the `Unwrap` method if one exists.
```
// Unwrap returns the result of calling the Unwrap method on err, if err implements Unwrap.
// Otherwise, Unwrap returns nil.
func Unwrap(err error) error
```

The `Is` function follows the chain of errors by calling `Unwrap`, searching for
one that matches a target. It is intended to be used instead of equality for
matching sentinel errors (unique error values). An error type can implement an
`Is` method to override the default behavior.

```
// Is reports whether any error in err's chain matches target.
//
// An error is considered to match a target if it is equal to that target or if
// it implements a method Is(error) bool such that Is(target) returns true.
func Is(err, target error) bool
```

The `As` function searches the wrapping chain for an error whose type matches
that of a target. An error type can implement `As` to override the default
behavior.
```
// As finds the first error in err's chain that matches the type to which target
// points, and if so, sets the target to its value and returns true. An error
// matches a type if it is assignable to the target type, or if it has a method
// As(interface{}) bool such that As(target) returns true. As will panic if target
// is not a non-nil pointer to a type which implements error or is of interface type.
//
// The As method should set the target to its value and return true if err
// matches the type to which target points.
func As(err error, target interface{}) bool
```

A [vet check](https://golang.org/cmd/vet) will be implemented to check that
the `target` argument is valid.


The `Opaque` function hides a wrapped error from programmatic inspection.
```
// Opaque returns an error with the same error formatting as err
// but that does not match err and cannot be unwrapped.
func Opaque(err error) error
```

### Stack Frames

The `Frame` type holds location information: the function name, file and line of
a single stack frame.
```
type Frame struct {
	// unexported fields
}
```

The `Caller` function returns a `Frame` at a given distance from the call site.
It is a convenience wrapper around `runtime.Callers`.
```
func Caller(skip int) Frame
```

To display itself, `Frame` implements a `Format` method that takes a `Printer`.
See [Formatting](#formatting) below for the definition of `Printer`.
```
// Format prints the stack as error detail.
// It should be called from an error's FormatError implementation,
// before printing any other error detail.
func (f Frame) Format(p Printer)
```

The errors returned from `errors.New` and `fmt.Errorf` include a `Frame` which
will be displayed when the error is formatted with additional detail (see
below).

### Formatting

We introduce two interfaces for error formatting into the `errors` package and
change the behavior of formatted output (the `Print`, `Println` and `Printf`
functions of the `fmt` package and their `S` and `F` variants) to recognize
them.

The `errors.Formatter` interface adds the `FormatError` method to the `error` interface.
```
type Formatter interface {
	error

	// FormatError prints the receiver's first error and returns the next error to
	// be formatted, if any.
	FormatError(p Printer) (next error)
}
```
An error type that wants to control its formatted output should implement
`Formatter`. During formatted output, `FormatError` will be called if it is
implemented, in preference to both the `Error` and `Format` methods.

`FormatError` returns an error, which will also be output if it is not `nil`. If
an error type implements `Wrapper`, then it would likely return the result of
`Unwrap` from `FormatError`, but it is not required to do so. An error that does
not implement `Wrapper` may still return a non-nil value from `FormatError`,
hiding implementation detail from programs while still displaying it to users.

The `Printer` passed to `FormatError` provides `Print` and `Printf` methods to
generate output, as well as a `Detail` method that reports whether the printing
is happening in "detail mode" (triggered by `%+v`). Implementations should first
call `Printer.Detail`, and if it returns true should then print detailed
information like the location of the error.
```
type Printer interface {
	// Print appends args to the message output.
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
```

When not in detail mode (`%v`, or in `Print` and `Println` functions and their
variants), errors print on a single line. In detail mode, errors print over
multiple lines, as shown here:
```
write users database:
    more detail here
    mypkg/db.Open
        /path/to/database.go:111
  - call myserver.Method:
    google.golang.org/grpc.Invoke
        /path/to/grpc.go:222
  - dial myserver:3333:
    net.Dial
        /path/to/net/dial.go:333
  - open /etc/resolv.conf:
    os.Open
        /path/to/os/open.go:444
  - permission denied
```

### Changes to `fmt.Errorf`

We modify the behavior of `fmt.Errorf` in the following case: if the last
argument is an error `err` and the format string ends with `: %s`, `: %v`, or
`: %w`, then the returned error will implement `FormatError` to return `err`. In
the case of the new verb `%w`, the returned error will also implement
`errors.Wrapper` with an `Unwrap` method returning `err`.

### Changes to the `os` package

The `os` package contains a several predicate functions which test
an error against a condition: `IsExist`, `IsNotExist`, `IsPermission`,
and `IsTimeout`.  For each of these conditions, we modify the `os`
package so that `errors.Is(err, os.ErrX)` returns true when
`os.IsX(err)` is true for any error in `err`'s chain. The `os` package
already contains `ErrExist`, `ErrIsNotExist`, and `ErrPermission`
sentinel values; we will add `ErrTimeout`.

### Transition

If we add this functionality to the standard library in Go 1.13, code that needs
to keep building with previous versions of Go will not be able to depend on the
new standard library. While every such package could use build tags and multiple
source files, that seems like too much work for a smooth transition.

To help the transition, we will publish a new package
[golang.org/x/xerrors](https://godoc.org/golang.org/x/xerrors), which will work
with both Go 1.13 and earlier versions and will provide the following:

- The `Wrapper`, `Frame`, `Formatter` and `Printer` types described above.
- The `Unwrap`, `Is`, `As`, `Opaque` and `Caller` functions described above.
- A `New` function that is a drop-in replacement for `errors.New`, but returns
  an error that behaves as described above.
- An `Errorf` function that is a drop-in replacement for `fmt.Errorf`, except
  that it behaves as described above.
- A `FormatError` function that adapts the `Format` method to use the new
  formatting implementation. An error implementation can make sure earlier Go
  versions call its `FormatError` method by adding this `Format` method:
  ```
  type MyError ...

  func (m *MyError) Format(f fmt.State, c rune) { // implements fmt.Formatter
      xerrors.FormatError(m, f, c) // will call m.FormatError
  }
  
  func (m *MyError) Error() string { ... }
  func (m *MyError) FormatError(p xerrors.Printer) error { ... } 
  ```

## Rationale

We provided a rationale for most of these changes in the draft designs (linked
above). Here we justify the parts of the design that have changed or been added
since those documents were written.

- The original draft design proposed that the `As` function use generics, and
  suggested an `AsValue` function as a temporary alternative until generics were
  available. We find that the `As` function in the form we describe here is just
  as concise and readable as a generic version would be, if not more so.

- We added the ability for error types to modify the default behavior of the
  `Is` and `As` functions by implementing `Is` and `As` methods, respectively.
  We felt that the extra power these give to error implementers was worth the
  slight additional complexity.

- We included a `Frame` in the errors returned by `errors.New` and `fmt.Errorf`
  so that existing Go programs could reap the benefits of location information.
  We benchmarked the slowdown from fetching stack information and felt that it
  was tolerable.

- We changed the behavior of `fmt.Errorf` for the same reason: so existing Go
  programs could enjoy the new formatting behavior without modification. We
  decided against wrapping errors passed to `fmt.Errorf` by default, since doing
  so would effectively change the exposed surface of a package by revealing the
  types of the wrapped errors. Instead, we require that programmers opt in to
  wrapping by using the new formatting verb `%w`.

- Lastly, we want to acknowledge the several comments on the [feedback
  wiki](https://golang.org/wiki/Go2ErrorValuesFeedback) that suggested that we
  go further by incorporating a way to represent multiple errors as a single
  error value. We understand that this is a popular request, but at this point
  we feel we have introduced enough new features for one proposal, and we’d like
  to see how these work out before adding more. We can always add a multi-error
  type in a later proposal, and meanwhile it remains easy to write your own.

## Compatibility

None of the proposed changes violates the [Go 1 compatibility
guidelines](https://golang.org/doc/go1compat). Gathering frame information may
slow down `errors.New` slightly, but this is unlikely to affect practical
programs. Errors constructed with `errors.New` and `fmt.Errorf` will display
differently with `%+v`.

## Implementation

The implementation requires changes to the standard library.

The [golang.org/x/exp/errors](https://godoc.org/golang.org/x/exp/errors) package
contains a proposed implementation by Marcel van Lohuizen. We intend to make the
changes to the main tree at the start of the Go 1.13 cycle, around February 1.

As noted in our blog post ["Go 2, here we
come!"](https://blog.golang.org/go2-here-we-come), the development cycle will
serve as a way to collect experience about these new features and feedback from
(very) early adopters.

As noted above, the
[golang.org/x/xerrors](https://godoc.org/golang.org/x/xerrors) package, also by
Marcel, will provide code that can be used with earlier Go versions.
