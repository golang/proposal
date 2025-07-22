# Proposal: Goroutine leak detection via garbage collection

Author(s): Georgian-Vlad Saioc (vsaioc@uber.com), Milind Chabbi (milind@uber.com)

Last updated: 15 Jul 2025

Discussion at [issue #74609](https://go.dev/issue/74609)

## Abstract

This proposal outlines a dynamic technique for detecting goroutine leaks within Go programs. It leverages the existing marking phase of the Go garbage collector to find goroutines blocked over concurrency primitives that are not reachable in memory from live goroutines.

## Background

Due to its concurrency features (lightweight goroutines, message passing), Go is particularly susceptible to concurrency bugs known as _goroutine leaks_ (also known as _partial deadlocks_ in literature [1](https://dl.acm.org/doi/10.1145/3676641.3715990)). Unlike full deadlocks that halt an entire application, goroutine leaks occur whenever a goroutine is blocked indefinitely, e.g., by reading from a channel that no other goroutine has access to. This issue can lead to severe memory leaks and performance penalties by over-burdening the garbage collector with the task to mark useless memory. Goroutine leaks may be notoriously difficult to debug, and in some cases even their presence alone is difficult to discern, even with otherwise thorough diagnostic information (e.g., memory and goroutine profiles).

## Proposal

The change involves several modifications to key points of the garbage collection cycle. The modified GC cycle has the following steps:
1. Mark root preparation: initially treat only _runnable_ goroutines as mark roots (current GC treats _all_ goroutines)
2. Proceed to mark memory from this set of roots.
3. Once all memory has been marked, check whether any unmarked goroutines are blocked over any concurrency primitives that have been marked as a result of step 2.
4. Any such goroutines are considered _eventually runnable_, and must be treated as mark roots. Resume marking from step 2 with the new roots.
5. Once a fixed point over reachable memory is computed, report any goroutines that are not treated as roots as leaks; resume from step 2 one last time with leaked goroutines as mark roots to ensure that all reachable memory is marked (like in the regular GC).
6. Sweeping proceeds as normal

For an additional in-depth description of the theoretical underpinnings of the technique, refer [here](https://dl.acm.org/doi/10.1145/3676641.3715990).

## Rationale

The proposal gives developers one more tool that allows them to identify goroutine leaks, which may otherwise be difficult to identify, especially in long-running systems. The advantage of this approach over other deadlock detection techniques is that it can be leveraged in regular Go systems (e.g., production services) at minimal performance cost. It is also theoretically sound, i.e., there are no false positives.

## Compatibility

The change should be perfectly outwardly compatible with any Go program. All changes are internal, and only additional APIs are exposed.

## Implementation

A working prototype of the approach is already available at [PR #74622](https://github.com/golang/go/pull/74622).

In this section we discuss implementation miscellania.

**Opting in via API:** unlike in the [published version](https://dl.acm.org/doi/10.1145/3676641.3715990), where leak detection runs every GC cycle, in this proposal, leak detection is behaviour is only triggered on-demand by the user runtime APIs. Otherwise, the GC behaves (mostly) as in the regular runtime, with a few exceptions described in this section. In order to avoid any penalties for regular Go builds, the proposal is currently only enabled via the experimental flag `deadlockgc`.

**Hiding pointers from the GC:** in order for the approach to work, visibility to the GC must be toggleable for several pointers, i.e., the pointers should initially be invisible to the GC, but should also be made visible once certain criteria are met. In the current implementation is achieved via pointer **masking**, selected for its efficiency over space. The 2 most signficant bits of each address are reserved for the bitmask. If either is set to 1, the address is ignored during `scanobject` (2 bits chosen for robustness). Once an address should be available for marking, locations where the masked address was stored are updated with the unmasked value of the pointer.

Masking is essential because key addresses are globally exposed: goroutines (as `*g` objects) by `allgs`, and semaphores (as `unsafe.Pointer` used by `sync.Mutex`, `sync.RWMutex` and `sync.WaitGroup`), stored in the `.elem` field of the `*sudog` objects binding the goroutine to the lock, which are in turn reachable via `semtable.root`.

**Soft dependency on the restart checkpoint caused by [#27993](https://go.dev/issue/27993):** in the current implementation, there is one call for attempting to expand the mark root set upon entry to `gcMarkDone`. However, the check for goroutine leaks only occurs after checking whether the marking phase must be restarted due to [#27993](https://go.dev/issue/27993). The goroutine leak check may itself also trigger a restart here if any goroutines are identified as potentially runnable.

## Open issues

Ideally, bitmasking would be as uninvasive as possible. However, in the current implementation, it is still carried out even when the GC is operating normally (assuming experimental changes are enabled). Consider the following (admittedly contrived) example:
```
func main() {                      // Goroutine G0
  mu := &sync.Mutex{}              // Create lock
  mu.Lock()                        // Acquire lock
  go func() {                      // Goroutine G1
    mu.Lock()                      // Acquire lock (leaks)
  }()

  time.Sleep(100 * time.Milisecond // Give the child thread the chance to deadlock
  runtime.DetectDeadlocks()        // Run goroutine leak detection
}
```
During the execution, the leak will already have occurred by the time leak detection is invoked. We need to prevent the GC for that cycle from marking `mu` in the heap in order to single out `G1` as leaked. Assuming `G0` will have lost the reference to `mu` when leak detection is involved. However, the reference to `mu` is indirectly preserved in `semtable` as soon as `G1` tries to acquire `mu`.

There are two potential strategies to deal with this:
1. **Bitmasks are always enabled** (current implementation): sensitive addresses are _always_ stored with a bitmask in the global resources. This makes the GC always ready to perform leak detection with no additional preparation, but `scanblock` must always check for masked addresses, even when not running leak detection.
2. **Bitmasks are applied when leak detection is triggered**: bitmasks are applied to all sensitive locations when triggering the GC (should be performed under STW to ensure there is no interference with user code). The GC then "switches tracks" to leak detection mode, changing its behaviour. This can be achieved either via checks or by reassigning closures. After the GC cycle (or at least marking phase) is completed, the GC unmasks the bitmasks at all sensitive locations and "switches tracks" back to regular behaviour.
  This variant should incur a smaller performance penalty when not running leak detection GC at the cost of a larger application size and more expensive leak detection.
