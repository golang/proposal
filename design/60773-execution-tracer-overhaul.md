# Execution tracer overhaul

Authored by mknyszek@google.com with a mountain of input from others.

In no particular order, thank you to Felix Geisendorfer, Nick Ripley, Michael
Pratt, Austin Clements, Rhys Hiltner, thepudds, Dominik Honnef, and Bryan
Boreham for your invaluable feedback.

## Background

[Original design document from
2014.](https://docs.google.com/document/d/1FP5apqzBgr7ahCCgFO-yoVhk4YZrNIDNf9RybngBc14/pub)

Go execution traces provide a moment-to-moment view of what happens in a Go
program over some duration.
This information is invaluable in understanding program behavior over time and
can be leveraged to achieve significant performance improvements.
Because Go has a runtime, it can provide deep information about program
execution without any external dependencies, making traces particularly
attractive for large deployments.

Unfortunately limitations in the trace implementation prevent widespread use.

For example, the process of analyzing execution traces scales poorly with the
size of the trace.
Traces need to be parsed in their entirety to do anything useful with them,
making them impossible to stream.
As a result, trace parsing and validation has very high memory requirements for
large traces.

Also, Go execution traces are designed to be internally consistent, but don't
provide any way to align with other kinds of traces, for example OpenTelemetry
traces and Linux sched traces.
Alignment with higher level tracing mechanisms is critical to connecting
business-level tasks with resource costs.
Meanwhile alignment with lower level traces enables a fully vertical view of
application performance to root out the most difficult and subtle issues.

Thanks to work in Go 1.21 cycle, the execution tracer's run-time overhead was
reduced from about -10% throughput and +10% request latency in web services to
about 1% in both for most applications.
This reduced overhead in conjunction with making traces more scalable enables
some [exciting and powerful new opportunities](#use-cases) for the diagnostic.

Lastly, the implementation of the execution tracer has evolved organically over
time and it shows.
The codebase also has many old warts and some age-old bugs that make collecting
traces difficult, and seem broken.
Furthermore, many significant decision decisions were made over the years but
weren't thoroughly documented; those decisions largely exist solely in old
commit messages and breadcrumbs left in comments within the codebase itself.

## Goals

The goal of this document is to define an alternative implementation for Go
execution traces that scales up to large Go deployments.

Specifically, the design presented aims to achieve:

- Make trace parsing require a small fraction of the memory it requires today.
- Streamable traces, to enable analysis without storage.
- Fix age-old bugs and present a path to clean up the implementation.

Furthermore, this document will present the existing state of the tracer in
detail and explain why it's like that to justify the changes being made.

## Design

### Overview

The design is broken down into four parts:

- Timestamps and sequencing.
- Orienting against threads instead of Ps.
- Partitioning.
- Wire format cleanup.

These four parts are roughly ordered by how fundamental they are to the trace
design, and so the former sections are more like concrete proposals, while the
latter sections are more like design suggestions that would benefit from
prototyping.
The earlier parts can also be implemented without considering the latter parts.

Each section includes in the history and design of the existing system as well
to document the current system in one place, and to more easily compare it to
the new proposed system.
That requires, however, a lot of prose, which can obscure the bigger picture.
Here are the highlights of each section without that additional context.

**Timestamps and sequencing**.

- Compute timestamps from the OS's monotonic clock (`nanotime`).
- Use per-goroutine sequence numbers for establishing a partial order of events
  (as before).

**Orienting against threads (Ms) instead of Ps**.

- Batch trace events by M instead of by P.
- Use lightweight M synchronization for trace start and stop.
- Simplify syscall handling.
- All syscalls have a full duration in the trace.

**Partitioning**.

- Traces are sequences of fully self-contained partitions that may be streamed.
  - Each partition has its own stack table and string table.
- Partitions are purely logical: consecutive batches with the same ID.
  - In general, parsers need state from the previous partition to get accurate
    timing information.
  - Partitions have an "earliest possible" timestamp to allow for imprecise
    analysis without a previous partition.
- Partitions are bound by both a maximum wall time and a maximum size
  (determined empirically).
- Traces contain an optional footer delineating partition boundaries as byte
  offsets.
- Emit batch lengths to allow for rapidly identifying all batches within a
  partition.

**Wire format cleanup**.

- More consistent naming scheme for event types.
- Separate out "reasons" that a goroutine can block or stop from the event
  types.
- Put trace stacks, strings, and CPU samples in dedicated batches.

### Timestamps and sequencing

For years, the Go execution tracer has used the `cputicks` runtime function for
obtaining a timestamp.
On most platforms, this function queries the CPU for a tick count with a single
instruction.
(Intuitively a "tick" goes by roughly every CPU clock period, but in practice
this clock usually has a constant rate that's independent of CPU frequency
entirely.) Originally, the execution tracer used this stamp exclusively for
ordering trace events.
Unfortunately, many [modern
CPUs](https://docs.google.com/spreadsheets/d/1jpw5aO3Lj0q23Nm_p9Sc8HrHO1-lm9qernsGpR0bYRg/edit#gid=0)
don't provide such a clock that is stable across CPU cores, meaning even though
cores might synchronize with one another, the clock read-out on each CPU is not
guaranteed to be ordered in the same direction as that synchronization.
This led to traces with inconsistent timestamps.

To combat this, the execution tracer was modified to use a global sequence
counter that was incremented synchronously for each event.
Each event would then have a sequence number that could be used to order it
relative to other events on other CPUs, and the timestamps could just be used
solely as a measure of duration on the same CPU.
However, this approach led to tremendous overheads, especially on multiprocessor
systems.

That's why in Go 1.7 the [implementation
changed](https://go-review.googlesource.com/c/go/+/21512) so that each goroutine
had its own sequence counter.
The implementation also cleverly avoids including the sequence number in the
vast majority of events by observing that running goroutines can't actually be
taken off their thread until they're synchronously preempted or yield
themselves.
Any event emitted while the goroutine is running is trivially ordered after the
start.
The only non-trivial ordering cases left are where an event is emitted by or on
behalf of a goroutine that is not actively running (Note: I like to summarize
this case as "emitting events at a distance" because the scheduling resource
itself is not emitting the event bound to it.) These cases need to be able to be
ordered with respect to each other and with a goroutine starting to run (i.e.
the `GoStart` event).
In the current trace format, there are only two such cases: the `GoUnblock`
event, which indicates that a blocked goroutine may start running again and is
useful for identifying scheduling latencies, and `GoSysExit`, which is used to
determine the duration of a syscall but may be emitted from a different P than
the one the syscall was originally made on.
(For more details on the `GoSysExit` case see in the [next section](#batching).)
Furthermore, there are versions of the `GoStart, GoUnblock`, and `GoSysExit`
events that omit a sequence number to save space if the goroutine just ran on
the same P as the last event, since that's also a case where the events are
trivially serialized.
In the end, this approach successfully reduced the trace overhead from over 3x
to 10-20%.

However, it turns out that the trace parser still requires timestamps to be in
order, leading to the infamous ["time stamps out of
order"](https://github.com/golang/go/issues/16755) error when `cputicks`
inevitably doesn't actually emit timestamps in order.
Ps are a purely virtual resource; they don't actually map down directly to
physical CPU cores at all, so it's not even reasonable to assume that the same P
runs on the same CPU for any length of time.

Although we can work around this issue, I propose we try to rely on the
operating system's clock instead and fix up timestamps as a fallback.
The main motivation behind this change is alignment with other tracing systems.
It's already difficult enough to try to internally align the `cputicks` clock,
but making it work with clocks used by other traces such as those produced by
distributed tracing systems is even more difficult.

On Linux, the `clock_gettime` syscall, called `nanotime` in the runtime, takes
around 15ns on average when called in a loop.
This is compared to `cputicks'` 10ns.
Trivially replacing all `cputicks` calls in the current tracer with `nanotime`
reveals a small performance difference that depends largely on the granularity
of each result.
Today, `cputicks'` is divided by 64.
On a 3 GHz processor, this amounts to a granularity of about 20 ns.
Replacing that with `nanotime` and no time division (i.e. nanosecond
granularity) results in a 0.22% geomean regression in throughput in the Sweet
benchmarks.
The trace size also increases by 17%.
Dividing `nanotime` by 64 we see approximately no regression and a trace size
decrease of 1.7%.
Overall, there seems to be little performance downside to using `nanotime`,
provided we pick an appropriate timing granularity: what we lose by calling
`nanotime`, we can easily regain by sacrificing a small amount of precision.
And it's likely that most of the precision below 128 nanoseconds or so is noise,
given the average cost of a single call into the Go scheduler (~250
nanoseconds).
To give us plenty of precision, I propose a target timestamp granularity of 64
nanoseconds.
This should be plenty to give us fairly fine-grained insights into Go program
behavior while also keeping timestamps small.

As for sequencing, I believe we must retain the per-goroutine sequence number
design as-is.
Relying solely on a timestamp, even a good one, has significant drawbacks.
For one, issues arise when timestamps are identical: the parser needs to decide
on a valid ordering and has no choice but to consider every possible ordering of
those events without additional information.
While such a case is unlikely with nanosecond-level timestamp granularity, it
totally precludes making timestamp granularity more coarse, as suggested in the
previous paragraph.
A sequencing system that's independent of the system's clock also retains the
ability of the tracing system to function despite a broken clock (modulo
returning an error when timestamps are out of order, which again I think we
should just work around).
Even `clock_gettime` might be broken on some machines!

How would a tracing system continue to function despite a broken clock? For that
I propose making the trace parser fix up timestamps that don't line up with the
partial order.
The basic idea is that if the parser discovers a partial order edge between two
events A and B, and A's timestamp is later than B's, then the parser applies A's
timestamp to B.
B's new timestamp is in turn propagated later on in the algorithm in case
another partial order edge is discovered between B and some other event C, and
those events' timestamps are also out-of-order.

There's one last issue with timestamps here on platforms for which the runtime
doesn't have an efficient nanosecond-precision clock at all, like Windows.
(Ideally, we'd make use of system calls to obtain a higher-precision clock, like
[QPC](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps),
but [calls to this API can take upwards of a hundred nanoseconds on modern
hardware, and even then the resolution is on the order of a few hundred
nanoseconds](https://github.com/golang/go/issues/8687#issuecomment-694498710).)
On Windows we can just continue to use `cputicks` to get the precision and rely
on the timestamp fixup logic in the parser, at the cost of being unable to
reliably align traces with other diagnostic data that uses the system clock.

### Orienting by threads (Ms) instead of Ps

Today the Go runtime batches trace events by P.
That is, trace events are grouped in batches that all happened, in order, on the
same P.
A batch is represented in the runtime as a buffer, 32 KiB in size, which is
attached to a P when it's actively being written to.
Events are written to this P's buffer in their encoded form.
This design choice allows most event writes to elide synchronization with the
rest of the runtime and linearizes the trace with respect to a P, which is
crucial to [sequencing without requiring a global total
order](#timestamps-and-sequencing).

Batching traces by any core scheduling resource (G, M, or P) could in principle
have similar properties.
At a glance, there are a few reasons Ps make a better choice.
One reason is that there are generally a small number of Ps compared to Ms and
Gs, minimizing the maximum number of buffers that can be active at any given
time.
Another reason is convenience.
When batching, tracing generally requires some kind of synchronization with all
instances of its companion resource type to get a consistent trace.
(Think of a buffer which has events written to it very infrequently.
It needs to be flushed at some point before the trace can be considered
complete, because it may contain critical information needed to sequence events
in other buffers.) Furthermore, synchronization when starting a trace is also
generally useful, as that provides an opportunity to inspect the state of the
world and write down details about it, simplifying validation.
Stopping the world is a convenient way to get the attention of all Ps in the Go
runtime.

However, there are problems with batching by P that make traces more complex
than necessary.

The core of these problems lies with the `GoSysExit` event.
This event requires special arrangements in both the runtime and when validating
traces to ensure a consistent trace.
The difficulty with this event is that it's emitted by a goroutine that was
blocked in a syscall and lost its P, and because it doesn't have a P, it might
race with the runtime enabling and disabling tracing.
Therefore it needs to wait until it has a P to avoid that race.
(Note: the tracing system does have a place to put events when there is no P
available, but that doesn't help in this case.
The tracing system uses the fact that it stops-the-world to synchronize with
`GoSysExit` by preventing it from writing an event until the trace system can
finish initialization.)

The problem with `GoSysExit` stems from a fundamental mismatch: Ms emit events,
but only Ps are preemptible by the Go scheduler.
This really extends to any situation where we'd like an M to emit an event when
it doesn't have a P, say for example when it goes to sleep after dropping its P
and not finding any work in the scheduler, and it's one reason why we don't have
any M-specific events at all today.

So, suppose we batch trace events by M instead.

In the case of `GoSysExit`, it would always be valid to write to a trace buffer,
because any synchronization would have to happen on the M instead of the P, so
no races with stopping the world.
However, this also means the tracer _can't_ simply stop the world, because
stopping the world is built around stopping user Go code, which runs with a P.
So, the tracer would have to use something else (more on this later).

Although `GoSysExit` is simpler, `GoSysBlock` becomes slightly more complex in
the case where the P is retaken by `sysmon`.
In the per-P world it could be written into the buffer of the taken P, so it
didn't need any synchronization.
In the per-M world, it becomes an event that happens "at a distance" and so
needs a sequence number from the syscalling goroutine for the trace consumer to
establish a partial order.

However, we can do better by reformulating the syscall events altogether.

Firstly, I propose always emitting the full time range for each syscall.
This is a quality-of-life choice that may increase trace overheads slightly, but
also provides substantially more insight into how much time is spent in
syscalls.
Syscalls already take ~250 nanoseconds at a baseline on Linux and are unlikely
to get faster in the future for security reasons (due to Spectre and Meltdown)
and the additional event would never contain a stack trace, so writing it out
should be quite fast.
(Nonetheless, we may want to reconsider emitting these events for cgo calls.)
The new events would be called, for example, `GoSyscallBegin` and
`GoSyscallEnd`.
If a syscall blocks, `GoSyscallEnd` is replaced with `GoSyscallEndBlocked`
(more on this later).

Secondly, I propose adding an explicit event for stealing a P.
In the per-M world, keeping just `GoSysBlock` to represent both a goroutine's
state transition and the state of a P is not feasible, because we're revealing
the fact that fundamentally two threads are racing with one another on the
syscall exit.
An explicit P-stealing event, for example `ProcSteal`, would be required to
be ordered against a `GoSyscallEndBlocked`, with the former always happening
before.
The precise semantics of the `ProcSteal` event would be a `ProcStop` but one
performed by another thread.
Because this means events can now happen to P "at a distance," the `ProcStart`,
`ProcStop`, and `ProcSteal` events all need sequence numbers.

Note that the naive emission of `ProcSteal` and `GoSyscallEndBlocked` will
cause them to race, but the interaction of the two represents an explicit
synchronization within the runtime, so the parser can always safely wait for the
`ProcSteal` to emerge in the frontier before proceeding.
The timestamp order may also not be right, but since [we already committed to
fixing broken timestamps](#timestamps-and-sequencing) in general, this skew will
be fixed up by that mechanism for presentation.
(In practice, I expect the skew to be quite small, since it only happens if the
retaking of a P races with a syscall exit.)

Per-M batching might also incur a higher memory cost for tracing, since there
are generally more Ms than Ps.
I suspect this isn't actually too big of an issue since the number of Ms is
usually close to the number of Ps.
In the worst case, there may be as many Ms as Gs! However, if we also [partition
the trace](#partitioning), then the number of active buffers will only be
proportional to the number of Ms that actually ran in a given time window, which
is unlikely to be an issue.
Still, if this does become a problem, a reasonable mitigation would be to simply
shrink the size of each trace buffer compared to today.
The overhead of the tracing slow path is vanishingly small, so doubling its
frequency would likely not incur a meaningful compute cost.

Other than those three details, per-M batching should function identically to
the current per-P batching: trace events may already be safely emitted without a
P (modulo `GoSysExit` synchronization), so we're not losing anything else with
the change.

Instead, however, what we gain is a deeper insight into thread execution.
Thread information is currently present in execution traces, but difficult to
interpret because it's always tied to P start and stop events.
A switch to per-M batching forces traces to treat Ps and Ms orthogonally.

Given all this, I propose switching to per-M batching.
The only remaining question to resolve is trace synchronization for Ms.

(As an additional minor consideration, I would also like to propose adding the
batch length to the beginning of each batch.
Currently (and in the foreseeable future), the trace consumer needs to iterate
over the entire trace once to collect all the batches for ordering.
We can speed up this process tremendously by allowing the consumer to _just_
collect the information it needs.)

#### M synchronization

The runtime already contains a mechanism to execute code on every M via signals,
`doAllThreadsSyscall`.
However, traces have different requirements than `doAllThreadsSyscall`, and I
think we can exploit the specifics of these requirements to achieve a more
lightweight alternative.

First, observe that getting the attention of every M for tracing is not strictly
necessary: Ms that never use the tracer need not be mentioned in the trace at
all.
This observation allows us to delegate trace state initialization to the M
itself, so we can synchronize with Ms at trace start simply by atomically
setting a single global flag.
If an M ever writes into the trace buffer, then it will initialize its state by
emitting an event indicating what it was doing when tracing started.
For example, if the first event the M is going to emit is `GoBlock`, then it
will emit an additional event before that that indicates the goroutine was
running since the start of the trace (a hypothetical `GoRunning` event).
Disabling tracing is slightly more complex, as the tracer needs to flush every
M's buffer or identify that its buffer was never written to.
However, this is fairly straightforward to do with per-M seqlocks.

Specifically, Ms would double-check the `trace.enabled` flag under the seqlock
and anything trying to stop a trace would first disable the flag, then iterate
over every M to make sure it _observed_ its seqlock was unlocked.
This guarantees that every M observed or will observe the new flag state.

There's just one problem with all this: it may be that an M might be running and
never emit an event.
This case is critical to capturing system dynamics.
As far as I can tell, there are three cases here: the M is running user code
without emitting any trace events (e.g. a tight loop), the M is in a system call
or C code the whole time, or the M is `sysmon`, a special thread that always
runs without a P.

The first case is fairly easy to deal with: because it's running with a P, we
can just preempt it and establish an invariant that any preemption always emits
an event if the M's trace state has not been initialized.

The second case is a little more subtle, but luckily not very complex to
implement.
The tracer can identify whether the M has a G blocked in a syscall (or
equivalently has called into C code) just before disabling tracing globally by
checking `readgstatus(m.curg) == _Gsyscall` on each M's G and write it down.
If the tracer can see that the M never wrote to its buffer _after_ it disables
tracing, it can safely conclude that the M was still in a syscall at the moment
when tracing was disabled, since otherwise it would have written to the buffer.

Note that since we're starting to read `gp.atomicstatus` via `readgstatus`, we
now need to ensure consistency between the G's internal status and the events
we emit representing those status changes, from the tracer's perspective.
Thus, we need to make sure we hold the M's trace seqlock across any
`gp.atomicstatus` transitions, which will require a small refactoring of the
runtime and the tracer.

For the third case, we can play basically the same trick as the second case, but
instead check to see if sysmon is blocked on a note.
If it's not, it's running.
If it doesn't emit any events (e.g. to stop on a note) then the tracer can
assume that it's been running, if its buffer is empty.

A big change with this synchronization mechanism is that the tracer no longer
obtains the state of _all_ goroutines when a trace starts, only those that run
or execute syscalls.
The remedy to this is to simply add it back in.
Since the only cases not covered are goroutines in `_Gwaiting` or `_Grunnable`,
the tracer can set the `_Gscan` bit on the status to ensure the goroutine can't
transition out.
At that point, it collects a stack trace and writes out a status event for the
goroutine inside buffer that isn't attached to any particular M.
To avoid ABA problems with a goroutine transitioning out of `_Gwaiting` or
`_Grunnable` and then back in, we also need an atomically-accessed flag for each
goroutine that indicates whether an event has been written for that goroutine
yet.

The result of all this synchronization is that the tracer only lightly perturbs
application execution to start and stop traces.
In theory, a stop-the-world is no longer required at all, but in practice
(especially with [partitioning](#partitioning)), a brief stop-the-world to begin
tracing dramatically simplifies some of the additional synchronization necessary.
Even so, starting and stopping a trace will now be substantially more lightweight
than before.

### Partitioning

The structure of the execution trace's binary format limits what you can do with
traces.

In particular, to view just a small section of the trace, the entire trace needs
to be parsed, since a batch containing an early event may appear at the end of
the trace.
This can happen if, for example, a P that stays relatively idle throughout the
trace wakes up once at the beginning and once at the end, but never writes
enough to the trace buffer to flush it.

To remedy this, I propose restructuring traces into a stream of self-contained
partitions, called "generations."
More specifically, a generation is a collection of trace batches that represents
a complete trace.
In practice this means each generation boundary is a global buffer flush.
Each trace batch will have a generation number associated with, and generations
will not interleave.
The way generation boundaries are identified in the trace is when a new batch
with a different number is identified.

The size of each generation will be roughly constant: new generation boundaries
will be created when either the partition reaches some threshold size _or_ some
maximum amount of wall-clock time has elapsed.
The exact size threshold and wall-clock limit will be determined empirically,
though my general expectation for the size threshold is around 16 MiB.

Generation boundaries will add a substantial amount of implementation
complexity, but the cost is worth it, since it'll fundamentally enable new
use-cases.

The trace parser will need to be able to "stitch" together events across
generation boundaries, and for that I propose the addition of a new `GoStatus`
event.
This event is a generalization of the `GoInSyscall` and `GoWaiting` events.
This event will be emitted the first time a goroutine is about to be mentioned
in a trace, and will carry a state enum argument that indicates what state the
goroutine was in *before* the next event to be emitted.
The state emitted for a goroutine, for more tightly coupling events to states,
will be derived from the event about to be emitted (except for the "waiting" and
"syscall" cases where it's explicit).
The trace parser will be able to use these events to validate continuity across
generations.

This global buffer flush can be implemented as an extension to the
aforementioned [M synchronization](#m-synchronization) design by replacing the
`enabled` flag with a generation counter and doubling up much of the trace
state.
The generation counter will be used to index into the trace state, allowing for
us to dump and then toss old trace state, to prepare it for the next generation
while the current generation is actively being generated.
In other words, it will work akin to ending a trace, but for just one half of
the trace state.

One final subtlety created by partitioning is that now we may no longer have a
stop-the-world in between complete traces (since a generation is a complete
trace).
This means some events may be active when a trace is starting, and we'll lose
that information.
For user-controlled event types (user tasks and user regions), I propose doing
nothing special.
It's already true that if a task or region was in progress we lose that
information, and it's difficult to track that efficiently given how the API is
structured.
For range event types we control (sweep, mark assist, STW, etc.), I propose
adding the concept of "active" events which are used to indicate that a
goroutine or P has been actively in one of these ranges since the start of a
generation.
These events will be emitted alongside the `GoStatus` event for a goroutine.
(This wasn't mentioned above, but we'll also need a `ProcStatus` event, so we'll
also emit these events as part of that processes as well.)

### Event cleanup

Since we're modifying the trace anyway, this is a good opportunity to clean up
the event types, making them simpler to implement, simpler to parse and
understand, and more uniform overall.

The three biggest changes I would like to propose are

1. A uniform naming scheme,
1. Separation of the reasons that goroutines might stop or block from the event
   type.
1. Placing strings, stacks, and CPU samples in their own dedicated batch types.

Firstly, for the naming scheme, I propose the following rules (which are not
strictly enforced, only guidelines for documentation):

- Scheduling resources, such as threads and goroutines, have events related to
  them prefixed with the related resource (i.e. "Thread," "Go," or "Proc").
  - Scheduling resources have "Create" and "Destroy" events.
  - Scheduling resources have generic "Status" events used for indicating their
    state at the start of a partition (replaces `GoInSyscall` and `GoWaiting`).
  - Scheduling resources have "Start" and "Stop" events to indicate when that
    resource is in use.
    The connection between resources is understood through context today.
  - Goroutines also have "Block" events which are like "Stop", but require an
    "Unblock" before the goroutine can "Start" again.
  - Note: Ps are exempt since they aren't a true resource, more like a
    best-effort semaphore in practice.
    There's only "Start" and "Stop" for them.
- Events representing ranges of time come in pairs with the start event having
  the "Begin" suffix and the end event having the "End" suffix.
- Events have a prefix corresponding to the deepest resource they're associated
  with.

Secondly, I propose moving the reasons why a goroutine resource might stop or
block into an argument.
This choice is useful for backwards compatibility, because the most likely
change to the trace format at any given time will be the addition of more
detail, for example in the form of a new reason to block.

Thirdly, I propose placing strings, stacks, and CPU samples in their own
dedicated batch types.
This, in combination with batch sizes in each batch header, will allow the trace
parser to quickly skim over a generation and find all the strings, stacks, and
CPU samples.
This makes certain tasks faster, but more importantly, it simplifies parsing and
validation, since the full tables are just available up-front.
It also means that the event batches are able to have a much more uniform format
(one byte event type, followed by several varints) and we can keep all format
deviations separate.

Beyond these big three, there are a myriad of additional tweaks I would like to
propose:

- Remove the `FutileWakeup` event, which is no longer used (even in the current
  implementation).
- Remove the `TimerGoroutine` event, which is no longer used (even in the
  current implementation).
- Rename `GoMaxProcs` to `ProcsChange`.
  - This needs to be written out at trace startup, as before.
- Redefine `GoSleep` as a `GoBlock` and `GoUnblock` pair.
- Break out `GoStartLabel` into a more generic `GoLabel` event that applies a
  label to a goroutine the first time it emits an event in a partition.
- Change the suffixes of pairs of events representing some activity to be
  `Begin` and `End`.
- Ensure all GC-related events contain the string `GC`.
- Add [sequence numbers](#timestamps-and-sequencing) to events where necessary:
  - `GoStart` still needs a sequence number.
  - `GoUnblock` still needs a sequence number.
  - Eliminate the {`GoStart,GoUnblock,Go}Local` events for uniformity.
- Because traces are no longer bound by stopping the world, and can indeed now
  start during the GC mark phase, we need a way to identify that a GC mark is
  currently in progress.
  Add the `GCMarkActive` event.
- Eliminate inline strings and make all strings referenced from a table for
  uniformity.
  - Because of partitioning, the size of the string table is unlikely to become
    large in practice.
  - This means all events can have a fixed size (expressed in terms of
    the number of arguments) and we can drop the argument count bits from the
    event type.

A number of these tweaks above will likely make traces bigger, mostly due to
additional information and the elimination of some optimizations for uniformity.

One idea to regain some of this space is to compress goroutine IDs in each
generation by maintaining a lightweight mapping.
Each time a goroutine would emit an event that needs the current goroutine
ID, it'll check a g-local cache.
This cache will contain the goroutine's alias ID for the current partition
and the partition number.
If the goroutine does not have an alias for the current partition, it
increments a global counter to acquire one and writes down the mapping of
that counter to its full goroutine ID in a global table.
This table is then written out at the end of each partition.
But this is optional.

## Implementation

As discussed in the overview, this design is intended to be implemented in
parts.
Some parts are easy to integrate into the existing tracer, such as the switch to
nanotime and the traceback-related improvements.
Others, such as per-M batching, partitioning, and the change to the event
encoding, are harder.

While in theory all could be implemented separately as an evolution of the
existing tracer, it's simpler and safer to hide the changes behind a feature
flag, like a `GOEXPERIMENT` flag, at least to start with.
Especially for per-M batching and partitioning, it's going to be quite
complicated to try to branch in all the right spots in the existing tracer.

Instead, we'll basically have two trace implementations temporarily living
side-by-side, with a mostly shared interface.
Where they differ (and there are really only a few spots), the runtime can
explicitly check for the `GOEXPERIMENT` flag.
This also gives us an opportunity to polish the new trace implementation.

The implementation will also require updating the trace parser to make tests
work.
I suspect this will result in what is basically a separate trace parser that's
invoked when the new header version is identified.
Once we have a basic trace parser that exports the same API, we can work on
improving the internal trace parser API to take advantage of the new features
described in this document.

## Use-cases

This document presents a large change to the existing tracer under the banner of
"traces at scale" which is a bit abstract.
To better understand what that means, let's explore a few concrete use-cases
that this design enables.

### Flight recording

Because the trace in this design is partitioned, it's now possible for the
runtime to carry around the most recent trace partition.
The runtime could then expose this partition to the application as a snapshot of
what the application recently did.
This is useful for debugging at scale, because it enables the application to
collect data exactly when something goes wrong.
For instance:

- A server's health check fails.
  The server takes a snapshot of recent execution and puts it into storage
  before exiting.
- Handling a request exceeds a certain latency threshold.
  The server takes a snapshot of the most recent execution state and uploads it
  to storage for future inspection.
- A program crashes when executing in a deployed environment and leaves behind a
  core dump.
  That core dump contains the recent execution state.

Here's a quick design sketch:

```go
package trace

// FlightRecorder represents
type FlightRecorder struct { ... }

// NewFlightRecorder creates a new flight recording configuration.
func NewFlightRecorder() *FlightRecorder

// Start begins process-wide flight recording. Only one FlightRecorder
// may be started at once. If another FlightRecorder is started, this
// function will return an error.
//
// This function can be used concurrently with Start and Stop.
func (fr *FlightRecorder) Start() error

// TakeSnapshot collects information about the execution of this program
// from the last few seconds and write it to w. This FlightRecorder must
// have started to take a snapshot.
func (fr *FlightRecorder) TakeSnapshot(w io.Writer) error

// Stop ends process-wide flight recording. Stop must be called on the
// same FlightRecorder that started recording.
func (fr *FlightRecorder) Stop() error
```

- The runtime accumulates trace buffers as usual, but when it makes a partition,
  it puts the trace data aside as it starts a new one.
- Once the new partition is finished, the previous is discarded (buffers are
  reused).
- At any point, the application can request a snapshot of the current trace
  state.
  - The runtime immediately creates a partition from whatever data it has, puts
    that together with the previously-accumulated partition, and hands it off to
    the application for reading.
  - The runtime then continues accumulating trace data in a new partition while
    the application reads the trace data.
- The application is almost always guaranteed two partitions, with one being as
  large as a partition would be in a regular trace (the second one is likely to
  be smaller).
- Support for flight recording in the `/debug/pprof/trace` endpoint.

### Fleetwide trace collection

Today some power users collect traces at scale by setting a very modest sampling
rate, e.g. 1 second out of every 1000 seconds that a service is up.
This has resulted in collecting a tremendous amount of useful data about
execution at scale, but this use-case is currently severely limited by trace
performance properties.

With this design, it should be reasonable to increase the sampling rate by an
order of magnitude and collect much larger traces for offline analysis.

### Online analysis

Because the new design allows for partitions to be streamed and the trace
encoding is much faster to process, it's conceivable that a service could
process its own trace continuously and aggregate and filter only what it needs.
This online processing avoids the need to store traces for future inspection.

The kinds of processing I imagine for this includes:

- Detailed task latency breakdowns over long time horizons.
- CPU utilization estimates for different task types.
- Semantic processing and aggregation of user log events.
- Fully customizable flight recording (at a price).

### Linux sched trace association

Tooling can be constructed that interleaves Go execution traces with traces
produced via:

`perf sched record --clockid CLOCK_MONOTONIC <command>`

## Prior art

### JFR

[JFR or "Java Flight
Recorder](https://developers.redhat.com/blog/2020/08/25/get-started-with-jdk-flight-recorder-in-openjdk-8u#using_jdk_flight_recorder_with_jdk_mission_control)"
is an execution tracing system for Java applications.
JFR is highly customizable with a sophisticated wire format.
It supports very detailed configuration of events via an XML configuration file,
including the ability to enable/disable stack traces per event and set a latency
threshold an event needs to exceed in order to be sampled (e.g. "only sample
file reads if they exceed 20ms").
It also supports custom user-defined binary-encoded events.

By default, JFR offers a low overhead configuration (<1%) for "continuous
tracing" and slightly higher overhead configuration (1-2%) for more detailed
"profile tracing."
These configurations are just default configuration files that ship with the
JVM.

Continuous tracing is special in that it accumulates data into an internal
global ring buffer which may be dumped at any time.
Notably this data cannot be recovered from a crashed VM, though it can be
recovered in a wide variety of other cases.
Continuous tracing is disabled by default.

The JFR encoding scheme is quite complex, but achieves low overhead partially
through varints.
JFR traces are also partitioned, enabling scalable analysis.

In many ways the existing Go execution tracer looks a lot like JFR, just without
partitioning, and with a simpler encoding.

### KUTrace

[KUTrace](https://github.com/dicksites/KUtrace) is a system-wide execution
tracing system for Linux.
It achieves low overhead, high resolution, and staggering simplicity by cleverly
choosing to trace on each kernel transition (the "goldilocks" point in the
design space, as the author puts it).

It uses a fairly simple 8-byte-word-based encoding scheme to keep trace writing
fast, and exploits the very common case of a system call returning quickly
(>90%) to pack two events into each word when possible.

### This project's low-overhead tracing inspired this effort, but in the end we
didn't take too many of its insights.

### CTF

[CTF or "Common Trace Format](https://diamon.org/ctf/#spec7)" is more of a meta
tracing system.
It defines a binary format, a metadata format (to describe that binary format),
as well as a description language.
In essence, it contains all the building blocks of a trace format without
defining one for a specific use-case.

Traces in CTF are defined as a series of streams of events.
Events in a stream are grouped into self-contained packets.
CTF contains many of the same concepts that we define here (packets are batches;
the streams described in this document are per-thread, etc.), though it largely
leaves interpretation of the trace data up to the one defining a CTF-based trace
format.

## Future work

### Event encoding

The trace format relies heavily on LEB128-encoded integers.
While this choice makes the trace quite compact (achieving 4-6 bytes/event, with
some tricks to keep each encoded integer relatively small), it comes at a cost
to decoding speed since LEB128 is well-known for being relatively slow to decode
compared to similar integer encodings.
(Note: this is only a hunch at present; this needs to be measured.) (The cost at
encoding time is dwarfed by other costs, like tracebacks, so it's not on the
critical path for this redesign.)

This section proposes a possible future trace encoding that is simpler, but
without any change would produce a much larger trace.
It then proposes two possible methods of compressing the trace from there.

#### Encoding format

To start with, let's redefine the format as a series of 4-byte words of data.

Each event has a single header word that includes the event type (8 bits), space
for a 4-bit event reason, and the timestamp delta (20 bits).
Note that every event requires a timestamp.
At a granularity of 64 nanoseconds, this gives us a timestamp range of ~1
second, which is more than enough for most cases.
In the case where we can't fit the delta in 24 bits, we'll emit a new
"timestamp" event which is 2 words wide, containing the timestamp delta from the
start of the partition.
This gives us a 7-byte delta which should be plenty for any trace.

Each event's header is then followed by a number of 4-byte arguments.
The minimum number of arguments is fixed per the event type, and will be made
evident in self-description.
A self-description table at the start of the trace could indicate (1) whether
there are a variable number of additional arguments, (2) which argument
indicates how many there are, and (3) whether any arguments are byte arrays
(integer followed by data).
Byte array data lengths are always rounded up to 4 bytes.
Possible arguments include, for example, per-goroutine sequence numbers,
goroutine IDs, thread IDs, P IDs, stack IDs, and string IDs.
Within a partition, most of these trivially fit in 32 bits:

- Per-goroutine sequence numbers easily fit provided each partition causes a
  global sequence number reset, which is straightforward to arrange.
- Thread IDs come from the OS as `uint32` on all platforms we support.
- P IDs trivially fit within 32 bits.
- Stack IDs are local to a partition and as a result trivially fit in 32-bits.
  Assuming a partition is O(MiB) in size (so, O(millions) of events), even if
  each event has a unique stack ID, it'll fit.
- String IDs follow the same logic as stack IDs.
- Goroutine IDs, when compressed as described in the event cleanup section, will
  easily fit in 32 bits.

The full range of possible encodings for an event can be summarized as thus:

This format change, before any compression, will result in an encoded trace size
of 2-3x.
Plugging in the size of each proposed event above into the breakdown of a trace
such as [this 288 MiB one produced by
felixge@](https://gist.github.com/felixge/a79dad4c30e41a35cb62271e50861edc)
reveals an increase in encoded trace size by a little over 2x.
The aforementioned 288 MiB trace grows to around 640 MiB in size, not including
additional timestamp events, the batch header in this scheme, or any tables at
the end of each partition.

This increase in trace size is likely unacceptable since there are several cases
where holding the trace in memory is desirable.
Luckily, the data in this format is very compressible.

This design notably doesn't handle inline strings.
The easy thing to do would be to always put them in the string table, but then
they're held onto until at least the end of a partition, which isn't great for
memory use in the face of many non-cacheable strings.
This design would have to be extended to support inline strings, perhaps
rounding up their length to a multiple of 4 bytes.

#### On-line integer compression

One possible route from here is to simply choose a different integer compression
scheme.
There exist many fast block-based integer compression schemes, ranging from [GVE
and
PrefixVarint](https://en.wikipedia.org/wiki/Variable-length_quantity#Group_Varint_Encoding)
to SIMD-friendly bit-packing schemes.

Inline strings would likely have to be excepted from this compression scheme,
and would likely need to be sent out-of-band.

#### On-demand user compression

Another alternative compression scheme is to have none, and instead expect the
trace consumer to perform their own compression, if they want the trace to be
compressed.
This certainly simplifies the runtime implementation, and would give trace
consumers a choice between trace encoding speed and trace size.
For a sufficiently fast compression scheme (perhaps LZ4), it's possible this
could rival integer compression in encoding overhead.

More investigation on this front is required.

### Becoming a CPU profile superset

Traces already contain CPU profile samples, but are missing some information
compared to what Go CPU profile pprof protos contain.
We should consider bridging that gap, such that it is straightforward to extract
a CPU profile from an execution trace.

This might look like just emitting another section to the trace that contains
basically the entire pprof proto.
This can likely be added as a footer to the trace.
