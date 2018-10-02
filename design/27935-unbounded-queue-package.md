# Proposal: Built in support for high performance unbounded queue

Author: Christian Petrin.

Last updated: October 2, 2018

Discussion at: https://github.com/golang/go/issues/27935

Design document at https://github.com/golang/proposal/blob/master/design/27935-unbounded-queue-package.md


## Abstract
I propose to add a new package, "container/queue", to the standard library to
support an in-memory, unbounded, general purpose queue implementation.

[Queues](https://en.wikipedia.org/wiki/Queue_(abstract_data_type)) in computer
science is a very old, well established and well known concept, yet Go doesn't
provide a specialized, safe to use, performant and issue free unbounded queue
implementation.

Buffered channels provide an excellent option to be used as a queue, but
buffered channels are bounded and so doesn't scale to support very large data
sets. The same applies for the standard [ring
package](https://github.com/golang/go/tree/master/src/container/ring).

The standard [list
package](https://github.com/golang/go/tree/master/src/container/list) can be
used as the underlying data structure for building unbounded queues, but the
performance yielded by this linked list based implementation [is not
optimal](https://github.com/christianrpetrin/queue-tests/blob/master/bench_queue.md).

Implementing a queue using slices as suggested
[here](https://stackoverflow.com/a/26863706) is a feasible approach, but the
performance yielded by this implementation can be abysmal in some [high load
scenarios](https://github.com/christianrpetrin/queue-tests/blob/master/bench_queue.md).

## Background
Queues that grows dynamically has many uses. As an example, I'm working on a
logging system called [CloudLogger](https://github.com/cloud-logger/docs) that
sends all logged data to external logging management systems, such as
[Stackdriver](https://cloud.google.com/stackdriver/) and
[Cloudwatch](https://aws.amazon.com/cloudwatch/). External logging systems
typically [rate limit](https://en.wikipedia.org/wiki/Rate_limiting) how much
data their service will accept for a given account and time frame. So in a
scenario where the hosting application is logging more data than the logging
management system will accept at a given moment, CloudLogger has to queue the
extra logs and send them to the logging management system at a pace the system
will accept. As there's no telling how much data will have to be queued as it
depends on the current traffic, an unbounded, dynamically growing queue is the
ideal data structure to be used. Buffered channels in this scenario is not ideal
as they have a limit on how much data they will accept, and once that limit has
been reached, the producers (routines adding to the channel) start to block,
making the adding to the channel operation an "eventual" synchronous process. A
fully asynchronous operation in this scenario is highly desirable as logging
data should not slow down significantly the hosting application.

Above problem is a problem that, potentially, every system that calls another
system faces. And in the [cloud](https://en.wikipedia.org/wiki/Cloud_computing)
and [microservices](https://en.wikipedia.org/wiki/Microservices) era, this is an
extremely common scenario.

Due to the lack of support for built in unbounded queues in Go, Go engineers are
left to either:
1) Research and use external packages, or
2) Build their own queue implementation

Both approaches are riddled with pitfalls.

Using external packages, specially in enterprise level software, requires a lot
of care as using external, potentially untested and hard to understand code can
have unwanted consequences. This problem is made much worse by the fact that,
currently, there's no well established and disseminated open source Go queue
implementation according to [this stackoverflow
discussion](https://stackoverflow.com/questions/2818852/is-there-a-queue-implementation),
[this github search for Go
queues](https://github.com/search?l=Go&q=go+queue&type=Repositories) and
[Awesome Go](https://awesome-go.com/).

Building a queue, on the other hand, might sound like a compelling argument, but
building efficient, high performant, bug free unbounded queue is a hard job that
requires a pretty solid computer science foundation as well a good deal of time
to research different design approaches, test different implementations, make
sure the code is bug and memory leak free, etc.

In the end what Go engineers have been doing up to this point is building their
own queues, which are for the most part inefficient and can have disastrous, yet
hidden performance and memory issues. As examples of poorly designed and/or
implemented queues, the approaches suggested
[here](https://stackoverflow.com/a/26863706) and
[here](https://stackoverflow.com/a/11757161) (among many others), requires
linear copy of the internal slice for resizing purposes. Some implementations
also has memory issues such as an ever expanding internal slice and memory
leaks.

## Proposal
I propose to add a new package, "container/queue", to the standard library to
support in-memory unbounded queues. The [proposed queue
implementation](https://github.com/christianrpetrin/queue-tests/blob/master/queueimpl7/queueimpl7.go)
offers [excellent performance and very low memory
consumption](https://github.com/christianrpetrin/queue-tests/blob/master/bench_queue.md)
when comparing it to three promising open source implementations
([gammazero](https://github.com/gammazero/deque),
[phf](https://github.com/phf/go-queue) and
[juju](https://github.com/juju/utils/tree/master/deque)); to use Go channels as
queue; the standard list package as a queue as well as six other experimental
queue implementations.

The [proposed queue
implementation](https://github.com/christianrpetrin/queue-tests/blob/master/queueimpl7/queueimpl7.go)
offers the most balanced approach to performance given different loads, being
significantly faster and still uses less memory than every other queue
implementation in the
[tests](https://github.com/christianrpetrin/queue-tests/blob/master/benchmark_test.go).

The closest data structure Go has to offer for building dynamically growing
queues for large data sets is the [standard list
package](https://github.com/golang/go/tree/master/src/container/list). When
comparing the proposed solution to [using the list package as an unbounded
queue](https://github.com/christianrpetrin/queue-tests/blob/master/benchmark_test.go)
(refer to "BenchmarkList"), the proposed solution is consistently faster than
using the list package as a queue as well as displaying a much lower memory
footprint.


### Reasoning
There's [two well accepted
approaches](https://en.wikipedia.org/wiki/Queue_(abstract_data_type)#Queue_implementation)
to implementing queues when in comes to the queue underlying data structure:

1) Using linked list
2) Using array

Linked list as the underlying data structure for an unbounded queue has the
advantage of scaling efficiently when the underlying data structure needs to
grow to accommodate more values. This is due to the fact that the existing
elements doesn't need to be repositioned or copied around when the queue needs
to grow.

However, there's a few concerns with this approach:
1) The use of prev/next pointers for each value requires a good deal of extra
   memory
2) Due to the fact that each "node" in the linked list can be allocated far away
   from the previous one, navigating through the list can be slow due to its bad
   [memory
   locality](https://www.cs.cornell.edu/courses/cs3110/2012sp/lectures/lec25-locality/lec25.html)
   properties
3) Adding new values always require new memory allocations and pointers being
   set, hindering performance

On the other hand, using a slice as the underlying data structure for unbounded
queues has the advantage of very good [memory
locality](https://www.cs.cornell.edu/courses/cs3110/2012sp/lectures/lec25-locality/lec25.html),
making retrieval of values faster when comparing to linked lists. Also an "alloc
more than needed right now" approach can easily be implemented with slices.

However, when the slice needs to expand to accommodate new values, a [well
adopted
strategy](https://en.wikipedia.org/wiki/Dynamic_array#Geometric_expansion_and_amortized_cost)
is to allocate a new, larger slice, copy over all elements from the previous
slice into the new one and use the new one to add the new elements.

The problem with this approach is the obvious need to copy all the values from
the older, small slice, into the new one, yielding a poor performance when the
amount of values that need copying are fairly large.

Another potential problem is a theoretical lower limit on how much data they can
hold as slices, like arrays, have to allocate its specified positions in
sequential memory addresses, so the maximum number of items the queue would ever
be able to hold is the maximum size a slice can be allocated on that particular
system at any given moment. Due to modern memory management techniques such as
[virtual memory](https://en.wikipedia.org/wiki/Virtual_memory) and
[paging](https://en.wikipedia.org/wiki/Paging), this is a very hard scenario to
corroborate thru practical testing.

Nonetheless, this approach doesn't scale well with large data sets.

Having said that, there's a third, newer approach to implementing unbounded
queues: use fixed size linked slices as the underlying data structure.

The fixed size linked slices approach is a hybrid between the first two,
providing good memory locality arrays have alongside the efficient growing
mechanism linked lists offer. It is also not limited on the maximum size a slice
can be allocated, being able to hold and deal efficiently with a theoretical
much larger amount of data than pure slice based implementations.


## Rationale
### Research
[A first implementation](https://github.com/cloud-spin/queue) of the new design
was built.

The benchmark tests showed the new design was very promising, so I decided to
research about other possible queue designs and implementations with the goal to
improve the first design and implementation.

As part of the research to identify the best possible queue designs and
implementations, I implemented and probed below queue implementations.

- [queueimpl1](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl1/queueimpl1.go):
  custom queue implementation that stores the values in a simple slice. Pop
  removes the first slice element. This is a slice based implementation that
  tests [this](https://stackoverflow.com/a/26863706) suggestion.
- [queueimpl2](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl2/queueimpl2.go):
  custom queue implementation that stores the values in a simple slice. Pop
  moves the current position to next one instead of removing the first element.
  This is a slice based implementation similarly to queueimpl1, but differs in
  the fact that it uses pointers to point to the current first element in the
  queue instead of removing the first element.
- [queueimpl3](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl3/queueimpl3.go):
  custom queue implementation that stores the values in linked slices. This
  implementation tests the queue performance when controlling the length and
  current positions in the slices using the builtin len and append functions.
- [queueimpl4](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl4/queueimpl4.go):
  custom queue implementation that stores the values in linked arrays. This
  implementation tests the queue performance when controlling the length and
  current positions in the arrays using simple local variables instead of the
  built in len and append functions (i.e. it uses arrays instead of slices).
- [queueimpl5](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl5/queueimpl5.go):
  custom queue implementation that stores the values in linked slices. This
  implementation tests the queue performance when storing the "next" pointer as
  part of the values slice instead of having it as a separate "next" field. The
  next element is stored in the last position of the internal slices, which is a
  reserved position.
- [queueimpl6](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl6/queueimpl6.go):
  custom queue implementation that stores the values in linked slices. This
  implementation tests the queue performance when performing lazy creation of
  the first slice as well as starting with an slice of size 1 and doubling its
  size up to 128, everytime a new linked slice needs to be created.
- [queueimpl7](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl7/queueimpl7.go):
  custom queue implementation that stores the values in linked slices. This
  implementation tests the queue performance when performing lazy creation of
  the internal slice as well as starting with a 1-sized slice, allowing it to
  grow up to 16 by using the built in append function. Subsequent slices are
  created with 128 fixed size.

Also as part of the research, I investigated and probed below open source queue
implementations as well.
- [phf](https://github.com/phf/go-queue): this is a slice, ring based queue
  implementation. Interesting to note the author did a pretty good job
  researching and probing other queue implementations as well.
- [gammazero](https://github.com/gammazero/deque): the deque implemented in this
  package is also a slice, ring based queue implementation.
- [juju](https://github.com/juju/utils/tree/master/deque): the deque implemented
  in this package uses a linked list based approach, similarly to other
  experimental implementations in this package such as
  [queueimpl3](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl3/queueimpl3.go).
  The biggest difference between this implementation and the other experimental
  ones is the fact that this queue uses the standard list package as the linked
  list. The standard list package implements a doubly linked list, while the
  experimental implementations implements their own singly linked list.

The [standard list
package](https://github.com/golang/go/blob/master/src/container/list/list.go) as
well as buffered channels were probed as well.


### Benchmark Results

Initialization time only<br/> Performance<br/>
![ns/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-0-items-perf.jpg?raw=true
"Benchmark tests") <br/>

Memory<br/>
![B/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-0-items-mem.jpg?raw=true
"Benchmark tests")

Add and remove 1k items<br/> Performance<br/>
![ns/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-1k-items-perf.jpg?raw=true
"Benchmark tests")

Memory<br/>
![B/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-1k-items-mem.jpg?raw=true
"Benchmark tests") <br/>

Add and remove 100k items<br/> Performance<br/>
![ns/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-100k-items-perf.jpg?raw=true
"Benchmark tests")

Memory<br/>
![B/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-100k-items-mem.jpg?raw=true
"Benchmark tests") <br/>

Aggregated Results<br/> Performance<br/>
![ns/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-line-perf.jpg?raw=true
"Benchmark tests")

Memory<br/>
![B/op](https://github.com/christianrpetrin/queue-tests/blob/master/images/queue-line-mem.jpg?raw=true
"Benchmark tests") <br/>

Detailed, curated results can be found
[here](https://docs.google.com/spreadsheets/d/e/2PACX-1vRnCm7v51Eo5nq66NsGi8aQI6gL14XYJWqaeRJ78ZIWq1pRCtEZfsLD2FcI-gIpUhhTPnkzqDte_SDB/pubhtml?gid=668319604&single=true)

Aggregated, curated results can be found
[here](https://docs.google.com/spreadsheets/d/e/2PACX-1vRnCm7v51Eo5nq66NsGi8aQI6gL14XYJWqaeRJ78ZIWq1pRCtEZfsLD2FcI-gIpUhhTPnkzqDte_SDB/pubhtml?gid=582031751&single=true)
<br/>

Given above results,
[queueimpl7](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl7/queueimpl7.go),
henceforth just "impl7", proved to be the most balanced implementation, being
either faster or very competitive in all test scenarios from a performance and
memory perspective.

Refer [here](https://github.com/christianrpetrin/queue-tests) for more details
about the tests.

The benchmark tests can be found
[here](https://github.com/christianrpetrin/queue-tests/blob/master/benchmark_test.go).


#### Impl7 Design and Implementation
[Impl7](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl7/queueimpl7.go)
was the result of the observation that some slice based implementations such as
[queueimpl1](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl1/queueimpl1.go)
and
[queueimpl2](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl2/queueimpl2.go)
offers phenomenal performance when the queue is used with small data sets.

For instance, comparing
[queueimpl3](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl3/queueimpl3.go)
(very simple linked slice implementation) with
[queueimpl1](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl1/queueimpl1.go)
(very simple slice based implementation), the results at adding 0 (init time
only), 1 and 10 items are very favorable for impl1, from a performance and
memory perspective.

```
benchstat rawresults/bench-impl1.txt rawresults/bench-impl3.txt
name       old time/op    new time/op    delta
/0-4         6.83ns ± 3%  472.53ns ± 7%   +6821.99%  (p=0.000 n=20+17)
/1-4         48.1ns ± 6%   492.4ns ± 5%    +924.66%  (p=0.000 n=20+20)
/10-4         532ns ± 5%     695ns ± 8%     +30.57%  (p=0.000 n=20+20)
/100-4       3.19µs ± 2%    2.50µs ± 4%     -21.69%  (p=0.000 n=18+19)
/1000-4      24.5µs ± 3%    23.6µs ± 2%      -3.33%  (p=0.000 n=19+19)
/10000-4      322µs ± 4%     238µs ± 1%     -26.02%  (p=0.000 n=19+18)
/100000-4    15.8ms ±10%     3.3ms ±13%     -79.32%  (p=0.000 n=20+20)

name       old alloc/op   new alloc/op   delta
/0-4          0.00B       2080.00B ± 0%       +Inf%  (p=0.000 n=20+20)
/1-4          16.0B ± 0%   2080.0B ± 0%  +12900.00%  (p=0.000 n=20+20)
/10-4          568B ± 0%     2152B ± 0%    +278.87%  (p=0.000 n=20+20)
/100-4       4.36kB ± 0%    2.87kB ± 0%     -34.13%  (p=0.000 n=20+20)
/1000-4      40.7kB ± 0%    24.6kB ± 0%     -39.54%  (p=0.000 n=20+20)
/10000-4      746kB ± 0%     244kB ± 0%     -67.27%  (p=0.000 n=20+20)
/100000-4    10.0MB ± 0%     2.4MB ± 0%     -75.85%  (p=0.000 n=15+20)

name       old allocs/op  new allocs/op  delta
/0-4           0.00           2.00 ± 0%       +Inf%  (p=0.000 n=20+20)
/1-4           1.00 ± 0%      2.00 ± 0%    +100.00%  (p=0.000 n=20+20)
/10-4          14.0 ± 0%      11.0 ± 0%     -21.43%  (p=0.000 n=20+20)
/100-4          108 ± 0%       101 ± 0%      -6.48%  (p=0.000 n=20+20)
/1000-4       1.01k ± 0%     1.01k ± 0%      +0.50%  (p=0.000 n=20+20)
/10000-4      10.0k ± 0%     10.2k ± 0%      +1.35%  (p=0.000 n=20+20)
/100000-4      100k ± 0%      102k ± 0%      +1.53%  (p=0.000 n=20+20)
```

Impl7 is a hybrid experiment between using a simple slice based queue
implementation for small data sets and the fixed size linked slice approach for
large data sets, which is an approach that scales really well, offering really
good performance for small and large data sets.

The implementation starts by lazily creating the first slice to hold the first
values added to the queue.

```go
const (
    // firstSliceSize holds the size of the first slice.
    firstSliceSize = 1

    // maxFirstSliceSize holds the maximum size of the first slice.
    maxFirstSliceSize = 16

    // maxInternalSliceSize holds the maximum size of each internal slice.
    maxInternalSliceSize = 128
)

...

// Push adds a value to the queue.
// The complexity is amortized O(1).
func (q *Queueimpl7) Push(v interface{}) {
    if q.head == nil {
        h := newNode(firstSliceSize) // Returns a 1-sized slice.
        q.head = h
        q.tail = h
        q.lastSliceSize = maxFirstSliceSize
    } else if len(q.tail.v) >= q.lastSliceSize {
        n := newNode(maxInternalSliceSize) // Returns a 128-sized slice.
        q.tail.n = n
        q.tail = n
        q.lastSliceSize = maxInternalSliceSize
    }

    q.tail.v = append(q.tail.v, v)
    q.len++
}

...

// newNode returns an initialized node.
func newNode(capacity int) *Node {
    return &Node{
        v: make([]interface{}, 0, capacity),
    }
}
```

The very first created slice is created with capacity 1. The implementation
allows the builtin append function to dynamically resize the slice up to 16
(maxFirstSliceSize) positions. After that it reverts to creating fixed size 128
position slices, which offers the best performance for data sets above 16 items.

16 items was chosen as this seems to provide the best balanced performance for
small and large data sets according to the [array size benchmark
tests](https://github.com/christianrpetrin/queue-tests/blob/master/bench_slice_size.md).
Above 16 items, growing the slice means allocating a new, larger one and copying
all 16 elements from the previous slice into the new one. The append function
phenomenal performance can only compensate for the added copying of elements if
the data set is very small, no more than 8 items in the benchmark tests. For
above 8 items, the fixed size slice approach is consistently faster and uses
less memory, where 128 sized slices are allocated and linked together when the
data structure needs to scale to accommodate new values.

Why 16? Why not 15 or 14?

The builtin append function, as of "go1.11 darwin/amd64", seems to double the
slice size every time it  needs to allocate a new one.

```go
ts := make([]int, 0, 1)

ts = append(ts, 1)
fmt.Println(cap(ts)) // Slice has 1 item; output: 1

ts = append(ts, 1)
fmt.Println(cap(ts)) // Slice has 2 items; output: 2

ts = append(ts, 1)
fmt.Println(cap(ts)) // Slice has 3 items; output: 4

ts = append(ts, 1)
ts = append(ts, 1)
fmt.Println(cap(ts)) // Slice has 5 items; output: 8

ts = append(ts, 1)
ts = append(ts, 1)
ts = append(ts, 1)
ts = append(ts, 1)
fmt.Println(cap(ts)) // Slice has 9 items; output: 16
```

Since the append function will resize the slice from 8 to 16 positions, it makes
sense to use all 16 already allocated positions before switching to the fixed
size slices approach.

#### Design Considerations
[Impl7](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl7/queueimpl7.go)
uses linked slices as its underlying data structure.

The reasonale for the choice comes from two main obervations of slice based
queues:
1) When the queue needs to expand to accomodate new values, a new, larger slice
   needs to be allocated and used
2) Allocating and managing large slices is expensive, especially in an
   overloaded system with little avaialable physical memory

To help clarify the scenario, below is what happens when a slice based queue
that already holds, say 1bi items, needs to expand to accommodate a new item.

Slice based implementation
- Allocate a new, [twice the
  size](https://en.wikipedia.org/wiki/Dynamic_array#Geometric_expansion_and_amortized_cost)
  of the previous allocated one, say 2 billion positions slice
- Copy over all 1 billion items from the previous slice into the new one
- Add the new value into the first unused position in the new array, position
  1000000001.

The same scenario for impl7 plays out like below.

Impl7
- Allocate a new 128 size slice
- Set the next pointer
- Add the value into the first position of the new array, position 0

Impl7 never copies data around, but slice based ones do, and if the data set is
large, it doesn't matter how fast the copying algorithm is. The copying has to
be done and will take some time.

The decision to use linked slices was also the result of the observation that
slices goes to great length to provide predictive, indexed positions. A hash
table, for instance, absolutely need this property, but not a queue. So impl7
completely gives up this property and focus on what really matters: add to end,
retrieve from head. No copying around and repositioning of elements is needed
for that. So when a slice goes to great length to provide that functionality,
the whole work of allocating new arrays, copying data around is all wasted work.
None of that is necessary. And this work costs dearly for large data sets as
observed in the
[tests](https://github.com/christianrpetrin/queue-tests/blob/master/bench_queue.md).


#### Impl7 Benchmark Results
Below compares impl7 with a few selected implementations.

The tests name are formatted given below.
- Benchmark/N-4: benchmark a queue implementation where N denotes the number of
  items added and removed to/from the queue; 4 means the number of CPU cores in
  the host machine.

Examples:
- Benchmark/0-4: benchmark the queue by creating a new instance of it. This only
  test initialization time.
- Benchmark/100-4: benchmark the queue by creating a new instance of it and
  adding and removing 100 items to/from the queue.

---

Standard list used as a FIFO queue vs impl7.
```
benchstat rawresults/bench-list.txt rawresults/bench-impl7.txt
name       old time/op    new time/op    delta
/0-4         34.9ns ± 1%     1.2ns ± 3%   -96.64%  (p=0.000 n=19+20)
/1-4         77.0ns ± 1%    68.3ns ± 1%   -11.21%  (p=0.000 n=20+20)
/10-4         574ns ± 0%     578ns ± 0%    +0.59%  (p=0.000 n=18+20)
/100-4       5.94µs ± 1%    3.07µs ± 0%   -48.28%  (p=0.000 n=19+18)
/1000-4      56.0µs ± 1%    25.8µs ± 1%   -53.92%  (p=0.000 n=20+20)
/10000-4      618µs ± 1%     260µs ± 1%   -57.99%  (p=0.000 n=20+18)
/100000-4    13.1ms ± 6%     3.1ms ± 3%   -76.50%  (p=0.000 n=20+20)

name       old alloc/op   new alloc/op   delta
/0-4          48.0B ± 0%      0.0B       -100.00%  (p=0.000 n=20+20)
/1-4          96.0B ± 0%     48.0B ± 0%   -50.00%  (p=0.000 n=20+20)
/10-4          600B ± 0%      600B ± 0%      ~     (all equal)
/100-4       5.64kB ± 0%    3.40kB ± 0%   -39.72%  (p=0.000 n=20+20)
/1000-4      56.0kB ± 0%    25.2kB ± 0%   -55.10%  (p=0.000 n=20+20)
/10000-4      560kB ± 0%     243kB ± 0%   -56.65%  (p=0.000 n=20+20)
/100000-4    5.60MB ± 0%    2.43MB ± 0%   -56.66%  (p=0.000 n=18+20)

name       old allocs/op  new allocs/op  delta
/0-4           1.00 ± 0%      0.00       -100.00%  (p=0.000 n=20+20)
/1-4           2.00 ± 0%      2.00 ± 0%      ~     (all equal)
/10-4          20.0 ± 0%      15.0 ± 0%   -25.00%  (p=0.000 n=20+20)
/100-4          200 ± 0%       107 ± 0%   -46.50%  (p=0.000 n=20+20)
/1000-4       2.00k ± 0%     1.02k ± 0%   -48.95%  (p=0.000 n=20+20)
/10000-4      20.0k ± 0%     10.2k ± 0%   -49.20%  (p=0.000 n=20+20)
/100000-4      200k ± 0%      102k ± 0%   -49.22%  (p=0.000 n=20+20)
```
Impl7 is:
- Up to ~29x faster (1.2ns vs 34.9ns) than list package for init time (0 items)
- Up to ~4x faster (3.1ms vs 13.1ms) than list package for 100k items
- Uses ~1/2 memory (2.43MB vs 5.60MB) than list package for 100k items

---

[impl1](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl1/queueimpl1.go)
(simple slice based queue implementaion) vs impl7.
```
benchstat rawresults/bench-impl1.txt rawresults/bench-impl7.txt
name       old time/op    new time/op    delta
/0-4         6.83ns ± 3%    1.18ns ± 3%   -82.79%  (p=0.000 n=20+20)
/1-4         48.1ns ± 6%    68.3ns ± 1%   +42.23%  (p=0.000 n=20+20)
/10-4         532ns ± 5%     578ns ± 0%    +8.55%  (p=0.000 n=20+20)
/100-4       3.19µs ± 2%    3.07µs ± 0%    -3.74%  (p=0.000 n=18+18)
/1000-4      24.5µs ± 3%    25.8µs ± 1%    +5.51%  (p=0.000 n=19+20)
/10000-4      322µs ± 4%     260µs ± 1%   -19.23%  (p=0.000 n=19+18)
/100000-4    15.8ms ±10%     3.1ms ± 3%   -80.60%  (p=0.000 n=20+20)

name       old alloc/op   new alloc/op   delta
/0-4          0.00B          0.00B           ~     (all equal)
/1-4          16.0B ± 0%     48.0B ± 0%  +200.00%  (p=0.000 n=20+20)
/10-4          568B ± 0%      600B ± 0%    +5.63%  (p=0.000 n=20+20)
/100-4       4.36kB ± 0%    3.40kB ± 0%   -22.02%  (p=0.000 n=20+20)
/1000-4      40.7kB ± 0%    25.2kB ± 0%   -38.25%  (p=0.000 n=20+20)
/10000-4      746kB ± 0%     243kB ± 0%   -67.47%  (p=0.000 n=20+20)
/100000-4    10.0MB ± 0%     2.4MB ± 0%   -75.84%  (p=0.000 n=15+20)

name       old allocs/op  new allocs/op  delta
/0-4           0.00           0.00           ~     (all equal)
/1-4           1.00 ± 0%      2.00 ± 0%  +100.00%  (p=0.000 n=20+20)
/10-4          14.0 ± 0%      15.0 ± 0%    +7.14%  (p=0.000 n=20+20)
/100-4          108 ± 0%       107 ± 0%    -0.93%  (p=0.000 n=20+20)
/1000-4       1.01k ± 0%     1.02k ± 0%    +1.09%  (p=0.000 n=20+20)
/10000-4      10.0k ± 0%     10.2k ± 0%    +1.39%  (p=0.000 n=20+20)
/100000-4      100k ± 0%      102k ± 0%    +1.54%  (p=0.000 n=20+20)
```
Impl7 is:
- Up to ~5x faster (1.18ns vs 6.83ns) than impl1 for init time (0 items)
- Up to ~5x faster (3.1ms vs 15.8ms) than impl1 for 100k items
- Uses ~1/4 memory (2.4MB vs 10MB) than impl1 for 100k items

It's important to note that the performance and memory gains for impl7 is
exponential like the larger the data set is due to the fact slice based
implementations doesn't scale well, [paying a higher and higher
price](https://en.wikipedia.org/wiki/Dynamic_array#Geometric_expansion_and_amortized_cost),
performance and memory wise, every time it needs to scale to accommodate an ever
expanding data set.

---

[phf](https://github.com/phf/go-queue) (slice, ring based FIFO queue
implementation) vs impl7.
```
benchstat rawresults/bench-phf.txt rawresults/bench-impl7.txt
name       old time/op    new time/op    delta
/0-4         28.1ns ± 1%     1.2ns ± 3%   -95.83%  (p=0.000 n=20+20)
/1-4         42.5ns ± 1%    68.3ns ± 1%   +60.80%  (p=0.000 n=20+20)
/10-4         681ns ± 1%     578ns ± 0%   -15.11%  (p=0.000 n=18+20)
/100-4       4.55µs ± 1%    3.07µs ± 0%   -32.45%  (p=0.000 n=19+18)
/1000-4      35.5µs ± 1%    25.8µs ± 1%   -27.32%  (p=0.000 n=18+20)
/10000-4      349µs ± 2%     260µs ± 1%   -25.67%  (p=0.000 n=20+18)
/100000-4    11.7ms ±11%     3.1ms ± 3%   -73.77%  (p=0.000 n=20+20)

name       old alloc/op   new alloc/op   delta
/0-4          16.0B ± 0%      0.0B       -100.00%  (p=0.000 n=20+20)
/1-4          16.0B ± 0%     48.0B ± 0%  +200.00%  (p=0.000 n=20+20)
/10-4          696B ± 0%      600B ± 0%   -13.79%  (p=0.000 n=20+20)
/100-4       6.79kB ± 0%    3.40kB ± 0%   -49.94%  (p=0.000 n=20+20)
/1000-4      57.0kB ± 0%    25.2kB ± 0%   -55.86%  (p=0.000 n=20+20)
/10000-4      473kB ± 0%     243kB ± 0%   -48.68%  (p=0.000 n=20+20)
/100000-4    7.09MB ± 0%    2.43MB ± 0%   -65.77%  (p=0.000 n=18+20)

name       old allocs/op  new allocs/op  delta
/0-4           1.00 ± 0%      0.00       -100.00%  (p=0.000 n=20+20)
/1-4           1.00 ± 0%      2.00 ± 0%  +100.00%  (p=0.000 n=20+20)
/10-4          15.0 ± 0%      15.0 ± 0%      ~     (all equal)
/100-4          111 ± 0%       107 ± 0%    -3.60%  (p=0.000 n=20+20)
/1000-4       1.02k ± 0%     1.02k ± 0%    +0.39%  (p=0.000 n=20+20)
/10000-4      10.0k ± 0%     10.2k ± 0%    +1.38%  (p=0.000 n=20+20)
/100000-4      100k ± 0%      102k ± 0%    +1.54%  (p=0.000 n=20+20)
```
Impl7 is:
- Up to ~23x faster (1.2ns vs 28.1ns) than phf for init time (0 items)
- Up to ~3x faster (3.1ms vs 11.7ms) than phf for 100k items
- Uses ~1/2 memory (2.43MB vs 7.09MB) than phf for 100k items

---

Buffered channel vs impl7.
```
benchstat rawresults/bench-channel.txt rawresults/bench-impl7.txt
name       old time/op    new time/op    delta
/0-4         30.2ns ± 1%     1.2ns ± 3%   -96.12%  (p=0.000 n=19+20)
/1-4         87.6ns ± 1%    68.3ns ± 1%   -22.00%  (p=0.000 n=19+20)
/10-4         704ns ± 1%     578ns ± 0%   -17.90%  (p=0.000 n=20+20)
/100-4       6.78µs ± 1%    3.07µs ± 0%   -54.70%  (p=0.000 n=20+18)
/1000-4      67.3µs ± 1%    25.8µs ± 1%   -61.65%  (p=0.000 n=20+20)
/10000-4      672µs ± 1%     260µs ± 1%   -61.36%  (p=0.000 n=19+18)
/100000-4    6.76ms ± 1%    3.07ms ± 3%   -54.61%  (p=0.000 n=19+20)

name       old alloc/op   new alloc/op   delta
/0-4          96.0B ± 0%      0.0B       -100.00%  (p=0.000 n=20+20)
/1-4           112B ± 0%       48B ± 0%   -57.14%  (p=0.000 n=20+20)
/10-4          248B ± 0%      600B ± 0%  +141.94%  (p=0.000 n=20+20)
/100-4       1.69kB ± 0%    3.40kB ± 0%  +101.42%  (p=0.000 n=20+20)
/1000-4      16.2kB ± 0%    25.2kB ± 0%   +55.46%  (p=0.000 n=20+20)
/10000-4      162kB ± 0%     243kB ± 0%   +49.93%  (p=0.000 n=20+20)
/100000-4    1.60MB ± 0%    2.43MB ± 0%   +51.43%  (p=0.000 n=16+20)

name       old allocs/op  new allocs/op  delta
/0-4           1.00 ± 0%      0.00       -100.00%  (p=0.000 n=20+20)
/1-4           1.00 ± 0%      2.00 ± 0%  +100.00%  (p=0.000 n=20+20)
/10-4          10.0 ± 0%      15.0 ± 0%   +50.00%  (p=0.000 n=20+20)
/100-4          100 ± 0%       107 ± 0%    +7.00%  (p=0.000 n=20+20)
/1000-4       1.00k ± 0%     1.02k ± 0%    +2.10%  (p=0.000 n=20+20)
/10000-4      10.0k ± 0%     10.2k ± 0%    +1.61%  (p=0.000 n=20+20)
/100000-4      100k ± 0%      102k ± 0%    +1.57%  (p=0.000 n=20+20)
```
Impl7 is:
- Up to ~25x faster (1.2ns vs 30.2ns) than channels for init time (0 items)
- Up to ~2x faster (3.07ms vs 6.76ms) than channels for 100k items
- Uses ~50% MORE memory (2.43MB vs 1.60MB) than channels for 100k items

Above is not really a fair comparison as standard buffered channels doesn't
scale (at all) and they are meant for routine synchronization. Nonetheless, they
can and make for an excellent bounded FIFO queue option. Still, impl7 is
consistently faster than channels across the board, but uses considerably more
memory than channels.

---

Given its excellent performance under all scenarios, the hybrid approach impl7
seems to be the ideal candidate for a high performance, low memory footprint
general purpose FIFO queue.

For above reasons, I propose to port impl7 to the standard library.

All raw benchmark results can be found
[here](https://github.com/christianrpetrin/queue-tests/tree/master/rawresults).


### Internal Slice Size
[Impl7](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl7/queueimpl7.go)
uses linked slices as its underlying data structure.

The size of the internal slice does influence performance and memory consumption
significantly.

According to the [internal slice size bench
tests](https://github.com/christianrpetrin/queue-tests/blob/master/queueimpl7/benchmark_test.go),
larger internal slice sizes yields better performance and lower memory
footprint. However, the gains diminishes dramatically as the slice size
increases.

Below are a few interesting results from the benchmark tests.

```
BenchmarkMaxSubsequentSliceSize/1-4                20000         76836 ns/op       53967 B/op       2752 allocs/op
BenchmarkMaxSubsequentSliceSize/2-4                30000         59811 ns/op       40015 B/op       1880 allocs/op
BenchmarkMaxSubsequentSliceSize/4-4                30000         42925 ns/op       33039 B/op       1444 allocs/op
BenchmarkMaxSubsequentSliceSize/8-4                50000         36946 ns/op       29551 B/op       1226 allocs/op
BenchmarkMaxSubsequentSliceSize/16-4               50000         30597 ns/op       27951 B/op       1118 allocs/op
BenchmarkMaxSubsequentSliceSize/32-4               50000         28273 ns/op       27343 B/op       1064 allocs/op
BenchmarkMaxSubsequentSliceSize/64-4               50000         26969 ns/op       26895 B/op       1036 allocs/op
BenchmarkMaxSubsequentSliceSize/128-4              50000         27316 ns/op       26671 B/op       1022 allocs/op
BenchmarkMaxSubsequentSliceSize/256-4              50000         26221 ns/op       28623 B/op       1016 allocs/op
BenchmarkMaxSubsequentSliceSize/512-4              50000         25882 ns/op       28559 B/op       1012 allocs/op
BenchmarkMaxSubsequentSliceSize/1024-4             50000         25674 ns/op       28527 B/op       1010 allocs/op
```

Given the fact that larger internal slices also means potentially more unused
memory in some scenarios, 128 seems to be the perfect balance between
performance and worst case scenario for memory footprint.

Full results can be found
[here](https://github.com/christianrpetrin/queue-tests/blob/master/bench_slice_size.md).


### API
[Impl7](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl7/queueimpl7.go)
implements below API methods.

| Operation | Method |
| --- | --- |
| Add | func (q *Queueimpl7) Push(v interface{}) |
| Remove | func (q *Queueimpl7) Pop() (interface{}, bool) |
| Size | func (q *Queueimpl7) Len() int |
| Return First | func (q *Queueimpl7) Front() (interface{}, bool) |

As nil values are considered valid queue values, similarly to the map data
structure, "Front" and "Pop" returns a second bool parameter to indicate whether
the returned value is valid and whether the queue is empty or not.

The resonale for above method names and signatures are the need to keep
compatibility with existing Go data structures such as the
[list](https://github.com/golang/go/blob/master/src/container/list/list.go),
[ring](https://github.com/golang/go/blob/master/src/container/ring/ring.go) and
[heap](https://github.com/golang/go/blob/master/src/container/heap/heap.go)
packages.

Below are the method names used by the existing list, ring and heap Go data
structures, as well as the new proposed queue.

| Operation | list | ring | heap | queue |
| --- | --- | --- | --- | --- |
| Add | PushFront/PushBack | Link | Push | Push |
| Remove | Remove | Unlink | Pop | Pop |
| Size | Len | Len | - | Len |
| Return First | Front | - | - | Front |

For comparison purposes, below are the method names for
[C++](http://www.cplusplus.com/reference/queue/queue/),
[Java](https://docs.oracle.com/javase/7/docs/api/java/util/Queue.html) and
[C#](https://docs.microsoft.com/en-us/dotnet/api/system.collections.generic.queue-1?view=netframework-4.7.2)
for their queue implementation.

| Operation | C++ | Java | C# |
| --- | --- | --- | --- |
| Add | push | add/offer | Enqueue |
| Remove | pop | remove/poll | Dequeue |
| Size | size | - | Count |
| Return First | front | peek | Peek |


### Range Support
Just like the current container data strucutures such as
[list](https://github.com/golang/go/blob/master/src/container/list/list.go),
[ring](https://github.com/golang/go/blob/master/src/container/ring/ring.go) and
[heap](https://github.com/golang/go/tree/master/src/container/heap), Impl7
doesn't support the range keyword for navigation.

The API offers two ways to iterate over the queue items.

Either use "Pop" to retrieve the first current element and the second bool
parameter to check for an empty queue.

```go
for v, ok := q.Pop(); ok; v, ok = q.Pop() {
    // Do something with v
}
```

Or use "Len" and "Pop" to check for an empty queue and retrieve the first
current element.
```go
for q.Len() > 0 {
    v, _ := q.Pop()
    // Do something with v
}
```

### Data Type
Just like the current container data strucutures such as the
[list](https://github.com/golang/go/blob/master/src/container/list/list.go),
[ring](https://github.com/golang/go/blob/master/src/container/ring/ring.go) and
[heap](https://github.com/golang/go/tree/master/src/container/heap), Impl7 only
supported data type is "interface{}", making it usable by virtually any Go
types.

It is possible to implement support for specialized data types such as int,
float, bool, etc, but that would require duplicating the Push/Pop methods to
accept the different data types, much like
strconv.ParseBool/ParseFloat/ParseInt/etc. However, with the impending release
of generics, we should probrably wait as generics would solve this problem
nicely.



### Safe for Concurrent Use
[Impl7](https://github.com/christianrpetrin/queue-tests/tree/master/queueimpl7/queueimpl7.go)
is not safe for concurrent use by default. The rationale for this decision is
below.

1) Not all users will need a safe for concurrent use queue implementation
2) Executing routine synchronization is expensive, causing performance to drop
   very significantly
3) Getting impl7 to be safe for concurrent use is actually very simple

Below is an example of a safe for concurrent use queue implementation that uses
impl7 as its underlying queue.

```go
package tests

import (
    "fmt"
    "sync"
    "testing"

    "github.com/christianrpetrin/queue-tests/queueimpl7"
)

type SafeQueue struct {
    q Queueimpl7
    m sync.Mutex
}

func (s *SafeQueue) Len() int {
    s.m.Lock()
    defer s.m.Unlock()

    return s.q.Len()
}

func (s *SafeQueue) Push(v interface{}) {
    s.m.Lock()
    defer s.m.Unlock()

    s.q.Push(v)
}

func (s *SafeQueue) Pop() (interface{}, bool) {
    s.m.Lock()
    defer s.m.Unlock()

    return s.q.Pop()
}

func (s *SafeQueue) Front() (interface{}, bool) {
    s.m.Lock()
    defer s.m.Unlock()

    return s.q.Front()
}

func TestSafeQueue(t *testing.T) {
    var q SafeQueue

    q.Push(1)
    q.Push(2)

    for v, ok := q.Pop(); ok; v, ok = q.Pop() {
        fmt.Println(v)
   }

   // Output:
   // 1
   // 2
}
```


### Drawbacks
The biggest drawback of the proposed implementation is the potentially extra
allocated but not used memory in its head and tail slices.

This scenario realizes when exactly 17 items are added to the queue, causing the
creation of a full sized internal slice of 128 positions. Initially only the
first element in this new slice is used to store the added value. All the other
127 elements are already allocated, but not used.

```go
// Assuming a 128 internal sized slice.
q := queueimpl7.New()

// Push 16 items to fill the first dynamic slice (sized 16).
for i := 1; i <= 16; i++ {
   q.Push(i)
}
// Push 1 extra item that causes the creation of a new 128 sized slice to store this value.
q.Push(17)

// Pops the first 16 items to release the first slice (sized 16).
for i := 1; i <= 16; i++ {
   q.Pop()
}

// As unsafe.Sizeof (https://golang.org/pkg/unsafe/#Sizeof) doesn't consider the length of slices,
// we need to manually calculate the memory used by the internal slices.
var internalSliceType interface{}
fmt.Println(fmt.Sprintf("%d bytes", unsafe.Sizeof(q)+(unsafe.Sizeof(internalSliceType) /* bytes per slice position */ *127 /* head slice unused positions */)))

// Output for a 64bit system (Intel(R) Core(TM) i5-7267U CPU @ 3.10GHz): 2040 bytes
```

The worst case scenario realizes when exactly 145 items are added to the queue
and 143 items are removed. This causes the queue struct to hold a 128-sized
slice as its head slice, but only the last element is actually used. Similarly,
the queue struct will hold a separate 128-sized slice as its tail slice, but
only the first position in that slice is being used.

```go
// Assuming a 128 internal sized slice.
q := queueimpl7.New()

// Push 16 items to fill the first dynamic slice (sized 16).
for i := 1; i <= 16; i++ {
   q.Push(i)
}

// Push an additional 128 items to fill the first full sized slice (sized 128).
for i := 1; i <= 128; i++ {
   q.Push(i)
}

// Push 1 extra item that causes the creation of a new 128 sized slice to store this value,
// adding a total of 145 items to the queue.
q.Push(1)

// Pops the first 143 items to release the first dynamic slice (sized 16) and
// 127 items from the first full sized slice (sized 128).
for i := 1; i <= 143; i++ {
   q.Pop()
}

// As unsafe.Sizeof (https://golang.org/pkg/unsafe/#Sizeof) doesn't consider the length of slices,
// we need to manually calculate the memory used by the internal slices.
var internalSliceType interface{}
fmt.Println(fmt.Sprintf("%d bytes", unsafe.Sizeof(q)+(unsafe.Sizeof(internalSliceType) /* bytes per slice position */ *(127 /* head slice unused positions */ +127 /* tail slice unused positions */))))

// Output for a 64bit system (Intel(R) Core(TM) i5-7267U CPU @ 3.10GHz): 4072 bytes
```

Above code was run on Go version "go1.11 darwin/amd64".


## Open Questions/Issues
Should this be a deque (double-ended queue) implementation instead? The deque
could be used as a stack as well, but it would make more sense to have a queue
and stack implementations (like most mainstream languages have) instead of a
deque that can be used as a stack (confusing). Stack is a very important
computer science data structure as well and so I believe Go should have a
specialized implementation for it as well (given the specialized implementation
offers real value to the users and not just a "nice" named interface and
methods).

Should "Pop" and "Front" return only the value instead of the value and a second
bool parameter (which indicates whether the queue is empty or not)? The
implication of the change is adding nil values wouldn't be valid anymore so
"Pop" and "Front" would return nil when the queue is empty. Panic should be
avoided in libraries.

The memory footprint for a 128 sized internal slice causes, in the worst case
scenario, a 2040 bytes of memory allocated (on a 64bit system) but not used.
Switching to 64 means roughly half the memory would be used with a slight ~2.89%
performance drop (252813ns vs 260137ns). The extra memory footprint is not worth
the extra performance gain is a very good point to make. Should we change this
value to 64 or maybe make it configurable?

Should we also provide a safe for concurrent use implementation? A specialized
implementation that would rely on atomic operations to update its internal
indices and length could offer a much better performance when comparing to a
similar implementation that relies on a mutex.

With the impending release of generics, should we wait to release the new queue
package once the new generics framework is released?

Should we implement support for the range keyword for the new queue? It could be
done in a generic way so other data structures could also benefit from this
feature. For now, IMO, this is a topic for another proposal/discussion.



## Summary
I propose to add a new package, "container/queue", to the standard library to
support an in-memory, unbounded, general purpose queue implementation.

I feel strongly this proposal should be accepted due to below reasons.

1) The proposed solution was well researched and probed, being dramatically and
   consistently faster than 6 other experimental queue implementations as well 3
   promising open source queue implementations as well the standard list package
   and buffered channels; it still consumes considerably less memory than every
   other queue implementation tested, except for buffered channels
2) The proposed solution uses a new, unique approach to building queues, yet its
   [implementation](https://github.com/christianrpetrin/queue-tests/blob/master/queueimpl7/queueimpl7.go)
   is clean and extremely simple. Both main methods, "Push" and "Pop", are
   composed of only 16 and 19 lines of code (total), respectively. The proposed
   implementation also have proper tests with 100% test coverage and should
   require minimal maintenance moving forward
3) I'll implement any changes the Go community feel are needed for the proposed
   solution to be worth of the standard library and the Go community
