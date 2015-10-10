# Proposal: `-json` flag in `go test`

Author(s): Nodir Turakulov &lt;nodir@google.com&gt;

_With initial input by Russ Cox, Caleb Spare, Andrew Gerrand and Minux Ma._

Last updated: 2015-10-07

Discussion at https://golang.org/issue/2981.

*  [Abstract](#abstract)
*  [Background](#background)
*  [Proposal](#proposal)
   *  [`testing` package](#testing-package)
   *  [`go test`](#go-test)
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
This proposal attempts to preserve streaming capability in the `-json` mode, so
third party tools interpreting `go test` output can stream results too.

`-json` flag was originally proposed by Russ Cox in
https://golang.org/issue/2981 in 2012.
This proposal differs from the original:

* supports streaming
* `go test` JSON output contains unrecognized test binary output.
* minimal changes in `testing` package.

## Proposal

I propose the following user-visible changes:

*   add `-json` flag to `go test`
    *   `-json`: all `go test` stdout is indented JSON objects containing
        test binary artifacts, separated by newline.
        Format below.
    *   `-json -v`: verbose messages are printed to stderr,
        so stdout contains only JSON.
    *   `-json -n`: not supported
    *   `-json -x`: not supported
*   In `testing` package
    *   Add `type State` which is enum (`PASS`, `FAIL`, `SKIP`).
    *   Add `Name`, `Log`, `State` and `Procs` fields to `BenchmarkResult`.
    *   Add `type CoverageResult`.
    *   In type `Cover`, change `CoveredPackages` field type from `string` to
        `[]string`. This type is not covered by Go 1 compatibility guidelines.
    *   Add `type JSONResult` for JSON output.

Type definitions and details below.

### `testing` package

```go

// State is one of test/benchmark execution states.
// Implements fmt.Stringer, json.Marshaler and json.Unmarshaler.
type State int

const (
    PASS State = iota
    FAIL
    SKIP
)

type BenchmarkResult struct {
    Name  string
    State State
    Procs int    // The value of runtime.GOMAXPROCS for this benchmark run.
    Log   string // The log created by calling (*B).Log and (*B).Logf.

    // existing fields
    // make them `json:",omitempty"`
}

// CoverageResult is aggregated code coverage info.
// It is used for `go test` JSON output.
// To get full coverage info, use -coverprofile flag in go test.
type CoverageResult struct {
    Mode             string
    TotalStatements  int64
    ActiveStatements int64
    CoveredPackages  []string
}

// JSONResult is used for test binary JSON output format.
//
// Each time a test/benchmark completes, the test binary emits one result
// in unindented JSON format to stdout, surrounded by '\n'.
type JSONResult struct {
  // BenchmarkResult contains fields used by both benchmarks and tests,
  // such as Name and State.
  BenchmarkResult

  Coverage  *CoverageResult  `json:",omitempty"`
}
```

Example of a test binary stdout (JSON output is made indented for the
convenience of the reader. It will be unindented in fact):

```json
{
    "Name": "TestFoo",
    "State": "PASS",
    "T": 1000000
}
Random string written directly to os.Stdout.
{
    "Name": "TestBar",
    "State": "PASS",
    "T": 1000000,
    "Log": "some test output\n"
}
{
    "Name": "Example1",
    "State": "PASS",
    "T": 1000000,
}
{
    "Name": "BenchmarkBar",
    "State": "PASS",
    "T": 1000000,
    "N": 1000,
    "Bytes": 100,
    "MemAllocs": 10,
    "MemBytes": 10
}
{
    "Coverage": {
        "Mode": "set",
        "TotalStatements":  1000,
        "ActiveStatements": 900,
        "CoveredPackages": [
            "example.com/foobar"
        ]
    }
}
```

### `go test`

`go test` JSON output format:

```go
// TestResult contains one output line of a test binary.
type TestResult struct {
  Package string // package of the test binary.

  Result    *testing.JSONResult  `json:",omitempty"`
  Stdout    string               `json:",omitempty"` // Unrecognized stdout of the test binary.
  Stderr    string               `json:",omitempty"` // Stderr output line of the test binary.
}
```

Example `go test -json` output


```json
{
    "Package": "example.com/foobar",
    "Result": {
        "Name": "TestFoo",
        "State": "PASS",
        "T": 1000000
    }
}
{
    "Package": "example.com/foobar",
    "Stdout": "Random string written directly to os.Stdout.\n"
}
{
    "Package": "example.com/foobar",
    "Result": {
        "Name": "TestBar",
        "State": "PASS",
        "T": 1000000,
        "Log": "some test output\n"
    }
}
{
    "Package": "example.com/foobar",
    "Result": {
        "Name": "Example1",
        "State": "PASS",
        "T": 1000000
    }
}
{
    "Package": "example.com/foobar",
    "Result": {
        "Name": "BenchmarkBar",
        "State": "PASS",
        "Procs": 8,
        "T": 1000000,
        "N": 1000,
        "Bytes": 0,
        "MemAllocs": 0,
        "MemBytes": 0
    }
}
{
    "Package": "example.com/foobar",
    "Result": {
        "Coverage": {
            "Mode": "set",
            "TotalStatements":  1000,
            "ActiveStatements": 900,
            "CoveredPackages": [
                "example.com/foobar"
            ]
        }
    }
}

```

## Rationale

*   A test binary surrounds `testing.JSONResult` JSON with `\n` to handle the
    situation when a string without a trailing `\n` is printed directly to
    `os.Stdout`.
*   A test binary always streams results so we don't loose them if the binary
    panics.

Alternatives:

*   Add `-format` and `-benchformat` flags proposed in
    https://github.com/golang/go/issues/12826. This is simpler to implement
    by moving the burden of output parsing to third party programs.

Trade offs:

*   `testing.JSONResult` is used for tests, examples and benchmarks.
    A third party tool would have to determine the type of the result by the
    prefix of `"Name"` property, e.g. tests always start with `"Test"`.
    This is a trade off for simplicity of `testing` package API.

    Alternatives:

    *   add `type TestResult`, which together with
        `BenchmarkResult` would have duplicated fields, such as `Name`,
        `Status`, `Procs`, `T`, `Log`.
        We cannot add `type CommonResult` with common fields and embed it in
        `TestResult` and `BenchmarkResult` because it would break backwards
        compatibility of `BenchmarkResult`.
    *   Duplicate fields in `TestResult` but make `TestResult` and any other
        JSON-output-related types internal.
        The problem is that third party tool authors would have to write structs
        for JSON parsing themselves.

*   I propose to make `-json` mutually exclusive with `-n` and `-x` flags.
    This is a trade off for `go test` output format simplicity.
    Supporting `-json` with `-n`/`-x` flags would require a new field in
    `TestResult` that would contain commands that have been run. Note that
    we cannot print commands to stdout because stdout must be valid JSON.

    Supporting `-json` with `-n`/`-x` flags would also raise the question
    whether the field must be specific to commands or it should contain anything
    `build.go` prints to stdout.
    At this time `-n` and `-x` are the only flags that cause `build.go`
    to print to stdout, so we can avoid the problem for now.

    If we add more output to `build.go` in future, we can add
    `BuildOutput string` field to `TestResult` in `cmd/go/test.go` for arbitrary
    `build.go` output.

    I propose not to add `BuildOutput` now because `-n` affects `go test` too.
    For example, `go test -n` prints a command to run the test binary, which
    should not be a part of `BuildOutput` (because it is not build).
*   `go test` always streams and does not aggregate results into one JSON
    object.
    This is a trade off for `go test -json` output format simplicity.

## Compatibility

The only backwards incompatibility is changing `testing.Cover.CoveredPackages`
field type, but `testing.Cover` is not covered by Go 1 compatibility
guidelines.

## Implementation

Most of the work would be done by the author of this proposal.

Implementation steps:

1.  Add `type Status` and add new fields to `testing.BenchmarkResult`.
    Modify `testing.(*B).launch` to fill the new fields.
1.  Add `-test.json` flag, `type CoverageResult` and `type JSONResult` to the
    `testing` package.
    Modify `(*T).report`, `RunBenchmarks`, `coverReport` and `runExample`
    functions to print JSON if `-test.json` is specified.
    If `-test.verbose` is specified, print verbose messages to stderr.
1.  Add `-json` flag to `go test`.
    If specified, pass `-test.json` to test binaries.

    For each line in a test binary output, try to parse it as
    `testing.JSONResult`, and print a `TestResult`.

The goal is to get agreement on this proposal and to complete the work
before the 1.6 freeze date.

[testStreamOutput]: https://github.com/golang/go/blob/0b248cea169a261cd0c2db8c014269cca5a170c4/src/cmd/go/test.go#L361-L369
