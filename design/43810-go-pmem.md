### Proposal: Add support for Persistent Memory in Go

Authors: Jerrin Shaji George, Mohit Verma, Rajesh Venkatasubramanian, Pratap Subrahmanyam

Last updated: January 20, 2021

Discussion at https://golang.org/issue/43810.

## Abstract

Persistent memory is a new memory technology that allows byte-addressability at
DRAM-like access speed and provides disk-like persistence. Operating systems
such as Linux and Windows server already support persistent memory and the
hardware is available commercially in servers. More details on this technology
can be found at [pmem.io](https://pmem.io).

This is a proposal to add native support for programming persistent memory in
Go. A detailed design of our approach to add this support is described in our
2020 USENIX ATC paper [go-pmem](https://www.usenix.org/system/files/atc20-george.pdf).
An implementation of the above design based on Go 1.15 release is available
[here](http://github.com/jerrinsg/go-pmem).

## Background

Persistent Memory is a new type of random-access memory that offers persistence
and byte-level addressability at DRAM-like access speed. Operating systems
provide the capability to mmap this memory to an application's virtual address
space. Applications can then use this mmap'd region just like memory. Durable
data updates made to persistent memory can be retrieved by an application even
after a crash/restart.

Applications using persistent memory benefit in a number of ways. Since durable
data updates made to persistent memory is non-volatile, applications no longer
need to marshal data between DRAM and storage devices. A significant portion
of application code that used to do this heavy-lifting can now be retired.
Another big advantage is a significant reduction in application startup times on
restart. This is because applications no longer need to transform their at-rest
data into an in-memory representation. For example, commercial applications like
SAP HANA report a [12x improvement](https://cloud.google.com/blog/topics/partners/available-first-on-google-cloud-intel-optane-dc-persistent-memory)
in startup times using persistent memory.

This proposal is to provide first-class native support for Persistent memory in
Go. Our design modifies Go 1.15 to introduce a garbage collected persistent
heap. We also instrument the Go compiler to introduce semantics that enables
transactional updates to persistent-memory datastructures. We call our modified
Go suite as *go-pmem*. A Redis database developed with using go-pmem offers more
than 5x throughput compared to Redis running on NVMe SSD.

## Proposal

We propose adding native support for programming persistent memory in Go. This
requires making the following features available in Go:

1. Support persistent memory allocations
2. Garbage collection of persistent memory heap objects
3. Support modifying persistent memory datastructures in a crash-consistent
manner
4. Enable applications to recover following a crash/restart
5. Provide applications a mechanism to retrieve back durably stored data in
persistent memory

To support these features, we extended the Go runtime and added a new SSA pass
in our implementation as discussed below.

## Rationale

There exists libraries such as Intel [PMDK](https://pmem.io/pmdk/) that provides
C and C++ developers support for persistent memory programming. Other
programming languages such as Java and Python are exploring ways to enable
efficient access to persistent memory. E.g.,
* Java - https://bugs.openjdk.java.net/browse/JDK-8207851
* Python - https://pynvm.readthedocs.io/en/v0.3.1/

But no language provide a native persistent memory programming support. We
believe this is an impediment to widespread adoption to this technology. This
proposal attempts to remedy this problem by making Go the first language to
completely support persistent memory.

### Why language change?

The C libraries expose a programming model significantly different (and complex)
than existing programming models. In particular, memory management becomes
difficult with libraries. A missed "free" call can lead to memory leaks and
persistent memory leaks become permanent and do not vanish after application
restarts. In a language with a managed runtime such as Go, providing visibility
to its garbage collector into a memory region managed by a library becomes very
difficult.
Identifying and instrumenting stores to persistent memory data to provide
transactional semantics also requires programming language change.
In our implementation experience, the Go runtime and compiler was easily
amenable to add these capabilities.

## Compatibility

Our current changes preserve the Go 1.x future compatibility promise. It does
not break compatibility for programs not using any persistent memory features
exposed by go-pmem.

Having said that, we acknowledge a few downsides with our current design:

1. We store memory allocator metadata in persistent memory. When a program
restarts, we use these metadata to recreate the program state of the memory
allocator and garbage collector. As with any persistent data, we need to
maintain the data layout of this metadata. Any changes to Go memory allocator's
datastructure layout can break backward compatibility with our persistent
metadata. This can be fixed by developing an offline tool which can do this
data format conversion or by embedding this capability in go-pmem.

2. We currently add three new Go keywords : pnew, pmake and txn. pnew, pmake are
persistent memory allocation APIs and txn is used to demarcate transactional
updates to data structures. We have explored a few ways to avoid making these
language changes as described below.

a) pnew/pmake

The availability of generics support in a future version of Go can help us avoid
introducing these memory allocation functions. They can instead be functions
exported by a Go package.

```
func Pnew[T any](_ T) *T {
    ptr := runtime.pnew(T)
    return ptr
}

func Pmake[T any](_ T, len, cap int) []T {
    slc := runtime.pmake([]T, len, cap)
    return slc
}
```

`runtime.pnew` and `runtime.pmake` would be special functions that can take a
type as arguments. They then behave very similar to the `new()` and `make()`
APIs but allocate objects in the persistent memory heap.

b) txn

An alternative approach would be to define a new Go pragma that identifies a
transactional block of code. It could have the following syntax:

```
//go:transactional
{
    // transactional data updates
}
```

Another alternative approach can be to use closures with the help of a few
runtime and compiler changes. For example, something like this can work:

```
runtime.Txn() foo()
```

Internally, this would be similar to how Go compiler instruments stores when
mrace/msan flag is passed while compiling. In this case, writes inside
function foo() will be instrumented and foo() will be executed transactionally.

See this playground [code](https://go2goplay.golang.org/p/WRUTZ9dr5W3) for a
complete code listing with our proposed alternatives.

## Implementation

Our implementation is based on a fork of Go source code version Go 1.15. Our
implementation adds three new keywords to Go: pnew, pmake and txn. pnew and
pmake are persistent memory allocation APIs and txn is used to demarcate a
block of transaction data update to persistent memory.

1. pnew - `func pnew(Type) *Type`

Just like `new`, `pnew` creates a zero-value object of the `Type` argument in
persistent memory and returns a pointer to this object.


2. pmake - `func pmake(t Type, size ...IntType) Type`

The `pmake` API is used to create a slice in persistent memory. The semantics of
`pmake` is exactly the same as `make` in Go. We don't yet support creating maps
and channels in persistent memory.

3. txn

```
txn() {
    // transaction data updates
}
```

Our code changes to Go can be broken down into two parts - runtime changes and
compiler-SSA changes.

### Runtime changes

We extend the Go runtime to support persistent memory allocations. The garbage
collector now works across both the persistent and volatile heaps. The `mspan`
datastructure has one additional data member `memtype` to distinguish between
persistent and volatile spans. We also extend various memory allocator
datastructures in mcache, mcentral, and mheap to store metadata related to
persistent memory and volatile memory separately. The garbage collector now
understands these different span types and puts back garbage collected spans
in the appropriate datastructures depending on its `memtype`.

Persistent memory is managed in arenas that are a multiple of 64MB. Each
persistent memory arena has in its header section certain metadata that
facilitates heap recovery in case of application crash or restart. Two kinds of
metadata are stored:
* GC heap type bits - Garbage collector heap type bits set for any object in
this arena is copied as such to the metadata section to be restored on a
subsequent run of this application
* Span table - Captures metadata about each span in this arena that lets the
heap recovery code recreates these spans in the next run.

We added the following APIs in the runtime package to manage persistent memory:

1  `func PmemInit(fname string) (unsafe.Pointer, error)`

Used to initialize persistent memory. It takes the path to a persistent memory
file as input. It returns the application root pointer and an error value.

2  `func SetRoot(addr unsafe.Pointer) (err Error)`

Used to set the application root pointer. All application data in persistent
memory hangs off this root pointer.

3  `func GetRoot() (addr unsafe.Pointer)`

Returns the root pointer set using SetRoot().

4  `func InPmem(addr unsafe.Pointer) bool`

Returns whether `addr` points to data in persistent memory or not.

5. `func PersistRange(addr unsafe.Pointer, len uintptr)`

Flushes all the cachelines in the address range (addr, addr+len) to ensure
any data updates to this memory range is persistently stored.

### Compiler-SSA changes

1.  We change the parser to recognize three new language tokens - `pnew`,
`pmake`, and `txn`.

2. We add a new SSA pass to instrument all stores to persistent memory. Because
data in persistent memory survives crashes, updates to data in persistent memory
have to be transactional.

3.  The Go AST and SSA was modified so that users can now demarcate a block of
Go code as transactional by encapsulating them within a `txn()` block.
    -  To do this, we add a new keyword to Go called `txn`.
    -  A new SSA pass would then look for stores(`OpStore`/`OpMove`/`OpZero`) to
       persistent memory locations within this `txn()` block, and store the old
       data at this location in an [undo Log](https://github.com/vmware/go-pmem-transaction/blob/master/transaction/undoTx.go).
       This would be done before making the actual memory update.


### go-pmem packages

We have developed two packages that makes it easier to use go-pmem to write
persistent memory applications.

1. [pmem](https://github.com/vmware/go-pmem-transaction/tree/master/pmem) package

It provides a simple `Init(fname string) bool` API that applications can use to
initialize persistent memory. It returns if this is a first-time initialization
or not. In case it is not the first-time initialization, any incomplete
transactions are reverted as well.

pmem package also provides named objects where names can be associated with
objects in persistent memory. Users can create and retrieve these objects using
string names.

2. [transaction](https://github.com/vmware/go-pmem-transaction/tree/master/transaction) package

Transaction package provides the implementation of undo logging that is used
by go-pmem to enable crash-consistent data updates.


### Example Code

Below is a simple linked list application written using go-pmem

```
// A simple linked list application. On the first invocation, it creates a
// persistent memory pointer named "dbRoot" which holds pointers to the first
//  and last element in the linked list. On each run, a new node is added to
// the linked list and all contents of the list are printed.

package main

import (
    "github.com/vmware/go-pmem-transaction/pmem"
    "github.com/vmware/go-pmem-transaction/transaction"
)

const (
    // Used to identify a successful initialization of the root object
    magic = 0x1B2E8BFF7BFBD154
)

// Structure of each node in the linked list
type entry struct {
    id   int
    next *entry
}

// The root object that stores pointers to the elements in the linked list
type root struct {
    magic int
    head  *entry
    tail  *entry
}

// A function that populates the contents of the root object transactionally
func populateRoot(rptr *root) {
    txn() {
        rptr.magic = magic
        rptr.head = nil
        rptr.tail = nil
    }
}

// Adds a node to the linked list and updates the tail (and head if empty)
func addNode(rptr *root) {
    entry := pnew(entry)
    txn() {
        entry.id = rand.Intn(100)

        if rptr.head == nil {
            rptr.head = entry
        } else {
            rptr.tail.next = entry
        }
        rptr.tail = entry
    }
}

func main() {
    firstInit := pmem.Init("database")
    var rptr *root
    if firstInit {
        // Create a new named object called dbRoot and point it to rptr
        rptr = (*root)(pmem.New("dbRoot", rptr))
        populateRoot(rptr)
    } else {
        // Retrieve the named object dbRoot
        rptr = (*root)(pmem.Get("dbRoot", rptr))
        if rptr.magic != magic {
            // An object named dbRoot exists, but its initialization did not
            // complete previously.
            populateRoot(rptr)
        }
    }
    addNode(rptr)    // Add a new node in the linked list
}
```

