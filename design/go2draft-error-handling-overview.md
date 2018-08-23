# Error Handling — Problem Overview

Russ Cox\
August 27, 2018

## Introduction

This overview and the accompanying
[detailed draft design](go2draft-error-handling.md)
are part of a collection of [Go 2 draft design documents](go2draft.md).
The overall goal of the Go 2 effort is to address
the most significant ways that Go fails to scale
to large code bases and large developer efforts.

One way that Go programs fail to scale well is in the
writing of error-checking and error-handling code.
In general Go programs have too much code checking errors
and not enough code handling them.
(This will be illustrated below.)
The draft design aims to address this problem by introducing
lighter-weight syntax for error checks
than the current idiomatic assignment-and-if-statement combination.

As part of Go 2, we are also considering, as a separate concern,
changes to the [semantics of error values](go2draft-error-values-overview.md),
but this document is only about error checking and handling.

## Problem

To scale to large code bases, Go programs must be lightweight,
[without undue repetition](https://www.youtube.com/watch?v=5kj5ApnhPAE),
and also robust,
[dealing gracefully with errors](https://www.youtube.com/watch?v=lsBF58Q-DnY)
when they do arise.

In the design of Go, we made a conscious choice
to use explicit error results and explicit error checks.
In contrast, C most typically uses explicit checking
of an implicit error result, [errno](http://man7.org/linux/man-pages/man3/errno.3.html),
while exception handling—found in many languages,
including C++, C#, Java, and Python—represents implicit checking of implicit results.

The subtleties of implicit checking are covered well in
Raymond Chen’s pair of blog posts,
"[Cleaner, more elegant, and wrong](https://blogs.msdn.microsoft.com/oldnewthing/20040422-00/?p=39683)" (2004),
and "[Cleaner, more elegant, and harder to recognize](https://blogs.msdn.microsoft.com/oldnewthing/20050114-00/?p=36693)" (2005).
In essence, because you can’t see implicit checks at all,
it is very hard to verify by inspection that the error handling code
correctly recovers from the state of the program at the time the check fails.

For example, consider this code, written in a hypothetical dialect of Go with exceptions:

	func CopyFile(src, dst string) throws error {
		r := os.Open(src)
		defer r.Close()

		w := os.Create(dst)
		io.Copy(w, r)
		w.Close()
	}

It is nice, clean, elegant code.
It is also invisibly wrong: if `io.Copy` or `w.Close` fails,
the code does not remove the partially-written `dst` file.

On the other hand, the equivalent actual Go code today would be:

	func CopyFile(src, dst string) error {
		r, err := os.Open(src)
		if err != nil {
			return err
		}
		defer r.Close()

		w, err := os.Create(dst)
		if err != nil {
			return err
		}
		defer w.Close()

		if _, err := io.Copy(w, r); err != nil {
			return err
		}
		if err := w.Close(); err != nil {
			return err
		}
	}

This code is not nice, not clean, not elegant, and still wrong:
like the previous version, it does not remove `dst` when `io.Copy` or `w.Close` fails.
There is a plausible argument that at least a visible check
could prompt an attentive reader to wonder about
the appropriate error-handling response at that point in the code.
In practice, however, error checks take up so much space
that readers quickly learn to skip them to see the structure of the code.

This code also has a second omission in its error handling.
Functions should typically [include relevant information](https://golang.org/doc/effective_go.html#errors)
about their arguments in their errors,
like `os.Open` returning the name of the file being opened.
Returning the error unmodified produces a failure
without any information about the sequence of operations that led to the error.

In short, this Go code has too much error checking
and not enough error handling.
A more robust version with more helpful errors would be:


	func CopyFile(src, dst string) error {
		r, err := os.Open(src)
		if err != nil {
			return fmt.Errorf("copy %s %s: %v", src, dst, err)
		}
		defer r.Close()

		w, err := os.Create(dst)
		if err != nil {
			return fmt.Errorf("copy %s %s: %v", src, dst, err)
		}

		if _, err := io.Copy(w, r); err != nil {
			w.Close()
			os.Remove(dst)
			return fmt.Errorf("copy %s %s: %v", src, dst, err)
		}

		if err := w.Close(); err != nil {
			os.Remove(dst)
			return fmt.Errorf("copy %s %s: %v", src, dst, err)
		}
	}

Correcting these faults has only made the code more correct, not cleaner or more elegant.

## Goals

For Go 2, we would like to make error checks more lightweight,
reducing the amount of Go program text dedicated to error checking.
We also want to make it more convenient to write error handling,
raising the likelihood that programmers will take the time to do it.

Both error checks and error handling must remain explicit,
meaning visible in the program text.
We do not want to repeat the pitfalls of exception handling.

Existing code must keep working and remain as valid as it is today.
Any changes must interoperate with existing code.

As mentioned above, it is not a goal of this draft design
to change or augment the semantics of errors.
For that discussion see the [error values problem overview](go2draft-error-values-overview.md).

## Draft Design

This section quickly summarizes the draft design,
as a basis for high-level discussion and comparison with other approaches.

The draft design introduces two new syntactic forms.
First, it introduces a checked expression `check f(x, y, z)` or `check err`,
marking an explicit error check.
Second, it introduces a `handle` statement defining an error handler.
When an error check fails, it transfers control to the innermost handler,
which transfers control to the next handler above it,
and so on, until a handler executes a `return` statement.

For example, the corrected code above shortens to:

	func CopyFile(src, dst string) error {
		handle err {
			return fmt.Errorf("copy %s %s: %v", src, dst, err)
		}

		r := check os.Open(src)
		defer r.Close()

		w := check os.Create(dst)
		handle err {
			w.Close()
			os.Remove(dst) // (only if a check fails)
		}

		check io.Copy(w, r)
		check w.Close()
		return nil
	}

The `check`/`handle` combination is permitted in functions
that do not themselves return errors.
For example, here is a main function from a
[useful but trivial program](https://github.com/rsc/tmp/blob/master/unhex/main.go):

	func main() {
		hex, err := ioutil.ReadAll(os.Stdin)
		if err != nil {
			log.Fatal(err)
		}

		data, err := parseHexdump(string(hex))
		if err != nil {
			log.Fatal(err)
		}

		os.Stdout.Write(data)
	}

It would be shorter and clearer to write instead:

	func main() {
		handle err {
			log.Fatal(err)
		}

		hex := check ioutil.ReadAll(os.Stdin)
		data := check parseHexdump(string(hex))
		os.Stdout.Write(data)
	}

For details, see the [draft design](go2draft-error-handling.md).

## Discussion and Open Questions

These draft designs are meant only as a starting point for community discussion.
We fully expect the details to be revised based on feedback and especially experience reports.
This section outlines some of the questions that remain to be answered.

**Check versus try**.
The keyword `check` is a clear statement of what is being done.
Originally we used the well-known exception keyword `try`.
This did read well for function calls:

	data := try parseHexdump(string(hex))

But it did not read well for checks applied to error values:

	data, err := parseHexdump(string(hex))
	if err == ErrBadHex {
		... special handling ...
	}
	try err

In this case, `check err` is a clearer description than `try err`.
Rust originally used `try!` to mark an explicit error check
but moved to a special `?` operator instead.
Swift also uses `try` to mark an explicit error check,
but also `try!` and `try?`, and as part of a broader
analogy to exception-handling that also includes `throw` and `catch`.

Overall it seems that the draft design’s `check`/`handle`
are sufficiently different from exception handling
and from Rust and Swift to justify the clearer keyword,
`check`, over the more familiar one, `try`.

Both Rust and Swift are discussed in more detail below.

**Defer**.
The error handling is in some ways similar to [`defer`](https://golang.org/ref/spec#Defer_statements) and
[`recover`](https://golang.org/ref/spec#Handling_panics),
but for errors instead of panics.
The current draft design makes error handlers chain lexically,
while `defer` builds up a chain at runtime
depending on what code executes.
This difference matters for handlers (or deferred functions)
declared in conditional bodies and loops.
Although lexical stacking of error handlers seems like a marginally better design,
it may be less surprising to match `defer` exactly.
As an example where `defer`-like handling would be more convenient,
if `CopyFile` established its destination `w` as either `os.Stdout` or the result of `os.Create`,
then it would be helpful to be able to introduce the `os.Remove(dst)` handler conditionally.

**Panics**.
We’ve spent a while trying to harmonize error handling and panics,
so that cleanup due to error handling need not be repeated for cleanup due to panics.
All our attempts at unifying the two only led to more complexity.

**Feedback**.
The most useful general feedback would be examples of interesting uses
that are enabled or disallowed by the draft design.
We’d also welcome feedback about the points above,
especially based on experience with complex
or buggy error handling in real programs.

We are collecting links to feedback at
[golang.org/wiki/Go2ErrorHandlingFeedback](https://golang.org/wiki/Go2ErrorHandlingFeedback).

## Designs in Other Languages

The problem section above briefly discussed C and exception-based languages.

Other recent language designs have also recognized
the problems caused by exception handling’s invisible error checks,
and those designs are worth examining in more detail.
The Go draft design was inspired, at least in part, by each of them.

## Rust

Like Go, [Rust distinguishes](https://doc.rust-lang.org/book/second-edition/ch09-00-error-handling.html)
between expected errors, like "file not found", and unexpected errors,
like accessing past the end of an array.
Expected errors are returned explicitly
while unexpected errors become program-ending panics.
But Rust has little special-purpose
language support for expected errors.
Instead, concise handling of expected errors
is done almost entirely by generics.

In Rust, functions return single values (possibly a single tuple value),
and a function returning a potential error returns a
[discriminated union `Result<T, E>`](https://doc.rust-lang.org/book/second-edition/ch09-02-recoverable-errors-with-result.html)
that is either the successful result of type `T` or an error of type `E`.

	enum Result<T, E> {
		Ok(T),
		Err(E),
	}

For example, `fs::File::Open` returns a `Result<fs::File, io::Error>`.
The generic `Result<T, E>` type defines an
[unwrap method](https://doc.rust-lang.org/book/second-edition/ch09-02-recoverable-errors-with-result.html#shortcuts-for-panic-on-error-unwrap-and-expect)
that turns a result into the underlying value (of type `T`)
or else panics (if the result represents an error).

If code does want to check an error instead of panicking,
[the `?` operator](https://doc.rust-lang.org/book/second-edition/ch09-02-recoverable-errors-with-result.html#a-shortcut-for-propagating-errors-the--operator)
macro-expands `use(result?)` into the Rust equivalent of this Go code:

	if result.err != nil {
		return result.err
	}
	use(result.value)


The `?` operator therefore helps shorten the error checking
and is very similar to the draft design’s `check`.
But Rust has no equivalent of `handle`:
the convenience of the `?` operator comes with
the likely omission of proper handling.
Rust’s equivalent of Go’s explicit error check `if err != nil` is
[using a `match` statement](https://doc.rust-lang.org/book/second-edition/ch09-02-recoverable-errors-with-result.html),
which is equally verbose.

Rust’s `?` operator began life as
[the `try!` macro](https://doc.rust-lang.org/beta/book/first-edition/error-handling.html#the-real-try-macro).

## Swift

Swift’s `try`, `catch`, and `throw` keywords appear at first glance to be
implementing exception handling, but really they are syntax for explicit error handling.

Each function’s signature specifies whether the function
can result in ("throw") an error.
Here is an [example from the Swift book](https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html#ID510):

	func canThrowErrors() throws -> String
	func cannotThrowErrors() -> String

These are analogous to the Go result lists `(string, error)` and `string`.

Inside a "throws" function, the
`throw` statement returns an error,
as in this [example, again from the Swift book](https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html#ID509):

	throw VendingMachineError.insufficientFunds(coinsNeeded: 5)

Every call to a "throws" function must specify at the call site
what to do in case of error. In general that means nesting the call
(perhaps along with other calls) inside a [do-catch block](https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html#ID541),
with all potentially-throwing calls marked by the `try` keyword:


	do {
		let s = try canThrowErrors()
		let t = cannotThrowErrors()
		let u = try canThrowErrors() // a second call
	} catch {
		handle error from try above
	}

The key differences from exception handling as in C++, Java, Python,
and similar languages are:

- Every error check is marked.
- There must be a `catch` or other direction about what to do with an error.
- There is no implicit stack unwinding.

Combined, those differences make all error checking,
handling, and control flow transfers explicit, as in Go.

Swift introduces three shorthands to avoid having
to wrap every throwing function call in a `do`-`catch` block.

First, outside a block, `try canThrowErrors()`
[checks for the error and re-throws it](https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html#ID510),
like Rust’s old `try!` macro and current `?` operator.

Second, `try! canThrowErrors()`
[checks for the error and turns it into a runtime assertion failure](https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html#ID513),
like Rust’s `.unwrap` method.

Third, `try? canThrowErrors()`
[evaluates to nil on error, or else the function’s result](https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html#ID542).
The Swift book gives this example:

	func fetchData() -> Data? {
		if let data = try? fetchDataFromDisk() { return data }
		if let data = try? fetchDataFromServer() { return data }
		return nil
	}

The example discards the exact reasons these functions failed.

For cleanup, Swift adds lexical [`defer` blocks](https://docs.swift.org/swift-book/LanguageGuide/ErrorHandling.html#ID514),
which run when the enclosing scope is exited, whether by an explicit `return` or by throwing an error.
