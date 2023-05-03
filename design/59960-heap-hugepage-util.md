# A more hugepage-aware Go heap

Authors: Michael Knyszek, Michael Pratt

## Background

[Transparent huge pages (THP) admin
guide](https://www.kernel.org/doc/html/latest/admin-guide/mm/transhuge.html).

[Go scavenging
policy](30333-smarter-scavenging.md#which-memory-should-we-scavenge).
(Implementation details are out-of-date, but linked policy is relevant.)

[THP flag behavior](#appendix_thp-flag-behavior).

## Motivation

Currently, Go's hugepage-related policies [do not play well
together](https://github.com/golang/go/issues/55328) and have bit-rotted.[^1]
The result is that the memory regions the Go runtime chooses to mark as
`MADV_NOHUGEPAGE` and `MADV_HUGEPAGE` are somewhat haphazard, resulting in
memory overuse for small heaps.
The memory overuse is upwards of 40% memory overhead in some cases.
Turning off huge pages entirely fixes the problem, but leaves CPU performance on
the table.
This policy also means large heaps might have dense sections that are
erroneously mapped as `MADV_NOHUGEPAGE`, costing up to 1% throughput.

The goal of this work is to eliminate this overhead for small heaps while
improving huge page utilization for large heaps.

[^1]: [Large allocations](https://cs.opensource.google/go/go/+/master:src/runtime/mheap.go;l=1344;drc=c70fd4b30aba5db2df7b5f6b0833c62b909f50eb)
    will force [a call to `MADV_HUGEPAGE` for any aligned huge pages
    within](https://cs.opensource.google/go/go/+/master:src/runtime/mem_linux.go;l=148;drc=9839668b5619f45e293dd40339bf0ac614ea6bee),
    while small allocations tend to leave memory in an undetermined state for
    huge pages.
    The scavenger will try to release entire aligned hugepages at a time.
    Also, when any memory is released, [we `MADV_NOHUGEPAGE` any aligned pages
    in the range we
    release](https://cs.opensource.google/go/go/+/master:src/runtime/mem_linux.go;l=40;drc=9839668b5619f45e293dd40339bf0ac614ea6bee).
    However, the scavenger will [only release 64 KiB at a time unless it finds
    an aligned huge page to
    release](https://cs.opensource.google/go/go/+/master:src/runtime/mgcscavenge.go;l=564;drc=c70fd4b30aba5db2df7b5f6b0833c62b909f50eb),
    and even then it'll [only `MADV_NOHUGEPAGE` the corresponding huge pages if
    the region it's scavenging crosses a huge page
    boundary](https://cs.opensource.google/go/go/+/master:src/runtime/mem_linux.go;l=70;drc=9839668b5619f45e293dd40339bf0ac614ea6bee).

## Proposal

One key insight in the design of the scavenger is that the runtime always has a
good idea of how much memory will be used soon: the total heap footprint for a
GC cycle is determined by the heap goal. [^2]

[^2]: The runtime also has a first-fit page allocator so that the scavenger can
    take pages from the high addresses in the heap, again to reduce the chance
    of conflict.
    The scavenger tries to return memory to the OS such that it leaves enough
    paged-in memory around to reach the heap goal (adjusted for fragmentation
    within spans and a 10% buffer for fragmentation outside of spans, or capped
    by the memory limit).
    The purpose behind this is to reduce the chance that the scavenger will
    return memory to the OS that will be used soon.

Indeed, by [tracing page allocations and watching page state over
time](#appendix_page-traces) we can see that Go heaps tend to get very dense
toward the end of a GC cycle; this makes all of that memory a decent candidate
for huge pages from the perspective of fragmentation.
However, it's also clear this density fluctuates significantly within a GC
cycle.

Therefore, I propose the following policy:
1. All new memory is initially marked as `MADV_HUGEPAGE` with the expectation
   that it will be used.
1. Before the scavenger releases pages in an aligned 4 MiB region of memory [^3]
   it [first](#appendix_thp-flag-behavior) marks it as `MADV_NOHUGEPAGE` if it
   isn't already marked as such.
    - If `max_ptes_none` is 0, then skip this step.
1. Aligned 4 MiB regions of memory are only available to scavenge if they
   weren't at least 96% [^4] full at the end of the last GC cycle. [^5]
    - Scavenging for `GOMEMLIMIT` or `runtime/debug.FreeOSMemory` ignores this
      rule.
1. Any aligned 4 MiB region of memory that exceeds 96% occupancy is immediately
   marked as `MADV_HUGEPAGE`.
    - If `max_ptes_none` is 0, then use `MADV_COLLAPSE` instead, if available.
    - Memory scavenged for `GOMEMLIMIT` or `runtime/debug.FreeOSMemory` is not
      marked `MADV_HUGEPAGE` until the next allocation that causes this
      condition after the end of the current GC cycle. [^6]

[^3]: 4 MiB doesn't align with linux/amd64 huge page sizes, but is a very
    convenient number of the runtime because the page allocator manages memory
    in 4 MiB chunks.

[^4]: The bar for explicit (non-default) backing by huge pages must be very
    high.
    The main issue is the default value of
    `/sys/kernel/mm/transparent_hugepage/defrag` on Linux: it forces regions
    marked as `MADV_HUGEPAGE` to be immediately backed, stalling in the kernel
    until it can compact and rearrange things to provide a huge page.
    Meanwhile the combination of `MADV_NOHUGEPAGE` and `MADV_DONTNEED` does the
    opposite.
    Switching between these two states often creates really expensive churn.

[^5]: Note that `runtime/debug.FreeOSMemory` and the mechanism to maintain
    `GOMEMLIMIT` must still be able to release all memory to be effective.
    For that reason, this rule does not apply to those two situations.
    Basically, these cases get to skip waiting until the end of the GC cycle,
    optimistically assuming that memory won't be used.

[^6]: It might happen that the wrong memory was scavenged (memory that soon
    after exceeds 96% occupancy).
    This delay helps reduce churn.

The goal of these changes is to ensure that when sparse regions of the heap have
their memory returned to the OS, it stays that way regardless of
`max_ptes_none`.
Meanwhile, the policy avoids expensive churn by delaying the release of pages
that were part of dense memory regions by at least a full GC cycle.

Note that there's potentially quite a lot of hysteresis here, which could impact
memory reclaim for, for example, a brief memory spike followed by a long-lived
idle low-memory state.
In the worst case, the time between GC cycles is 2 minutes, and the scavenger's
slowest return rate is ~256 MiB/sec. [^7] I suspect this isn't slow enough to be
a problem in practice.
Furthermore, `GOMEMLIMIT` can still be employed to maintain a memory maximum.

[^7]: The scavenger is much more aggressive than it once was, targeting 1% of
    total CPU usage.
    Spending 1% of one CPU core in 2018 on `MADV_DONTNEED` meant roughly 8 KiB
    released per millisecond in the worst case.
    For a `GOMAXPROCS=32` process, this worst case is now approximately 256 KiB
    per millisecond.
    In the best case, wherein the scavenger can identify whole unreleased huge
    pages, it would release 2 MiB per millisecond in 2018, so 64 MiB per
    millisecond today.

## Alternative attempts

Initially, I attempted a design where all heap memory up to the heap goal
(address-ordered) is marked as `MADV_HUGEPAGE` and ineligible for scavenging.
The rest is always eligible for scavenging, and the scavenger marks that memory
as `MADV_NOHUGEPAGE`.

This approach had a few problems:
1. The heap goal tends to fluctuate, creating churn at the boundary.
1. When the heap is actively growing, the aftermath of this churn actually ends
   up in the middle of the fully-grown heap, as the scavenger works on memory
   beyond the boundary in between GC cycles.
1. Any fragmentation that does exist in the middle of the heap, for example if
   most allocations are large, is never looked at by the scavenger.

I also tried a simple heuristic to turn off the scavenger when it looks like the
heap is growing, but not all heaps grow monotonically, so a small amount of
churn still occurred.
It's difficult to come up with a good heuristic without assuming monotonicity.

My next attempt was more direct: mark high density chunks as `MADV_HUGEPAGE`,
and allow low density chunks to be scavenged and set as `MADV_NOHUGEPAGE`.
A chunk would become high density if it was observed to have at least 80%
occupancy, and would later switch back to low density if it had less than 20%
occupancy.
This gap existed for hysteresis to reduce churn.
Unfortunately, this also didn't work: GC-heavy programs often have memory
regions that go from extremely low (near 0%) occupancy to 100% within a single
GC cycle, creating a lot of churn.

The design above is ultimately a combination of these two designs: assume that
the heap gets generally dense within a GC cycle, but handle it on a
chunk-by-chunk basis.

Where all this differs from other huge page efforts, such as [what TCMalloc
did](https://google.github.io/tcmalloc/temeraire.html), is the lack of
bin-packing of allocated memory in huge pages (which is really the majority and
key part of the design).
Bin-packing provides the benefit of increasing the likelihood that an entire
huge page will be free by putting new memory in existing huge pages over some
global policy that may put it anywhere like "best-fit."
This not only improves the efficiency of releasing memory, but makes the overall
footprint smaller due to less fragmentation.

This is unlikely to be that useful for Go since Go's heap already, at least
transiently, gets very dense.
Another thing that gets in the way of doing the same kind of bin-packing for Go
is that the allocator's slow path gets hit much harder than TCMalloc's slow
path.
The reason for this boils down to the GC memory reuse pattern (essentially, FIFO
vs. LIFO reuse).
Slowdowns in this path will likely create scalability problems.

## Appendix: THP flag behavior

Whether or not pages are eligible for THP is controlled by a combination of
settings:

`/sys/kernel/mm/transparent_hugepage/enabled`: system-wide control, possible
values:
- `never`: THP disabled
- `madvise`: Only pages with `MADV_HUGEPAGE` are eligible
- `always`: All pages are eligible, unless marked `MADV_NOHUGEPAGE`

`prctl(PR_SET_THP_DISABLE)`: process-wide control to disable THP

`madvise`: per-mapping control, possible values:
- `MADV_NOHUGEPAGE`: mapping not eligible for THP
  - Note that existing huge pages will not be split if this flag is set.
- `MADV_HUGEPAGE`: mapping eligible for THP unless there is a process- or
  system-wide disable.
- Unset: mapping eligible for THP if system-wide control is set to “always”.

`/sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none`: system-wide
control that specifies how many extra small pages can be allocated when
collapsing a group of pages into a huge page.
In other words, how many small pages in a candidate huge page can be
not-faulted-in or faulted-in zero pages.

`MADV_DONTNEED` on a smaller range within a huge page will split the huge page
to zero the range.
However, the full huge page range will still be immediately eligible for
coalescing by `khugepaged` if `max_ptes_none > 0`, which is true for the default
open source Linux configuration.
Thus to both disable future THP and split an existing huge page race-free, you
must first set `MADV_NOHUGEPAGE` and then call `MADV_DONTNEED`.

Another consideration is the newly-upstreamed `MADV_COLLAPSE`, which collapses
memory regions into huge pages unconditionally.
`MADV_DONTNEED` can then used to break them up.
This scheme represents effectively complete control over huge pages, provided
`khugepaged` doesn't coalesce pages in a way that undoes the `MADV_DONTNEED`.
(For example by setting `max_ptes_none` to zero.)

## Appendix: Page traces

To investigate this issue I built a
[low-overhead](https://perf.golang.org/search?q=upload:20221024.9) [page event
tracer](https://go.dev/cl/444157) and [visualization
utility](https://go.dev/cl/444158) to check assumptions of application and GC
behavior.
Below are a bunch of traces and conclusions from them.
- [Tile38 K-Nearest benchmark](./59960/tile38.png): GC-heavy benchmark.
  Note the fluctuation between very low occupancy and very high occupancy.
  During a single GC cycle, the page heap gets at least transiently very dense.
  This benchmark caused me the most trouble when trying out ideas.
- [Go compiler building a massive package](./59960/compiler.png): Note again the
  high density.
