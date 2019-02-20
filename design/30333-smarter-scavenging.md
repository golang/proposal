# Proposal: Smarter Scavenging

Author(s): Michael Knyszek \<mknyszek@google.com\> Last Updated: 2019-02-20

## Motivation & Purpose

Out-of-memory errors (OOMs) have long been a pain-point for Go applications.
A class of these errors come from the same underlying cause: a temporary spike
in memory causes the Go runtime to grow the heap, but it takes a very long time
(on the order of minutes) to return that unneeded memory back to the system.

The system can end up killing the application in many situations, such as if
the system has no swap space or if system monitors count this space against
your application.
In addition, if this additional space is counted against your application, you
end up paying more for memory when you don’t really need it.

The Go runtime does have internal mechanisms to help deal with this, but they
don’t react to changes in the application promptly enough.
The way users solve this problem today is through a runtime library function
called `debug.FreeOSMemory`.
`debug.FreeOSMemory` performs a GC and subsequently returns all unallocated
memory back to the underlying system.
However, this solution is very heavyweight:
* Returning all free memory back to the underlying system at once is expensive,
  and can lead to latency spikes as it holds the heap lock through the whole
  process.
* It’s an invasive solution: you need to modify your code to call it when you
  need it.
* Reusing free chunks of memory becomes more expensive. On UNIX-y systems that
  means an extra page fault (which is surprisingly expensive on some systems).

The purpose of this document is to propose we replace the existing mechanisms in
the runtime with something stronger that responds promptly to the memory
requirements of Go applications, ensuring the application is only charged for as
much as it needs to remain performant.

## Background

### Scavenging

Dynamic memory allocators typically obtain memory from the operating system by
requesting for it to be mapped into their virtual address space.
Sometimes this space ends up unused, and modern operating systems provide a way
to tell the OS that certain virtual memory address regions won’t be used
without unmapping them. This means the physical memory backing those regions
may be taken back by the OS and used elsewhere.
We in the Go runtime refer to this technique as “scavenging”.

Scavenging is especially useful in dealing with page-level external
fragmentation, since we can give these fragments back to the OS, reducing the
process’ resident set size (RSS).
That is, the amount of memory that is backed by physical memory in the
application’s address space.

### Go 1.11

As of Go 1.11, the only scavenging process in the Go runtime was a periodic
scavenger which runs every 2.5 minutes.
This scavenger combs over all the free spans in the heap and scavenge them if
they have been unused for at least 5 minutes.
When the runtime coalesced spans, it would track how much of the new span was
scavenged.

While this simple technique is surprisingly effective for long-running
applications, the peak RSS of an application can end up wildly exaggerated in
many circumstances, even though the application’s peak in-use memory is
significantly smaller.
The periodic scavenger just does not react quickly enough to changes in the
application’s memory usage.

### Go 1.12

As of Go 1.12, in addition to the periodic scavenger, the Go runtime
also performs heap-growth scavenging.
On each heap growth up to N bytes of the largest spans are scavenged, where N
is the amount of bytes the heap grew by.
The idea here is to “pay back” the cost of a heap growth.
This technique helped to reduce the peak RSS of some applications.

#### Note on Span Coalescing Rules

As part of the Go 1.12 release, the span coalescing rules had changed such that
scavenged and unscavenged spans would not coalesce.

Earlier in the Go 1.12 cycle a choice was made to coalesce the two different
kinds of spans by scavenging them, but this turned out to be far too aggressive
in practice since most spans would become scavenged over time.
This policy was especially costly if scavenging was particularly expensive on a
given platform.

In addition to avoiding the problem above, there’s a key reason why not to merge
across this boundary: if most spans end up scavenged over time, then we do not
have the fine-grained control we need over memory to create good policies and
mechanisms for scavenging memory.

### Prior Art

For scavenging, we look to C/C++ allocators which have a much richer history of
scavenging memory than allocators for managed languages. For example, the
HotSpot VM just started scavenging memory, and even then its policies are very
conservative, [only returning memory during low application
activity](https://openjdk.java.net/jeps/346).
The [Shenandoah
collector](https://mail.openjdk.java.net/pipermail/hotspot-gc-dev/2018-June/022203.html)
has had this functionality for a little while, but it just does the same thing
Go 1.11 did, as far as I can tell.

For the purposes of this document, we will focus our comparisons on
[jemalloc](https://jemalloc.net), which appears to me to be the state-of-the-art
in scavenging.

## Goals

The goal in scavenging smarter is two-fold:
* Reduce the average and peak RSS of Go applications.
* Minimize the CPU impact of keeping the RSS low.

The two goals go hand-in-hand. On the one hand, you want to keep the RSS of the
application as close to its in-use memory usage as possible.
On the other hand, doing so is expensive in terms of CPU time, having to make
syscalls and handle page faults.
If we’re too aggressive and scavenge every free space we have, then on every
span allocation we effectively incur a hard page fault (or invoke a syscall),
and we’re calling a syscall on every span free.

The ideal scenario, in my view, is that the RSS of the application “tracks” the
peak in-use memory over time.
* We should keep the RSS close to the actual in-use heap, but leave enough of a
  buffer such that the application has a pool of unscavenged memory to allocate
  from.
* We should try to smooth over fast and transient changes in heap size.

The goal of this proposal is to improve the Go runtime’s scavenging mechanisms
such that it exhibits the behavior shown above.
Compared with today’s implementation, this behavior should reduce the average
overall RSS of most Go applications with minimal impact on performance.

## Proposal

Three questions represent the key policy decisions that describe a memory
scavenging system.
1. At what rate is memory scavenged?
1. How much memory should we retain (not scavenge)?
1. Which memory should we scavenge?

I propose that for the Go runtime, we:
1. Scavenge at a rate proportional to the rate at which the application is
   allocating memory.
1. Retain some constant times the peak heap goal over the last `N` GCs.
1. Scavenge the unscavenged spans with the highest base addresses first.

Additionally, I propose we change the span allocation policy to prefer
unscavenged spans over scavenged spans, and to be first-fit rather than
best-fit.

## Rationale

### How much memory should we retain?

As part of our goal to keep the program’s reported RSS to a minimum, we ideally
want to scavenge as many pages as it takes to track the program’s in-use memory.

However, there’s a performance trade-off in tracking the program’s in-use memory
too closely.
For example, if the heap very suddenly shrinks but then grows again, there's a
significant cost in terms of syscalls and page faults incurred.
On the other hand, if we scavenge too passively, then the program’s reported
RSS may be inflated significantly.

This question is difficult to answer in general, because generally allocators
can not predict the future behavior of the application.
jemalloc avoids this question entirely, relying solely on having a good (albeit
complicated) answer to the “rate” question (see next section).

But, as Austin mentioned in
[golang/go#16930](https://github.com/golang/go/issues/16930), Go has an
advantage over C/C++ allocators in this respect.
The Go runtime knows that before the next GC, the heap will grow to the heap
goal.

This suggests that between GCs there may be some body of free memory that one
can drop with relatively few consequences.
Thus, I propose the following heuristic, borrowed from #16930: retain
`C*max(heap goal, max(heap goal over the last N GCs))` bytes of memory, and
scavenge the rest.
For a full rationale of the formula, see
[golang/go#16930](https://github.com/golang/go/issues/16930).
`C` is the "steady state variance factor" mentioned in #16930.
`C` also represents a pool of unscavenged memory in addition to that guaranteed
by the heap goal which the application may allocate from, increasing the
probability that a given allocation will be satisfied by unscavenged memory and
thus not incur a page fault on access.
The initial proposed values for `C` and `N` are 1.125 (9/8) and 16,
respectively.

### At what rate is memory scavenged?

In order to have the application’s RSS track the amount of heap space it’s
actually using over time, we want to be able to grow and shrink the RSS at a
rate proportional to how the in-use memory of the application is growing and
shrinking, with smoothing.

When it comes to growth, that problem is generally solved.
The application may cause the heap to grow, and the allocator will map new,
unscavenged memory in response.
Or, similarly, the application may allocate out of scavenged memory.

On the flip side, figuring out the rate at which to shrink the RSS is harder.
Ideally the rate is “as soon as possible”, but unfortunately this could result
in latency issues.

jemalloc solves this by having its memory “decay” according to a sigmoid-like
curve.

Each contiguous extent of allocable memory decays according to a
globally-defined tunable rate, and how many of them end up available for
scavenging is governed by a sigmoid-like function.

The result of this policy is that the heap shrinks in sigmoidal fashion:
carefully turning down to smooth out noise in in-use memory but at some point
committing and scavenging lots of memory at once.
While this strategy works well in general, it’s still prone to making bad
decisions in certain cases, and relies on the developer to tune the decay rate
for the application.
Furthermore, I believe that this design by jemalloc was a direct result of not
knowing anything about the future state of the heap.

As mentioned earlier, the Go runtime does know that the heap will grow to the
heap goal.

Thus, I propose a *proportional scavenging policy*, in the same vein as the
runtime’s proportional sweeping implementation.
Because of how Go’s GC is paced, we know that the heap will grow to the heap
goal in the future and we can measure how quickly it’s approaching that goal by
seeing how quickly it’s allocating.
Between GCs, I propose that the scavenger do its best to scavenge down to the
scavenge goal by the time the next GC comes in.

The proportional scavenger will run asynchronously, much like the Go runtime’s
background sweeper, but will be more aggressive, batching more scavenging work
if it finds itself falling behind.

One issue with this design is situations where the application goes idle.
In that case, the scavenger will do at least one unit of work (scavenge one
span) on wake-up to ensure it makes progress as long as there's work to be
done.

Another issue with having the scavenger be fully asynchronous is that the
application could actively create more work for the scavenger to do.
There are two ways this could happen:
* An allocation causes the heap to grow.
* An allocation is satisfied using scavenged memory.
The former case is already eliminated by heap-growth scavenging.
The latter case may be eliminated by scavenging memory when we allocate from
scavenged memory, which as of Go 1.12 we also already do.

The additional scavenging during allocation could prove expensive, given the
costs associated with the madvise syscall.
I believe we can dramatically reduce the amount of times this is necessary by
reusing unscavenged memory before scavenged memory when allocating.
Thus, where currently we try to find the best-fit span across both scavenged
and unscavenged spans, I propose we *prefer unscavenged to scavenged spans
during allocation*.

The benefits of this policy are that unscavenged pages are now significantly
more likely to be reused.

### Which memory should we scavenge?

At first, this question appears to be a lot like trying to pick an eviction
policy for caches or a page replacement policy.
The naive answer is thus to favor least-recently used memory, since there’s a
cost to allocating scavenged memory (much like a cache miss).
Indeed, this is the route which jemalloc takes.

However unlike cache eviction policies or page replacement policies, which
cannot make any assumptions about memory accesses, scavenging policy is deeply
tied to allocation policy.
Fundamentally, we want to scavenge the memory that the allocator is least
likely to pick in the future.

For a best-fit allocation policy, one idea (the current one) is to pick the
largest contiguous chunks of memory first for scavenging.

This scavenging
policy does well and picks the least likely to be reused spans assuming that
most allocations are small.
If most allocations are small, then smaller contiguous free spaces will be used
up first, and larger ones may be scavenged with little consequence.
Consider also that even though the cost of scavenging memory is generally
proportional to how many physical pages are scavenged at once, scavenging
memory still has fixed costs that may be amortized by picking larger spans
first.
In essence, by making fewer madvise syscalls, we pay the cost of the syscall
itself less often.
In the cases where most span allocations aren’t small, however, we’ll be making
the same number of madvise syscalls but we will incur many more page faults.

Thus, I propose a more robust alternative: *change the Go runtime’s span
allocation policy to be first-fit, rather than best-fit*.
Address-ordered first-fit allocation policies generally perform as well as
best-fit in practice when it comes to fragmentation [Johnstone98], a claim
which I verified holds true for the Go runtime by simulating a large span
allocation trace.

Furthermore, I propose we then *scavenge the spans with the highest base address
first*.
The advantage of a first-fit allocation policy here is that we know something
about which chunks of memory will actually be chosen, which leads us to a
sensible scavenging policy.

First-fit allocation paired with scavenging the "last" spans has a clear
preference for taking spans which are less likely to be used, even if the
assumption that most allocations are small does not hold.
Therefore this policy is more robust than the current one and should therefore
incur fewer page faults overall.

There’s still the more general question of how performant this policy will be.
First and foremost, efficient implementations of first fit-allocation exist (see
Appendix).
Secondly, a valid concern with this new policy is that it no longer amortizes
the fixed costs of scavenging because it may choose smaller spans to scavenge,
thereby making more syscalls to scavenge the same amount of memory.

In the case where most span allocations are small, a first-fit allocation
policy actually works to our advantage since it tends to aggregate smaller
fragments at lower addresses and larger fragments at higher addresses
[Wilson95].
In this case I expect performance to be on par with best-fit
allocation and largest-spans-first scavenging. Where this assumption does not
hold true, it’s true that this new policy may end up making more syscalls.
However, the sum total of the marginal costs in scavenging generally outweigh
the fixed costs.
The one exception here is huge pages, which have very tiny marginal costs, but
it's unclear how good of a job we or anyone else is doing with keeping huge
pages intact, and this demands more research that is outside the scope of this
design.
Overall, I suspect any performance degradation will be minimal.

## Implementation

Michael Knyszek will implement this functionality.
The rough plan will be as follows:
1. Remove the existing periodic scavenger.
1. Track the last N heap goals, as in the prompt scavenging proposal.
1. Add a background goroutine which performs proportional scavenging.
1. Modify and augment the treap implementation to efficiently implement first-fit
   allocation.
   * This step will simultaneously change the policy to pick higher addresses
     first without any additional work.
   * Add tests to ensure the augmented treap works as intended.

## Other Considerations

*Heap Lock Contention.*
Currently the scavenging process happens with the heap lock held.
With each scavenging operation taking on the order of 10µs, this can add up
fast and block progress.
The way jemalloc combats this is to give up the heap lock when actually making
any scavenging-related syscalls.
Unfortunately this comes with the caveat that any spans currently being
scavenged are not available for allocation, which could cause more heap growths
and discourage reuse of existing virtual address space.
Also, a process’s memory map is protected by a single coarse-grained read-write
lock on many modern operating systems and writers typically need to queue
behind readers.
Since scavengers are usually readers of this lock and heap growth is a writer
on this lock it may mean that letting go of the heap lock doesn’t help so much.

## Appendix: Implementing a First-fit Data Structure

We can efficiently find the lowest-address available chunk of memory that also
satisfies the allocation request by modifying and augmenting any existing
balanced binary tree.

For brevity we’ll focus just on the treap implementation in the runtime here.
The technique shown here is similar to that found in [Rezaei00].
The recipe for transforming out best-fit treap into a first-fit treap consists
of the following steps:

First, modify the existing treap implementation to sort by a span’s base
address.

Next, attach a new field to each binary tree node called maxPages.
This field represents the maximum size in 8 KiB pages of a span in the subtree
rooted at that node.

For a leaf node, maxPages is always equal to the node’s span’s
length.
This invariant is maintained every time the tree changes. For most balanced
trees, the tree may change in one of three ways: insertion, removal, and tree
rotations.

Tree rotations are simple: one only needs to update the two rotated nodes by
checking their span’s size and comparing it with maxPages of their left and
right subtrees, taking the maximum (effectively just recomputing maxPages
non-recursively).

A newly-inserted node in a treap is always a leaf, so that case is handled.
Once we insert it, however, any number of subtrees from the parent may now have
a different maxPages, so we start from the newly-inserted node and walk up the
tree, updating maxPages.
Once we reach a point where maxPages does not change, we may stop.
Then we may rotate the leaf into place. At most, we travel the height of the
tree in this update, but usually we’ll travel less.

On removal, a treap uses rotations to make the node to-be-deleted a leaf. Once
the node becomes a leaf, we remove it, and then update its ancestors starting
from its new parent.
We may stop, as before, when maxPages is no longer affected by the change.

Finally, we modify the algorithm which finds a suitable span to use for
allocation, or returns nil if one is not found.
To find the first-fit span in the tree we leverage maxPages in the following
algorithm (in pseudo-Go pseudocode):

```
1  func Find(root, pages):
2    t = root
3    for t != nil:
4      if t.left != nil and t.left.maxPages >= pages:
5        t = t.left
6      else if t.span.pages >= pages:
7        return t.span
8      else t.right != nil and t.right.maxPages >= pages:
9        t = t.right
10     else:
11       return nil
```

By only going down paths where we’re sure there’s at least one span that can
satisfy the allocation, we ensure that the algorithm always returns a span of
at least `pages` in size.

Because we prefer going left if possible (line 4) over taking the current
node’s span (line 6) over going right if possible (line 8), we ensure that we
allocate the node with the lowest base address.

The case where we cannot go left, cannot take the current node, and cannot go
right (line 10) should only be possible at the root if maxPages is managed
properly.
That is, just by looking at the root, one can tell whether an allocation
request is satisfiable.

## References

Johnstone, Mark S., and Paul R. Wilson. "The Memory Fragmentation Problem:
Solved?" Proceedings of the First International Symposium on Memory Management -
ISMM 98, 1998. doi:10.1145/286860.286864.

M. Rezaei and K. M. Kavi, "A new implementation technique for memory
management," Proceedings of the IEEE SoutheastCon 2000. 'Preparing for The New
Millennium' (Cat.No.00CH37105), Nashville, TN, USA, 2000, pp. 332-339.
doi:10.1109/SECON.2000.845587

Wilson, Paul R., Mark S. Johnstone, Michael Neely, and David Boles. "Dynamic
Storage Allocation: A Survey and Critical Review." Memory Management Lecture
Notes in Computer Science, 1995, 1-116. doi:10.1007/3-540-60368-9_19.
