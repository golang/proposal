# Design Draft: First Class Fuzzing

Author: Katie Hockman

[golang.org/s/draft-fuzzing-design](https://golang.org/s/draft-fuzzing-design)

This is a **Draft Design**, not a formal Go proposal, since it is a large
change that is still flexible.
The goal of circulating this draft design is to collect feedback to shape an
intended eventual proposal.

For this change, we will use [a Go Reddit
thread](https://golang.org/s/draft-fuzzing-reddit) to manage Q&A, since Reddit's
threading support can easily match questions with answers and keep separate
lines of discussion separate.

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
It should be just as easy to write fuzz targets as it is to write unit tests.
Developers should be able to use existing tools for which they are already
familiar, with small variations to support fuzzing.
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

At the beginning of the [fuzz target](#fuzz-target), a developer provides a
“[seed corpus](#seed-corpus)”.
This is an interesting set of inputs that will be tested using <code>[go
test](#go-command)</code> by default, and can provide a starting point for a
[mutation engine](#fuzzing-engine-and-mutator) if fuzzing.
The testing portion of the fuzz target is a function within an `f.Fuzz`
invocation.
This function runs like a standard unit test with `testing.T` for each input in
the seed corpus.
If the developer is fuzzing this target with the new `-fuzz` flag with `go
test`, then a [generated corpus](#generated-corpus) will be managed by the
fuzzing engine, and a mutator will generate new inputs to run against the
testing function, attempting to discover interesting inputs or
[crashers](#crashers).

With the new support, a fuzz target could look like this:

```
func FuzzMarshalFoo(f *testing.F) {
	// Seed the initial corpus
	inputs := []string{"cat", "DoG", "!mouse!"}
	for _, input := range inputs {
		f.Add(input, big.NewInt(0))
	}

	// Run the fuzz test
	f.Fuzz(func(t *testing.T, a string, num *big.Int) {
		t.Parallel()
		if num.Sign() <= 0 {
			t.Skip() // only test positive numbers
		}
		val, err := MarshalFoo(a, num)
		if err != nil {
			t.Skip()
		}
		if val == nil {
			t.Fatal("MarshalFoo: val == nil, err == nil")
		}
		a2, num2, err := UnmarshalFoo(val)
		if err != nil {
			t.Fatalf("failed to unmarshal valid Foo: %v", err)
		}
		if a2 == nil || num2 == nil {
			t.Error("UnmarshalFoo: a==nil, num==nil, err==nil")
		}
		if a2 != a || !num2.Equal(num) {
			t.Error("UnmarshalFoo does not match the provided input")
		}
	})
}
```

### testing.F

`testing.F` works similiarly to `testing.T` and `testing.B`.
It will implement the `testing.TB` interface.
Functions that are new and only apply to `testing.F` are listed below.

```
// Add will add the arguments to the seed corpus for the fuzz target. This
// cannot be invoked after or within the Fuzz function. The args must match
// those in the Fuzz function.
func (f *F) Add(args ...interface{})

// Fuzz runs the fuzz function, ff, for fuzz testing. It runs ff in a separate
// goroutine. Only one call to Fuzz is allowed per fuzz target, and any
// subsequent calls will panic. If ff fails for a set of arguments, those
// arguments will be added to the seed corpus.
func (f *F) Fuzz(ff interface{})
```

### Fuzz target

A fuzz target has two main components: 1) seeding the corpus and 2) the `f.Fuzz`
function which is executed for items in the corpus.

1.  The corpus generation is done first, and builds a seed corpus with
    interesting input values for the fuzz test.  This should be fairly quick,
    thus able to run before the fuzz testing begins, every time it’s run. These
    inputs are run by default with `go test`.
1.  The `f.Fuzz(...)` function is executed for each item in the corpus. If this
    target is being fuzzed, then new inputs will be generated and continously
    tested against the `f.Fuzz(...)` function.

The arguments to `f.Add(...)` and the function in `f.Fuzz(...)` must be the same
type within the target, and there must be at least one argument specified.
This will be ensured by a vet check.
Fuzzing of built-in types (e.g. simple types, maps, arrays) and types which
implement the BinaryMarshaler and TextMarshaler interfaces are supported.

Interfaces, functions, and channels are not appropriate types to fuzz, so will
never be supported.

### Seed Corpus

The **seed corpus** is the user-specified set of inputs to a fuzz target which
will be run by default with go test.
These should be composed of meaningful inputs to test the behavior of the
package, as well as a set of regression inputs for any newly discovered bugs
identified by the fuzzing engine.
This set of inputs is also used to “seed” the corpus used by the fuzzing engine
when mutating inputs to discover new code coverage.

The seed corpus can be populated programmatically using `f.Add` within the
fuzz target.
Programmatic seed corpuses make it easy to add new entries when support for new
things are added (for example adding a new key type to a key parsing function)
saving the mutation engine a lot of work.
These can also be more clear for the developer when they break the build when
something changes.

The fuzz target will always look in the package’s testdata/ directory for an
existing seed corpus to use as well, if one exists.
This seed corpus will be in a directory of the form `testdata/<target_name>`,
with a file for each unit that can be unmarshaled for testing.

_Examples:_

1: A fuzz target’s `f.Fuzz` function takes three arguments

```
f.Fuzz(func(t *testing.T, a string, b myStruct, num *big.Int) {...})

type myStruct struct {
    A, B string
    num int
}
```

In this example, string is a built-in type, so can be decoded directly.
`*big.Int` implements `UnmarshalText`, so can also be unmarshaled directly.
However, `myStruct` does not implement `UnmarshalBinary` or `UnmarshalText` so
the struct is pieced together recursively from its exported types. That would
mean two sets of bytes will be written for this type, one for each of A and B.
In total, four files would be written, and four inputs can be mutated when
fuzzing.

2:  A fuzz target’s `f.Fuzz` function takes a single `[]byte`

```
f.Fuzz(func(t *testing.T, b []byte) {...})
```

This is the typical “non-structured fuzzing” approach.
There is only one set of bytes to be provided by the mutator, so only one file
will be written.

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

#### Generated corpus

A generated corpus will be managed by the fuzzing engine and will live outside
the module.
New items can be added to this corpus in several ways, e.g. as part of the seed
corpus, or by the fuzzing engine (e.g. because of new code coverage).

The details of how the corpus is built and processed should be unimportant to
users.
This should be a technical detail that developers don’t need to understand in
order to seed a corpus or write a fuzz target.
Any existing files that a developer wants to include in the fuzz test should be
added to the seed corpus directory, `testdata/<target_name>`.


#### Minification + Pruning

Corpus entries will be minified to the smallest input that causes the failure
where possible, and pruned wherever possible to remove corpus entries that don’t
add additional coverage.
If a developer manually adds input files to the corpus directory, the fuzzing
engine may change the file names in order to help with this.

### Crashers

A **crasher** is a panic or failure in `f.Fuzz(...)`, or a race condition.
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
an appropriate cache directory on the developer's machine.
This directory will hold the generated corpus.
For example, the corpus for each fuzz target will be managed in a subdirectory
called `<module_name>/<pkg>/@corpus/<target_name>` where `<module_name>` will
follow module case-encoding and include the major version.

The default behavior of `go test` will be to build and run the fuzz targets
using the seed corpus only.
No special instrumentation would be needed, the mutation engine would not run,
and the test can be cached as usual.
This default mode **will not** run the generated corpus against the fuzz target.
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
-fuzztime
    Run enough iterations of the fuzz test to take t, specified as a
    time.Duration (for example, -fuzztime 1h30s).
    The default is to run forever.
    The special syntax Nx means to run the fuzz test N times
    (for example, -fuzztime 100x).
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

### Naming scheme for corpus files

There are several naming schemes for the corpus files which may be appropriate,
and the final decision is still undecided.

Take the following example:

```
f.Fuzz(func(t *testing.T, a string, b myStruct, num *big.Int) {...})

type myStruct struct {
    A, B string
    num int
}
```

For two corpus entries, this could be structured as follows:
* 0000001.string
* 0000001.myStruct.string
* 0000001.myStruct.string
* 0000001.big_int
* 0000002.string
* 0000002.myStruct.string
* 0000002.myStruct.string
* 0000002.big_int


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
   f.Fuzz(func(t *testing.T, a string) {
      ...
   })
```

Or individually as:

```
func FuzzFoo(f *testing.F) {
   f.MaxInputSize(1024)
   f.Fuzz(func(t *testing.T, a string) {
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

### Custom Generators

There may be a need for developers to craft custom generators for use by the
mutator.
The design can support this by using marshaling/unmarshaling to edit certain
fields, but the work to do so is a bit cumbersome.
For example, if a string should always have some prefix in order to work in the
fuzz function, one could do the following.

```
type myString struct {
	s string
}
func (m *myString) MarshalText() (text []byte, err error) {
	return []byte(m.s[len("SOME_PREFIX"):]), nil
}
func (m *myString) UnmarshalText(text []byte) error {
	m.s = "SOME_PREFIX" + string(text)
	return nil
}
func FuzzFoo(f *testing.F) {
	f.Fuzz(func(t *testing.T, m *myString) {...})
}
```