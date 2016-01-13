# Proposal: testing: programmatic sub-test and sub-benchmark support

Author: Marcel van Lohuizen

_With input from Sameer Ajmani, Austin Clements, Russ Cox, Bryan Mills, and Damien Neil._


Last updated: September 2, 2015

Discussion at https://golang.org/issue/12166.

## Abstract
This proposal introduces programmatic subtest and subbenchmarks for a variety
of purposes.

## Background

Adding a Run methods for spawning subtests and subbenchmarks addresses a variety
of features, including:

* an easy way to select single tests and benchmarks from a table from the
command line (e.g. for debugging),
* simplify writing a collection of similar benchmarks,
* use of Fail and friends in subtests,
* creating subtests from an external/dynamic table source,
* more control over scope of setup and teardown than TestMain provides,
* more control over parallelism,
* cleaner code, compared to many top-level functions, both for tests and
benchmarks, and
* eliminate need to prefix each error message in a test with its subtest's name.


## Proposal

The proposal for tests and benchmarks are discussed separately below. A separate
section explains logging and how to select subbenchmarks and subtests on the
command line.

### Subtests

T gets the following method:

```go
// Run runs f as a subtest of t called name. It reports whether f succeeded.
// Run will block until all its parallel subtests have completed.
func (t *T) Run(name string, f func(t *testing.T)) bool
```

Several methods get further clarification on their behavior for subfunctions.
Changes inbetween square brackets:


```go
// Fail marks the function [and its calling functions] as having failed but
// continues execution.
func (c *common) Fail()

// FailNow marks the function as having failed, stops its execution
// [and aborts pending parallel subtests].
// Execution will continue at the next test or benchmark.
// FailNow must be called from the goroutine running the
// test or benchmark function, not from other goroutines
// created during the test. Calling FailNow does not stop
// those other goroutines.
func (c *common) FailNow()

// SkipNow marks the test as having been skipped, stops its execution
// [and aborts pending parallel subtests].
// ... (analoguous to FailNow)
func (c *common) SkipNow()
```

A NumFailed method might be useful as well.

#### Examples

A simple example:

```go
tests := []struct {
     A, B int
     Sum  int
}{
    { 1, 2, 3 },
    { 1, 1, 2 },
    { 2, 1, 3 },
}
func TestSum(t *testing.T) {
    for _, tc := range tests {
        t.Run(fmt.Sprint(tc.A, "+", tc.B), func(t *testing.T) {
            if got := tc.A + tc.B; got != tc.Sum {
                t.Errorf("got %d; want %d", got, tc.Sum)
            }
        })
    }
}
```

Note that we write `t.Errorf("got %d; want %d")` instead of something like
`t.Errorf("%d+%d = %d; want %d")`: the subtest's name already uniquely
identifies the test.

Select (sub)tests from the command line using -test.run:

```go
go test --run=TestFoo/1+2  # selects the first test in TestFoo
go test --run=TestFoo/1+   # selects tests for which A == 1 in TestFoo
go test --run=.*/1+        # for any top-level test, select subtests matching ”1+”
```

Skipping a subtest will not terminate subsequent tests in the calling test:

```go
func TestFail(t *testing.T) {
    for i, tc := range tests {
        t.Run(fmt.Sprint(tc.A, "+", tc.B), func(t *testing.T) {
            if tc.A < 0 {
                t.Skip(i) // terminate test i, but proceed with test i+1.
            }
            if got := tc.A + tc.B; got != tc.Sum {
                t.Errorf("got %d; want %d", got, tc.Sum)
            }
        })
    }
}
```

A more concrete and realistic use case is an adaptation of bufio.TestReader:

```go
func TestReader(t *testing.T) {
    var texts [31]string
    str := ""
    all := ""
    for i := 0; i < len(texts)-1; i++ {
        texts[i] = str + "\n"
        all += texts[i]
        str += string(i%26 + 'a')
    }
    texts[len(texts)-1] = all

    for _, readmaker := range readMakers {
        t.Run("readmaker="+readMaker.name, func(t *testing.T) {
            for _, text := range texts {
                for _, bufreader := range bufreaders {
                    for _, bufsize := range bufsizes {
                        read := readmaker.fn(strings.NewReader(text))
                        buf := NewReaderSize(read, bufsize)
                        s := bufreader.fn(buf)
                        if s != text {
                            t.Fatalf("fn=%s bufsize=%d got=%q; want=%q",
                                bufreader.name, bufsize, got, text)
                        }
                    }
                }
            }
        })
    }
}
```

In this example the use of `t.Fatalf` avoids getting a large number of similar
errors for different buffer sizes.
In case of failure, testing will resume with testing the next reader.

Run a subtest in parallel:

```go
func TestParallel(t *testing.T) {
    for _, tc := range tests {
        tc := tc // Must capture the range variable.
        t.Run(tc.Name, func(t *testing.T) {
            t.Parallel()
            ...
        })
    }
}
```

Run teardown code after a few tests:

    func TestTeardown(t *testing.T) {
        t.Run("Test1", test1)
        t.Run("Test2", test2)
        t.Run("Test3", test3)
        // teardown code.
    }

Run teardown code after parallel tests:

```go
func TestTeardownParallel(t *testing.T) {
    // By definition, this Run will not return until the parallel tests finish.
    t.Run("block", func(t *testing.T) {
        t.Run("Test1", parallelTest1)
        t.Run("Test2", parallelTest2)
        t.Run("Test3", parallelTest3)
    })
    // teardown code.
}
```

Test1-Test3 will run in parallel with each other, but not with any other
parallel tests.
This follows from the fact that `Run` will block until _all_ subtests have
completed and that both TestTeardownParallel and "block" are sequential.

### Flags

The -test.run flag allows filtering of subtests given a prefix path where each
path component is a regular expression, applying the following rules:

* Each test has its own (sub) name.
* Each test has a level. A top-level test (e.g. `func TestFoo`) has level 1, a
test invoked with Run by such test has level 2, a test invoked by such a
subtest level 3, and so forth.
* A (sub)test is run if the (level-1)-th regular expression
resulting from splitting -test.run by '/' matches the test's name or if this
regular expression is not defined.
So for a -test.run not containing a '/' the behavior is identical to the current
behavior.
* Spaces (as defined by unicode.IsSpace) are replaced by underscores.

Rules for -test.bench are analogous, except that only a non-empty -test.bench
flag triggers running of benchmarks.
The implementation of these flags semantics can be done later.

####Examples:
Select top-level test “TestFoo” and all its subtests:

    go test --run=TestFoo

Select top-level tests that contain the string “Foo” and all their subtests that
contain the string “A:3”.

    go test --run=Foo/A:3

Select all subtests of level 2 which name contains the string “A:1 B:2” for any
top-level test:

    go test --run=.*/A:1_B:2

The latter could match, for example, struct{A, B int}{1, 2} printed with %+v.


### Subbenchmarks

The following method would be added to B:

    // Run benchmarks f as a subbenchmark with the given name. It reports
    // whether there were any failures.
    //
    // A subbenchmark is like any other benchmark. A benchmark that calls Run at
    // least once will not be measured itself and will only run for one iteration.
    func (b *B) Run(name string, f func(b *testing.B)) bool


The `Benchmark` function gets an additional clarification (addition between []):


    // Benchmark benchmarks a single function. Useful for creating
    // custom benchmarks that do not use the "go test" command.
    // [
    // If f calls Run, the result will be an estimate of running all its
    // subbenchmarks that don't call Run in sequence in a single benchmark.]
    func Benchmark(f func(b *B)) BenchmarkResult

See the Rational section for an explanation.

### Example
The following code shows the use of two levels of subbenchmarks.
It is based on a possible rewrite of
golang.org/x/text/unicode/norm/normalize_test.go.

```go
func BenchmarkMethod(b *testing.B) {
    for _, tt := range allMethods {
        b.Run(tt.name, func(b *testing.B) {
            for _, d := range textdata {
                fn := tt.f(NFC, []byte(d.data)) // initialize the test
                b.Run(d.name, func(b *testing.B) {
                    b.SetBytes(int64(len(d.data)))
                    for i := 0; i < b.N; i++ {
                        fn()
                    }
                })
            }
        })
    }
}

var allMethods = []struct {
    name string
    f    func(to Form, b []byte) func()
}{
    {"Transform", transform },
    {"Iter", iter },
    ...
}

func transform(f Form, b []byte) func()
func iter(f Form, b []byte) func()

var textdata = []struct { name, data string }{
    {"small_change", "No\u0308rmalization"},
    {"small_no_change", "nörmalization"},
    {"ascii", ascii},
    {"all", txt_all},
}
```

Note that there is some initialization code above the second Run.
Because it is outside of Run, there is no need to call ResetTimer.
As `Run` starts a new Benchmark, it is not possible to hoist the SetBytes call
in a similar manner.

The output for the above benchmark, without additional logging, could look something like:

    BenchmarkMethod/Transform/small_change-8      200000           668 ns/op      22.43 MB/s
    BenchmarkMethod/Transform/small_no_change-8  1000000           100 ns/op     139.13 MB/s
    BenchmarkMethod/Transform/ascii-8              10000         22430 ns/op     735.60 MB/s
    BenchmarkMethod/Transform/all-8                 1000        128511 ns/op      43.82 MB/s
    BenchmarkMethod/Iter/small_change-8           200000           701 ns/op      21.39 MB/s
    BenchmarkMethod/Iter/small_no_change-8        500000           321 ns/op      43.52 MB/s
    BenchmarkMethod/Iter/ascii-8                    1000        210633 ns/op      78.33 MB/s
    BenchmarkMethod/Iter/all-8                      1000        235950 ns/op      23.87 MB/s
    BenchmarkMethod/ToLower/small_change-8        300000           475 ns/op      31.57 MB/s
    BenchmarkMethod/ToLower/small_no_change-8     500000           239 ns/op      58.44 MB/s
    BenchmarkMethod/ToLower/ascii-8                  500        297486 ns/op      55.46 MB/s
    BenchmarkMethod/ToLower/all-8                   1000        151722 ns/op      37.12 MB/s
    BenchmarkMethod/QuickSpan/small_change-8     2000000            70.0 ns/op   214.20 MB/s
    BenchmarkMethod/QuickSpan/small_no_change-8  1000000           115 ns/op     120.94 MB/s
    BenchmarkMethod/QuickSpan/ascii-8               5000         25418 ns/op     649.13 MB/s
    BenchmarkMethod/QuickSpan/all-8                 1000        175954 ns/op      32.01 MB/s
    BenchmarkMethod/Append/small_change-8         200000           721 ns/op      20.78 MB/s
    ok      golang.org/x/text/unicode/norm  5.601s

The only change in the output is the characters allowable in the Benchmark name.
The output is identical in the absence of subbenchmarks.
This format is compatible with tools like benchstats.


### Logging

Logs for tests are printed hierarchically. Example:

    --- FAIL: TestFoo  (0.03s)
        display_test.go:75: setup issue
        --- FAIL: TestFoo/{Alpha:1_Beta:1}  (0.01s)
            display_test.go:75: Foo(Beta) = 5: want 6
        --- FAIL: TestFoo/{Alpha:1_Beta:3}  (0.01s)
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
        display_test.go:75: setup issue
        --- FAIL: TestFoo/{Alpha:1_Beta:4}  (0.01s)
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
        --- FAIL: TestFoo/{Alpha:1_Beta:8}  (0.01s)
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
            display_test.go:75: Foo(Beta) = 5; want 6
        --- FAIL: TestFoo/{Alpha:1_Beta:9}  (0.03s)
            display_test.go:75: Foo(Beta) = 5; want 6

For each header, we include the full name, repeating the name of the parent.
This makes it easier to identify the specific test from within the local context
and obviates the need for tools to keep track of context.


For benchmarks we adopt a different strategy. For benchmarks, it is important to
be able to relate the logs that might have influenced performance to the
respective benchmark.
This means we should ideally interleave the logs with the benchmark results.


```
--- BENCH: BenchmarkForm/from_NFC-8
        normalize_test.go:768: Some message
BenchmarkForm/from_NFC/canonical/to_NFC-8            10000       15914 ns/op     166.64 MB/s
--- BENCH: BenchmarkForm/from_NFC-8
        normalize_test.go:768: Some message
--- BENCH: BenchmarkForm/from_NFC/canonical-8
        normalize_test.go:776: Some message.
BenchmarkForm/from_NFC/canonical/to_NFD-8            10000       15914 ns/op     166.64 MB/s
--- BENCH: BenchmarkForm/from_NFC/canonical-8
        normalize_test.go:776: Some message.
--- BENCH: BenchmarkForm/from_NFC/canonical/to_NFD-8
        normalize_test.go:789: Some message.
        normalize_test.go:789: Some message.
        normalize_test.go:789: Some message.
BenchmarkForm/from_NFC/canonical/to_NFKC-8           10000       15170 ns/op     174.82 MB/s
--- BENCH: BenchmarkForm/from_NFC/canonical-8
        normalize_test.go:776: Some message.
BenchmarkForm/from_NFC/canonical/to_NFKD-8           10000       15881 ns/op     166.99 MB/s
--- BENCH: BenchmarkForm/from_NFC/canonical-8
        normalize_test.go:776: Some message.
BenchmarkForm/from_NFC/ext_latin/to_NFC-8             5000       30720 ns/op      52.86 MB/s
--- BENCH: BenchmarkForm/from_NFC-8
        normalize_test.go:768: Some message
BenchmarkForm/from_NFC/ext_latin/to_NFD-8             2000       71258 ns/op      22.79 MB/s
--- BENCH: BenchmarkForm/from_NFC/ext_latin/to_NFD-8
        normalize_test.go:789: Some message.
        normalize_test.go:789: Some message.
        normalize_test.go:789: Some message.
BenchmarkForm/from_NFC/ext_latin/to_NFKC-8            5000       32233 ns/op      50.38 MB/s
```

No bench results are printed for "parent" benchmarks.


## Rationale

### Alternative
One alternative to the given proposal is to define variants of tests as
top-level tests or benchmarks that call helper functions.
For example, the use case explained above could be written as:

```go
func doSum(t *testing.T, a, b, sum int) {
    if got := a + b; got != sum {
        t.Errorf("got %d; want %d", got, sum)
    }
}

func TestSumA1B2(t *testing.T) { doSum(t, 1, 2, 3) }
func TestSumA1B1(t *testing.T) { doSum(t, 1, 1, 2) }
func TestSumA2B1(t *testing.T) { doSum(t, 2, 1, 3) }
```

This approach can work well for smaller sets, but starts to get tedious for
larger sets.
Some disadvantages of this approach:

1. considerably more typing for larger test sets (less code, much larger test cases),
1. duplication of information in test name and test values,
1. may get unwieldy if a Cartesian product of multiple tables is used as source,
1. doesn't work well with dynamic table sources,
1. does not allow for the same flexibility of inserting setup and teardown code
   as using Run,
1. does not allow for the same flexibility in parallelism as using Run,
1. no ability to terminate early a subgroup of tests.

Some of these objections can be addressed by generating the test cases.
It seems, though, that addressing anything beyond point 1 and 2 with generation
would require more complexity than the addition of Run introduces.
Overall, it seems that the benefits of the proposed addition outweigh the
benefits of an approach using generation as well as expanding tests by hand.

### Subtest semantics
A _subtest_ refers to a call to Run and a _test function_ refers to the function
f passed to Run.
A subtest will be like any other test.
In fact, top-level tests are semantically equivalent to subtests of a single
main test function.

For all subtests holds:

1. a Fail of a subtest causes the Fail of all of its ancestor tests,
2. a FailNow of a test also causes its uncompleted descendants to be skipped,
but does not cause any of its ancestor tests to be skipped,
3. any subtest of a test must finish within the scope of this calling test,
4. any Parallel test function will run only after the enclosing test function
returns,
5. at most --test.parallel subtests will run concurrently at any time.

The combination of 3 and 4 means that all subtests marked as `Parallel` run
after the enclosing test function returns but before the Run method invoking
this test function returns.
This corresponds to the semantics of `Parallel` as it exists today.

These semantics enhance consistency: a call to `FailNow` will always terminate
the same set of subtests.

These semantics also guarantee that sequential tests are always run exclusively,
while only parallel tests can run together.
Also, parallel tests created by one sequentially running test will never run in
parallel with parallel tests created by another sequentially running test.
These simple rules allow for fairly extensive control over parallelism.


### Subbenchmark semantics

The `Benchmark` function defines the `BenchmarkResult` to be the result of
running all of its subbenchmarks in sequence.
This is equivalent to returning N == 1 and then the sum of all values for all
benchmarks, normalized to a single iteration.
It may be more appropriate to use a geometric mean, but as some of the values
may be zero the usage of such is somewhat problematic.
The proposed definition is meaningful and the user can still compute geometric
means by replacing calls to Run with calls to Benchmark if needed.
The main purpose of this definition is to define some semantics to using `Run`
in functions passed to `Benchmark`.


### Logging

The rules for logging subtests are:

* Each subtest maintains its own buffer to which it logs.
* The Main test uses os.Stdout as its “buffer”.
* When a subtest finishes, it flushes its buffer to the parent test’s buffer,
prefixed with a header to identify the subtest.
* Each subtest logs to the buffer with an indentation corresponding to its level.

These rule are consistent with the sub-test semantics presented earlier.
Combined with these semantics, logs have the following properties:

* Logs from a parallel subtests always come after the logs of its parent.
* Logs from a parallel subtests immediately follow the output of their parent.
* Messages logged by sequential tests will appear in chronological order in the
overall test logs.
* Each logged message is only displayed once.
* The output is identical to the old log format absent calls to t.Run.
* The output is identical except for non-Letter characters being allowed in
names if subtests are used.

Printing hierarchically makes the relation between tests visually clear.
It also avoids repeating printing some headers.

For benchmarks the priorities for logging are different.
It is important to visually correlate the logs with the benchmark lines.
It is also relatively rare to log a lot during benchmarking, so repeating some
headers is less of an issue.
The proposed logging scheme for benchmarks takes this into account.

As an alternative, we could use the same approach for benchmarks as for tests.
In that case, logs would only be printed after each top-level test.
For example:

```
BenchmarkForm/from_NFC/canonical/to_NFC-8       10000        23609 ns/op     112.33 MB/s
BenchmarkForm/from_NFC/canonical/to_NFD-8       10000        16597 ns/op     159.78 MB/s
BenchmarkForm/from_NFC/canonical/to_NFKC-8      10000        17188 ns/op     154.29 MB/s
BenchmarkForm/from_NFC/canonical/to_NFKD-8      10000        16082 ns/op     164.90 MB/s
BenchmarkForm/from_NFD/overflow/to_NFC-8          300       441589 ns/op      38.34 MB/s
BenchmarkForm/from_NFD/overflow/to_NFD-8          300       483748 ns/op      35.00 MB/s
BenchmarkForm/from_NFD/overflow/to_NFKC-8         300       467694 ns/op      36.20 MB/s
BenchmarkForm/from_NFD/overflow/to_NFKD-8         300       515475 ns/op      32.85 MB/s
--- FAIL: BenchmarkForm
    --- FAIL: BenchmarkForm/from_NFC
        normalize_test.go:768: Some failure.
        --- BENCH: BenchmarkForm/from_NFC/canonical
            normalize_test.go:776: Just a message.
            normalize_test.go:776: Just a message.
            --- BENCH: BenchmarkForm/from_NFC/canonical/to_NFD-8
                normalize_test.go:789: Some message
                normalize_test.go:789: Some message
                normalize_test.go:789: Some message
            normalize_test.go:776: Just a message.
            normalize_test.go:776: Just a message.
        normalize_test.go:768: Some failure.
        …
    --- FAIL: BenchmarkForm-8/from_NFD
        normalize_test.go:768: Some failure.
        …
        normalize_test.go:768: Some failure.
            --- BENCH: BenchmarkForm-8/from_NFD/overflow
            normalize_test.go:776: Just a message.
            normalize_test.go:776: Just a message.
            --- BENCH: BenchmarkForm-8/from_NFD/overflow/to_NFD
                normalize_test.go:789: Some message
                normalize_test.go:789: Some message
                normalize_test.go:789: Some message
            normalize_test.go:776: Just a message.
            normalize_test.go:776: Just a message.
BenchmarkMethod/Transform/small_change-8            100000        1165 ns/op      12.87 MB/s
BenchmarkMethod/Transform/small_no_change-8        1000000         103 ns/op     135.26 MB/s
…
```

It is still easy to see which logs influenced results (those marked `BENCH`), but
the user will have to align the logs with the result lines to correlate the data.


## Compatibility

The API changes are fully backwards compatible.
It introduces several minor changes in the logs:

* Names of tests and benchmarks may contain additional printable, non-space runes.
* Log items for tests may be indented.

benchstats and benchcmp may need to be adapted to take into account the
possibility of duplicate names.

## Implementation

Most of the work would be done by the author of this proposal.

The first step consists of some minor refactorings to make the diffs for
implementing T.Run and B.Run as small as possible.
Subsequently, T.Run and B.Run can be implemented individually.

Although the capability for parallel subtests will be implemented in the first
iteration, they will initially only be allowed for top-level tests.
Once we have a good way to detect improper usage of range variables, we could
open up parallelism by introducing Go or enable calling `Parallel` on subtests.

The aim is to have the first implementations of T.Run and B.Run in for 1.7.

<!-- ### Implementation details

The proposed concurrency model only requires a small extension to the existing model. Handling communication between tests and subtests is new and is done by means of sync.WaitGroups.

The “synchronization life-cycle” of a parallel test is as follows:

While the parent is still blocking on the subtest, a subtest’s call to Parallel will:
1. Add the test to the parent's list of subtests that should run in parallel. (**new**)
2. Add 1 to the parent’s waitgroup. (**new**)
3. Signal the parent the subtest is detaching and will be run in parallel.

While the parent running unblocked, the subtest will:
4. Wait for a channel that will be used to receive signal to run in parallel.  (**new**)
5. Wait for a signal on the channel received in Step 4.
6. Run test.
7. Post list of parallel subtests for this test for release to concurrency manager. (**new**) The concurrency manager will signal these tests they may run in parallel (see 4 and 5).
8. Signal completion to the manager goroutine spawned during the call to Parallel.

The manager goroutine, run concurrently with a test if Parallel is used:
9. Wait for completion of the test.
10. Signal the concurrency manager the test is done (decrease running count).
11. Wait for the test’s subtests to complete (through test’s WaitGroup). (**new**)
12. Flush report to parent. (Done by concurrency manager in current implementation.)
13. Signal parent completion (through parent’s WaitGroup).

Notes:
Unlike the old implementation, tests will only acquire a channel to receive a signal on to be run in parallel after the parent releases it to them (step 4.). This helps to retain the clarity in the code to see that subtests cannot be run earlier inadvertently.
Top-level subtest share the same code-base as subtests run with t.Run. Under the hood top-level test would be started with t.Run as well. -->


## Open issues

### Parallelism

Using Parallel in combination with closures is prone  to the “forgetting to
capture a range variable” problem.
We could define a Go method analogous to Run, defined as follows:

```go
func (t *T) Go(name string, f func(t *T)) {
    t.Run(name, func(t *T) {
        t.Parallel()
        f(t)
    }
}
```

This suffers from the same problem, but at least would make it a) more explicit
that a range variable requires capturing and b) makes it easier to detect misuse
by go vet.
If it is possible for go vet to detect whether t.Parallel is in the call graph
of t.Run and whether the closure refers to a range variable this would be
sufficient and the Go method might not be necessary.

At first we could prohibit calls to Parallel from within subtests until we
decide on one of these methods or find a better solution.

### Teardown

We showed how it is possible to insert teardown code after running a few
parallel tests.
Thought not difficult, it is a bit clumsy.
We could add the following method to make this easier:


```go
// Wait blocks until all parallel subtests have finished. It will Skip
// the current test if more than n subtests have failed. If n < 0 it will
// wait for all subtests to complete.
func (t *T) Wait(n numFailures)
```

The documentation in Run would have to be slightly changed to say that Run will
call Wait(-1) before returning.
The parallel teardown example could than be written as:

```go
func TestTeardownParallel(t *testing.T) {
    t.Go("Test1", parallelTest1)
    t.Go("Test2", parallelTest2)
    t.Go("Test3", parallelTest3)
    t.Wait(-1)
    // teardown code.
}
```

This could be added later if there seems to be a need for it.
The introduction of Wait would only require a minimal and backward compatible
change to the sub-test semantics.

