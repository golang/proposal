# Proposal: Rules for passing pointers between Go and C

Author: Ian Lance Taylor
Last updated: October, 2015

Discussion at https://golang.org/issue/12416.

## Abstract

List specific rules for when it is safe to pass pointers between Go
and C using cgo.

## Background

Go programmers need to know the rules for how to use cgo safely to
share memory between Go and C.
When using cgo, there is memory allocated by Go and memory allocated
by C.
For this discussion, we define a *Go pointer* to be a pointer to Go
memory, and a *C pointer* to be a pointer to C memory.
The rules that need to be defined are when and how Go code can use C
pointers and C code can use Go pointers.

Note that for this discussion a Go pointer may be any pointer type,
including a pointer to a type defined in C.
Note that some Go values contain Go pointers implicitly, such as
strings, slices, maps, channels, and function values.

It is a generally accepted (but not actually documented) rule that Go
code can use C pointers, and they will work as well or as poorly as C
code holding C pointers.
So the only question is this: when can C code use Go pointers?

The de-facto rule for 1.4 is: you can pass any Go pointer to C.
C code may use it freely.
If C code stores the Go pointer in C memory then there must be a live
copy of the pointer in Go as well.
You can allocate Go memory in C code by calling the Go function
`_cgo_allocate`.

The de-facto rule for 1.5 adds restrictions.
You can still pass any Go pointer to C.
However, C code may not store a Go pointer in Go memory (C code can
still store a Go pointer in C memory, with the same restrictions as
in 1.4).
The `_cgo_allocate` function has been removed.

We do not want to document the 1.5 de-facto restrictions as the
permanent rules because they are somewhat confusing, they limit future
garbage collection choices, and in particular they prohibit any future
development of a moving garbage collector.

## Proposal

I propose that we permit Go code to pass Go pointers to C code, while
preserving the following invariant:

* The Go garbage collector must be aware of the location of all Go
  pointers, except for a known set of pointers that are temporarily
  *visible to C code*.
  The pointers visible to C code exist in an area that the garbage
  collector can not see, and the garbage collector may not modify or
  release them.

It is impossible to break this invariant in Go code that does not
import "unsafe" and does not call C.

I propose the following rules for passing pointers between Go and C,
while preserving this invariant:

1. Go code may pass a Go pointer to C provided that the Go memory to
  which it points does not contain any Go pointers.
  * The C code must not store any Go pointers in Go memory, even
    temporarily.
  * When passing a pointer to a field in a struct, the Go memory in
    question is the memory occupied by the field, not the entire
    struct.
  * When passing a pointer to an element in an array or slice, the Go
    memory in question is the entire array or the entire backing array
    of the slice.
  * Passing a Go pointer to C code means that that Go pointer is
    visible to C code; passing one Go pointer does not cause any
    other Go pointers to become visible.
  * The maximum number of Go pointers that can become visible to C
    code in a single function call is the number of arguments to the
    function.

2. C code may not keep a copy of a Go pointer after the call returns.
  * A Go pointer passed as an argument to C code is only visible to C
    code for the duration of the function call.

3. A Go function called by C code may not return a Go pointer.
  * A Go function called by C code may take C pointers as arguments,
    and it may store non-pointer or C pointer data through those
    pointers, but it may not store a Go pointer in memory pointed to
    by a C pointer.
  * A Go function called by C code may take a Go pointer as an
    argument, but it must preserve the property that the Go memory to
    which it points does not contain any Go pointers.
  * C code calling a Go function can not cause any additional Go
    pointers to become visible to C code.

4. Go code may not store a Go pointer in C memory.
  * C code may store a Go pointer in C memory subject to rule 2: it
    must stop storing the pointer before it returns to Go.

The purpose of these four rules is to preserve the above invariant and
to limit the number of Go pointers visible to C code at any one time.

### Examples

Go code can pass the address of an element of a byte slice to C, and C
code can use pointer arithmetic to access all the data in the slice,
and change it (the C code is of course responsible for doing its own
bounds checking).

Go code can pass a Go string to C.  With the current Go compilers it
will look like a two element struct.

Go code can pass the address of a struct to C, and C code can use the
data or change it.
Go code can pass the address of a struct that has pointer fields, but
those pointers must be nil or must be C pointers.

Go code can pass a non-nested Go func value into C, and the C code may
call a Go function passing the func value as an argument, but it must
not save the func value in C memory between calls, and it must not
call the func value directly.

A Go function called by C code may not return a string.

### Consequences

This proposal restricts the Go garbage collector: any Go pointer
passed to C code must be pinned for the duration of the C call.
By definition, since that memory block may not contain any Go
pointers, this will only pin a single block of memory.

Because C code can call back into Go code, and that Go code may need
to copy the stack, we can never pass a Go stack pointer into C code.
Any pointer passed into C code must be treated by the compiler as
escaping, even though the above rules mean that we know it will not
escape.
This is an additional cost to the already high cost of calling C code.

Although these rules are written in terms of cgo, they also apply to
SWIG, which uses cgo internally.

Similar rules may apply to the syscall package.  Individual functions
in the syscall package will have to declare what Go pointers are
permitted.  This particularly applies to Windows.

That completes the rules for sharing memory and the implementation
restrictions on Go code.

### Support

We turn now to helping programmers use these rules correctly.
There is little we can do on the C side.
Programmers will have to learn that C code may not store Go pointers
in Go memory, and may not keep copies of Go pointers after the
function returns.

We can help programmers on the Go side, by implementing restrictions
within the cgo program.
Let us assume that the C code and any unsafe Go code behaves perfectly.
We want to have a way to test that the Go code never breaks the
invariant.

We propose an expensive dynamic check that may be enabled upon
request, similar to the race detector.
The dynamic checker will be turned on via a new option to go build:
`-checkcgo`.
The dynamic checker will have the following effects:

* We will turn on the write barrier at all times.
  Whenever a pointer is written to memory, we will check whether the
  pointer is a Go pointer.
  If it is, we will check whether we are writing it to Go
  memory (including the heap, the stack, global variables).
  If we are not, we will report an error.

* We will change cgo to add code to check any pointer value passed to
  a C function.
  If the value points to memory containing a Go pointer, we will
  report an error.

* We will change cgo to add the same check to any pointer value passed
  to an exported Go function, except that the check will be done on
  function return rather than function entry.

* We will change cgo to check that any pointer returned by an exported
  Go function is not a Go pointer.

These rules taken together preserve the invariant.
It will be impossible to write a Go pointer to non-Go memory.
When passing a Go pointer to C, only that Go pointer will be made
visible to C.
The cgo check ensures that no other pointers are exposed.
Although the Go pointer may contain pointer to C memory, the write barrier
ensures that that C memory can not contain any Go pointers.
When C code calls a Go function, no additional Go pointers will become
visible to C.

We propose that we enable the above changes, other than the write
barrier, at all times.
These checks are reasonably cheap.

These checks should detect all violations of the invariant on the Go side.
It is still possible to violate the invariant on the C side.
There is little we can do about this (in the long run we could imagine
writing a Go specific memory sanitizer to catch errors.)

A particular unsafe area is C code that wants to hold on to Go func
and pointer values for future callbacks from C to Go.
This works today but is not permitted by the invariant.
It is hard to detect.
One safe approach is: Go code that wants to preserve funcs/pointers
stores them into a map indexed by an int.
Go code calls the C code, passing the int, which the C code may store
freely.
When the C code wants to call into Go, it passes the int to a Go
function that looks in the map and makes the call.
An explicit call is required to release the value from the map if it
is no longer needed, but that was already true before.

## Rationale

The garbage collector has more flexibility when it has complete
control over all Go pointers.
We want to preserve that flexibility as much as possible.

One simple rule would be to always prohibit passing Go pointers to C.
Unfortunately that breaks existing packages, like github.com/gonum/blas,
that pass slices of floats from Go to C for efficiency.
It also breaks the standard library, which passes the address of a
`C.struct_addrinfo` to `C.getaddrinfo`.
It would be possible to require all such code to change to allocate
their memory in C rather than Go, but it would make cgo considerably
harder to use.

This proposal is an attempt at the next simplest rule.
We permit passing Go pointers to C, but we limit their number, and
require that the garbage collector be aware of exactly which pointers
have been passed.
If a later garbage collector implements moving pointers, cgo will
introduce temporary pins for the duration of the C call.

Rules are necessary, but it's always useful to enforce the rules.
We can not enforce the rules in C code, but we can attempt to do so in
Go code.

If we adopt these rules, we can not change them later, except to
loosen them.
We can, however, change the enforcement mechanism, if we think of
better approaches.

## Compatibility

This rules are intended to extend the Go 1 compatibility guidelines to
the cgo interface.

## Implementation

The implementation of the rules requires adding documentation to the
cgo command.

The implementation of the enforcement mechanism requires changes to
the cgo tool and the go tool.

The goal is to get agreement on this proposal and to complete the work
before the 1.6 freeze date.

## Open issues

Can and should we provide library support for certain operations, like
passing a token for a Go value through C to Go functions called from
C?

Should there be a way for C code to allocate Go memory, where of
course the Go memory may not contain any Go pointers?
