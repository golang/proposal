# Proposal: Make 64-bit fields be 64-bit aligned on 32-bit systems, add //go:packed, //go:align directives

Author(s): Dan Scales (with input from many others)

Last updated: 2020-06-08

Initial proposal and discussion at:  https://github.com/golang/go/issues/36606

## Abstract

We propose to change the default layout of structs on 32-bit systems such that
64-bit fields will be 8-byte (64-bit) aligned. The layout of structs on 64-bit systems
will not change. For compatibility reasons (and finer control of struct layout),
we also propose the addition of a `//go:packed` directive that applies to struct
types. When the `//go:packed` directive is specified immediately before a struct
type, then that struct will have a fully-packed layout, where fields are placed
in order with no padding between them and hence no alignment based on types. The
developer must explicitly add padding to enforce any desired alignment.  We also
propose the addition of a `//go:align` directive that applies to all types.  It
sets the required alignment in bytes for the associated type.  This directive
will be useful in general, but specifically can be used to set the required
alignment for packed structs.


## Background


Currently, each Go type has a required alignment in bytes.
This alignment is used for setting the alignment for any
variable of the associated type (whether global variable, local variable,
argument, return value, or heap allocation) or a field of the associated type in
a struct. The actual alignments are implementation-dependent.  In gc, the alignment
can be 1, 2, 4, or 8 bytes.  The alignment determination is fairly straightforward,
and mostly encapsulated in the functions `gc.dowidth()` and `gc.widstruct()` in
`cmd/compile/internal/gc/align.go`.  gccgo and GoLLVM have slightly different alignments
for some types.  This proposal is focused on the alignments used in gc.

The alignment rules differ slightly between 64-bit and 32-bit systems. Of
course, certain types (such as pointers and integers) have different sizes
and hence different alignments. The main other difference is the treatment of
64-bit basic types such as `int64`, `uint64`, and `float64`. On 64-bit systems, the
alignment of 64-bit basic types is 8 bytes (64 bits), while on 32-bit systems,
the alignment of these types is 4 bytes (32 bits). This means that fields in a
struct on a 32-bit system that have a 64-bit basic type may be aligned only to 4
bytes, rather than to 8 bytes.

There are a few more alignment rules for global variables and heap-allocated
locations. Any heap-allocated type that is 8 bytes or more is always aligned on
an 8-byte boundary, even on 32-bit systems (see `runtime.mallocgc`).
Any global variable which is a
64-bit base type or is a struct also always is aligned on 8 bytes (even on
32-bit systems). Hence, the above alignment difference for 64-bit base types
between 64-bit and 32-bit systems really only occurs for fields in a struct and
for stack variables (including arguments and return values).

The main goal of this change is to avoid the bugs that frequently happen on
32-bit systems, where a developer wants to be able to do 64-bit operations (such
as an atomic operation) on a 64-bit field, but gets an alignment error because
the field is not 8-byte aligned. With the current struct layout rules (based on
the current type alignment rules), a developer must often add explicit padding
in order to make sure that such a 64-bit field is on a 8-byte boundary. As shown
by repeated mentions in issue [#599](https://github.com/golang/go/issues/599)
(18 in 2019 alone), developers still often run into this problem. They may only
run into it late in the development cycle as they are testing on 32-bit
architectures, or when they execute an uncommon code path that requires the
alignment.

As an example, the struct for ticks in `runtime/runtime.go` is declared as

```go
var ticks struct {
	lock mutex
	pad  uint32 // ensure 8-byte alignment of val on 386
	val  uint64
}
```

so that the `val` field is properly aligned on 32-bit architectures.

Note that there can also be alignment issues with stack variables which have
64-bit base types, but it seems less likely that a program would be using a local
variable for 64-bit operations such as atomic operations.

There are related reasons why a developer might want to explicitly control the
alignment of a specific type (possibly to an alignment even great than 8 bytes),
as detailed in issue [#19057](https://github.com/golang/go/issues/19057). As
mentioned in that issue, "on x86 there are vector instructions that require
alignment to 16 bytes, and there are even some instructions (e.g., vmovaps with
VEC.256), that require 32 byte alignment." It is also possible that a developer
might want to force alignment of a type to be on a cache line boundary, to
improve locality and avoid false sharing (e.g. see `cpu.CacheLinePad` in the
`runtime` package sources). Cache line sizes typically range from
32 to 128 bytes.


## Proposal

This proposal consists of a proposed change to the default alignment rules on 32-bit systems,
a new `//go:packed` directive, and a new `//go:align` directive.  We describe each in a
separate sub-section.

### Alignment changes

The main part of our proposal is the following:

 * We change the default alignment of 64-bit fields in structs on 32-bit systems
   from 4 bytes to 8 bytes
 * We do not change the alignment of 64-bit base types otherwise (i.e. for stack
   variables, global variables, or heap allocations)

Since the alignment of a struct is based on the maximum alignment of any field
in the struct, this change will also change the overall alignment of certain
structs on 32-bit systems from 4 to 8 bytes.

It is important that we do not change the alignment of stack variables
(particular arguments and return values), since changing their alignment would
directly change the Go calling ABI.  (As we’ll note below, we are still
changing the ABI in a minor way, since we are changing the layout and possibly
the size of some structs that could be passed as arguments and return values.)

As mentioned above, 64-bit basic types are already aligned to 8 bytes
(based on other rules) for global variables or heap allocations.  Therefore, we
do not usually run into alignment problems for 64-bit basic types on 32-bit
systems when they are simple global variables or heap allocations.

One way to think about this change is that each type has two alignment
properties, analogous to the `Type.FieldAlign()` and `Type.Align()`
methods in the `reflect` package. The first property specifies
the alignment when that type
occurs as a field in a struct. The second property specifies the
alignment when that type is used in any other situation, including stack
variables, global variables, and heap allocations. For almost all types, the
field alignment and the "other" alignment of each type will be equal to each
other and the same as it is today. However, in this proposal, 64-bit basic types
(`int64`, `uint64`, and `float64`) on 32-bit system will have a field alignment of 8
bytes, but keep an "other" alignment of 4 bytes.  As we mentioned, structs that
contain 64-bit basic types on 32-bit systems may have 8-byte alignment now where
previously they had 4-byte alignment; however, both their field alignment and
their "other" alignment would have this new value.

### Addition of a `//go:packed` directive

We make the above proposed change in order to reduce the kind of bugs detailed in issue
[#599](https://github.com/golang/go/issues/599). However, we need to maintain
explicit compatibility for struct layout in some important situations.
Therefore, we also propose the following:

 * We add a new Go directive `//go:packed` which applies to the immediately
   following struct type. That struct type will have a fully-packed layout,
   where fields are placed in order with no padding between them and hence no
   alignment based on types.

The `//go:packed` property will become part of the following struct type
that it applies to.  In particular, we will not allow assignment/conversion from
a struct type to the equivalent packed struct type, and vice versa.

The `//go:packed` property only applies to the struct type being defined.  It does
not apply to any struct type that is embedded in the type being defined.  Any
embedded struct type must similarly be defined with the `//go:packed` property if
it is to be packed either on its own or inside another struct definition.
`//go:packed` will be ignored if it appears anywhere
else besides immediately preceding a struct type definition.

The idea with the `//go:packed` directive is to give the developer complete
control over the layout of a struct.  In particular, the developer (or a
code-generating program) can add padding so that the fields of a packed struct are laid
out in exactly the same way as they were in Go 1.15 (i.e. without the above
proposed alignment change).  Matching the exact layout as in Go 1.15 is needed
in some specific situations:

1.  Matching the layout of some Syscall structs, such as `Stat_t` and `Flock_t` on linux/386.
    On 32-bit systems, these two structs actually have 64-bit fields that are
    not aligned on 8-byte boundaries.  Since these structs are the exact
    struct used to interface with Linux syscalls, they must have exactly the
    specified layout.  With this proposal, any structs passed to syscall.Syscall
    should be laid out exactly using `//go:packed`.

2.  Some cgo structs (which are used to match declared C structs) may also
    have 64-bit fields that are not aligned on 8-byte boundaries.  So, with this
    proposal, cgo should use `//go:packed` for generated Go structs that must
    exactly match the layout of C structs.  In fact, there are currently C
    structs that cannot be matched exactly by Go structs, because of the current
    (Go 1.15) alignment rules.  With the use of `//go:packed`, cgo will now be able
    to match exactly the layout of any C struct (unless the struct uses bitfields).

Note that there is possibly assembly language code in some Go programs or
libraries that directly accesses the fields of a struct using hard-wired
offsets, rather than offsets obtained from a `go_asm.h` file. If that struct has
64-bit fields, then the offsets of those fields may change on 32-bit systems
with this proposal. In that case, then the assembly code may break. In that
case, we strongly recommend rewriting the assembly language code to use offsets
from `go_asm.h` (or using values obtained from from Go code via
`unsafe.Offsetof`). We would not recommend forcing the layout of the struct to
remain the same by using `//go:packed` and appropriate padding.

### Addition of a `//go:align` directive

One issue with the `//go:packed` idea is determining the overall alignment of
a packed struct.  Currently, the overall alignment of a struct is computed as
the maximum alignment of any of its fields.  In the case of `//go:packed`, the
alignment of each field is essentially 1.  Therefore, conceptually, the overall
alignment of a packed struct is 1.  We could therefore consider that we need to
explicitly specify the alignment of a packed struct.

As we mentioned above, there are other reasons why developers would like to
specify an explicit alignment for a Go type.  For both of these reasons, we
therefore propose a method to specify the alignment of a Go type:

 * We add a new Go directive `//go:align` N, which applies to the immediately
   following type, where N can be any positive power of 2. The following
   type will have the specified required alignment, or the natural alignment
   of the type, whichever is larger.  It will be a compile-time
   error if N is missing or is not a positive power of 2.  `//go:packed` and `//go:align`
   can appear in either order if they are both specified preceding a struct type.

In order to work well with memory allocators, etc., we only allow alignments
that are powers of 2.  There will probably have to be some practical upper limit on
the possible value of N.  Even for the purposes of aligning to cache lines, we would
likely only need alignment up to 128 bytes.

One issue with allowing otherwise identical types to have different alignments
is the question of when pointers to these types can be converted.  Consider the
following example:

```go

type A struct {
  x, y, z, w int32
}

type B struct {
  x, y, z, w int32
}

//go:align 8
type C struct {
  x, y, z, w int32
}

a := &A{}
b := (*B)(a)     // conversion 1
c := (*C)(a)    // conversion 2
```

As in current Go, conversion 1 should certainly be allowed.  However, it is not
clear that conversion 2 should be allowed, since object `a` may not be
aligned to 8 bytes, so it may not satisfy the alignment property of `C` if `a`
is assigned to `c`.  Although this issue of convertability applies only to pointers of aligned
structs, it seems simplest and most consistent to include alignment as part of the base
type that it applies to.  We would therefore disallow converting from `A` to `C` and vice versa.
We propose the following:

 * An alignment directive becomes part of the type that it applies to, and makes that type
   distinct from an otherwise identical type with a different (or no) alignment.

With this proposal, types `(*C)` and `(*A)` are not convertible, despite pointing to
structs that look identical, because the alignment of the structs to which they
point are different.  Therefore, conversion 2 would cause a compile-time error.  Similarly,
conversion between `A` and `C` would be disallowed.

### Vet and compiler checks

Finally, we would like to help ensure that `//go:packed` is used in
cases where struct layout must maintain strict compatibility with Go 1.15. As
mentioned above, the important cases where compatibility must be maintained are structs
passed to syscalls and structs used with
Cgo.  Therefore, we propose the addition of the following vet check:

 * New 'go vet' pass that requires the usage of `//go:packed` on a struct if a
   pointer to that struct type is passed to syscall.Syscall (or its variants) or to cgo.

The syscall check should cover most of the supported OSes (including Windows and
Windows DLLs), but we may have to extend the vet check if there are other ways
to call native OS functions. For example, in Windows, we may also want to cover
the `(*LazyProc).Call` API for calling DLL functions.

We could similarly have an error if a pointer to a non-packed struct type is
passed to an assembly language function, though that warning might have a lot of
false positives. Possibly we would limit warnings to such assembly language
functions that clearly do not make use of `go_asm.h` definitions.

We intend that `//go:packed` should only be used in limited situations, such as
controlling exact layout of structs used in syscalls or in cgo.  It is possible
to cause bugs or performance problems if it is not used correctly.  In
particular, there could be problems with garbage collection if fields containing
pointers are not aligned to the standard pointer alignment.  Therefore,
we propose the following compiler and vet checks:

 * The compiler will give a compile-time error if the fields of a packed struct are aligned
   incorrectly for garbage collection or hardware-specific needs.  In particular, it will be
   an error if a pointer field is not aligned to a 4-byte boundary.  It may also be an error,
   depending on the hardware, if 16-bit fields are not aligned to 2-byte boundaries or
   32-bit fields are not aligned to 4-byte boundaries.

Some processors can successfully load 32-bit quantities that are not aligned to
4 bytes, but the unaligned load is much slower than an aligned load.  So, the idea
of compiler check for the alignment of 16-bit and 32-bit quantities is to protect
against this case where certain loads are "silently" much slower because they
are accessing unaligned fields.


## Alternate proposals

The above proposal contains a coherent set of proposed changes that address the
main issue [#599](https://github.com/golang/go/issues/599), 
while also including some functionality (packed structs, aligned
types) that are useful for other purposes as well.

However, there are a number of alternatives, both to the set of features in the
proposal, and also in the details of individual items in the proposal.

The above proposal has quite a number of
individual items, each of which adds complexity and may have unforeseen issues.
One alternative is to reduce the scope of the proposal, by removing
`//go:align`. With this alternative, we would propose a separate rule for the
alignment of a packed struct. Instead of having a default alignment of 1, a
packed struct would have as its alignment the max alignment of all the types
that make up its individual fields. That is, a packed struct would automatically
have the same overall alignment as the equivalent unpacked struct.  With this
definition, we don't need to include `//go:align` in this proposal.

Another alternative (which actually increases the scope of the proposal) would
be to allow `//go:align` to apply not just to type declarations, but also to
field declarations within a packed struct.  This would allow explicit alignment of
fields within a packed struct, which would make it easier for developers to get field
alignment correct without using padding.  However, we probably do not want to
encourage broad use of `//go:align`, and this ability of `//go:align` to set the
alignment of fields might become greatly overused.

## Alternate syntax

There is also an alternative design that has the same set of features, but expresses the
alignment of types differently.  Instead of using `//go:align`, this alternative
follows the proposal in issue [#19057](https://github.com/golang/go/issues/19057) and
expresses alignment via new runtime types
included in structs.  In this proposal, there are runtime types
`runtime.Aligned8`, `runtime.Aligned16`, etc.  If, for example, a field with
type `runtime.Aligned16` is included in a struct type definition, then that
struct type will have an alignment of 16 bytes, as in:

```go
type vector struct {
    _ runtime.Aligned16
    vals [16]byte
}
```

It is possible that using `runtime.AlignedN` could directly apply to the following field in
the struct as well.  Hence, `runtime.AlignedN` could appear multiple times in a struct in order
to set the alignment of various fields, as well as affecting the overall alignment of the struct.

Similarly, the packed attribute of a struct is expressed by including a field with type
`runtime.Packed`.  These fields are zero-length and can either have a name or not.  If they
have a name, it is possible to take a pointer to them.  It would be an error to use these types
in any situation other than as a type for a field in a struct.

There are a number of positives and negatives to this proposal, as compared to the use
of `//go:packed` and `//go:aligned`, as listed below.

Advantages of special field types / disadvantages of directives:
1. Most importantly, using `runtime.AlignedN` and `runtime.Packed` types in a struct makes it
   obvious that these constructs affect the type of the containing struct.  The inclusion of these
   extra fields means that Go  doesn't require any special added constraints for type
   equivalence, assignability, or convertibility.  The use of directives `//go:packed` and
   `//go:aligned` don’t make it as obvious that they actually change the following type.  This
   may cause more changes in other Go tools, since they must be changed to notice these
   directives and realize their effect on the following type.  There is no current `//go:` directive
   that affects the following type.  (`//go:notinheap` relates to the following type, but does not
   change the declared type, and is only available in the runtime package.)
2. `runtime.AlignedN` could just be a zero-width type with alignment N that also affects the
   alignment of the following field.  This is easy to describe and understand, and provides a
   natural way to control both field and struct alignment.  [`runtime.AlignedN` may or may not 
   disable field re-ordering -- to be determined.]
3. If `runtime.AlignedN` applies to the following field, users can easily control padding and
   alignment within a struct. This is particularly useful in conjunction with `runtime.Packed`, as it
   provides a mechanism to add back desired field alignment where packing removed it.  It
   potentially seems much more unusual to have a directive `//go:align` be specified inside a 
   struct declaration and applying specifically to the next field.
4. Some folks prefer to not add any more pragma-like `//go:`  comments in the language.

Advantages of directives / disadvantages of special field types:
1. We have established `//go:` as the prefix for these kinds of build/compiler directives, and it's
   unfortunate to add a second one in the type system instead.
2. With `runtime.AlignedN`, a simple non-struct type (such as `[16]byte`) can only be aligned by
   embedding it in a struct, whereas `//go:align` can apply directly to a non-struct type. It doesn't
   seem very Go-like to force people to create structs like the 'vector' type when plain types like
   `[16]byte` will do.
3. `runtime.Packed` and `runtime.AlignedN` both appear to apply to the following field in the
   struct.  In the case of runtime.Packed, this doesn’t make any sense -- `runtime.Packed`
   applies to the whole struct only, not to any particular field.
4. Adding an alignment/packing field forces the use of key:value literals, which is annoying
   and non-orthogonal. Directives have no effect on literals, so unkeyed literals would continue
   to work.
5. With `runtime.Packed`, there is a hard break at some Go version, where you can't write a
   single struct that works for both older and newer Go versions. That will necessitate separate
   files and build tags during any conversion. With the comments you can write one piece of
   code that has the same meaning to both older and newer versions of Go (because the explicit
   padding is old-version compatible and the old version ignores the `//go:packed` comment).


## Compatibility

We are not changing the alignment of arguments, return variables, or local
variables. Since we would be changing the default layout of structs, we could
affect some programs running on 32-bit systems that depend on the layout of
structs. However, the layout of structs is not explicitly defined in the Go
language spec, except for the minimum alignment, and we are maintaining the
previous minimum alignments. So, we don't believe this change breaks the Go 1
compatibility promise. If assembly code is accessing struct fields, it should be
using the symbolic constants (giving the offset of each field in a struct) that
are available in `go_asm.h`. `go_asm.h` is automatically generated and available for
each package that contains an assembler file, or can be explicitly generated for
use elsewhere via `go tool compile -asmhdr go_asm.h`.

## Implementation

We have a developed some prototype code that changes the default alignment of
64-bit fields on 32-bit systems from 4 bytes to 8 bytes. Since it does not
include an implementation of `//go:packed`, it does not yet try to deal with the
compatibility issues associated with syscall structs `Stat_t` and `Flock_t` or
cgo-generated structs in a complete way. The change is
[CL 210637](https://go-review.googlesource.com/c/go/+/210637). Comments on the design
or implementation are very welcome.

## Open Issues
