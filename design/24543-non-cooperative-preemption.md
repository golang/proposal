# Proposal: Non-cooperative goroutine preemption

Author(s): Austin Clements

Last updated: 2019-01-18

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
preemption, which would allow goroutines to be preempted at
essentially any point without the need for explicit preemption checks.
This approach will solve the problem of delayed preemption and do so
with zero run-time overhead.

Non-cooperative preemption is a general concept with a whole class of
implementation techniques.
This document describes and motivates the switch to non-cooperative
preemption and discusses common concerns of any non-cooperative
preemption approach in Go.
Specific implementation approaches are detailed in sub-proposals
linked from this document.


## Background

Up to and including Go 1.10, Go has used cooperative preemption with
safe-points only at function calls (and even then, not if the function
is small or gets inlined).
This means that Go can only switch between concurrently-executing
goroutines at specific points.
The main advantage of this is that the compiler can ensure useful
invariants at these safe-points.
In particular, the compiler ensures that all local garbage collection
roots are known at all safe-points, which is critical to precise
garbage collection.
It can also ensure that no registers are live at safe-points, which
means the Go runtime can switch goroutines without having to save and
restore a large register set.

However, this can result in infrequent safe-points, which leads to
many problems:

1. The most common in production code is that this can delay STW
   operations, such as starting and ending a GC cycle.
   This increases STW latency, and on large core counts can
   significantly impact throughput (if, for example, most threads are
   stopped while the runtime waits on a straggler for a long time).
   ([#17831](https://golang.org/issue/17831),
   [#19241](https://golang.org/issue/19241))

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
   ([#543](https://golang.org/issue/543),
   [#12553](https://golang.org/issue/12553),
   [#13546](https://golang.org/issue/13546),
   [#14561](https://golang.org/issue/14561),
   [#15442](https://golang.org/issue/15442),
   [#17174](https://golang.org/issue/17174),
   [#20793](https://golang.org/issue/20793),
   [#21053](https://golang.org/issue/21053))

These problems impede developer productivity and production efficiency
and expose Go's users to implementation details they shouldn't have to
worry about.

### Cooperative loop preemption

@dr2chase put significant effort into trying to solve these problems
using cooperative *loop preemption*
([#10958](https://golang.org/issue/10958)).
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
It requires more instructions (and more overhead) on non-x86 and
non-UNIX platforms.
Finally, it interferes with debuggers, which assume bad memory
references are a good reason to stop a program.
It's not clear it can work at all under many debuggers on OS X due to
a [kernel bug](https://bugs.llvm.org/show_bug.cgi?id=22868).


## Non-cooperative preemption

*Non-cooperative preemption* switches between concurrent execution
contexts without explicit preemption checks or assistance from those
contexts.
This is used by all modern desktop and server operating systems to
switch between threads.
Without this, a single poorly-behaved application could wedge the
entire system, much like how a single poorly-behaved goroutine can
currently wedge a Go application.
It is also a convenient abstraction: it lets us program as if there
are an infinite number of CPUs available, hiding the fact that the OS
is time-multiplexing a finite number of CPUs.

Operating system schedulers use hardware interrupt support to switch a
running thread into the OS scheduler, which can save that thread's
state such as its CPU registers so that it can be resumed later.
In Go, we would use operating system support to do the same thing.
On UNIX-like operating systems, this can be done using signals.

However, because of the garbage collector, Go has requirements that an
operating system does not: Go must be able to find the live pointers
on a goroutine's stack wherever it stops it.
Most of the complexity of non-cooperative preemption in Go derives
from this requirement.


## Proposal

I propose that Go implement non-cooperative goroutine preemption by
sending a POSIX signal (or using an equivalent OS mechanism) to stop a
running goroutine and capture its CPU state.
If a goroutine is interrupted at a point that must be GC atomic, as
detailed in the ["Handling unsafe-points"](#handling-unsafe-points)
section, the runtime can simply resume the goroutine and try again
later.

The key difficulty of implementing non-cooperative preemption for Go
is finding live pointers in the stack of a preempted goroutine.
There are many possible ways to do this, which are detailed in these
sub-proposals:

* The [safe-points everywhere
  proposal](24543/safe-points-everywhere.md) describes an
  implementation where the compiler records stack and register maps
  for nearly every instruction.
  This allows the runtime to halt a goroutine anywhere and find its GC
  roots.

* The [conservative inner-frame scanning
  proposal](24543/conservative-inner-frame.md) describes an
  implementation that uses conservative GC techniques to find pointers
  in the inner-most stack frame of a preempted goroutine.
  This can be done without any extra safe-point metadata.


## Handling unsafe-points

Any non-cooperative preemption approach in Go must deal with code
sequences that have to be atomic with respect to the garbage
collector.
We call these "unsafe-points", in contrast with GC safe-points.
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

As of Go 1.10, range loops are compiled roughly like:

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

This lowering requires that the compiler mark the increment and
condition blocks as unsafe-points.
However, if the body is short, this could result in infrequent
safe-points.
It also requires creating a separate block for the increment, which is
currently usually appended to the end of the body.
Separating these blocks would inhibit reordering opportunities.

In preparation for non-cooperative preemption, Go 1.11 began compiling
range loops as follows to avoid ever creating a past-the-end pointer:

```go
i, _n, _p := 0, len(s), &s[0]
if i >= _n { goto end } else { goto body }
top:
_p += unsafe.Sizeof(s[0])
body:
{ b }
i++
if i >= _n { goto end } else { goto top }
end:
```

This allows safe-points everywhere in the loop.
Compared to the original loop compilation, it generates slightly more
code, but executes the same number of conditional branch instructions
(n+1) and results in the same number of SSA basic blocks (3).

This lowering does complicate bounds-check elimination.
In Go 1.10, bounds-check elimination knew that `i < _n` in the body
because the body block is dominated by the cond block.
However, in the new lowering, deriving this fact required detecting
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

### Unsafe standard library code

The Windows syscall package contains many `unsafe.Pointer` conversions
that don't follow the `unsafe.Pointer` rules.
It broadly makes shaky assumptions about safe-point behavior,
liveness, and when stack movement can happen.
It would likely need a thorough auditing, or would need to be opted
out like the runtime.

Perhaps more troubling is that some of the Windows syscall package
types have uintptr fields that are actually pointers, hence forcing
callers to perform unsafe pointer conversions.
For example, see issue [#21376](https://golang.org/issue/21376).

### Ensuring progress with unsafe-points

We propose simply giving up and retrying later when a goroutine is
interrupted at an unsafe-point.
One danger of this is that safe points may be rare in tight loops.
However, in many cases, there are more sophisticated alternatives to
this approach.

For interruptions in the runtime or in functions without any safe
points (such as assembly), the signal handler could unwind the stack
and insert a return trampoline at the next return to a function with
safe point metadata.
The runtime could then let the goroutine continue running and the
trampoline would pause it as soon as possible.

For write barriers and `unsafe.Pointer` sequences, the compiler could
insert a cheap, explicit preemption check at the end of the sequence.
For example, the runtime could modify some register that would be
checked at the end of the sequence and let the thread continue
executing.
In the write barrier sequence, this could even be the register that
the write barrier flag was loaded into, and the compiler could insert
a simple register test and conditional branch at the end of the
sequence.
To even further shrink the sequence, the runtime could put the address
of the stop function in this register so the stop sequence would be
just a register call and a jump.

Alternatives to this check include forward and reverse simulation.
Forward simulation is tricky because the compiler must be careful to
only generate operations the runtime knows how to simulate.
Reverse simulation is easy *if* the compiler can always generate a
restartable sequence (simply move the PC back to the write barrier
flag check), but quickly becomes complicated if there are multiple
writes in the sequence or more complex writes such as DUFFCOPY.


## Other considerations

All of the proposed approaches to non-cooperative preemption involve
stopping a running goroutine by sending its thread an OS signal.
This section discusses general consequences of this.

**Windows support.** Unlike fault-based loop preemption, signaled
preemption is quite easy to support in Windows because it provides
`SuspendThread` and `GetThreadContext`, which make it trivial to get a
thread's register set.

**Choosing a signal.** We have to choose a signal that is unlikely to
interfere with existing uses of signals or with debuggers.
There are no perfect choices, but there are some heuristics.
1) It should be a signal that's passed-through by debuggers by
default.
On Linux, this is SIGALRM, SIGURG, SIGCHLD, SIGIO, SIGVTALRM, SIGPROF,
and SIGWINCH, plus some glibc-internal signals.
2) It shouldn't be used internally by libc in mixed Go/C binaries
because libc may assume it's the only thing that can handle these
signals.
For example SIGCANCEL or SIGSETXID.
3) It should be a signal that can happen spuriously without
consequences.
For example, SIGALRM is a bad choice because the signal handler can't
tell if it was caused by the real process alarm or not (arguably this
means the signal is broken, but I digress).
SIGUSR1 and SIGUSR2 are also bad because those are often used in
meaningful ways by applications.
4) We need to deal with platforms without real-time signals (like
macOS), so those are out.

We use SIGURG because it meets all of these criteria, is extremely
unlikely to be used by an application for its "real" meaning (both
because out-of-band data is basically unused and because SIGURG
doesn't report which socket has the condition, making it pretty
useless), and even if it is, the application has to be ready for
spurious SIGURG. SIGIO wouldn't be a bad choice either, but is more
likely to be used for real.

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


## Alternatives

### Single-stepping

Rather than making an effort to be able to stop at any instruction,
the compiler could emit metadata for safe-points only at back-edges
and the runtime could use hardware single-stepping support to advance
the thread to a safe-point (or a point where the compiler has provided
a branch to reach a safe-point, like in the current loop preemption
approach).
This works (somewhat surprisingly), but thoroughly bamboozles
debuggers since both the debugger and the operating system assume the
debugger owns single-stepping, not the process itself.
This would also require the compiler to provide register flushing
stubs for these safe-points, which increases code size (and hence
instruction cache pressure) as well as stack size, much like
cooperative loop preemption.
However, unlike cooperative loop preemption, this approach would have
no effect on mainline code size or performance.

### Jump rewriting

We can solve the problems of single-stepping by instead rewriting the
next safe-point jump instruction after the interruption point to jump
to a preemption path and resuming execution like usual.
To make this easy, the compiler could leave enough room (via padding
NOPs) so only the jump target needs to be modified.

This approach has the usual drawbacks of modifiable code.
It's a security risk, it breaks text page sharing, and simply isn't
allowed on iOS.
It also can't target an individual goroutine (since another goroutine
could be executing the same code) and may have odd interactions with
concurrent execution on other cores.

### Out-of-line execution

A further alternative in the same vein, but that doesn't require
modifying existing text is out-of-line execution.
In this approach, the signal handler relocates the instruction stream
from the interruption point to the next safe-point jump into a
temporary buffer, patches it to jump into the runtime at the end, and
resumes execution in this relocated sequence.

This solves most of the problems with single-stepping and jump
rewriting, but is quite complex to implement and requires substantial
implementation effort for each platform.
It also isn't allowed on iOS.

There is precedent for this sort of approach.
For example, when Linux uprobes injects an INT3, it relocates the
overwritten instructions into an "execute out-of-line" area to avoid
the usual problems with resuming from an INT3 instruction.
[The
implementation](https://github.com/torvalds/linux/blob/v4.18/arch/x86/kernel/uprobes.c)
is surprisingly simple given the complexity of the x86 instruction
encoding, but is still quite complex.
