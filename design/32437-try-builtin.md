# Proposal: A built-in Go error check function, `try`

Author: Robert Griesemer

Last update: 2019-06-12

Discussion at [golang.org/issue/32437](https://golang.org/issue/32437).

## Summary

We propose a new built-in function called `try`, designed specifically to eliminate the boilerplate `if` statements typically associated with error handling in Go. No other language changes are suggested. We advocate using the existing `defer` statement and standard library functions to help with augmenting or wrapping of errors. This minimal approach addresses most common scenarios while adding very little complexity to the language. The `try` built-in is easy to explain, straightforward to implement, orthogonal to other language constructs, and fully backward-compatible. It also leaves open a path to extending the mechanism, should we wish to do so in the future.

The rest of this document is organized as follows: After a brief introduction, we provide the definition of the built-in and explain its use in practice. The discussion section reviews alternative proposals and the current design. We’ll end with conclusions and an implementation schedule followed by examples and FAQs.

## Introduction

At last year’s Gophercon in Denver, members of the Go Team (Russ Cox, Marcel van Lohuizen) presented some new ideas on how to reduce the tedium of manual error handling in Go ([draft design](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling.md)). We have received a lot of feedback since then.

As Russ Cox explained in his [problem overview](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling-overview.md), our goal is to make error handling more lightweight by reducing the amount of source code dedicated solely to error checking. We also want to make it more convenient to write error handling code, to raise the likelihood programmers will take the time to do it. At the same time we do want to keep error handling code explicitly visible in the program text.

The ideas discussed in the draft design centered around a new unary operator `check` which simplified explicit checking of an error value returned by some expression (typically a function call), a `handle` declaration for error handlers, and a set of rules connecting the two new language constructs.

Much of the immediate feedback we received focused on the details and complexity of `handle` while the idea of a `check`-like operator seemed more palatable. In fact, several community members picked up on the idea of a `check`-like operator and expanded on it. Here are some of the posts most relevant to this proposal:

- The first written-down suggestion (known to us) to use a `check` _built-in_ rather than a `check` _operator_ was by [PeterRK](https://gist.github.com/PeterRK) in his post [Key Parts of Error Handling](https://gist.github.com/PeterRK/4f59579c1162cdbc28086f6b5f7b4fa2).

- More recently, [Markus](https://github.com/markusheukelom) proposed two new keywords `guard` and `must` as well as the use of `defer` for error wrapping in issue [#31442](https://golang.org/issue/31442).

- Related, [pjebs](https://github.com/pjebs) proposed a `must` built-in in issue [#32219](https://golang.org/issue/32219).

The current proposal, while different in detail, was influenced by these three issues and the general feedback received on last year’s draft design.

For completeness, we note that more error-handling related proposals can be found [here](https://github.com/golang/go/wiki/Go2ErrorHandlingFeedback). Also noteworthy, [Liam Breck](https://gist.github.com/networkimprov) came up with an extensive menu of [requirements](https://gist.github.com/networkimprov/961c9caa2631ad3b95413f7d44a2c98a) to consider.

Finally, we learned after publishing this proposal that [Ryan Hileman](https://github.com/lunixbochs) implemented `try` five years ago via the [`og` rewriter tool](https://github.com/lunixbochs/og) and used it with success in real projects. See also https://news.ycombinator.com/item?id=20101417.

## The `try` built-in

### Proposal

We propose to add a new function-like built-in called `try` with signature (pseudo-code)

```Go
func try(expr) (T1, T2, … Tn)
```

where `expr` stands for an incoming argument expression (usually a function call) producing n+1 result values of types `T1`, `T2`, ... `Tn`, and `error` for the last value. If `expr` evaluates to a single value (n is 0), that value must be of type `error` and `try` doesn't return a result. Calling `try` with an expression that does not produce a last value of type `error` leads to a compile-time error.

The `try` built-in may _only_ be used inside a function with at least one result parameter where the last result is of type `error`. Calling `try` in a different context leads to a compile-time error.

Invoking `try` with a function call `f()` as in (pseudo-code)

```Go
x1, x2, … xn = try(f())
```
turns into the following (in-lined) code:

```Go
t1, … tn, te := f()  // t1, … tn, te are local (invisible) temporaries
if te != nil {
        err = te     // assign te to the error result parameter
        return       // return from enclosing function
}
x1, … xn = t1, … tn  // assignment only if there was no error
```

In other words, if the last value produced by "expr", of type `error`, is nil, `try` simply returns the first n values, with the final nil error stripped. If the last value produced by "expr" is not nil, the enclosing function’s error result variable (called `err` in the pseudo-code above, but it may have any other name or be unnamed) is set to that non-nil error value and the enclosing function returns. If the enclosing function declares other named result parameters, those result parameters keep whatever value they have. If the function declares other unnamed result parameters, they assume their corresponding zero values (which is the same as keeping the value they already have).

If `try` happens to be used in a multiple assignment as in this illustration, and a non-nil error is detected, the assignment (to the user-defined variables) is _not_ executed and none of the variables on the left-hand side of the assignment are changed. That is, `try` behaves like a function call: its results are only available if `try` returns to the actual call site (as opposed to returning from the enclosing function). As a consequence, if the variables on the left-hand side are named result parameters, using `try` will lead to a different result than typical code found today. For instance, if `a`, `b`, and `err` are all named result parameters of the enclosing function, this code

```Go
a, b, err = f()
if err != nil {
        return
}
```

will always set `a`, `b`, and `err`, independently of whether `f()` returned an error or not. In contrast

```Go
a, b = try(f())
```

will leave `a` and `b` unchanged in case of an error. While this is a subtle difference, we believe cases like these are rare. If current behavior is expected, keep the `if` statement.

### Usage

The definition of `try` directly suggests its use: many `if` statements checking for error results today can be eliminated with `try`. For instance

```Go
f, err := os.Open(filename)
if err != nil {
        return …, err  // zero values for other results, if any
}
```

can be simplified to

```Go
f := try(os.Open(filename))
```

If the enclosing function does not return an error result, `try` cannot be used (but see the Discussion section). In that case, an error must be handled locally anyway (since no error is returned), and then an `if` statement remains the appropriate mechanism to test for the error.

More generally, it is not a goal to replace all possible testing of errors with the `try` function. Code that needs different semantics can and should continue to use if statements and explicit error variables.

### Testing and `try`

In one of our earlier attempts at specifying `try` (see the section on Design iterations, below), `try` was designed to panic upon encountering an error if used inside a function without an `error` result. This enabled the use of `try` in unit tests as supported by the standard library’s `testing` package.

One option is for the `testing` package to allow test/benchmark functions of the form

```Go
func TestXxx(*testing.T) error
func BenchmarkXxx(*testing.B) error
```

to enable the use of `try` in tests. A test or benchmark function returning a non-nil error would implicitly call `t.Fatal(err)` or `b.Fatal(err)`. This would be a modest library change and avoid the need for different semantics (returning or panicking) for `try` depending on context.

One drawback of this approach is that `t.Fatal` and `b.Fatal` would not report the line number of the actually failing call. Another drawback is that we must adjust subtests in some way as well. How to address these best is an open question; we do not propose a specific change to the `testing` package with this document.

See also issue [#21111](https://golang.org/issue/21111) which proposes that example functions may return an error result.

### Handling errors

A significant aspect of the original [draft design](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling.md) concerned language support for wrapping or otherwise augmenting an error. The draft design introduced a new keyword `handle` and a new _error handler_ declaration. This new language construct was problematic because of its non-trivial semantics, especially when considering its impact on control flow. In particular, its functionality intersected with the functionality of `defer` in unfortunate ways, which made it a non-orthogonal new language feature.

This proposal reduces the original draft design to its essence. If error augmentation or wrapping is desired there are two approaches: Stick with the tried-and-true `if` statement, or, alternatively, “declare” an error handler with a `defer` statement:

```Go
defer func() {
        if err != nil {  // no error may have occurred - check for it
                err = …  // wrap/augment error
        }
}()
```

Here,  `err` is the name of the error result of the enclosing function.

In practice, we envision suitable helper functions such as

```Go
func HandleErrorf(err *error, format string, args ...interface{}) {
        if *err != nil {
                *err = fmt.Errorf(format + ": %v", append(args, *err)...)
        }
}
```

or similar; the `fmt` package would be a natural place for such helpers (it already provides `fmt.Errorf`). Using a helper function, the declaration of an error handler will be reduced to a one-liner in many cases. For instance, to augment an error returned by a "copy" function, one might write

```Go
defer fmt.HandleErrorf(&err, "copy %s %s", src, dst)
```

if `fmt.HandleErrorf` implicitly adds the error information. This reads reasonably well and has the advantage that it can be implemented without the need for new language features.

The main drawback of this approach is that the error result parameter needs to be named, possibly leading to less pretty APIs (but see the FAQs on this subject). We believe that we will get used to it once this style has established itself.

### Efficiency of `defer`

An important consideration with using `defer` as error handlers is efficiency. The `defer` statement has a reputation of being [slow](https://golang.org/issue/14939). We do not want to have to choose between efficient code and good error handling. Independently, the Go runtime and compiler team has been discussing alternative implementation options and we believe that we can make typical `defer` uses for error handling about as efficient as existing “manual” code. We hope to make this faster `defer` implementation available in Go 1.14 (see also [CL 171758](https://golang.org/cl/171758/) which is a first step in this direction).

### Special cases: `go try(f)` and `defer try(f)`

The `try` built-in looks like a function and thus is expected to be usable wherever a function call is permitted. But if a `try` call is used in a `go` statement, things are less clear:

```Go
go try(f)
```

Here, `f` is evaluated when the `go` statement is executed in the current goroutine, and then its results are passed as arguments to `try` which is launched in a new goroutine. If `f` returns a non-nil error, `try` is expected to return from the enclosing function, but there isn’t any such (Go) function (nor a last result parameter of type `error`) since we are running in a separate goroutine. Therefore we suggest to disallow `try` as the called function in a `go` statement.

The situation with

```Go
defer try(f)
```

appears similar but here the semantics of `defer` mean that the execution of `try` would be suspended until the enclosing function is about to return. As before, the argument `f` is evaluated when the `defer` statement is executed, and `f`’s results are passed to the suspended `try`.

Only when the enclosing function is about to return does `try` test for an error returned by `f`. Without changes to the behavior of `try`, such an error might then overwrite another error currently being returned by the enclosing function. This is at best confusing, and at worst error-prone. Therefore we suggest to disallow `try` as the called function in a `defer` statement as well. We can always revisit this decision if sensible applications are found.

Finally, like other built-ins, the built-in `try` must be called; it cannot be used as a function value, as in `f := try` (just like `f := print` and `f := new` are also disallowed).

## Discussion

### Design iterations

What follows is a brief discussion of earlier designs which led to the current minimal proposal. We hope that this will shed some light on the specific design choices made.

Our first iteration of this proposal was inspired by two ideas from [Key Parts of Error Handling](https://gist.github.com/PeterRK/4f59579c1162cdbc28086f6b5f7b4fa2), which is to use a built-in rather than an operator, and an ordinary Go function to handle an error rather than a new error handler language construct. In contrast to that post, our error handler had the fixed function signature `func(error) error` to simplify matters. The error handler would be called by `try` in the presence of an error, just before `try` returned from the enclosing function. Here is an example:

```Go
handler := func(err error) error {
        return fmt.Errorf("foo failed: %v", err)  // wrap error
}

f := try(os.Open(filename), handler)              // handler will be called in error case
```

While this approach permitted the specification of efficient user-defined error handlers, it also opened a lot of questions which didn’t have obviously correct answers: What should happen if the handler is provided but is nil? Should `try` panic or treat it as an absent error handler? What if the handler is invoked with a non-nil error and then returns a nil result? Does this mean the error is “cancelled”? Or should the enclosing function return with a nil error? It was also not clear if permitting an optional error handler would lead programmers to ignore proper error handling altogether. It would also be easy to do proper error handling everywhere but miss a single occurrence of a `try`. And so forth.

The next iteration removed the ability to provide a user-defined error handler in favor of using `defer` for error wrapping. This seemed a better approach because it made error handlers much more visible in the code. This step eliminated all the questions around optional functions as error handlers but required that error results were named if access to them was needed (we decided that this was ok). Furthermore, in an attempt to make `try` useful not just inside functions with an error result, the semantics of `try` depended on the context: If `try` were used at the package-level, or if it were called inside a function without an error result, `try` would panic upon encountering an error. (As an aside, because of that property the built-in was called `must` rather than `try` in that proposal.) Having `try` (or `must`) behave in this context-sensitive way seemed natural and also quite useful: It would allow the elimination of many user-defined `must` helper functions currently used in package-level variable initialization expressions. It would also open the possibility of using `try` in unit tests via the `testing` package.

Yet, the context-sensitivity of `try` was considered fraught: For instance, the behavior of a function containing `try` calls could change silently (from possibly panicking to not panicking, and vice versa) if an error result was added or removed from the signature. This seemed too dangerous a property. The obvious solution would have been to split the functionality of `try` into two separate functions, `must` and `try` (very similar to what is suggested by issue [#31442](https://github.com/golang/go/issues/31442)). But that would have required two new built-in functions, with only `try` directly connected to the immediate need for better error handling support.

Thus, in the current iteration, rather than introducing a second built-in, we decided to remove the dual semantics of `try` and consequently only permit its use inside functions that have an error result.

### Properties of the proposed design

This proposal is rather minimal, and may even feel like a step back from last year’s draft design. We believe the design choices we made to arrive at `try` are well justified:

- First and foremost, `try` has exactly the semantics of the originally proposed `check` operator in the absence of a `handle` declaration. This validates the original draft design in an important aspect.

- Choosing a built-in function rather than an operator has several advantages. There is no need for a new keyword such as `check` which would have made the design not backward compatible with existing parsers. There is also no need for extending the expression syntax with the new operator. Adding a new built-in is a comparatively trivial and completely orthogonal language change.

- Using a built-in function rather than an operator requires the use of parentheses. We must write `try(f())` rather than `try f()`. This is the (small) price we pay for being backward compatible with existing parsers. But it also makes the design forward-compatible: If we determine down the road that having some form of explicitly provided error handler function, or any other additional parameter for that matter, is a good idea, it is trivially possible to pass that additional argument to a `try` call.

- As it turns out, having to write parentheses has its advantages. In more complex expressions with multiple `try` calls, writing parentheses improves readability by eliminating guesswork about the precedence of operators, as the following examples illustrate:

```Go
info := try(try(os.Open(file)).Stat())    // proposed try built-in
info := try (try os.Open(file)).Stat()    // try binding looser than dot
info := try (try (os.Open(file)).Stat())  // try binding tighter than dot
```

The second line corresponds to a `try` operator that binds looser than a method call: Parentheses are required around the entire inner `try` expression since the result of that `try` is the receiver of the `.Stat` call (rather than the result of `os.Open`).

The third line corresponds to a `try` operator that binds tighter than a method call: Parentheses are required around the `os.Open(file)` call since the results of that are the arguments for the inner `try` (we don’t want the inner `try` to apply only to `os`, nor the outer try to apply only to the inner `try`’s result).

The first line is by far the least surprising and most readable as it is just using the familiar function call notation.

- The absence of a dedicated language construct to support error wrapping may disappoint some people. However, note that this proposal does not preclude such a construct in the future. It is clearly better to wait until a really good solution presents itself than prematurely add a mechanism to the language that is not fully satisfactory.

## Conclusions

The main difference between this design and the original [draft design](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling.md) is the elimination of the error handler as a new language construct. The resulting simplification is huge, yet there is no significant loss of generality. The effect of an explicit error handler declaration can be achieved with a suitable `defer` statement which is also prominently visible at the opening of a function body.

In Go, built-ins are the _language escape mechanism of choice_ for operations that are irregular in some way but which don’t justify special syntax. For instance, the very first versions of Go didn’t define the `append` built-in. Only after manually implementing `append` over and over again for various slice types did it become clear that [dedicated language support](https://golang.org/cl/2627043) was warranted. The repeated implementation helped clarify how exactly the built-in should look like. We believe we are in an analogous situation now with `try`.

It may also seem odd at first for a built-in to affect control-flow, but we should keep in mind that Go already has a couple of built-ins doing exactly that: `panic` and `recover`. The built-in type `error` and function `try` complement that pair.

In summary, `try` may seem unusual at first, but it is simply syntactic sugar tailor-made for one specific task, error handling with less boilerplate, and to handle that task well enough. As such it fits nicely into the philosophy of Go:

- There is no interference with the rest of the language.
- Because it is syntactic sugar, `try` is easily explained in more basic terms of the language.
- The design does not require new syntax.
- The design is fully backwards-compatible.

This proposal does not solve all error handling situations one might want to handle, but it addresses the most commonly used patterns well. For everything else there are `if` statements.

## Implementation

The implementation requires:

- Adjusting the Go spec.
- Teaching the compiler’s type-checker about the `try` built-in. The actual implementation is expected to be a relatively straight-forward syntax tree transformation in the compiler’s front-end. No back-end changes are expected.
- Teaching go/types about the `try` built-in. This is a minor change.
- Adjusting gccgo accordingly (again, just the front-end).
- Testing the built-in with new tests.

As this is a backward-compatible language change, no library changes are required. However, we anticipate that support functions for error handling may be added. Their detailed design and respective implementation work is discussed [elsewhere](https://golang.org/issue/29934).

Robert Griesemer will do the spec and go/types changes including additional tests, and (probably) also the cmd/compile compiler changes. We aim to have all the changes ready at the start of the [Go 1.14 cycle](https://golang.org/wiki/Go-Release-Cycle), around August 1, 2019.

Separately, Ian Lance Taylor will look into the gccgo changes, which is released according to a different schedule.

As noted in our [“Go 2, here we come!” blog post](https://blog.golang.org/go2-here-we-come), the development cycle will serve as a way to collect experience about these new features and feedback from (very) early adopters.

At the release freeze, November 1, we will revisit this proposed feature and decide whether to include it in Go 1.14.

## Examples

The `CopyFile` example from the [overview](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling-overview.md) becomes

```Go
func CopyFile(src, dst string) (err error) {
        defer func() {
                if err != nil {
                        err = fmt.Errorf("copy %s %s: %v", src, dst, err)
                }
        }()

        r := try(os.Open(src))
        defer r.Close()

        w := try(os.Create(dst))
        defer func() {
                w.Close()
                if err != nil {
                        os.Remove(dst) // only if a “try” fails
                }
        }()

        try(io.Copy(w, r))
        try(w.Close())
        return nil
}
```

Using a helper function as discussed in the section on handling errors, the first `defer` in `CopyFile` becomes a one-liner:

```Go
defer fmt.HandleErrorf(&err, "copy %s %s", src, dst)
```

It is still possible to have multiple handlers, and even chaining of handlers (via the stack of `defer`’s), but now the control flow is defined by existing `defer` semantics, rather than a new, unfamiliar mechanism that needs to be learned first.

The `printSum` example from the [draft design](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling.md) doesn’t require an error handler and becomes

```Go
func printSum(a, b string) error {
        x := try(strconv.Atoi(a))
        y := try(strconv.Atoi(b))
        fmt.Println("result:", x + y)
        return nil
}
```

or even simpler:

```Go
func printSum(a, b string) error {
        fmt.Println(
                "result:",
                try(strconv.Atoi(a)) + try(strconv.Atoi(b)),
        )
        return nil
}
```

The `main` function of [this useful but trivial program](https://github.com/rsc/tmp/blob/master/unhex/main.go) could be split into two functions:

```Go
func localMain() error {
        hex := try(ioutil.ReadAll(os.Stdin))
        data := try(parseHexdump(string(hex)))
        try(os.Stdout.Write(data))
        return nil
}

func main() {
        if err := localMain(); err != nil {
                log.Fatal(err)
        }
}
```

Since `try` requires at a minimum an `error` argument, it may be used to check for remaining errors:

```Go
n, err := src.Read(buf)
if err == io.EOF {
        break
}
try(err)
```

## FAQ

This section is expected to grow as necessary.

__Q: What were the main criticisms of the original [draft design](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling.md)?__

A: The draft design introduced two new keywords `check` and `handle` which made the proposal not backward-compatible. Furthermore, the semantics of `handle` was quite complicated and its functionality significantly overlapped with `defer`, making `handle` a non-orthogonal language feature.

__Q: Why is `try` a built-in?__

A: By making `try` a built-in, there is no need for a new keyword or operator in Go. Introducing a new keyword is not a backward-compatible language change because the keyword may conflict with identifiers in existing programs. Introducing a new operator requires new syntax, and the choice of a suitable operator, which we would like to avoid. Using ordinary function call syntax has also advantages as explained in the section on Properties of the proposed design. And `try` can not be an ordinary function, because the number and types of its results depend on its input.

__Q: Why is `try` called `try`?__

A: We have considered various alternatives, including `check`, `must`, and `do`. Even though `try` is a built-in and therefore does not conflict with existing identifiers, such identifiers may still shadow the built-in and thus make it inaccessible. `try` seems less common a user-defined identifier than `check` (probably because it is a keyword in some other languages) and thus it is less likely to be shadowed inadvertently. It is also shorter, and does convey its semantics fairly well. In the standard library we use the pattern of user-defined `must` functions to raise a panic if an error occurs in a variable initialization expression; `try` does not panic. Finally, both Rust and Swift use `try` to annotate explicitly-checked function calls as well (but see the next question). It makes sense to use the same word for the same idea.

__Q: Why can’t we use `?` like Rust?__

A: Go has been designed with a strong emphasis on readability; we want even people unfamiliar with the language to be able to make some sense of Go code (that doesn’t imply that each name needs to be self-explanatory; we still have a language spec, after all). So far we have avoided cryptic abbreviations or symbols in the language, including unusual operators such as `?`, which have ambiguous or non-obvious meanings. Generally, identifiers defined by the language are either fully spelled out (`package`, `interface`, `if`, `append`, `recover`, etc.), or shortened if the shortened version is unambiguous and well-understood (`struct`, `var`, `func`, `int`, `len`, `imag`, etc.). Rust introduced `?` to alleviate issues with `try` and chaining - this is much less of an issue in Go where statements tend to be simpler and chaining (as opposed to nesting) less common. Finally, using `?` would introduce a new post-fix operator into the language. This would require a new token and new syntax and with that adjustments to a multitude of packages (scanners, parsers, etc.) and tools. It would also make it much harder to make future changes. Using a built-in eliminates all these problems while keeping the design flexible.

__Q: Having to name the final (error) result parameter of a function just so that `defer` has access to it screws up `go doc` output. Isn’t there a better approach?__

A: We could adjust `go doc` to recognize the specific case where all results of a function except for the final error result have a blank (_) name, and omit the result names for that case. For instance, the signature `func f() (_ A, _ B, err error)` could be presented by `go doc` as `func f() (A, B, error)`. Ultimately this is a matter of style, and we believe we will adapt to expecting the new style, much as we adapted to not having semicolons. That said, if we are willing to add more new mechanisms to the language, there are other ways to address this. For instance, one could define a new, suitably named, built-in _variable_ that is an alias for the final error result parameter, perhaps only visible inside a deferred function literal. Alternatively, [Jonathan Geddes](https://github.com/jargv) [proposed](https://golang.org/issue/32437#issuecomment-499594811) that calling `try()` with no arguments could return an `*error` pointing to the error result variable.

__Q: Isn’t using `defer` for wrapping errors going to be slow?__

A: Currently a `defer` statement is relatively expensive compared to ordinary control flow. However, we believe that it is possible to make common use cases of `defer` for error handling comparable in performance with the current “manual” approach. See also [CL 171758](https://golang.org/cl/171758/) which is expected to improve the performance of `defer` by around 30%.

__Q: Won't this design discourage adding context information to errors?__

A: We think the verbosity of checking error results is a separate issue from adding context. The context a typical function should add to its errors (most commonly, information about its arguments) usually applies to multiple error checks. The plan to encourage the use of `defer` to add context to errors is mostly a separate concern from having shorter checks, which this proposal focuses on. The design of the exact `defer` helpers is part of [golang.org/issue/29934](https://golang.org/issue/29934) (Go 2 error values), not this proposal.

__Q: The last argument passed to `try` _must_ be of type `error`. Why is it not sufficient for the incoming argument to be _assignable_ to `error`?__

A: A [common novice mistake](https://golang.org/doc/faq#nil_error) is to assign a concrete nil pointer value to a variable of type `error` (which is an interface) only to find that that variable is not nil. Requiring the incoming argument to be of type `error` prevents this bug from occurring through the use of `try`. (We can revisit this decision in the future if necessary. Relaxing this rule would be a backward-compatible change.)

__Q: If Go had “generics”, couldn’t we implement `try` as a generic function?__

A: Implementing `try` requires the ability to return from the function enclosing the `try` call. Absent such a “super return” statement, `try` cannot be implemented in Go even if there were generic functions. `try` also requires a variadic parameter list with parameters of different types. We do not anticipate support for such variadic generic functions.

__Q: I can’t use `try` in my code, my error checks don’t fit the required pattern. What should I do?__

A: `try` is not designed to address _all_ error handling situations; it is designed to handle the most common case well, to keep the design simple and clear. If it doesn’t make sense (or it isn’t possible) to change your code such that `try` can be used, stick with what you have. `if` statements are code, too.

__Q: In my function, most of the error tests require different error handling. I can use `try` just fine but it gets complicated or even impossible to use `defer` for error handling. What can I do?__

A: You may be able to split your function into smaller functions of code that shares the same error handling. Also, see the previous question.

__Q: How is `try` different from exception handling (and where is the `catch`)?__

A: `try` is simply syntactic sugar (a "macro") for extracting the non-error values of an expression followed by a conditional `return` (if a non-nil error was found) from the enclosing function. `try` is always explicit; it must be literally present in the source code. Its effect on control flow is limited to the current function. There is also no mechanism to "catch" an error. After the function has returned, execution continues as usual at the call site. In summary, `try` is a shortcut for a conditional `return`.
Exception handling on the other hand, which in some languages involves `throw` and `try`-`catch` statements, is akin to handling Go panics. An exception, which may be explicitly `throw`n but also implicitly raised (for instance a division-by-0 exception), terminates the currently active function (by returning from it) and then continues to unwind the activation stack by terminating the callee and so forth. An exception may be "caught" if it occurs within a `try`-`catch` statement at which point the exception is not further propagated. An exception that is not caught may cause the entire program to terminate. In Go, the equivalent of an exception is a panic. Throwing an exception is equivalent to calling `panic`. And catching an exception is equivalent to `recover`ing from a panic.
