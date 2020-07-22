# Design Draft: First Class Fuzzing

Author: Katie Hockman

Last updated: 2020-07-21

Discussion at https://golang.org/issue/40307

## Abstract

Systems built with Go must be secure and resilient.
Fuzzing can help with this, by allowing developers to identify and fix bugs,
empowering them to improve the quality of their code.
However, there is no standard way of fuzzing Go code today, and no
out-of-the-box tooling or support.
This proposal will create a unified fuzzing narrative which makes fuzzing a
first class option for Go developers.

## Background

Fuzzing is a type of automated testing which continuously manipulates inputs to
a program to find issues such as panics, bugs, or data races to which the code
may be susceptible.
These semi-random data mutations can discover new code coverage that existing
unit tests may miss, and uncover edge-case bugs which would otherwise go
unnoticed.
This type of testing works best when able to run more mutations quickly, rather
than fewer mutations intelligently.

Since fuzzing can reach edge cases which humans often miss, fuzz testing is
particularly valuable for finding security exploits and vulnerabilities.
Fuzz tests have historically been authored primarily by security engineers, and
hackers may use similar methods to find vulnerabilities maliciously.
However, writing fuzz targets needn’t be constrained to developers with security
expertise.
There is great value in fuzz testing all programs, including those
which may be more subtly security-relevant, especially those working with
arbitrary user input.

Other languages support and encourage fuzz testing.
[libFuzzer](https://llvm.org/docs/LibFuzzer.html) and
[AFL](https://lcamtuf.coredump.cx/afl/) are widely used, particularly with
C/C++, and AFL has identified vulnerabilities in programs like Mozilla Firefox,
Internet Explorer, OpenSSH, Adobe Flash, and more.
In Rust,
[cargo-fuzz](https://fitzgeraldnick.com/2020/01/16/better-support-for-fuzzing-structured-inputs-in-rust.html)
allows for fuzzing of structured data in addition to raw bytes, allowing for
even more flexibility with authoring fuzz targets.
Existing tools in Go, such as go-fuzz, have many [success
stories](https://github.com/dvyukov/go-fuzz#trophies), but there is no fully
supported or canonical solution for Go.
The goal is to make fuzzing a first-class experience, making it so easy that it
becomes the norm for Go packages to have fuzz targets.
Having fuzz targets available in a standard format makes it possible to use them
automatically in CI, or even as the basis for experiments with different
mutation engines.

There is strong community interest for this.
It’s the third most supported
[proposal](https://github.com/golang/go/issues/19109) on the issue tracker (~500
+1s), with projects like [go-fuzz](https://github.com/dvyukov/go-fuzz) (3.5K
stars) and other community-led efforts that have been in the works for several
years.
Prototypes exist, but lack core features like robust module support, go command
integration, and integration with new [compiler
instrumentation](https://github.com/golang/go/issues/14565).

## Proposal

Support `Fuzz` functions in Go test files, making fuzzing a first class option
for Go developers through unified, end-to-end support.

## Rationale

One alternative would be to keep with the status quo and ask Go developers to
use existing tools, or build their own as needed.
Developers could use tools
like [go-fuzz](https://github.com/dvyukov/go-fuzz) or
[fzgo](https://github.com/thepudds/fzgo) (built on top of go-fuzz) to solve some
of their needs.
However, each existing solution involves more work than typical Go testing, and
is missing crucial features.
Fuzz testing shouldn’t be any more complicated, or any less feature-complete,
than other types of Go testing (like benchmarking or unit testing).
Existing solutions add extra overhead such as custom command line tools,
separate test files or build tags, lack of robust modules support, and lack of
testing/customization support from the standard library.

By making fuzzing easier for developers, we will increase the amount of Go code
that’s covered by fuzz tests.
This will have particularly high impact for heavily depended upon or
security-sensitive packages.
The more Go code that’s covered by fuzz tests, the more bugs will be found and
fixed in the wider ecosystem.
These bug fixes matter for the stability and security of systems written in Go.

The best solution for Go in the long-term is to have a feature-rich, fully
supported, unified narrative for fuzzing.
It should be just as easy to write fuzz targets as it is to write unit tests,
and developers shouldn’t need to learn custom workflows or new tools to build or
run these fuzz targets.
Along with the language support, we must provide documentation, tutorials, and
incentives for Go package owners to add fuzz tests to their packages.
This is a measurable goal, and we can track the number of fuzz targets and
resulting bug fixes resulting from this design.

Standardizing this also provides new opportunities for other tools to be built,
and integration into existing infrastructure.
For example, this proposal creates consistency for building and running fuzz
targets, making it easier to build turnkey
[OSS-Fuzz](https://github.com/google/oss-fuzz) support.

In the long term, this design could start to replace existing table tests,
seamlessly integrating into the existing Go testing ecosystem.

Some motivations written or provided by members of the Go community:

*   https://tiny.cc/why-go-fuzz
*   [Around 400 documented bugs](https://github.com/dvyukov/go-fuzz#trophies)
    were found by owners of various open-source Go packages with go-fuzz.

## Compatibility

This proposal will not impact any current compatibility promises.
It is possible that there are existing `FuzzX` functions in yyy\_test.go files
today, and the go command will emit an error on such functions if they have an
unsupported signature.
This should however be unlikely, since most existing fuzz tools don’t
support these functions within yyy\_test.go files.

## Implementation

There are several components to this proposal which are described below.
The big pieces to be supported in the MVP are: support for fuzzing built-in
types, structs, and types which implement the BinaryMarshaler and
BinaryUnmarshaler interfaces or the TextMarshaler and TextUnmarshaler
interfaces, a new `testing.F` type, full `go` command support, and building a
tailored-to-Go fuzzing engine using the [new compiler
instrumentation](https://golang.org/issue/14565).

There is already a lot of existing work that has been done to support this, and
we should leverage as much of that as possible when building native support,
e.g. [go-fuzz](https://github.com/dvyukov/go-fuzz),
[fzgo](https://github.com/thepudds/fzgo).
Work for this will be done in a dev branch (e.g. dev.fuzzing) of the main Go
repository, led by Katie Hockman, with contributions from other members of the
Go team and members of the community as appropriate.

### Overview

The **fuzz target** is a `FuzzX` function in a test file. Each fuzz target has
its own corpus of inputs.

The **fuzz function** is the function that is executed for every seed or
generated corpus entry.

At the beginning of the fuzz target, a developer provides a “[seed
corpus](#seed-corpus)”.
This is an interesting set of inputs that will be tested using <code>[go
test](#go-command)</code> by default, and can provide a starting point for a
[mutation engine](#fuzzing-engine-and-mutator) if fuzzing.
The testing portion of the fuzz target is a function within an
<code>[f.Fuzz](#fuzz-function)</code> invocation.
This function is run for each input in the seed corpus.
If the developer is fuzzing this target, then an [on disk
corpus](#fuzzing-engine-managed-corpus) will be managed by the fuzzing engine,
and a mutator will generate new inputs to run against the testing function,
attempting to discover interesting inputs or [crashes](#crashers).

With the new support, a fuzz target will look something like this:

```
func FuzzMarshalFoo(f *testing.F) {
	// Seed the initial corpus
	inputs := []string{"cat", "DoG", "!mouse!"}
	for _, input := range inputs {
		f.Add(input, big.NewInt(100))
	}

	// Run the fuzz test
	f.Fuzz(func(a string, num *big.Int) {
		f.Parallel()
		if num.Sign() <= 0 {
			f.BadInput() // only test positive numbers
		}
		val, err := MarshalFoo(a, num)
		if err != nil {
			f.BadInput()
		}
		if val == nil {
			f.Fatal("MarshalFoo: val == nil, err == nil")
		}
		a2, num2, err := UnmarshalFoo(val)
		if err != nil {
			f.Fatalf("failed to unmarshal valid Foo: %v", err)
		}
		if a2 == nil || num2 == nil {
			f.Error("UnmarshalFoo: a==nil, num==nil, err==nil")
		}
		if a2 != a || !num2.Equal(num) {
			f.Error("UnmarshalFoo does not match the provided input")
		}
	})
}
```

### testing.F

Below is the list of methods on testing.F.

```
// Add will add the arguments to the seed corpus for the fuzz target. This
// cannot be called within the Fuzz function. The args must match those in
// in the Fuzz function.
func (f *F) Add(args ...interface{})

// Cleanup registers a function to be called when the fuzz target completes.
func (f *F) Cleanup(fn func())

// Error marks the arguments as having failed the test, but continues execution
// for that set of arguments.
func (f *F) Error(args ...interface{})

// Errorf behaves the same as Error but formats its arguments according to the
// format, analogous to Printf.
func (f *F) Errorf(args ...interface{})

// Fatal marks the arguments as having failed the test and stops its execution
// by calling runtime.Goexit (which then runs all deferred calls in the current
// goroutine). The fuzz target keeps executing with the next set of arguments.
func (f *F) Fatal(args ...interface{})

// Fatalf behaves the same as Fatal but formats its arguments according to the
// format, analogous to Printf.
func (f *F) Fatalf(args ...interface{})

// Fuzz runs the fuzz function with the target. It runs fn in a separate
// goroutine. Only one call to Fuzz is allowed per fuzz target, and any
// subsequent calls will panic. It only returns once all arguments have been
// passed to the fuzz function.
func (f *F) Fuzz(fn interface{})

// Helper marks the calling function as a helper function.
func (f *F) Helper()

// Log formats its arguments using default formatting, analogous to Println,
// and records the text in the error log.
func (f *F) Log(args ...interface{})

// Logf formats its arguments according to the format, analogous to Printf, and
// records the text in the error log.
func (f *F) Logf(args ...interface{})

// Name returns the name of the running fuzz target.
func (f *F) Name()

// Parallel signals that multiple instances of the Fuzz function can be run in
// parallel on separate goroutines. This must be called within an f.Fuzz
// function.
func (f *F) Parallel()

// Skip marks the test as having been skipped and stops its execution by
// calling runtime.Goexit. Skip must be called before the Fuzz function.
func (f *F) Skip()

// BadInput indicates that the input has failed some pre-condition, and the
// rest of the test should be skipped. The args will not be added to the
// corpus, nor will they be considered a crasher.
func (f *F) BadInput()
```

### Fuzz function

A fuzz function has two main sections: 1) initializing and seeding the corpus
and 2) the Fuzz function which is executed for every seed or generated corpus
entry.

1.  The corpus generation is done first, and builds a seed corpus by calling
    `f.Add(...)` with interesting input values for the fuzz test.
    This should be fairly quick, thus able to run before the fuzz testing
    begins, every time it’s run. These inputs are run by default with `go test`.
1.  The `f.Fuzz(...)` function is executed with the provided seed corpus.
    If this target is being fuzzed, then new inputs of the provided argument
    types will be continously tested against the `f.Fuzz(...)` function.

The arguments to `f.Add(...)` and the function in `f.Fuzz(...)` must be the same
type within the target, and there must be at least one argument specified.
This will be ensured by a vet check.
Fuzzing of built-in types (e.g. simple types, maps, arrays) and types which
implement the BinaryMarshaler and TextMarshaler interfaces are supported.

Interfaces, functions, and channels will never be supported.

### Seed Corpus

The **seed corpus** is the user-specified set of inputs to a fuzz target which
will be run by default with go test.
These are a set of meaningful input to test the behavior of the package, as well
as a set of regression tests for any newly discovered bugs discovered by the
fuzzing engine.
This set of inputs is also used to “seed” the corpus used by the fuzzing engine
when mutating inputs to discover new code coverage.

The fuzz target will always look in the package’s testdata/ directory for an
existing seed corpus to use, if one exists.

The seed corpus can also be populated programmatically using `f.Add` within the
fuzz target.
Programmatic seed corpuses make it easy to add new entries when support for new
things are added (for example adding a new key type to a key parsing function)
saving the mutation engine a lot of work.
These can also be more clear for the developer when they break the build when
something changes.

### Fuzzing Engine and Mutator

A new **coverage-guided fuzzing engine**, written in Go, will be built.
This fuzzing engine will be responsible for using compiler instrumentation to
understand coverage information, generating test arguments with a mutator, and
maintaining the corpus.

The **mutator** is responsible for working with a generator to mutate bytes to
be used as input to the fuzz target.

Take the following `f.Fuzz` arguments as an example.

```
    A string       // N bytes
    B int64        // 8 bytes
    Num *big.Int   // M bytes
```

A generator will provide some bytes for each type, where the number of bytes
could be constant (e.g. 8 bytes for an int64) or variable (e.g. N bytes for a
string, likely with some upper bound).

For constant-length types, the number of bytes can be hard-coded into the
fuzzing engine, making generation simpler.

For variable-length types, the mutator is responsible for varying the number of
bytes requested from the generator.

These bytes then need to be converted to the types used by the `f.Fuzz`
function.
The string and other built-in types can be decoded directly.
For other types, this can be done using either
<code>[UnmarshalBinary](https://pkg.go.dev/encoding?tab=doc#BinaryUnmarshaler)</code>
or
<code>[UnmarshalText](https://pkg.go.dev/encoding?tab=doc#TextUnmarshaler)</code>
if implemented on the type.
If building a struct, it can also build exported fields recursively as needed.

#### Fuzzing engine managed corpus

An on disk corpus will be managed by the fuzzing engine and will live outside
the module.
New items can be added to the corpus in several ways, e.g. adding it to the seed
corpus, or by the fuzzing engine (e.g. because of new code coverage).
The details of how the corpus is built and processed should be unimportant to
users.
This should be a technical detail that developers don’t need to understand in
order to seed a corpus or write a fuzz target.
However, a developer still has the ability to copy files directly into the on
disk corpus directory if they wish to do so.

Under the hood, the corpus will be several files, with each file being a “unit”,
or bytes, that can be umarshaled for use in the fuzz target.

_Examples:_

1: A fuzz target’s `f.Fuzz` function takes three arguments, a `string`, a
`myString`, and a `*big.Int`

```
f.Fuzz(func(a string, b myString, num *big.Int) { ... })
```

There are three “units” that will need to be provided by the mutator, so three
files written to the corpus for this fuzz target (one per input).
The string can be decoded directly by the mutator.
The `myString` and `*big.Int` types both need an `UnmarshalText` or
`UnmarshalBinary` implementation in order for the mutator to decode the
generator-provided bytes into the respective type.

2:  A fuzz target’s `f.Fuzz` function takes one argument, a single `[]byte`

```
f.Fuzz(func(b []byte) { ... })
```

This is the typical “non-structured fuzzing” approach, and one that many
existing Go fuzz targets currently implement.
There is only one “unit” to be provided by the mutator, so only one file per
corpus entry will be written.

#### Minification + Pruning

Corpus entries will be minified to the smallest input that causes the failure
where possible, and pruned wherever possible to remove corpus entries that don’t
add additional coverage.
If a developer manually adds input files to the corpus directory, the fuzzing
engine may change the file names in order to help with this.

### Crashers

A **crasher** is a panic found within `f.Fuzz(...)`, a race condition, a call to
`Fatal`, or a call to `Error`.
By default, the fuzz target will stop after the first crasher is found, and a
crash report will be provided.
Crash reports will include the inputs that caused the crash and the resulting
error message or stack trace.
The crasher inputs will be written to the package's testdata/ directory as a
seed corpus entry.

Since this crasher is added to testdata/, which will then be run by default as
part of the seed corpus for the fuzz target, this can act as a test for the new
failure.
A user experience may look something like this:

1.  A user runs `go test -fuzz=FuzzFoo`, and a crasher is found while fuzzing.
1.  The arguments that caused the crash are added to a testdata directory within
    the package automatically.
1.  A subsequent run of `go test` (even without `-fuzz=FuzzFoo`) will then hit
    this newly discovering failing condition, and continue to fail until the bug
    is fixed.

### Go command

Fuzz testing will only be supported in module mode, and if run in GOPATH mode
the fuzz targets will be ignored.

Fuzz targets will be in *_test.go files, and can be in the same file as Test and
Benchmark targets.
These test files can exist wherever *_test.go files can currently live, and do
not need to be in any fuzz-specific directory or have a fuzz-specific file name
or build tag.

A new environment variable will be added, `$GOFUZZCACHE`, which will default to
`$HOME/Library/Caches/go-test-fuzz`.
This directory will hold the mutator-managed corpus.
For example, the corpus for each fuzz target will be managed in a subdirectory
called `<module_name>/<pkg>/@corpus/<target_name>` where `<module_name>` will
follow module case-encoding and include the major version.

The default behavior of `go test` will be to build and run the fuzz targets
using the seed corpus only.
No special instrumentation would be needed, the mutation engine would not run,
and the test can be cached as usual.
This default mode **will not** run the existing on disk corpus against the fuzz
target.
This is to allow for reproducibility and cacheability for `go test` executions
by default.

In order to run a fuzz target with the mutation engine, `-fuzz` will take a
regexp which must match only one fuzz target.
In this situtation, only the fuzz target will run (ignoring all other tests).
Only one package is allowed to be tested at a time in this mode.
The following flags will be added or have modified meaning:

```
-fuzz name
    Run the fuzz target with the given regexp. Must match at most one fuzz
    target.
-keepfuzzing
    Keep running the target if a crasher is found. (default false)
-parallel
    Allow parallel execution of f.Fuzz functions that call f.Parallel.
    The value of this flag is the maximum number of f.Fuzz functions to run
    simultaneously within the given fuzz target. (default GOMAXPROCS)
-race
    Enable data race detection while fuzzing. (default true)
```

`go test` will not respect `-p` when running with `-fuzz`, as it doesn't make
sense to fuzz multiple packages at the same time.

## Open issues and future work

### Options

There are options that developers often need to fuzz effectively and safely.
These options will likely make the most sense on a target-by-target basis,
rather than as a `go test` flag.
Which options to make available still needs some investigation.
The options may be set in a few ways.

As a struct:

```
func FuzzFoo(f *testing.F) {
   f.FuzzOpts(&testing.FuzzOpts {
      MaxInputSize: 1024,
   })
   f.Fuzz(func(a string) {
      ...
   })
```

Or individually as:

```
func FuzzFoo(f *testing.F) {
   f.MaxInputSize(1024)
   f.Fuzz(func(a string) {
      ...
   })
}
```

### Dictionaries

Support accepting [dictionaries](https://llvm.org/docs/LibFuzzer.html#id31) when
seeding the corpus to guide the fuzzer.

### Instrument specific packages only

We might need a way to specify to instrument only some packages for coverage,
but there isn’t enough data yet to be sure.
One example use case for this would be a fuzzing engine which is spending too
much time discovering coverage in the encoding/json parser, when it should
instead be focusing on coverage for some intended package.

There are also questions about whether or not this is possible with the current
compiler instrumentation available.
By runtime, the fuzz target will have already been compiled, so recompiling to
leave out (or only include) certain packages may not be feasible.

### Auto-generated unit test

A crash report may be able to provide a reproducible unit test.
The generated unit test can be copied directly into a *_test.go file, or can be
used as a good starting point for a regression test.
This test can be auto-generated from the fuzz target, with a few changes:

*   Creating the vars to be used in the fuzz target will vary depending on the
    type. In the case of a simple type, it may be instantiated directly from the
    bytes. If, for example, the bytes are not printable, then they may be
    decoded from hex before being decoded using UnmarshalBinary.
*   The name passed into `t.Run()` will be the name of the associated fuzz
    target.
*   Each `f.BadInput()` will be turned into a `panic("unreachable code")`.
*   Each `f.Add()` will be turned into a no-op on the LHS, and will keep the RHS
    (ie. `_=<args to f.Add()>`). This is to preserve any necessary setup, and
    can be removed at the developer’s discretion.
*   All other `testing.F` functions will be converted to the equivalent
    `testing.T` function.

```
const corpus_w5fcysjrx7yqtD = ``  // const name is the hash

func TestMarshalFoo(t *testing.T) {
   inputs := []string{"cat", "dog", "mouse", "bird", "turtle"}
   for _, input := range inputs {
       _, _ = input, big.NewInt(100)
   }
   var a string, num *big.Int, other otherType
   a = "badString"
   if num.UnmarshalText([]byte("10")) != nil {
    panic("failed to unmarshal num")
   }
   otherBytes, err := hex.DecodeString("a3fd12jd03df")
   if err != nil {
      panic("failed to decode other hex")
   }
   if other.UnmarshalBinary(otherBytes) != nil {
     panic("failed to unmarshal other")
   }
   // Run the fuzz test with these arguments
   t.Run("FuzzMarshalFoo", func(t *testing.T) {
       if num.Sign() <= 0 {
           panic("unreachable code")  // only test positive numbers
       }
       val, err := MarshalFoo(test.A, test.Num)
       if err != nil {
           panic("unreachable code")  // bad input
       }
       if val == nil {
           t.Fatal("val == nil, err == nil")
       }
       a2, num2, err := UnmarshalFoo(val)
       if err != nil {
           t.Fatalf("failed to unmarshal valid Foo: %v", err)
       }
       if a2 == nil || num2 == nil {
           t.Error("UnmarshalFoo succeeded but gave a nil a and num")
       }
       if a2 != a || !num2.Equal(test.Num) {
           t.Error("UnmarshalFoo does not match the provided input")
       }
   })
}
