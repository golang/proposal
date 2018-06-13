# Proposal: percpu.Sharded, an API for reducing cache contention

Discussion at https://golang.org/issue/18802

## Abstract

As it stands, Go programs do not have a good way to avoid contention when
combining highly concurrent code with shared memory locations that frequently
require mutation. This proposal describes a new package and type to satisfy this
need.

## Background

There are several scenarios in which a Go program might want to have shared data
that is mutated frequently. We will briefly discuss some of these scenarios,
such that we can evaluate the proposed API against these concrete use-cases.

### Counters

In RPC servers or in scientific computing code, there is often a need for global
counters. For instance, in an RPC server, a global counter might count the
number of requests received by the server, or the number of bytes received by
the server. Go makes it easy to write RPC servers which are inherently
concurrent, often processing each connection and each request on a concurrent
goroutine. This means that in the context of a multicore machine, several
goroutines can be incrementing the same global counter in parallel. Using an API
like `atomic.AddInt64` will ensure that such a counter is lock-free, but
parallel goroutines will be contending for the same cache line, so this counter
will not experience linear scalability as the number of cores is increased.
(Indeed, one might even expect scalability to unexpectedly decrease due to
increased core-to-core communication).

It's probably also worth noting that there are other similar use-cases in this
space (e.g. types that record distributions rather than just sums, max-value
trackers, etc).

### Read-write locks

It is common in programs to have data that is read frequently, but written very
rarely. In these cases, a common synchronization primitive is `sync.RWMutex`,
which offers an `RLock`/`RUnlock` API for readers. When no writers are
interacting with an `RWMutex`, an arbitrary number of goroutines can use the
read-side of the `RWMutex` without blocking.

However, in order to correctly pair calls to `RLock` with calls to `RUnlock`,
`RWMutex` internally maintains a counter, which is incremented during `RLock`
and decremented during `RUnlock`. There is also other shared mutable state that
is atomically updated inside the `RWMutex` during these calls (and during
calls to `Lock` and `Unlock`). For reasons similar to the previous example, if
many goroutines are acquiring and releasing read-locks concurrently and the
program is running on a multicore machine, then it is likely that the
performance of `RWMutex.RLock`/`RWMutex.RUnlock` will not scale linearly with
the number of cores given to the program.

### RPC clients

In programs that make many RPC calls in parallel, there can be
contention on shared mutable state stored inside the RPC or HTTP clients. For
instance, an RPC client might support connecting to a pool of servers, and
implements a configurable load balancing policy to select a connection to use
for a given RPC; these load balancing policies often need to maintain state for
each connection in the pool of managed connections. For instance, an
implementation of the "Least-Loaded" policy needs to maintain a counter of
active requests per connection, such that a new request can select the
connection with the least number of active requests. In scenarios where a client
is performing a large number of requests in parallel (perhaps enqueueing many
RPCs before finally waiting on them at a later point in the program), then
contention on this internal state can start to affect the rate at which the
requests can be dispatched.

### Order-independent accumulators

In data-processing pipelines, code running in a particular stage may want to
'batch' its output, such that it only sends data downstream in N-element
batches, rather than sending single elements through the pipeline at a time. In
the single-goroutine case and where the element type is 'byte', then the
familiar type `bufio.Writer` implements this pattern. Indeed, one
option for the general data-processing pipeline, is to have a single goroutine
run every stage in the pipeline from end-to-end, and then instantiate a small
number of parallel pipeline instances. This strategy effectively handles
pipelines composed solely of stages dominated by CPU-time. However, if a
pipeline contains any IO (e.g. initially reading the input from a distributed
file system, making RPCs, or writing the result back to a distributed file
system), then this setup will not be efficient, as a single stall in IO will
take out a significant chunk of your throughput.

To mitigate this problem, IO bound stages need to run many goroutines. Indeed,
a clever framework (like Apache Beam) can detect these sorts of situations
dynamically, by measuring the rate of stage input compared to the rate of stage
output; they can even reactively increase or decrease the "concurrency level" of
a stage in response to these measurements. In Beam's case, it might do this by
dynamically changing the number of threads-per-binary, or number of
workers-per-stage.

When stages have varying concurrency levels, but are connected to each other in
a pipeline structure, it is important to place a concurrency-safe abstraction
between the stages to buffer elements waiting to be processed by the next stage.
Ideally, this structure would minimize the contention experienced by the caller.

## The Proposed API

To solve these problems, we propose an API with a single new type
`percpu.Sharded`. Here is an outline of the proposed API.

```go
// Package percpu provides low-level utilities for avoiding contention on
// multicore machines.
package percpu

// A Sharded is a container of homogenously typed values.
//
// On a best effort basis, the runtime will strongly associate a given value
// with a CPU core. That is to say, retrieving a value twice on the same CPU
// core will return the same value with high probablity. Note that the runtime
// cannot guarantee this fact, and clients must assume that retrieved values
// can be shared between concurrently executing goroutines.
//
// Once a value is placed in a Sharded, the Sharded will retain a reference to
// this value permanently. Clients can control the maximum number of distinct
// values created using the SetMaxShards API.
//
// A Sharded must not be copied after first use.
//
// All methods are safe to call from multiple goroutines.
type Sharded struct {
  // contains unexported fields
}

// SetMaxShards sets a limit on the maximum number of elements stored in the
// Sharded.
//
// It will not apply retroactively, any elements already created will remain
// inside the Sharded.
//
// If maxShards is less than 1, Sharded will panic.
func (s *Sharded) SetMaxShards(maxShards int)

// GetOrCreate retrieves a value roughly associated with the current CPU. If
// there is no such value, then createFn is called to create a value, store it
// in the Sharded, and return it.
//
// All calls to createFn are serialized; this means that one must complete
// before the next one is started.
//
// createFn should not return nil, or Sharded will panic.
//
// If createFn is called with a ShardInfo.ShardIndex equal to X, no future call
// to GetOrCreate will call createFn again with a ShardInfo.ShardIndex equal to
// X.
func (s *Sharded) GetOrCreate(createFn func(ShardInfo) interface{}) interface{}

// Get retrieves any preexisting value associated with the current CPU. If
// there is no such value, nil is returned.
func (s *Sharded) Get() interface{}

// Do iterates over a snapshot of all elements stored in the Sharded, and calls
// fn once for each element.
//
// If more elements are created during the iteration itself, they may be
// visible to the iteration, but this is not guaranteed. For stronger
// guarantees, see DoLocked.
func (s *Sharded) Do(fn func(interface{}))

// DoLocked iterates over all the elements stored in the Sharded, and calls fn
// once for each element.
//
// DoLocked will observe a consistent snapshot of the elements in the Sharded;
// any previous creations will complete before the iteration begins, and all
// subsequent creations will wait until the iteration ends.
func (s *Sharded) DoLocked(fn func(interface{}))

// ShardInfo contains information about a CPU core.
type ShardInfo struct {
  // ShardIndex is strictly less than any call to any prior call to SetMaxShards.
  ShardIndex int
}
```

## Evaluating the use-cases

Here, we evaluate the proposed API in light of the use-cases described above.

### Counters

A counter API can be fairly easily built on top of `percpu.Sharded`.
Specifically, it would offer two methods `IncrementBy(int64)`, and `Sum() int64`.
The former would only allow positive increments (if required, clients can build
negative increments by composing two counters of additions and subtractions).

The implementation of `IncrementBy`, would call `GetOrCreate`, passing a
function that returned an `*int64`. To avoid false sharing between cache lines,
it would probably return it as an interior pointer into a struct with
appropriate padding. Once the pointer is retrieved from `GetOrCreate`, the
function would then use `atomic.AddInt64` on that pointer with the value passed
to `IncrementBy`.

The implementation of `Sum` would call `Do` to retrieve a snapshot of all
previously created values, then sum up their values using `atomic.LoadInt64`.

If the application is managing many long-lived counters, then one possible
optimization would be to implement the `Counter` type in terms of a
`counterBatch` (which logically encapsulates `N` independent counters). This can
drastically limit the padding required to fix false sharing between cache lines.

### Read-write locks

It is a little tricky to implement a drop-in replacement for `sync.RWMutex` on
top of `percpu.Sharded`. Naively, one could imagine a sharded lock composed of
many internal `sync.RWMutex` instances. Calling `RLock()` on the aggregate lock
would grab a single `sync.RWMutex` instance using `GetOrCreate` and then call
`RLock()` on that instance. Unfortunately, because there is no state passed
between `RLock()` and `RUnlock()` (something we should probably consider fixing
for Go 2), we cannot implement `RUnlock()` efficiently, as the `percpu.Sharded`
might have migrated to a different shard and therefore we've lost the
association to the original `RLock()`.

That said, since such a sharded lock would be considerably more memory-hungry
than a normal `sync.RWMutex`, callers should only replace truly contended
mutexes with a sharded lock, so requiring them to make minor API changes should
not be too onerous (particularly for mutexes, which should always be private
implementation details, and therefore not cross API boundaries). In particular,
one could have `RLock()` on the sharded lock return a `RLockHandle` type, which
has a `RUnlock()` method. This `RLockHandle` could keep an internal pointer to
the `sync.RWMutex` that was initially chosen, and it can then `RUnlock()` that
specific instance.

It's worth noting that it's also possible to drastically change the standard
library's `sync.RWMutex` implementation itself to be scalable by default using
`percpu.Sharded`; this is why the implementation sketch below is careful not not
use the `sync` package to avoid circular dependencies. See Facebook's
[SharedMutex](https://github.com/facebook/folly/blob/a440441d2c6ba08b91ce3a320a61cf0f120fe7f3/folly/SharedMutex.h#L148)
class to get a sense of how this could be done. However, that requires
significant research and deserves a proposal of its own.

### RPC clients

It's straightforward to use `percpu.Sharded` to implement a sharded RPC client.

This is a case where its likely that the default implementation will continue to
be unsharded, and a program will need to explicitly say something like
`grpc.Dial("some-server", grpc.ShardedClient(4))` (where the "4" might come from
an application flag). This kind of client-contrallable sharding is one place
where the `SetMaxShards` API can be useful.

### Order-independent accumulators

This can be implemented using `percpu.Sharded`. For instance, a writer would
call `GetOrCreate` to retrieve a shard-local buffer, they would acquire a lock,
and insert the element into the buffer. If the buffer became full, they would
flush it downstream.

A watchdog goroutine could walk the buffers periodically using `AppendAll`, and
flush partially-full buffers to ensure that elements are flushed fairly
promptly. If it finds no elements to flush, it could start incrementing a
counter of "useless" scans, and stop scanning after it reaches a threshold. If a
writer is enqueuing the first element in a buffer, and it sees the counter over
the threshold, it could reset the counter, and wake the watchdog.

## Sketch of Implementation

What follows is a rough sketch of an implementation of `percpu.Sharded`. This is
to show that this is implementable, and to give some context to the discussion
of performance below.

First, a sketch of an implementation for `percpu.sharder`, an internal helper
type for `percpu.Sharded`.

```go
const (
  defaultUserDefinedMaxShards = 32
)

type sharder struct {
  maxShards int32
}

func (s *sharder) SetMaxShards(maxShards int) {
  if maxShards < 1 {
    panic("maxShards < 1")
  }
  atomic.StoreInt32(&s.maxShards, roundDownToPowerOf2(int32(maxShards)))
}

func (s *sharder) userDefinedMaxShards() int32 {
  s := atomic.LoadInt32(&s.maxShards)
  if s == 0 {
    return defaultUserDefinedMaxShards
  }
  return s
}

func (s *sharder) shardInfo() ShardInfo {
  shardId := runtime_getShardIndex()

  // If we're in race mode, then all bets are off. Half the time, randomize the
  // shardId completely, the rest of the time, use shardId 0.
  //
  // If we're in a test but not in race mode, then we want an implementation
  // that keeps cache contention to a minimum so benchmarks work properly, but
  // we still want to flush out any assumption of a stable mapping to shardId.
  // So half the time, we double the id. This catches fewer problems than what
  // we get in race mode, but it should still catch one class of issue (clients
  // assuming that two sequential calls to Get() will return the same value).
  if raceEnabled {
    rnd := runtime_fastRand()
    if rnd%2 == 0 {
      shardId = 0
    } else {
      shardId += rnd / 2
    }
  } else if testing {
    if runtime_fastRand()%2 == 0 {
      shardId *= 2
    }
  }

  shardId &= runtimeDefinedMaxShards()-1
  shardId &= userDefinedMaxShards()-1

  return ShardInfo{ShardIndex: shardId}
}

func runtimeDefinedMaxShards() int32 {
  max := runtime_getMaxShards()
  if (testing || raceEnabled) && max < 4 {
    max = 4
  }
  return max
}

// Implemented in the runtime, should effectively be
// roundUpToPowerOf2(min(GOMAXPROCS, NumCPU)).
// (maybe caching that periodically in the P).
func runtime_getMaxShards() int32 {
  return 4
}

// Implemented in the runtime, should effectively be the result of the getcpu
// syscall, or similar. The returned index should densified if possible (i.e.
// if binary is locked to cores 2 and 4), they should return 0 and 1
// respectively, not 2 and 4.
//
// Densification can be best-effort, and done with a process-wide mapping table
// maintained by sysmon periodically.
//
// Does not have to be bounded by runtime_getMaxShards(), or indeed by
// anything.
func runtime_getShardIndex() int32 {
  return 0
}

// Implemented in the runtime. Only technically needs an implementation for
// raceEnabled and tests. Should be scalable (e.g. using a per-P seed and
// state).
func runtime_fastRand() int32 {
  return 0
}
```

Next, a sketch of `percpu.Sharded` itself.

```go
type Sharded struct {
  sharder

  lock uintptr
  data atomic.Value // *shardedData
  typ  unsafe.Pointer
}

func (s *Sharded) loadData() *shardedData {
  return s.data.Load().(*shardedData)
}

func (s *Sharded) getFastPath(createFn func(ShardInfo) interface{}) (out interface{}) {
  shardInfo := s.shardInfo()

  curData := s.loadData()
  if curData == nil || shardInfo.ShardIndex >= len(curData.elems) {
    if createFn == nil {
      return nil
    }
    return s.getSlowPath(shardInfo, createFn)
  }

  existing := curData.load(shardInfo.ShardIndex)
  if existing == nil {
    if createFn == nil {
      return nil
    }
    return s.getSlowPath(shardInfo, createFn)
  }

  outp := (*ifaceWords)(unsafe.Pointer(&out))
  outp.typ = s.typ
  outp.data = existing
  return
}

func (s *Sharded) getSlowPath(shardInfo ShardInfo, createFn func(ShardInfo) interface{}) (out interface{}) {
  runtime_lock(&s.lock)
  defer runtime_unlock(&s.lock)

  curData := s.loadData()
  if curData == nil || shardInfo.ShardIndex >= len(curData.elems) {
    curData = allocShardedData(curData, shardInfo)
    s.data.Store(curData)
  }

  existing := curData.load(shardInfo.ShardIndex)
  if existing != nil {
    outp := (*ifaceWords)(unsafe.Pointer(&out))
    outp.typ = s.typ
    outp.data = existing
    return
  }

  newElem := createFn(shardInfo)
  if newElem == nil {
    panic("createFn returned nil value")
  }

  newElemP := *(*ifaceWords)(unsafe.Pointer(&newElem))

  // If this is the first call to createFn, then stash the type-pointer for
  // later verification.
  //
  // Otherwise, verify its the same as the previous.
  if s.typ == nil {
    s.typ = newElemP.typ
  } else if s.typ != newElemP.typ {
    panic("percpu: GetOrCreate was called with function that returned inconsistently typed value")
  }

  // Store back the new value.
  curData.store(shardInfo.ShardIndex, newElemP.val)

  // Return it.
  outp := (*ifaceWords)(unsafe.Pointer(&out))
  outp.typ = s.typ
  outp.data = newElemP.val
}

func (s *Sharded) loadData() *shardedData {
  return s.data.Load().(*shardedData)
}

func (s *Sharded) GetOrCreate(createFn func(ShardInfo) interface{}) interface{} {
  if createFn == nil {
    panic("createFn nil")
  }
  return s.getFastPath(createFn)
}

func (s *Sharded) Get() interface{} {
  return s.getFastPath(nil)
}

func (s *Sharded) Do(fn func(interface{})) {
  curData := s.loadData()
  if curData == nil {
    return nil
  }

  for i := range curData.elems {
    elem := curData.load(i)
    if elem == nil {
      continue
    }

    var next interface{}
    nextP := (*ifaceWords)(unsafe.Pointer(&next))
    nextP.typ = s.typ
    nextP.val = elem

    fn(next)
  }

  return elems
}

func (s *Sharded) DoLocked(fn func(interface{})) {
  runtime_lock(&s.lock)
  defer runtime_unlock(&s.lock)
  s.Do(fn)
}

type shardedData struct {
  elems []unsafe.Pointer
}
```

## Performance

### `percpu.sharder`

As presented, calling `shardInfo` on a `percpu.sharder` makes two calls to the
runtime, and does a single atomic load.

However, both of the calls to the runtime would be satisfied with stale values.
So, an obvious avenue of optimization is to squeeze these two pieces of
information (effectively "current shard", and "max shards") into a single word,
and cache it on the `P` when first calling the `shardInfo` API. To accommodate
changes in the underlying values, a `P` can store a timestamp when it last
computed these values, and clear the cache when the value is older than `X` and
the `P` is in the process of switching goroutines.

This means that effectively, `shardInfo` will consist of 2 atomic loads, and a
little bit of math on the resulting values.

### `percpu.Sharded`

In the get-for-current-shard path, `percpu.Sharded` will call `shardInfo`, and
then perform 2 atomic loads (to retrieve the list of elements and to retrieve
the specific element for the current shard, respectively). If either of these
loads fails, it might fall back to a much-slower slow path. In the fast path,
there's no allocation.

In the get-all path, `percpu.Sharded` will perform a single atomic followed by a
`O(n)` atomic loads, proportional to the number of elements stored in the
`percpu.Sharded`. It will not allocate.


# Discussion

## Garbage collection of stale values in `percpu.Sharded`

With the given API, if `GOMAXPROCS` is temporarily increased (or the CPUs
assigned to the given program), and then decreased to its original value, a
`percpu.Sharded` might have allocated additional elements to satisfy the
additional CPUs. These additional elements would not be eligible for garbage
collection, as the `percpu.Sharded` would retain an internal reference.

First, its worth noting that we cannot unilaterally shrink the number of
elements stored in a `percpu.Sharded`, because this might affect program
correctness. For instance, this could result in counters losing values, or in
breaking the invariants of sharded locks.

The presented solution just sidesteps this problem by defaulting to a fairly low
value of `MaxShards`. This can be overridden by the user with explicit action
(though the runtime has the freedom to bound the number more strictly than the
user's value, e.g. to limit the size of internal data-structures to reasonable
levels.).

One thing to keep in mind, clients who require garbage collection of stale
values can build this on top of `percpu.Sharded`. For instance, one could
imagine a design where clients would maintain a counter recording each use. A
watchdog goroutine can then scan the elements and if a particular value has not
been used for some period of time, swap in a `nil` pointer, and then gracefully
tear down the value (potentially transferring the logical data encapsulated to
other elements in the `percpu.Sharded`).

Requiring clients to implement their own GC in this way seems kinda gross, but
on the other hand, its unclear to me how to generically solve this problem
without knowledge of the client use-case. One could imagine some sort of
reference-counting design, but again, without knowing the semantics of the
use-case, its hard to know if its safe to clear the reference to the type.

Also, for a performance-oriented type, like `percpu.Sharded`, it seems
unfortunate to add unnecessary synchronization to the fast path of the type (and
I don't see how to implement something in this direction without adding
synchronization).

## Why is `ShardInfo` a struct and not just an int?

This is mostly to retain the ability to extend the API in a compatible manner.
One concrete avenue is to add additional details to allow clients to optimize
their code for the NUMA architecture of the machine. For instance, for a sharded
buffering scheme (i.e. the "Order-independent accumulator" above), it might make
sense to have multiple levels of buffering in play, with another level at the
NUMA-node layer.

## Is `ShardInfo.ShardIndex` returning an id for the CPU, or the `P` executing the goroutine?

This is left unspecified, but the name of the package seems to imply the former.
In practice, I think we want a combination.

That is to say, we would prefer that a program running on a 2-core machine with
`GOMAXPROCS` set to 100 should use 2 shards, not 100. On the other hand, we
would also prefer that a program running on a 100-core machine with `GOMAXPROCS`
set to 2 should also use 2 shards, not 100.

This ideal state should be achievable on systems that provide reasonable APIs to
retrieve the id of the current CPU.

That said, any implementation effort would likely start with a simple portable
implementation which uses the id of the local `P`. This will allow us to get a
sense of the performance of the type, and to serve as a fallback implementation
for platforms where the necessary APIs are either not available, or require
privileged execution.

## Is it a good idea for `percpu.Sharded` to behave differently during tests?

This is a good question; I am not certain of the answer here. I am confident
that during race mode, we should definitely randomize the behaviour of
`percpu.Sharded` significantly (and the implementation sketch above does that).
However, for tests, the answer seems less clear to me.

As presented, the implementation sketch above randomizes the value by flipping
randomly between two values for every CPU. That seems like it will catch bugs
where the client assumes that sequential calls to `Get`/`GetOrCreate` will return
the same values. That amount of randomness seems warranted to me, though I'd
understand if folks would prefer to avoid it in favor of keeping non-test code
and test code behaving identically.

On a more mundane note: I'm not entirely sure if this is implementable with
zero-cost. One fairly efficient strategy would be an internal package that
exposes an "IsTesting bool", which is set by the `testing` package and read by
the `percpu` package. But ideally, this could be optimized away at compile time;
I don't believe we have any mechanism to do this now.

## Should we expose `ShardInfo.ShardIndex` at all?

I think so. Even if we don't, clients can retrieve an effectively equivalent
value by just incrementing an atomic integer inside the `createFn` passed to
`GetOrCreate`. For pre-allocated use-cases (e.g. see the Facebook `SharedMutex`
linked above), it seems important to let clients index into pre-allocated
memory.

## Should we expose both of Get and GetOrCreate?

We could define `GetOrCreate` to behave like `Get` if the passed `createFn` is
nil. This is less API (and might be more efficient, until mid-stack inlining
works), but seems less semantically clean to me. It seems better to just have
clients say what they want explicitly.

## Should we expose both of Do and DoLocked?

If we had to choose one of those, then I would say we should expose `Do`. This
is because it is the higher performance, minimal-synchronization version, and
`DoLocked` can be implemented on top. That said, I do think we should just
provide both. The implementation is simple, and implementing it on top feels
odd.

Of the 4 use-cases presented above, 2 would probably use `Do` (counters and
order-independent accumulators), and 2 would probably use `DoLocked` (read-write
locks, and RPC clients (for the latter, probably just for implementing
`Close()`)).

## Naming

I'm not particularly wedded to any of the names in the API sketch above, so I'm
happy to see it changed to whatever people prefer.

# Backwards compatibility

The API presented above is straightforward to implement without any runtime
support; in particular, this could be implemented as a thin wrapper around a
`sync.Once`. This will not effectively reduce contention, but it would still be
a correct implementation. It's probably a good idea to implement such a shim,
and put it in the `x/sync` repo, with appropriate build tags and type-aliases to
allow clients to immediately start using the new type.
