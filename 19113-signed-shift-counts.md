# Proposal: Permit Signed Integers as Shift Counts for Go 2

Robert Griesemer

Last updated: January 17, 2019

Discussion at [golang.org/issue/19113](https://golang.org/issue/19113).

## Summary

We propose to change the language spec such that the shift count
(the rhs operand in a `<<` or `>>` operation)
may be a _signed_ or unsigned (non-constant) integer,
or any non-negative constant value that can be represented as an integer.

## Background

See **Rationale** section below.

## Proposal

We change the language spec regarding shift operations as follows:
In the section on [Operators](https://golang.org/ref/spec#Operators), the text:

> The right operand in a shift expression must have unsigned integer type
> or be an untyped constant that can be converted to unsigned integer type.

to

> The right operand in a shift expression must have integer type
> or be an untyped constant that can be converted to an integer type.
> If the right operand is constant, it must not be negative.

Furthermore, in the section on [Integer operators](https://golang.org/ref/spec#Arithmetic_operators), we change the text:

> The shift operators shift the left operand by the shift count specified by the right operand.

to

> The shift operators shift the left operand by the shift count specified by the right operand.
> A run-time panic occurs if a non-constant shift count is negative.

## Rationale

Since Go's inception, shift counts had to be of unsigned integer type
(or a non-negative constant representable as an unsigned integer).
The idea behind this rule was that
(a) the spec didn't have to explain what happened for negative values,
and (b) the implementation didn't have to deal with negative values
possibly occurring at run-time.

In retrospect, this may have been a mistake; 
for example see
[this comment by Russ Cox](https://github.com/golang/go/issues/18616#issuecomment-278852766)
during the development of
[`math/bits`](https://golang.org/pkg/math/bits).
It turns out that we could actually change the spec
in a backward-compatible way in this regard,
and this proposal is suggesting that we do exactly that.

There are other language features where the result (`len(x)`),
argument (`n` in `make([]T, n)`) or constant (`n` in `[n]T`)
are known to be never negative or must not be negative,
yet we return an `int` (for `len`, `cap`) or permit any integer type.
Requiring an unsigned integer type for shift counts is frequently
a non-issue because the shift count is constant (see below);
but in some cases explicit `uint` conversions are needed,
or the code around the shift is carefully crafted to use unsigned integers.
In either case, readability is slightly compromised,
and more decision making is required when crafting the code:
Should we use a conversion or type other variables as unsigned integers?
Finally, and perhaps most importantly, there may be cases
where we simply convert an integer to an unsigned integer
and in the process inadvertently make an (invalid) negative value
positive in the process, possibly hiding a bug that way
(resulting in a shift by a very large number,
leading to 0 or -1 depending on the shifted value).

If we permit any integer type, the existing code will continue to work.
Places where we currently use a `uint` conversion won't need it anymore,
and code that is crafted for an unsigned shift count
may not require unsigned integers elsewhere.
(There’s a remote chance that some code relies on the
fact that a negative value becomes a large positive value
with a uint conversion; such code would continue to need the uint conversion.
We cannot remove the uint conversions without testing.)

An investigation of shifts in the current standard library and tests
as of 2/15/2017 (excluding package-external tests) found:

  - 8081 shifts total; 5457 (68%) right shifts vs 2624 (32%) left shifts
  - 6151 (76%) of those are shifts by a (typed or untyped) constant
  - 1666 (21%) shifts are in tests (_test.go files)
  - 253 (3.1%) shifts use an explicit uint conversion for the shift count

If we only look at shifts outside of test files we have:

  - 6415 shifts total; 4548 (71%) right shifts vs 1867 (29%) left shifts
  - 5759 (90%) of those are shifts by a (typed or untyped) constant
  - 243 (3.8%) shifts use an explicit uint conversion for the shift count

The overwhelming majority (90%) of shifts
outside of testing code is by untyped constant values,
and none of those turns out to require a conversion.
This proposal won't affect that code.

From the remaining 10% of all shifts,
38% (3.8% of the total number of shifts) require a `uint` conversion.
That's a significant number.
In the remaining 62% of non-constant shifts,
the shift count expression must be using a variable
that's of unsigned integer type, and often a conversion is required there.
A typical example is [archive/tar/strconv.go:88](https://golang.org/src/archive/tar/strconv.go#L88):

```Go
func fitsInBase256(n int, x int64) bool {
	var binBits = uint(n-1) * 8    // <<<< uint cast
	return n >= 9 || (x >= -1<<binBits && x < 1<<binBits)
}
```

In this case, `n` is an incoming argument,
and we can't be sure that `n > 1` without further analysis of the callers,
and thus there's a possibility that `n - 1` is negative.
The `uint` conversions hides that error silently.

Another one is [cmd/compile/internal/gc/esc.go:1460](https://golang.org/src/cmd/compile/internal/gc/esc.go#L1460):

```Go
	shift := uint(bitsPerOutputInTag*(vargen-1) + EscReturnBits)    // <<<< uint cast
	old := (e >> shift) & bitsMaskForTag
```

Or [src/fmt/scan.go:604](https://golang.org/src/fmt/scan.go#L604):

```Go
	n := uint(bitSize)    // uint cast
	x := (r << (64 - n)) >> (64 - n)
```

Many (most?) of the non-constant shifts
that don't use an explicit `uint` conversion in the shift expression itself
appear to have a `uint` conversion before that expression.
Most (all?) of these conversions wouldn't be necessary anymore.

The drawback of permitting signed integers
where negative values are not permitted is that we need to check
for negative values at run-time and panic as needed,
as we do elsewhere (e.g., for `make`).
This requires a bit more code; an estimated minimum of
two extra instructions per non-constant shift: a test and a branch).
However, none of the existing code will incur that cost
because all shift counts are unsigned integers at this point,
thus the compiler can omit the check.
For new code using non-constant integer shift counts,
often the compiler may be able to prove that
the operand is non-negative and then also avoid the extra instructions.
The compiler can already often prove that a value is non-negative
(done anyway for automatic bounds check elimination),
and in that case it can avoid the new branch entirely.
Of course, as a last resort,
an explicit `uint` conversion or mask in the source code
will allow programmers to force the removal of the check,
just as an explicit mask of the shift count today
avoids the oversize shift check.

On the plus side, almost all code that used a `uint` conversion
before won't need it anymore, and it will be safer for that
since possibly negative values will not be silently converted into positive ones.

## Compatibility

This is a backward-compatible language change:
Any valid program will continue to be valid,
and will continue to run exactly the same,
without any performance impact.
New programs may be using non-constant integer shift counts
as right operands in shift operations.
Except for fairly small changes to the spec,
the compiler, and go/types,
(and possibly go/vet and golint if they look at shift operations),
no other code needs to be changed.

There's a (remote) chance that some code makes intentional
use of negative shift count values converted to unsigned:

```Go
var shift int = <some expression> // use negative value to indicate that we want a 0 result
result := x << uint(shift)
```

Here, `uint(shift)` will produce a very large positive
value if `shift` is negative, resulting in `x << uint(shift)` becoming 0.
Because such code required an explicit conversion
and will continue to have an explicit conversion, it will continue to work. 
Programmers removing uint conversions from their code will
need to keep this in mind. Most of the time, however, a panic
resulting from removing the conversion will indicate a bug.

## Implementation

The implementation requires:

- Adjusting the compiler’s type-checker to allow signed integer shift counts
- Adjusting the compiler’s back-end to generate the extra test
- Possibly some (minimal) runtime work to support the new runtime panic
- Adjusting go/types to allow signed integer shift counts
- Adjusting the Go spec as outlined earlier in this proposal
- Adjusting gccgo accordingly (type-checker and back-end)
- Testing the new changes by adding new tests

No library changes will be needed as this is a 100% backward-compatible change.

Robert Griesemer and Keith Randall plan to split the work
and aim to have all the changes ready at the start of the Go 1.13 cycle,
around February 1. Ian Lance Taylor will look into the gccgo changes.

As noted in our
[“Go 2, here we come!” blog post](https://blog.golang.org/go2-here-we-come),
the development cycle will serve as a way to collect experience about
these new features and feedback from (very) early adopters.

At the release freeze, May 1, we will revisit the proposed features
and decide whether to include them in Go 1.13.
