# Proposal: Conservative inner-frame scanning for non-cooperative goroutine preemption

Author(s): Austin Clements

Last updated: 2019-01-21

Discussion at https://golang.org/issue/24543.

## Introduction

Up to and including Go 1.10, Go has used cooperative preemption with
safe-points only at function calls.
We propose that the Go implementation switch to *non-cooperative*
preemption.
The background and rationale for this proposal are detailed in the
[top-level proposal document](../24543-non-cooperative-preemption.md).

This document details a specific approach to non-cooperative
preemption that uses conservative GC techniques to find live pointers
in the inner-most frame of a preempted goroutine.


## Proposal

I propose that Go use POSIX signals (or equivalent) to interrupt
running goroutines and capture their CPU state.
If a goroutine is interrupted at a point that must be GC atomic, as
detailed in ["Handling
unsafe-points"](../24543-non-cooperative-preemption.md#handling-unsafe-points)
in the top-level proposal, the runtime can simply let the goroutine
resume and try again later.

This leaves the problem of how to find local GC roots—live pointers on
the stack—of a preempted goroutine.
Currently, the Go compiler records *stack maps* at every call site
that tell the Go runtime where live pointers are in the call's stack
frame.
Since Go currently only preempts at function calls, this is sufficient
to find all live pointers on the stack at any cooperative preemption
point.
But an interrupted goroutine is unlikely to have a liveness map at the
interrupted instruction.

I propose that when a goroutine is preempted non-cooperatively, the
garbage collector scan the inner-most stack frame and registers of
that goroutine *conservatively*, treating anything that could be a
valid heap pointer as a heap pointer, while using the existing
call-site stack maps to precisely scan all other frames.


## Rationale

Compared to the alternative proposal of [emitting liveness maps for
every instruction](safe-points-everywhere.md), this proposal is far
simpler to implement and much less likely to have a long bug tail.

It will also make binaries about 5% smaller.
The Go 1.11 compiler began emitting stack and register maps in support
of non-cooperative preemption as well as debugger call injection, but
this increased binary sizes by about 5%.
This proposal will allow us to roll that back.

This approach has the usual problems of conservative GC, but in a
severely limited scope.
In particular, it can cause heap allocations to remain live longer
than they should ("GC leaks").
However, unlike conservatively scanning the whole stack (or the whole
heap), it's unlikely that any incorrectly retained objects would last
more than one GC cycle because the inner frame typically changes
rapidly.
Hence, it's unlikely that an inner frame would remain the inner frame
across multiple cycles.

Furthermore, this can be combined with cooperative preemption to
further reduce the chances of retaining a dead object.
Neither stack scan preemption nor scheduler preemption have tight time
bounds, so the runtime can wait for a cooperative preemption before
falling back to non-cooperative preemption.
STW preemptions have a tight time bound, but don't scan the stack, and
hence can use non-cooperative preemption immediately.

### Stack shrinking

Currently, the garbage collector triggers stack shrinking during stack
scanning, but this will have to change if stack scanning may not have
precise liveness information.
With this proposal, stack shrinking must happen only at cooperative
preemption points.
One approach is to have stack scanning mark stacks that should be
shrunk, but defer the shrinking until the next cooperative preemption.

### Debugger call injection

Currently, debugger call injection support depends on the liveness
maps emitted at every instruction by Go 1.11.
This is necessary in case a GC or stack growth happens during an
injected call.
If we remove these, the runtime will need a different approach to call
injection.

One possibility is to leave the interrupted frame in a "conservative"
state, and to start a new stack allocation for the injected call.
This way, if the stack needs to be grown during the injected call,
only the stack below the call injection needs to be moved, and the
runtime will have precise liveness information for this region of the
stack.

Another possibility is for the injected call to start on a new
goroutine, though this complicates passing stack pointers from a
stopped frame, which is likely to be a common need.

### Scheduler preemptions

We will focus first on STW and stack scan preemptions, since these are
where cooperative preemption is more likely to cause issues in
production code.
However, it's worth considering how this mechanism can be used for
scheduler preemptions.

Preemptions for STWs and stack scans are temporary, and hence cause
little trouble if a pointer's lifetime is extended by conservative
scanning.
Scheduler preemptions, on the other hand, last longer and hence may
keep leaked pointers live for longer, though they are still bounded.
Hence, we may wish to bias scheduler preemptions toward cooperative
preemption.

Furthermore, since a goroutine that has been preempted
non-cooperatively must record its complete register set, it requires
more state than a cooperatively-preempted goroutine, which only needs
to record a few registers.
STWs and stack scans can cause at most GOMAXPROCS goroutines to be in
a preempted state simultaneously, while scheduler preemptions could in
principle preempt all runnable goroutines, and hence require
significantly more space for register sets.
The simplest way to implement this is to leave preempted goroutines in
the signal handler, but that would consume an OS thread for each
preempted goroutine, which is probably not acceptable for scheduler
preemptions.
Barring this, the runtime needs to explicitly save the relevant
register state.
It may be possible to store the register state on the stack of the
preempted goroutine itself, which would require no additional memory
or resources like OS threads.
If this is not possible, this is another reason to bias scheduler
preemptions toward cooperative preemption.


## Compatibility

This proposal introduces no new APIs, so it is Go 1 compatible.


## Implementation

Austin Clements plans to implement this proposal for Go 1.13. The
rough implementation steps are:

1. Make stack shrinking occur synchronously, decoupling it from stack
   scanning.

2. Implement conservative frame scanning support.

3. Implement general support for asynchronous injection of calls using
   non-cooperative preemption.

4. Use asynchronous injection to inject STW and stack scan operations.

5. Re-implement debug call injection to not depend on liveness maps.

6. Remove liveness maps except at call sites.

7. Implement non-cooperative scheduler preemption support.
