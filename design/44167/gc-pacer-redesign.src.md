# GC Pacer Redesign

Author: Michael Knyszek

Updated: 8 February 2021

## Abstract

Go's tracing garbage collector runs concurrently with the application, and thus
requires an algorithm to determine when to start a new cycle.
In the runtime, this algorithm is referred to as the pacer.
Until now, the garbage collector has framed this process as an optimization
problem, utilizing a proportional controller to achieve a desired stopping-point
(that is, the cycle completes just as the heap reaches a certain size) as well
as a desired CPU utilization.
While this approach has served Go well for a long time, it has accrued many
corner cases due to resolved issues, as well as a backlog of unresolved issues.

I propose redesigning the garbage collector's pacer from the ground up to
capture the things it does well and eliminate the problems that have been
discovered.
More specifically, I propose:

1. Including all non-heap sources of GC work (stacks, globals) in pacing
   decisions.
1. Reframing the pacing problem as a search problem, solved by a
   proportional-integral controller,
1. Extending the hard heap goal to the worst-case heap goal of the next GC,

(1) will resolve long-standing issues with small heap sizes, allowing the Go
garbage collector to scale *down* and act more predictably in general.
(2) will eliminate offset error present in the current design, will allow
turning off GC assists in the steady-state, and will enable clearer designs for
setting memory limits on Go applications.
(3) will enable smooth and consistent response to large changes in the live heap
size with large `GOGC` values.

## Background

Since version 1.5 Go has had a tracing mark-sweep garbage collector (GC) that is
able to execute concurrently with user goroutines.
The garbage collector manages several goroutines called "workers" to carry out
its task.
A key problem in concurrent garbage collection is deciding when to begin, such
that the work is complete "on time."
Timeliness, today, is defined by the optimization of two goals:

1. The heap size relative to the live heap at the end of the last cycle, and
1. A target CPU utilization for the garbage collector while it is active.

These two goals are tightly related.
If a garbage collection cycle starts too late, for instance, it may consume more
CPU to avoid missing its target.
If a cycle begins too early, it may end too early, resulting in GC cycles
happening more often than expected.

Go's garbage collector sets a fixed target of 30% CPU utilization (25% from GC
workers, with 5% from user goroutines donating their time to assist) while the
GC is active.
It also offers a parameter to allow the user to set their own memory use and CPU
trade-off: `GOGC`.
`GOGC` is a percent overhead describing how much *additional* memory (over the
live heap) the garbage collector may use.
A higher `GOGC` value indicates that the garbage collector may use more memory,
setting the target heap size higher, and conversely a lower `GOGC` value sets
the target heap size lower.
The process of deciding when a garbage collection should start given these
parameters has often been called "pacing" in the Go runtime.

To attempt to reach its goals, Go's "pacer" utilizes a proportional controller
to decide when to start a garbage collection cycle.
The controller attempts to find the correct point to begin directly, given an
error term that captures the two aforementioned optimization goals.

It's worth noting that the optimization goals are defined for some steady-state.
Today, the steady-state is implicitly defined as: constant allocation rate,
constant heap size, and constant heap composition (hence, constant mark rate).
The pacer expects the application to settle on some average global behavior
across GC cycles.

However, the GC is still robust to transient application states.
When the GC is in some transient state, the pacer is often operating with stale
information, and is actively trying to find the new steady-state.
To avoid issues with memory blow-up, among other things, the GC makes allocating
goroutines donate their time to assist the garbage collector, proportionally to
the amount of memory that they allocate.
This GC assist system keeps memory use stable in unstable conditions, at the
expense of user CPU time and latency.

The GC assist system operates by dynamically computing an assist ratio.
The assist ratio is the slope of a curve in the space of allocation time and GC
work time, a curve that the application is required to stay under.
This assist ratio is then used as a conversion factor between the amount a
goroutine has allocated, and how much GC assist work it should do.
Meanwhile, GC workers generate assist credit from the work that they do and
place it in a global pool that allocating goroutines may steal from to avoid
having to assist.

## Motivation

Since version 1.5, the pacer has gone through several minor tweaks and changes
in order to resolve issues, usually adding special cases and making its behavior
more difficult to understand, though resolving the motivating problem.
Meanwhile, more issues have been cropping up that are diagnosed but more
difficult to tackle in the existing design.
Most of these issues are listed in the [GC pacer
meta-issue](https://github.com/golang/go/issues/42430).

Even more fundamentally, the proportional controller at the center of the pacer
is demonstrably unable to completely eliminate error in its scheduling, a
well-known issue with proportional-only controllers.

Another significant motivator, beyond resolving latent issues, is that the Go
runtime lacks facilities for dealing with finite memory limits.
While the `GOGC` mechanism works quite well and has served Go for a long time,
it falls short when there's a hard memory limit.
For instance, a consequence of `GOGC` that often surprises new gophers coming
from languages like Java, is that if `GOGC` is 100, then Go really needs 2x more
memory than the peak live heap size.
The garbage collector will *not* automatically run more aggressively as it
approaches some memory limit, leading to out-of-memory errors.
Conversely, users that know they'll have a fixed amount of memory up-front are
unable to take advantage of it if their live heap is usually small.
Users have taken to fooling the GC into thinking more memory is live than their
application actually needs in order to let the application allocate more memory
in between garbage collections.
Simply increasing `GOGC` doesn't tend to work in this scenario either because of
the previous problem: if the live heap spikes suddenly, `GOGC` will result in
much more memory being used overall.
See issue [#42430](https://github.com/golang/go/issues/42430) for more details.

The current pacer is not designed with these use-cases in mind.

## Design

### Definitions

```render-latex
\begin{aligned}
\gamma & = 1+\frac{GOGC}{100} \\
   S_n & = \textrm{bytes of memory allocated to goroutine stacks at the beginning of the mark phase of GC } n \\
   G_n & = \textrm{bytes of memory dedicated to scannable global variables at the beginning of the mark phase of GC } n \\
   M_n & = \textrm{bytes of memory marked live after GC } n
\end{aligned}
```

There is some nuance to these definitions.

Firstly, `$\gamma$` is used in place of `GOGC` because it makes the math easier
to understand.

Secondly, `$S_n$` may vary throughout the sweep phase, but effectively becomes
fixed once a GC cycle starts.
Stacks may not shrink, only grow during this time, so there's a chance any value
used by the runtime during a GC cycle will be stale.
`$S_n$` also includes space that may not be actively used for the stack.
That is, if an 8 KiB goroutine stack is actually only 2 KiB high (and thus only
2 KiB is actually scannable), for consistency's sake the stack's height will be
considered 8 KiB.
Both of these estimates introduce the potential for skew.
In general, however, stacks are roots in the GC and will be some of the first
sources of work for the GC, so the estimate should be fairly close.
If that turns out not to be true in practice, it is possible, though tricky to
track goroutine stack heights more accurately, though there must necessarily
always be some imprecision because actual scannable stack height is rapidly
changing.

Thirdly, `$G_n$` acts similarly to `$S_n$`.
The amount of global memory in a Go program can change while the application is
running because of the `plugin` package.
This action is relatively rare compared to a change in the size of stacks.
Because of this rarity, I propose allowing a bit of skew.
At worst (as we'll see later) the pacer will overshoot a little bit.

Lastly, `$M_n$` is the amount of heap memory known to be live to the runtime the
*instant* after a garbage collection cycle completes.
Intuitively, it is the bottom of the classic GC sawtooth pattern.

### Heap goal

Like in the [previous definition of the
pacer](https://docs.google.com/document/d/1wmjrocXIWTr1JxU-3EQBI6BK6KgtiFArkG47XK73xIQ/edit#heading=h.poxawxtiwajr),
the runtime sets some target heap size for the GC cycle based on `GOGC`.
Intuitively, this target heap size is the targeted heap size at the top of the
classic GC sawtooth pattern.

The definition I propose is very similar, except it includes non-heap sources of
GC work.
Let `$N_n$` be the heap goal for GC `$n$` ("N" stands for "Next GC").

```render-latex
N_n = \gamma(M_{n-1} + S_n + G_n)
```

The old definition makes the assumption that non-heap sources of GC work are
negligible.
In practice, that is often not true, such as with small heaps.
This definition says that we're trading off not just heap memory, but *all*
memory that influences the garbage collector's CPU consumption.

From a philospical standpoint wherein `GOGC` is intended to be a knob
controlling the trade-off between CPU resources and memory footprint, this
definition is more accurate.

This change has one large user-visible ramification: the default `GOGC`, in most
cases, will use slightly more memory than before.

This change will inevitably cause some friction, but I believe the change is
worth it.
It unlocks the ability to scale *down* to heaps smaller than 4 MiB (the origin
of this limit is directly tied to this lack of accounting).
It also unlocks better behavior in applications with many, or large goroutine
stacks, or very many globals.
That GC work is now accounted for, leading to fewer surprises.

### Deciding when to trigger a GC

Unlike the current pacer, I propose that instead of finding the right point to
start a GC such that the runtime reaches some target in the steady-state, that
the pacer instead searches for a value that is more fundamental, though more
indirect.

Before continuing I want take a moment to point out some very fundamental and
necessary assumptions made in both this design and the current pacer.
Here, we are taking a "macro-economic" view of the Go garbage collector.
The actual behavior of the application at the "micro" level is all about
individual allocations, but the pacer is concerned not with the moment-to-moment
behavior of the application.
Instead, it concerns itself with broad aggregate patterns.
And evidently, this abstraction is useful.
Most programs are not wildly unpredictable in their behavior; in fact it's
somewhat of a challenge to write a useful application that non-trivially has
unpredictable memory allocation behavior, thanks to the law of large numbers.
This observation is why it is useful to talk about the steady-state of an
application *at all*.

The pacer concerns itself with two notions of time: the time it takes to
allocate from the GC trigger point to the heap goal and the time it takes to
find and perform all outstanding GC work.
These are only *notions* of time because the pacer's job is to make them happen
in the *same* amount of time, relative to a wall clock.
Since in the steady-state the amount of GC work (broadly speaking) stays fixed,
the pacer is then concerned with figuring out how early it should start such
that it meets its goal.
Because they should happen in the *same* amount of time, this question of "how
early" is answered in "bytes allocated so far."

So what's this more fundamental value? Suppose we model a Go program as such:
the world is split in two while a GC is active: the application is either
spending time on itself and potentially allocating, or on performing GC work.
This model is "zero-sum," in a sense: if more time is spent on GC work, then
less time is necessarily spent on the application and vice versa.
Given this model, suppose we had two measures of program behavior during a GC
cycle: how often the application is allocating, and how rapidly the GC can scan
and mark memory.
Note that these measure are *not* peak throughput.
They are a measure of the rates, in actuality, of allocation and GC work happens
during a GC.
To give them a concrete unit, let's say they're bytes per cpu-seconds per core.
The idea with this unit is to have some generalized, aggregate notion of this
behavior, independent of available CPU resources.
We'll see why this is important shortly.
Lets call these rates `$a$` and `$s$` respectively.
In the steady-state, these rates aren't changing, so we can use them to predict
when to start a garbage collection.

Coming back to our model, some amount of CPU time is going to go to each of
these activities.
Let's say our target GC CPU utilization in the steady-state is `$u_t$`.
If `$C$` is the number of CPU cores available and `$t$` is some wall-clock time
window, then `$a(1-u_t)Ct$` bytes will be allocated and `$s u_t Ct$` bytes will
be scanned in that window.

Notice that *ratio* of "bytes allocated" to "bytes scanned" is constant in the
steady-state in this model, because both `$a$` and `$s$` are constant.
Let's call this ratio `$r$`.
To make things a little more general, let's make `$r$` also a function of
utilization `$u$`, because part of the Go garbage collector's design is the
ability to dynamically change CPU utilization to keep it on-pace.

```render-latex
r(u) = \frac{a(1-u)Ct}{suCt}
```

The big idea here is that this value, `$r(u)$` is a *conversion rate* between
these two notions of time.

Consider the following: in the steady-state, the runtime can perfectly back out
the correct time to start a GC cycle, given that it knows exactly how much work
it needs to do.
Let `$T_n$` be the trigger point for GC cycle `$n$`.
Let `$P_n$` be the size of the live *scannable* heap at the end of GC `$n$`.
More precisely, `$P_n$` is the subset of `$M_n$` that contains pointers.
Why include only pointer-ful memory? Because GC work is dominated by the cost of
the scan loop, and each pointer that is found is marked; memory containing Go
types without pointers are never touched, and so are totally ignored by the GC.
Furthermore, this *does* include non-pointers in pointer-ful memory, because
scanning over those is a significant cost in GC, enough so that GC is roughly
proportional to it, not just the number of pointer slots.
In the steady-state, the size of the scannable heap should not change, so
`$P_n$` remains constant.

```render-latex
T_n = N_n - r(u_t)(P_{n-1} + S_n + G_n)
```

That's nice, but we don't know `$r$` while the runtime is executing.
And worse, it could *change* over time.

But if the Go runtime can somehow accurately estimate and predict `$r$` then it
can find a steady-state.

Suppose we had some prediction of `$r$` for GC cycle `$n$` called `$r_n$`.
Then, our trigger condition is a simple extension of the formula above.
Let `$A$` be the size of the Go live heap at any given time.
`$A$` is thus monotonically increasing during a GC cycle, and then
instantaneously drops at the end of the GC cycle.
In essence `$A$` *is* the classic GC sawtooth pattern.

```render-latex
A \ge N_n - r_n(u_t)(P_{n-1} + S_n + G_n)
```

Note that this formula is in fact a *condition* and not a predetermined trigger
point, like the trigger ratio.
In fact, this formula could transform into the previous formula for `$T_n$` if
it were not for the fact that `$S_n$` actively changes during a GC cycle, since
the rest of the values are constant for each GC cycle.

A big question remains: how do we predict `$r$`?

To answer that, we first need to determine how to measure `$r$` at all.
I propose a straightforward approximation: each GC cycle, take the amount of
memory allocated, divide it by the amount of memory scanned, and scale it from
the actual GC CPU utilization to the target GC CPU utilization.
Note that this scaling factor is necessary because we want our trigger to use an
`$r$` value that is at the target utilization, such that the GC is given enough
time to *only* use that amount of CPU.
This note is a key aspect of the proposal and will come up later.

What does this scaling factor look like? Recall that because of our model, any
value of `$r$` has a `$1-u$` factor in the numerator and a `$u$` factor in the
denominator.
Scaling from one utilization to another is as simple as switching out factors.

Let `$\hat{A}_n$` be the actual peak live heap size at the end of a GC cycle (as
opposed to `$N_n$`, which is only a target).
Let `$u_n$` be the GC CPU utilization over cycle `$n$` and `$u_t$` be the target
utilization.
Altogether,

```render-latex
r_{measured} \textrm{ for GC } n = \frac{\hat{A}_n - T_n}{M_n + S_n + G_n}\frac{(1-u_t)u_n}{(1-u_n)u_t}
```

Now that we have a way to measure `$r$`, we could use this value directly as our
prediction.
But I fear that using it directly has the potential to introduce a significant
amount of noise, so smoothing over transient changes to this value is desirable.
To do so, I propose using this measurement as the set-point for a
proportional-integral (PI) controller.

The advantage of a PI controller over a proportional controller is that it
guarantees that steady-state error will be driven to zero.
Note that the current GC pacer has issues with offset error.
It may also find the wrong point on the isocline of GC CPU utilization and peak
heap size because the error term can go to zero even if both targets are missed.
The disadvantage of a PI controller, however, is that it oscillates and may
overshoot significantly on its way to reaching a steady value.
This disadvantage could be mitigated by overdamping the controller, but I
propose we tune it using the tried-and-tested standard Ziegler-Nichols method.
In simulations (see [the simulations section](#simulations)) this tuning tends
to work well.
It's worth noting that PI (more generally, PID controllers) have a lot of years
of research and use behind them, and this design lets us take advantage of that
and tune the pacer further if need be.

Why a PI controller and not a PID controller? The PI controllers are simpler to
reason about, and the derivative term in a PID controller tends to be sensitive
to high-frequency noise.
The advantage of the derivative term is a shorter rise time, but simulations
show that the rise time is roughly 1 GC cycle, so I don't think there's much
reason to include it just yet.
Adding the derivative term though is trivial once the rest of the design is in
place, so the door is always open.

By focusing on this `$r$` value, we've now reframed the pacing problem as a
search problem instead of an optimization problem.
That raises question: are we still reaching our optimization goals? And how do
GC assists fit into this picture?

The good news is that we're always triggering for the right CPU utilization.
Because `$r$` being scaled for the *target* GC CPU utilization and `$r$` picks
the trigger, the pacer will naturally start at a point that will generate a
certain utilization in the steady-state.

Following from this fact, there is no longer any reason to have the target GC
CPU utilization be 30%.
Originally, in the design for the current pacer, the target GC CPU utilization,
began at 25%, with GC assists always *extending* from that, so in the
steady-state there would be no GC assists.
However, because the pacer was structured to solve an optimization problem, it
required feedback from both directions.
That is, it needed to know whether it was actinng too aggressively *or* not
aggressively enough.
This feedback could only be obtained by actually performing GC assists.
But with this design, that's no longer necessary.
The target CPU utilization can completely exclude GC assists in the steady-state
with a mitigated risk of bad behavior.

As a result, I propose the target utilization be reduced once again to 25%,
eliminating GC assists in the steady-state (that's not out-pacing the GC), and
potentially improving application latency as a result.

### Smoothing out GC assists

This discussion of GC assists brings us to the existing issues around pacing
decisions made *while* the GC is active (which I will refer to as the "GC assist
pacer" below).
For the most part, this system works very well, and is able to smooth over small
hiccups in performance, due to noise from the underlying platform or elsewhere.

Unfortunately, there's one place where it doesn't do so well: the hard heap
goal.
Currently, the GC assist pacer prevents memory blow-up in pathological cases by
ramping up assists once either the GC has found more work than it expected (i.e.
the live scannable heap has grown) or the GC is behind and the application's
heap size has exceeded the heap goal.
In both of these cases, it sets a somewhat arbitrarily defined hard limit at
1.1x the heap goal.

The problem with this policy is that high `GOGC` values create the opportunity
for very large changes in live heap size, because the GC has quite a lot of
runway (consider an application with `GOGC=51100` has a steady-state live heap
of size 10 MiB and suddenly all the memory it allocates is live).
In this case, the GC assist pacer is going to find all this new live memory and
panic: the rate of assists will begin to skyrocket.
This particular problem impedes the adoption of any sort of target heap size, or
configurable minimum heap size.
One can imagine a small live heap with a large target heap size as having a
large *effective* `GOGC` value, so it reduces to exactly the same case.

To deal with this, I propose modifying the GC assist policy to set a hard heap
goal of `$\gamma N_n$`.
The intuition behind this goal is that if *all* the memory allocated in this GC
cycle turns out to be live, the *next* GC cycle will end up using that much
memory *anyway*, so we let it slide.

But this hard goal need not be used for actually pacing GC assists other than in
extreme cases.
In fact, it must not, because an assist ratio computed from this hard heap goal
and the worst-case scan work turns out to be extremely loose, leading to the GC
assist pacer consistently missing the heap goal in some steady-states.

So, I propose an alternative calculation for the assist ratio.
I believe that the assist ratio must always pass through the heap goal, since
otherwise there's no guarantee that the GC meets its heap goal in the
steady-state (which is a fundamental property of the pacer in Go's existing GC
design).
However, there's no reason why the ratio itself needs to change dramatically
when there's more GC work than expected.
In fact, the preferable case is that it does not, because that lends itself to a
much more even distribution of GC assist work across the cycle.

So, I propose that the assist ratio be an extrapolation of the current
steady-state assist ratio, with the exception that it now include non-heap GC
work as the rest of this document does.

That is,

```render-latex
\begin{aligned}
\textrm{max scan work} & = T_n + S_n + G_n \\
\textrm{extrapolated runway} & = \frac{N_n - T_n}{P_{n-1} + S_n + G_n} (T_n + S_n + G_n) \\
\textrm{assist ratio} & = \frac{\textrm{extrapolated runway}}{\textrm{max scan work}}
\end{aligned}
```

This definition is intentially roundabout.
The assist ratio changes dynamically as the amount of GC work left decreases and
the amount of memory allocated increases.
This responsiveness is what allows the pacing mechanism to be so robust.

Today, the assist ratio is calculated by computing the remaining heap runway and
the remaining expected GC work, and dividing the former by the latter.
But of course, that's not possible if there's more GC work than expected, since
then the assist ratio could go negative, which is meaningless.

So that's the purpose defining the "max scan work" and "extrapolated runway":
these are worst-case values that are always safe to subtract from, such that we
can maintain roughly the same assist ratio throughout the cycle (assuming no
hiccups).

One minor details is that the "extrapolated runway" needs to be capped at the
hard heap goal to prevent breaking that promise, though in practice this will
almost.
The hard heap goal is such a loose bound that it's really only useful in
pathological cases, but it's still necessary to ensure robustness.

A key point in this choice is that the GC assist pacer will *only* respond to
changes in allocation behavior and scan rate, not changes in the *size* of the
live heap.
This point seems minor, but it means the GC assist pacer's function is much
simpler and more predictable.

## Remaining unanswered questions

Not every problem listed in issue
[#42430](https://github.com/golang/go/issues/42430) is resolved by this design,
though many are.

Notable exclusions are:
1. Mark assists are front-loaded in a GC cycle.
1. The hard heap goal isn't actually hard in some circumstances.
1. Dealing with idle GC workers.
1. Donating goroutine assist credit/debt on exit.
1. Existing trigger limits to prevent unbounded memory growth.

(1) is difficult to resolve without special cases and arbitrary heuristics, and
I think in practice it's OK; the system was fairly robust and will now be more
so to this kind of noise.
That doesn't mean that it shouldn't be revisited, but it's not quite as big as
the other problems, so I leave it outside the scope of this proposal.

(2) is also tricky and somewhat orthogonal.
I believe the path forward there involves better scheduling of fractional GC
workers, which are currently very loosely scheduled.
This design has made me realize how important dedicated GC workers are to
progress, and how GC assists are a back-up mechanism.
I believe that the fundamental problem there lies with the fact that fractional
GC workers don't provide that sort of consistent progress.

For (3) I believe we should remove idle GC workers entirely, which is why this
document ignores them.
Idle GC workers are extra mark workers that run if the application isn't
utilizing all GOMAXPROCS worth of parallelism.
The scheduler schedules "low priority" background workers on any additional CPU
resources, and this ultimately skews utilization measurements in the GC, because
as of today they're unaccounted for.
Unfortunately, it's likely that idle GC workers have accidentally become
necessary for the GC to make progress, so just pulling them out won't be quite
so easy.
I believe that needs a separate proposal given other large potential changes
coming to the compiler and runtime in the near future, because there's
unfortunately a fairly significant risk of bugs with doing so, though I do think
it's ultimately an improvement.
See [the related issue for more
details](https://github.com/golang/go/issues/44163).

(4) is easy and I don't believe needs any deliberation.
That is a bug we should simply fix.

For (5), I propose we retain the limits, translated to the current design.
For reference, these limits are `$0.95 (\gamma - 1)$` as the upper-bound on the
trigger ratio, and `$0.6 (\gamma - 1)$` as the lower-bound.

The upper bound exists to prevent ever starting the GC too late in low-activity
scenarios.
It may cause consistent undershoot, but prevents issues in GC pacer calculations
by preventing the calculated runway from ever being too low.
The upper-bound may need to be revisited when considering a configurable target
heap size.

The lower bound exists to prevent the application from causing excessive memory
growth due to floating garbage as the application's allocation rate increases.
Before that limit was installed, it wasn't very easy for an application to
allocate hard enough for that to happen.
The lower bound probably should be revisited, but I leave that outside of the
scope of this document.

To translate them to the current design, I propose we simply modify the trigger
condition to include these limits.
It's not important to put these limits in the rest of the pacer because it no
longer tries to compute the trigger point ahead of time.

### Initial conditions

Like today, the pacer has to start somewhere for the first GC.
I propose we carry forward what we already do today: set the trigger point at
7/8ths of the first heap goal, which will always be the minimum heap size.
If GC 1 is the first GC, then in terms of the math above, we choose to avoid
defining `$M_0$`, and instead directly define

```render-latex
\begin{aligned}
N_1 & = \textrm{minimum heap size} \\
T_1 & = \frac{7}{8} N_1 \\
P_0 & = 0
\end{aligned}
```

The definition of `$P_0$` is necessary for the GC assist pacer.

Furthermore, the PI controller's state will be initialized to zero otherwise.

These choices are somewhat arbitrary, but the fact is that the pacer has no
knowledge of the progam's past behavior for the first GC.
Naturally the behavior of the GC will always be a little odd, but it should, in
general, stabilize quite quickly (note that this is the case in each scenario
for the [simulations](#simulations).

## A note about CPU utilization

This document uses the term "GC CPU utilization" quite frequently, but so far
has refrained from defining exactly how it's measured.
Before doing that, let's define CPU utilization over a GC mark phase, as it's
been used so far.
First, let's define the mark phase: it is the period of wall-clock time between
the end of sweep termination and the start of mark termination.
In the mark phase, the process will have access to some total number of
CPU-seconds of execution time.
This CPU time can then be divided into "time spent doing GC work" and "time
spent doing anything else."
GC CPU utilization is then defined as a proportion of that total CPU time that
is spent doing GC work.

This definition seems straightforward enough but in reality it's more
complicated.
Measuring CPU time on most platforms is tricky, so what Go does today is an
approximation: take the wall-clock time of the GC mark phase, multiply it by
`GOMAXPROCS`.
Call this $`T`$.
Take 25% of that (representing the dedicated GC workers) and add total amount of
time all goroutines spend in GC assists.
The latter is computed directly, but is just the difference between the start
and end time in the critical section; it does not try to account for context
switches forced by the underlying system, or anything like that.
Now take this value we just computed and divide it by `$T$`.
That's our GC CPU utilization.

This approximation is mostly accurate in the common case, but is prone to skew
in various scenarios, such as when the system is CPU-starved.
This fact can be problematic, but I believe it is largely orthogonal to the
content of this document; we can work on improving this approximation without
having to change any of this design.
It already assumes that we have a good measure of CPU utilization.

## Alternatives considered

The alternatives considered for this design basically boil down to its
individual components.

For instance, I considered grouping stacks and globals into the current
formulation of the pacer, but that adds another condition to the definition of
the steady-state: stacks and globals do not change.
That makes the steady-state more fragile.

I also considered a design that was similar, but computed everything in terms of
an "effective" `GOGC`, and "converted" that back to `GOGC` for pacing purposes
(that is, what would the heap trigger have been had the expected amount of live
memory been correct?).
This formulation is similar to how Austin formulated the experimental
`SetMaxHeap` API.
Austin suggested I avoid this formulation because math involving `GOGC` tends to
have to work around infinities.
A good example of this is if `runtime.GC` is called while `GOGC` is off: the
runtime has to "fake" a very large `GOGC` value in the pacer.
By using a ratio of rates that's more grounded in actual application behavior
the trickiness of the math is avoided.

I also considered not using a PI controller and just using the measured `$r$`
value directly, assuming it doesn't change across GC cycles, but that method is
prone to noise.

## Justification

Pros:
- The steady-state is now independent of the amount of GC work to be done.
- Steady-state mark assist drops to zero if not allocating too heavily (a likely
  latency improvement in many scenarios) (see the "high `GOGC`" scenario in
  [simulations](#simulations)).
- GC amortization includes non-heap GC work, and responds well in those cases.
- Eliminates offset error present in the existing design.

Cons:
- Definition of `GOGC` has changed slightly, so a `GOGC` of 100 will use
  slightly more memory in nearly all cases.
- `$r$` is a little bit unintuitive.

## Implementation

This pacer redesign will be implemented by Michael Knyszek.

1. The existing pacer will be refactored into a form fit for simulation.
1. A comprehensive simulation-based test suite will be written for the pacer.
1. The existing pacer will be swapped out with the new implementation.

The purpose of the simulation infrastructure is to make the pacer, in general,
more testable.
This lets us write regression test cases based on real-life problems we
encounter and confirm that they don't break going forward.
Furthermore, with fairly large changes to the Go compiler and runtime in the
pipeline, it's especially important to reduce the risk of this change as much as
possible.

## Go 1 backwards compatibility

This change will not modify any user-visible APIs, but may have surprising
effects on application behavior.
The two "most" incompatible changes in this proposal are the redefinition of the
heap goal to include non-heap sources of GC work, since that directly influences
the meaning of `GOGC`, and the change in target GC CPU utilization.
These two factors together mean that, by default and on average, Go applications
will use slightly more memory than before.
To obtain previous levels of memory usage, users may be required to tune down
`GOGC` lower manually, but the overall result should be more consistent, more
predictable, and more efficient.

## Simulations

In order to show the effectiveness of the new pacer and compare it to the
current one, I modeled both the existing pacer and the new pacer and simulated
both in a variety of scenarios.

The code used to run these simulations and generate the plots below may be found
at [github.com/mknyszek/pacer-model](https://github.com/mknyszek/pacer-model).

### Assumptions and caveats

The model of each pacer is fairly detailed, and takes into account most details
like allocations made during a GC being marked.
The one big assumption it makes, however, is that the behavior of the
application while a GC cycle is running is perfectly smooth, such that the GC
assist pacer is perfectly paced according to the initial assist ratio.
In practice, this is close to true, but it's worth accounting for the more
extreme cases.
(TODO: Show simulations that inject some noise into the GC assist pacer.)

Another caveat with the simulation is the graph of "R value" (that is, `$r_n$`),
and "Alloc/scan ratio."
The latter is well-defined for all simulations (it's a part of the input) but
the former is not a concept used in the current pacer.
So for simulations of the current pacer, the "R value" is backed out from the
trigger ratio: we know the runway, we know the *expected* scan work for the
target utilization, so we can compute the `$r_n$` that the trigger point
encodes.

### Results

**Perfectly steady heap size.**

The simplest possible scenario.

Current pacer:

![](44167/pacer-plots/old-steady.png)

New pacer:

![](44167/pacer-plots/new-steady.png)

Notes:
- The current pacer doesn't seem to find the right utilization.
- Both pacers do reasonably well at meeting the heap goal.

**Jittery heap size and alloc/scan ratio.**

A mostly steady-state heap with a slight jitter added to both live heap size and
the alloc/scan ratio.

Current pacer:

![](44167/pacer-plots/old-jitter-alloc.png)

New pacer:

![](44167/pacer-plots/new-jitter-alloc.png)

Notes:
- Both pacers are resilient to a small amount of noise.

**Small step in alloc/scan ratio.**

This scenario demonstrates the transitions between two steady-states, that are
not far from one another.

Current pacer:

![](44167/pacer-plots/old-step-alloc.png)

New pacer:

![](44167/pacer-plots/new-step-alloc.png)

Notes:
- Both pacers react to the change in alloc/scan rate.
- Clear oscillations in utilization visible for the new pacer.

**Large step in alloc/scan ratio.**

This scenario demonstrates the transitions between two steady-states, that are
further from one another.

Current pacer:

![](44167/pacer-plots/old-heavy-step-alloc.png)

New pacer:

![](44167/pacer-plots/new-heavy-step-alloc.png)

Notes:
- The old pacer consistently overshoots the heap size post-step.
- The new pacer minimizes overshoot.

**Large step in heap size with a high `GOGC` value.**

This scenario demonstrates the "high `GOGC` problem" described in the [GC pacer
meta-issue](https://github.com/golang/go/issues/42430).

Current pacer:

![](44167/pacer-plots/old-high-GOGC.png)

New pacer:

![](44167/pacer-plots/new-high-GOGC.png)

Notes:
- The new pacer's heap size stabilizes faster than the old pacer's.
- The new pacer has a spike in overshoot; this is *by design*.
- The new pacer's utilization is independent of this heap size spike.
- The old pacer has a clear spike in utilization.

**Oscillating alloc/scan ratio.**

This scenario demonstrates an oscillating alloc/scan ratio.
This scenario is interesting because it shows a somewhat extreme case where a
steady-state is never actually reached for any amount of time.
However, this is not a realistic scenario.

Current pacer:

![](44167/pacer-plots/old-osc-alloc.png)

New pacer:

![](44167/pacer-plots/new-osc-alloc.png)

Notes:
- The new pacer tracks the oscillations worse than the old pacer.
  This is likely due to the error never settling, so the PI controller is always
  overshooting.

**Large amount of goroutine stacks.**

This scenario demonstrates the "heap amortization problem" described in the [GC
pacer meta-issue](https://github.com/golang/go/issues/42430) for goroutine
stacks.

Current pacer:

![](44167/pacer-plots/old-big-stacks.png)

New pacer:

![](44167/pacer-plots/new-big-stacks.png)

Notes:
- The old pacer consistently overshoots because it's underestimating the amount
  of work it has to do.
- The new pacer uses more memory, since the heap goal is now proportional to
  stack space, but it stabilizes and is otherwise sane.

**Large amount of global variables.**

This scenario demonstrates the "heap amortization problem" described in the [GC
pacer meta-issue](https://github.com/golang/go/issues/42430) for global
variables.

Current pacer:

![](44167/pacer-plots/old-big-globals.png)

New pacer:

![](44167/pacer-plots/new-big-globals.png)

Notes:
- This is essentially identical to the stack space case.

**High alloc/scan ratio.**

This scenario shows the behavior of each pacer in the face of a very high
alloc/scan ratio, with jitter applied to both the live heap size and the
alloc/scan ratio.

Current pacer:

![](44167/pacer-plots/old-heavy-jitter-alloc.png)

New pacer:

![](44167/pacer-plots/new-heavy-jitter-alloc.png)

Notes:
- In the face of a very high allocation rate, the old pacer consistently
  overshoots, though both maintain a similar GC CPU utilization.
