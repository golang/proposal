# Proposal: Goroutine leak detection via garbage collection

Author(s): Georgian-Vlad Saioc (vsaioc@uber.com), Milind Chabbi (milind@uber.com)

Last updated: 14 Aug 2025

Discussion at [issue #74609](https://go.dev/issue/74609).

## Abstract

This proposal outlines a dynamic technique for detecting goroutine leaks within Go programs. It leverages the existing marking phase of the Go garbage collector (GC) to find goroutines blocked over concurrency primitives that are not reachable in memory from goroutines that may still be runnable.

## Background

Due to its concurrency features (lightweight goroutines, message passing), Go is particularly susceptible to concurrency bugs known as _goroutine leaks_ (also known as _partial deadlocks_ in literature [1](https://dl.acm.org/doi/10.1145/3676641.3715990)).
Unlike global deadlocks (wherein all goroutines are blocked) that halt an entire application, goroutine leaks occur whenever a goroutine is blocked indefinitely, e.g., by reading from a channel that no other goroutine has access to, but other running goroutines keep the program operational.
This issue can lead to (a) severe memory leaks, and (b) performance penalties, by over-burdening the GC with the task to mark useless memory.
Goroutine leaks may be notoriously difficult to debug; in some cases even their presence alone is difficult to discern, even with otherwise thorough diagnostic information, e.g., memory and goroutine profiles. This makes tooling capable of detecting their presence valuable to the Go ecosystem.

## Proposal

The change involves several modifications to key points during phases of the GC cycle, as follows:
1. Mark root preparation: initially treat only _runnable_ goroutines as mark roots (the regular GC treats _all_ goroutines as roots)
2. Proceed to mark memory from this set of roots.
3. Once all reachable memory has been marked, check whether any unmarked goroutines are blocked at operations over any concurrency primitives that have been marked as a result of step 2.
4. Any such goroutines are considered _eventually runnable_, and must be treated as mark roots. Resume marking from step 2 with the new roots.
5. Once a fixed point over reachable memory is computed, report any goroutines that are not treated as roots as leaks; resume from step 2 one last time with leaked goroutines as mark roots to ensure that all reachable memory is marked, like in the regular GC.
6. Sweeping proceeds as normal.

For an additional in-depth description of the theoretical underpinnings, refer [here](https://dl.acm.org/doi/10.1145/3676641.3715990).

## Rationale

The proposal expands the developer toolset when it comes to identifying goroutine leaks, especially in long-running systems with complex non-deterministic behavior.
The advantage of this approach over other goroutine leak detection techniques is that it can be leveraged, with a minimal performance cost, in regular Go systems, e.g., production services.
It is also theoretically sound, i.e., there are no false positives.
Its primary limitation is that its effectiveness is reduced the more heap resources are over-exposed in memory, i.e., pair-wise reachable.

## Compatibility

The feature is outwards-compatible with any Go program.
Changes are strictly internal, and any extensions are only accessible on an opt-in basis via additional APIs, in this case by adding a new profile.

## Implementation

A working prototype is available at [PR #74622](https://github.com/golang/go/pull/74622).

In this section we discuss implementation miscellanea.

**Opting in via profiling:** goroutine leak detection behaviour is triggered on-demand via profiling.
An additional profile type, `"goroutineleak"`, is now available. Attempting to extract it will perform the following:

1. Queue a leak detecting GC cycle and wait for it to complete.
2. Extract a goroutine profile.
3. Filter for goroutines with a leaked status, if `debug < 2`;
alternatively, get a full stack dump of all goroutines, if `debug >=2`.
4. Output the results.

Otherwise, the GC preserves regular behavior, with a few exceptions described in this section.

**Temporary experimental flag:** in order to avoid most performance penalties, the proposal is currently only enabled via the experimental flag `goroutineleakfindergc`.

**Hiding pointers from the GC:** it is essential for the approach that certain pointers are only conditionally traced by the GC.
In the current implementation, this is achieved via **maybe-traceable pointers**, expressed as type `maybeTraceablePtr` in the runtime.

A maybe-traceable pointer value is a pair between a `unsafe.Pointer` and `uintptr` value, stored at fields `.vp` and `.vu`, respectively, within the `maybeTraceablePtr` type.
A maybe-traceable pointer has one of three states:

1) **Unset:** both `.vp` and `.vu` are zero values. This is homologous to `nil`.
2) **Traceable:** both `.vp` and `.vu` are set, where both point to the same address.
3) **Untraceable:** `.vu` is set to the address that is referenced, but `.vp` is set to `nil`, such that the GC does not automatically trace it when scanning the object embedding the maybe-traceable pointer.

Maybe-traceable pointers are then provided with a set of methods for setting and unsetting them, that guarantee certain invariants at runtime, e.g., that if `.vp` and `.vu` are set, they point to the same address.

The use of maybe-traceable pointers is only required for `*sudog` objects, specifically for the `.elem` and `.hchan` fields.
This prevents the GC from inadvertendly marking channels that have not yet been deemed reachable in memory via eventually runnable goroutines.
This may occur because `*sudog` objects are globally reachable: via the list of goroutine objects (`*g`) at `allgs`, and via the treap forest of semaphore-related `*sudog`s at `semtable`.

All uses of these fields have been updated with the methods provided by the `maybeTraceablePtr` type.
When a goroutine leak detection GC cycle starts, it sets all maybe-traceable pointers in `*sudog` objects as untraceable.
Once the cycle concludes, it resets all the pointers to being traceable.

**Soft dependency on the restart checkpoint caused by [#27993](https://go.dev/issue/27993):** in the current implementation of the GC, there is a check for whether marking phase must be restarted due to [#27993](https://go.dev/issue/27993).
We extend that checkpoint with additional logic: (1) to find additional eventually-runnable goroutines, or (2) to mark goroutines as leaked, both of which provide another reason to restart the marking phase.
If issue #27993 is resolved, the checkpoint must nonetheless be preserved when facilitating leak detection.
