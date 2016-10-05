# Proposal: `-json` flag in `go test`

Author(s): Nodir Turakulov &lt;nodir@google.com&gt;

_With initial input by Russ Cox, Caleb Spare, Andrew Gerrand and Minux Ma._

Last updated: 2016-09-14

Discussion at https://golang.org/issue/2981.

*  [Abstract](#abstract)
*  [Background](#background)
*  [Proposal](#proposal)
   *  [`testing` package](#testing-package)
   *  [Example output](#example-output)
*  [Rationale](#rationale)
*  [Compatibility](#compatibility)
*  [Implementation](#implementation)

## Abstract

Add `-json` flag to `go test`.
When specified, `go test` stdout is JSON.

## Background

There is a clear need in parsing test and benchmark results by third party
tools, see feedback in https://golang.org/issue/2981.
Currently `go test` output format is suited for humans, but not computers.
Also a change to the current format may break existing programs that parse
`go test` output.

Currently, under certain conditions, `go test` streams test/benchmark results
so a user can see them as they happen.
Also streaming prevents losing data if `go test` crashes.
This proposal attempts to preserve streaming capability in the `-json` mode, so
third party tools interpreting `go test` output can stream results too.

`-json` flag was originally proposed by Russ Cox in
https://golang.org/issue/2981 in 2012. This proposal has several differences.

## Proposal

I propose the following user-visible changes:

*   add `-json` flag to `go test`
    *   `-json`: `go test` stdout is a valid [JSON Text Sequence][rfc7464]
        of JSON objects containing test binary artifacts.
        Format below.
    *   `-json -v`: verbose messages are printed to stderr, so stdout contains
        only JSON.
    *   `-json -n`: not supported
    *   `-json -x`: not supported
*   In `testing` package
    *   Add `type State int` with constants to describe test/benchmark states.
    *   Add type `JSONResult` for JSON output.
    *   Change `Cover.CoveredPackages` field type from `string` to `[]string`.

Type definitions and details below.

### `testing` package

```go

// State is one of test/benchmark execution states.
// Implements fmt.Stringer, json.Marshaler and json.Unmarshaler.
type State int

const (
    // RUN means a test/benchmark execution has started
    RUN State = iota + 1
    PASS
    FAIL
    SKIP
)

// JSONResult structs encoded in JSON are emitted by `go test` if -json flag is
// specified.
type JSONResult struct {
    // Configuration is metadata produced by test/benchmark infrastructure.
    // The interpretation of a key/value pair is up to tooling, but the key/value
    // pair describes all test/benchmark results that follow,
    // until overwritten by a JSONResult with a non-empty Configuration field.
    //
    // The key begins with a lowercase character (as defined by unicode.IsLower),
    // contains no space characters (as defined by unicode.IsSpace)
    // nor upper case characters (as defined by unicode.IsUpper).
    // Conventionally, multiword keys are written with the words separated by hyphens,
    // as in cpu-speed.
    Configuration map[string]string  `json:",omitempty"`

    // Package is a full name of the package containing the test/benchmark.
    // It is zero iff Name is zero.
    Package string  `json:",omitempty"`
    // Name is the name of the test/benchmark that this JSONResult is about.
    // It can be empty if JSONResult describes global state, such as
    // Configuration or Stdout/Stderr.
    Name    string  `json:",omitempty"`
    // State is the current state of the test/benchmark.
    // It is non-zero iff Name is non-zero.
    State   State   `json:",omitempty"`
    // Procs is the value of runtime.GOMAXPROCS for this test/benchmark run.
    // It is specified only in the first JSONResult of a test/benchmark.
    Procs   int     `json:",omitempty"`
    // Log is log created by calling Log or Logf functions of *T or *B.
    // A JSONResult with Log is emitted by go test as soon as possible.
    // First occurrence of test/benchmark does not contain logs.
    Log     string  `json:",omitempty"`

    // Benchmark contains benchmark-specific details.
    // It is emitted in the final JSONResult of a benchmark with a terminal
    // State if the benchmark does not have sub-benchmarks.
    Benchmark *BenchmarkResult  `json:",omitempty"`

    // CoverageMode is coverage mode that was used to run these tests.
    CoverageMode     string    `json:",omitempty"
    // TotalStatements is the number of statements checked for coverage.
    TotalStatements  int64     `json:",omitempty"`
    // ActiveStatements is the number of statements covered by tests, examples
    // or benchmarks.
    ActiveStatements int64     `json:",omitempty"`
    // CoveragedPackages is full names of packages included in coverage.
    CoveredPackages  []string  `json:",omitempty"`

    // Stdout is text written by the test binary directly to os.Stdout.
    // If this field is non-zero, all others are zero.
    Stdout string  `json:",omitempty"`
    // Stderr is text written by test binary directly to os.Stderr.
    // If this field is non-zero, all others are zero.
    Stderr string  `json:",omitempty"`
}
```

### Example output

Here is an example of `go test -json` output.
It is simplified and commented for the convenience of the reader;
in practice it will be unindented and will contain JSON Text Sequence separators
and no comments.

```json
// go test emits environment configuration
{
    "Configuration": {
        "commit": "7cd9055",
        "commit-time": "2016-02-11T13:25:45-0500",
        "goos": "darwin",
        "goarch": "amd64",
        "cpu": "Intel(R) Core(TM) i7-4980HQ CPU @ 2.80GHz",
        "cpu-count": "8",
        "cpu-physical-count": "4",
        "os": "Mac OS X 10.11.3",
        "mem": "16 GB"
    }
}
// TestFoo started
{
    "Package": "github.com/user/repo",
    "Name": "TestFoo",
    "State": "RUN",
    "Procs": 4
}
// A line was written directly to os.Stdout
{
    "Package": "github.com/user/repo",
    "Stderr": "Random string written directly to os.Stdout\n"
}
// TestFoo passed
{
    "Package": "github.com/user/repo",
    "Name": "TestFoo",
    "State": "PASS",
}
// TestBar started
{
    "Package": "github.com/user/repo",
    "Name": "TestBar",
    "State": "RUN",
    "Procs": 4
}
// TestBar logged a line
{
    "Package": "github.com/user/repo",
    "Name": "TestBar",
    "State": "RUN",
    "Log": "some test output"
}
// TestBar failed
{
    "Package": "github.com/user/repo",
    "Name": "TestBar",
    "State": "FAIL"
}
// TestQux started
{
    "Package": "github.com/user/repo",
    "Name": "TestQux",
    "State": "RUN",
    "Procs": 4
}
// TestQux calls T.Fatal("bug")
{
    "Package": "github.com/user/repo",
    "Name": "TestBar",
    "State": "RUN",
    "Log": "bug"
}
{
    "Package": "github.com/user/repo",
    "Name": "TestQux",
    "State": "FAIL"
}
// TestComposite started
{
    "Package": "github.com/user/repo",
    "Name": "TestComposite",
    "State": "RUN",
    "Procs": 4
}
// TestComposite/A=1 subtest started
{
    "Package": "github.com/user/repo",
    "Name": "TestComposite/A=1",
    "State": "RUN",
    "Procs": 4
}
// TestComposite/A=1 passed
{
    "Package": "github.com/user/repo",
    "Name": "TestComposite/A=1",
    "State": "PASS",
}
// TestComposite passed
{
    "Package": "github.com/user/repo",
    "Name": "TestComposite",
    "State": "PASS",
}
// Example1 started
{
    "Package": "github.com/user/repo",
    "Name": "Example1",
    "State": "RUN",
    "Procs": 4
}
// Example1 passed
{
    "Package": "github.com/user/repo",
    "Name": "Example1",
    "State": "PASS"
}
// BenchmarkRun started
{
    "Package": "github.com/user/repo",
    "Name": "BenchmarkBar",
    "State": "RUN",
    "Procs": 4
}
// BenchmarkRun passed
{
    "Package": "github.com/user/repo",
    "Name": "BenchmarkBar",
    "State": "PASS",
    "Benchmark": {
        "T": 1000000,
        "N": 1000,
        "Bytes": 100,
        "MemAllocs": 10,
        "MemBytes": 10
    }
}
// BenchmarkComposite started
{
    "Package": "github.com/user/repo",
    "Name": "BenchmarkComposite",
    "State": "RUN",
    "Procs": 4
}
// BenchmarkComposite/A=1 started
{
    "Package": "github.com/user/repo",
    "Name": "BenchmarkComposite/A=1",
    "State": "RUN",
    "Procs": 4
}
// BenchmarkComposite/A=1 passed
{
    "Package": "github.com/user/repo",
    "Name": "BenchmarkComposite/A=1",
    "State": "PASS",
    "Benchmark": {
        "T": 1000000,
        "N": 1000,
        "Bytes": 100,
        "MemAllocs": 10,
        "MemBytes": 10
    }
}
// BenchmarComposite passed
{
    "Package": "github.com/user/repo",
    "Name": "BenchmarComposite",
    "State": "PASS"
}
// Total coverage information in the end.
{
    "CoverageMode": "set",
    "TotalStatements":  1000,
    "ActiveStatements": 900,
    "CoveredPackages": [
        "github.com/user/repo"
    ]
}
```

## Rationale

Alternatives:

*   Add `-format` and `-benchformat` flags proposed in
    https://github.com/golang/go/issues/12826.
    While this is simpler to implement, users will have to do more work to
    specify format and then parse it.

Trade offs:

*   I propose to make `-json` mutually exclusive with `-n` and `-x` flags.
    These flags belong to `go build` subcommand while this proposal is scoped
    to `go test`.
    Supporting the flags would require adding JSON output knowledge to
    `go/build.go`.
*   `JSONResult.Benchmark.T` provides duration of a benchmark run, but there is
    not an equivalent for a test run.
    This is a trade off for `JSONResult` simplicity.
    We don't have to define `TestResult` because `JSONResult` is enough to
    describe a test result.

    Currently `go test` does not provide test timing info, so the proposal is
    consistent with the current `go test` output.


## Compatibility

The only backwards incompatibility is changing `testing.Cover.CoveredPackages`
field type, but `testing.Cover` is not covered by Go 1 compatibility
guidelines.

## Implementation

Most of the work would be done by the author of this proposal.

The goal is to get agreement on this proposal and to complete the work
before the 1.8 freeze date.

[testStreamOutput]: https://github.com/golang/go/blob/0b248cea169a261cd0c2db8c014269cca5a170c4/src/cmd/go/test.go#L361-L369
[rfc7464]: https://tools.ietf.org/html/rfc7464
