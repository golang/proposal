# Proposal: Safe-points everywhere for non-cooperative goroutine preemption

Author(s): Austin Clements

Last updated: 2018-03-26 (extracted from general proposal 2019-01-17)

Discussion at https://golang.org/issue/24543.

## Introduction

Up to and including Go 1.10, Go has used cooperative preemption with
safe-points only at function calls.
We propose that the Go implementation switch to *non-cooperative*
preemption.
The background and rationale for this proposal are detailed in the
[top-level proposal document](../24543-non-cooperative-preemption.md).

This document details a specific approach to non-cooperative
preemption based on constructing stack and register maps at
(essentially) every instruction.


## Proposal

I propose that we implement fully non-cooperative preemption by
recording enough metadata to allow safe-points (almost) everywhere.

To do this, we would modify the compiler to produce register maps in
addition to stack maps, and to emit these for as many program counters
as possible.
The runtime would use a signal (or `GetThreadContext` on Windows, or a
note on Plan9) to retrieve each thread's register state, from which it
could get the stack and register map for the interrupted PC.
The garbage collector would then treat live pointers in registers just
as it treats live pointers on the stack.

Certain instructions cannot be safe-points, so if a signal occurs at
such a point, the runtime would simply resume the thread and try again
later.
The compiler just needs to make *most* instructions safe-points.

To @minux's credit, he suggested this in [the very first
reply](https://github.com/golang/go/issues/10958#issuecomment-105678822)
to [#10958](https://golang.org/issue/10958).
At the time we thought adding safe-points everywhere would be too
difficult and that the overhead of explicit loop preemption would be
lower than it turned out to be.

Many other garbage-collected languages use explicit safe-points on
back-edges, or they use forward-simulation to reach a safe-point.
Partly, it's possible for Go to support safe-points everywhere because
Go's GC already must have excellent support for interior pointers; in
many languages, interior pointers never appear at a safe-point.


## Encoding of stack and register maps

In the implementation for Go 1.11, register maps are encoded using the
exact same encoding as argument and locals maps.
Unlike argument and locals maps, which are indexed together in a
single PCDATA stream, the register maps are indexed by a separate
PCDATA stream because changes to the register map tend not to
correlate with changes to the arguments and locals maps.

Curiously, the significant majority of the space overhead from this
scheme is from the PCDATA stream that indexes into the register map.
The actual register map FUNCDATA is relatively small, suggesting that
functions have relatively few distinct register maps, but change
between them frequently.

### Alternates considered/attempted

Biasing the register allocator to allocate pointers and scalars from
different registers to reduce the number of unique maps and possibly
reduce the number of map changes would seem like an easy improvement.
However, it had very little effect.

Similarly, adding "slop" to the register maps by allowing the liveness
of a register to extend between its last use and next clobber slightly
reduced the number of register map changes, but only slightly.

The one successful alternate tried was to Huffman-code the delta
stream, which roughly halved the size of the metadata.
In this scheme, the register maps are encoded in a single bit stream
per function that alternates between PC delta (as a positive offset
from the previous PC), and register map delta (as an XOR from the
previous register map).
The two deltas are Huffman coded with separate Huffman tables, and the
Huffman tables are shared across the entire binary.
It may be even more effective to interleave the stack map changes into
the same stream, since this would allow the PC deltas to be shared.
This change was too invasive to implement for Go 1.11, but may be
worth attempting for Go 1.12.


## Other uses of stack/register maps

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

2. Debugger function calls ([#21678](https://golang.org/issue/21678)).
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

**Assembly.** By default, the runtime cannot safely preempt assembly
code since it won't know what registers contain pointers. As a
follow-on to the work on safe-points everywhere, we should audit
assembly in the standard library for non-preemptible loops and
annotate them with register maps. In most cases this should be trivial
since most assembly never constructs a pointer that isn't shadowed by
an argument, so it can simply claim there are no pointers in
registers. We should also document in the Go assembly guide how to do
this for user code.


## Compatibility

This proposal introduces no new APIs, so it is Go 1 compatible.


## Implementation

Austin Clements (@aclements) plans to implement register and stack
maps everywhere for Go 1.11.
This will enable some low-risk uses in the short term, such as
debugger function calls.

Debugging and testing of register and stack maps can continue into the
Go 1.11 freeze, including building the static analysis tool.

Then, for Go 1.12, Austin will implement safe-points everywhere atop
the register and stacks maps.


## References

[1] James M. Stichnoth, Guei-Yuan Lueh, and Michał Cierniak. 1999. Support for garbage collection at every instruction in a Java compiler. In *Proceedings of the ACM SIGPLAN 1999 conference on Programming language design and implementation* (PLDI '99). ACM, New York, NY, USA, 118–127.
