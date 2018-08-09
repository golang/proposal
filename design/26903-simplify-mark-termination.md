# Proposal: Simplify mark termination and eliminate mark 2

Author(s): Austin Clements

Last updated: 2018-08-09

Discussion at https://golang.org/issue/26903.


## Abstract

Go's garbage collector has evolved substantially over time, and as
with any software with a history, there are places where the vestigial
remnants of this evolution show.
This document proposes several related simplifications to the design
of Go's mark termination and related parts of concurrent marking that
were made possible by shifts in other parts of the garbage collector.

The keystone of these simplifications is a new mark completion
algorithm.
The current algorithm is racy and, as a result, mark termination must
cope with the possibility that there may still be marking work to do.
We propose a new algorithm based on distributed termination detection
that both eliminates this race and replaces the existing "mark 2"
sub-phase, yielding simplifications throughout concurrent mark and
mark termination.

This new mark completion algorithm combined with a few smaller changes
can simplify or completely eliminate several other parts of the
garbage collector. Hence, we propose to also:

1. Unify stop-the-world GC and checkmark mode with concurrent marking;

2. Flush mcaches after mark termination;

3. And allow safe-points without preemption in dedicated workers.

Taken together, these fairly small changes will allow us to eliminate
mark 2, "blacken promptly" mode, the second root marking pass,
blocking drain mode, `getfull` and its troublesome spin loop, work
queue draining during mark termination, `gchelper`, and idle worker
tracking.

This will eliminate a good deal of subtle code from the garbage
collector, making it simpler and more maintainable.
As an added bonus, it's likely to perform a little better, too.


## Background

Prior to Go 1.5, Go's garbage collector was a stop-the-world garbage
collector, and Go continues to support STW garbage collection as a
debugging mode.
Go 1.5 introduced a concurrent collector, but, in order to minimize a
massively invasive change, it kept much of the existing GC mechanism
as a STW "mark termination" phase, while adding a concurrent mark
phase before the STW phase.
This concurrent mark phase did as much as it could, but ultimately
fell back to the STW algorithm to clean up any work it left behind.

Until Go 1.8, concurrent marking always left behind at least some
work, since any stacks that had been modified during the concurrent
mark phase had to be re-scanned during mark termination.
Go 1.8 introduced [a new write barrier](17503-eliminate-rescan.md)
that eliminated the need to re-scan stacks.
This significantly reduced the amount of work that had to be done in
mark termination.
However, since it had never really mattered before, we were sloppy
about entering mark termination: the algorithm that decided when it
was time to enter mark termination *usually* waited until all work was
done by concurrent mark, but sometimes [work would slip
through](17503-eliminate-rescan.md#appendix-mark-completion-race),
leaving mark termination to clean up the mess.

Furthermore, in order to minimize (though not eliminate) the chance of
entering mark termination prematurely, Go 1.5 divided concurrent
marking into two phases creatively named "mark 1" and "mark 2".
During mark 1, when it ran out of global marking work, it would flush
and disable all local work caches (enabling "blacken promptly" mode)
and enter mark 2.
During mark 2, when it ran out of global marking work again, it would
enter mark termination.
Unfortunately, blacken promptly mode has performance implications
(there was a reason for those local caches), and this algorithm can
enter mark 2 very early in the GC cycle since it merely detects a work
bottleneck.
And while disabling all local caches was intended to prevent premature
mark termination, this doesn't always work.


## Proposal

There are several steps to this proposal, and it's not necessary to
implement all of them.
However, the crux of the proposal is a new termination detection
algorithm.

### Replace mark 2 with a race-free algorithm

We propose replacing mark 2 with a race-free algorithm based on ideas
from distributed termination detection [Matocha '97].

The GC maintains several work queues of grey objects to be blackened.
It maintains two global queues, one for root marking work and one for
heap objects, but we can think of these as a single logical queue.
It also maintains a queue of locally cached work on each *P* (that is,
each GC worker).
A P can move work from the global queue to its local queue or
vice-versa.
Scanning removes work from the local queue and may add work back to
the local queue.
This algorithm does not change the structure of the GC's work queues
from the current implementation.

A P *cannot* observe or remove work from another P's local queue.
A P also *cannot* create work from nothing: it must consume a marking
job in order to create more marking jobs.
This is critical to termination detection because it means termination
is a stable condition.
Furthermore, all of these actions must be *GC-atomic*; that is, there
are no safe-points within each of these actions.
Again, all of this is true of the current implementation.

The proposed algorithm is as follows:

First, each P, maintains a local *flushed* flag that it sets whenever
the P flushes any local GC work to the global queue.
The P may cache an arbitrary amount of GC work locally without setting
this flag; the flag indicates that it may have shared work with
another P.
This flag is only accessed synchronously, so it need not be atomic.

When a P's local queue is empty and the global queue is empty it runs
the termination detection algorithm:

1. Acquire a global termination detection lock (only one P may run
   this algorithm at a time).

2. Check the global queue. If it is non-empty, we have not reached
   termination, so abort the algorithm.

3. Execute a ragged barrier. On each P, when it reaches a safe-point,

    1. Flush the local write barrier buffer.
       This may mark objects and add pointers to the local work queue.

    2. Flush the local work queue.
       This may set the P's flushed flag.

    3. Check and clear the P's flushed flag.

4. If any P's flushed flag was set, we have not reached termination,
   so abort the algorithm.
   If no P's flushed flag was set, enter mark termination.

Like most wave-based distributed termination algorithms, it may be
necessary to run this algorithm multiple times during a cycle.
However, this isn't necessarily a disadvantage: flushing the local
work queues also serves to balance work between Ps, and makes it okay
to keep work cached on a P that isn't actively doing GC work.

There are a few subtleties to this algorithm that are worth noting.
First, unlike many distributed termination algorithms, it *does not*
detect that no work was done since the previous barrier.
It detects that no work was *communicated*, and that all queues were
empty at some point.
As a result, while many similar algorithms require at least two waves
to detect termination [Hudson '97], this algorithm can detect
termination in a single wave.
For example, on small heaps it's possible for all Ps to work entirely
out of their local queues, in which case mark can complete after just
a single wave.

Second, while the only way to add work to the local work queue is by
consuming work, this is not true of the local write barrier buffer.
Since this buffer simply records pointer writes, and the recorded
objects may already be black, it can continue to grow after
termination has been detected.
However, once termination is detected, we know that all pointers in
the write barrier buffer must be to black objects, so this buffer can
simply be discarded.

#### Variations on the basic algorithm

There are several small variations on the basic algorithm that may be
desirable for implementation and efficiency reasons.

When flushing the local work queues during the ragged barrier, it may
be valuable to break up the work buffers that are put on the global
queue.
For efficiency, work is tracked in batches and the queues track these
batches, rather than individual marking jobs.
The ragged barrier is an excellent opportunity to break up these
batches to better balance work.

The ragged barrier places no constraints on the order in which Ps
flush, nor does it need to run on all Ps if some P has its local
flushed flag set.
One obvious optimization this allows is for the P that triggers
termination detection to flush its own queues and check its own
flushed flag before trying to interrupt other Ps.
If its own flushed flag is set, it can simply clear it and abort (or
retry) termination detection.

#### Consequences

This new termination detection algorithm replaces mark 2, which means
we no longer need blacken-promptly mode.
Hence, we can delete all code related to blacken-promptly mode.

It also eliminates the mark termination race, so, in concurrent mode,
mark termination no longer needs to detect this race and behave
differently.
However, we should probably continue to detect the race and panic, as
detecting the race is cheap and this is an excellent self-check.

### Unify STW GC and checkmark mode with concurrent marking

The next step in this proposal is to unify stop-the-world GC and
checkmark mode with concurrent marking.
Because of the GC's heritage from a STW collector, there are several
code paths that are specific to STW collection, even though STW is
only a debugging option at this point.
In fact, as we've made the collector more concurrent, more code paths
have become vestigial, existing only to support STW mode.
This adds complexity to the garbage collector and makes this debugging
mode less reliable (and less useful) as these code paths are poorly
tested.

We propose instead implementing STW collection by reusing the existing
concurrent collector, but simply telling the scheduler that all Ps
must run "dedicated GC workers".
Hence, while the world won't technically be stopped during marking, it
will effectively be stopped.

#### Consequences

Unifying STW into concurrent marking directly eliminates several code
paths specific to STW mode.
Most notably, concurrent marking currently has two root marking phases
and STW mode has a single root marking pass.
All three of these passes must behave differently.
Unifying STW and concurrent marking collapses all three passes into
one.

In conjunction with the new termination detection algorithm, this
eliminates the need for mark work draining during mark termination.
As a result, the write barrier does not need to be on during mark
termination, and we can eliminate blocking drain mode entirely.
Currently, blocking drain mode is only used if the mark termination
race happens or if we're in STW mode.
This in turn eliminates the troublesome spin loop in `getfull` that
implements blocking drain mode.
Specifically, this eliminates `work.helperDrainBlock`, `gcDrainBlock`
mode, `gcWork.get`, and `getfull`.

At this point, the `gcMark` function should be renamed, since it will
no longer have anything to do with marking.

Unfortunately, this isn't enough to eliminate work draining entirely
from mark termination, since the draining mechanism is also used to
flush mcaches during mark termination.

### Flush mcaches after mark termination

The third step in this proposal is to delay the flushing of mcaches
until after mark termination.

Each P has an mcache that tracks spans being actively allocated from
by that P.
Sweeping happens when a P brings a span into its mcache, or can happen
asynchronously as part of background sweeping.
Hence, the spans in mcaches must be flushed out in order to trigger
sweeping of those spans and to prevent a race between allocating from
an unswept span and the background sweeper sweeping that span.

While it's important for the mcaches to be flushed between enabling
the sweeper and allocating, it does not have to happen during mark
termination.

Hence, we propose to flush each P's mcache when that P returns from
the mark termination STW.
This is early enough to ensure no allocation can happen on that P,
parallelizes this flushing, and doesn't block other Ps during
flushing.

Combined with the first two steps, this eliminates the only remaining
use of work draining during mark termination, so we can eliminate mark
termination draining entirely, including `gchelper` and related
mechanisms (`mhelpgc`, `m.helpgc`, `helpgc`, `gcprocs`,
`needaddgcproc`, etc).

### Allow safe-points without preemption in dedicated workers

The final step of this proposal is to allow safe-points in dedicated
GC workers.
Currently, dedicated GC workers only reach a safe-point when there is
no more local or global work.
However, this interferes with the ragged barrier in the termination
detection algorithm (which can only run at a safe-point on each P).
As a result, it's only fruitful to run the termination detection
algorithm if there are no dedicated workers running, which in turn
requires tracking the number of running and idle workers, and may
delay work balancing.

By allowing more frequent safe-points in dedicated GC workers,
termination detection can run more eagerly.

Furthermore, worker tracking was based on the mechanism used by STW GC
to implement the `getfull` barrier.
Once that has also been eliminated, we no longer need any worker
tracking.


## Proof of termination detection algorithm

The proposed termination detection algorithm is remarkably simple to
implement, but subtle in its reasoning.
Here we prove it correct and endeavor to provide some insight into why
it works.

**Theorem.** The termination detection algorithm succeeds only if all
mark work queues are empty when the algorithm terminates.

**Proof.** Assume the termination detection algorithm succeeds.
In order to show that all mark work queues must be empty once the
algorithm succeeds, we use induction to show that all possible actions
must maintain three conditions: 1) the global queue is empty, 2) all
flushed flags are clear, and 3) after a P has been visited by the
ragged barrier, its local queue is empty.

First, we show that these conditions were true at the instant it
observed the global queue was empty.
This point in time trivially satisfies condition 1.
Since the algorithm succeeded, each P's flushed flag must have been
clear when the ragged barrier observed that P.
Because termination detection is the only operation that clears the
flushed flags, each flag must have been clear for all time between the
start of termination detection and when the ragged barrier observed
the flag.
In particular, all flags must have been clear at the instant it
observed that the global queue was empty, so condition 2 is satisfied.
Condition 3 is trivially satisfied at this point because no Ps have
been visited by the ragged barrier.
This establishes the base case for induction.

Next, we consider all possible actions that could affect the state of
the queue or the flags after this initial state.
There are four such actions:

1. The ragged barrier can visit a P.
   This may modify the global queue, but if it does so it will set the
   flushed flag and the algorithm will not succeed, contradicting the
   assumption.
   Thus it could not have modified the global queue, maintaining
   condition 1.
   For the same reason, we know it did not set the flushed flag,
   maintaining condition 2.
   Finally, the ragged barrier adds the P to the set of visited P, but
   flushes the P's local queue, thus maintaining condition 3.

2. If the global queue is non-empty, a P can move work from the global
   queue to its local queue.
   By assumption, the global queue is empty, so this action can't
   happen.

3. If its local queue is non-empty, a P can consume local work and
   potentially produce local work.
   This action does not modify the global queue or flushed flag, so it
   maintains conditions 1 and 2.
   If the P has not been visited by the ragged barrier, then condition
   3 is trivially maintained.
   If it has been visited, then by assumption the P's local queue is
   empty, so this action can't happen.

4. If the local queue is non-empty, the P can move work from the local
   queue to the global queue.
   There are two sub-cases.
   If the P has not been visited by the ragged barrier, then this
   action would set the P's flushed flag, causing termination
   detection to fail, which contradicts the assumption.
   If the P has been visited by the ragged barrier, then its local
   queue is empty, so this action can't happen.

Therefore, by induction, all three conditions must be true when
termination detection succeeds.
Notably, we've shown that once the ragged barrier is complete, none of
the per-P actions (2, 3, and 4) can happen.
Thus, if termination detection succeeds, then by conditions 1 and 3,
all mark work queues must be empty.


**Corollary.** Once the termination detection algorithm succeeds,
there will be no work to do in mark termination.

Go's GC never turns a black object grey because it uses black mutator
techniques (once a stack is black it remains black) and a
forward-progress barrier.
Since the mark work queues contain pointers to grey objects, it
follows that once the mark work queues are empty, they will remain
empty, including when the garbage collector transitions in to mark
termination.


## Compatibility

This proposal does not affect any user-visible APIs, so it is Go 1
compatible.


## Implementation

This proposal can be implemented incrementally, and each step opens up
new simplifications.
The first step will be to implement the new termination detection
algorithm, since all other simplifications build on that, but the
other steps can be implemented as convenient.

Austin Clements plans to implement all or most of this proposal for Go
1.12.
The actual implementation effort for each step is likely to be fairly
small (the mark termination algorithm was implemented and debugged in
under an hour).


## References

[Hudson '97] R. L. Hudson, R. Morrison, J. E. B. Moss, and D. S.
Munro. Garbage collecting the world: One car at a time. In *ACM
SIGPLAN Notices* 32(10):162–175, October 1997.

[Matocha '98] Jeff Matocha and Tracy Camp. "A taxonomy of distributed
termination detection algorithms." In *Journal of Systems and
Software* 43(3):207–221, November 1998.
