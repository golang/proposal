# Proposal: extend code coverage testing to include applications

Author(s): Than McIntosh

Last updated: 2022-03-02

Discussion at https://golang.org/issue/51430

## Abstract

This document contains a proposal for improving/revamping the system used in Go
for code coverage testing.

## Background

### Current support for coverage testing

The Go toolchain currently includes support for collecting and reporting
coverage data for Golang unit tests; this facility is made available via the "go
test -cover" and "go tool cover" commands.

The current workflow for collecting coverage data is baked into "go test"
command; the assumption is that the source code of interest is a Go package
or set of packages with associated tests.

To request coverage data for a package test run, a user can invoke the test(s)
via:

```
  go test -coverprofile=<filename> [package target(s)]
```

This command will build the specified packages with coverage instrumentation,
execute the package tests, and write an output file to "filename" with the
coverage results of the run.

The resulting output file can be viewed/examined using commands such as

```
  go tool cover -func=<covdatafile>
  go tool cover -html=<covdatafile>
```

Under the hood, the implementation works by source rewriting: when "go test" is
building the specified set of package tests, it runs each package source file
of interest through a source-to-source translation tool that produces an
instrumented/augmented equivalent, with instrumentation that records which
portions of the code execute as the test runs.

A function such as

```Go
  func ABC(x int) {
    if x < 0 {
      bar()
    }
  }
```

is rewritten to something like

```Go
  func ABC(x int) {GoCover_0_343662613637653164643337.Count[9] = 1;
    if x < 0 {GoCover_0_343662613637653164643337.Count[10] = 1;
      bar()
    }
  }
```

where "GoCover_0_343662613637653164643337" is a tool-generated structure with
execution counters and source position information.

The "go test" command also emits boilerplate code into the generated
"_testmain.go" to register each instrumented source file and unpack the coverage
data structures into something that can be easily accessed at runtime.
Finally, the modified "_testmain.go" has code to call runtime routines that
emit the coverage output file when the test completes.

### Strengths and weaknesses of what we currently provide

The current implementation is simple and easy to use, and provides a good user
experience for the use case of collecting coverage data for package unit tests.
Since "go test" is performing both the build and the invocation/execution of the
test, it can provide a nice seamless "single command" user experience.

A key weakness of the current implementation is that it does not scale well-- it
is difficult or impossible to gather coverage data for **applications** as opposed
to collections of packages, and for testing scenarios involving multiple
runs/executions.

For example, consider a medium-sized application such as the Go compiler ("gc").
While the various packages in the compiler source tree have unit tests, and one
can use "go test" to obtain coverage data for those tests, the unit tests by
themselves only exercise a small fraction of the code paths in the compiler that
one would get from actually running the compiler binary itself on a large
collection of Go source files.

For such applications, one would like to build a coverage-instrumented copy of
the entire application ("gc"), then run that instrumented application over many
inputs (say, all the Go source files compiled as part of a "make.bash" run for
multiple GOARCH values), producing a collection of coverage data output files,
and finally merge together the results to produce a report or provide a
visualization.

Many folks in the Golang community have run into this problem; there are large
numbers of blog posts and other pages describing the issue, and recommending
workarounds (or providing add-on tools that help); doing a web search for
"golang integration code coverage" will turn up many pages of links.

An additional weakness in the current Go toolchain offering relates to the way
in which coverage data is presented to the user from the "go tool cover")
commands.
The reports produced are "flat" and not hierarchical (e.g. a flat list of
functions, or a flat list of source files within the instrumented packages).
This way of structuring a report works well when the number of instrumented
packages is small, but becomes less attractive if there are hundreds or
thousands of source files being instrumented.
For larger applications, it would make sense to create reports with a more
hierarchical structure: first a summary by module, then package within module,
then source file within package, and so on.

Finally, there are a number of long-standing problems that arise due to the use of source-to-source rewriting used by cmd/cover and the go command, including

  [#23883](https://github.com/golang/go/issues/23883)
  "cmd/go: -coverpkg=all gives different coverage value when run on a
      package list vs ./..."

  [#23910](https://github.com/golang/go/issues/23910)
  "cmd/go: -coverpkg packages imported by all tests, even ones that
      otherwise do not use it"

  [#27336](https://github.com/golang/go/issues/27336)
  "cmd/go: test coverpkg panics when defining the same flag in
      multiple packages"

Most of these problems arise because of the introduction of additional imports in the `_testmain.go` shim created by the Go command when carrying out a coverage test run (in combination with the "-coverpkg" option).

## Proposed changes

### Building for coverage

While the existing "go test" based coverage workflow will continue to be supported, the proposal is to add coverage as a new build mode for "go build".
In the same way that users can build a race-detector instrumented executable using "go build -race", it will be possible to build a coverage-instrumented executable using "go build -cover".

To support this goal, the plan will be to migrate a portion of the support for coverage instrumentation into the compiler, while still retaining the existing source-to-source rewriting strategy (a so-called "hybrid" approach).

### Running instrumented applications

Applications are deployed and run in many different ways, ranging from very
simple (direct invocation of a single executable) to very complex (e.g. gangs of
cooperating processes involving multiple distinct executables).
To allow for more complex execution/invocation scenarios, it doesn't make sense
to try to serialize updates to a single coverage output data file during the
run, since this would require introducing synchronization or some other
mechanism to ensure mutually exclusive access.

For non-test applications built for coverage, users will instead select an
output directory as opposed to a single file; each run of the instrumented
executable will emit data files within that directory. Example:


```
$ go build -o myapp.exe -cover ...
$ mkdir /tmp/mycovdata
$ export GOCOVERDIR=/tmp/mycovdata
$ <run test suite, resulting in multiple invocations of myapp.exe>
$ go tool cover -html=/tmp/mycovdata
$
```

For coverage runs in the context of "go test", the default will continue to be
emitting a single named output file when the test is run.

File names within the output directory will be chosen at runtime so as to
minimize the possibility of collisions, e.g. possibly something to the effect of

```
  covdata.<metafilehash>.<processid>.<nanotimevalue>.out
```

When invoked for reporting, the coverage tool itself will test its input
argument to see whether it is a file or a directory; in the latter case, it will
read and process all of the files in the specified directory.

### Programs that call os.Exit(), or never terminate

With the current coverage tooling, if a Go unit test invokes `os.Exit()` passing a
non-zero exit status, the instrumented test binary will terminate immediately
without writing an output data file.
If a test invokes `os.Exit()` passing a zero exit status, this will result in a
panic.

For unit tests, this is perfectly acceptable-- people writing tests generally
have no incentive or need to call `os.Exit`, it simply would not add anything in
terms of test functionality.
Real applications routinely finish by calling `os.Exit`, however, including
cases where a non-zero exit status is reported.
Integration test suites nearly always include tests that ensure an application
fails properly (e.g. returns with non-zero exit status) if the application
encounters an invalid input.
The Go project's `all.bash` test suite has many of these sorts of tests,
including test cases that are expected to cause compiler or linker errors (and
to ensure that the proper error paths in the tool are covered).

To support collecting coverage data from such programs, the Go runtime will need
to be extended to detect `os.Exit` calls from instrumented programs and ensure (in
some form) that coverage data is written out before the program terminates.
This could be accomplished either by introducing new hooks into the `os.Exit`
code, or possibly by opening and mmap'ing the coverage output file earlier in
the run, then letting writes to counter variables go directly to an mmap'd
region, which would eliminated the need to close the file on exit (credit to
Austin for this idea).

To handle server programs (which in many cases run forever and may not call
exit), APIs will be provided for writing out a coverage profile under user
control. The first API variants will support writing coverage data to a specific
directory path:

```Go
  import "runtime/coverage"

  var *coverageoutdir flag.String(...)

  func server() {
    ...
    if *coverageoutdir != "" {
      // Meta-data is already available on program startup; write it now.
      // NB: we're assuming here that the specified dir already exists
      if err := coverage.EmitMetaDataToDir(*coverageoutdir); err != nil {
        log.Fatalf("writing coverage meta-data: %v")
      }
    }
    for {
      ...
      if *coverageoutdir != "" && <received signal to emit coverage data> {
        if err := coverage.EmitCounterDataToDir(*coverageoutdir); err != nil {
          log.Fatalf("writing coverage counter-data: %v")
        }
      }
    }
  }
```

The second API variants will support writing coverage meta-data and counter data to a user-specified io.Writer (where the io.Writer is presumably backed by a pipe or network connection of some sort):

```Go
  import "runtime/coverage"

  var *codecoverageflag flag.Bool(...)

  func server() {
    ...
    var w io.Writer
    if *codecoverageflag {
      // Meta-data is already available on program startup; write it now.
      w = <obtain destination io.Writer somehow>
      if err := coverage.EmitMetaDataToWriter(w); err != nil {
        log.Fatalf("writing coverage meta-data: %v")
      }
    }
    for {
      ...
      if *codecoverageflag && <received signal to emit coverage data> {
        if err := coverage.EmitCounterDataToWriter(w); err != nil {
          log.Fatalf("writing coverage counter-data: %v")
        }
      }
    }
  }
```

These APIs will return an error if invoked from within an application not built
with the "-cover" flag.

 
### Coverage and modules

Most modern Go programs make extensive use of dependent third-party packages;
with the advent of Go modules, we now have systems in place to explicitly
identify and track these dependencies.

When application writers add a third-party dependency, in most cases the authors
will not be interested in having that dependency's code count towards the
"percent of lines covered" metric for their application (there will definitely
be exceptions to this rule, but it should hold in most cases).

It makes sense to leverage information from the Go module system when collecting
code coverage data.
Within the context of the module system, a given package feeding into the build
of an application will have one of the three following dispositions (relative to
the main module):

* Contained: package is part of the module itself (not a dependency)
* Dependent: package is a direct or indirect dependency of the module (appearing in go.mod)
* Stdlib: package is part of the Go standard library / runtime

With this in mind, the proposal when building an application for coverage will
be to instrument every package that feeds into the build, but record the
disposition for each package (as above), then allow the user to select the
proper granularity or treatment of dependencies when viewing or reporting.

As an example, consider the [Delve](https://github.com/go-delve/delve) debugger
(a Go application). One entry in the Delve V1.8 go.mod file is:

        github.com/cosiner/argv v0.1.0

This package ("argv") has about 500 lines of Go code and a couple dozen Go
functions; Delve uses only a single exported function.
For a developer trying to generate a coverage report for Delve, it seems
unlikely that they would want to include "argv" as part of the coverage
statistics (percent lines/functions executed), given the secondary and very
modest role that the dependency plays.

On the other hand, it's possible to imagine scenarios in which a specific
dependency plays an integral or important role for a given application, meaning
that a developer might want to include the package in the applications coverage
statistics.

### Merging coverage data output files

As part of this work, the proposal is to provide "go tool" utilities for merging coverage data files, so that collection of coverage data files (emitted from multiple runs of an instrumented executable) can be merged into a single summary output file. 

More details are provided below in the section 'Coverage data file tooling'.

### Differential coverage

When fixing a bug in an application, it is common practice to add a new unit
test in addition to the code change that comprises the actual fix.
When using code coverage, users may want to learn how many of the changed lines
in their code are actually covered when the new test runs.

Assuming we have a set of N coverage data output files (corresponding to those
generated when running the existing set of tests for a package) and a new
coverage data file generated from a new testpoint, it would be useful to provide
a tool to "subtract" out the coverage information from the first set from the
second file.
This would leave just the set of new lines / regions that the new test causes to
be covered above and beyond what is already there.

This feature (profile subtraction) would make it much easier to write tooling
that would provide feedback to developers on whether newly written unit tests
are covering new code in the way that the developer intended.

## Design details

This section digs into more of the technical details of the changes needed in
the compiler, runtime, and other parts of the toolchain.

### Package selection when building instrumented applications

In the existing "go test" based coverage design, the default is to instrument only those packages that are specifically selected for testing. Example:

```
  $ go test -cover p1 p2/...
  ...
  $
```

In the invocation above, the Go tool reports coverage for package 'p1' and for all packages under 'p2', but not for any other packages (for example, any of the various packages imported by 'p1'). 

When building applications for coverage, the default will be to instrument all packages in the main module for the application being built.
Here is an example using the "delve" debugger (a Go application):

```
$ git clone -b v1.3.2 https://github.com/go-delve/delve
...
$ cd delve
$ go list ./...
github.com/go-delve/delve/cmd/dlv
github.com/go-delve/delve/cmd/dlv/cmds
...
github.com/go-delve/delve/service/rpccommon
github.com/go-delve/delve/service/test
$ fgrep spf13 go.mod
github.com/spf13/cobra v0.0.0-20170417170307-b6cb39589372
github.com/spf13/pflag v0.0.0-20170417173400-9e4c21054fa1 // indirect
$ go build -cover -o dlv.inst.exe ./cmd/dlv
$
```

When the resulting program (`dlv.inst.exe`) is run, it will capture coverage information for just the subset of dependent packages shown in the `go list` command above.
In particular, not coverage will be collected/reported for packages such as `github.com/spf13/cobra` or for packages in the Go standard library (ex: `fmt`).

Users can override this default by passing the `-coverpkg` option to `go build`.
Some additional examples:

```
  // Collects coverage for _only_ the github.com/spf13/cobra package
  $ go build -cover -coverpkg=github.com/spf13/cobra ./cmd/dlv
  // Collects coverage for all packages in the main module and 
  // all packages listed as dependencies in go.mod
  $ go build -cover -coverpkg=mod.deps ./cmd/dlv
  // Collects coverage for all packages (including the Go std library)
  $ go build -cover -coverpkg=all ./cmd/dlv
  $
```

### Coverage instrumentation: compiler or tool?

Performing code coverage instrumentation in the compiler (as opposed to prior to compilation via tooling) has some distinct advantages.

Compiler-based instrumentation is potentially much faster than the tool-based approach, for a start.
In addition, the compiler can apply special treatment to the coverage meta-data variables generated during instrumentation (marking it read-only), and/or provide special treatment for coverage counter variables (ensuring that they are aggregated).

Compiler-based instrumentation also has disadvantages, however. 
The "front end" (lexical analysis and parsing) portions of most compilers are typically designed to capture a minimum amount of source position information, just enough to support accurate error reporting, but no more.
For example, in this code:

```Go
L11:  func ABC(x int) {
L12:    if x < 0 {
L13:      bar()
L14:    }
L15:  }
```

Consider the `{` and '}' tokens on lines 12 and 14. While the compiler will accept these tokens, it will not necessarily create explicit representations for them (with detailed line/column source positions) in its IR, because once parsing is complete (and no syntax errors are reported), there isn't any need to keep this information around (it would just be a waste of memory). 

This is a problem for code coverage meta-data generation, since we'd like to record these sorts of source positions for reporting purposes later on (for example, during HTML generation).

This poses a problem: if we change the compiler to capture and hold onto more of this source position info, we risk slowing down compilation overall (even if coverage instrumentation is turned off).

### Hybrid instrumentation

To ensure that coverage instrumentation has all of the source position information it needs, and that we gain some of the benefits of using the compiler, the proposal is to use a hybrid approach: employ source-to-source rewriting for the actual counter annotation/insertion, but then pass information about the counter data structures to the compiler (via a config file) so that the compiler can also play a part.

The `cmd/cover` tool will be modified to operate at the package level and not at the level of an individual source file; the output from the instrumentation process will be a series of modified source files, plus summary file containing things like the the names of generated variables create during instrumentation. 
This generated file will be passed to the compiler when the instrumented package is compiled.

The new style of instrumentation will segregate coverage meta-data and coverage counters, so as to allow the compiler to place emta-data into the read-only data section of the instrumented binary.

This segregation will continue when the instrumented program writes out coverage data files at program termination: meta-data and counter data will be written to distinct output files. 

### New instrumentation strategy

Consider the following source fragment:

```Go
        package p

  L4:   func small(x, y int) int {
  L5:     v++
  L6:     // comment
  L7:     if y == 0 || x < 0 {
  L8:       return x
  L9:     }
  L10:    return (x << 1) ^ (9 / y)
  L11:  }
  L12:
  L13:  func medium() {
  L14:    s1 := small(q, r)
  L15:    z += s1
  L16:    s2 := small(r, q)
  L17:    w -= s2
  L18:  }
```

For each function, the coverage instrumentater will analyze the function to divide it into "coverable units", where each coverable unit corresponds roughly to a [basic block](https://en.wikipedia.org/wiki/Basic_block).

The instrumenter will create:

  1. a chunk of read-only meta-data that stores details on the coverable units
     for the function, and
  2. an array of counters, one for each coverable unit

Finally, the instrumenter will insert code into each coverable unit to increment or set the appropriate counter when the unit executes.

#### Function meta-data

The function meta-data entry for a unit will include the starting and ending
source position for the unit, along with the number of executable statements in
the unit.
For example, the portion of the meta-data for the function "small" above might
look like

```
  Unit   File   Start  End   Number of
  index         pos    pos   statements

  0      F0     L5     L7    2
  1      F0     L8     L8    1
```

where F0 corresponds to an index into a table of source files for the package.

At the package level, the compiler will emit code into the package "init"
function to record the blob of meta-data describing all the functions in the
package, adding it onto a global list.
More details on the package meta-data format can be found below.

#### Function counter array

The counter array for each function will be a distinct BSS (uninitialized data)
symbol. These anonymous symbols will be separate entities to ensure that if a
function is dead-coded by the linker, the corresponding counter array is also
removed. 
Counter arrays will be tagged by the compiler with an attribute to indentify
them to the Go linker, which will aggregate all counter symbols into a single
section in the output binary.

Although the counter symbol is managed by the compiler as an array, it can be
viewed as a struct of the following form:

```C
 struct {
     numCtrs uint32
     pkgId uint32
     funcId uint32
     counterArray [numUnits]uint32
 }
```

In the struct above, "numCtrs" stores the number of blocks / coverable units
within the function in question, "pkgId" is the ID of the containing package for
the function, "funcId" is the ID or index of the function within the package,
and finally "counterArray" stores the actual coverage counter values for the
function.

The compiler will emit code into the entry basic block of each function that
will store func-specific values for the number of counters (will always be
non-zero), the function ID, and the package ID.
When a coverage-instrumented binary terminates execution and we need to write
out coverage data, the runtime can make a sweep through the counter section for
the binary, and can easily skip over sub-sections corresponding to functions
that were never executed.

### Details on package meta-data symbol format

As mentioned previously, for each instrumented package, the compiler will emit a
blob of meta-data describing each function in the package, with info on the
specific lines in the function corresponding to "coverable" statements.

A package meta-data blob will be a single large RODATA symbol with the following
internal format.

```
  Header
  File/Func table
  ... list of function descriptors ...

```

Header information will include:

```
  - package path
  - number of files
  - number of functions
  - package classification/disposition relative to go.mod
```

where classification is an enum or set of flags holding the provenance of the
package relative to its enclosing module (described in the "Coverage and
Modules" section above).

The file/function table is basically a string table for the meta-data blob;
other parts of the meta data (header and function descriptors) will refer to
strings by index (order of appearance) in this table.

A function descriptor will take the following form:

```
  function name (index into string table)
  number of coverable units
  <list of entries for each unit>
```

Each entry for a coverable unit will take the form

```
  <file>  <start line>  <end line>  <number of statements>
```

As an example, consider the following Go package:

```Go
    01: package p
    02:
    03: var v, w, z int
    04:
    05: func small(x, y int) int {
    06: 	v++
    07: 	// comment
    08: 	if y == 0 {
    09: 		return x
    10: 	}
    11: 	return (x << 1) ^ (9 / y)
    12: }
    13:
    14: func Medium(q, r int) int {
    15: 	s1 := small(q, r)
    16: 	z += s1
    17: 	s2 := small(r, q)
    18: 	w -= s2
    19: 	return w + z
    20: }
```

The meta-data for this package would look something like

```
  --header----------
  | size: size of this blob in bytes
  | packagepath: <path to p>
  | module: <modulename>
  | classification: ...
  | nfiles: 1
  | nfunctions: 2
  --file + function table------
  | <uleb128 len> 4
  | <uleb128 len> 5
  | <uleb128 len> 6
  | <data> "p.go"
  | <data> "small"
  | <data> "Medium"
  --func 1------
  | uint32 num units: 3
  | uint32 func name: 1 (index into string table)
  | <unit 0>:  F0   L6     L8    2
  | <unit 1>:  F0   L9     L9    1
  | <unit 2>:  F0   L11    L11   1
  --func 2------
  | uint32 num units: 1
  | uint32 func name: 2 (index into string table)
  | <unit 0>:  F0   L15    L19   5
  ---end-----------
```


### Details on runtime support

#### Instrumented program execution

When an instrumented executable runs, during package initialization each package
will register a pointer to its meta-data blob onto a global list, so that when
the program terminates we can write out the meta-data for all packages
(including those whose functions were never executed at runtime).

Within an instrumented function, the prolog for the function will have
instrumentation code to:

* record the number of counters, function ID, and package ID in the initial
  portion of the counter array
* update the counter for the prolog basic block (either set a bit, increment a
  counter, or atomically increment a counter)

#### Instrumented program termination

When an instrumented program terminates, or when some other event takes place
that requires emitting a coverage data output file, the runtime routines
responsible will open an output file in the appropriate directory (name chosen
to minimize the possibility of collisions) and emit an output data file.

### Coverage data file format

The existing Go cmd/cover uses a text-based output format when emitting coverage
data files.
For the example package "p" given in the “Details on compiler changes” section
above, the output data might look like this:

```
  mode: set
  cov-example/p/p.go:5.26,8.12 2 1
  cov-example/p/p.go:11.2,11.27 1 1
  cov-example/p/p.go:8.12,10.3 1 1
  cov-example/p/p.go:14.27,20.2 5 1
```

Each line is a package path, source position info (file/line/col) for a basic
block, and an execution count (or 1/0 boolean value indicating "hit" or "not
hit").

This format is simple and straightforward to digest for reporting tools, but is
also somewhat space-inefficient.

The proposal is to switch to a binary data file format, but provide tools for
easily converting a binary file to the existing legacy format.

Exact details of the new format are still TBD, but very roughly: it should be
possible to just have a file header with information on the
execution/invocation, then a series of package meta-data blobs (drawn directly
from the corresponding rodata symbols in the binary).

Counter data will be written to a separate file composed of a header followed by a series of counter blocks, one per function.
Each counter data file will store the hash of the meta-data file that it is assocated with. 

Counter file header information will include items such as:

* binary name
* module name
* hash of meta-data for program
* process ID
* nanotime at point where data is emitted

Since the meta-data portion of the coverage output will be invariant from run to run of a given instrumented executable, at the point where an instrumented program terminates, if it sees that a meta-data file with the proper hash and length already exists, then it can avoid the meta-data writing step and only emit a counter data file.


### Coverage data file tooling

A new tool, `covdata`, will be provided for manipulating coverage data files generated from runs of instrumented executables.
The covdata tool will support merging, dumping, conversion, substraction, intersection, and other operations. 

#### Merge

The covdata `merge` subcommands reads data files from a series of input directories and merges them together into a single output directory. 

Example usage:

```
  // Run an instrumented program twice.
  $ mkdir /tmp/dir1 /tmp/dir2
  $ GOCOVERDIR=/tmp/dir1 ./prog.exe <first set of inputs>
  $ GOCOVERDIR=/tmp/dir2 ./prog.exe <second set of inputs>
  $ ls /tmp/dir1
  covcounters.7927fd1274379ed93b11f6bf5324859a.592186.1651766123343357257
  covmeta.7927fd1274379ed93b11f6bf5324859a
  $ ls /tmp/dir2
  covcounters.7927fd1274379ed93b11f6bf5324859a.592295.1651766170608372775
  covmeta.7927fd1274379ed93b11f6bf5324859a
  
  // Merge the both directories into a single output dir.
  $ mkdir final
  $ go tool covdata merge -i=/tmp/dir1,/tmp/dir1 -o final

```

#### Conversion to legacy text format

The `textfmt` subcommand reads coverage data files in the new format and emits a an equivalent file in the existing text format supported by `cmd/cover`. The resulting text files can then be used for reporting using the existing workflows.

Example usage (continuing from above):

```
  // Convert coverage data from directory 'final' into text format.
  $ go tool covdata textfmt -i=final -o=covdata.txt 
  $ head covdata.txt
  mode: set
  cov-example/p/p.go:7.22,8.2 0 0
  cov-example/p/p.go:10.31,11.2 1 0
  cov-example/p/p.go:11.3,13.3 0 0
  cov-example/p/p.go:14.3,16.3 0 0
  cov-example/p/p.go:19.33,21.2 1 1
  cov-example/p/p.go:23.22,25.2 1 0
  ...
  $ go tool cover -func=covdata.txt | head
  cov-example/main/main.go:12:	main			90.0%
  cov-example/p/p.go:7:		emptyFn			0.0%
  ...
  $
```

## Possible Extensions, Future Work, Limitations

### Tagging coverage profiles to support test "origin" queries

For very large applications, it is unlikely that any individual developer has a
complete picture of every line of code in the application, or understands the
exact set of tests that exercise a given region of source code.
When working with unfamiliar code, a common question for developers is, "Which
test or tests caused this line to be executed?".
Currently Go coverage tooling does not provide support for gathering or
reporting this type of information.

For this use case, one way to provide help to users would be to introduce the
idea of coverage data "labels" or "tags", analagous to the [profiling
labels](https://github.com/golang/proposal/blob/master/design/17280-profile-labels.md)
feature for CPU and memory profiling.

The idea would be to associate a set of tags with the execution of a given
execution of a coverage-instrumented binary.
Tags applied by default would include the values of GOOS + GOARCH, and in the
case of "go test" run, and the name of the specific Go test being executed.
The coverage runtime support would capture and record tags for each program or
test execution, and then the reporting tools would provide a way to build a
reverse index (effectively mapping each covered source file line to a set of
tags recorded for its execution).

This is (potentially) a complicated feature to implement given that there are
many different ways to write tests and to structure or organize them.
Go's all.bash is a good example; in addition to the more well-behaved tests like
the standard library package tests, there are also tests that shell out to run
other executables (ex: "go build ...") and tests that operate outside of the
formal "testing" package framework (for example, those executed by
$GOROOT/test/run.go).

In the specific case of Go unit tests (using the "testing" package), there is
also the problem that the package test is a single executable, thus would
produce a single output data file unless special arrangements were made.
One possibility here would be to arrange for a testing mode in which the testing
runtime would clear all of the coverage counters within the executable prior to
the invocation of a given testpoint, then emit a new data file after the
testpoint is complete (this would also require serializing the tests).

### Intra-line coverage

Some coverage tools provide details on control flow within a given source line,
as opposed to only at the line level.

For example, in the function from the previous section:

```Go
  L4:   func small(x, y int) int {
  L5:     v++
  L6:     // comment
  L7:     if y == 0 || *x < 0 {
  L8:       return x
  L9:     }
  L10:    return (x << 1) ^ (9 / y)
  L11:  }
```

For line 7 above, it can be helpful to report not just whether the line itself
was executed, but which portions of the conditional within the line.
If the condition “y == 0” is always true, and the "*x < 0" test is never
executed, this may be useful to the author/maintainer of the code.
Doing this would require logically splitting the line into two pieces, then
inserting counters for each piece. Each piece can then be reported separately;
in the HTML report output you might see something like:

```
  L7a:     if y == 0
  L7b:               || *x < 0 {
```

where each piece would be reported/colored separately.
Existing commercial C/C++ coverage tools (ex: Bullseye) provide this feature
under an option.

### Function-level coverage

For use cases that are especially sensitive to runtime overhead, there may be
value in supporting collection of function-level coverage data, as opposed to
line-level coverage data.
This reduction in granularity would decrease the size of the compiler-emitted
meta-data as well as the runtime overhead (since only a single counter or bit
would be required for a given function).

### Taking into account panic paths

When a Go program invokes panic(), this can result in basic blocks (coverable
units) that are only partially executed, meaning that the approach outlined in
the previous sections can report misleading data. For example:

```Go
L1:  func myFunc() int {
L2:    defer func()  { cleanup() }()
L3:    dosomework()
L4:    mayPanic()
L5:    morework()
L6:    if condition2 {
L7:      launchOperation()
L8:    }
L9:    return x
L10: }
```

In the current proposal, the compiler would insert two counters for this
function, one in the function entry and one in the block containing
“`launchOperation()`”.
If it turns out that the function `mayPanic()` always panics, then the reported
coverage data will show lines 5 and 6 above as covered, when in fact they never
execute.
This limitation also exists in the current source-to-source translation based
implementation of cmd/cover.

The limitation could be removed if the compiler were to treat each function call as
ending a coverable unit and beginning a new unit.
Doing this would result in a (probably very substantial) increase in the number
of counters and the size of the meta-data, but would eliminate the drawback in
question.

A number of existing coverage testing frameworks for other languages also have
similar limitations (for example, that of LLVM/clang), and it is an open
question as to how many users would actually make use this feature if it were
available. There is at least one open issue for this problem.

### Source file directives

It is worth noting that when recording position info, the compiler may need to
have special treatment for file/line directives.
For example, when compiling this package:

```Go
  foo.go:

  package foo
  //line apple.go:101:2
  func orange() {
  }
  //line peach.go:17:1
  func something() {
  }

```

If the line directives were to be honored when creating coverage reports
(particularly HTML output), it might be difficult for users to make sense of the
output.

# Implementation timetable

Plan is for thanm@ to implement this in go 1.19 timeframe.

# Prerequisite Changes

N/A

# Preliminary Results

No data available yet.

