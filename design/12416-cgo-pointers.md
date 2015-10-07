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
including a pointer to a type defined in C.  Note that some Go values
contain Go pointers implicitly, such as strings, slices, maps,
channels, and function values.

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
However, C code may not store a Go pointer into Go memory (C code can
still store a Go pointer into C memory, with the same restrictions as
in 1.4).
The `_cgo_allocate` function has been removed.

We do not want to document the 1.5 de-facto restrictions as the
permanent rules because they are somewhat confusing, they limit future
garbage collection choices, and in particular they prohibit any future
development of a moving garbage collector.

## Proposal

I propose the following rules:

* Go code may pass a Go pointer to C provided that the Go memory to
  which it points does not contain any Go pointers.
  * The rule must be preserved during C execution: the C code must not
    store any Go pointers into that memory.
  * When passing a pointer to a field in a struct, the Go memory in
    question is the memory occupied by the field, not the entire
    struct.
  * When passing a pointer to an element in an array or slice, the Go
    memory in question is the entire array or the entire backing array
    of the slice.

* C code may not keep a copy of a Go pointer after the call returns.

* If Go code passes a Go pointer to a C function, the C function must
  return.
  * While there are no documented time limits, a C function that simply
    blocks holding a Go pointer while other goroutines are running may
    eventually cause the program to run out of memory and fail.

* A Go function called by C code may not return a Go pointer.
  * A Go function called by C code may take C pointers as arguments,
    and it may store non-pointer or C pointer data through those
    pointers, but it may not store a Go pointer into memory pointed to
    by a C pointer.
  * A Go function called by C code may take a Go pointer as an
    argument, but it must preserve the property that the Go memory to
    which it points does not contain any Go pointers.

### Examples

Go code can pass the address of an element of a byte slice to C, and C
code can use pointer arithmetic to access all the data in the slice,
and change it.

Go code can pass a Go string to C, where it will look like a two
element struct.

Go code can pass the address of a struct to C, and C code can use the
data or change it.
Go code can pass the address of a struct that has pointer fields, but
those pointers must be nil or must be C pointers.

Go code can pass a Go func value into C, and the C code may call a Go
function passing the func value as an argument, but it must not save
the Go func value in C memory between calls.

A Go function called by C code may not return a string.

This proposal restricts the Go garbage collector: any Go pointer
passed to C code must be pinned for the duration of the C call.
By definition, since that memory block may not contain any pointers,
this will only pin a single block of memory.

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
Programmers will have to learn that they may not store Go pointers in
C even if the Go memory is still referenced, possibly transitively
through Go memory, from Go roots.

We can help programmers on the Go side, by implementing restrictions
within the cgo program.
We propose two different kinds of checks: a cheap static check that is
always enabled, and a more expensive dynamic check that may be enabled
upon request.
The intent is that if your cgo-using program crashes due to a memory
error, you can run the expensive dynamic check to make sure you are
passing memory safely to C.

The static check is a change to the cgo program: we propose modifying
cgo to prohibit any type conversion from a Go pointer type to a C
pointer type, except as a direct argument to a C function call.
Even within a direct function call, we prohibit type conversions if
the Go pointer type points to a type that itself contains pointers.

We can apply additional restrictions to a function labelled //export,
which may be called from C code.
Such a function must not return any Go pointer type.
It may not have any parameters that are Go pointer types.

The intent of these restrictions is to separate pointers by type: Go
pointers will have a Go type, and C pointers will have a C type.

The following example is OK because Go type `[]byte` does not itself
contain any pointers (that is, there are no pointers in the underlying
array), and type conversion is permitted in a direct function call:

    var b []byte
    C.memcpy(C.voidp(unsafe.Pointer(&b[0])), C.voidp(unsafe.Pointer(&b[10])), 10)

This is OK because `s` is a C type:

    var s *C.struct_addrinfo
    C.getaddrinfo(nil, C.Cstring("google.com"), nil, &s)

This is not OK, because it converts a Go pointer type to a C pointer type:

    var s C.struct_addrinfo
    s.ai_canonname = C.charp(unsafe.Pointer(&b[0]))

Likewise:

    s := &C.struct_addrinfo{ai_canonname: C.charp(unsafe.Pointer(&b[0]))}

This static checking is imperfect.  It does not catch a case like this:

    x := &C.X{}
    x.y = &C.Y{}
    C.Foo(x)

In this example we store a Go pointer into `x.y`, but there is no type
conversion from a Go pointer type to a C pointer type.

In practice, we must permit converting from C pointer types to Go
pointer types, so that a Go function can call C code and then return
the results to other code that does not use cgo.  That means that this
static check does not catch cases like this:

    x := (*C.X)(unsafe.Pointer(C.malloc(10)))
    g := (*X)(unsafe.Pointer(x))
    g.y = &y{}
    C.Foo(x)

In this example we convert the C pointer to a Go type, then set a
field to a Go pointer, then pass the original C pointer, now pointing
to memory that holds a Go pointer, to C.

In order to catch all Go code that violates the cgo rules, we
introduce a dynamic checker.
This checker is more expensive, and we do not expect people to run it
all the time.
Think of it as similar to the race detector.

The dynamic checker will be turned on via a new option to go build:
-checkcgo.
The dynamic checker will have the following effects:

* We will turn on the write barrier at all times.
  Whenever a pointer is written to memory, we will check whether the
  pointer is a Go pointer.
  If it is, we will check whether we are writing it to Go memory.
  If we are not, we will report an error.

* We will change cgo to add code to check the pointer fields of any
  value passed to a C function, and any value returned by an exported
  Go function.
  If any of them are Go pointers, we will report an error.

* We will add a timeout to any C function that takes a Go pointer as a
  value.
  If the C function does not return within 1 minute, we will report an
  error.

These checks should detect all violations of the cgo rules on the Go
side.
It is still possible to violate the cgo rules on the C side.
There is little we can do about this (in the long run we could imagine
writing a Go specific memory sanitizer to catch errors.)

A particular unsafe area is C code that wants to hold on to Go func
and pointer values for future callbacks from C to Go.
This works today but is not permitted by these rules.
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
Unfortunately that break existing packages like github.com/gonum/blas,
which pass slices of floats from Go to C for efficiency.
It also breaks the standard library, which passes the address of a
`C.struct_addrinfo` to `C.getaddrinfo`.
It would be possible to require all such code to change to allocate
their memory in C rather than Go, but it would make cgo considerably
harder to use.

This proposal is an attempt at the next simplest rule.
We permit passing Go pointers to C, but we require that the Go memory
not contain any further pointers.
If a later garbage collector implements moving pointers, cgo will
introduce temporary pins for the duration of the C call.
This leads directly to the four rules listed in this proposal.

The further restrictions on //export functions implement a stricter
form of the same idea, since an //export function passes values from
Go to C by returning them.

Rules are necessary, but it's always useful to enforce the rules.
We can not enforce the rules in C code, but we can attempt to do so in
Go code.
The proposal tries to catch most cases at build time, by introducing
additional type checking rules implemented in cgo.
It tries to catch all cases at run time, by introducing dynamic checks.

If we adopt these rules, we can not change them later, except to
loosen them.
We can, however, change the enforcement mechanism written in cgo, if
we think of better approaches.

## Compatibility

This rules are intended to extend the Go 1 compatibility guidelines to
the cgo interface.

## Implementation

The implementation of the rules requires adding documentation to the
cgo command.

The implementation of the enforcement mechanism requires changes to
the cgo tool and the go tool.
The changes should not be extensive.

The goal is to get agreement on this proposal and to complete the work
before the 1.6 freeze date.

## Open issues

Can and should we provide library support for certain operations, like
passing a token for a Go value through C to Go functions called from
C?
