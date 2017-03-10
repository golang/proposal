# Proposal: Mid-stack inlining in the Go compiler

Author(s): David Lazar, Austin Clements

Last updated: 2017-03-10

Discussion at: https://golang.org/issue/19348

See also: https://golang.org/s/go19inliningtalk

# Abstract

As of Go 1.8, the compiler does not inline mid-stack functions (functions
that call other non-inlineable functions) by default.
This is because the runtime does not have sufficient information to generate
accurate tracebacks for inlined code.

We propose fixing this limitation of tracebacks and enabling mid-stack
inlining by default.
To do this, we will add a new PC-value table to functions with inlined
calls that the runtime can use to generate accurate tracebacks, generate
DWARF inlining information for debuggers, modify runtime.Callers and
related functions to operate in terms of “logical” stack frames, and
modify tools that work with stack traces such as pprof and trace.

Preliminary results show that mid-stack inlining can improve performance by 9%
(Go1 benchmarks on both amd64 and ppc64) with a 15% increase in binary size.
Follow-on work will focus on improving the inlining heuristics to hopefully
achieve this performance with less increase in binary size.


# Background

Inlining is a fundamental compiler optimization that replaces a function
call with the body of the called function.
This eliminates call overhead but more importantly enables other compiler
optimizations, such as constant folding, common subexpression elimination,
loop-invariant code motion, and better register allocation.
As of Go 1.8, inlining happens at the AST level.
To illustrate how the Go 1.8 compiler does inlining, consider the code in
the left column of the table below.
Using heuristics, the compiler decides that the call to PutUint32 in app.go
can be inlined. It replaces the call with a copy of the AST nodes that make
up the body of PutUint32, creating new AST nodes for the arguments.
The resulting code is shown in the right column.

<table>
<tr><th>Before inlining</th><th>After inlining</th></tr>
<tr><td>
<pre>
binary.go:20 func PutUint32(b []byte, v uint32) {
binary.go:21     b[0] = byte(v >> 24)
binary.go:22     b[1] = byte(v >> 16)
binary.go:23     b[2] = byte(v >> 8)
binary.go:24     b[3] = byte(v)
binary.go:25 }

app.go:5 func main() {
app.go:6     // ...
app.go:7     PutUint32(data, input)
app.go:8     // ...
app.go:9 }
</pre>
</td><td>
<pre>
app.go:5 func main() {
app.go:6     // ...
app.go:7     var b []byte, v uint32
app.go:7     b, v = data, input
app.go:7     b[0] = byte(v >> 24)
app.go:7     b[1] = byte(v >> 16)
app.go:7     b[2] = byte(v >> 8)
app.go:7     b[3] = byte(v)
app.go:8     // ...
app.go:9 }
</pre>
</td></tr>
</table>

Notice that the compiler replaces the source positions of the inlined AST
nodes with the source position of the call.
If the inlined code panics (due to an index out of range error), the
resulting stack trace is missing a stack frame for PutUint32 and the user
doesn't get an accurate line number for what caused the panic:
<pre>
panic: runtime error: index out of range

main.main()
	/home/gopher/app.go:7 +0x114
</pre>
Thus, even without aggressive inlining, the user might see inaccurate
tracebacks due to inlining.

To mitigate this problem somewhat, the Go 1.8 compiler does not inline
functions that contain calls.
This reduces the likelihood that the user will see an inaccurate traceback,
but it has a negative impact on performance.
Suppose in the example below that `intrinsicLog` is a large function that
won’t be inlined.
By default, the compiler will not inline the calls to `Log` or `LogBase`
since these functions make calls to non-inlineable functions.
However, we can force the compiler to inline these call to using the
compiler flag `-l=4`.

<table>
<tr><th>Before inlining</th><th>After inlining (-l=4)</th></tr>
<tr><td>
<pre>
math.go:41 func Log(x float64) float64 {
math.go:42     if x <= 0 {
math.go:43         panic("log x <= 0")
math.go:44     }
math.go:45     return intrinsicLog(x)
math.go:46 }

math.go:93 func LogBase(x float64, base float64) float64 {
math.go:94     n := Log(x)
math.go:95     d := Log(base)
math.go:96     return n / d
math.go:97 }

app.go:5 func main() {
app.go:6     // ...
app.go:7     val := LogBase(input1, input2)
app.go:8     // ...
app.go:9 }
</pre>
</td><td>
<pre>
app.go:5 func main() {
app.go:6     // ...
app.go:7     x, base := input1, input2
app.go:7     x1 := x
app.go:7     if x1 <= 0 {
app.go:7         panic("log x <= 0")
app.go:7     }
app.go:7     r1 := intrinsicLog(x1)
app.go:7     x2 := base
app.go:7     if x2 <= 0 {
app.go:7         panic("log x <= 0")
app.go:7     }
app.go:7     r2 := intrinsicLog(x2)
app.go:7     n := r1
app.go:7     d := r2
app.go:7     r3 := n / d
app.go:7     val := r3
app.go:8     // ...
app.go:9 }
</pre>
</td></tr>
</table>

Below we have the corresponding stack traces for these two versions of code,
caused by a call to `Log(0)`.
With mid-stack inlining, there is no stack frame or line number information
available for `LogBase`, so the user is unable to determine which input was 0.
<table>
<tr><th>Stack trace before inlining</th><th>Stack trace after inlining (-l=4)</th></tr>
<tr><td>
<pre>
panic(0x497140, 0xc42000e340)
	/usr/lib/go/src/runtime/panic.go:500 +0x1a1
main.Log(0x0, 0x400de6bf542e3d2d)
	/home/gopher/math.go:43 +0xa0
main.LogBase(0x4045000000000000, 0x0, 0x0)
	/home/gopher/math.go:95 +0x49
main.main()
	/home/gopher/app.go:7 +0x4c
</pre>
</td><td>
<pre>
panic(0x497140, 0xc42000e340)
	/usr/lib/go/src/runtime/panic.go:500 +0x1a1
main.main()
	/home/gopher/app.go:7 +0x161
</pre>
</td></tr>
</table>

The goal of this proposed change is to produce complete tracebacks in the
presence of inlining and to enable the compiler to inline non-leaf functions
like `Log` and `LogBase` without sacrificing debuggability.


# Proposal

## Changes to the compiler

Our approach is to modify the compiler to retain the original source
position information of inlined AST nodes and to store information about
the call site in a separate data structure.
Here is what the inlined example from above would look like instead:

<pre>
app.go:5   func main() {
app.go:6       // ...
app.go:7       x, base := input1, input2 ┓ LogBase
math.go:94     x1 := x                   ┃ app.go:7 ┓ Log
math.go:42     if x1 <= 0 {              ┃          ┃ math.go:94
math.go:43         panic("log x <= 0")   ┃          ┃
math.go:44     }                         ┃          ┃
math.go:45     r1 := intrinsicLog(x1)    ┃          ┛
math.go:95     x2 := base                ┃          ┓ Log
math.go:42     if x2 <= 0 {              ┃          ┃ math.go:95
math.go:43         panic("log x <= 0")   ┃          ┃
math.go:44     }                         ┃          ┃
math.go:45     r2 := intrinsicLog(x2)    ┃          ┛
math.go:94     n := r1                   ┃
math.go:95     d := r2                   ┃
math.go:96     r3 := n / d               ┛
app.go:7       val := r3
app.go:8       // ...
app.go:9   }
</pre>

Information about inlined calls is stored in a compiler-global data
structure called the *global inlining tree*.
Every time a call is inlined, the compiler adds a new node to the global
inlining tree that contains information about the call site (line number,
file name, and function name).
If the parent function of the inlined call is also inlined, the node for
the inner inlined call points to the node for the parent's inlined call.
For example, here is the inlining tree for the code above:

<pre>
┌──────────┐
│ LogBase  │
│ app.go:7 │
└──────────┘
   ↑    ↑   ┌────────────┐
   │    └───┤ Log        │
   │        │ math.go:94 │
   │        └────────────┘
   │        ┌────────────┐
   └────────┤ Log        │
            │ math.go:95 │
            └────────────┘
</pre>

The inlining tree is encoded as a table with one row per node in the tree.
The parent column is the row index of the node's parent in the table, or -1
if the node has no parent:

| Parent | File           | Line | Function Name     |
| ------ | -------------- | ---- | ----------------- |
| -1     | app.go         | 7    | LogBase           |
| 0      | math.go        | 94   | Log               |
| 0      | math.go        | 95   | Log               |

Every AST node is associated to a row index in the global inlining
tree/table (or -1 if the node is not the result of inlining).
We maintain this association by extending the `src.PosBase` type with a new
field called the *inlining index*.
Here is what our AST looks like now:

<pre>
app.go:5   func main() {
app.go:6       // ...
app.go:7       x, base := input1, input2 ┃ 0
math.go:94     x1 := x                   ┓
math.go:42     if x1 <= 0 {              ┃
math.go:43         panic("log x <= 0")   ┃ 1
math.go:44     }                         ┃
math.go:45     r1 := intrinsicLog(x1)    ┛
math.go:95     x2 := base                ┓
math.go:42     if x2 <= 0 {              ┃
math.go:43         panic("log x <= 0")   ┃ 2
math.go:44     }                         ┃
math.go:45     r2 := intrinsicLog(x2)    ┛
math.go:94     n := r1                   ┓
math.go:95     d := r2                   ┃ 0
math.go:96     r3 := n / d               ┛
app.go:7       val := r3
app.go:8       // ...
app.go:9   }
</pre>

As the AST nodes are lowered, their `src.PosBase` values are copied to
the resulting `Prog` pseudo-instructions.
The object writer reads the global inlining tree and the inlining index of
each `Prog` and writes this information compactly to object files.

## Changes to the object writer

The object writer creates two new tables per function.
The first table is the *local inlining tree* which contains all the
branches from the global inlining tree that are referenced by the Progs
in that function.
The second table is a PC-value table called the *pcinline table* that maps
each PC to a row index in the local inlining tree, or -1 if the PC does not
correspond to a function that has been inlined.

The local inlining tree and pcinline table are written to object files as
part of each function's pcln table.
The file names and function names in the local inlining tree are represented
using symbol references which are resolved to name offsets by the linker.

## Changes to the linker

The linker reads the new tables produced by the object writer and writes
the tables to the final binary.
We reserve `pcdata[1]` for the pcinline table and `funcdata[2]` for the
local inlining tree.
The linker writes the pcinline table to `pcdata[1]` unmodified.

The local inlining tree is encoded using 16 bytes per row (4 bytes per column).
The parent and line numbers are encoded directly as int32 values.
The file name and function names are encoded as int32 offsets into existing
global string tables.
This table must be written by the linker rather than the compiler because the
linker deduplicates these names and resolves them to global name offsets.

If necessary, we can encode the inlining tree more compactly using a varint
for each column value.
In the compact encoding, the parent column and the values in the pcinline
table would be byte offsets into the local inlining tree instead of row
indices.
In this case, the linker would have to regenerate the pcinline table.

## Changes to the runtime

The `runtime.gentraceback` function generates tracebacks and is modified
to produce logical stack frames for inlined functions.
The `gentraceback` function has two modes that are affected by inlining:
printing mode, used to print a stack trace when the runtime panics, and
pcbuf mode, which returns a buffer of PC values used by `runtime.Callers`.
In both modes, `gentraceback` checks if the current PC is mapped to a node
in the function's inlining tree by decoding the pcinline table for the
current function until it finds the value at the current PC.
If the value is -1, this instruction is not a result of inlining, so the
traceback proceeds normally.
Otherwise, `gentraceback` decodes the inlining tree and follows the path
up the tree to create the traceback.

Suppose that `pcPos` is the position information for the current PC
(obtained from the pcline and pcfile tables), `pcFunc` is the function
name for the current PC, and `st[0] -> st[1] -> ... -> st[k]` is the
path up the inlining tree for the current PC.
To print an accurate stack trace, `gentraceback` prints function names
and their corresponding position information in this order:

| Function name | Source position |
| ------------- | --------------- |
| st[0].Func    | pcPos           |
| st[1].Func    | st[0].Pos       |
|     ...       |       ...       |
| st[k].Func    | st[k-1].Pos     |
| pcFunc        | st[k].Pos       |

This process repeats for every PC in the traceback.
Note that the runtime only has sufficient information to print function
arguments and PC offsets for the last entry in this table.
Here is the resulting stack trace from the example above with our changes:

<pre>
main.Log(...)
	/home/gopher/math.go:43
main.LogBase(...)
	/home/gopher/math.go:95
main.main()
	/home/gopher/app.go:7 +0x1c8
</pre>

## Changes to the runtime public API

With inlining, a PC may represent multiple logical calls, so we need to
clarify the meaning of some runtime APIs related to tracebacks.
For example, the `skip` argument passed to `runtime.Caller` and
`runtime.Callers` will be interpreted as the number of logical calls to skip
(rather than the number of physical stack frames to skip).

Unfortunately, the runtime.Callers API requires some modification to be
compatible with mid-stack inlining.
The result value of runtime.Callers is a slice of program counters
([]uintptr) representing physical stack frames.
If the `skip` parameter to runtime.Callers skips part-way into a physical
frame, there is no convenient way to encode that in the resulting slice.
To avoid changing the API in an incompatible way, our solution is to store
the number of skipped logical calls of the first frame in the _second_
uintptr returned by runtime.Callers.
Since this number is a small integer, we encode it as a valid PC value
into a small symbol called `runtime.skipPleaseUseCallersFrames`.
For example, if f() calls g(), g() calls `runtime.Callers(2, pcs)`, and
g() is inlined into f, then the frame for f will be partially skipped,
resulting in the following slice:

    pcs = []uintptr{pc_in_f, runtime.skipPleaseUseCallersFrames+1, ...}

The `runtime.CallersFrames` function will check if the second PC is
in `runtime.skipPleaseUseCallersFrames` and skip the corresponding
number of logical calls.
We store the skip PC in `pcs[1]` instead of `pcs[0]` so that `pcs[i:]`
will truncate the captured stack trace rather than grow it for all i
(otherwise `pcs[1:]` would grow the stack trace).

Code that iterates over the PC slice from `runtime.Callers` calling
`FuncForPC` will have to be updated as described below to continue
observing complete stack traces.


# Rationale

Even with just leaf inlining, the new inlining tables increase the
size of binaries (see Preliminary Results).
However, this increase is unavoidable if the runtime is to print complete
stack traces.
Turning on mid-stack inlining increases binary size more significantly,
but we can tweak the inlining heuristic to find a good tradeoff between
binary size, performance, and build times.

We considered several alternative designs before we reached the design
described in this document.
One tempting alternative is to reuse the existing file and line PC-value
tables and simply add a new PC-value table for the “parent” PC of each
instruction, rather than a new funcdata table.
This appears to represent the same information as the proposed funcdata table.
However, some PCs might not have a parent PC to point at, for example
if an inlined call is the very first instructions in a function.
We considered adding NOP instructions to represent the parent of an inlined
call, but concluded that a separate inlining tree is more compact.

Another alternative design involves adding push and pop operations to the
PC-value table decoder for representing the inlined call stack.
We didn't prototype this design since the other designs seemed conceptually
simpler.


# Compatibility

Prior to Go 1.7, the recommended way to use `runtime.Callers` was to loop
over the returned PCs and call functions like `runtime.FuncForPC` on each
PC directly.
With mid-stack inlining, code using this pattern will observe incomplete
call stacks, since inlined frames will be omitted.
In preparation for this, the `runtime.Frames` API was introduced in Go 1.7
as a higher-level way to interpret the results of `runtime.Callers`.
We consider this to be a minor issue, since users will have had two releases
to update to `runtime.Frames` and any remaining direct uses of
`runtime.FuncForPC` will continue to work, simply in a degraded fashion.


# Implementation

David will implement this proposal during the Go 1.9 time frame.
As of the beginning of the Go 1.9 development cycle, a mostly complete
prototype of the changes the compiler, linker, and runtime is already
working.

The initial implementation goal is to make all tests pass with `-l=4`.
We will then focus on bringing tools and DWARF information up-to-date
with mid-stack inlining.
Once this support is complete, we plan to make `-l=4` the default setting.

We should also update the `debug/gosym` package to expose the new inlining
information.

*Update* (2017-03-04): CLs that add inlining info and fix stack traces
have been merged into master.
CLs that fix runtime.Callers are under submission.


# Prerequisite Changes

Prior to this work, Go had the `-l=4` flag to turn on mid-stack inlining,
but this mode had issues beyond incomplete stack traces.

For example, before we could run experiments with `-l=4`, we had to fix
inlining of variadic functions ([CL 33671](golang.org/cl/33671)),
mark certain cgo functions as uninlineable ([CL 33722](golang.org/cl/33722)),
and include linknames in export data ([CL 33911](golang.org/cl/33911)).

Before we turn on mid-stack inlining, we will have to update uses
of runtime.Callers in the runtime to use runtime.CallersFrames.
We will also have to make tests independent of inlining
(e.g., [CL 37237](golang.org/cl/37237)).


# Preliminary Results

Mid-stack inlining (`-l=4`) gives a 9% geomean improvement on the Go1
benchmarks on amd64:

  https://perf.golang.org/search?q=upload:20170309.1

The same experiment on ppc64 also showed a 9-10% improvement.

The new inlining tables increase binary size by 4% without mid-stack inlining.
Mid-stack inlining increases the size of the Go1 benchmark binary by an
additional 11%.


# Open issues

One limitation of this approach is that the runtime is unable to print
the arguments to inlined calls in a stack trace.
This is because the runtime gets arguments by assuming a certain stack
layout, but there is no stack frame for inlined calls.

This proposal does not propose significant changes to the existing
inlining heuristics.
Since mid-stack inlining is now a possibility, we should revisit the
inlining heuristics in follow-on work.
