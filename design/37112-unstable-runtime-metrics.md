# Proposal: API for unstable runtime metrics

Author: Michael Knyszek

## Background & Motivation

The need for a new API for unstable metrics was already summarized quite well by
@aclements, so I'll quote that here:

> The runtime currently exposes heap-related metrics through
> `runtime.ReadMemStats` (which can be used programmatically) and
> `GODEBUG=gctrace=1` (which is difficult to read programmatically).
> These metrics are critical to understanding runtime behavior, but have some
> serious limitations:
> 1. `MemStats` is hard to evolve because it must obey the Go 1 compatibility
>    rules.
>    The existing metrics are confusing, but we can't change them.
>    Some of the metrics are now meaningless (like `EnableGC` and `DebugGC`),
>    and several have aged poorly (like hard-coding the number of size classes
>    at 61, or only having a single pause duration per GC cycle).
>    Hence, we tend to shy away from adding anything to this because we'll have
>    to maintain it for the rest of time.
> 1. The `gctrace` format is unspecified, which means we can evolve it (and have
>    completely changed it several times).
>    But it's a pain to collect programmatically because it only comes out on
>    stderr and, even if you can capture that, you have to parse a text format
>    that changes.
>    Hence, automated metric collection systems ignore gctrace.
>    There have been requests to make this programmatically accessible (#28623).
> There are many metrics I would love to expose from the runtime memory manager
> and scheduler, but our current approach forces me to choose between two bad
> options: programmatically expose metrics that are so fundamental they'll make
> sense for the rest of time, or expose unstable metrics in a way that's
> difficult to collect and process programmatically.

Other problems with `ReadMemStats` include performance, such as the need to
stop-the-world.
While it's otherwise difficult to collect many of the metrics in `MemStats`, not
all metrics require it, and it would be nice to be able to acquire some subset
of metrics without a global application penalty.

## Requirements

Conversing with @aclements, we agree that:
* The API should be easily extendable with new metrics.
* The API should be easily retractable, to deprecate old metrics.
    * Removing a metric should not break any Go applications as per the Go 1
      compatibility promise.
* The API should be discoverable, to obtain a list of currently relevant
  metrics.
* The API should be rich, allowing a variety of metrics (e.g. distributions).
* The API implementation should minimize CPU/memory usage, such that it does not
  appreciably affect any of the metrics being measured.
* The API should include useful existing metrics already exposed by the runtime.

## Goals

Given the requirements, I suggest we prioritize the following concerns when
designing the API in the following order.

1. Extensibility.
    * Metrics are "unstable" and therefore it should always be compatible to add
      or remove metrics.
    * Since metrics will tend to be implementation-specific, this feature is
      critical.
1. Discoverability.
    * Because these metrics are "unstable," there must be a way for the
      application, and for the human writing the application, to discover the
      set of usable metrics and be able to do something useful with that
      information (e.g. log the metric).
    * The API should enable collecting a subset of metrics programmatically.
      For example, one might want to "collect all memory-related metrics" or
      "collect all metrics which are efficient to collect".
1. Performance.
    * Must have a minimized effect on the metrics it returns in the
      steady-state.
    * Should scale up to 100s metrics, an amount that a human might consider "a
      lot."
        * Note that picking the right types to expose can limit the amount of
          metrics we need to expose.
          For example, a distribution type would significantly reduce the number
          of metrics.
1. Ergonomics.
    * The API should be as easy to use as it can be, given the above.

## Design

I propose we add a new standard library package to support a new runtime metrics
API to avoid polluting the namespace of existing packages.
The proposed name of the package is the `runtime/metrics` package.

I propose that this package expose a sampling-based API for acquiring runtime
metrics, in the same vein as `runtime.ReadMemStats`, that meets this proposal's
stated goals.
The sampling approach is taken in opposition to a stream-based (or event-based)
API.
Many of the metrics currently exposed by the runtime are "continuous" in the
sense that they're cheap to update and are updated frequently enough that
emitting an event for every update would be quite expensive, and would require
scaffolding to allow the user to control the emission rate.
Unless noted otherwise, this document will assume a sampling-based API.

With that said, I believe that in the future it will be worthwhile to expose an
event-based API as well, taking a hybrid approach, much like Linux's `perf`
tool.
See "Time series data" for a discussion of such an extension.

### Representation of metrics

Firstly, it probably makes the most sense to interact with a set of metrics,
rather than one metric at a time.
Many metrics require that the runtime reach some safe state to collect, so
naturally it makes sense to collect all such metrics at this time for
performance.
For the rest of this document, we're going to consider "sets of metrics" as the
unit of our API instead of individual metrics for this reason.

Second, the extendability and retractability requirements imply a less rigid
data structure to represent and interact with a set of metrics.
Perhaps the least rigid data structure in Go is something like a byte slice, but
this is decidedly too low-level to use from within a Go application because it
would need to have an encoding.
Simply defining a new encoding for this would be a non-trivial undertaking with
its own complexities.

The next least-rigid data structure is probably a Go map, which allows us to
associate some key for a metric with a sampled metric value.
The two most useful properties of maps here is that their set of keys is
completely dynamic, and that they allow efficient random access.
The inconvenience of a map though is its undefined iteration order.
While this might not matter if we're just constructing an RPC message to hit an
API, it does matter if one just wants to print statistics to STDERR every once
in a while for debugging.

A slightly more rigid data structure would be useful for managing an unstable
set of metrics is a slice of structs, with each struct containing a key (the
metric name) and a value.
This allows us to have a well-defined iteration order, and it's up to the user
if they want efficient random access.
For example, they could keep the slice sorted by metric keys, and do a binary
search over them, or even have a map on the side.

There are several variants of this slice approach (e.g. struct of keys slice and
values slice), but I think the general idea of using slices of key-value pairs
strikes the right balance between flexibility and usability.
Going any further in terms of rigidity and we end up right where we don't want
to be: with a `MemStats`-like struct.

Third, I propose the metric key be something abstract but still useful for
humans, such as a string.
An alternative might be an integral ID, where we provide a function to obtain a
metric's name from its ID.
However, using an ID pollutes the API.
Since we want to allow a user to ask for specific metrics, we would be required
to provide named constants for each metric which would later be deprecated.
It's also unclear that this would give any performance benefit at all.

Finally, we want the metric value to be able to take on a variety of forms.
Many metrics might work great as `uint64` values, but most do not.
For example we might want to collect a distribution of values (size classes are
one such example).
Distributions in particular can take on many different forms, for example if we
wanted to have an HDR histogram of STW pause times.
In the interest of being as extensible as possible, something like an empty
interface value works well here.

Putting this all together, I propose sampled metric values look like

```go
// Sample captures a single metric sample.
type Sample struct {
  Name string
  Value interface{}
}

// Read populates a slice of samples.
func Read(m []Sample)
```

### Efficiently populating a `[]struct{Name string, Value interface{}}`

Returning a `[]struct{Name string, Value interface{}}` on each call to the API
would cause potentially many allocations, which could mean a significant impact
on the performance of metrics collection in the steady-state (and also a skew in
the metrics themselves!).

To remedy this, we can do what `ReadMemStats` does: take a pointer to allocated
memory and populate it with values.
In this case, the first call may need to populate each Value field in the struct
with a new allocation.
However, since each metric is stable for the lifetime of the application binary
(because its stability is tied to the runtime's implementation), we can re-use
the same slice and all its values on subsequent calls without allocation,
provided that each Value field contains a pointer type.
For example, the Value field would contain a `*int64` instead of `int64`.
Using a non-pointer-typed value in the interface would require allocation on
every call; whereas using a pointer-typed value requires an initial allocation,
but that allocation can be reused on subsequent calls.

### Discoverability

To support discovering which metrics the system supports, we must provide a
function that returns the set of supported metric keys.

I propose that the discovery API return a slice of "metric descriptors" which
contain a "Name" field referring to a metric key.
Using a slice here mirrors the sampling API.

#### Metric naming

Choosing a naming scheme for each metric will significantly influence its usage,
since these are the names that will eventually be surfaced to the user.
There are two important properties we would like to have such that these metric
names may be smoothly and correctly exposed to the user.

The first, and perhaps most important of these properties is that semantics be
tied to their name.
If the semantics (including the type of each sample value) of a metric changes,
then the name should too.

The second is that the name should be easily parsable and mechanically
rewritable, since different metric collection systems have different naming
conventions.

Putting these two together, I propose that the metric name be built from two
components: its English name, and its unit (e.g. bytes, seconds).
I propose we separate the two components of "name" and "unit" by a colon (":")
and provide a well-defined format for the unit.

The use of an English name is in some ways not much of a deviation from
`ReadMemStats`, which uses Go identifiers for naming.
I propose that we mostly stick to the current convention and use UpperCamelCase
consisting of only uppercase and lowercase characters from the latin alphabet.
The introduction of this new API is also a good time to rename some of the more
vaguely named statistics, and perhaps to introduce a better namespacing
convention.
Austin suggested using a common prefixes for namespacing such as "GC" or
"Sched," which seems good enough to me.

Including the unit in the name may be a bit surprising at first.
First of all, why should the unit even be a string? One alternative way to
represent the unit is to use some structured format, but this has the potential
to lock us into some bad decisions or limit us to only a certain subset of
units.
Using a string gives us more flexibility to extend the units we support in the
future.
Thus, I propose that no matter what we do, we should definitely keep the unit as
a string.

In terms of a format for this string, I think we should keep the unit closely
aligned with the Go benchmark output format to facilitate a nice user experience
for measuring these metrics within the Go testing framework.
This goal suggests the following very simple format: a series of all-lowercase
common base unit names, singular or plural, without SI prefixes (such as
"seconds" or "bytes", not "nanoseconds" or "MiB"), potentially containing
hyphens (e.g. "cpu-seconds"), delimited by either `*` or `/` characters.
A regular expression is sufficient to describe the format, and ignoring the
restriction of common base unit names, would look like
`^[a-z-]+(?:[*\/][a-z-]+)*$`.

Why should the unit be a part of the name? Mainly to help maintain the first
property mentioned above.
If we decide to change a metric's unit, which represents a semantic change, then
the name must also change.
Also, in this situation, it's much more difficult for a user to forget to
include the unit.
If their metric collection system has no rules about names, then great, they can
just use whatever Go gives them.
If they do (and most seem to be fairly opinionated) it forces the user to
account for the unit when dealing with the name and it lessens the chance that
it would be forgotten.
Furthermore, splitting a string is typically less computationally expensive than
combining two strings.

#### Metric Descriptors

Firstly, any metric descriptor must contain the name of the metric.
No matter which way we choose to store a set of descriptions, it is both useful
and necessary to carry this information around.
Another useful field is the unit of the metric.
As mentioned above in discussing metric naming, I propose that the unit be kept
as part of the name.

The metric descriptor should also indicate the performance sensitivity of the
metric.
Today `ReadMemStats` forces the user to endure a stop-the-world to collect all
metrics.
There are a number of pieces of information we could add, but one good one for
now would be "does this metric require a stop-the-world event?".
The intended use of such information would be to collect certain metrics less
often, or to exclude them altogether from metrics collection.
While this is fairly implementation-specific for metadata, the majority of
tracing GC designs involve a stop-the-world event at one point or another.

Another useful aspect of a metric descriptor would be to indicate whether the
metric is a "gauge" or a "counter" (i.e. it increases monotonically).
We have examples of both in the runtime and this information is often useful to
bubble up to metrics collection systems to influence how they're displayed and
what operations are valid on them (e.g. counters are often more usefully viewed
as rates).
By including whether a metric is a gauge or a counter in the descriptions,
metrics collection systems don't have to try to guess, and users don't have to
annotate exported metrics manually; they can do so programmatically.

### Time series metrics

The API as described so far has been a sampling-based API, but many metrics are
updated at well-defined (and relatively infrequent) intervals, such as many of
the metrics found in the `gctrace` output.
These metrics, which I'll call "time series metrics," may be sampled, but the
sampling operation is inherently lossy.
In many cases it's very useful for performance debugging to have precise
information of how a metric might change e.g. from GC cycle to GC cycle.

Measuring such metrics thus fits better in an event-based, or stream-based API,
which emits a stream of metric values (tagged with precise timestamps) which are
then ingested by the application and logged someplace.

While we stated earlier that considering such time series metrics is outside of
the scope of this proposal, it's worth noting that buying into a sampling-based
API today does not close any doors toward exposing precise time series metrics
in the future.
A straightforward way of extending the API would be to add the time series
metrics to the total list of metrics, allowing the usual sampling-based approach
if desired, while also tagging some metrics with a "time series" flag in their
descriptions.
The event-based API, in that form, could then just be a pure addition.

A feasible alternative in this space is to only expose a sampling API, but to
include a timestamp on event metrics to allow users to correlate metrics with
specific events.
For example, if metrics came from the previous GC, they would be tagged with the
timestamp of that GC, and if the metric and timestamp hadn't changed, the user
could identify that.

One interesting consequence of having an event-based API which is prompt is that
users could then to Go runtime state on-the-fly, such as for detecting when the
GC is running.
On the one hand, this could provide value to some users of Go, who require
fine-grained feedback from the runtime system.
On the other hand, the supported metrics will still always be unstable, so
relying on a metric for feedback in one release might no longer be possible in a
future release.

## Draft API Specification

Given the discussion of the design above, I propose the following draft API
specification.

```go
package metrics

// Metric describes a runtime metric.
type Metric struct {
  // Name is the full name of the metric which includes the unit.
  //
  // The format of the metric may be described by the following regular expression.
  // ^(?P<name>[^:]+):(?P<unit>[^:*\/]+(?:[*\/][^:*\/]+)*)$
  //
  // The format splits the name into two components, separated by a colon: a human-readable
  // name and a computer-parseable unit. The name may only contain characters in the lowercase
  // and uppercase latin alphabet, and by convention will be UpperCamelCase.
  //
  // The unit is a series of lowercase English unit names (singular or plural) without
  // prefixes (but potentially containing hyphens) delimited by ‘*' or ‘/'. For example
  // "seconds", "bytes", "bytes/second", "cpu-seconds", "byte*cpu-seconds", and
  // "bytes/second/second" are all valid. The value will never contain whitespace.
  //
  // A complete name might look like "GCPauseTimes:seconds".
  Name string

  // Cumulative is whether or not the metric is cumulative. If a cumulative metric is just
  // a single number, then it increases monotonically. If the metric is a distribution,
  // then each bucket count increases monotonically.
  //
  // This flag thus indicates whether or not it's useful to compute a rate from this value.
  Cumulative bool

  // StopTheWorld is whether or not the metric requires a stop-the-world
  // event in order to collect it.
  StopTheWorld bool
}

// Histogram is an interface for a distribution of a runtime metric.
type Histogram interface {
  // Buckets returns a range of values represented by each bucket.
  //
  // The valid return types are one of `[]float64` or `[]time.Duration`.
  // More valid return types may be added in the future, and the caller
  // should be prepared to handle them.
  //
  // The slice contains the boundaries between buckets, in increasing order.
  // There are len(slice)+1 total buckets: a bucket for all values less than
  // the first boundary, a bucket covering each [slice[i], slice[i+1]) interval,
  // and a bucket for all values greater than or equal to the last boundary.
  Buckets() interface{}

  // Counts populates the given slice with weights for each histogram
  // bucket. The length of this slice should be the length of the slice
  // returned by Buckets, plus one to account for the implicit minimum
  // bucket. If the given slice is too small, this method will panic.
  //
  // Given N buckets, the following is the mathematical relationship between
  // Counts and Buckets.
  // count[0] is the weight of the range (-inf, bucket[0])
  // count[n] is the weight of the range [bucket[n], bucket[n+1]), for 0 < n < N-1
  // count[N-1] is the weight of the range [bucket[N-1], inf)
  Counts([]uint64)

  // ValueSum returns the sum of all the values added to the distribution.
  //
  // Note that this sum is exact, so it cannot be computed from Buckets and
  // Counts. This value is useful for computing an accurate mean.
  //
  // The valid return types are one of `float64` or `time.Duration`.
  ValueSum() interface{}
}

// Descriptions returns a slice of metric descriptions for all metrics.
func Descriptions() []Metric

// Sample captures a single metric sample.
type Sample struct {
  // Name is the name of the metric sampled.
  //
  // It must correspond to a name in one of the metric descriptions
  // returned by Descriptions.
  Name string

  // Value is the value of the metric sample.
  //
  // The valid set of types which this field may take on are *uint64,
  // *int64, *float64, *time.Duration, and Histogram.
  //
  // This set of types may expand in the future, but will never shrink.
  Value interface{}
}

// Read populates the given slice of metric samples.
//
// Desired metrics should be present in the slice with the appropriate name.
//
// The first time Read is called, it will populate each value's
// Value field with a properly sized allocation, which may then be
// re-used by subsequent calls to Read. The user is therefore
// encouraged to re-use the same slice between calls.
//
// Metric values with names not appearing in the value returned by Descriptions
// will simply be left untouched.
func Read(m []Sample)
```

The usage of the API we have in mind for collecting specific metrics is the
following:

```go
var stats = []metrics.Sample{
  {Name: "GCHeapGoal:bytes"},
  {Name: "GCPauses:seconds"},
}

// Somewhere...
...
  go statsLoop(stats)
...

func statsLoop(stats []metrics.Sample, d time.Duration) {
  // Read and print stats every 30 seconds.
  ticker := time.NewTicker(30*time.Second)
  for {
    metrics.Read(stats)
    for _, sample := range stats {
      split := strings.IndexByte(sample.Name, ‘:')
      name, unit := sample.Name[:split], sample.Name[split+1:]
      switch v := value.(type) {
      case *int64:
        log.Printf("%s: %s %d %s", name, *v, unit)
      case *uint64:
        log.Printf("%s: %s %d %s", name, *v, unit)
      case *float64:
        log.Printf("%s: %s %f %s", name, *v, unit)
      case *time.Duration:
        log.Printf("%s: %s %s %s", name, *v)
      case Histogram:
        log.Printf("%s: %s mean %f %s", name, v.ValueSum()/v.CountSum(), unit)
      }
    }
    <-ticker.C
  }
}
```

I believe common usage will be to simply slurp up all metrics, which would look
like this:

```go
...
  // Generate a sample array for all the metrics.
  desc := metrics.Descriptions()
  stats := make([]metric.Sample, len(desc))
  for _, desc := range {
    stats = append(stats, metric.Sample{Name: desc.Name})
  }
  go statsLoop(stats)
...
```

## Proposed initial list of metrics

### Existing metrics

```
GCHeapFree:bytes        *uint64 // (== HeapIdle - HeapReleased)
GCHeapUncommitted:bytes *uint64 // (== HeapReleased)
GCHeapObject:bytes      *uint64 // (== HeapAlloc)
GCHeapUnused:bytes      *uint64 // (== HeapInUse - HeapAlloc)
StackInUse:bytes        *uint64 // (== StackInuse)
StackOther:bytes        *uint64 // (== StackSys - StackInuse)

GCHeapObjects:objects          *uint64 // (== HeapObjects)
GCMSpanInUse:bytes             *uint64 // (== MSpanInUse)
GCMSpanFree:bytes              *uint64 // (== MSpanSys - MSpanInUse)
GCMCacheInUse:bytes            *uint64 // (== MCacheInUse)
GCMCacheFree:bytes             *uint64 // (== MCacheSys - MCacheInUse)
GCCount:completed-cycles       *uint64 // (== NumGC)
GCForcedCount:completed-cycles *uint64 // (== NumForcedGC)
ProfilingBucketMemory:bytes    *uint64 // (== BuckHashSys)
GCMetadata:bytes               *uint64 // (== GCSys)
RuntimeOtherMemory:bytes       *uint64 // (== OtherSys)

// (== GCHeap.* + StackInUse + StackOther + GCMSpan.* + GCMCache.* +
// ProfilingBucketMemory + GCMetadata + RuntimeOtherMemory)
RuntimeVirtualMemory:bytes *uint64

GCHeapGoal:bytes *uint64 // (== NextGC)
```

## New GC metrics

```
// Distribution of what fraction of CPU time was spent in each GC cycle.
GCCPUPercent:cpu-percent Histogram

// Distribution of pause times, replaces PauseNs and PauseTotalNs.
GCPauses:seconds Histogram

// Distribution of unsmoothed trigger ratio.
GCTriggerRatios:ratio Histogram

// Distribution of objects by size.
// Buckets correspond directly to size classes up to 32 KiB,
// after that it's approximated by an HDR histogram.
// GCHeapAllocations replaces BySize, TotalAlloc, and Mallocs.
// GCHeapFrees replaces BySize and Frees.
GCHeapAllocations:bytes Histogram
GCHeapFrees:bytes       Histogram

// Distribution of allocations satisfied by the page cache.
// Buckets are exact since there are only 16 options.
GCPageCacheAllocations:bytes Histogram

// Distribution of stack scanning latencies. HDR histogram.
GCStackScans:seconds Histogram
```

## Scheduler metrics

```
SchedGoroutines:goroutines        *uint64
SchedAsyncPreemptions:preemptions *uint64

// Distribution of how long goroutines stay in runnable
// before transitioning to running. HDR histogram.
SchedTimesToRun:seconds Histogram
```

## Backwards Compatibility

Note that although the set of metrics the runtime exposes will not be stable
across Go versions, the API to discover and access those metrics will be.

Therefore, this proposal strictly increases the API surface of the Go standard
library without changing any existing functionality and is therefore Go 1
compatible.

