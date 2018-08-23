# Error Handling — Draft Design

Marcel van Lohuizen\
August 27, 2018

## Abstract

We present a draft design to extend the Go language with dedicated error handling constructs.
These constructs are in the spirit of "[errors are values](https://blog.golang.org/errors-are-values)"
but aim to reduce the verbosity of handling errors.

For more context, see the [error handling problem overview](go2draft-error-handling-overview.md).

## Background

There have been many proposals over time to improve error handling in Go. For instance, see:

*   [golang.org/issue/21161](https://golang.org/issue/21161): simplify error handling with `|| err` suffix
*   [golang.org/issue/18721](https://golang.org/issue/18721): add "must" operator `#` to check and return error
*   [golang.org/issue/16225](https://golang.org/issue/16225): add functionality to remove repetitive `if err != nil` return
*   [golang.org/issue/21182](https://golang.org/issue/21182): reduce noise in return statements that contain mostly zero values
*   [golang.org/issue/19727](https://golang.org/issue/19727): add vet check for test of wrong `err` variable
*   [golang.org/issue/19642](https://golang.org/issue/19642): define `_` on right-hand side of assignment as zero value
*   [golang.org/issue/19991](https://golang.org/issue/19991): add built-in result type, like Rust, OCaml

Related, but not addressed by this proposal:

*   [golang.org/issue/20803](https://golang.org/issue/20803): require call results to be used or explicitly gnored
*   [golang.org/issue/19511](https://golang.org/issue/19511): “Writing Web Applications” ignores error from `ListenAndServe`
*   [golang.org/issue/20148](https://golang.org/issue/20148): add vet check for missing test of returned error

We have also consulted the [experience reports about error handling](https://golang.org/wiki/ExperienceReports#error-handling).

Many of the proposals focus on verbosity.
both the verbosity of having to check error values
and the verbosity of zeroing out non-error return values.
Other proposals address issues related to correctness,
like error variable shadowing or the relative ease with which one can forget to check an error value.

This draft design incorporates many of the suggestions made in these issues.

## Design

This draft design builds upon the convention in Go programs
that a function that can fail
returns an `error` value as its final result.

This draft design introduces the keywords `check` and `handle`,
which we will introduce first by example.

Today, errors are commonly handled in Go using the following pattern:

	func printSum(a, b string) error {
		x, err := strconv.Atoi(a)
		if err != nil {
			return err
		}
		y, err := strconv.Atoi(b)
		if err != nil {
			return err
		}
		fmt.Println("result:", x + y)
		return nil
	}

With the `check`/`handle` construct, we can instead write:

	func printSum(a, b string) error {
		handle err { return err }
		x := check strconv.Atoi(a)
		y := check strconv.Atoi(b)
		fmt.Println("result:", x + y)
		return nil
	}

For each check, there is an implicit handler chain function,
explained in more detail below.
Here, the handler chain is the same for each check
and is defined by the single `handle` statement to be:

	func handleChain(err error) error {
		return err
	}

The handler chain is only presented here as a function to define its semantics;
it is likely to be implemented differently inside the Go compiler.

### Checks

A `check` applies to an expression of type `error`
or a function call returning a list of values ending in
a value of type `error`.
If the error is non-nil.
A `check` returns from the enclosing function
by returning the result of invoking the handler chain
with the error value.
A `check` expression applied to a function call returning multiple results
evaluates to the result of that call with the final error result removed.
A `check` expression applied to a plain expression or to a function call returning only an error value
cannot itself be used as a value; it can only appear as an expression statement.

Given new variables `v1`, `v2`, ..., `vN`, `vErr`,

	v1, ..., vN := check <expr>

is equivalent to:

	v1, ..., vN, vErr := <expr>
	if vErr != nil {
		<error result> = handlerChain(vn)
		return
	}

where `vErr` must have type `error` and `<error result>` denotes
the (possibly unnamed) error result from the enclosing function.
Similarly,

	foo(check <expr>)

is equivalent to:

	v1, ..., vN, vErr := <expr>
	if vErr != nil {
		<error result> = handlerChain(vn)
		return
	}
	foo(v1, ..., vN)

If the enclosing function has no final error result,
a failing `check` calls `handlerChain` followed by a return.

Since a `check` is an expression, we could write the `printSum` example above as:

	func printSum(a, b string) error {
		handle err { return err }
		fmt.Println("result:", check strconv.Atoi(x) + check strconv.Atoi(y))
		return nil
	}

For purposes of order of evaluation, `check` expressions are treated as equivalent to function calls.

In general, the syntax of `check` is:

	UnaryExpr  = PrimaryExpr | unary_op UnaryExpr | CheckExpr .
	CheckExpr  = "check" UnaryExpr .

It is common for idiomatic Go code to wrap the error with context information.
Suppose our original example wrapped the error with the name of the function:

	func printSum(a, b string) error {
		x, err := strconv.Atoi(a)
		if err != nil {
			return fmt.Errorf("printSum(%q + %q): %v", a, b, err)
		}
		y, err := strconv.Atoi(b)
		if err != nil {
			return fmt.Errorf("printSum(%q + %q): %v", a, b, err)
		}
		fmt.Println("result:", x+y)
		return nil
	}

Using a handler allows writing the wrapping just once:

	func printSum(a, b string) error {
		handle err {
			return fmt.Errorf("printSum(%q + %q): %v", a, b, err)
		}
		x := check strconv.Atoi(a)
		y := check strconv.Atoi(b)
		fmt.Println("result:", x + y)
		return nil
	}

It is not necessary to vary the wrapping code to determine where in `printSum` the error occurred:
The error returned by `strconv.Atoi` will include its argument.
This design encourages writing more idiomatic and cleaner error messages
and is in keeping with existing Go practice, at least in the standard library.

### Handlers

The `handle` statement defines a block, called a _handler_, to handle an error detected by a `check`.
A `return` statement in a handler
causes the enclosing function to return immediately with the given return values.
A `return` without values is only allowed if the enclosing function
has no results or uses named results.
In the latter case,  the function returns with the current values
of those results.

The syntax for a `handle` statement is:

	Statement   = Declaration | … | DeferStmt | HandleStmt .
	HandleStmt  = "handle" identifier Block .

A _handler chain function_ takes an argument of type `error`
and has the same result signature as the function
for which it is defined.
It executes all handlers in lexical scope in reverse order of declaration
until one of them executes a `return` statement.
The identifier used in each `handle` statement
maps to the argument of the handler chain function.

Each check may have a different handler chain function
depending on the scope in which it is defined. For example, consider this function:

    func process(user string, files chan string) (n int, err error) {
	    handle err { return 0, fmt.Errorf("process: %v", err)  }      // handler A
	    for i := 0; i < 3; i++ {
	        handle err { err = fmt.Errorf("attempt %d: %v", i, err) } // handler B
	        handle err { err = moreWrapping(err) }                    // handler C

	        check do(something())  // check 1: handler chain C, B, A
	    }
	    check do(somethingElse())  // check 2: handler chain A
	}

Check 1, inside the loop, runs handlers C, B, and A, in that order.
Note that because `handle` is lexically scoped,
the handlers defined in the loop body do not accumulate
on each new iteration, in contrast to `defer`.

Check 2, at the end of the function, runs only handler A,
no matter how many times the loop executed.

It is a compile-time error for a handler chain function body to be empty:
there must be at least one handler, which may be a default handler.

As a consequence of what we have introduced so far:

- There is no way to resume control in the enclosing function after `check` detects an error.
- Any handler always executes before any deferred functions are executed.
- If the enclosing function has result parameters, it is a compile-time error if the handler chain for any check
  is not guaranteed to execute a `return` statement.

A panic in a handler executes as if it occurred in the enclosing function.

### Default handler

All functions whose last result is of type `error` begin with an implicit _default handler_.
The default handler assigns the error argument to the last result and then returns,
using the other results unchanged.
In functions without named results, this means using zero values for the leading results.
In functions with named results, this means using the current values of those results.

Relying on the default handler, `printSum` can be rewritten as

	func printSum(a, b string) error {
		x := check strconv.Atoi(a)
		y := check strconv.Atoi(b)
		fmt.Println("result:", x + y)
		return nil
	}

The default handler eliminates one of the motivations for
[golang.org/issue/19642](https://golang.org/issue/19642)
(using `_` to mean a zero value, to make explicit error returns shorter).

In case of named return values,
the default handler does not guarantee the non-error return values will be zeroed:
the user may have assigned values to them earlier.
In this case it will still be necessary to specify the zero values explicitly,
but at least it will only have to be done once.

### Stack frame preservation

Some error handling packages, like [github.com/pkg/errors](https://github.com/pkg/errors),
decorate errors with stack traces.
To preserve the ability to provide this information,
a handler chain appears to the runtime
as if it were called by the enclosing function,
in its own stack frame.
The `check` expression appears in the stack
as the caller of the handler chain.

There should be some helper-like mechanism to allow skipping
over handler stack frames. This will allow code like

	func TestFoo(t *testing.T) {
		for _, tc := range testCases {
			x, err := Foo(tc.a)
			if err != nil {
				t.Fatal(err)
			}
			y, err := Foo(tc.b)
			if err != nil {
				t.Fatal(err)
			}
			if x != y {
				t.Errorf("Foo(%v) != Foo(%v)", tc.a, tc.b)
			}
		}
	}

to be rewritten as:

	func TestFoo(t *testing.T) {
		handle err { t.Fatal(err) }
		for _, tc := range testCases {
			x := check Foo(tc.a)
			y := check Foo(tc.b)
			if x != y {
				t.Errorf("Foo(%v) != Foo(%v)", tc.a, tc.b)
			}
		}
	}

while keeping the error line information useful. Perhaps it would be enough to allow:

	handle err {
		t.Helper()
		t.Fatal(err)
	}

### Variable shadowing

The use of `check` avoids repeated declaration of variables named `err`,
which was the main motivation for
allowing a mix of new and predeclared variables in [short variable declarations](https://golang.org/ref/spec#Short_variable_declarations) (`:=` assignments).
Once `check` statements are available,
there would be so little valid redeclaration remaining
that we might be able to forbid shadowing
and close [issue 377](https://golang.org/issue/377).

### Examples

A good error message includes relevant context,
such as the function or method name and its arguments.
Allowing handlers to chain allows adding new information as the function progresses.
For example, consider this function:

	func SortContents(w io.Writer, files []string) error {
	    handle err {
	        return fmt.Errorf("process: %v", err)             // handler A
	    }

	    lines := []strings{}
	    for _, file := range files {
	        handle err {
	            return fmt.Errorf("read %s: %v ", file, err)  // handler B
	        }
	        scan := bufio.NewScanner(check os.Open(file))     // check runs B on error
	        for scan.Scan() {
	            lines = append(lines, scan.Text())
	        }
	        check scan.Err()                                  // check runs B on error
	    }
	    sort.Strings(lines)
	    for _, line := range lines {
	        check io.WriteString(w, line)                     // check runs A on error
	    }
	}

The comments show which handlers are invoked for each of the
`check` expressions if these were to detect an error.
Here, only one handler is called in each case.
If handler B did not execute in a return statement,
it would transfer control to handler A.


If a `handle` body does not execute an explicit `return` statement,
the next earlier handler in lexical order runs:

	type Error struct {
		Func string
		User string
		Path string
		Err  error
	}

	func (e *Error) Error() string

	func ProcessFiles(user string, files chan string) error {
		e := Error{ Func: "ProcessFile", User: user}
		handle err { e.Err = err; return &e } // handler A
		u := check OpenUserInfo(user)         // check 1
		defer u.Close()
		for file := range files {
			handle err { e.Path = file }       // handler B
			check process(check os.Open(file)) // check 2
		}
		...
	}

Here, if check 2 catches an error,
it will execute handler B and,
since handler B does not execute a `return` statement,
then handler A.
All handlers will be run before the `defer`.
Another key difference between `defer` and `handle`:
the second handler will be executed exactly once
only when the second `check` fails.
A `defer` in that same position would cause a new function call
to be deferred until function return for every iteration.

### Draft spec

The syntax for a `handle` statement is:

	HandleStmt  = "handle" identifier Block .

It declares a _handler_, which is a block of code with access to a new identifier
bound to a variable of type `error`.
A `return` statement in a handler returns from the enclosing function,
with the same semantics and restrictions as for `return` statements
in the enclosing function itself.

A _default handler_ is defined at the top of functions
whose last return parameter is of type `error`.
It returns the current values of all leading results
(zero values for unnamed results), and the error value
as its final result.

A _handler chain call_ for a statement and error value executes
all handlers in scope of that statement in reverse order in a new stack frame,
binding their identifier to the error value.
At least one handler must be in scope and, if the enclosing function
has result parameters, at least one of those (possibly the default handler)
must end with a terminating statement.

The syntax of the `check` expression is:

	CheckExpr    = "check" UnaryExpr .

It checks whether a plain expression or a function call’s last result,
which must be of type error, is non-nil.
If the error result is nil, the check evaluates to all but the last value.
If the error result is nil, the check calls its handler chain for that value
in a new stack frame and returns the result from the enclosing function.

The same rules that apply for the order of evaluation of calls in
expressions apply to the order of evaluation of multiple checks
appearing in a single expression.
The `check` expression cannot be used inside handlers.

## Summary

*   A _handler chain_ is a function, defined within the context of an _enclosing function_, which:
    -   takes a single argument of type `error`,
    -   has the same return parameters as the enclosing function, and
    -   executes one or more blocks, called _handlers_.
*   A `handle` statement declares a handler for a handler chain and declares
    an identifier that refers to the error argument of that handler chain.
    -   A `return` statement in a handler causes the handler chain to stop executing
        and the enclosing function to return using the specified return values.
    -   If the enclosing function has named result parameters,
        a `return` statement with an empty expression list causes the handler chain
        to return with the current values of those arguments.
*   The `check` expression tests whether a plain expression or a
    function’s last result, which must be of type `error`, is non-nil.
    -   For multi-valued expressions, `check` yields all but the last value as its result.
    -   If `check` is applied to a single error value,
        `check` consumes that value and doesn’t produce any result.
        Consequently it cannot be used in an expression.
    -   The _handler chain of a check_ is defined to execute all the handlers
        in scope within the enclosing function in reverse order until one of them returns.
    -   For non-nil values, `check` calls the handler chain with this value,
        sets the return values, if any, with the results, and returns from the enclosing function.
    -   The same rules that apply for the order of evaluation of calls in expressions
        apply to the order of evaluation of multiple checks appearing in a single expression.
*   A `check` expression cannot be used inside handlers.
*   A _default handler_ is defined implicitly at the top of a function with a final result parameter
    of type `error`.
    -   For functions with unnamed results, the default handler returns zero values
        for all leading results and the error value for the final result.
    -   For functions with named results, the default handler returns the current
        values of all leading results and the error value for the final result.
    -   Because the default handler is declared at the top of a function,
        it is always last in the handler chain.

As a corollary of these rules:

*   Because the handler chain is called like a function, the location
    where the `check` caught an error is preserved as the handler’s caller’s frame.
*   If the enclosing function has result parameters,
    it is a compile-time error if at the point of any `check` expression
    none of the handlers in scope is a
    [terminating statement](https://golang.org/ref/spec#Terminating_statements).
    Note that the default handler ends in a terminating statement.
*   After a `check` detects an error, one cannot resume control of an enclosing function.
*   If a handler executes, it is always before any `defer` defined within the same enclosing function.

## Discussion

One drawback of the presented design is that it introduces a context-dependent control-flow jump,
like `break` and `continue`.
The semantics of `handle` are similar to but the same as `defer`, adding
another thing for developers to learn.
We believe that the reduction in verbosity, coupled with the increased ease to wrap error messages
as well as doing so idiomatically is worth this cost.

Another drawback is that this design might appear to add exceptions to Go.
The two biggest problems with exceptions are
that checks are not explicitly marked and that
the invoked handler is difficult to determine
and may depend on the call stack.
`Check`/`handle` has neither problem:
checks are marked and only execute lexically scoped
handlers in the enclosing function.

## Other considerations

This section discusses aspects of the design that we have discussed in the past.

### Keyword: try versus check

Swift and Rust define a `try` keyword which is similar to the `check` discussed
in this design.
Unlike `try` in Swift and Rust, check allows checking of any expression
that is assignable to error, not just calls,
making the use of `try` somewhat contrived.
We could consider `try` for the sake of consistency with other languages,
but Rust is moving away from try to the new `?` operator,
and Swift has not just `try` but also `try!`, `try?`, `catch`, and `throw`.

### Keyword: handle versus catch

The keyword `handle` was chosen instead of `catch` to avoid confusion with the
exception semantics conventionally associated with `catch`.
Most notably, `catch` permits the surrounding function to continue,
while a handler cannot: the function will always exit after the handler chain completes.
All the handler chain can do is clean up and set the function results.

### Checking error returns from deferred calls

The presented design does not provide a mechanism for checking errors
returned by deferred calls.
We were unable to find a way to unify them cleanly.

This code does not compile:

	func Greet(w io.WriteCloser) error {
		defer func() {
			check w.Close()
		}()
		fmt.Fprintf(w, "hello, world\n")
		return nil
	}

What the code likely intends is for the `check` to cause `Greet` to return the error,
but the `check` is not in `Greet`.
Instead, the `check` appears in a function literal returning no results.
The function therefore has no default handler,
so there is no handler chain for the `check` to call,
which causes a compilation failure.

Even with new syntax to write a deferred checked function call,
such as `defer check w.Close()`,
there is an ordering problem: deferred calls run
after the function executes its `return` statement;
in the case of an error, the handlers have already run.
It would be surprising to run any of them a second time
as a result of a deferred `check`.

### A check-else statement

A `check <expr> else <block>` statement could allow a block attached to
a check to be executed if an error is detected.
This would allow, for instance, setting an HTTP error code that a handler can pick up to wrap an error.

Joe Duffy proposed a similar construct in his
[Error Model](http://joeduffyblog.com/2016/02/07/the-error-model/) blog post.

However, this is generally not needed for error wrapping,
so it seems that this will not be needed much in practice.
Nesting `check` expressions with else blocks could make code unwieldy.

Analysis of a large code corpus shows that adding a `check`-`else`
construct usually does not help much.
Either way, the design does not preclude adding such a construct later if all else fails.

Note that a `check`-`else` can already be spelled out explicitly:

	x, err := <expr>
	if err != nil {
		<any custom handling, possibly including "check err">
	}

We can also write helpers like:

	func e(err, code int, msg string) *appError {
		if err == nil {
			return nil
		}
		return &appError{err, msg, code}
	}

	check e(doX(), 404, "record not found")

instead of:

	if err := doX(); err != nil {
		return &appError{err, "record not found", 404}
	}

Many wrapper functions, including `github.com/pkg/errors`'s `Wrap`,
start with a nil check.
We could rely on the compiler to optimize this particular case.

## Considered Ideas

### Using a ? operator instead of check

Rust is moving to a syntax of the form `<expr>?` instead of `try! <expr>`.
The rationale is that the `?` allows for better chaining, as in `f()?.g()?.h()`.
In Go, control flow transfers are as a general rule accompanied by keywords
(the exception being the boolean operators `||` and `&&`).
We believe that deviating from this would be too inconsistent.

Also, although the `?` approach may read better for chaining,
it reads worse for passing the result of a `check` to a function.
Compare, for instance

	check io.Copy(w, check newReader(foo))

to

	io.Copy(w, newReader(foo)?)?

Finally, handlers and `check` expressions go hand-in-hand.
Handlers are more naturally defined with a keyword.
It would be somewhat inconsistent
to have the accompanying `check` construct not also use a keyword.

## Comparisons

### Midori

Joe Duffy offers many valuable insights in the use of exceptions versus error codes
in his [Error Model](http://joeduffyblog.com/2016/02/07/the-error-model/) blog post.

### C++ proposal

Herb Sutter’s [proposal for C++](http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0709r0.pdf)
seems to come close to the what is presented here.
Although syntax varies in several places, the basic approach of propagating errors
as values with try and allowing handlers to deal with errors is similar.
The catch handlers, however, discard the error by default
unless they are rethrown in the catch block.
There is no way to continue after an error in our design.
The article offers interesting insights about the advantages of this approach.

### Rust

Rust originally defined `try!` as shorthand for checking an error
and returning it from the enclosing function if found.
For more complex handling, instead of handlers, Rust uses pattern matching on unwrapped return types.

### Swift

Swift defines a `try` keyword with somewhat similar semantics to the
`check` keyword introduced here.
A `try` in Swift may be accompanied by a `catch` block.
However, unlike with `check`-`handle`,
the `catch` block will prevent the function from returning
unless the block explicitly rethrows the error.
In the presented design, there is no way to stop exiting the function.

Swift also has a `try!`, which panics if an error is detected,
and a `try?`-`else`, which allows two blocks to be associated
that respectively will be run if the `try?` checks succeeds or fails.
