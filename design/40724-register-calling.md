# Proposal: Register-based Go calling convention

Author: Austin Clements, with input from Cherry Zhang, Michael
Knyszek, Martin Möhrmann, Michael Pratt, David Chase, Keith Randall,
Dan Scales, and Ian Lance Taylor.

Last updated: 2020-08-10

Discussion at https://golang.org/issue/40724.

## Abstract

We propose switching the Go ABI from its current stack-based calling
convention to a register-based calling convention.
[Preliminary experiments
indicate](https://github.com/golang/go/issues/18597#issue-199914923)
this will achieve at least a 5–10% throughput improvement across a
range of applications.
This will remain backwards compatible with existing assembly code that
assumes Go’s current stack-based calling convention through Go’s
[multiple ABI
mechanism](https://golang.org/design/27539-internal-abi).

## Background

Since its initial release, Go has used a *stack-based calling
convention* based on the Plan 9 ABI, in which arguments and result
values are passed via memory on the stack.
This has significant simplicity benefits: the rules of the calling
convention are simple and build on existing struct layout rules; all
platforms can use essentially the same conventions, leading to shared,
portable compiler and runtime code; and call frames have an obvious
first-class representation, which simplifies the implementation of the
`go` and `defer` statements and reflection calls.
Furthermore, the current Go ABI has no *callee-save registers*,
meaning that no register contents live across a function call (any
live state in a function must be flushed to the stack before a call).
This simplifies stack tracing for garbage collection and stack growth
and stack unwinding during panic recovery.

Unfortunately, Go’s stack-based calling convention leaves a lot of
performance on the table.
While modern high-performance CPUs heavily optimize stack access,
accessing arguments in registers is still roughly [40%
faster](https://gist.github.com/aclements/ded22bb8451eead8249d22d3cd873566)
than accessing arguments on the stack.
Furthermore, a stack-based calling convention, especially one with no
callee-save registers, induces additional memory traffic, which has
secondary effects on overall performance.

Most language implementations on most platforms use a register-based
calling convention that passes function arguments and results via
registers rather than memory and designates some registers as
callee-save, allowing functions to keep state in registers across
calls.

## Proposal

We propose switching the Go ABI to a register-based calling
convention, starting with a minimum viable product (MVP) on amd64, and
then expanding to other architectures and improving on the MVP.

We further propose that this calling convention should be designed
specifically for Go, rather than using platform ABIs.
There are several reasons for this.

It’s incredibly tempting to use the platform calling convention, as it
seems that would allow for more efficient language interoperability.
Unfortunately, there are two major reasons it would do little good,
both related to the scalability of goroutines, a central feature of
the Go language.
One reason goroutines scale so well is that the Go runtime dynamically
resizes their stacks, but this imposes requirements on the ABI that
aren’t satisfied by non-Go functions, thus requiring the runtime to
transition out of the dynamic stack regime on a foreign call.
Another reason is that goroutines are scheduled by the Go runtime
rather than the OS kernel, but this means that transitions to and from
non-Go code must be communicated to the Go scheduler.
These two things mean that sharing a calling convention wouldn’t
significantly lower the cost of calling non-Go code.

The other tempting reason to use the platform calling convention would
be tooling interoperability, particularly with debuggers and profiling
tools.
However, these almost universally support DWARF or, for profilers,
frame pointer unwinding.
Go will continue to work with DWARF-based tools and we can make the Go
ABI compatible with platform frame pointer unwinding without otherwise
taking on the platform ABI.

Hence, there’s little upside to using the platform ABI.
And there are several reasons to favor using our own ABI:

- Most existing ABIs were based on the C language, which differs in
  important ways from Go.
  For example, most ELF ABIs (at least x64-64, ARM64, and RISC-V)
  would force Go slices to be passed on the stack rather than in
  registers because the slice header is three words.
  Similarly, because C functions rarely return more than one word,
  most platform ABIs reserve at most two registers for results.
  Since Go functions commonly return at least three words (a result
  and a two word error interface value), the platform ABI would force
  such functions to return values on the stack.
  Other things that influence the platform ABI include that array
  arguments in C are passed by reference rather than by value and
  small integer types in C are promoted to `int` rather than retaining
  their type.
  Hence, platform ABIs simply aren’t a good fit for the Go language.

- Platform ABIs typically define callee-save registers, which place
  substantial additional requirements on a garbage collector.
  There are alternatives to callee-save registers that share many of
  their benefits, while being much better suited to Go.

- While platform ABIs are generally similar at a high level, their
  details differ in myriad ways.
  By defining our own ABI, we can follow a common structure across all
  platforms and maintain much of the cross-platform simplicity and
  reliability of Go’s stack-based calling convention.

The new calling convention will remain backwards-compatible with
existing assembly code that’s based on the stack-based calling
convention via Go’s [multiple ABI
mechanism](https://golang.org/design/27539-internal-abi).

This same multiple ABI mechanism allows us to continue to evolve the
Go calling convention in future versions.
This lets us start with a simple, minimal calling convention and
continue to optimize it in the future.

The rest of this proposal outlines the work necessary to switch Go to
a register-based calling convention.
While it lays out the requirements for the ABI, it does not describe a
specific ABI.
Defining a specific ABI will be one of the first implementation steps,
and its definition should reside in a living document rather than a
proposal.

## Go’s current stack-based ABI

We give an overview of Go’s current ABI to give a sense of the
requirements of any Go ABI and because the register-based calling
convention builds on the same concepts.

In the stack-based Go ABI, when a function F calls a function or
method G, F reserves space in its own stack frame for G’s receiver (if
it’s a method), arguments, and results.
These are laid out in memory as if G’s receiver, arguments, and
results were simply fields in a struct.

There is one exception to all call state being passed on the stack: if
G is a closure, F passes a pointer to its function object in a
*context register*, via which G can quickly access any closed-over
values.

Other than a few fixed-function registers, all registers are
caller-save, meaning F must spill any live state in registers to its
stack frame before calling G and reload the registers after the call.

The Go ABI also keeps a pointer to the runtime structure representing
the current goroutine (“G”) available for quick access.
On 386 and amd64, it is stored in thread-local storage; on all other
platforms, it is stored in a dedicated register.<sup>1</sup>

Every function must ensure sufficient stack space is available before
reserving its stack frame.
The current stack bound is stored in the runtime goroutine structure,
which is why the ABI keeps this readily accessible.
The standard prologue checks the stack pointer against this bound and
calls into the runtime to grow the stack if necessary.
In assembly code, this prologue is automatically generated by the
assembler itself.
Cooperative preemption is implemented by poisoning a goroutine’s stack
bound, and thus also makes use of this standard prologue.

Finally, both stack growth and the Go garbage collector must be able
to find all live pointers.
Logically, function entry and every call instruction has an associated
bitmap indicating which slots in the local frame and the function’s
argument frame contain live pointers.
Sometimes liveness information is path-sensitive, in which case a
function will have additional [*stack
object*](https://golang.org/cl/134155) metadata.
In all cases, all pointers are in known locations on the stack.

<sup>1</sup> This is largely a historical accident.
The G pointer was originally stored in a register on 386/amd64.
This is ideal, since it’s accessed in nearly every function prologue.
It was moved to TLS in order to support cgo, since transitions from C
back to Go (including the runtime signal handler) needed a way to
access the current G.
However, when we added ARM support, it turned out accessing TLS in
every function prologue was far too expensive on ARM, so all later
ports used a hybrid approach where the G is stored in both a register
and TLS and transitions from C restore it from TLS.

## ABI design recommendations

Here we lay out various recommendations for the design of a
register-based Go ABI.
The rest of this document assumes we’ll be following these
recommendations.

1. Common structure across platforms.
   This dramatically simplifies porting work in the compiler and
   runtime.
   We propose that each architecture should define a sequence of
   integer and floating point registers (and in the future perhaps
   vector registers), plus size and alignment constraints, and that
   beyond this, the calling convention should be derived using a
   shared set of rules as much as possible.

1. Efficient access to the current goroutine pointer and the context
   register for closure calls.
   Ideally these will be in registers; however, we may use TLS on
   architectures with extremely limited registers (namely, 386).

1. Support for many-word return values.
   Go functions frequently return three or more words, so this must be
   supported efficiently.

1. Support for scanning and adjusting pointers in register arguments
   on stack growth.
   Since the function prologue checks the stack bound before reserving
   a stack frame, the runtime must be able to spill argument registers
   and identify those containing pointers.

1. First-class generic call frame representation.
   The `go` and `defer` statements as well as reflection calls need to
   manipulate call frames as first-class, in-memory objects.
   Reflect calls in particular are simplified by a common, generic
   representation with fairly generic bridge code (the compiler could
   generate bridge code for `go` and `defer`).

1. No callee-save registers.
   Callee-save registers complicate stack unwinding (and garbage
   collection if pointers are allowed in callee-save registers).
   Inter-function clobber sets have many of the benefits of
   callee-save registers, but are much simpler to implement in a
   garbage collected language and are well-suited to Go’s compilation
   model.
   For an MVP, we’re unlikely to implement any form of live registers
   across calls, but we’ll want to revisit this later.

1. Where possible, be compatible with platform frame-pointer unwinding
   rules.
   This helps Go interoperate with system-level profilers, and can
   potentially be used to optimize stack unwinding in Go itself.

There are also some notable non-requirements:

1. No compatibility with the platform ABI (other than frame pointers).
   This has more downsides and upsides, as described above.

1. No binary compatibility between Go versions.
   This is important for shared libraries in C, but Go already
   requires all shared libraries in a process to use the same Go
   toolchain version.
   This means we can continue to evolve and improve the ABI.

## Toolchain changes overview

This section outlines the changes that will be necessary to the Go
build toolchain and runtime.
The "Detailed design" section will go into greater depth on some of
these.

### Compiler

*Abstract argument registers*: The compiler’s register allocator will
need to allocate function arguments and results to the appropriate
registers.
However, it needs to represent argument and result registers in a
platform-independent way prior to architecture lowering and register
allocation.
We propose introducing generic SSA values to represent the argument
and result registers, as done in [David Chase’s
prototype](https://golang.org/cl/28832).
These would simply represent the *i*th argument/result register and
register allocation would assign them to the appropriate architecture
registers.
Having a common ABI structure across platforms means the
architecture-independent parts of the compiler would only need to know
how many argument/result registers the target architecture has.

*Late call lowering*: Call lowering and argument frame construction
currently happen during AST to SSA lowering, which happens well before
register allocation.
Hence, we propose moving call lowering much later in the compilation
process.
Late call lowering will have knock-on effects, as the current approach
hides a lot of the structure of calls from most optimization passes.

*ABI bridges*: For compatibility with existing assembly code, the
compiler must generate ABI bridges when calling between Go
(ABIInternal) and assembly (ABI0) code, as described in the [internal
ABI proposal](https://golang.org/design/27539-internal-abi).
These are small functions that translate between ABIs according to a
function’s type.
While the compiler currently differentiates between the two ABIs
internally, since they’re actually identical right now, it currently
only generates *ABI aliases* and has no mechanism for generating ABI
bridges.
As a post-MVP optimization, the compiler should inline these ABI
bridges where possible.

*Argument GC map*: The garbage collector needs to know which arguments
contain live pointers at function entry and at any calls (since these
are preemption points).
Currently this is represented as a bitmap over words in the function’s
argument frame.
With the register-based ABI, the compiler will need to emit a liveness
map for argument registers for the function entry point.
Since initially we won't have any live registers across calls, live
arguments will be spilled to the stack at a call, so the compiler does
*not* need to emit register maps at calls.
For functions that still require a stack argument frame (because their
arguments don’t all fit in registers), the compiler will also need to
emit argument frame liveness maps at the same points it does today.

*Traceback argument maps*: Go tracebacks currently display a simple
word-based hex dump of a function’s argument frame.
This is not particularly user-friendly nor high-fidelity, but it can
be incredibly valuable for debugging.
With a register-based ABI, there’s a wide range of possible designs
for retaining this functionality.
For an MVP, we propose trying to maintain a similar level of fidelity.
In the future, we may want more detailed maps, or may want to simply
switch to using DWARF location descriptions.

To that end, we propose that the compiler should emit two logical
maps: a *location map* from (PC, argument word index) to
register/`stack`/`dead` and a *home map* from argument word index to
stack home (if any).
Since a named variable’s stack spill home is fixed if it ever spills,
the location map can use a single distinguished value for `stack` that
tells the runtime to refer to the home map.
This approach works well for an ABI that passes argument values in
separate registers without packing small values.
The `dead` value is not necessarily the same as the garbage
collector’s notion of a dead slot: for the garbage collector, you want
slots to become dead as soon as possible, while for debug printing,
you want them to stay live as long as possible (until clobbered by
something else).

The exact encoding of these tables is to be determined.
Most likely, we’ll want to introduce pseudo-ops for representing
changes in the location map that the `cmd/internal/obj` package can
then encode into `FUNCDATA`.
The home map could be produced directly by the compiler as `FUNCDATA`.

*DWARF locations*: The compiler will need to generate DWARF location
lists for arguments and results.
It already has this ability for local variables, and we should reuse
that as much as possible.
We will need to ensure Delve and GDB are compatible with this.
Both already support location lists in general, so this is unlikely to
require much (if any) work in these debuggers.

Clobber sets will require further changes, which we discuss later.
We propose not implementing clobber sets (or any form of callee-save)
for the MVP.

### Linker

The linker requires relatively minor changes, all related to ABI
bridges.

*Eliminate ABI aliases*: Currently, the linker resolves ABI aliases
generated by the compiler by treating all references to a symbol
aliased under one ABI as references to the symbol another the other
ABI.
Once the compiler generates ABI bridges rather than aliases, we can
remove this mechanism, which is likely to simplify and speed up the
linker somewhat.

*ABI name mangling*: Since Go ABIs work by having multiple symbol
definitions under the same name, the linker will also need to
implement a name mangling scheme for non-Go symbol tables.

### Runtime

*First-class call frame representation*: The `go` and `defer`
statements and reflection calls must manipulate call frames as
first-class objects.
While the requirements of these three cases differ, we propose having
a common first-class call frame representation that can capture a
function’s register and stack arguments and record its register and
stack results, along with a small set of generic call bridges that
invoke a call using the generic call frame.

*Stack growth*: Almost every Go function checks for sufficient stack
space before opening its local stack frame.
If there is insufficient space, it calls into the `runtime.morestack`
function to grow the stack.
Currently, `morestack` saves only the calling PC, the stack pointer,
and the context register (if any) because these are the only registers
that can be live at function entry.
With register-based arguments, `morestack` will also have to save all
argument registers.
We propose that it simply spill all *possible* argument registers
rather than trying to be specific to the function; `morestack` is
relatively rare, so the cost is this is unlikely to be noticeable.
It’s likely possible to spill all argument registers to the stack
itself: every function that can grow the stack ensures that there’s
room not only for its local frame, but also for a reasonably large
“guard” space.
`morestack` can spill into this guard space.
The garbage collector can recognize `morestack`’s spill space and use
the argument map of its caller as the stack map of `morestack`.

*Runtime assembly*: While Go’s multiple ABI mechanism makes it
generally possible to transparently call between Go and assembly code
even if they’re using different ABIs, there are runtime assembly
functions that have deep knowledge of the Go ABI and will have to be
modified.
This includes any function that takes a closure (`mcall`,
`systemstack`), is called in a special context (`morestack`), or is
involved in reflection-like calls (`reflectcall`, `debugCallV1`).

*Cgo wrappers*: Generated cgo wrappers marked with
`//go:cgo_unsafe_args` currently access their argument structure by
casting a pointer to their first argument.
This violates the `unsafe.Pointer` rules and will no longer work with
this change.
We can either special case `//go:cgo_unsafe_args` functions to use
ABI0 or change the way these wrappers are generated.

*Stack unwinding for panic recovery*: When a panic is recovered, the
Go runtime must unwind the panicking stack and resume execution after
the deferred call of the recovering function.
For the MVP, we propose not retaining any live registers across calls,
in which case stack unwinding will not have to change.
This is not the case with callee-save registers or clobber sets.

*Traceback argument printing*: As mentioned in the compiler section,
the runtime currently prints a hex dump of function arguments in panic
tracebacks.
This will have to consume the new traceback argument metadata produced
by the compiler.

## Detailed design

This section dives deeper into some of the toolchain changes described
above.
We’ll expand this section over time.

### `go`, `defer` and reflection calls

Above we proposed using a first-class call frame representation for
`go` and `defer` statements and reflection calls with a small set of
call bridges.
These three cases have somewhat different requirements:

- The types of `go` and `defer` calls are known statically, while
  reflect calls are not.
  This means the compiler could statically generate bridges to
  unmarshall arguments for `go` and `defer` calls, but this isn’t an
  option for reflection calls.

- The return values of `go` and `defer` calls are always ignored,
  while reflection calls must capture results.
  This means a call bridge for a `go` or `defer` call can be a tail
  call, while reflection calls can require marshalling return values.

- Call frames for `go` and `defer` calls are long-lived, while
  reflection call frames are transient.
  This means the garbage collector must be able to scan `go` and
  `defer` call frames, while we could use non-preemptible regions for
  reflection calls.

- Finally, `go` call frames are stored directly on the stack, while
  `defer` and reflection call frames may be constructed in the heap.
  This means the garbage collector must be able to construct the
  appropriate stack map for `go` call frames, but `defer` and
  reflection call frames can use the heap bitmap.
  It also means `defer` and reflection calls that require stack
  arguments must copy that part of the call frame from the heap to the
  stack, though we don’t expect this to be the common case.

To satisfy these requirements, we propose the following generic
call-frame representation:

```
struct {
    pc           uintptr          // PC of target function
    nInt, nFloat uintptr          // # of int and float registers
    ints         [nInt]uintptr    // Int registers
    floats       [nFloat]uint64   // Float registers
    ctxt         uintptr          // Context register
    stack        [...]uintptr     // Stack arguments/result space
}
```

`go` calls can build this structure on the new goroutine stack and the
call bridge can pop the register part of this structure from the
stack, leaving just the `stack` part on the stack, and tail-call `pc`.
The garbage collector can recognize this call bridge and construct the
stack map by inspecting the `pc` in the call frame.

`defer` and reflection calls can build frames in the heap with the
appropriate heap bitmap.
The call bridge in these cases must open a new stack frame, copy
`stack` to the stack, load the register arguments, call `pc`, and then
copy the register results and the stack results back to the in-heap
frame (using write barriers where necessary).
It may be valuable to have optimized versions of this bridge for
tail-calls (always the case for `defer`) and register-only calls
(likely a common case).
In the register-only reflection call case, the bridge could take the
register arguments as arguments itself and return register results as
results; this would avoid any copying or write barriers.

## Compatibility

This proposal is Go 1-compatible.

While Go assembly is not technically covered by Go 1 compatibility,
this will maintain compatibility with the vast majority of assembly
code using Go’s [multiple ABI
mechanism](https://golang.org/design/27539-internal-abi).
This translates between Go’s existing stack-based calling convention
used by all existing assembly code and Go’s internal calling
convention.

There are a few known forms of unsafe code that this change will
break:

- Assembly code that invokes Go closures.
  The closure calling convention was never publicly documented, but
  there may be code that does this anyway.

- Code that performs `unsafe.Pointer` arithmetic on pointers to
  arguments in order to observe the contents of the stack.
  This is a violation of the [`unsafe.Pointer`
  rules](https://pkg.go.dev/unsafe#Pointer) today.

## Implementation

We aim to implement a minimum viable register-based Go ABI for amd64
in the 1.16 time frame.
As of this writing (nearing the opening of the 1.16 tree), Dan Scales
has made substantial progress on ABI bridges for a simple ABI change
and David Chase has made substantial progress on late call lowering.
Austin Clements will lead the work with David Chase and Than McIntosh
focusing on the compiler side, Cherry Zhang focusing on aspects that
bridge the compiler and runtime, and Michael Knyszek focusing on the
runtime.
