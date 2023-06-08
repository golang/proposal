# Proposal: Custom Fuzz Input Types

Author: Richard Hansen <rhansen@rhansen.org>

Last updated: 2023-06-08

Discussion at https://go.dev/issue/48815.

## Abstract

Extend [`testing.F.Fuzz`](https://pkg.go.dev/testing#F.Fuzz) to support custom
types, with their own custom mutation logic, as input parameters. This enables
developers to perform [structure-aware
fuzzing](https://github.com/google/fuzzing/blob/master/docs/structure-aware-fuzzing.md).

## Background

As of Go 1.20, `testing.F.Fuzz` only accepts fuzz functions that have basic
parameter types: `[]byte`, `string`, `int`, etc. Custom input types with custom
mutation logic would make it easier to fuzz functions that take complex data
structures as input.

It is technically possible to fuzz such functions using the basic types, but the
benefit is limited:

  * A basic input type can be used as a pseudo-random number generator seed to
    generate a valid structure at test time. Downsides:
      * The seed, not the generated structure, is saved in
        `testdata/fuzz/FuzzTestName/*`. This makes it difficult for developers
        to examine the structure to figure out why it is interesting. It also
        means that a minor change to the structure generation algorithm can
        invalidate the entire seed corpus.
      * A problematic or interesting structure discovered or created outside of
        fuzzing cannot be added to the seed corpus.
      * `F.Fuzz` cannot distinguish the structure generation code from the code
        under test, so the structure generation code is instrumented and
        included in `F.Fuzz`'s analysis. This causes unnecessary slowdowns and
        false positives (uninteresting inputs treated as interesting due to
        changed coverage).
      * `F.Fuzz` has limited ability to explore or avoid "similar" inputs in its
        pursuit of new execution paths. (Similar seeds produce pseudo-randomly
        independent structures.)
  * Multiple input values can be used to populate the fields of the complex
    structure. This has many of the same downsides as using a single seed
    input.
  * Raw input values can be cast as (an encoding of) the complex structure. For
    example, a `[]byte` input could be interpreted as a protobuf. Depending on
    the specifics, the yield of this approach (the number of bugs it finds) is
    likely to be low due to the low probability of generating a syntactically
    and semantically valid structure. (Sometimes it is important to attempt
    invalid structures to exercise error handling and discover security
    vulnerabilities, but this does not apply to function call traces that are
    replayed to test a stateful system.)

See [Structure-Aware Fuzzing with
libFuzzer](https://github.com/google/fuzzing/blob/master/docs/structure-aware-fuzzing.md)
for additional background.

## Proposal

Extend `testing.F.Fuzz` to accept fuzz functions with parameter types that
implement the following interface (not exported, just documented in
`testing.F.Fuzz`):

```go
// A customMutator is a fuzz input value that is self-mutating. This interface
// extends the encoding.BinaryMarshaler and encoding.BinaryUnmarshaler
// interfaces.
type customMutator interface {
	// MarshalBinary encodes the customMutator's value in a platform-independent
	// way (e.g., JSON or Protocol Buffers).
	MarshalBinary() ([]byte, error)
	// UnmarshalBinary restores the customMutator's value from encoded data
	// previously returned from a call to MarshalBinary.
	UnmarshalBinary([]byte) error
	// Mutate pseudo-randomly transforms the customMutator's value. The mutation
	// must be repeatable: every call to Mutate with the same starting value and
	// seed must result in the same transformed value.
	Mutate(ctx context.Context, seed int64) error
}
```

Also extend the seed corpus file format to support custom values. A line for a
custom value has the following form:

```
custom("type identifier here", []byte("marshal output here"))
```

The type identifier is a globally unique and stable identifier derived from the
value's fully qualified type name, such as `"*example.com/mod/pkg.myType"`.

### Example Usage

```go
package pkg_test

import (
	"encoding/json"
	"testing"

	"github.com/go-loremipsum/loremipsum"
)

type fuzzInput struct{ Word string }

func (v *fuzzInput) MarshalBinary() ([]byte, error) { return json.Marshal(v) }
func (v *fuzzInput) UnmarshalBinary(d []byte) error { return json.Unmarshal(d, v) }
func (v *fuzzInput) Mutate(ctx context.Context, seed int64) error {
	v.Word = loremipsum.NewWithSeed(seed).Word()
	return nil
}

func FuzzInput(f *testing.F) {
	f.Fuzz(func(t *testing.T, v *fuzzInput) {
		if v.Word == "lorem" {
			t.Fatal("boom!")
		}
	})
}
```

The fuzzer eventually encounters an input value that causes the test function to
fail, and produces a seed corpus file in `testdata/fuzz` like the following:

```
go test fuzz v1
custom("*example.com/mod/pkg_test.fuzzInput", []byte("{\"Word\":\"lorem\"}"))
```

## Rationale

### Private interface

The `customMutator` interface is not exported for a few reasons:

  * Exporting is not strictly required because it does not appear anywhere
    outside of internal logic.
  * It can be easily exported in the future if needed. The opposite is not true:
    un-exporting requires a major version change.
  * [YAGNI](https://en.wikipedia.org/wiki/You_aren%27t_gonna_need_it): Users are
    unlikely to want to declare anything with that type. One possible exception
    is a compile-time type check such as the following:

    ```go
    var _ testing.CustomMutator = (*myType)(nil)
    ```

    Such a check is unlikely to have much value: the code is likely being
    compiled because tests are about to run, and `testing.F.Fuzz`'s runtime
    check will immediately catch the bug.
  * Exporting now would add friction to extending `testing.F.Fuzz` again in the
    future. Should the new interface be exported even if doing so doesn't add
    much value beyond consistency?

### `MarshalBinary`, `UnmarshalBinary` methods

`Marshal` and `Unmarshal` would be shorter to type than `MarshalBinary` and
`UnmarshalBinary`, but the longer names make it easier to extend existing types
that already implement the `encoding.BinaryMarshaler` and
`encoding.BinaryUnmarshaler` interfaces.

`MarshalText` and `UnmarshalText` were considered but rejected because the most
natural representation of a custom type might be binary, not text.

`UnmarshalBinary` is used both to load seed corpus files from disk and to
transmit input values between the coordinator and its workers. Unmarshaling
malformed data from disk is allowed to fail, but unmarshaling after
transmission to another process is expected to always succeed.

`MarshalBinary` is used both to save seed corpus files to disk and to transmit
input values between the coordinator and its workers. Marshaling is expected to
always succeed. Despite this, it returns an error for several reasons:

  * to implement the `encoding.BinaryMarshaler` interface
  * for symmetry with `UnmarshalBinary`
  * to match the APIs provided by packages such as `encoding/json` and
    `encoding/gob`
  * to discourage the use of `panic`

Panicking is especially problematic because:

  * The coordinator process currently interprets a panic as a bug in the code
    under test, even if it happens outside of the test function.
  * Worker process stdout and stderr is currently suppressed, presumably to
    [reduce the amount of output
    noise](https://github.com/golang/go/blob/aa4d5e739f32397969fd5c33cbc95d316686039f/src/testing/fuzz.go#L380-L383),
    so developers might not notice that a failure is caused by a panic in a
    custom input type's method.

### `Mutate` method

The `seed` parameter is an `int64`, not an unsigned integer type as is common
for holding random bits, because that is what
[`math/rand.NewSource`](https://pkg.go.dev/math/rand#NewSource) takes.

The `Mutate` method must be repeatable to avoid violating [an assumption in the
coordinator–worker
protocol](https://github.com/golang/go/blob/0a9875c5c809fa70ae6662b8a38f5f86f648badd/src/internal/fuzz/worker.go#L702-L705).
This may be relaxed in the future by revising the protocol.

Some alternatives for the `Mutate` method were considered:

  * `Mutate()`: Simplest, but the lack of a seed parameter makes it difficult
    to satisfy the repeatability requirement.
  * `Mutate(seed int64)`: Simple. Naturally hints to developers that the method
    is expected to be fast, repeatable, and error-free, which increases the
    effectiveness of fuzzing. Adding a context parameter or error return value
    (or both) might be YAGNI, but their absence makes complex mutation
    operations more difficult to implement. The lack of an error return value
    encourages the use of `panic`, which is problematic for the reasons
    discussed in the `MarshalBinary` rationale above.
  * `Mutate(seed int64) error`: The error return value discourages the use of
    `panic`, and enables better dev UX when debugging complex mutation
    operations.
  * `Mutate(ctx context.Context, seed int64) error`: The context makes this more
    future-proof by enabling advanced techniques once the repeatability
    requirement is removed. For example, `Mutate` could send an RPC to a service
    that feeds automatic crash report data to fuzzing tasks to increase the
    likelihood of encountering an interesting value. The context parameter and
    error return value might be YAGNI, but the added implementation complexity
    and developer cognitive load is believed to be minor enough to not worry
    about it (they can be ignored in most use cases).
  * Accept both `Mutate(seed int64)` and `Mutate(ctx context.Context, seed
    int64) error`: The second of the two can be added later after accumulating
    additional feedback from developers. Supporting both might result in
    unnecessary complexity.

Because mutation operations on custom types are expected to be somewhat complex
(otherwise a basic type would probably suffice), the `Mutate(ctx
context.Context, seed int64) error` option is believed to be the best choice.

### Minimization

To simplify the initial implementation, input types are not minimizable.
Minimizability could be added in the future by accepting a type like the
following and calling its `Minimize` method:

```go
// A customMinimizingMutator is a customMutator that supports attempts to reduce
// the size of an interesting value.
type customMinimizingMutator interface {
	customMutator
	// Minimize attempts to produce the smallest value (usually defined as
	// easiest to process by machine and/or humans) that still provides the same
	// coverage as the original value. It repeatedly generates candidates,
	// checking each one for suitability with the given callback. It returns
	// a suitable candidate if it is satisfied that the candidate is
	// sufficiently small or nil if it has given up searching.
	Minimize(seed int64, check func(candidate any) (bool, error)) (any, error)
}
```

## Compatibility

No changes in behavior are expected with existing code and seed corpus files.

## Implementation

See https://go.dev/cl/493304 for an initial attempt.

For the initial implementation, a worker can simply panic if one of the custom
type's methods returns an error. A future change can improve UX by plumbing the
error.

No particular Go release is targeted.
