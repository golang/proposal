# Error Inspection — Draft Design

Jonathan Amsterdam\
Damien Neil\
August 27, 2018

## Abstract

We present a draft design that adds support for
programmatic error handling to the standard errors package.
The design adds an interface to standardize the
common practice of wrapping errors.
It then adds a pair of helper functions in [package `errors`](https://golang.org/pkg/errors),
one for matching sentinel errors and one for matching errors by type.

For more context, see the [error values problem overview](go2draft-error-values-overview.md).

## Background

Go promotes the idea that [errors are values](https://blog.golang.org/errors-are-values)
and can be handled via ordinary programming.
One part of handling errors is extracting information from them,
so that the program can make decisions and take action.
(The control-flow aspects of error handling are [a separate topic](go2draft-error-handling-overview.md),
as is [formatting errors for people to read](go2draft-error-values-overview.md).)

Go programmers have two main techniques for providing information in errors.
If the intent is only to describe a unique condition with no additional data,
a variable of type error suffices, like this one from the [`io` package](https://golang.org/pkg/io).

	var ErrUnexpectedEOF = errors.New("unexpected EOF")

Programs can act on such _sentinel errors_ by a simple comparison:

	if err == io.ErrUnexpectedEOF { ... }

To provide more information, the programmer can define a new type
that implements the `error` interface.
For example, `os.PathError` is a struct that includes a pathname.
Programs can extract information from these errors by using type assertions:

	if pe, ok := err.(*os.PathError); ok { ... pe.Path ... }

Although a great deal of successful Go software has been written
over the past decade with these two techniques,
their weakness is the inability to handle the addition of new information to existing errors.
The Go standard library offers only one tool for this, `fmt.Errorf`,
which can be used to add textual information to an error:

	if err != nil {
		return fmt.Errorf("loading config: %v", err)
	}

But this reduces the underlying error to a string,
easily read by people but not by programs.

The natural way to add information while preserving
the underlying error is to _wrap_ it in another error.
The standard library already does this;
for example, `os.PathError` has an `Err` field that contains the underlying error.
A variety of packages outside the standard library generalize this idea,
providing functions to wrap errors while adding information.
(See the references below for a partial list.)
We expect that wrapping will become more common if Go adopts
the suggested [new error-handling control flow features](go2draft-error-handling-overview.md)
to make it more convenient.

Wrapping an error preserves its information, but at a cost.
If a sentinel error is wrapped, then a program cannot check
for the sentinel by a simple equality comparison.
And if an error of some type T is wrapped (presumably in an error of a different type),
then type-asserting the result to T will fail.
If we encourage wrapping, we must also support alternatives to the
two main techniques that a program can use to act on errors,
equality checks and type assertions.

## Goals

Our goal is to provide a common framework so that programs can treat errors
from different packages uniformly.
We do not wish to replace the existing error-wrapping packages.
We do want to make it easier and less error-prone for programs to act on errors,
regardless of which package originated the error or how it was augmented
on the way back to the caller.
And of course we want to preserve the correctness
of existing code and the ability for any package to declare a type that is an error.

Our design focuses on retrieving information from errors.
We don’t want to constrain how errors are constructed or wrapped,
nor must we in order to achieve our goal of simple and uniform error handling by programs.

## Design

### The Unwrap Method

The first part of the design is to add a standard, optional interface implemented by
errors that wrap other errors:

	package errors

	// A Wrapper is an error implementation
	// wrapping context around another error.
	type Wrapper interface {
		// Unwrap returns the next error in the error chain.
		// If there is no next error, Unwrap returns nil.
		Unwrap() error
	}

Programs can inspect the chain of wrapped errors
by using a type assertion to check for the `Unwrap` method
and then calling it.

The design does not add `Unwrap` to the `error` interface itself:
not all errors wrap another error,
and we cannot invalidate
existing error implementations.

### The Is and As Functions

Wrapping errors breaks the two common patterns for acting on errors,
equality comparison and type assertion.
To reestablish those operations,
the second part of the design adds two new functions: `errors.Is`, which searches
the error chain for a specific error value, and `errors.As`, which searches
the chain for a specific type of error.

The `errors.Is` function is used instead of a direct equality check:

	// instead of err == io.ErrUnexpectedEOF
	if errors.Is(err, io.ErrUnexpectedEOF) { ... }

It follows the wrapping chain, looking for a target error:

	func Is(err, target error) bool {
		for {
			if err == target {
				return true
			}
			wrapper, ok := err.(Wrapper)
			if !ok {
				return false
			}
			err = wrapper.Unwrap()
			if err == nil {
				return false
			}
		}
	}

The `errors.As` function is used instead of a type assertion:

	// instead of pe, ok := err.(*os.PathError)
	if pe, ok := errors.As(*os.PathError)(err); ok { ... pe.Path ... }

Here we are assuming the use of the [contracts draft design](go2draft-generics-overview.md)
to make `errors.As` explicitly polymorphic:

	func As(type E)(err error) (e E, ok bool) {
		for {
			if e, ok := err.(E); ok {
				return e, true
			}
			wrapper, ok := err.(Wrapper)
			if !ok {
				return e, false
			}
			err = wrapper.Unwrap()
			if err == nil {
				return e, false
			}
		}
	}

If Go 2 does not choose to adopt polymorphism or if we need a function
to use in the interim, we could write a temporary helper:

	// instead of pe, ok := err.(*os.PathError)
	var pe *os.PathError
	if errors.AsValue(&pe, err) { ... pe.Path ... }

It would be easy to mechanically convert this code to the polymorphic `errors.As`.

## Discussion

The most important constraint on the design
is that no existing code should break.
We intend that all the existing code in the standard library
will continue to return unwrapped errors,
so that equality and type assertion will behave exactly as before.

Replacing equality checks with `errors.Is` and type assertions with `errors.As`
will not change the meaning of existing programs that do not wrap errors,
and it will future-proof programs against wrapping,
so programmers can start using these two functions as soon as they are available.

We emphasize that the goal of these functions,
and the `errors.Wrapper` interface in particular, is to support _programs_, not _people_.
With that in mind, we offer two guidelines:

1. If your error type’s only purpose is to wrap other errors
with additional diagnostic information,
like text strings and code location, then don’t export it.
That way, callers of `As` outside your package
won’t be able to retrieve it.
However, you should provide an `Unwrap` method that returns the wrapped error,
so that `Is` and `As` can walk past your annotations
to the actionable errors that may lie underneath.

2. If you want programs to act on your error type but not any errors
you’ve wrapped, then export your type and do _not_ implement `Unwrap`.
You can still expose the information of underlying errors to people
by implementing the `Formatter` interface described
in the [error printing draft design](go2draft-error-values-overview.md).

As an example of the second guideline, consider a configuration package
that happens to read JSON files using the `encoding/json` package.
Malformed JSON files will result in a `json.SyntaxError`.
The package defines its own error type, `ConfigurationError`,
to wrap underlying errors.
If `ConfigurationError` provides an `Unwrap` method,
then callers of `As` will be able to discover the `json.SyntaxError` underneath.
If the use of a JSON is an implementation detail that the package wishes to hide,
`ConfigurationError` should still implement `Formatter`,
to allow multi-line formatting including the JSON error,
but it should not implement `Unwrap`, to hide the use of JSON from programmatic inspection.

We recognize that there are situations that `Is` and `As` don’t handle well.
Sometimes callers want to perform multiple checks against the same error,
like comparing against more than one sentinel value.
Although these can be handled by multiple calls to `Is` or `As`,
each call walks the chain separately, which could be wasteful.
Sometimes, a package will provide a function to retrieve information from an unexported error type,
as in this [old version of gRPC's status.Code function](https://github.com/grpc/grpc-go/blob/f4b523765c542aa30ca9cdb657419b2ed4c89872/status/status.go#L172).
`Is` and `As` cannot help here at all.
For cases like these,
programs can traverse the error chain directly.

## Alternative Design Choices

Some error packages intend for programs to act on a single error (the "Cause")
extracted from the chain of wrapped errors.
We feel that a single error is too limited a view into the error chain.
More than one error might be worth examining.
The `errors.As` function can select any error from the chain;
two calls with different types can return two different errors.
For instance, a program could both ask whether an error is a `PathError`
and also ask whether it is a permission error.

We chose `Unwrap` instead of `Cause` as the name for the unwrapping method
because different existing packages disagree on the meaning of `Cause`.
A new method will allow existing packages to converge.
Also, we’ve noticed that having both a `Cause` function and a `Cause` method
that do different things tends to confuse people.

We considered allowing errors to implement optional `Is` and `As` methods
to allow overriding the default checks in `errors.Is` and `errors.As`.
We omitted them from the draft design for simplicity.
For the same reason, we decided against a design that provided a tree of underlying errors,
despite its use in one prominent error package
([github.com/hashicorp/errwrap](https://godoc.org/github.com/hashicorp/errwrap)).
We also decided against explicit error hierarchies,
as in https://github.com/spacemonkeygo/errors.
The `errors.As` function’s ability to retrieve errors of more than one type
from the chain provides similar functionality:
if you want every `InvalidRowKey` error to be a `DatabaseError`, include both in the chain.

## References

We were influenced by several of the existing error-handling packages, notably:

 - [github.com/pkg/errors](https://godoc.org/github.com/pkg/errors)
 - [gopkg.in/errgo.v2](https://godoc.org/gopkg.in/errgo.v2)
 - [github.com/hashicorp/errwrap](https://godoc.org/github.com/hashicorp/errwrap)
 - [upspin.io/errors](https://commandcenter.blogspot.com/2017/12/error-handling-in-upspin.html)
 - [github.com/spacemonkeygo/errors](https://godoc.org/github.com/spacemonkeygo/errors)

Some of these package would only need to add an `Unwrap` method to their wrapping error types to be compatible with this design.

We also want to acknowledge Go proposals similar to ours:

 - [golang.org/issue/27020](https://golang.org/issue/27020) — add a standard Causer interface for Go 2 errors
 - [golang.org/issue/25675](https://golang.org/issue/25675) — adopt Cause and Wrap from github.com/pkg/errors
