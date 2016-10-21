# Proposal: Eliminate STW stack re-scanning

Author(s): Austin Clements, Rick Hudson

Last updated: 2016-10-21

Discussion at https://golang.org/issue/17503.

## Abstract

As of Go 1.7, the one remaining source of unbounded and potentially
non-trivial stop-the-world (STW) time is stack re-scanning.
We propose to eliminate the need for stack re-scanning by switching to
a *hybrid write barrier* that combines a Yuasa-style deletion write
barrier [Yuasa '90] and a Dijkstra-style insertion write barrier
[Dijkstra '78].
Preliminary experiments show that this can reduce worst-case STW time
to under 50µs, and this approach may make it practical to eliminate
STW mark termination altogether.

Eliminating stack re-scanning will in turn simplify and eliminate many
other parts of the garbage collector that exist solely to improve the
performance of stack re-scanning.
This includes stack barriers (which introduce significant complexity
in many parts of the runtime) and maintenance of the re-scan list.
Hence, in addition to substantially improving STW time, the hybrid
write barrier should also reduce the overall complexity of the garbage
collector.


## Background

The Go garbage collector is a *tricolor* concurrent collector
[Dijkstra '78].
Every object is shaded either white, grey, or black.
At the beginning of a GC cycle, all objects are white, and it is the
goal of the garbage collector to mark all reachable objects black and
then free all white objects.
The garbage collector achieves this by shading GC roots (stacks and
globals, primarily) grey and then endeavoring to turn all grey objects
black while satisfying the *strong tricolor invariant*:

> No black object may contain a pointer to a white object.

Ensuring the tricolor invariant in the presence of concurrent pointer
updates requires *barriers* on either pointer reads or pointer writes
(or both).
There are many flavors of barrier [Pirinen '98].
Go 1.7 uses a coarsened Dijkstra write barrier [Dijkstra '78], where
pointer writes are implemented as follows:

```
writePointer(slot, ptr):
    shade(ptr)
    *slot = ptr
```

`shade(ptr)` marks the object at `ptr` grey if it is not already grey
or black.
This ensures the strong tricolor invariant by conservatively assuming
that `*slot` may be in a black object, and ensuring `ptr` cannot be
white before installing it in `*slot`.

The Dijkstra barrier has several advantages over other types of
barriers.
It does not require any special handling of pointer reads, which has
performance advantages since pointer reads tend to outweigh pointer
writes by an order of magnitude or more.
It also ensures forward progress; unlike, for example, the Steele
write barrier [Steele '75], objects transition monotonically from
white to grey to black, so the total work is bounded by the heap size.

However, it also has disadvantages.
In particular, it presents a trade-off for pointers on stacks: either
writes to pointers on the stack must have write barriers, which is
prohibitively expensive, or stacks must be *permagrey*.
Go chooses the later, which means that many stacks must be re-scanned
during STW.
The garbage collector first scans all stacks at the beginning of the
GC cycle to collect roots.
However, without stack write barriers, we can't ensure that the stack
won't later contain a reference to a white object, so a scanned stack
is only black until its goroutine executes again, at which point it
conservatively reverts to grey.
Thus, at the end of the cycle, the garbage collector must re-scan grey
stacks to blacken them and finish marking any remaining heap pointers.
Since it must ensure the stacks don't continue to change during this,
the whole re-scan process happens *with the world stopped*.

Re-scanning the stacks can take 10's to 100's of milliseconds in an
application with a large number of active goroutines.


## Proposal

We propose to eliminate stack re-scanning and replace Go's write
barrier with a *hybrid write barrier* that combines a Yuasa-style
deletion write barrier [Yuasa '90] with a Dijkstra-style insertion
write barrier [Dijkstra '78].
The hybrid write barrier is implemented as follows:

```
writePointer(slot, ptr):
    shade(*slot)
    if current stack is grey:
        shade(ptr)
    *slot = ptr
```

That is, the write barrier shades the object whose reference is being
overwritten, and, if the current goroutine's stack has not yet been
scanned, also shades the reference being installed.

The hybrid barrier makes stack re-scanning unnecessary; once a stack
has been scanned and blackened, it remains black.
Hence, it eliminates the need for stack re-scanning and the mechanisms
that exist to support stack re-scanning, including stack barriers and
the re-scan list.

The hybrid barrier requires that objects be allocated black
(allocate-white is a common policy, but incompatible with this
barrier).
However, while not required by Go's current write barrier, Go already
allocates black for other reasons, so no change to allocation is
necessary.

The hybrid write barrier is equivalent to the "double write barrier"
used in the adaptation of Metronome used in the IBM real-time Java
implementation [Auerbach '07]. In that case, the garbage collector was
incremental, rather than concurrent, but ultimately had to deal with
the same problem of tightly bounded stop-the-world times.

### Reasoning

A full proof of the hybrid write barrier is given at the end of this
proposal.
Here we give the high-level intuition behind the barrier.

Unlike the Dijkstra write barrier, the hybrid barrier does *not*
satisfy the strong tricolor invariant: for example, a black goroutine
(a goroutine whose stack has been scanned) can write a pointer to a
white object into a black object without shading the white object.
However, it does satisfy the *weak tricolor invariant* [Pirinen '98]:

> Any white object pointed to by a black object is reachable from a
> grey object via a chain of white pointers (it is *grey-protected*).

The weak tricolor invariant observes that it's okay for a black object
to point to a white object, as long as *some* path ensures the garbage
collector will get around to marking that white object.

Any write barrier has to prohibit a mutator from "hiding" an object;
that is, rearranging the heap graph to violate the weak tricolor
invariant so the garbage collector fails to mark a reachable object.
For example, in a sense, the Dijkstra barrier allows a mutator to hide
a white object by moving the sole pointer to it to a stack that has
already been scanned.
The Dijkstra barrier addresses this by making stacks permagray and
re-scanning them during STW.

In the hybrid barrier, the two shades and the condition work together
to prevent a mutator from hiding an object:

1. `shade(*slot)` prevents a mutator from hiding an object by moving
   the sole pointer to it from the heap to its stack.
   If it attempts to unlink an object from the heap, this will shade
   it.

2. `shade(ptr)` prevents a mutator from hiding an object by moving the
   sole pointer to it from its stack into a black object in the heap.
   If it attempts to install the pointer into a black object, this
   will shade it.

3. Once a goroutine's stack is black, the `shade(ptr)` becomes
   unnecessary.
   `shade(ptr)` prevents hiding an object by moving it from the stack
   to the heap, but this requires first having a pointer hidden on the
   stack.
   Immediately after a stack is scanned, it only points to shaded
   objects, so it's not hiding anything, and the `shade(*slot)`
   prevents it from hiding any other pointers on its stack.

The hybrid barrier combines the best of the Dijkstra barrier and the
Yuasa barrier.
The Yuasa barrier requires a STW at the beginning of marking to either
scan or snapshot stacks, but does not require a re-scan at the end of
marking.
The Dijkstra barrier lets concurrent marking start right away, but
requires a STW at the end of marking to re-scan stacks (though more
sophisticated non-STW approaches are possible [Hudson '97]).
The hybrid barrier inherits the best properties of both, allowing
stacks to be concurrently scanned at the beginning of the mark phase,
while also keeping stacks black after this initial scan.


## Rationale

The advantage of the hybrid barrier is that it lets a stack scan
permanently blacken a stack (without a STW and without write barriers
to the stack), which entirely eliminates the need for stack
re-scanning, in turn eliminating the need for stack barriers and
re-scan lists.
Stack barriers in particular introduce significant complexity
throughout the runtime, as well as interfering with stack walks from
external tools such as GDB and kernel-based profilers.

Also, like the Dijkstra-style write barrier, the hybrid barrier does
not require a read barrier, so pointer reads are regular memory reads;
and it ensures progress, since objects progress monotonically from
white to grey to black.

The disadvantages of the hybrid barrier are minor.
It may result in more floating garbage, since it retains everything
reachable from roots (other than stacks) at any point during the mark
phase.
However, in practice it's likely that the current Dijkstra barrier is
retaining nearly as much.
The hybrid barrier also prohibits certain optimizations: in
particular, the Go compiler currently omits a write barrier if it can
statically show that the pointer is nil, but the hybrid barrier
requires a write barrier in this case.
This may slightly increase binary size.

### Alternative barrier approaches

There are several variations on the proposed barrier that would also
work, but we believe the proposed barrier represents the best set of
trade-offs.

A basic variation is to make the Dijkstra-style aspect of the barrier
unconditional:

```
writePointer(slot, ptr):
    shade(*slot)
    shade(ptr)
    *slot = ptr
```

The main advantage of this barrier is that it's easier to reason
about.
It directly ensures there are no black-to-white pointers in the heap,
so the only source of black-to-white pointers can be scanned stacks.
But once a stack is scanned, the only way it can get a white pointer
is by traversing reachable objects, and any white object that can be
reached by a goroutine with a black stack is grey-protected by a heap
object.

The disadvantage of this barrier is that it's effectively twice as
expensive as the proposed barrier for most of the mark phase.

Similarly, we could simply coarsen the stack condition:

```
writePointer(slot, ptr):
    shade(*slot)
    if any stack is grey:
        shade(ptr)
    *slot = ptr
```

This has the advantage of making cross-stack writes such as those
allowed by channels safe without any special handling, but prolongs
when the second shade is enabled, which slows down pointer writes.

A different approach would be to require that all stacks be blackened
before any heap objects are blackened, which would enable a pure
Yuasa-style deletion barrier:

```
writePointer(slot, ptr):
    shade(*slot)
    *slot = ptr
```

As originally proposed, the Yuasa barrier takes a complete snapshot of
the stack before proceeding with marking.
Yuasa argued that this was reasonable on hardware that could perform
bulk memory copies very quickly.
However, Yuasa's proposal was in the context of a single-threaded
system with a comparatively small stack, while Go programs regularly
have thousands of stacks that can total to a large amount of memory.

However, this complete snapshot isn't necessary.
It's sufficient to ensure all stacks are black before scanning any
heap objects.
This allows stack scanning to proceed concurrently, but has the
downside that it introduces a bottleneck to the parallelism of the
mark phase between stack scanning and heap scanning.
This bottleneck has downstream effects on goroutine availability,
since allocation is paced against marking progress.

Finally, there are other types of *black mutator* barrier techniques.
However, as shown by Pirinen, all possible black mutator barriers
other than the Yuasa barrier require a read barrier [Pirinen '98].
Given the relative frequency of pointer reads to writes, we consider
this unacceptable for application performance.

### Alternative approaches to re-scanning

Going further afield, it's also possible to make stack re-scanning
concurrent without eliminating it [Hudson '97].
This does not require changes to the write barrier, but does introduce
significant additional complexity into stack re-scanning.
Proposal #17505 gives a detailed design for how to do concurrent stack
re-scanning in Go.


## Other considerations

### Channel operations and go statements

The hybrid barrier assumes a goroutine cannot write to another
goroutine's stack.
This is true in Go except for two operations: channel sends and
starting goroutines, which can copy values directly from one stack to
another.
For channel operations, the `shade(ptr)` is necessary if *either* the
source stack or the destination stack is grey.
For starting a goroutine, the destination stack is always black, so
the `shade(ptr)` is necessary if the source stack is grey.

### Racy programs

In a racy program, two goroutines may store to the same pointer
simultaneously and invoke the write barrier concurrently on the same
slot.
The hazard is that this may cause the barrier to fail to shade some
object that it would have shaded in a sequential execution,
particularly given a relaxed memory model.
While racy Go programs are generally undefined, we have so far
maintained that a racy program cannot trivially defeat the soundness
of the garbage collector (since a racy program can defeat the type
system, it can technically do anything, but we try to keep the garbage
collector working as long as the program stays within the type
system).

Suppose *optr* is the value of the slot before either write to the
slot and *ptr1* and *ptr2* are the two pointers being written to the
slot.
"Before" is well-defined here because all architectures that Go
supports have *coherency*, which means there is a total order over all
reads and writes of a single memory location.
If the goroutine's respective stacks have been scanned, then *ptr1*
and *ptr2* will clearly be shaded, since those shades don't read from
memory.
Hence, the difficult case is if the goroutine's stacks have been
scanned.
In this case, the barriers reduce to:

<table>
<tr><th>Goroutine G1</th><th>Goroutine G2</th></tr>
<tr><td>
<pre>optr1 = *slot
shade(optr1)
*slot = ptr1</pre>
</td><td>
<pre>optr2 = *slot
shade(optr2)
*slot = ptr2</pre>
</td></tr>
</table>

Given that we're only dealing with one memory location, the property
of coherence means we can reason about this execution as if it were
sequentially consistent.
Given this, concurrent execution of the write barriers permits one
outcome that is not permitted by sequential execution: if both
barriers read `*slot` before assigning to it, then only *optr* will be
shaded, and neither *ptr1* nor *ptr2* will be shaded by the barrier.
For example:

<table>
<tr><th>Goroutine G1</th><th>Goroutine G2</th></tr>
<tr><td>
<pre>optr1 = *slot
shade(optr1)

*slot = ptr1

</pre>
</td><td>
<pre>optr2 = *slot

shade(optr2)

*slot = ptr2</pre>
</td></tr>
</table>

We assert that this is safe.
Suppose *ptr1* is written first.
This execution is *nearly* indistinguishable from an execution that
simply skips the write of *ptr1*.
The only way to distinguish it is if a read from another goroutine
*G3* observes *slot* between the two writes.
However, given our assumption that stacks have already been scanned,
either *ptr1* is already shaded, or it must be reachable from some
other place in the heap anyway (and will be shaded eventually), so
concurrently observing *ptr1* doesn't affect the marking or
reachability of *ptr1*.

### cgo

The hybrid barrier could be a problem if C code overwrites a Go
pointer in Go memory with either nil or a C pointer.
Currently, this operation does not require a barrier, but with any
sort of deletion barrier, this does require the barrier.
However, a program that does this would violate the cgo pointer
passing rules, since Go code is not allowed to pass memory to a C
function that contains Go pointers.
Furthermore, this is one of the "cheap dynamic checks" enabled by the
default setting of `GODEBUG=cgocheck=1`, so any program that violates
this rule will panic unless the checks have been explicitly disabled.


## Future directions

### Write barrier omission

The current write barrier can be omitted by the compiler in cases
where the compiler knows the pointer being written is permanently
shaded, such as nil pointers, pointers to globals, and pointers to
static data.
These optimizations are generally unsafe with the hybrid barrier.
However, if the compiler can show that *both* the current value of the
slot and the value being written are permanently shaded, then it can
still safely omit the write barrier.
This optimization is aided by the fact that newly allocated objects
are zeroed, so all pointer slots start out pointing to nil, which is
permanently shaded.

### Low-pause stack scans

Currently the garbage collector pauses a goroutine while scanning its
stack.
If goroutines have large stacks, this can introduce significant tail
latency effects.
The hybrid barrier and the removal of the existing stack barrier
mechanism would make it feasible to perform stack scans with only
brief goroutine pauses.

In this design, scanning a stack pauses the goroutine briefly while it
scans the active frame.
It then installs a *blocking stack barrier* over the return to the
next frame and lets the goroutine resume.
Stack scanning then continues toward the outer frames, moving the
stack barrier up the stack as it goes.
If the goroutine does return as far as the stack barrier, before it
can return to an unscanned frame, the stack barrier blocks until
scanning can scan that frame and move the barrier further up the
stack.

One complication is that a running goroutine could attempt to grow its
stack during the stack scan.
The simplest solution is to block the goroutine if this happens until
the scan is done.

Like the current stack barriers, this depends on write barriers when
writing through pointers to other frames.
For example, in a partially scanned stack, an active frame could use
an up-pointer to move a pointer to a white object out of an unscanned
frame and into the active frame.
Without a write barrier on the write that removes the pointer from the
unscanned frame, this could hide the white object from the garbage
collector.

However, with write barriers on up-pointers, this is safe.
Rather than arguing about "partially black" stacks, the write barrier
on up-pointers lets us view the stack as a sequence of separate
frames, where unscanned frames are treated as part of the *heap*.
Writes without write barriers can only happen to the active frame, so
we only have to view the active frame as the stack.

This design is technically possible now, but the complexity of
composing it with the existing stack barrier mechanism makes it
unappealing.
With the existing stack barriers gone, the implementation of this
approach becomes relatively straightforward.
It's also generally simpler than the existing stack barriers in many
dimensions, since there are at most two stack barriers per goroutine
at a time, and they are present only during the stack scan.

### Strictly bounded mark termination

This proposal goes a long way toward strictly bounding the time spent
in STW mark termination, but there are some other known causes of
longer mark termination pauses.
The primary cause is a race that can trigger mark termination while
there is still remaining heap mark work.
This race and how to resolve it are detailed in the "Mark completion
race" appendix.

### Concurrent mark termination

With stack re-scanning out of mark termination, it may become
practical to make the remaining tasks in mark termination concurrent
and eliminate the mark termination STW entirely.
On the other hand, the hybrid barrier may reduce STW so much that
completely eliminating it is not a practical concern.

The following is a probably incomplete list of remaining mark
termination tasks and how to address them.
Worker stack scans can be eliminated by having workers self-scan
during mark.
Scanning the finalizer queue can be eliminated by adding explicit
barriers to `queuefinalizer`.
Without these two scans (and with the fix for the mark completion race
detailed in the appendix), mark termination will produce no mark work,
so finishing the work queue drain also becomes unnecessary.
`mcache`s can be flushed lazily at the beginning of the sweep phase
using rolling synchronization.
Flushing the heap profile can be done immediately at the beginning of
sweep (this is already concurrent-safe, in fact).
Finally, updating global statistics can be done using atomics and
possibly a global memory barrier.

### Concurrent sweep termination

Likewise, it may be practical to eliminate the STW for sweep
termination.
This is slightly complicated by the fact that the hybrid barrier
requires a global memory fence at the beginning of the mark phase to
enable the write barrier and ensure all pointer writes prior to
enabling the write barrier are visible to the write barrier.
Currently, the STW for sweep termination and setting up the mark phase
accomplishes this.
If we were to make sweep termination concurrent, we could instead use
a ragged barrier to accomplish the global memory fence, or the
[`membarrier` syscall](http://man7.org/linux/man-pages/man2/membarrier.2.html)
on recent Linux kernels.


## Compatibility

This proposal does not affect the language or any APIs and hence
satisfies the Go 1 compatibility guidelines.


## Implementation

Austin plans to implement the hybrid barrier during the Go 1.8
development cycle.
For 1.8, we will leave stack re-scanning support in the runtime for
debugging purposes, but disable it by default using a `GODEBUG`
variable.
Assuming things go smoothly, we will remove stack re-scanning support
when the tree opens for Go 1.9 development.

The planned implementation approach is:

1. Fix places that do unusual or "clever" things with memory
   containing pointers and make sure they cooperate with the hybrid
   barrier.
   We'll presumably find more of these as we debug in later steps, but
   we'll have to make at least the following changes:

    1. Ensure barriers on stack-to-stack copies for channel sends and
       starting goroutines.

    2. Check all places where we clear memory since the hybrid barrier
       requires distinguishing between clearing for initialization and
       clearing already-initialized memory.
       This will require a barrier-aware `memclr` and disabling the
       `duffzero` optimization for pointers with types.

    3. Check all uses of unmanaged memory in the runtime to make sure
       it is initialized properly.
       This is particularly important for pools of unmanaged memory
       such as the fixalloc allocator that may reuse memory.

2. Implement concurrent scanning of background mark worker stacks.
   Currently these are placed on the rescan list and *only* scanned
   during mark termination, but we're going to disable the rescan
   list.
   We could arrange for background mark workers to scan their own
   stacks, or explicitly keep track of heap pointers on background
   mark worker stacks.

3. Modify the write barrier to implement the hybrid write barrier and
   the compiler to disable write barrier elision optimizations that
   aren't valid for the hybrid barrier.

4. Disable stack re-scanning by making rescan enqueuing a no-op unless
   a `GODEBUG` variable is set.
   Likewise, disable stack barrier insertion unless this variable is
   set.

5. Use checkmark mode and stress testing to verify that no objects are
   missed.

6. Wait for the Go 1.9 development cycle.

7. Remove stack re-scanning, the rescan list, stack barriers, and the
   `GODEBUG` variable to enable re-scanning.
   Possibly, switch to low-pause stack scans, which can reuse some of
   the stack barrier mechanism.


## Appendix: Mark completion race

Currently, because of a race in the mark completion condition, the
garbage collector can begin mark termination when there is still
available mark work.
This is safe because mark termination will finish draining this work,
but it makes mark termination unbounded.
This also interferes with possible further optimizations that remove
all mark work from mark termination.

Specifically, the following interleaving starts mark termination
without draining all mark work:

Initially `workers` is zero and there is one buffer on the full list.

<table>
<tr><th>Thread 1</th><th>Thread 2</th></tr>
<tr><td><pre>
inc(&workers)
gcDrain(&work)
=> acquires only full buffer
=> adds more pointer to work
work.dispose()
=> returns buffer to full list
n := dec(&workers) [n=0]
if n == 0 && [true]



    full.empty() && [true]
    markrootNext >= markrootJobs { [true]
        startMarkTerm()
}


</pre></td><td><pre>









inc(&workers)
gcDrain(&work)
=> acquires only full buffer




=> adds more pointers to work
...
</pre></td></tr></table>

In this example, a race between observing the `workers` count and
observing the state of the full list causes thread 1 to start mark
termination prematurely.
Simply checking `full.empty()` before decrementing `workers` exhibits
a similar race.

To fix this race, we propose introducing a single atomic non-zero
indicator for the number of non-empty work buffers.
Specifically, this will count the number of work caches that are
caching a non-empty work buffer plus one for a non-empty full list.
Many buffer list operations can be done without modifying this count,
so we believe it will not be highly contended.
If this does prove to be a scalability issue, there are well-known
techniques for scalable non-zero indicators [Ellen '07].


## Appendix: Proof of soundness, completeness, and boundedness

<!-- TODO: Show that the only necessary memory fence is a global
 !-- store/load fence between enabling the write barrier and
 !-- blackening to ensure visibility of all pointers and the write
 !-- barrier flag.
 !-->

This section argues that the hybrid write barrier satisfies the weak
tricolor invariant, and hence is sound in the sense that it does not
collect reachable objects; that it terminates in a bounded number of
steps; and that it eventually collects all unreachable objects, and
hence is complete.
We have also further verified these properties using a
[randomized stateless model](https://github.com/aclements/go-misc/blob/master/go-weave/models/yuasa.go).

The following proofs consider global objects to be a subset of the
heap objects.
This is valid because the write barrier applies equally to global
objects.
Similarly, we omit explicit discussion of nil pointers, since the nil
pointer can be considered an always-black heap object of zero size.

The hybrid write barrier satisfies the *weak tricolor invariant*
[Pirinen '98].
However, rather than directly proving this, we prove that it satisfies
the following *modified tricolor invariant*:

> Any white object pointed to by a black object is grey-protected by a
> heap object (reachable via a chain of white pointers from the grey
> heap object).
> That is, for every *B -> W* edge, there is a path *G -> W₁ -> ⋯ ->
> Wₙ -> W* where *G* is a heap object.

This is identical to the weak tricolor invariant, except that it
requires that the grey-protector is a heap object.
This trivially implies the weak tricolor invariant, but gives us a
stronger basis for induction in the proof.

<!-- Thoughts on how to simplify the proof:

Perhaps define a more general notion of a "heap-protected object",
which is either black, grey, or grey-protected by a heap object.
-->

Lemma 1 establishes a simple property of paths we'll use several
times.

**Lemma 1.** In a path *O₁ -> ⋯ -> Oₙ* where *O₁* is a heap object,
all *Oᵢ* must be heap objects.

**Proof.** Since *O₁* is a heap object and heap objects can only point
to other heap objects, by induction, all *Oᵢ* must be heap objects.
∎

In particular, if some object is grey-protected by a heap object,
every object in the grey-protecting path must be a heap object.

Lemma 2 extends the modified tricolor invariant to white objects that
are *indirectly* reachable from black objects.

**Lemma 2.** If the object graph satisfies the modified tricolor
invariant, then every white object reachable (directly or indirectly)
from a black object is grey-protected by a heap object.

<!-- Alternatively: every object reachable from a black object is
either black, grey, or grey-protected by a heap object. -->

**Proof.** Let *W* be a white object reachable from black object *B*
via simple path *B -> O₁ -> ⋯ -> Oₙ -> W*.
Note that *W* and all *Oᵢ* and must be heap objects because stacks can
only point to themselves (in which case it would not be a simple path)
or heap objects, so *O₁* must be a heap object, and by lemma 1, the
rest of the path must be heap objects.
Without loss of generality, we can assume none of *Oᵢ* are black;
otherwise, we can simply reconsider using the shortest path suffix
that starts with a black object.

If there are no *Oᵢ*, *B* points directly to *W* and the modified
tricolor invariant directly implies that *W* is grey-protected by a
heap object.

If any *Oᵢ* is grey, then *W* is grey-protected by the last grey
object in the path.

Otherwise, all *Oᵢ* are white.
Since *O₁* is a white object pointed to by a black object, *O₁* is
grey-protected by some path *G -> W₁ -> ⋯ -> Wₙ -> O₁* where *G* is a
heap object.
Thus, *W* is grey-protected by *G -> W₁ -> ⋯ -> Wₙ -> O₁ -> ⋯ -> Oₙ ->
W*.
∎

Lemma 3 builds on lemma 2 to establish properties of objects reachable
by goroutines.

**Lemma 3.** If the object graph satisfies the modified tricolor
invariant, then every white object reachable by a black goroutine (a
goroutine whose stack has been scanned) is grey-protected by a heap
object.

**Proof.** Let *W* be a white object reachable by a black goroutine.
If *W* is reachable from the goroutine's stack, then by lemma 2 *W* is
grey-protected by a heap object.
Otherwise, *W* must be reachable from a global *X*.
Let *O* be the last non-white object in the path from *X* to *W* (*O*
must exist because *X* itself is either grey or black).
If *O* is grey, then *O* is a heap object that grey-protects *W*.
Otherwise, *O* is black and by lemma 2, *W* is grey-protected by some
heap object.
∎

Now we're ready to prove that the hybrid write barrier satisfies the
weak tricolor invariant, which implies it is *sound* (it marks all
reachable objects).

**Theorem 1.** The hybrid write barrier satisfies the weak tricolor
invariant.

**Proof.** We first show that the hybrid write barrier satisfies the
modified tricolor invariant.
The proof follows by induction over the operations that affect the
object graph or its coloring.

*Base case.* Initially there are no black objects, so the invariant
holds trivially.

*Write pointer in the heap.* Let *obj.slot := ptr* denote the write,
where *obj* is in the heap, and let *optr* denote the value of
*obj.slot* prior to the write.

Let *W* be a white object pointed to by a black object *B* after the
heap write.
There are two cases:

1. *B ≠ obj*: *W* was pointed to by them same black object *B* before
   the write, and, by assumption, *W* was grey-protected by a path *G
   -> W₁ -> ⋯ -> Wₙ -> W*, where *G* is a heap object.
   If none of these edges are *obj.slot*, then *W* is still protected
   by *G*.
   Otherwise, the path must have included the edge *obj -> optr* and,
   since the write barrier shades *optr*, *W* is grey-protected by
   *optr* after the heap write.

2. *B = obj*: We first establish that *W* was grey-protected before
   the write, which breaks down into two cases:

   1. *W = ptr*: The goroutine must be black, because otherwise the
      write barrier shades *ptr*, so it is not white.
      *ptr* must have been reachable by the goroutine for it to write
      it, so by lemma 3, *ptr* was grey-protected by some heap object
      *G* prior to the write.

   2. *W ≠ ptr*: *B* pointed to *W* before the write and, by
      assumption, *W* was grey-protected by some heap object *G*
      before the write.

   Because *obj* was black before the write, it could not be in the
   grey-protecting path from *G* to *W*, so this write did not affect
   this path, so *W* is still grey-protected by *G*.

*Write pointer in a stack.* Let *stk.slot := ptr* denote the write.

Let *W* be a white object pointed to by a black object *B* after the
stack write.
We first establish that *W* was grey-protected before the stack write,
which breaks down into two cases:

1. *B = stk* and *W = ptr*: *W* may not have been pointed to by a
   black object prior to the stack write (that is, the write may
   create a new *B -> W* edge).
   However, *ptr* must have been reachable by the goroutine, which is
   black (because *B = stk*), so by lemma 3, *W* was grey-protected by
   some heap object *G* prior to the write.

2. Otherwise: *W* was pointed to by the same black object *B* prior to
   the stack write, so, by assumption, *W* was grey-protected by some
   heap object *G* prior to the write.

By lemma 1, none of the objects in the grey-protecting path from heap
object *G* to *W* can be a stack, so the stack write does not modify
this path.
Hence, *W* is still grey-protected after the stack write by *G*.

*Scan heap object.* Let *obj* denote the scanned object.
Let *W* be an object pointed to by a black object *B* after the scan.
*B* cannot be *obj* because immediately after the scan, *obj* does not
 point to any white objects.
Thus, *B* must have been black and pointed to *W* before the scan as
well, so, by assumption, *W* was grey-protected by a path *G -> W₁ ->
⋯ -> Wₙ -> W*, where *G* is a heap object.
If some *Wᵢ* was an object pointed to by *obj*, then *W* is
grey-protected by *Wᵢ* after the scan.
Otherwise, *W* is still grey-protected by *G*.

*Stack scan.* This case is symmetric with scanning a heap object.

<!-- Old direct proof of stack scans:

*Stack scan.* Let *W* be an object pointed to by a black object *B*
 after the stack scan.
Even though scanning stack *stk* blackens *stk*, *B* cannot be *stk*
because scanning greys all objects directly referenced by *stk*.
Hence, *W* was pointed to by the same black object *B* before the
stack scan, and by assumption was grey-protected by some path *G -> W₁
-> ⋯ -> Wₙ -> W* where *G* is a heap object.
By lemma 1, none of the objects in the grey-protecting path can be a
stack, so after the stack scan, *W* is either still grey-protected by
*G*, or some *Wᵢ* was greyed by the stack scan and *W* is now
grey-protected by *Wᵢ*.
-->

*Allocate an object.* Since new objects are allocated black and point
to nothing, the invariant trivially holds across allocation.

*Create a stack.* This case is symmetric with object allocation
because new stacks start out empty and hence are trivially black.

This completes the induction cases and shows that the hybrid write
barrier satisfies the modified tricolor invariant.
Since the modified tricolor invariant trivially implies the weak
tricolor invariant, the hybrid write barrier satisfies the weak
tricolor invariant.
∎

The garbage collector is also *bounded*, meaning it eventually
terminates.

**Theorem 2.** A garbage collector using the hybrid write barrier
terminates in a finite number of marking steps.

**Proof.** We observe that objects progress strictly from white to
grey to black and, because new objects (including stacks) are
allocated black, the total marking work is bounded by the number of
objects at the beginning of garbage collection, which is finite.
∎

Finally, the garbage collector is also *complete*, in the sense that
it eventually collects all unreachable objects.
This is trivial from the fact that the garbage collector cannot mark
any objects that are not reachable when the mark phase starts.


## References

[Auerbach '07] J. Auerbach, D. F. Bacon, B. Blainey, P. Cheng, M.
Dawson, M. Fulton, D. Grove, D. Hart, and M. Stoodley. Design and
implementation of a comprehensive real-time java virtual machine. In
*Proceedings of the 7th ACM & IEEE international conference on
Embedded software (EMSOFT '07)*, 249–258, 2007.

[Dijkstra '78] E. W. Dijkstra, L. Lamport, A. J. Martin, C. S.
Scholten, and E. F. Steffens. On-the-fly garbage collection: An
exercise in cooperation. *Communications of the ACM*, 21(11), 966–975,
1978.

[Ellen '07] F. Ellen, Y. Lev, V. Luchango, and M. Moir. SNZI: Scalable
nonzero indicators. In *Proceedings of the 26th ACM SIGACT-SIGOPS
Symposium on Principles of Distributed Computing*, Portland, OR,
August 2007.

[Hudson '97] R. L. Hudson, R. Morrison, J. E. B. Moss, and D. S.
Munro. Garbage collecting the world: One car at a time. In *ACM
SIGPLAN Notices* 32(10):162–175, October 1997.

[Pirinen '98] P. P. Pirinen. Barrier techniques for incremental
tracing. In *ACM SIGPLAN Notices*, 34(3), 20–25, October 1998.

[Steele '75] G. L. Steele Jr. Multiprocessing compactifying garbage
collection. *Communications of the ACM*, 18(9), 495–508, 1975.

[Yuasa '90] T. Yuasa. Real-time garbage collection on general-purpose
machines. *Journal of Systems and Software*, 11(3):181–198, 1990.
