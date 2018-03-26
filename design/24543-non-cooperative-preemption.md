# Proposal: Non-cooperative goroutine preemption

Author(s): Austin Clements

Last updated: 2018-03-26

Discussion at https://golang.org/issue/24543.

## Abstract

Go currently uses compiler-inserted cooperative preemption points in
function prologues.
The majority of the time, this is good enough to allow Go developers
to ignore preemption and focus on writing clear parallel code, but it
has sharp edges that we've seen degrade the developer experience time
and time again.
When it goes wrong, it goes spectacularly wrong, leading to mysterious
system-wide latency issues and sometimes complete freezes.
And because this is a language implementation issue that exists
outside of Go's language semantics, these failures are surprising and
very difficult to debug.

@dr2chase has put significant effort into prototyping cooperative
preemption points in loops, which is one way to solve this problem.
However, even sophisticated approaches to this led to unacceptable
slow-downs in tight loops (where slow-downs are generally least
acceptable).

I propose that the Go implementation switch to non-cooperative
preemption using stack and register maps at (essentially) every
instruction.
This would allow goroutines to be preempted without explicit
preemption checks.
This approach will solve the problem of delayed preemption with zero
run-time overhead.


## Background

Up to and including Go 1.10, Go has used cooperative preemption with
safe-points only at function calls (and even then, not if the function
is small or gets inlined).
This can result in infrequent safe-points, which leads to many
problems:

1. The most common in production code is that this can delay STW
   operations, such as starting and ending a GC cycle.
   This increases STW latency, and on large core counts can
   significantly impact throughput (if, for example, most threads are
   stopped while the runtime waits on a straggler for a long time).
   (#17831, #19241)

2. This can delay scheduling, preventing competing goroutines from
   executing in a timely manner.

3. This can delay stack scanning, which consumes CPU while the runtime
   waits for a preemption point and can ultimately delay GC
   termination, resulting in an effective STW where the system runs
   out of heap and no goroutines can allocate.

4. In really extreme cases, it can cause a program to halt, such as
   when a goroutine spinning on an atomic load starves out the
   goroutine responsible for setting that atomic.
   This often indicates bad or buggy code, but is surprising
   nonetheless and has clearly wasted a lot of developer time on
   debugging.
   (#543, #12553, #13546, #14561, #15442, #17174, #20793, #21053)

These problems impede developer productivity and production efficiency
and expose Go's users to implementation details they shouldn't have to
worry about.

### Loop preemption

@dr2chase put significant effort into trying to solve these problems
using explicit *loop preemption* (#10958).
This is a standard approach for runtimes employing cooperative
preemption in which the compiler inserts preemption checks and
safe-points at back-edges in the flow graph.
This significantly improves the quality of preemption, since code
almost never executes without a back-edge for any non-trivial amount
of time.

Our most recent approach to loop preemption, which we call
*fault-based preemption*, adds a single instruction, no branches, and
no register pressure to loops on x86 and UNIX platforms ([CL
43050](https://golang.org/cl/43050)).
Despite this, the geomean slow-down on a [large suite of
benchmarks](https://perf.golang.org/search?q=upload%3A20171003.1+%7C+upload-part%3A20171003.1%2F3+vs+upload-part%3A20171003.1%2F1)
is 7.8%, with a handful of significantly worse outliers.
Even [compared to Go
1.9](https://perf.golang.org/search?q=upload%3A20171003.1+%7C+upload-part%3A20171003.1%2F0+vs+upload-part%3A20171003.1%2F1),
where the slow-down is only 1% thanks to other improvements, most
benchmarks see some slow-down and there are still significant
outliers.

Fault-based preemption also has several implementation downsides.
It can't target specific threads or goroutines, so it's a poor match
for stack scanning, ragged barriers, or regular scheduler preemption.
It's also "sticky", in that we can't resume any loops until we resume
*all* loops, so the safe-point can't simply resume if it occurs in an
unsafe state (such as when runtime locks are held).
And it requires more instructions (and more overhead) on non-x86 and
non-UNIX platforms.


## Proposal

I propose that we implement fully non-cooperative preemption by
recording enough metadata to allow safe-points (almost) everywhere
without explicit preemption checks in function bodies.

To do this, we would modify the compiler to produce register maps in
addition to stack maps, and to emit these for as many program counters
as possible.
The runtime would use a signal (or `GetThreadContext` on Windows, or a
note on Plan9) to retrieve each thread's register state, including the
stack and register map at the interrupted PC.
The garbage collector would then treat live pointers in registers just
as it treats live pointers on the stack.

Certain instructions cannot be safe-points, so if a signal occurs at
such a point, the runtime would simply resume the thread and try again
later.
The compiler just needs to make *most* instructions safe-points.

To @minux's credit, he suggested this in [the very first
reply](https://github.com/golang/go/issues/10958#issuecomment-105678822)
to #10958.
At the time we thought adding safe-points everywhere would be too
difficult and that the overhead of explicit loop preemption would be
lower than it turned out to be.

Many other garbage-collected languages use explicit safe-points on
back-edges, or they use forward-simulation to reach a safe-point.
Partly, it's possible for Go to support safe-points everywhere because
Go's GC already must have excellent support for interior pointers; in
many languages, interior pointers never appear at a safe-point.


## Handling unsafe-points

There are various points in generated code that must be GC-atomic and
thus cannot have safe-points in them.
A few known situations are:

1. Expressions involving `unsafe.Pointer` may temporarily represent
   the only pointer to an object as a `uintptr`.
   Hence, there must be no safe-points while a `uintptr` derived from
   an `unsafe.Pointer` is live.
   Likewise, we must recognize `reflect.Value.Pointer`,
   `reflect.Value.UnsafeAddr`, and `reflect.Value.InterfaceData` as
   `unsafe.Pointer`-to-`uintptr` conversions.
   Alternatively, if the compiler can reliably detect such `uintptr`s,
   it could mark this as pointers, but there's a danger that an
   intermediate value may not represent a legal pointer value.

2. In the write barrier there must not be a safe-point between the
   write-barrier-enabled check and a direct write.
   For example, suppose the goroutine is writing a pointer to B into
   object A.
   If the check happens, then GC starts and scans A, then the
   goroutine writes B into A and drops all references to B from its
   stack, the garbage collector could fail to mark B.

3. There are places where the compiler generates temporary pointers
   that can be past the end of allocations, such as in range loops
   over slices and arrays.
   These would either have to be avoided or safe-points would have to
   be disallowed while these are live.

All of these cases must already avoid significant reordering to avoid
being split across a call.
Internally, this is achieved via the "mem" pseudo-value, which must be
sequentially threaded through all SSA values that manipulate memory.
Mem is also threaded through values that must not be reordered, even
if they don't touch memory.
For example, conversion between `unsafe.Pointer` and `uintptr` is done
with a special "Convert" operation that takes a mem solely to
constrain reordering.

There are several possible solutions to these problem, some of which
can be combined:

1. We could mark basic blocks that shouldn't contain preemption
   points.
   For `unsafe.Pointer` conversions, we would opt-out the basic block
   containing the conversion.
   For code adhering to the `unsafe.Pointer` rules, this should be
   sufficient, but it may break code that is incorrect but happens to
   work today in ways that are very difficult to debug.
   For write barriers this is also sufficient.
   For loops, this is overly broad and would require splitting some
   basic blocks.

2. For `unsafe.Pointer` conversions, we could simply opt-out entire
   functions that convert from `unsafe.Pointer` to `uintptr`.
   This would be easy to implement, and would keep even broken unsafe
   code working as well as it does today, but may have broad impact,
   especially in the presence of inlining.

3. A simple combination of 1 and 2 would be to opt-out any basic block
   that is *reachable* from an `unsafe.Pointer` to `uintptr`
   conversion, up to a function call (which is a safe-point today).

4. For range loops, the compiler could compile them differently such
   that it never constructs an out-of-bounds pointer (see below).

5. A far more precise and general approach (thanks to @cherrymui)
   would be to create new SSA operations that "taint" and "untaint"
   memory.
   The taint operation would take a mem and return a new tainted mem.
   This taint would flow to any values that themselves took a tainted
   value.
   The untaint operation would take a value and a mem and return an
   untainted value and an untainted mem.
   During liveness analysis, safe-points would be disallowed wherever
   a tainted value was live.
   This is probably the most precise solution, and is likely to keep
   even incorrect uses of unsafe working, but requires a complex
   implementation.

More broadly, it's worth considering making the compiler check
`unsafe.Pointer`-using code and actively reject code that doesn't
follow the allowed patterns.
This could be implemented as a simple type system that distinguishes
pointer-ish `uintptr` from numeric `uintptr`.
But this is out of scope for this proposal.

### Range loops

Currently (as of 1.10), range loops are compiled roughly like:

```go
for i, x := range s { b }
  ⇓
for i, _n, _p := 0, len(s), &s[0]; i < _n; i, _p = i+1, _p + unsafe.Sizeof(s[0]) { b }
  ⇓
i, _n, _p := 0, len(s), &s[0]
goto cond
body:
{ b }
i, _p = i+1, _p + unsafe.Sizeof(s[0])
cond:
if i < _n { goto body } else { goto end }
end:
```

The problem with this lowering is that `_p` may temporarily point past
the end of the allocation the moment before the loop terminates.
Currently this is safe because there's never a safe-point while this
value of `_p` is live.

We could keep this lowering and mark the increment and condition
blocks as unsafe-points.
However, if the body is short, this could result in infrequent
safe-points.
It would also require creating a separate block for the increment,
which is currently usually appended to the end of the body.
Separating these blocks would inhibit reordering opportunities.

Alternatively, we could rewrite the loop to never create a
past-the-end pointer.
For example, we could lower it like:

```go
i, _n, _p := 0, len(s), &s[0]
if i < _n { goto end } else { goto body }
top:
_p += unsafe.Sizeof(s[0])
body:
{ b }
i++
if i < _n { goto end } else { goto top }
end:
```

This would allow safe-points everywhere in the loop.
Compared to the current loop compilation, it generates slightly more
code, but executes the same number of conditional branch instructions
(n+1) and results in the same number of SSA basic blocks (3).

This lowering does complicate bounds-check elimination.
Currently, bounds-check elimination knows that `i < _n` in the body
because the body block is dominated by the cond block.
However, in the new lowering, deriving this fact requires detecting
that `i < _n` on *both* paths into body and hence is true in body.

### Runtime safe-points

Beyond generated code, the runtime in general is not written to be
arbitrarily preemptible and there are many places that must not be
preempted.
Hence, we would likely disable safe-points by default in the runtime,
except at calls (where they occur now).

While this would have little downside for most of the runtime, there
are some parts of the runtime that could benefit substantially from
non-cooperative preemption, such as memory functions like `memmove`.
Non-cooperative preemption is an excellent way to make these
preemptible without slowing down the common case, since we would only
need to mark their register maps (which would often be empty for
functions like `memmove` since all pointers would already be protected
by arguments).

Over time we may opt-in more of the runtime.


## Encoding of stack and register maps

To be determined.

@austin's prototype simply added the register liveness map as a third
liveness map accompanying the existing argument and local liveness
maps.
The downside of this is that any change in any of these maps requires
writing out all of them, and the register liveness changes tend not to
correlate with argument and local liveness changes.


## Other uses

### Heap dump analysis

Having safe-points everywhere fixes problems with heap dump analysis
from core files, which currently has to use conservative heuristics to
identify live pointers in active call frames.

### Call injection

Having safe-points everywhere also allows some function calls to be
safely injected at runtime.
This is useful in at least two situations:

1. To handle synchronous signals, such as nil-pointer dereferences,
   the runtime injects a call to `runtime.sigpanic` at the location of
   the fault.
   However, since there isn't usually a call at this location, the
   stack map may be inaccurate, which leads to complicated
   interactions between defers, escape analysis, and traceback
   handling.
   Having safe-points everywhere could simplify this.

2. Debugger function calls (#21678).
   Currently it's essentially impossible for a debugger to dynamically
   invoke a Go function call because of poor interactions with stack
   scanning and the garbage collector.
   Having stack and register maps everywhere would make this
   significantly more viable, since a function call could be injected
   nearly anywhere without making the stack un-scannable.


## Testing

The primary danger of this approach is its potential for a long bug
tail, since the coverage of safe-points in regular testing will
decrease substantially.
In addition to standard testing, I propose checking the generated
liveness maps using static analysis of binaries.
This tool would look for pointer dereferences or stores with a write
barrier to indicate that a value is a pointer and would check the flow
of that value through all possible paths.
It would report anywhere a value transitioned from dead/scalar to live
pointer and anywhere a value was used both like a pointer and like a
scalar.

In effect, this tool would simulate the program to answer the question
"for every two points in time A < B, are there allocations reachable
from the liveness map at time B that were not reachable at time A and
were not allocated between A and B?"

Most likely this static analysis tool could be written atop the
existing [golang.org/x/arch](https://godoc.org/golang.org/x/arch)
packages.
These are the same packages used by, for example, `go tool objdump`,
and handle most heavy-lifting of decoding the binary itself.


## Other considerations

**Space overhead.** Traditionally, the main concern with having
safe-points everywhere is the overhead of saving the stack/register
maps.
A very preliminary implementation of register maps and safe-points
everywhere increased binary size by ~10%.
However, this left several obvious optimizations on the table.
Work by Stichmoth, et al. [1] further suggests that this overhead
can be significantly curtailed with simple compression techniques.

**Windows support.** Unlike fault-based loop preemption, signaled
preemption is quite easy to support in Windows because it provides
`SuspendThread` and `GetThreadContext`, which make it trivial to get a
thread's register set.

**Decoupling stack-move points from GC safe-points.** Because of the
details of the current implementation, these are (essentially) the
same.
By decoupling these and only allowing stack growth and shrinking at
function entry, stack copying would not need to adjust registers.
This keeps stack copying simpler.
It also enables better compiler optimizations and more safe-points
since the compiler need not mark a register as a live pointer if it
knows there's another live pointer to the object.
Likewise, registers that are known to be derived from pointer
arguments can be marked as scalar as long as those arguments are live.
Such optimizations are possible because of Go's non-moving collector.
This also prevents stack moving from observing (and crashing on)
transient small-valued pointers that the compiler constructs when it
knows an offset from a potentially-nil pointer will be small.

**Debuggers.** Debuggers would have to be taught to ignore the signal
used for stopping a thread.
However, if we can use a distinct signal for this (such as one of the
POSIX real-time signals), this should be easier than teaching
debuggers to distinguish the `SIGSEGV`s produced by 1.10's loop
preemption from genuine `SIGSEGV`s.
It's also not clear that our current fault-based approach can work at
all under many debuggers on OS X due to a [kernel
bug](https://bugs.llvm.org/show_bug.cgi?id=22868).

**Scheduler preemption.** This mechanism is well-suited to temporary
preemptions where the same goroutine will resume after the preemption
because we don't need to save the full register state and can rely on
the existing signal return path to restore the full register state.
This applies to all GC-related preemptions, but it's not as well
suited to permanent preemption performed by the scheduler.
However, we could still build on this mechanism.
For example, since most of the time goroutines self-preempt, we only
need to save the full signal state in the uncommon case, so the `g`
could contain a pointer to its full saved state that's only used after
a forced preemption.
Restoring the full signal state could be done by either writing the
architecture-dependent code to restore the full register set (a
beefed-up `runtime.gogo`), or by self-signaling, swapping in the
desired context, and letting the OS restore the full register set.

**Targeting and resuming.** In contrast with fault-based loop
preemption, signaled preemption can be targeted at a specific thread
and can immediately resume.
Thread-targeting is a little different from cooperative preemption,
which is goroutine-targeted.
However, in many cases this is actually better, since targeting
goroutines for preemption is racy and hence requires retry loops that
can add significantly to STW time.
Taking advantage of this for stack scanning will require some
restructuring of how we track GC roots, but the result should
eliminate the blocking retry loop we currently use.

**Non-pointer pointers.** This has the potential to expose incorrect
uses of `unsafe.Pointer` for transiently storing non-pointers.
Such uses are a clear violation of the `unsafe.Pointer` rules, but
they may happen (especially in, for example, cgo-using code).

**Assembly.** By default, the runtime cannot safely preempt assembly
code since it won't know what registers contain pointers. As a
follow-on to the work on safe-points everywhere, we should audit
assembly in the standard library for non-preemptible loops and
annotate them with register maps. In most cases this should be trivial
since most assembly never constructs a pointer that isn't shadowed by
an argument, so it can simply claim there are no pointers in
registers. We should also document in the Go assembly guide how to do
this for user code.


## Alternatives

Rather than significantly increasing the number of safe-points, we
could use a signal to stop a thread and then use hardware
single-stepping support to advance the thread to a safe-point (or a
point where the compiler has provided a branch to reach a safe-point,
like in the current loop preemption approach).
This works (somewhat surprisingly), but thoroughly bamboozles
debuggers since both the debugger and the operating system assume the
debugger owns single-stepping, not the process itself.
This would also require the compiler to provide register flushing
stubs for these safe-points, which increases code size (and hence
instruction cache pressure) as well as stack size.
Safe-points everywhere increase binary size, but not code size or
stack size.


## Compatibility

This proposal introduces no new APIs, so it is Go 1 compatible.


## Implementation

Austin Clements (@austin) plans to implement register and stack maps
everywhere for Go 1.11.
This will enable some low-risk uses in the short term, such as
debugger function calls.

Debugging and testing of register and stack maps can continue into the
Go 1.11 freeze, including building the static analysis tool.

Then, for Go 1.12, Austin will implement safe-points everywhere atop
the register and stacks maps.


## References

[1] James M. Stichnoth, Guei-Yuan Lueh, and Michał Cierniak. 1999. Support for garbage collection at every instruction in a Java compiler. In *Proceedings of the ACM SIGPLAN 1999 conference on Programming language design and implementation* (PLDI '99). ACM, New York, NY, USA, 118–127.

