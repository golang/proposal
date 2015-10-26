# Proposal: Decentralized GC coordination

Author(s): Austin Clements

Last updated: 2015-10-25

Discussion at https://golang.org/issue/11970.

## Abstract

The Go 1.5 GC is structured as a straight-line coordinator goroutine
plus several helper goroutines. All state transitions go through the
coordinator. This makes state transitions dependent on the scheduler,
which can delay transitions, in turn extending the length of the GC
cycle, blocking allocation, and occasionally leading to long delays.

We propose to replace this straight-line coordinator with an explicit
state machine where state transitions can be performed by any
goroutine.

## Background

As of Go 1.5, all GC phase changes are managed through straight-line
code in the `runtime.gc` function, which runs on a dedicated GC
goroutine. However, much of the real work is done in other goroutines.
These other goroutines generally detect when it is time for a phase
change and must coordinate with the main GC goroutine to effect this
phase change. This coordination delays phase changes and opens windows
where, for example, the mutator can allocate uncontrolled, or nothing
can be accomplished because everything is waiting on the coordinator
to wake up. This has led to bugs like
[#11677](https://golang.org/issue/11677) and
[#11911](https://golang.org/issue/11911). We've tried to mitigate this
by handing control directly to the coordinator goroutine when we wake
it up, but the scheduler isn't designed for this sort of explicit
co-routine scheduling, so this doesn't always work and it's more
likely to fall apart under stress than an explicit design.

## Proposal

We will restructure the garbage collector as an explicit state machine
where any goroutine can effect a state transition. This is primarily
an implementation change, not an algorithm change: for the most part,
these states and the transitions between them closely follow the
current GC algorithm.

Each state is global and determines the GC-related behavior of all
goroutines. Each state also has an exit condition. State transitions
are performed immediately by whatever goroutine detects that the
current state's exit condition is satisfied. Multiple goroutines may
detect an exit condition simultaneously, in which case none of these
goroutines may progress until the transition has been performed. For
many transitions, this is necessary to prevent runaway heap growth.
Each transition has a specific set of steps to prepare for the next
state and the system enters the next state as soon as those steps are
completed. Furthermore, each transition is designed to make the exit
condition that triggers that transition false so that the transition
happens once and only once per cycle.

In principle, all of the goroutines that detect an exit condition
could assist in performing the transition. However, we take a simpler
approach where all transitions are protected by a global *transition
lock* and transitions are designed to perform very little non-STW
work. When a goroutine detects the exit condition, it acquires the
transition lock, re-checks if the exit condition is still true and, if
not, simply releases the lock and continues executing in whatever the
new state is. It is necessary to re-check the condition, rather than
simply check the current state, in case the goroutine is blocked
though an entire GC cycle.

The sequence of states and transitions is as follows:

* **State: Sweep/Off** This is the initial state of the system. No
  scanning, marking, or assisting is performed. Mutators perform
  proportional sweeping on allocation and background sweeping performs
  additional sweeping on idle Ps.

  In this state, after allocating, a mutator checks if the heap size
  has exceeded the GC trigger size and, if so, it performs concurrent
  sweep termination by sweeping any remaining unswept spans (there
  shouldn't be any for a heap-triggered transition). Once there are no
  unswept spans, it performs the *sweep termination* transition.
  Periodic (sysmon-triggered) GC and `runtime.GC` perform these same
  steps regardless of the heap size.

* **Transition: Sweep termination and initialization** Acquire
  `worldsema`. Start background workers. Stop the world. Perform sweep
  termination. Clear sync pools. Initialize GC state and statistics.
  Enable write barriers, assists, and background workers. If this is a
  concurrent GC, configure root marking, start the world, and enter
  *concurrent mark*. If this is a STW GC (`runtime.GC`), continue with
  the *mark termination* transition.

* **State: Concurrent mark 1** In this state, background workers
  perform concurrent scanning and marking and mutators perform
  assists.

  Background workers initially participate in root marking and then
  switch to draining heap mark work.

  Mutators assist with heap marking work in response to allocation
  according to the assist ratio established by the GC controller.

  In this state, the system keeps an atomic counter of the number of
  active jobs, which includes the number of background workers and
  assists with checked out work buffers, plus the number of workers in
  root marking jobs. If this number drops to zero and
  `gcBlackenPromptly` is unset, the worker or assist that dropped it
  to zero transitions to *concurrent mark 2*. Note that it's important
  that this transition not happen until all root mark jobs are done,
  which is why the counter includes this.

  Note: Assists could participate in root marking jobs just like
  background workers do and accumulate assist credit for this scanning
  work. This would particularly help at the beginning of the cycle
  when there may be little background credit or queued heap scan work.
  This would also help with load balancing. In this case, we would
  want to update `scanblock` to track scan credit and modify the scan
  work estimate to include roots.

* **Transition: Disable workbuf caching** Disable caching of workbufs
  by setting `gcBlackenPromptly`. Queue root mark jobs for globals.

  Note: It may also make sense to queue root mark jobs for stacks.
  This would require making it possible to re-scan a stack (and extend
  existing stack barriers).

* **State: Concurrent mark 2** The goroutine that performed the flush
  transition flushes all workbuf caches using `forEachP`. This counts
  as an active job to prevent the next transition from happening
  before this is done.

  Otherwise, this state is identical to *concurrent mark 1*, except
  that workbuf caches are disabled.

  Because workbuf caches are disabled, if the active workbuf count
  drops to zero, there is no more work. When this happens and
  `gcBlackenPromptly` is set, the worker or assist that dropped it the
  count to zero performs the *mark termination* transition.

* **Transition: Mark termination** Stop the world. Unblock all parked
  assists. Perform `gcMark`, checkmark (optionally), `gcSweep`, and
  re-mark (optionally). Start the world. Release `worldsema`. Print GC
  stats. Free stacks.

  Note that `gcMark` itself runs on all Ps, so this process is
  parallel even though it happens during a transition.

## Rationale

There are various alternatives to this approach. The most obvious is
to simply continue with what we do now: a central GC coordinator with
hacks to deal with delays in various transitions. This is working
surprisingly well right now, but only as a result of a good deal of
engineering effort (primarily the cascade of fixes on
[#11677](https://github.com/golang/go/issues/11677)) and its fragility
makes it difficult to make further changes to the garbage collector.

Another approach would be make the scheduler treat the GC coordinator
as a high priority goroutine and always schedule it immediately when
it becomes runnable. This would consolidate several of our current
state transition "hacks", which attempt to help out the scheduler.
However, in a concurrent setting it's important to not only run the
coordinator as soon as possible to perform a state transition, but
also to disallow uncontrolled allocation on other threads while this
transition is being performed. Scheduler hacks don't address the
latter problem.

## Compatibility

This change is internal to the Go runtime. It does not change any
user-facing Go APIs, and hence it satisfies Go 1 compatibility.

## Implementation

This change will be implemented by Austin Clements, hopefully in the
Go 1.6 development cycle. Much of the design has already been
prototyped.

Many of the prerequisite changes have already been completed. In
particular, we've already moved most of the non-STW work out of the GC
coordinator ([CL 16059](https://go-review.googlesource.com/#/c/16059/)
and [CL 16070](https://go-review.googlesource.com/#/c/16070/)), made
root marking jobs smaller
([CL 16043](https://go-review.googlesource.com/#/c/16043)), and
improved the synchronization of blocked assists
([CL 15890](https://go-review.googlesource.com/#/c/15890)).

The GC coordinator will be converted to a decentralized state machine
incrementally, one state/transition at a time where possible. At the
end of this, there will be no work left in the GC coordinator and it
will be deleted.

## Open issues

There are devils in the details. One known devil in the current
garbage collector that will affect this design in different ways is
the complex constraints on scheduling within the garbage collector
(and the runtime in general). For example, background workers are
currently not allowed to block, which means they can't stop the world
to perform mark termination. These constraints were designed for the
current coordinator-based system and we will need to find ways of
resolving them in the decentralized design.
