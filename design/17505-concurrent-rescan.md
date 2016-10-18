# Proposal: Concurrent stack re-scanning

Author(s): Austin Clements, Rick Hudson

Last updated: 2016-10-18

Discussion at https://golang.org/issue/17505.

**Note:** We are not actually proposing this.
This design was developed before proposal #17503, which is a
dramatically simpler solution to the problem of stack re-scanning.
We're posting this design doc for its historical value.


## Abstract

Since the release of the concurrent garbage collector in Go 1.5, each
subsequent release has further reduced stop-the-world (STW) time by
moving more tasks to the concurrent phase.
As of Go 1.7, the only non-trivial STW task is stack re-scanning.
We propose to make stack re-scanning concurrent for Go 1.8, likely
resulting in sub-millisecond worst-case STW times.


## Background

Go's concurrent garbage collector consists of four phases: mark, mark
termination, sweep, and sweep termination.
The mark and sweep phases are *concurrent*, meaning that the
application (the *mutator*) continues to run during these phases,
while the mark termination and sweep termination phases are
*stop-the-world* (STW), meaning that the garbage collector pauses the
mutator for the duration of the phase.

Since Go 1.5, we've been steadily moving tasks from the STW phases to
the concurrent phases, with a particular focus on tasks that take time
proportional to something under application control, such as heap size
or number of goroutines.
As a result, in Go 1.7, most applications have sub-millisecond STW
times.

As of Go 1.7, the only remaining application-controllable STW task is
*stack re-scanning*.
Because of this one task, applications with large numbers of active
goroutines can still experience STW times in excess of 10ms.

Stack re-scanning is necessary because stacks are *permagray* in the
Go garbage collector.
Specifically, for performance reasons, there are no write barriers for
writes to pointers in the current stack frame.
As a result, even though the garbage collector scans all stacks at the
beginning of the mark phase, it must re-scan all modified stacks with
the world is stopped to catch any pointers the mutator "hid" on the
stack.

Unfortunately, this makes STW time proportional to the total amount of
stack that needs to be rescanned.
Worse, stack scanning is relatively expensive (~5ms/MB).
Hence, applications with a large number of active goroutines can
quickly drive up STW time.


## Proposal

We propose to make stack re-scanning concurrent using a *transitive
mark* write barrier.

In this design, we add a new concurrent phase between mark and mark
termination called *stack re-scan*.
This phase starts as soon as the mark phase has marked all objects
reachable from roots *other than stacks*.
The phase re-scans stacks that have been modified since their initial
scan, and enables a special *transitive mark* write barrier.

Re-scanning and the write barrier ensure the following invariant
during this phase:

> *After a goroutine stack G has been re-scanned, all objects locally
> reachable to G are black.*

This depends on a goroutine-local notion of reachability, which is the
set of objects reachable from globals or a given goroutine's stack or
registers.
Unlike regular global reachability, this is not stable: as goroutines
modify heap pointers or communicate, an object that was locally
unreachable to a given goroutine may become locally reachable.
However, the concepts are closely related: a globally reachable object
must be locally reachable by at least one goroutine, and, conversely,
an object that is not locally reachable by any goroutine is not
globally reachable.

This invariant ensures that re-scanning a stack *blackens* that stack,
and that the stack remains black since the goroutine has no way to
find a white object once its stack has been re-scanned.

Furthermore, once every goroutine stack has been re-scanned, marking
is complete.
Every globally reachable object must be locally reachable by some
goroutine and, once every stack has been re-scanned, every object
locally reachable by some goroutine is black, so it follows that every
globally reachable object is black once every stack has been
re-scanned.

### Transitive mark write barrier

The transitive mark write barrier for an assignment `*dst = src`
(where `src` is a pointer) ensures that all objects reachable from
`src` are black *before* writing `src` to `*dst`.
Writing `src` to `*dst` may make any object reachable from `src`
(including `src` itself) locally reachable to some goroutine that has
been re-scanned.
Hence, to maintain the invariant, we must ensure these objects are all
black.

To do this, the write barrier greys `src` and then drains the mark
work queue until there are no grey objects (using the same work queue
logic that drives the mark phase).
At this point, it writes `src` to `*dst` and allows the goroutine to
proceed.

The write barrier must not perform the write until all simultaneous
write barriers are also ready to perform the write.
We refer to this *mark quiescence*.
To see why this is necessary, consider two simultaneous write barriers
for `*D1 = S1` and `*D2 = S2` on an object graph that looks like this:

    G1 [b] → D1 [b]   S1 [w]
                            ↘
                             O1 [w] → O2 [w] → O3 [w]
                            ↗
             D2 [b]   S2 [w]

Goroutine *G1* has been re-scanned (so *D1* must be black), while *Sn*
and *On* are all white.

Suppose the *S2* write barrier blackens *S2* and *O1* and greys *O2*,
then the *S1* write barrier blackens *S1* and observes that *O1* is
already black:

    G1 [b] → D1 [b]   S1 [b]
                            ↘
                             O1 [b] → O2 [g] → O3 [w]
                            ↗
             D2 [b]   S2 [b]

At this point, the *S1* barrier has run out of local work, but the
*S2* barrier is still going.
If *S1* were to complete and write `*D1 = S1` at this point, it would
make white object *O3* reachable to goroutine *G1*, violating the
invariant.
Hence, the *S1* barrier cannot complete until the *S2* barrier is also
ready to complete.

This requirement sounds onerous, but it can be achieved in a simple
and reasonably efficient manner by sharing a global mark work queue
between the write barriers.
This reuses the existing mark work queue and quiescence logic and
allows write barriers to help each other to completion.

### Stack re-scanning

The stack re-scan phase re-scans the stacks of all goroutines that
have run since the initial stack scan to find pointers to white
objects.
The process of re-scanning a stack is identical to that of the initial
scan, except that it must participate in mark quiescence.
Specifically, the re-scanned goroutine must not resume execution until
the system has reached mark quiescence (even if no white pointers are
found on the stack).
Otherwise, the same sorts of races that were described above are
possible.

There are multiple ways to realize this.
The whole stack scan could participate in mark quiescence, but this
would block any contemporaneous stack scans or write barriers from
completing during a stack scan if any white pointers were found.
Alternatively, each white pointer found on the stack could participate
individually in mark quiescence, blocking the stack scan at that
pointer until mark quiescence, and the stack scan could again
participate in mark quiescence once all frames had been scanned.

We propose an intermediate: gather small batches of white pointers
from a stack at a time and reach mark quiescence on each batch
individually, as well as at the end of the stack scan (even if the
final batch is empty).

### Other considerations

Goroutines that start during stack re-scanning cannot reach any white
objects, so their stacks are immediately considered black.

Goroutines can also share pointers through channels, which are often
implemented as direct stack-to-stack copies.
Hence, channel receives also require write barriers in order to
maintain the invariant.
Channel receives already have write barriers to maintain stack
barriers, so there is no additional work here.


## Rationale

The primary drawback of this approach to concurrent stack re-scanning
is that a write barrier during re-scanning could introduce significant
mutator latency if the transitive mark finds a large unmarked region
of the heap, or if overlapping write barriers significantly delay mark
quiescence.
However, we consider this situation unlikely in non-adversarial
applications.
Furthermore, the resulting delay should be no worse than the mark
termination STW time applications currently experience, since mark
termination has to do exactly the same amount of marking work, in
addition to the cost of stack scanning.

### Alternative approaches

An alternative solution to concurrent stack re-scanning would be to
adopt DMOS-style quiescence [Hudson '97].
In this approach, greying any object during stack re-scanning (either
by finding a pointer to a white object on a stack or by installing a
pointer to a white object in the heap) forces the GC to drain this
marking work and *restart* the stack re-scanning phase.

This approach has a much simpler write barrier implementation that is
constant time, so the write barrier would not induce significant
mutator latency.
However, unlike the proposed approach, the amount of work performed by
DMOS-style stack re-scanning is potentially unbounded.
This interacts poorly with Go's GC pacer.
The pacer enforces the goal heap size making allocating and GC work
proportional, but this requires an upper bound on possible GC work.
As a result, if the pacer underestimates the amount of re-scanning
work, it may need to block allocation entirely to avoid exceeding the
goal heap size.
This would be an effective STW.

There is also a hybrid solution: we could use the proposed transitive
marking write barrier, but bound the amount of work it can do (and
hence the latency it can induce).
If the write barrier exceeds this bound, it performs a DMOS-style
restart.
This is likely to get the best of both worlds, but also inherits the
sum of their complexity.

A final alternative would be to eliminate concurrent stack re-scanning
entirely by adopting a *deletion-style* write barrier [Yuasa '90].
This style of write barrier allows the initial stack scan to *blacken*
the stack, rather than merely greying it (still without the need for
stack write barriers).
For full details, see proposal #17503.


## Compatibility

This proposal does not affect the language or any APIs and hence
satisfies the Go 1 compatibility guidelines.


## Implementation

We do not plan to implement this proposal.
Instead, we plan to implement proposal #17503.

The implementation steps are as follows:

1. While not strictly necessary, first make GC assists participate in
   stack scanning.
   Currently this is not possible, which increases mutator latency at
   the beginning of the GC cycle.
   This proposal would compound this effect by also blocking GC
   assists at the end of the GC cycle, causing an effective STW.

2. Modify the write barrier to be pre-publication instead of
   post-publication.
   Currently the write barrier occurs after the write of a pointer,
   but this proposal requires that the write barrier complete
   transitive marking *before* writing the pointer to its destination.
   A pre-publication barrier is also necessary for
   [ROC](https://golang.org/s/gctoc).

3. Make the mark completion condition precise.
   Currently it's possible (albeit unlikely) to enter mark termination
   before all heap pointers have been marked.
   This proposal requires that we not start stack re-scanning until
   all objects reachable from globals are marked, which requires a
   precise completion condition.

4. Implement the transitive mark write barrier.
   This can reuse the existing work buffer pool lists and logic,
   including the global quiescence barrier in getfull.
   It may be necessary to improve the performance characteristics of
   the getfull barrier, since this proposal will lean far more heavily
   on this barrier than we currently do.

5. Check stack re-scanning code and make sure it is safe during
   non-STW.
   Since this only runs during STW right now, it may omit
   synchronization that will be necessary when running during non-STW.
   This is likely to be minimal, since most of the code is shared with
   the initial stack scan, which does run concurrently.

6. Make stack re-scanning participate in write barrier quiescence.

7. Create a new stack re-scanning phase.
   Make mark 2 completion transition to stack re-scanning instead of
   mark termination and enqueue stack re-scanning root jobs.
   Once all stack re-scanning jobs are complete, transition to mark
   termination.


## Acknowledgments

We would like to thank Rhys Hiltner (@rhysh) for suggesting the idea
of a transitive mark write barrier.


## References

[Hudson '97] R. L. Hudson, R. Morrison, J. E. B. Moss, and D. S.
Munro. Garbage collecting the world: One car at a time. In *ACM
SIGPLAN Notices* 32(10):162–175, October 1997.

[Yuasa '90] T. Yuasa. Real-time garbage collection on general-purpose
machines. *Journal of Systems and Software*, 11(3):181–198, 1990.
