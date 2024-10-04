# Proposal: Improve scalability of runtime.lock2

Author(s): Rhys Hiltner

Last updated: 2024-10-16

Discussion at https://go.dev/issue/68578.

## Abstract

Improve multi-core scalability of the runtime's internal mutex implementation
by minimizing wakeups of waiting threads.

Avoiding wakeups of threads that are waiting for the lock allows those threads
to sleep for longer.
That reduces the number of concurrent threads that are attempting to read the
mutex's state word.
Fewer reads of that cache line mean less cache coherency traffic within the
processor when a thread needs to make an update.
Fast updates (to acquire and release the lock) even when many threads need the
lock means better scalability.

This is not an API change, so is not part of the formal proposal process.

## Background

One of the simplest mutex designs is a single bit that is "0" when unlocked or
"1" when locked.
To acquire the lock, a thread attempts to swap in a "1",
looping until the result it gets is "0".
To unlock, the thread swaps in a "0".

The performance of such a spinlock is poor in at least two ways.
First, threads that are trying to acquire an already-held lock waste their own
on-CPU time.
Second, those software threads execute on hardware resources that need a local
copy of the mutex state word in cache.

Having the state word in cache for read access requires it not be writeable by
any other processors.
Writing to that memory location requires the hardware to invalidate all cached
copies of that memory, one in each processor that had loaded it for reading.
The hardware-internal communication necessary to implement those guarantees
has a cost, which appears as a slowdown when writing to that memory location.

Go's current mutex design is several steps more advanced than the simple
spinlock, but under certain conditions its performance can degrade in a similar way.
First, when `runtime.lock2` is unable to immediately obtain the mutex it will
pause for a moment before retrying, primarily using hardware-level delay
instructions (such as `PAUSE` on 386 and amd64).
Then, if it's unable to acquire the mutex after several retries it will ask
the OS to put it to sleep until another thread requests a wakeup.
On Linux, we use the `futex` syscall to sleep directly on the mutex address,
implemented in src/runtime/lock_futex.go.
On many other platforms (including Windows and macOS),the waiting threads
form a LIFO stack with the mutex state word as a pointer to the top of the
stack, implemented in src/runtime/lock_sema.go.

When the `futex` syscall is available,
the OS maintains a list of waiting threads and will choose which it wakes.
Otherwise, the Go runtime maintains that list and names a specific thread
when it asks the OS to do a wakeup.
To avoid a `futex` syscall when there's no contention,
we split the "locked" state into two variants:
1 meaning "locked with no contention" and
2 meaning "locked, and a thread may be asleep".
(With the semaphore-based implementation,
the Go runtime can--and must--know for itself whether a thread is asleep.)
Go's mutex implementation has those three logical states
(unlocked, locked, locked-with-sleepers) on all multi-threaded platforms.
For the purposes of the Go runtime, I'm calling this design "tristate".

After releasing the mutex,
`runtime.unlock2` will wake a thread whenever one is sleeping.
It does not consider whether one of the waiting threads is already awake.
If a waiting thread is already awake, it's not necessary to wake another.

Waking additional threads results in higher concurrent demand for the mutex
state word's cache line.
Every thread that is awake and spinning in a loop to reload the state word
leads to more cache coherency traffic within the processor,
and to slower writes to that cache line.

Consider the case where many threads all need to use the same mutex many times
in a row.
Furthermore, consider that the critical section is short relative to the time
it takes a thread to give up on spinning and go (back) to sleep.
At the end of each critical section, the thread that is releasing the mutex
will see that a waiting thread is asleep, and will wake it.
It takes a relatively long time for a thread to decide to go to sleep,
and there's a relatively short time until the next `runtime.unlock2` call will
wake it.
Many threads will be awake, all reloading the state word in a loop,
all slowing down updates to its value.

Without a limit on the number of threads that can spin on the state word,
higher demand for a mutex value degrades its performance.

See also https://go.dev/issue/68578.

## Proposal

Expand the mutex state word to include a new flag, "spinning".
Use the "spinning" bit to communicate whether one of the waiting threads is
awake and looping while trying to acquire the lock.
Threads mutually exclude each other from the "spinning" state,
but they won't block while attempting to acquire the bit.
Only the thread that owns the "spinning" bit is allowed to reload the state
word in a loop.
It releases the "spinning" bit before going to sleep.
The other waiting threads go directly to sleep.
The thread that unlocks a mutex can avoid waking a thread if it sees that one
is already awake and spinning.
For the purposes of the Go runtime, I'm calling this design "spinbit".

### futex-based option, https://go.dev/cl/601597

I've prepared https://go.dev/cl/601597,
which implements the "spinbit" design for GOOS=linux and GOARCH=amd64.
I've prepared a matching [TLA+ model](./68578/spinbit.tla)
to check for lost wakeups.
(When relying on the `futex` syscall to maintain the list of sleeping Ms,
it's easy to write lost-wakeup bugs.)

It uses an atomic `Xchg8` operation on two different bytes of the mutex state
word.
The low byte records whether the mutex is locked,
and whether one or more waiting Ms may be asleep.
The "spinning" flag is in a separate byte and so can be independently
manipulated with atomic `Xchg8` operations.
The two bytes are within a single uintptr field (`runtime.mutex.key`).
When the spinning M attempts to acquire the lock,
it can do a CAS on the entire state word,
setting the "locked" flag and clearing the "spinning" flag
in a single operation.

### Cross-OS option, https://go.dev/cl/620435

I've also prepared https://go.dev/cl/620435 which unifies the lock_sema.go and
lock_futex.go implementations and so supports all GOOS values for which Go
supports multiple threads.
(It uses `futex` to implement the `runtime.sema{create,sleep,wakeup}`
functions for lock_futex.go platforms.)
Go's development branch now includes `Xchg8` support for
GOARCH=amd64,arm64,ppc64,ppc64le,
and so that CL supports all of those architectures.

The fast path for `runtime.lock2` and `runtime.unlock2` use `Xchg8` operations
to interact with the "locked" flag.
The lowest byte of the state word is dedicated to use with those `Xchg8`
operations.
Most of the upper bytes hold a partial pointer to an M.
(The `runtime.m` datastructure is large enough to allow reconstructing the low
bits from the partial pointer,
with special handling for the non-heap-allocated `runtime.m0` value.)
Beyond the 8 bits needed for use with `Xchg8`,
a few more low bits are available for use as flags.
One of those bits holds the "spinning" flag,
which is manipulated with pointer-length `Load` and `CAS` operations.

When Ms go to sleep they form a LIFO stack linked via `runtime.m.nextwaitm`
pointers, as lock_sema.go does today.
The list of waiting Ms is a multi-producer, single-consumer stack.
Each M can add itself,
but inspecting or removing Ms requires exclusive access.
Today, lock_sema.go's `runtime.unlock2` uses the mutex itself to control that
ownership.
That puts any use of the sleeping M list in the critical path of the mutex.

My proposal uses another bit of the state word as a try-lock to control
inspecting and removing Ms from the list.
This allows additional list-management code without slowing the critical path
of a busy mutex, and use of efficient `Xchg8` operations in the fast paths.
We'll need access to the list in order to attribute contention delay to the
right critical section in the [mutex profile](https://go.dev/issue/66999).
Access to the list will also let us periodically wake an M even when it's not
strictly necessary, to combat tail latency that may be introduced by the
reduction in wakeups.

Here's the full layout of the `runtime.mutex.key` state word:
Bit 0 holds the "locked" flag, the primary purpose of the mutex.
Bit 1 is the "sleeping" flag, and is set when the upper bits point to an M.
Bits 2 through 7 are unused, since they're lost with every `Xchg8` operation.
Bit 8 holds the "spinning" try-lock, allowing the holder to reload the state
word in a loop.
Bit 9 holds the "stack" try-lock, allowing the holder to inspect and remove
sleeping Ms from the LIFO stack.
Bits 10 and higher of the state word hold bits 10 and higher of a pointer to
the M at the top of the LIFO stack of sleeping waiters.

## Rationale

The status quo is a `runtime.lock2` implementation that experiences congestion
collapse under high contention on machines with many hardware threads.
Addressing that will require fewer threads loading the same cache line in a
loop.

The literature presents several options for scalable / non-collapsing mutexes.
Some require an additional memory footprint for each mutex in proportion to
the number of threads that may seek to acquire the lock.
Some require threads to store a reference to a value that they will use to
release each lock they hold.
Go includes a `runtime.mutex` as part of every `chan`, and in some
applications those values are the ones with the most contention.
Coupled with `select`, there's no limit to the number of mutexes that an M can
hold.
That means neither of those forms of increased memory footprint is acceptable.

The performance of fully uncontended `runtime.lock2`/`runtime.unlock2` pairs
is also important to the project.
That limits the use of many of the literature's proposed locking algorithms,
if they include FIFO queue handoff behavior.
On my test hardware
(a linux/amd64 machine with i7-13700H, and a darwin/arm64 M1),
a `runtime.mutex` value with zero or moderate contention can support
50,000,000 uses per second on any threads,
or can move between active threads 10,000,000 times per second,
or can move between inactive threads (with sleep mediated by the OS)
about 40,000 to 500,000 times per second (depending on the OS).
Some amount of capture or barging, rather than queueing, is required to
maintain the level of throughput that Go users have come to expect.

Keeping the size of `runtime.mutex` values as they are today but allowing
threads to sleep with fewer interruptions seems like fulfilling the goal of
the original design.
The main disadvantage I know of is the risk of increased tail latency:
A small set of threads may be able to capture a contended mutex,
passing it back and forth among themselves while the other threads sleep
indefinitely.
That's already a risk of the current lock_sema.go implementation,
but the high volume of wakeups means threads are unlikely to sleep for long,
and the list of sleeping threads may regularly dip to zero.

The "cross-OS" option has an edge here:
with it, the Go runtime maintains an explicit list of sleeping Ms and so can do
targeted wakes or even direct handoffs to reduce starvation.

## Compatibility

There is no change in exported APIs.

## Implementation

I've prepared two options for the Go 1.24 release cycle.
One relies on the `futex` syscall and the `Xchg8` operation, and so initially
supports GOOS=linux and GOARCH=amd64: https://go.dev/cl/601597.
The other relies on only the `Xchg8` operation and works with any GOOS value
that supports threads: https://go.dev/cl/620435.
Both are controlled by `GOEXPERIMENT=spinbitmutex`,
enabled by default on supported platforms.

## Open issues (if applicable)

I appreciate feedback on the balance between simplicity,
performance at zero or low contention,
performance under extreme contention,
both the performance and maintenance burden for non-first-class ports,
and the accuracy of contention profiles.
