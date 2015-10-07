# Proposal: `-json` flag in `go test`

Author(s): Nodir Turakulov &lt;nodir@google.com&gt;

_With initial input by Russ Cox, Caleb Spare, Andrew Gerrand and Minux Ma._

Last updated: 2015-10-06

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
When it is passed, `go test` stdout is valid indented JSON format.

Add `-stream` flag to `go test` to explicitly specify that multiple JSON
objects in stdout is OK.

## Background

There is a clear need in parsing test and benchmark results by third party
tools, see feedback in https://github.com/golang/go/issues/2981.
Currently `go test` output format is suited for humans, but not computers.
Also a change to the current format may break existing programs that parse
`go test` output.

Currently, under certain conditions, `go test` streams test/benchmark results
so a user can see them as they happen.
This proposal attempts to preserve streaming capability in the `-json` mode, so
third party tools interpreting `go test` output can stream results too.

`-json` flag was originally proposed by Russ Cox in
https://github.com/golang/go/issues/2981 in 2012.
This proposal differs from the original:

* supports streaming
* `go test` JSON output contains unrecognized test binary output.
* no changes to `testing.InternalTest` and `testing.InternalBenchmark`.

## Proposal

I propose the following user-visible changes:

*   `go test`: add `-json` and `-stream` flags.
    *   `-json`: all `go test` stdout is valid indented JSON containing all
        test binary artifacts. Format below.
    *   `-json -stream`: all `go test` stdout is a series of valid indented JSON
        objects, delimited by newline.
        They are printed on each test binary output.

        The format is the same as without `-stream`, but not all JSON object
        properties are present.
        If synthesized to one JSON object, the output is same as without
        streaming.
    *   `-json -v`: verbose messages are printed to stderr,
        so stdout contains only JSON.
    *   `-json -n`: not supported
    *   `-json -x`: not supported
    *   `-stream`: print all test binary output.
        If not specified, streaming is enabled under certain undocumented
        conditions as it works now
        (see [testStreamOutput variable in test.go][testStreamOutput]).
*   `testing` package
    *   Add `type TestResult` and `type TestState`.
    *   Add `func Test(f func(*T)) TestResult`
        to be consistent with `func Benchmark(f func(*B)) BenchmarkResult`.
        This is not required for JSON output.
    *   Add `Name`, `Output` and `Procs` fields to `BenchmarkResult`.
    *   Add `type Result` for JSON output.

Type definitions and details below.

### `testing` package

```go

// TestState is one of terminal test states.
// Implements fmt.Stringer, json.Marshaler and json.Unmarshaler.
type TestState int

const (
    PASS TestState = iota
    FAIL
    SKIP
)

// The results of a test run.
type TestResult struct {
    Name     string
    State    TestState
    T        time.Duration // The total time taken.
    Output   string        // The log created by calling (*T).Log and (*T).Logf.
}

// Test runs a test function and returns results.
func Test(f func(*T)) TestResult

type BenchmarkResult struct {
    Name   string
    Procs  int    // The value of runtime.GOMAXPROCS for this benchmark run.
    Output string // The log created by calling (*B).Log and (*B).Logf.

    // existing fields
}

// Result contains test/benchmark results and other test binary artifacts.
//
// Every time a test/benchmark completes, the test binary emits one Result
// in unindented JSON format to stdout, surrounded by '\n'.
type Result struct {
  Tests      []TestResult      `json:",omitempty"`
  Benchmarks []BenchmarkResult `json:",omitempty"`

  // Stdout is the test binary stdout that was not recognized by `go test`.
  // It is always empty when emitted by a test binary.
  Stdout string `json:",omitempty"`
  // Stderr is the test binary stderr caught by by `go test`.
  // It is always empty when emitted by a test binary.
  Stderr string `json:",omitempty"`
}
```

Example of a test binary stdout (JSON output is made indented for the
convenience of the reader. It will be unindented in fact):

```json
{
        "Tests": [
                {
                        "Name": "TestFoo",
                        "State": "PASS",
                        "T": 1000000
                }
        ]
}
Random string written directly to os.Stdout.
{
        "Tests": [
                {
                        "Name": "TestBar",
                        "State": "PASS",
                        "T": 1000000,
                        "Output": "some test output\n"
                }
        ]
}
{
        "Benchmarks": [
                {
                        "Name": "BenchmarkBar",
                        "State": "PASS",
                        "T": 1000000,
                        "N": 1000,
                        "Bytes": 0,
                        "MemAllocs": 0,
                        "MemBytes": 0
                }
        ]
}
```

### `go test`

`go test` JSON output format:

```go
// TestResult contains output of all test binaries.
type TestResult struct {
  About *struct {
    Version   string     `json: ",omitempty"`
    OS        string     `json: ",omitempty"`
    Arch      string     `json: ",omitempty"`
    Hostname  string     `json: ",omitempty"`
    StartTime *time.Time `json: ",omitempty"`
    EndTime   *time.Time `json: ",omitempty"`
  } `json: ",omitempty"`

  // Results is a mapping packageName -> results of the package test binary.
  //
  // Results[P].Stdout contains unrecognized stdout of the P test binary.
  // Results[P].Stderr contains all stderr of the P test binary.
  //
  // In non-streaming mode, it is the synthesized output of all test binaries.
  // Multiple testing.Result structs generated by the same test binary are
  // combined.
  Results map[string]testing.Result `json: ",omitempty"`
}
```

Example output: `go test -json`

```json
{
        "About": {
                "Version": "go1.5",
                "OS": "darwin",
                "Arch": "amd64",
                "Hostname": "nodir-macbookpro",
                "Start": "2015-10-06T15:33:03.925363433-07:00",
                "End": "2015-10-06T15:33:04.925363433-07:00"
        },
        "Results": {
                "example.com/foobar": {
                        "Tests": [
                                {
                                        "Name": "TestFoo",
                                        "Pass": true,
                                        "T": 1000000
                                },
                                {
                                        "Name": "TestBar",
                                        "Pass": true,
                                        "T": 1000000,
                                        "Output": "some test output\n"
                                }
                        ],
                        "Benchmarks": [
                                {
                                        "Name": "BenchmarkBar",
                                        "Procs": 8,
                                        "Pass": true,
                                        "T": 1000000,
                                        "N": 1000,
                                        "Bytes": 0,
                                        "MemAllocs": 0,
                                        "MemBytes": 0
                                }
                        ],
                        "Stdout": "Random string written directly to os.Stdout.\n"
                }
        }
}
```

Example output: `go test -json -stream`

```json
{
        "About": {
                "Version": "go1.5",
                "OS": "darwin",
                "Arch": "amd64",
                "Hostname": "nodir-macbookpro",
                "Start": "2015-10-06T15:33:03.925363433-07:00",
        }
}
{
        "Results": {
                "example.com/foobar": {
                        "Tests": [
                                {
                                        "Name": "TestFoo",
                                        "Pass": true,
                                        "T": 1000000
                                }
                        ]
                }
        }
}
{
        "Results": {
                "example.com/foobar": {
                        "Stdout": "Random string written directly to os.Stdout.\n"
                }
        }
}
{
        "Results": {
                "example.com/foobar": {
                        "Package": "example.com/foobar",
                        "Tests": [
                                {
                                        "Name": "TestBar",
                                        "Pass": true,
                                        "T": 1000000,
                                        "Output": "some test output\n"
                                }
                        ]
                }
        }
}
{
        "Results": {
                "example.com/foobar": {
                        "Package": "example.com/foobar",
                        "Benchmarks": [
                                {
                                        "Name": "BenchmarkBar",
                                        "Procs": 8,
                                        "T": 1000000,
                                        "N": 1000,
                                        "Bytes": 0,
                                        "MemAllocs": 0,
                                        "MemBytes": 0
                                }
                        ]
                }
        }
}
{
        "About": {
                "End": "2015-10-06T15:33:04.925363433-07:00"
        }
}
```

## Rationale

*   Assuming streaming is important, `-stream` flag has to be explicit because
    a third party tool may prefer `go test -json` to always return one JSON
    object, so the tool doesn't have to combine multiple objects itself.

    There was no need for explicit `-stream` flag before because it didn't
    matter for humans.
*   Test binary surrounds `testing.Result` JSON with `\n` to handle situation
    when a string without a trailing `\n` is printed directly to `os.Stdout`.
*   Test binary always streams results so we don't loose them if the binary
    panics.

Alternatives:

*   Add `-format` and `-benchformat` flags proposed in
    https://github.com/golang/go/issues/12826. This is simpler to implement
    by moving the burden of output parsing to third party programs.
*   Drop streaming support in `go test -json`, remove `-stream` flag.
    Always print one JSON object in `go test -json` stdout.

Trade offs:

*   I propose to make `-json` mutually exclusive with `-n` and `-x` flags.
    This is a trade off for `TestResult` type simplicity  in `cmd/go/test.go`.
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
*   With `Stdout` and `Stderr` fields separated in `testing.Result`, it is
    impossible to determine the order of the test binary output.
    This is a trade off for `testing.Result` simplicity.

    Combining `Stdout` and `Stderr` would make it impossible to distinguish
    stdout and stderr.

    If a third party tool needs to know the stdout/stderr order, it can leverage
    the `-exec` flag.


Disadvantages:

*   Adding seemingly unnecessary types to the public `testing` package, that are
    possibly useless for users.

## Compatibility

The API changes are fully backwards compatible.

## Implementation

Most of the work would be done by the author of this proposal.

Implementation steps:

1.  Add new fields to `testing.BenchmarkResult`.
    Modify `testing.(*B).launch` to fill the new fields.
1.  Add `type TestResult`, `type TestStatus` and
    `func Test(f func(*T)) TestResult` to package `testing`.
    Modify `testing.tRunner` to create `TestResult`.
1.  Add `-test.json` flag and `type Result` to package `testing`.
    Modify `testing.(*T).report` and `testing.RunBenchmarks` functions
    to print JSON if `-test.json` is specified.
    If `-test.verbose` was passed, print verbose messages to stderr.
1.  Add `-json` and `-stream` flags to `go test`.
    If `-json` is passed, pass `-test.json` to test binaries.

    For each line in a test binary output, try to parse it as `testing.Result`
    in JSON format.
    Accumulate one `testing.Result` per package.

    If `-stream` was specified, override `testStreamOutput` variable value.
    Print JSON output on each test binary output line.
    If not streaming, print one JSON with all artifacts on completion of all
    test binaries.

The goal is to get agreement on this proposal and to complete the work
before the 1.6 freeze date.

[testStreamOutput]: https://github.com/golang/go/blob/0b248cea169a261cd0c2db8c014269cca5a170c4/src/cmd/go/test.go#L361-L369