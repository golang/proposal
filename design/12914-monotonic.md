# Proposal: Monotonic Elapsed Time Measurements in Go

Author: Russ Cox

Last updated: January 26, 2017<br>
Discussion: [https://golang.org/issue/12914](https://golang.org/issue/12914).<br>
URL: https://golang.org/design/12914-monotonic

## Abstract

Comparison and subtraction of times observed by `time.Now` can return incorrect
results if the system wall clock is reset between the two observations.
We propose to extend the `time.Time` representation to hold an
additional monotonic clock reading for use in those calculations.
Among other benefits, this should make it impossible for a basic elapsed time
measurement using `time.Now` and `time.Since` to report a negative duration
or other result not grounded in reality.

## Background

### Clocks

A clock never keeps perfect time.
Eventually, someone notices,
decides the accumulated error—compared to a reference clock deemed more reliable—is
large enough to be worth fixing,
and resets the clock to match the reference.
As I write this, the watch on my wrist is 44 seconds ahead of the clock on my computer.
Compared to the computer, my watch gains about five seconds a day.
In a few days I will probably be bothered enough to reset it to match the computer.

My watch may not be perfect for identifying the precise
moment when a meeting should begin,
but it's quite good for measuring elapsed time.
If I start timing an event by checking the time,
and then I stop timing the event by checking again
and subtracting the two times,
the error contributed by the watch speed
will be under 0.01%.

Resetting a clock makes it better for telling time
but useless, in that moment, for measuring time.
If I reset my watch to match my computer while I am timing an event,
the time of day it shows is now more accurate,
but subtracting the start and end times for the event
will produce a measurement that includes the reset.
If I turn my watch back 44 seconds
while timing a 60-second event, I would 
(unless I correct for the reset)
measure the event as taking 16 seconds.
Worse, I could measure a 10-second event
as taking −34 seconds, ending before it began.

Since I know the watch is consistently
gaining five seconds per day,
I could reduce the need for resets
by taking it to a watchmaker to adjust the
mechanism to tick ever so slightly slower.
I could also reduce the size of the resets
by doing them more often.
If, five times a day at regular intervals,
I stopped my watch for one second,
I wouldn't ever need a 44-second reset,
reducing the maximum possible error
introduced in the timing of an event.
Similarly, if instead my watch lost five seconds each day,
I could turn it forward one second five times a day
to avoid larger forward resets.

### Computer clocks

All the same problems affect computer clocks,
usually with smaller time units.

Most computers have some kind of
high-precision clock and a way to convert ticks of that clock
to an equivalent number of seconds.
Often, software on the computer compares that
clock to a higher-accuracy reference clock
[accessed over the network](https://tools.ietf.org/html/rfc5905).
If the local clock is observed to be
slightly ahead, it can be slowed a little
by dropping an occasional tick;
if slightly behind, sped up by counting some ticks twice.
If the local clock is observed to run at a
consistent speed relative to the reference clock
(for example, five seconds fast per day),
the software can change the conversion formula,
making the slight corrections less frequent.
These minor adjustments, applied regularly,
can keep the local clock matched to the reference clock 
without observable resets,
giving the outward appearance of a perfectly synchronized clock.

Unfortunately, many systems fall short of this
appearance of perfection, for two main reasons.

First, some computer clocks are unreliable or
don't run at all when the computer is off.
The time starts out very wrong.
After learning the correct time from the network,
the only correction option is a reset.

Second, most computer time representations ignore leap seconds,
in part because leap seconds—unlike leap years—follow no predictable pattern:
the [IERS decides about six months in advance](https://en.wikipedia.org/wiki/Leap_second)
whether to insert (or in theory remove)
a leap second at the end of a particular calendar month.
In the real world, the leap second 23:59:60 UTC is inserted
between 23:59:59 UTC and 00:00:00 UTC.
Most computers, unable to represent 23:59:60,
instead insert a clock reset and repeat 23:59:59.

Just like my watch,
resetting a computer clock makes it better for telling time
but useless, in that moment, for measuring time.
Entering a leap second, 
the clock might report 23:59:59.995 at one instant
and then report 23:59:59.005 ten milliseconds later;
subtracting these to compute elapsed time results in 
−990 ms instead of +10 ms.

To avoid the problem of measuring elapsed times across clock resets,
operating systems provide access to two different clocks:
a wall clock and a monotonic clock.
Both are adjusted to move forward at a target rate of one clock second per real second,
but the monotonic clock starts at an undefined absolute value and is never reset.
The wall clock is for telling time;
the monotonic clock is for measuring time.

C/C++ programs use the operating system-provided mechanisms
for querying one clock or the other.
Java's [`System.nanoTime`](https://docs.oracle.com/javase/8/docs/api/java/lang/System.html#nanoTime--)
is widely believed to read a monotonic clock where available,
returning an int64 counting nanoseconds since an arbitrary start point.
Python 3.3 added monotonic clock support in [PEP 418](https://www.python.org/dev/peps/pep-0418/).
The new function `time.monotonic` reads the monotonic clock, returning a float64 counting seconds since
an arbitrary start point; the old function `time.time` reads the system wall clock,
returning a float64 counting seconds since 1970.

### Go time

Go's current [time API](https://golang.org/pkg/time/),
which Rob Pike and I designed in 2011,
defines an opaque type `time.Time`,
a function `time.Now` that returns the current time,
and a method `t.Sub(u)` to subtract two times,
along with other methods interpreting a `time.Time` as a wall clock time.
These are widely used by Go programs to measure elapsed times.
The implementation of these functions only reads the system wall clock,
never the monotonic clock,
making the measurements incorrect in the event of clock resets.

Go's original target was Google's production servers, on which
the wall clock never resets: the time is set very early in
system startup, before any Go software runs,
and leap seconds are handled by a [leap smear](https://developers.google.com/time/smear#standardsmear),
spreading the extra second
over a 20-hour window in which the clock runs at 99.9986% speed
(20 hours on that clock corresponds to 20 hours and one second
in the real world).
In 2011, I hoped that the trend toward reliable, reset-free computer clocks
would continue and that Go programs could safely use the system wall clock
to measure elapsed times.
I was wrong.
Although Akamai, Amazon, and Microsoft use leap smears now too,
many systems still implement leap seconds by clock reset.
A Go program measuring a negative elapsed time during a leap second
caused [CloudFlare's recent DNS outage](https://blog.cloudflare.com/how-and-why-the-leap-second-affected-cloudflare-dns/).
Wikipedia's 
[list of examples of problems associated with the leap second](https://en.wikipedia.org/wiki/Leap_second#Examples_of_problems_associated_with_the_leap_second)
now includes CloudFlare's outage and
notes Go's time APIs as the root cause.
Beyond the problem of leap seconds, Go has also expanded to systems
in non-production environments
that may have less well-regulated clocks and consequently
more frequent clock resets.
Go must handle clock resets gracefully.

The internals of both the Go runtime and the Go time package
originally used wall time but have already been converted as much as possible
(without changing exported APIs)
to use the monotonic clock.
For example, if a goroutine runs `time.Sleep(1*time.Minute)` and then
the wall clock resets backward one hour,
in the original Go implementation that goroutine would have slept for
61 real minutes.
Today, that goroutine always sleeps for only 1 real minute.
All other time APIs using `time.Duration`, such as
`time.After`, `time.Tick`, and `time.NewTimer`,
have similarly been converted to implement those durations
using the monotonic clock.

Three standard Go APIs remain that use the system wall clock that should
more properly use the monotonic clock.
Due to [Go 1 compatibility](https://golang.org/doc/go1compat),
the types and method names used in the APIs cannot be changed.

The first problematic Go API is measurement of elapsed times.
Much code exists that uses patterns like:

	start := time.Now()
	... something ...
	end := time.Now()
	elapsed := start.Sub(end)

or, equivalently:

	start := time.Now()
	... something ...
	elapsed := time.Since(start)

Because today `time.Now` reads the wall clock,
those measurements are wrong if the wall clock resets
between calls,
as happened at CloudFlare.

The second problematic Go API is network connection timeouts.
Originally, the `net.Conn` interface included methods to set timeouts in terms of durations:

	type Conn interface {
		...
		SetTimeout(d time.Duration)
		SetReadTimeout(d time.Duration)
		SetWriteTimeout(d time.Duration)
	}

This API confused users: it wasn't clear whether the duration measurement began
when the timeout was set or began anew at each I/O operation.
That is, if you call `SetReadTimeout(100*time.Millisecond)`,
does every `Read` call wait 100ms before timing out,
or do all `Read`s simply stop working 100ms after the call to `SetReadTimeout`?
To avoid this confusion, we changed and renamed the APIs for Go 1 to use
deadlines represented as `time.Time`s:

	type Conn interface {
		...
		SetDeadline(t time.Time)
		SetReadDeadline(t time.Time)
		SetWriteDeadline(t time.Time)
	}

These are almost always invoked by adding a duration to the current time, as in
`c.SetDeadline(time.Now().Add(5*time.Second))`,
which is longer but clearer than `SetTimeout(5*time.Second)`.

Internally, the standard implementations of `net.Conn` implement
deadlines by converting the wall clock time to monotonic clock time
immediately.
In the call `c.SetDeadline(time.Now().Add(5*time.Second))`,
the deadline exists in wall clock form only for the hundreds of nanoseconds
between adding the current wall clock time while preparing the argument
and subtracting it again at the start of `SetDeadline`.
Even so, if the system wall clock resets
during that tiny window, the deadline will be extended or contracted
by the reset amount,
resulting in possible hangs or spurious timeouts.

The third problematic Go API is [context deadlines](https://golang.org/pkg/context/#Context).
The `context.Context` interface defines a method that returns a `time.Time`:

	type Context interface {
		Deadline() (deadline time.Time, ok bool)
		...
	}

Context uses a time instead of a duration for much the same
reasons as `net.Conn`: the returned deadline
may be stored and consulted occasionally,
and using a fixed `time.Time` makes those later
consultations refer to a fixed instant instead of a floating one.

In addition to these three standard APIs, there are any number of
APIs outside the standard library that also use `time.Time`s in similar ways.
For example a common metrics collection package encourages
users to time functions by:

	defer metrics.MeasureSince(description, time.Now())

It seems clear that Go must better support
computations involving elapsed times, including checking deadlines:
wall clocks do reset and cause problems on systems where Go runs.

A survey of existing Go usage suggests that about 30%
of the calls to `time.Now` (by source code appearance, not dynamic call count)
are used for measuring elapsed time and should use the system monotonic clock.
Identifying and fixing all of these would be a large undertaking,
as would developer education to correct future uses.

## Proposal

For both backwards compatibility and API simplicity, 
we propose not to introduce
any new API in the time package exposing the idea of monotonic clocks.

Instead, we propose to change `time.Time` to store both a wall clock reading
and an optional, additional monotonic clock reading;
to change `time.Now` to read both clocks and return a `time.Time` containing both readings;
to change `t.Add(d)` to return a `time.Time` in which both readings (if present)
have been adjusted by `d`;
and to change `t.Sub(u)` to operate on monotonic clock times
when both `t` and `u` have them.
In this way, developers keep using `time.Now` always,
leaving the implementation to follow the rule:
use the wall clock for telling time, the monotonic clock for measuring time.

More specifically, we propose to make these changes to the [package time documentation](https://golang.org/pkg/time/),
along with corresponding changes to the implementation.

Add this paragraph to the end of the `time.Time` documentation:

> In addition to the required “wall clock” reading, a Time may contain an
> optional reading of the current process's monotonic clock,
> to provide additional precision for comparison or subtraction.
> See the “Monotonic Clocks” section in the package documentation
> for details.

Add this section to the end of the package documentation:

> Monotonic Clocks
>
> Operating systems provide both a “wall clock,” which is subject
> to resets for clock synchronization, and a “monotonic clock,” which is not.
> The general rule is that the wall clock is for telling time and the
> monotonic clock is for measuring time.
> Rather than split the API, in this package the Time returned by time.Now
> contains both a wall clock reading and a monotonic clock reading;
> later time-telling operations use the wall clock reading,
> but later time-measuring operations, specifically comparisons
> and subtractions, use the monotonic clock reading.
>
> For example, this code always computes a positive elapsed time of 
> approximately 20 milliseconds, even if the wall clock is reset
> during the operation being timed:
>
>     start := time.Now()
>     ... operation that takes 20 milliseconds ...
>     t := time.Now()
>     elapsed := t.Sub(start)
>
> Other idioms, such as time.Since(start), time.Until(deadline),
> and time.Now().Before(deadline), are similarly robust against
> wall clock resets.
>
> The rest of this section gives the precise details of how operations
> use monotonic clocks, but understanding those details is not required 
> to use this package.
>
> The Time returned by time.Now contains a monotonic clock reading.
> If Time t has a monotonic clock reading, t.Add(d), t.Round(d),
> or t.Truncate(d) adds the same duration to both the wall clock 
> and monotonic clock readings to compute the result.
> Similarly, t.In(loc), t.Local(), or t.UTC(), which are defined to change
> only the Time's Location, pass any monotonic clock reading
> through unmodified.
> Because t.AddDate(y, m, d) is a wall time computation,
> it always strips any monotonic clock reading from its result.
>
> If Times t and u both contain monotonic clock readings, the operations
> t.After(u), t.Before(u), t.Equal(u), and t.Sub(u) are carried out using
> the monotonic clock readings alone, ignoring the wall clock readings.
> (If either t or u contains no monotonic clock reading, these operations
> use the wall clock readings.)
>
> Note that the Go == operator includes the monotonic clock reading in its comparison.
> If time values returned from time.Now and time values constructed by other means
> (for example, by time.Parse or time.Unix) are meant to compare equal when used
> as map keys, the times returned by time.Now must have the monotonic clock
> reading stripped, by setting t = t.AddDate(0, 0, 0).
> In general, prefer t.Equal(u) to t == u, since t.Equal uses the most accurate
> comparison available and correctly handles the case when only one of its
> arguments has a monotonic clock reading.

## Rationale

### Design

The main design question is whether to overload `time.Time`
or to provide a separate API for accessing the monotonic clock.

Most other systems provide separate APIs to read the wall clock
and the monotonic clock, leaving the developer to decide
between them at each use, hopefully by applying the rule stated above:
“The wall clock is for telling time.
The monotonic clock is for measuring time.”

if a developer uses a wall clock to measure time,
that program will work correctly, almost always,
except in the rare event of a clock reset.
Providing two APIs that behave the same 99% of the time
makes it very easy (and likely) for a developer to write
a program that fails only rarely and not notice.

It gets worse.
The program failures aren't random, like a race condition:
they're caused by external events, namely clock resets.
The most common clock reset in a well-run production setting
is the leap second, which occurs simultaneously on all systems.
When it does, all the copies of the program
across the entire distributed system fail simultaneously,
defeating any redundancy the system might have had.

So providing two APIs makes it very easy (and likely)
for a developer to write programs that fail only rarely,
but typically all at the same time.

This proposal instead treats the monotonic clock not as
a new concept for developers to learn but instead as an
implementation detail that can improve the accuracy of
measuring time with the existing API.
Developers don't need to learn anything new,
and the obvious code just works.
The implementation applies the rule;
the developer doesn't have to think about it.

As noted earlier,
a survey of existing Go usage (see Appendix below)
suggests that about 30% of calls to `time.Now`
are used for measuring elapsed time and should use a monotonic clock.
The same survey shows that all of those calls 
are fixed by this proposal, with no change in the programs themselves.

### Simplicity

It is certainly simpler, in terms of implementation,
to provide separate routines to read the wall clock and
the monotonic clock and leave proper usage to developers.
The API in this proposal is a bit more complex to specify
and to implement but much simpler for developers to use.

No matter what, the effects of clock resets, especially leap seconds,
can be counterintuitive.

Suppose a program starts just before a leap second:

	t1 := time.Now()
	... 10 ms of work
	t2 := time.Now()
	... 10 ms of work
	t3 := time.Now()
	... 10 ms of work
	const f = "15:04:05.000"
	fmt.Println(t1.Format(f), t2.Sub(t1), t2.Format(f), t3.Sub(t2), t3.Format(f))

In Go 1.8, the program can print:

    23:59:59.985 10ms 23:59:59.995 -990ms 23:59:59.005

In the design proposed above, the program instead prints:

    23:59:59.985 10ms 23:59:59.995 10ms 23:59:59.005

Although in both cases the second elapsed time requires some explanation,
I'd rather explain 10ms than −990ms. 
Most importantly, the actual time elapsed between the t2 and t3 calls to `time.Now`
really is 10 milliseconds.

In this case, 23:59:59.005 minus 23:59:59.995 can be 10 milliseconds, 
even though the printed times would suggest −990ms,
because the printed time is incomplete.

The printed time is incomplete in other settings too.
Suppose a program starts just before noon, printing only hours and minutes:

	t1 := time.Now()
	... 10 ms of work
	t2 := time.Now()
	... 10 ms of work
	t3 := time.Now()
	... 10 ms of work
	const f = "15:04"
	fmt.Println(t1.Format(f), t2.Sub(t1), t2.Format(f), t3.Sub(t2), t3.Format(f))

In Go 1.8, the program can print:

    11:59 10ms 11:59 10ms 12:00

This is easily understood, even though the printed times indicate durations of 0 and 1 minute.
The printed time is incomplete: it omits second and subsecond resolution.

Suppose instead that the program starts just before a 1am daylight savings shift.
In Go 1.8, the program can print:

    00:59 10ms 00:59 10ms 02:00

This too is easily understood, even though the printed times indicate durations of 0 and 61 minutes.
The printed time is incomplete: it omits the time zone.

In the original example, printing 10ms instead of −990ms.
The printed time is incomplete: it omits clock resets.

The Go 1.8 time representation makes correct time calculations across time zone changes
by storing a time unaffected by time zone changes,
along with additional information used for printing the time.
Similarly, the proposed new time representation makes correct time calculations across clock resets
by storing a time unaffected by clock resets (the monotonic clock reading),
along with additional information used for printing the time (the wall clock reading).

## Compatibility

[Go 1 compatibility](https://golang.org/doc/go1compat)
keeps us from changing any of the types in the APIs mentioned above.
In particular, `net.Conn`'s `SetDeadline` method must continue to
take a `time.Time`, and `context.Context`'s `Deadline` method
must continue to return one.
We arrived at the current proposal due to these compatibility
constraints, but as explained in the Rationale above,
it may actually be the best choice anyway.

Also mentioned above,
about 30% of calls to `time.Now` are used for measuring elapsed time
and would be affected by this proposal.
In every case we've examined (see Appendix below), the effect is to eliminate
the possibility of incorrect measurement results due to clock resets.
We have found no existing Go code that is broken by
the improved measurements.

If the proposal is adopted, the implementation should be landed at the
start of a [release cycle](https://golang.org/wiki/Go-Release-Cycle),
to maximize the time in which to find unexpected compatibility problems.

## Implementation

The implementation work in package time is fairly straightforward,
since the runtime has already worked out access to the monotonic clock on 
(nearly) all supported operating systems.

### Reading the clocks

**Precision**:
In general, operating systems provide different system operations to read the
wall clock and the monotonic clock, so the
implementation of `time.Now` must read both in sequence.
Time will advance between the calls, with the effect that even in the absence of
clock resets, `t.Sub(u)` (using monotonic clock readings) and `t.AddDate(0,0,0).Sub(u)` (using wall clock readings)
will differ slightly.
Since both cases are subtracting times obtained `time.Now`, both results are arguably correct:
any discrepancy is necessarily less than the overhead of the calls to `time.Now`.
This discrepancy only arises if code actively looks for it, by doing the subtraction or comparison both ways.
In the survey of extant Go code (see Appendix below),
we found no such code that would detect this discrepancy.

On x86 systems, Linux, macOS, and Windows convey clock information to user
processes by publishing a page of memory containing the coefficients for a formula
converting the processor's time stamp counter to monotonic clock and to wall clock readings.
A perfectly synchronized read of both clocks could be obtained in this case by
doing a single read of the time stamp counter and applying both formulas to the 
same input.
This is an option if we decide it is important to eliminate the discrepancy
on commonly used systems.
This would improve precision but again it is false precision beyond the actual accuracy
of the calls.

**Overhead**:
There is obviously an overhead to having `time.Now` read two system clocks instead of one.
However, as just mentioned, the usual implementation of these operations
does not typically enter the operating system kernel,
making two calls still quite cheap.
The same “simultaneous computation” we could apply for additional precision
would also reduce the overhead.

### Time representation

The current definition of a `time.Time` is:

	type Time struct {
		sec  int64     // seconds since Jan 1, year 1 00:00:00 UTC
		nsec int32     // nanoseconds, in [0, 999999999]
		loc  *Location // location, for minute, hour, month, day, year
	}

To add the optional monotonic clock reading, we can change the representation to:

	type Time struct {
		wall uint64    // wall time: 1-bit flag, 33-bit sec since 1885, 30-bit nsec
		ext  int64     // extended time information
		loc  *Location // location
	}

The wall field can encode the wall time, packed into a 33-bit seconds and 30-bit nsecs
(keeping them separate avoids costly divisions).
2<sup>33</sup> seconds is 272 years, so the wall field by itself
can encode times from the years 1885 to 2157 to nanosecond precision.
If the top flag bit in `t.wall` is set, then the wall seconds are packed into `t.wall`
as just described, and `t.ext` holds 
a monotonic clock reading, stored as nanoseconds since Go process startup
(translating to process start ensures we can store monotonic clock readings
even if the operating system returns a representation larger than 64 bits).
Otherwise (the top flag bit is clear), the 33-bit field in `t.wall` must be zero,
and `t.ext` holds the full 64-bit seconds since Jan 1, year 1, as in the
original Time representation.
Note that the meaning of the zero Time is unchanged.

An implication is that monotonic clock readings can only be stored
alongside wall clock readings for the years 1885 to 2157.
We only need to store monotonic clock readings in the result of `time.Now`
and derived nearby times,
and we expect those times to lie well within the range 1885 to 2157.
The low end of the range is constrained by the default boot time
used on a system with a dead clock:
in this common case, we must be able to store a
monotonic clock reading alongside the wall clock reading.
Unix-based systems often use 1970, and Windows-based systems often use 1980.
We are unaware of any systems using earlier default wall times,
but since the NTP protocol epoch uses 1900, it seemed more future-proof
to choose a year before 1900.

On 64-bit systems, there is a 32-bit padding gap between `nsec` and `loc`
in the current representation, which the new representation fills,
keeping the overall struct size at 24 bytes.
On 32-bit systems, there is no such gap, and the overall struct size
grows from 16 to 20 bytes.

# Appendix: time.Now usage

We analyzed uses of time.Now in [Go Corpus v0.01](https://github.com/rsc/corpus).

Overall estimates:

- 71% unaffected
- 29% fixed in event of wall clock time warps (subtractions or comparisons)

Basic counts:

	$ cg -f $(pwd)'.*\.go$' 'time\.Now\(\)' | sed 's;//.*;;' |grep time.Now >alltimenow
	$ wc -l alltimenow
	   16569 alltimenow
	$ egrep -c 'time\.Now\(\).*time\.Now\(\)' alltimenow
	63

	$ 9 sed -n 's/.*(time\.Now\(\)(\.[A-Za-z0-9]+)?).*/\1/p' alltimenow | sort | uniq -c
	4910 time.Now()
	1511 time.Now().Add
	  45 time.Now().AddDate
	  69 time.Now().After
	  77 time.Now().Before
	   4 time.Now().Date
	   5 time.Now().Day
	   1 time.Now().Equal
	 130 time.Now().Format
	  23 time.Now().In
	   8 time.Now().Local
	   4 time.Now().Location
	   1 time.Now().MarshalBinary
	   2 time.Now().MarshalText
	   2 time.Now().Minute
	  68 time.Now().Nanosecond
	  14 time.Now().Round
	  22 time.Now().Second
	  37 time.Now().String
	 370 time.Now().Sub
	  28 time.Now().Truncate
	 570 time.Now().UTC
	 582 time.Now().Unix
	8067 time.Now().UnixNano
	  17 time.Now().Year
	   2 time.Now().Zone

That splits into completely unaffected:

	  45 time.Now().AddDate
	   4 time.Now().Date
	   5 time.Now().Day
	 130 time.Now().Format
	  23 time.Now().In
	   8 time.Now().Local
	   4 time.Now().Location
	   1 time.Now().MarshalBinary
	   2 time.Now().MarshalText
	   2 time.Now().Minute
	  68 time.Now().Nanosecond
	  14 time.Now().Round
	  22 time.Now().Second
	  37 time.Now().String
	  28 time.Now().Truncate
	 570 time.Now().UTC
	 582 time.Now().Unix
	8067 time.Now().UnixNano
	  17 time.Now().Year
	   2 time.Now().Zone
	9631 TOTAL

and possibly affected:

	4910 time.Now()
	1511 time.Now().Add
	  69 time.Now().After
	  77 time.Now().Before
	   1 time.Now().Equal
	 370 time.Now().Sub
	6938 TOTAL

If we pull out the possibly affected lines, the overall count is slightly higher because of the 63 lines with more than one time.Now call:

	$ egrep 'time\.Now\(\)([^.]|\.(Add|After|Before|Equal|Sub)|$)' alltimenow >checktimenow
	$ wc -l checktimenow
	    6982 checktimenow

From the start, then, 58% of time.Now uses immediately flip to wall time and are unaffected.
The remaining 42% may be affected.

Randomly sampling 100 of the 42%, we find:

- 32 unaffected (23 use wall time once; 9 use wall time multiple times)
- 68 fixed

We estimate therefore that the 42% is made up of 13% additional unaffected and 29% fixed, giving an overall total of 71% unaffected, 29% fixed.

## Unaffected

### github.com/mitchellh/packer/vendor/google.golang.org/appengine/demos/guestbook/guestbook.go:97

	func handleSign(w http.ResponseWriter, r *http.Request) {
		...
		g := &Greeting{
			Content: r.FormValue("content"),
			Date:    time.Now(),
		}
		... datastore.Put(ctx, key, g) ...
	}

**Unaffected.** 
The time will be used exactly once, during the serialization of g.Date in datastore.Put.

### github.com/aws/aws-sdk-go/service/databasemigrationservice/examples_test.go:887

	func ExampleDatabaseMigrationService_ModifyReplicationTask() {
		...
		params := &databasemigrationservice.ModifyReplicationTaskInput{
			...
			CdcStartTime:              aws.Time(time.Now()),
			...
		}
		... svc.ModifyReplicationTask(params) ...
	}

**Unaffected.**
The time will be used exactly once, during the serialization of params.CdcStartTime in svc.ModifyReplicationTask.

### github.com/influxdata/telegraf/plugins/inputs/mongodb/mongodb_data_test.go:94

	d := NewMongodbData(
		&StatLine{
			...
			Time:          time.Now(),
			...
		},
		...
	)

StatLine.Time is commented as "the time at which this StatLine was generated'' and is only used
by passing to acc.AddFields, where acc is a telegraf.Accumulator.

	// AddFields adds a metric to the accumulator with the given measurement
	// name, fields, and tags (and timestamp). If a timestamp is not provided,
	// then the accumulator sets it to "now".
	// Create a point with a value, decorating it with tags
	// NOTE: tags is expected to be owned by the caller, don't mutate
	// it after passing to Add.
	AddFields(measurement string,
		fields map[string]interface{},
		tags map[string]string,
		t ...time.Time)

The non-test implementation of Accumulator calls t.Round, which will convert to wall time.

**Unaffected.**

### github.com/spf13/fsync/fsync_test.go:23

	// set times in the past to make sure times are synced, not accidentally
	// the same
	tt := time.Now().Add(-1 * time.Hour)
	check(os.Chtimes("src/a/b", tt, tt))
	check(os.Chtimes("src/a", tt, tt))
	check(os.Chtimes("src/c", tt, tt))
	check(os.Chtimes("src", tt, tt))

**Unaffected.**

### github.com/flynn/flynn/vendor/github.com/gorilla/handlers/handlers.go:66

	t := time.Now()
	...
	writeLog(h.writer, req, url, t, logger.Status(), logger.Size())

writeLog calls buildCommonLogLine, which eventually calls t.Format.

**Unaffected.**

### github.com/ncw/rclone/vendor/google.golang.org/grpc/server.go:586

	if err == nil && outPayload != nil {
		outPayload.SentTime = time.Now()
		stats.HandleRPC(stream.Context(), outPayload)
	}

SentTime seems to never be used. Client code could call stats.RegisterRPCHandler to do stats processing and look at SentTime.
Any use of time.Since(SentTime) would be improved by having SentTime be monotonic here.

There are no calls to stats.RegisterRPCHandler in the entire corpus.

**Unaffected.**

### github.com/openshift/origin/vendor/github.com/influxdata/influxdb/models/points.go:1316

	func (p *point) UnmarshalBinary(b []byte) error {	
		...
		p.time = time.Now()
		p.time.UnmarshalBinary(b[i:])
		...
	}

That's weird. It looks like it is setting p.time in case of an error in UnmarshalBinary, instead of checking for and propagating an error. All the other ways that a p.time is initalized end up using non-monotonic times, because they came from time.Unix or t.Round. Assuming that bad decodings are rare, going to call it unaffected.

**Unaffected** (but not completely sure).

### github.com/zyedidia/micro/cmd/micro/util.go

	// GetModTime returns the last modification time for a given file
	// It also returns a boolean if there was a problem accessing the file
	func GetModTime(path string) (time.Time, bool) {
		info, err := os.Stat(path)
		if err != nil {
			return time.Now(), false
		}
		return info.ModTime(), true
	}

The result is recorded in the field Buffer.ModTime and then checked against future calls to GetModTime to see if the file changed:

	// We should only use last time's eventhandler if the file wasn't by someone else in the meantime
	if b.ModTime == buffer.ModTime {
		b.EventHandler = buffer.EventHandler
		b.EventHandler.buf = b
	}

and

	if modTime != b.ModTime {
		choice, canceled := messenger.YesNoPrompt("The file has changed since it was last read. Reload file? (y,n)")
		...
	}

Normally Buffer.ModTime will be a wall time, but if the file doesn't exist Buffer.ModTime will be a monotonic time that will not compare == to any file time. That's the desired behavior here.

**Unaffected** (or maybe fixed).

### github.com/gravitational/teleport/lib/auth/init_test.go:59

	// test TTL by converting the generated cert to text -> back and making sure ExpireAfter is valid
	ttl := time.Second * 10
	expiryDate := time.Now().Add(ttl)
	bytes, err := t.GenerateHostCert(priv, pub, "id1", "example.com", teleport.Roles{teleport.RoleNode}, ttl)
	c.Assert(err, IsNil)
	pk, _, _, _, err := ssh.ParseAuthorizedKey(bytes)
	c.Assert(err, IsNil)
	copy, ok := pk.(*ssh.Certificate)
	c.Assert(ok, Equals, true)
	c.Assert(uint64(expiryDate.Unix()), Equals, copy.ValidBefore)

This is jittery, in the sense that the computed expiryDate may not exactly match the cert generation that—one must assume—grabs the current time and adds the passed ttl to it to compute ValidBefore. It's unclear without digging exactly how the cert gets generated (there seems to be an RPC, but I don't know if it's to a test server in the same process). Either way, the two times are only possibly equal because of the rounding to second granularity. Even today, if the call expiryDate := time.Now().Add(ttl) happens 1 nanosecond before a wall time second boundary, this test will fail. Moving to monotonic time will not change the fact that it's jittery.

**Unaffected.**

### github.com/aws/aws-sdk-go/private/model/api/operation.go:420

	case "timestamp":
		str = `aws.Time(time.Now())`

This is the example generator for the AWS documentation. An aws.Time is always just being put into a structure to send over the wire in JSON format to AWS, so these remain OK.

**Unaffected.**

### github.com/influxdata/telegraf/plugins/inputs/mongodb/mongodb_data_test.go:17

	d := NewMongodbData(
		&StatLine{
			...
			Time:             time.Now(),
			...
		},
		...
	}

**Unaffected** (see above from same file).

### github.com/aws/aws-sdk-go/service/datapipeline/examples_test.go:36

	params := &datapipeline.ActivatePipelineInput{
		...
		StartTimestamp: aws.Time(time.Now()),
	}
	resp, err := svc.ActivatePipeline(params)

The svc.ActivatePipeline call serializes StartTimestamp to JSON (just once).

**Unaffected.**

### github.com/jessevdk/go-flags/man.go:177

	t := time.Now()
	fmt.Fprintf(wr, ".TH %s 1 \"%s\"\n", manQuote(p.Name), t.Format("2 January 2006"))

**Unaffected.**

### k8s.io/heapster/events/manager/manager_test.go:28

	batch := &core.EventBatch{
		Timestamp: time.Now(),
		Events:    []*kube_api.Event{},
	}

Later used as:

	buffer.WriteString(fmt.Sprintf("EventBatch     Timestamp: %s\n", batch.Timestamp))

**Unaffected.**

### k8s.io/heapster/metrics/storage/podmetrics/reststorage.go:121

	CreationTimestamp: unversioned.NewTime(time.Now())

But CreationTimestamp is only ever checked for being the zero time or not.

**Unaffected.**

### github.com/revel/revel/server.go:46

	start := time.Now()
	...
	// Revel request access log format
	// RequestStartTime ClientIP ResponseStatus RequestLatency HTTPMethod URLPath
	// Sample format:
	// 2016/05/25 17:46:37.112 127.0.0.1 200  270.157µs GET /
	requestLog.Printf("%v %v %v %10v %v %v",
		start.Format(requestLogTimeFormat),
		ClientIP(r),
		c.Response.Status,
		time.Since(start),
		r.Method,
		r.URL.Path,
	)

**Unaffected.**

### github.com/hashicorp/consul/command/agent/agent.go:1426

	Expires: time.Now().Add(check.TTL).Unix(),

**Unaffected.**

### github.com/drone/drone/server/login.go:143

	exp := time.Now().Add(time.Hour * 72).Unix()

**Unaffected.**

### github.com/openshift/origin/vendor/github.com/coreos/etcd/pkg/transport/listener.go:113:

	tmpl := x509.Certificate{
		NotBefore:    time.Now(),
		NotAfter:     time.Now().Add(365 * (24 * time.Hour)),
		...
	}
	...
	derBytes, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)

**Unaffected.**

### github.com/ethereum/go-ethereum/swarm/api/http/server.go:189

	http.ServeContent(w, r, "", time.Now(), bytes.NewReader([]byte(newKey)))

eventually uses the passed time in formatting:

	w.Header().Set("Last-Modified", modtime.UTC().Format(TimeFormat))

**Unaffected.**

### github.com/hashicorp/consul/vendor/google.golang.org/grpc/call.go:187

	if sh != nil {
		ctx = sh.TagRPC(ctx, &stats.RPCTagInfo{FullMethodName: method})
		begin := &stats.Begin{
			Client:    true,
			BeginTime: time.Now(),
			FailFast:  c.failFast,
		}
		sh.HandleRPC(ctx, begin)
	}
	defer func() {
		if sh != nil {
			end := &stats.End{
				Client:  true,
				EndTime: time.Now(),
				Error:   e,
			}
			sh.HandleRPC(ctx, end)
		}
	}()

If something subtracted BeginTime and EndTime, that would be fixed by monotonic times.
I don't see any implementations of StatsHandler in the tree, though, so sh must be nil.

**Unaffected.**

### github.com/hashicorp/vault/builtin/logical/pki/backend_test.go:396

	if !cert.NotBefore.Before(time.Now().Add(-10 * time.Second)) {
		return nil, fmt.Errorf("Validity period not far enough in the past")
	}

cert.NotBefore is usually the result of decoding an wire format certificate,
so it's not monotonic, so the time will collapse to wall time during the Before check.

**Unaffected.**

### github.com/openshift/origin/vendor/k8s.io/kubernetes/plugin/pkg/admission/namespace/lifecycle/admission_test.go:194

	fakeClock := clock.NewFakeClock(time.Now())

The clock being implemented does Since, After, and other relative manipulation only.

**Unaffected.**

## Unaffected (but uses time.Time as wall time multiple times)

These are split out because an obvious optimization would be to store just the monotonic time 
and rederive the wall time using the current wall-vs-monotonic correspondence from the 
operating system. Using a wall form multiple times in this case could show up as jitter.
The proposal does _not_ suggest this optimization, precisely because of cases like these.

### github.com/docker/distribution/registry/storage/driver/inmemory/mfs.go:195

	// mkdir creates a child directory under d with the given name.
	func (d *dir) mkdir(name string) (*dir, error) {
		... d.mod = time.Now() ...
	}

ends up being used by

	fi := storagedriver.FileInfoFields{
		Path:    path,
		IsDir:   found.isdir(),
		ModTime: found.modtime(),
	}

which will result in that time being returned by an os.FileInfo implementation's ModTime method.

**Unaffected** (but uses time multiple times).

### github.com/minio/minio/cmd/server-startup-msg_test.go:52

	// given
	var expiredDate = time.Now().Add(time.Hour * 24 * (30 - 1)) // 29 days.
	var fakeCerts = []*x509.Certificate{
		... NotAfter: expiredDate ...
	}

	expectedMsg := colorBlue("\nCertificate expiry info:\n") +
		colorBold(fmt.Sprintf("#1 Test cert will expire on %s\n", expiredDate))

	msg := getCertificateChainMsg(fakeCerts)
	if msg != expectedMsg {
		t.Fatalf("Expected message was: %s, got: %s", expectedMsg, msg)
	}

**Unaffected** (but uses time multiple times).

### github.com/pingcap/tidb/expression/builtin_string_test.go:42

	{types.Time{Time: types.FromGoTime(time.Now()), Fsp: 6, Type: mysql.TypeDatetime}, 26},

The call to FromGoTime does:

	func FromGoTime(t gotime.Time) TimeInternal {
		year, month, day := t.Date()
		hour, minute, second := t.Clock()
		microsecond := t.Nanosecond() / 1000
		return newMysqlTime(year, int(month), day, hour, minute, second, microsecond)
	}

**Unaffected** (but uses time multiple times).

### github.com/docker/docker/vendor/github.com/docker/distribution/registry/client/repository.go:750

	func (bs *blobs) Create(ctx context.Context, options ...distribution.BlobCreateOption) (distribution.BlobWriter, error) {
		...
		return &httpBlobUpload{
			statter:   bs.statter,
			client:    bs.client,
			uuid:      uuid,
			startedAt: time.Now(),
			location:  location,
		}, nil
	}

That field is used to implement distribution.BlobWriter interface's StartedAt method, which is eventually copied into a handlers.blobUploadState, which is sometimes serialized to JSON and reconstructed. The serialization seems to be the single use.

**Unaffected** (but not completely sure about use count).


### github.com/pingcap/pd/_vendor/vendor/golang.org/x/net/internal/timeseries/timeseries.go:83

	// A Clock tells the current time.
	type Clock interface {
		Time() time.Time
	}
	
	type defaultClock int
	var defaultClockInstance defaultClock
	func (defaultClock) Time() time.Time { return time.Now() }
	
Let's look at how that gets used.

The main use is to get a now time and then check whether 

	if ts.levels[0].end.Before(now) {
		ts.advance(now)
	}

but levels[0].end was rounded, meaning its a wall time. advance then does:

	if !t.After(ts.levels[0].end) {
		return
	}
	for i := 0; i < len(ts.levels); i++ {
		level := ts.levels[i]
		if !level.end.Before(t) {
			break
		}

		// If the time is sufficiently far, just clear the level and advance
		// directly.
		if !t.Before(level.end.Add(level.size * time.Duration(ts.numBuckets))) {
			for _, b := range level.buckets {
				ts.resetObservation(b)
			}
			level.end = time.Unix(0, (t.UnixNano()/level.size.Nanoseconds())*level.size.Nanoseconds())
		}

		for t.After(level.end) {
			level.end = level.end.Add(level.size)
			level.newest = level.oldest
			level.oldest = (level.oldest + 1) % ts.numBuckets
			ts.resetObservation(level.buckets[level.newest])
		}

		t = level.end
	}

**Unaffected** (but uses time multiple times).

### github.com/astaxie/beego/logs/logger_test.go:24

	func TestFormatHeader_0(t *testing.T) {
		tm := time.Now()
		if tm.Year() >= 2100 {
			t.FailNow()
		}
		dur := time.Second
		for {
			if tm.Year() >= 2100 {
				break
			}
			h, _ := formatTimeHeader(tm)
			if tm.Format("2006/01/02 15:04:05 ") != string(h) {
				t.Log(tm)
				t.FailNow()
			}
			tm = tm.Add(dur)
			dur *= 2
		}
	}

**Unaffected** (but uses time multiple times).

### github.com/attic-labs/noms/vendor/github.com/aws/aws-sdk-go/aws/signer/v4/v4_test.go:418

	ctx := &signingCtx{
		...
		Time:        time.Now(),
		ExpireTime:  5 * time.Second,
	}

	ctx.buildCanonicalString()
	expected := "https://example.org/bucket/key-._~,!@#$%^&*()?Foo=z&Foo=o&Foo=m&Foo=a"
	assert.Equal(t, expected, ctx.Request.URL.String())

ctx is used as:

	ctx.formattedTime = ctx.Time.UTC().Format(timeFormat)
	ctx.formattedShortTime = ctx.Time.UTC().Format(shortTimeFormat)

and then ctx.formattedTime is used sometimes and ctx.formattedShortTime is used other times.

**Unaffected** (but uses time multiple times).

### github.com/zenazn/goji/example/models.go:21

	var Greets = []Greet{
		{"carl", "Welcome to Gritter!", time.Now()},
		{"alice", "Wanna know a secret?", time.Now()},
		{"bob", "Okay!", time.Now()},
		{"eve", "I'm listening...", time.Now()},
	}

used by:

	// Write out a representation of the greet
	func (g Greet) Write(w io.Writer) {
		fmt.Fprintf(w, "%s\n@%s at %s\n---\n", g.Message, g.User,
			g.Time.Format(time.UnixDate))
	}

**Unaffected** (but may use wall representation multiple times).

### github.com/afex/hystrix-go/hystrix/rolling/rolling_timing.go:77

	r.Mutex.RLock()
	now := time.Now()
	bucket, exists := r.Buckets[now.Unix()]
	r.Mutex.RUnlock()

	if !exists {
		r.Mutex.Lock()
		defer r.Mutex.Unlock()

		r.Buckets[now.Unix()] = &timingBucket{}
		bucket = r.Buckets[now.Unix()]
	}

**Unaffected** (but uses wall representation multiple times).

## Fixed

### github.com/hashicorp/vault/vendor/golang.org/x/net/http2/transport.go:721

	func (cc *ClientConn) RoundTrip(req *http.Request) (*http.Response, error) {
		...
		cc.lastActive = time.Now()
		...
	}

matches against:

	func traceGotConn(req *http.Request, cc *ClientConn) {
		... ci.IdleTime = time.Now().Sub(cc.lastActive) ...
	}

**Fixed.**
Only for debugging, though.

### github.com/docker/docker/vendor/github.com/hashicorp/serf/serf/serf.go:1417

	// reap is called with a list of old members and a timeout, and removes
	// members that have exceeded the timeout. The members are removed from
	// both the old list and the members itself. Locking is left to the caller.
	func (s *Serf) reap(old []*memberState, timeout time.Duration) []*memberState {
		now := time.Now()
		...
		for i := 0; i < n; i++ {
			...
			// Skip if the timeout is not yet reached
			if now.Sub(m.leaveTime) <= timeout {
				continue
			}
			...
		}
		...
	}
	
and m.leaveTime is always initialized by calling time.Now.

**Fixed.**

### github.com/hashicorp/consul/consul/acl_replication.go:173

	defer metrics.MeasureSince([]string{"consul", "leader", "updateLocalACLs"}, time.Now())

This is the canonical way to use the github.com/armon/go-metrics package. 

	func MeasureSince(key []string, start time.Time) {
		globalMetrics.MeasureSince(key, start)
	}
	
	func (m *Metrics) MeasureSince(key []string, start time.Time) {
		...
		now := time.Now()
		elapsed := now.Sub(start)
		msec := float32(elapsed.Nanoseconds()) / float32(m.TimerGranularity)
		m.sink.AddSample(key, msec)
	}

**Fixed.**

### github.com/flynn/flynn/vendor/gopkg.in/mgo.v2/session.go:3598

	if iter.timeout >= 0 {
		if timeout.IsZero() {
			timeout = time.Now().Add(iter.timeout)
		}
		if time.Now().After(timeout) {
			iter.timedout = true
			...
		}
	}

**Fixed.**

### github.com/huichen/wukong/examples/benchmark.go:173

	t4 := time.Now()
	done := make(chan bool)
	recordResponse := recordResponseLock{}
	recordResponse.count = make(map[string]int)
	for iThread := 0; iThread < numQueryThreads; iThread++ {
		go search(done, &recordResponse)
	}
	for iThread := 0; iThread < numQueryThreads; iThread++ {
		<-done
	}

	// 记录时间并计算分词速度
	t5 := time.Now()
	log.Printf("搜索平均响应时间 %v 毫秒",
		t5.Sub(t4).Seconds()*1000/float64(numRepeatQuery*len(searchQueries)))
	log.Printf("搜索吞吐量每秒 %v 次查询",
		float64(numRepeatQuery*numQueryThreads*len(searchQueries))/
			t5.Sub(t4).Seconds())

The first print is "Search average response time %v milliseconds" and the second is "Search Throughput %v queries per second."

**Fixed.**

### github.com/ncw/rclone/vendor/google.golang.org/grpc/call.go:171

	if EnableTracing {
		...
		if deadline, ok := ctx.Deadline(); ok {
			c.traceInfo.firstLine.deadline = deadline.Sub(time.Now())
		}
		...
	}

Here ctx is a context.Context. We should probably arrange for ctx.Deadline to return monotonic times.
If it does, then this code is fixed. 
If it does not, then this code is unaffected.

**Fixed.**

### github.com/hashicorp/consul/consul/fsm.go:281

	defer metrics.MeasureSince([]string{"consul", "fsm", "prepared-query", string(req.Op)}, time.Now())

See MeasureSince above.

**Fixed.**

### github.com/docker/libnetwork/vendor/github.com/Sirupsen/logrus/text_formatter.go:27

	var (
		baseTimestamp time.Time
		isTerminal    bool
	)
	
	func init() {
		baseTimestamp = time.Now()
		isTerminal = IsTerminal()
	}
	
	func miniTS() int {
		return int(time.Since(baseTimestamp) / time.Second)
	}

**Fixed.**

### github.com/flynn/flynn/vendor/golang.org/x/net/http2/go17.go:54

	if ci.WasIdle && !cc.lastActive.IsZero() {
		ci.IdleTime = time.Now().Sub(cc.lastActive)
	}

See above.

**Fixed.**

### github.com/zyedidia/micro/cmd/micro/eventhandler.go:102

	// Remove creates a remove text event and executes it
	func (eh *EventHandler) Remove(start, end Loc) {
		e := &TextEvent{
			C:         eh.buf.Cursor,
			EventType: TextEventRemove,
			Start:     start,
			End:       end,
			Time:      time.Now(),
		}
		eh.Execute(e)
	}

The time here is used by

	// Undo the first event in the undo stack
	func (eh *EventHandler) Undo() {
		t := eh.UndoStack.Peek()
		...
		startTime := t.Time.UnixNano() / int64(time.Millisecond)
		...
		for {
			t = eh.UndoStack.Peek()
			...
			if startTime-(t.Time.UnixNano()/int64(time.Millisecond)) > undoThreshold {
				return
			}
			startTime = t.Time.UnixNano() / int64(time.Millisecond)
			...
		}
	}

If this avoided the call to UnixNano (used t.Sub instead), then all the times involved would be monotonic and the elapsed time computation would be independent of wall time. As written, a wall time adjustment during Undo will still break the code. Without any monotonic times, a wall time adjustment before Undo also breaks the code; that no longer happens.

**Fixed.*

### github.com/ethereum/go-ethereum/cmd/geth/chaincmd.go:186

	start = time.Now()
	fmt.Println("Compacting entire database...")
	if err = db.LDB().CompactRange(util.Range{}); err != nil {
		utils.Fatalf("Compaction failed: %v", err)
	}
	fmt.Printf("Compaction done in %v.\n\n", time.Since(start))

**Fixed.**

### github.com/drone/drone/shared/oauth2/oauth2.go:176

	// Expired reports whether the token has expired or is invalid.
	func (t *Token) Expired() bool {
		if t.AccessToken == "" {
			return true
		}
		if t.Expiry.IsZero() {
			return false
		}
		return t.Expiry.Before(time.Now())
	}

t.Expiry is set with:

	if b.ExpiresIn == 0 {
		tok.Expiry = time.Time{}
	} else {
		tok.Expiry = time.Now().Add(time.Duration(b.ExpiresIn) * time.Second)
	}

**Fixed.**

### github.com/coreos/etcd/auth/simple_token.go:88

	for {
		select {
		case t := <-tm.addSimpleTokenCh:
			tm.tokens[t] = time.Now().Add(simpleTokenTTL)
		case t := <-tm.resetSimpleTokenCh:
			if _, ok := tm.tokens[t]; ok {
				tm.tokens[t] = time.Now().Add(simpleTokenTTL)
			}
		case t := <-tm.deleteSimpleTokenCh:
			delete(tm.tokens, t)
		case <-tokenTicker.C:
			nowtime := time.Now()
			for t, tokenendtime := range tm.tokens {
				if nowtime.After(tokenendtime) {
					tm.deleteTokenFunc(t)
					delete(tm.tokens, t)
				}
			}
		case waitCh := <-tm.stopCh:
			tm.tokens = make(map[string]time.Time)
			waitCh <- struct{}{}
			return
		}
	}

**Fixed.**

### github.com/docker/docker/cli/command/node/ps_test.go:105

	return []swarm.Task{
		*Task(TaskID("taskID1"), ServiceID("failure"),
			WithStatus(Timestamp(time.Now().Add(-2*time.Hour)), StatusErr("a task error"))),
		*Task(TaskID("taskID2"), ServiceID("failure"),
			WithStatus(Timestamp(time.Now().Add(-3*time.Hour)), StatusErr("a task error"))),
		*Task(TaskID("taskID3"), ServiceID("failure"),
			WithStatus(Timestamp(time.Now().Add(-4*time.Hour)), StatusErr("a task error"))),
	}, nil

It's just a test, but Timestamp sets the Timestamp field in the swarm.TaskStatus used eventually in docker/cli/command/task/print.go:

	strings.ToLower(units.HumanDuration(time.Since(task.Status.Timestamp))),

Having a monotonic time in the swam.TaskStatus makes time.Since more accurate.

**Fixed.**

### github.com/docker/docker/integration-cli/docker_api_attach_test.go:130

	conn.SetReadDeadline(time.Now().Add(time.Second))

**Fixed.**

### github.com/openshift/origin/vendor/k8s.io/kubernetes/test/e2e/framework/util.go:1696

	timeout := 2 * time.Minute
	for start := time.Now(); time.Since(start) < timeout; time.Sleep(5 * time.Second) {
		...
	}

**Fixed.**

### github.com/onsi/gomega/internal/asyncassertion/async_assertion_test.go:318

	t := time.Now()
	failures := InterceptGomegaFailures(func() {
		Eventually(c, 0.1).Should(Receive())
	})
	Ω(time.Since(t)).Should(BeNumerically("<", 90*time.Millisecond))

**Fixed.**

### github.com/hashicorp/vault/physical/consul.go:344

	defer metrics.MeasureSince([]string{"consul", "list"}, time.Now())

**Fixed.**

### github.com/hyperledger/fabric/vendor/golang.org/x/net/context/go17.go:62

	// WithTimeout returns WithDeadline(parent, time.Now().Add(timeout)).
	// ...
	func WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc) {
		return WithDeadline(parent, time.Now().Add(timeout))
	}

**Fixed.**

### github.com/hashicorp/consul/consul/state/tombstone_gc.go:134

	// nextExpires is used to calculate the next expiration time
	func (t *TombstoneGC) nextExpires() time.Time {
		expires := time.Now().Add(t.ttl)
		remain := expires.UnixNano() % int64(t.granularity)
		adj := expires.Add(t.granularity - time.Duration(remain))
		return adj
	}

used by:

	func (t *TombstoneGC) Hint(index uint64) {
		expires := t.nextExpires()
		...
		// Check for an existing expiration timer
		exp, ok := t.expires[expires]
		if ok {
			...
			return
		}
	
		// Create new expiration time
		t.expires[expires] = &expireInterval{
			maxIndex: index,
			timer: time.AfterFunc(expires.Sub(time.Now()), func() {
				t.expireTime(expires)
			}),
		}
	}

The granularity rounding will usually reuslt in something that can be used in a map key but not always.
The code is using the rounding only as an optimization, so it doesn't actually matter if a few extra keys get generated.
More importantly, the time passd to time.AfterFunc ends up monotonic, so that timers fire correctly.

**Fixed.**

### github.com/openshift/origin/vendor/k8s.io/kubernetes/pkg/storage/etcd/etcd_helper.go:310

	startTime := time.Now()
	...
	metrics.RecordEtcdRequestLatency("get", getTypeName(listPtr), startTime)

which ends up in:

	func RecordEtcdRequestLatency(verb, resource string, startTime time.Time) {
		etcdRequestLatenciesSummary.WithLabelValues(verb, resource).Observe(float64(time.Since(startTime) / time.Microsecond))
	}

**Fixed.**

### github.com/pingcap/pd/server/util.go:215

	start := time.Now()
	ctx, cancel := context.WithTimeout(c.Ctx(), requestTimeout)
	resp, err := m.Status(ctx, endpoint)
	cancel()

	if cost := time.Now().Sub(start); cost > slowRequestTime {
		log.Warnf("check etcd %s status, resp: %v, err: %v, cost: %s", endpoint, resp, err, cost)
	}

**Fixed.**

### github.com/openshift/origin/vendor/k8s.io/kubernetes/pkg/kubelet/kuberuntime/instrumented_services.go:235

	func (in instrumentedImageManagerService) ImageStatus(image *runtimeApi.ImageSpec) (*runtimeApi.Image, error) {
		...
		defer recordOperation(operation, time.Now())
		...
	}

	// recordOperation records the duration of the operation.
	func recordOperation(operation string, start time.Time) {
		metrics.RuntimeOperations.WithLabelValues(operation).Inc()
		metrics.RuntimeOperationsLatency.WithLabelValues(operation).Observe(metrics.SinceInMicroseconds(start))
	}

**Fixed.**

### github.com/openshift/origin/vendor/k8s.io/kubernetes/pkg/kubelet/dockertools/instrumented_docker.go:58

	defer recordOperation(operation, time.Now())
	
**Fixed.** (see previous)

### github.com/coreos/etcd/tools/functional-tester/etcd-runner/command/global.go:103

	start := time.Now()
	for i := 1; i < len(rcs)*rounds+1; i++ {
		select {
		case <-finished:
			if i%100 == 0 {
				fmt.Printf("finished %d, took %v\n", i, time.Since(start))
				start = time.Now()
			}
		case <-time.After(time.Minute):
			log.Panic("no progress after 1 minute!")
		}
	}

**Fixed.**

### github.com/reducedb/encoding/benchtools/benchtools.go:98

	now := time.Now()
	...
	if err = codec.Compress(in, inpos, len(in), out, outpos); err != nil {
		return 0, nil, err
	}
	since := time.Since(now).Nanoseconds()

**Fixed.**

### github.com/docker/swarm/vendor/github.com/hashicorp/consul/api/semaphore.go:200

		start := time.Now()
		attempts := 0
	WAIT:
		// Check if we should quit
		select {
		case <-stopCh:
			return nil, nil
		default:
		}
	
		// Handle the one-shot mode.
		if s.opts.SemaphoreTryOnce && attempts > 0 {
			elapsed := time.Now().Sub(start)
			if elapsed > qOpts.WaitTime {
				return nil, nil
			}
	
			qOpts.WaitTime -= elapsed
		}
		attempts++
		... goto WAIT ...

**Fixed.**

### github.com/gravitational/teleport/lib/reversetunnel/localsite.go:83

	func (s *localSite) GetLastConnected() time.Time {
		return time.Now()
	}

This gets recorded in a services.Site's LastConnected field, the only use of which is:

	c.Assert(time.Since(sites[0].LastConnected).Seconds() < 5, Equals, true)

**Fixed.**

### github.com/coreos/etcd/tools/benchmark/cmd/watch.go:201

	st := time.Now()
	for range r.Events {
		results <- report.Result{Start: st, End: time.Now()}
		bar.Increment()
		atomic.AddInt32(&nrRecvCompleted, 1)
	}

Those fields get used by

	func (res *Result) Duration() time.Duration { return res.End.Sub(res.Start) }

	func (r *report) processResult(res *Result) {
		if res.Err != nil {
			r.errorDist[res.Err.Error()]++
			return
		}
		dur := res.Duration()
		r.lats = append(r.lats, dur.Seconds())
		r.avgTotal += dur.Seconds()
		if r.sps != nil {
			r.sps.Add(res.Start, dur)
		}
	}

The duration computation is fixed by use of monotonic time. The call tp r.sps.Add buckets the start time by converting to Unix seconds and is therefore unaffected (start time only used once other than the duration calculation, so no visible jitter).

**Fixed.**

### github.com/flynn/flynn/vendor/github.com/flynn/oauth2/internal/token.go:191

	token.Expiry = time.Now().Add(time.Duration(expires) * time.Second)

used by:

	func (t *Token) expired() bool {
		if t.Expiry.IsZero() {
			return false
		}
		return t.Expiry.Add(-expiryDelta).Before(time.Now())
	}

Only partly fixed because sometimes token.Expiry has been loaded from a JSON serialization of a fixed time. But in the case where the expiry was set from a duration, the duration is now correctly enforced.

**Fixed.**

### github.com/hashicorp/consul/consul/fsm.go:266

	defer metrics.MeasureSince([]string{"consul", "fsm", "coordinate", "batch-update"}, time.Now())

**Fixed.**

### github.com/openshift/origin/vendor/github.com/coreos/etcd/clientv3/lease.go:437

	now := time.Now()
	l.mu.Lock()
	for id, ka := range l.keepAlives {
		if ka.nextKeepAlive.Before(now) {
			tosend = append(tosend, id)
		}
	}
	l.mu.Unlock()

ka.nextKeepAlive is set to either time.Now() or 

	nextKeepAlive := time.Now().Add(1 + time.Duration(karesp.TTL/3)*time.Second)

**Fixed.**

### github.com/eBay/fabio/cert/source_test.go:567

	func waitFor(timeout time.Duration, up func() bool) bool {
		until := time.Now().Add(timeout)
		for {
			if time.Now().After(until) {
				return false
			}
			if up() {
				return true
			}
			time.Sleep(100 * time.Millisecond)
		}
	}

**Fixed.**

### github.com/lucas-clemente/quic-go/ackhandler/sent_packet_handler_test.go:524

	err := handler.ReceivedAck(&frames.AckFrame{LargestAcked: 1}, 1, time.Now())
	Expect(err).NotTo(HaveOccurred())
	Expect(handler.rttStats.LatestRTT()).To(BeNumerically("~", 10*time.Minute, 1*time.Second))
	err = handler.ReceivedAck(&frames.AckFrame{LargestAcked: 2}, 2, time.Now())
	Expect(err).NotTo(HaveOccurred())
	Expect(handler.rttStats.LatestRTT()).To(BeNumerically("~", 5*time.Minute, 1*time.Second))
	err = handler.ReceivedAck(&frames.AckFrame{LargestAcked: 6}, 3, time.Now())
	Expect(err).NotTo(HaveOccurred())
	Expect(handler.rttStats.LatestRTT()).To(BeNumerically("~", 1*time.Minute, 1*time.Second))

where:

	func (h *sentPacketHandler) ReceivedAck(ackFrame *frames.AckFrame, withPacketNumber protocol.PacketNumber, rcvTime time.Time) error {
		...
		timeDelta := rcvTime.Sub(packet.SendTime)
		h.rttStats.UpdateRTT(timeDelta, ackFrame.DelayTime, rcvTime)
		...
	}

and packet.SendTime is initialized (earlier) with time.Now.

**Fixed.**


### github.com/CodisLabs/codis/pkg/proxy/redis/conn.go:140

	func (w *connWriter) Write(b []byte) (int, error) {
		...
		w.LastWrite = time.Now()
		...
	}

used by:

	func (p *FlushEncoder) NeedFlush() bool {
		...
		if p.MaxInterval < time.Since(p.Conn.LastWrite) {
			return true
		}
		...
	}

**Fixed.**


### github.com/docker/docker/vendor/github.com/docker/swarmkit/manager/scheduler/scheduler.go:173

	func (s *Scheduler) Run(ctx context.Context) error {
		...
		var (
			debouncingStarted     time.Time
			commitDebounceTimer   *time.Timer
		)
		...
	
		// Watch for changes.
		for {
			select {
			case event := <-updates:
				switch v := event.(type) {
				case state.EventCommit:
					if commitDebounceTimer != nil {
						if time.Since(debouncingStarted) > maxLatency {
							...
						}
					} else {
						commitDebounceTimer = time.NewTimer(commitDebounceGap)
						debouncingStarted = time.Now()
						...
					}
				}
			...
		}
	}

**Fixed.**

### golang.org/x/net/nettest/conntest.go:361

	c1.SetDeadline(time.Now().Add(10 * time.Millisecond))

**Fixed.**

### github.com/minio/minio/vendor/github.com/eapache/go-resiliency/breaker/breaker.go:120

	expiry := b.lastError.Add(b.timeout)
	if time.Now().After(expiry) {
		b.errors = 0
	}

where b.lastError is set using time.Now.

**Fixed.**

### github.com/pingcap/tidb/store/tikv/client.go:65

	start := time.Now()
	defer func() { sendReqHistogram.WithLabelValues("cop").Observe(time.Since(start).Seconds()) }()

**Fixed.**


### github.com/coreos/etcd/cmd/vendor/golang.org/x/net/context/go17.go:62

	return WithDeadline(parent, time.Now().Add(timeout))

**Fixed** (see above).

### github.com/coreos/rkt/rkt/image/common_test.go:161

	maxAge := 10
	for _, tt := range tests {
		age := time.Now().Add(time.Duration(tt.age) * time.Second)
		got := useCached(age, maxAge)
		if got != tt.use {
			t.Errorf("expected useCached(%v, %v) to return %v, but it returned %v", age, maxAge, tt.use, got)
		}
	}

where:

	func useCached(downloadTime time.Time, maxAge int) bool {
		freshnessLifetime := int(time.Now().Sub(downloadTime).Seconds())
		if maxAge > 0 && freshnessLifetime < maxAge {
			return true
		}
		return false
	}

**Fixed.**

### github.com/lucas-clemente/quic-go/flowcontrol/flow_controller.go:131

	c.lastWindowUpdateTime = time.Now()

used as:

	if c.lastWindowUpdateTime.IsZero() {
		return
	}
	...
	timeSinceLastWindowUpdate := time.Now().Sub(c.lastWindowUpdateTime)

**Fixed.**

### github.com/hashicorp/serf/serf/snapshot.go:327

	now := time.Now()
	if now.Sub(s.lastFlush) > flushInterval {
		s.lastFlush = now
		if err := s.buffered.Flush(); err != nil {
			return err
		}
	}

**Fixed.**

### github.com/junegunn/fzf/src/matcher.go:210

	startedAt := time.Now()
	...
	for matchesInChunk := range countChan {
		...
		if time.Now().Sub(startedAt) > progressMinDuration {
			m.eventBox.Set(EvtSearchProgress, float32(count)/float32(numChunks))
		}
	}

**Fixed.**

### github.com/mitchellh/packer/vendor/google.golang.org/appengine/demos/helloworld/helloworld.go:19

	var initTime = time.Now()

	func handle(w http.ResponseWriter, r *http.Request) {
		...
		tmpl.Execute(w, time.Since(initTime))
	}

**Fixed.**

### github.com/ncw/rclone/vendor/google.golang.org/appengine/internal/api.go:549

	func (c *context) logFlusher(stop <-chan int) {
		lastFlush := time.Now()
		tick := time.NewTicker(flushInterval)
		for {
			select {
			case <-stop:
				// Request finished.
				tick.Stop()
				return
			case <-tick.C:
				force := time.Now().Sub(lastFlush) > forceFlushInterval
				if c.flushLog(force) {
					lastFlush = time.Now()
				}
			}
		}
	}

**Fixed.**

### github.com/ethereum/go-ethereum/cmd/geth/chaincmd.go:159

	start := time.Now()
	...
	fmt.Printf("Import done in %v.\n\n", time.Since(start))

**Fixed.**

### github.com/nats-io/nats/test/conn_test.go:652

	if firstDisconnect {
		firstDisconnect = false
		dtime1 = time.Now()
	} else {
		dtime2 = time.Now()
	}

and later:

	if (dtime1 == time.Time{}) || (dtime2 == time.Time{}) || (rtime == time.Time{}) || (atime1 == time.Time{}) || (atime2 == time.Time{}) || (ctime == time.Time{}) {
		t.Fatalf("Some callbacks did not fire:\n%v\n%v\n%v\n%v\n%v\n%v", dtime1, rtime, atime1, atime2, dtime2, ctime)
	}

	if rtime.Before(dtime1) || dtime2.Before(rtime) || atime2.Before(atime1) || ctime.Before(atime2) {
		t.Fatalf("Wrong callback order:\n%v\n%v\n%v\n%v\n%v\n%v", dtime1, rtime, atime1, atime2, dtime2, ctime)
	}

**Fixed.**

### github.com/google/cadvisor/manager/container.go:456

	// Schedule the next housekeeping. Sleep until that time.
	if time.Now().Before(next) {
		time.Sleep(next.Sub(time.Now()))
	} else {
		next = time.Now()
	}
	lastHousekeeping = next

**Fixed.**

### github.com/google/cadvisor/vendor/golang.org/x/oauth2/token.go:98

	return t.Expiry.Add(-expiryDelta).Before(time.Now())

**Fixed** (see above).

### github.com/hashicorp/consul/consul/fsm.go:109

	defer metrics.MeasureSince([]string{"consul", "fsm", "register"}, time.Now())

**Fixed.**

### github.com/hashicorp/vault/vendor/github.com/hashicorp/yamux/session.go:295

	// Wait for a response
	start := time.Now()
	...

	// Compute the RTT
	return time.Now().Sub(start), nil

**Fixed.**

### github.com/go-kit/kit/examples/shipping/booking/instrumenting.go:31

	defer func(begin time.Time) {
		s.requestCount.With("method", "book").Add(1)
		s.requestLatency.With("method", "book").Observe(time.Since(begin).Seconds())
	}(time.Now())

**Fixed.**

### github.com/cyfdecyf/cow/timeoutset.go:22

	func (ts *TimeoutSet) add(key string) {
		now := time.Now()
		ts.Lock()
		ts.time[key] = now
		ts.Unlock()
	}

used by

	func (ts *TimeoutSet) has(key string) bool {
		ts.RLock()
		t, ok := ts.time[key]
		ts.RUnlock()
		if !ok {
			return false
		}
		if time.Now().Sub(t) > ts.timeout {
			ts.del(key)
			return false
		}
		return true
	}

**Fixed.**

### github.com/prometheus/prometheus/vendor/k8s.io/client-go/1.5/rest/request.go:761

	//Metrics for total request latency
	start := time.Now()
	defer func() {
		metrics.RequestLatency.Observe(r.verb, r.finalURLTemplate(), time.Since(start))
	}()

**Fixed.**

### github.com/ethereum/go-ethereum/p2p/discover/udp.go:383

	for {
		...
		select {
		...
		case p := <-t.addpending:
			p.deadline = time.Now().Add(respTimeout)
			...

		case now := <-timeout.C:
			// Notify and remove callbacks whose deadline is in the past.
			for el := plist.Front(); el != nil; el = el.Next() {
				p := el.Value.(*pending)
				if now.After(p.deadline) || now.Equal(p.deadline) {
					...
				}
			}
		}
	}

**Fixed** assuming time channels receive monotonic times as well.

### k8s.io/heapster/metrics/sinks/manager.go:150

	startTime := time.Now()
	...
	defer exporterDuration.
		WithLabelValues(s.Name()).
		Observe(float64(time.Since(startTime)) / float64(time.Microsecond))

**Fixed.**

### github.com/vmware/harbor/src/ui/auth/lock.go:43

	func (ul *UserLock) Lock(username string) {
		...
		ul.failures[username] = time.Now()
	}

used by:

	func (ul *UserLock) IsLocked(username string) bool {
		...
		return time.Now().Sub(ul.failures[username]) <= ul.d
	}

**Fixed.**

### github.com/openshift/origin/vendor/k8s.io/kubernetes/pkg/kubectl/resource_printer_test.go:1410

	{"an hour ago", translateTimestamp(unversioned.Time{Time: time.Now().Add(-6e12)}), "1h"},

where

	func translateTimestamp(timestamp unversioned.Time) string {
		if timestamp.IsZero() {
			return "<unknown>"
		}
		return shortHumanDuration(time.Now().Sub(timestamp.Time))
	}

**Fixed.**

### github.com/pingcap/pd/server/kv.go:194

	start := time.Now()
	resp, err := clientv3.NewKV(c).Get(ctx, key, opts...)
	if cost := time.Since(start); cost > kvSlowRequestTime {
		log.Warnf("kv gets too slow: key %v cost %v err %v", key, cost, err)
	}

**Fixed.**

### github.com/xtaci/kcp-go/sess.go:489

	if interval > 0 && time.Now().After(lastPing.Add(interval)) {
		...
		lastPing = time.Now()
	}
	
**Fixed.**

### github.com/go-xorm/xorm/lru_cacher.go:202

	el.Value.(*sqlNode).lastVisit = time.Now()

used as

	if removedNum <= core.CacheGcMaxRemoved &&
		time.Now().Sub(e.Value.(*idNode).lastVisit) > m.Expired {
		...
	}

**Fixed.**

### github.com/openshift/origin/vendor/github.com/samuel/go-zookeeper/zk/conn.go:510

	conn.SetWriteDeadline(time.Now().Add(c.recvTimeout))

**Fixed.**

### github.com/openshift/origin/vendor/k8s.io/kubernetes/pkg/client/leaderelection/leaderelection.go:236

	le.observedTime = time.Now()

used as:

	if le.observedTime.Add(le.config.LeaseDuration).After(now.Time) && ...

**Fixed.**

### k8s.io/heapster/events/sinks/manager.go:139

	startTime := time.Now()
	defer exporterDuration.
		WithLabelValues(s.Name()).
		Observe(float64(time.Since(startTime)) / float64(time.Microsecond))

**Fixed.**

### golang.org/x/net/ipv4/unicast_test.go:64

	... p.SetReadDeadline(time.Now().Add(100 * time.Millisecond)) ...

**Fixed.**

### github.com/kelseyhightower/confd/vendor/github.com/Sirupsen/logrus/text_formatter.go:27

	func init() {
		baseTimestamp = time.Now()
		isTerminal = IsTerminal()
	}
	
	func miniTS() int {
		return int(time.Since(baseTimestamp) / time.Second)
	}

**Fixed** (same as above, vendored in docker/libnetwork).

### github.com/openshift/origin/vendor/github.com/coreos/etcd/etcdserver/v3_server.go:693

	start := time.Now()
	...
	return nil, s.parseProposeCtxErr(cctx.Err(), start)

where

	curLeadElected := s.r.leadElectedTime()
	prevLeadLost := curLeadElected.Add(-2 * time.Duration(s.Cfg.ElectionTicks) * time.Duration(s.Cfg.TickMs) * time.Millisecond)
	if start.After(prevLeadLost) && start.Before(curLeadElected) {
		return ErrTimeoutDueToLeaderFail
	}

All the times involved end up being monotonic, making the After/Before checks more accurate.

**Fixed.**

