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
interface value could work here.

However, an empty interface value has implications for performance.
How do we efficiently populate that empty interface value without allocating?
One idea is to only use pointer types, for example it might contain `*float64`
or `*uint64` values.
While this strategy allows us to re-use allocations between samples, it's
starting to rely on the internal details of Go interface types for efficiency.

Fundamentally, the problem we have here is that we want to include a fixed set
of valid types as possible values.
This concept maps well to the notion of a sum type in other languages.
While Go lacks such a facility, we can emulate one.
Consider the following representation for a value:

```go
type Kind int

const (
	KindBad Kind = iota
	KindUint64
	KindFloat64
	KindFloat64Histogram
)

type Value struct {
	// unexported fields
}

func (v Value) Kind() Kind

// panics if v.Kind() != KindUint64
func (v Value) Uint64() uint64

// panics if v.Kind() != KindFloat64
func (v Value) Float64() float64

// panics if v.Kind() != KindFloat64Histogram
func (v Value) Float64Histogram() *Float64Histogram
```

The advantage of such a representation means that we can hide away details about
how each metric sample value is actually represented.
For example, we could embed a `uint64` slot into the `Value` which is used to
hold either a `uint64`, a `float64`, or an `int64`, and which is populated
directly by the runtime without any additional allocations at all.
For types which will require an indirection, such as histograms, we could also
hold an `unsafe.Pointer` or `interface{}` value as an unexported field and pull
out the correct type as needed.
In these cases we would still need to allocate once up-front (the histogram
needs to contain a slice for counts, for example).

The downside of such a structure is mainly ergonomics.
In order to use it effectively, one needs to `switch` on the result of the
`Kind()` method, then call the appropriate method to get the underlying value.
While in that case we lose some type safety as opposed to using an `interface{}`
and a type-switch construct, there is some precedent for such a structure.
In particular a `Value` mimics the API `reflect.Value` in some ways.

Putting this all together, I propose sampled metric values look like

```go
// Sample captures a single metric sample.
type Sample struct {
  Name string
  Value Value
}
```

Furthermore, I propose that we use a slice of these `Sample` structures to
represent our "snapshot" of the current state of the system (i.e. the
counterpart to `runtime.MemStats`).

### Discoverability

To support discovering which metrics the system supports, we must provide a
function that returns the set of supported metric keys.

I propose that the discovery API return a slice of "metric descriptions" which
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
components: a forward-slash-separated path to a metric where each component is
lowercase words separated by hyphens (the "name", e.g. "/memory/heap/free"), and
its unit (e.g. bytes, seconds).
I propose we separate the two components of "name" and "unit" by a colon (":")
and provide a well-defined format for the unit (e.g. "/memory/heap/free:bytes").

Representing the metric name as a path is intended to provide a mechanism for
namespacing metrics.
Many metrics naturally group together, and this provides a straightforward way
of filtering out only a subset of metrics, or perhaps matching on them.
The use of lower-case and hyphenated path components is intended to make the
name easy to translate to most common naming conventions used in metrics
collection systems.
The introduction of this new API is also a good time to rename some of the more
vaguely named statistics, and perhaps to introduce a better namespacing
convention.

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

#### Metric Descriptions

Firstly, any metric description must contain the name of the metric.
No matter which way we choose to store a set of descriptions, it is both useful
and necessary to carry this information around.
Another useful field is an English description of the metric.
This description may then be propagated into metrics collection systems
dynamically.

The metric description should also indicate the performance sensitivity of the
metric.
Today `ReadMemStats` forces the user to endure a stop-the-world to collect all
metrics.
There are a number of pieces of information we could add, but one good one for
now would be "does this metric require a stop-the-world event?".
The intended use of such information would be to collect certain metrics less
often, or to exclude them altogether from metrics collection.
While this is fairly implementation-specific for metadata, the majority of
tracing GC designs involve a stop-the-world event at one point or another.

Another useful aspect of a metric description would be to indicate whether the
metric is a "gauge" or a "counter" (i.e. it increases monotonically).
We have examples of both in the runtime and this information is often useful to
bubble up to metrics collection systems to influence how they're displayed and
what operations are valid on them (e.g. counters are often more usefully viewed
as rates).
By including whether a metric is a gauge or a counter in the descriptions,
metrics collection systems don't have to try to guess, and users don't have to
annotate exported metrics manually; they can do so programmatically.

Finally, metric descriptions should allow users to filter out metrics that their
application can't understand.
The most common situation in which this can happen is if a user upgrades or
downgrades the Go version their application is built with, but they do not
update their code.
Another situation in which this can happen is if a user switches to a different
Go runtime (e.g. TinyGo).
There may be a new metric in this Go version represented by a type which was not
used in previous versions.
For this case, it's useful to include type information in the metric description
so that applications can programmatically filter these metrics out.
In this case, I propose we use add a `Kind` field to the description.

#### Documentation

While the metric descriptions allow an application to programmatically discover
the available set of metrics at runtime, it's tedious for humans to write an
application just to dump the set of metrics available to them.

For `ReadMemStats`, the documentation is on the `MemStats` struct itself.
For `gctrace` it is in the runtime package's top-level comment.
Because this proposal doesn't tie metrics to Go variables or struct fields, the
best we can do is what `gctrace` does and document it in the metrics
package-level documentation.
A test in the `runtime/metrics` package will ensure that the documentation
always matches the metric's English description.

Furthermore, the documentation should contain a record of when metrics were
added and when metrics were removed (such as a note like "(since Go 1.X)" in the
English description).
Users who are using an old version of Go but looking at up-to-date
documentation, such as the documentation exported to golang.org, will be able to
more easily discover information relevant to their application.
If a metric is removed, the documentation should note which version removed it.

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

// Float64Histogram represents a distribution of float64 values.
type Float64Histogram struct {
	// Counts contains the weights for each histogram bucket. The length of
	// Counts is equal to the length of Bucket plus one to account for the
	// implicit minimum bucket.
	//
	// Given N buckets, the following is the mathematical relationship between
	// Counts and Buckets.
	// count[0] is the weight of the range (-inf, bucket[0])
	// count[n] is the weight of the range [bucket[n], bucket[n+1]), for 0 < n < N-1
	// count[N-1] is the weight of the range [bucket[N-1], inf)
	Counts []uint64

	// Buckets contains the boundaries between histogram buckets, in increasing order.
	//
	// Because this slice contains boundaries, there are len(Buckets)+1 total buckets:
	// a bucket for all values less than the first boundary, a bucket covering each
	// [slice[i], slice[i+1]) interval, and a bucket for all values greater than or
	// equal to the last boundary.
	Buckets []float64
}

// Clone generates a deep copy of the Float64Histogram.
func (f *Float64Histogram) Clone() *Float64Histogram

// Kind is a tag for a metric Value which indicates its type.
type Kind int

const (
	// KindBad indicates that the Value has no type and should not be used.
	KindBad Kind = iota

	// KindUint64 indicates that the type of the Value is a uint64.
	KindUint64

	// KindFloat64 indicates that the type of the Value is a float64.
	KindFloat64

	// KindFloat64Histogram indicates that the type of the Value is a *Float64Histogram.
	KindFloat64Histogram
)

// Value represents a metric value returned by the runtime.
type Value struct {
	kind    Kind
	scalar  uint64         // contains scalar values for scalar Kinds.
	pointer unsafe.Pointer // contains non-scalar values.
}

// Value returns a value of one of the types mentioned by Kind.
//
// This function may allocate memory.
func (v Value) Value() interface{}

// Kind returns the a tag representing the kind of value this is.
func (v Value) Kind() Kind

// Uint64 returns the internal uint64 value for the metric.
//
// If v.Kind() != KindUint64, this method panics.
func (v Value) Uint64() uint64

// Float64 returns the internal float64 value for the metric.
//
// If v.Kind() != KindFloat64, this method panics.
func (v Value) Float64() float64

// Float64Histogram returns the internal *Float64Histogram value for the metric.
//
// The returned value may be reused by calls to Read, so the user should clone
// it if they intend to use it across calls to Read.
//
// If v.Kind() != KindFloat64Histogram, this method panics.
func (v Value) Float64Histogram() *Float64Histogram

// Description describes a runtime metric.
type Description struct {
	// Name is the full name of the metric, including the unit.
	//
	// The format of the metric may be described by the following regular expression.
	// ^(?P<name>/[^:]+):(?P<unit>[^:*\/]+(?:[*\/][^:*\/]+)*)$
	//
	// The format splits the name into two components, separated by a colon: a path which always
	// starts with a /, and a machine-parseable unit. The name may contain any valid Unicode
	// codepoint in between / characters, but by convention will try to stick to lowercase
	// characters and hyphens. An example of such a path might be "/memory/heap/free".
	//
	// The unit is by convention a series of lowercase English unit names (singular or plural)
	// without prefixes delimited by '*' or '/'. The unit names may contain any valid Unicode
	// codepoint that is not a delimiter.
	// Examples of units might be "seconds", "bytes", "bytes/second", "cpu-seconds",
	// "byte*cpu-seconds", and "bytes/second/second".
	//
	// A complete name might look like "/memory/heap/free:bytes".
	Name string

	// Cumulative is whether or not the metric is cumulative. If a cumulative metric is just
	// a single number, then it increases monotonically. If the metric is a distribution,
	// then each bucket count increases monotonically.
	//
	// This flag thus indicates whether or not it's useful to compute a rate from this value.
	Cumulative bool

	// Kind is the kind of value for this metric.
	//
	// The purpose of this field is to allow users to filter out metrics whose values are
	// types which their application may not understand.
	Kind Kind

	// StopTheWorld is whether or not the metric requires a stop-the-world
	// event in order to collect it.
	StopTheWorld bool
}

// All returns a slice of containing metric descriptions for all supported metrics.
func All() []Description

// Sample captures a single metric sample.
type Sample struct {
	// Name is the name of the metric sampled.
	//
	// It must correspond to a name in one of the metric descriptions
	// returned by Descriptions.
	Name string

	// Value is the value of the metric sample.
	Value Value
}

// Read populates each Value element in the given slice of metric samples.
//
// Desired metrics should be present in the slice with the appropriate name.
// The user of this API is encouraged to re-use the same slice between calls.
//
// Metric values with names not appearing in the value returned by Descriptions
// will simply be left untouched (Value.Kind == KindBad).
func Read(m []Sample)
```

The usage of the API we have in mind for collecting specific metrics is the
following:

```go
var stats = []metrics.Sample{
	{Name: "/gc/heap/goal:bytes"},
	{Name: "/gc/pause-latency-distribution:seconds"},
}

// Somewhere...
...
	go statsLoop(stats, 30*time.Second)
...

func statsLoop(stats []metrics.Sample, d time.Duration) {
	// Read and print stats every 30 seconds.
	ticker := time.NewTicker(d)
	for {
		metrics.Read(stats)
		for _, sample := range stats {
			split := strings.IndexByte(sample.Name, ':')
			name, unit := sample.Name[:split], sample.Name[split+1:]
			switch value.Kind() {
			case KindUint64:
				log.Printf("%s: %d %s", name, value.Uint64(), unit)
			case KindFloat64:
				log.Printf("%s: %d %s", name, value.Float64(), unit)
			case KindFloat64Histogram:
				v := value.Float64Histogram()
				m := computeMean(v)
				log.Printf("%s: %f avg %s", name, m, unit)
			default:
				log.Printf("unknown value %s:%s: %v", sample.Value())
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
	desc := metrics.All()
	stats := make([]metric.Sample, len(desc))
	for i := range desc {
		stats[i] = metric.Sample{Name: desc[i].Name}
	}
	go statsLoop(stats, 30*time.Second)
...
```

## Proposed initial list of metrics

### Existing metrics

```
/memory/heap/free:bytes        KindUint64 // (== HeapIdle - HeapReleased)
/memory/heap/uncommitted:bytes KindUint64 // (== HeapReleased)
/memory/heap/objects:bytes     KindUint64 // (== HeapAlloc)
/memory/heap/unused:bytes      KindUint64 // (== HeapInUse - HeapAlloc)
/memory/heap/stacks:bytes      KindUint64 // (== StackInuse)

/memory/metadata/mspan/inuse:bytes             KindUint64 // (== MSpanInUse)
/memory/metadata/mspan/free:bytes              KindUint64 // (== MSpanSys - MSpanInUse)
/memory/metadata/mcache/inuse:bytes            KindUint64 // (== MCacheInUse)
/memory/metadata/mcache/free:bytes             KindUint64 // (== MCacheSys - MCacheInUse)
/memory/metadata/other:bytes                   KindUint64 // (== GCSys)
/memory/metadata/profiling/buckets-inuse:bytes KindUint64 // (== BuckHashSys)

/memory/other:bytes        KindUint64 // (== OtherSys)
/memory/native-stack:bytes KindUint64 // (== StackSys - StackInuse)

/aggregates/total-virtual-memory:bytes KindUint64 // (== sum over everything in /memory/**)

/gc/heap/objects:objects       KindUint64 // (== HeapObjects)
/gc/heap/goal:bytes            KindUint64 // (== NextGC)
/gc/cycles/completed:gc-cycles KindUint64 // (== NumGC)
/gc/cycles/forced:gc-cycles    KindUint64 // (== NumForcedGC)
```

## New GC metrics

```
// Distribution of pause times, replaces PauseNs and PauseTotalNs.
/gc/pause-latency-distribution:seconds KindFloat64Histogram

// Distribution of unsmoothed trigger ratio.
/gc/pacer/trigger-ratio-distribution:ratio KindFloat64Histogram

// Distribution of what fraction of CPU time was spent on GC in each GC cycle.
/gc/pacer/utilization-distribution:cpu-percent KindFloat64Histogram

// Distribution of objects by size.
// Buckets correspond directly to size classes up to 32 KiB,
// after that it's approximated by an HDR histogram.
// allocs-by-size replaces BySize, TotalAlloc, and Mallocs.
// frees-by-size replaces BySize and Frees.
/malloc/allocs-by-size:bytes KindFloat64Histogram
/malloc/frees-by-size:bytes  KindFloat64Histogram

// How many hits and misses in the mcache.
/malloc/cache/hits:allocations   KindUint64
/malloc/cache/misses:allocations KindUint64

// Distribution of sampled object lifetimes in number of GC cycles.
/malloc/lifetime-distribution:gc-cycles KindFloat64Histogram

// How many page cache hits and misses there were.
/malloc/page/cache/hits:allocations   KindUint64
/malloc/page/cache/misses:allocations KindUint64

// Distribution of stack scanning latencies. HDR histogram.
/gc/stack-scan-latency-distribution:seconds KindFloat64Histogram
```

## Scheduler metrics

```
/sched/goroutines:goroutines     KindUint64
/sched/preempt/async:preemptions KindUint64
/sched/preempt/sync:preemptions  KindUint64

// Distribution of how long goroutines stay in runnable
// before transitioning to running. HDR histogram.
/sched/time-to-run-distribution:seconds KindFloat64Histogram
```

## Backwards Compatibility

Note that although the set of metrics the runtime exposes will not be stable
across Go versions, the API to discover and access those metrics will be.

Therefore, this proposal strictly increases the API surface of the Go standard
library without changing any existing functionality and is therefore Go 1
compatible.

