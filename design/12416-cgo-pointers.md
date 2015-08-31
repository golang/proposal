# Proposal: Rules for passing pointers between Go and C

Author: Ian Lance Taylor
Last updated: August, 2015

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
  That rule must be preserved during C execution, in that the program
  must not store any Go pointers into that memory.
  When passing a pointer to a field in struct, the Go memory in
  question is the memory occupied by the field, not the entire struct.

* C code may otherwise use the Go pointer and the Go memory to which
  it points freely during the call.
  However, C code may not keep a copy of the Go pointer after the call
  returns.
  C code may not modify the Go pointer to point outside of the Go
  memory (a pointer just past the end is permissible, as is usual in
  C).

* If Go code passes a Go pointer to a C function, the C function must
  return.
  While there are no documented time limits, a C function that simply
  blocks holding a Go pointer while other goroutines are running may
  eventually cause the program to run out of memory and fail.

* A Go function called by C code may not return a Go pointer.
  A Go function called by C code may take C pointers as arguments, and
  it may store non-pointer or C pointer data through those pointers,
  but it may not store a Go pointer into memory pointed to by a C
  pointer.
  A Go function called by C code may take a Go pointer as an argument,
  but it must preserve the property that the Go memory to which it
  points does not contain any Go pointers.

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
Every value passed to a C function has a C type.
We can make it difficult for those C types to hold Go pointers.
We can not make it impossible for people to pass Go memory containing
Go pointers to C, but we can make it hard.

We do this by modifying cgo to prohibit any type conversion from a Go
pointer type to a C pointer type, except as a direct argument to a C
function call.
Any such type conversion is an error in cgo.
Even within a direct function call, we prohibit type conversions if
the Go pointer type points to a type that itself contains pointers.

We can apply additional restrictions to a function labelled //export,
which may be called from C code.
Such a function must not return any Go pointer type.
It may not have any parameters that are Go pointer types.

The following example is OK because Go type `[]byte` does not itself
contain any pointers (that is, there are no pointers in the underlying
array), and type conversion is permitted in a direct function call:

    var b []byte
    C.memcpy(C.voidp(&b[0]), C.voidp(&b[10]), 10)

This is OK because `s` is a C type:

    var s *C.struct_addrinfo
    C.getaddrinfo(nil, C.Cstring("google.com"), nil, &s)

This is not OK, because it converts a Go pointer type to a C pointer type:

    var s C.struct_addrinfo
    s.ai_canonname = C.charp(&b[0])

Likewise:

    s := &C.struct_addrinfo{ai_canonname: C.charp(&b[0])}

This proposal is imperfect.  It does not catch a case like this:

    x := &C.X{}
    x.y = &C.Y{}
    C.Foo(x)

In this example we store a Go pointer into `x.y`, but there is no type
conversion from a Go pointer type to a C pointer type.
We may be able to add an additional prohibition: you may not take the
address of a value of C type (including a composite literal of C type)
except in a direct function call.
I’m not sure we can get away with that, but maybe we can.

We may want to modify cgo to dynamically check pointers.
If they are Go pointers, cgo could call code that uses the type
descriptor to verify that the memory does not contain any Go pointers.
That would provide a further check, at some additional runtime cost.
It would catch cases like the last example above.
It would not catch cases where the Go pointer was converted to uintptr
or some other non-pointer type.

This cgo restriction is stricter than what the proposal above actually
requires.
However, it can be implemented and it can be understood.
It can be worked around via the unsafe package but otherwise will mostly
enforce the required rules on the Go side.

This restriction does not make code safe.
For example, it is still possible to write C code that stores a Go
pointer into Go memory, which can fail in an unpleasant manner.
It may be possible for cgo to detect this by examining values upon
function return.
I don't know that it's worth it, because of course it is possible for
C to store a Go pointer into C memory, and that is undetectable.

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
the cgo tool.  The changes should not be extensive.

The goal is to get agreement on this proposal and to complete the work
before the 1.6 freeze date.

## Open issues

Should we dynamically check pointers in the cgo runtime?

Should we permit taking the address of a value of C type outside of a
direct function call?

Can and should we provide library support for certain operations, like
passing a token for a Go value through C to Go functions called from
C?
