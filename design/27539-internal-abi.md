# Proposal: Create an undefined internal calling convention

Author(s): Austin Clements

Last updated: 2019-01-14

Discussion at https://golang.org/issue/27539.

## Abstract

Go's current calling convention interferes with several significant
optimizations, such as [register
passing](https://golang.org/issue/18597) (a potential 5% win).
Despite the obvious appeal of these optimizations, we've encountered
significant roadblocks to their implementation.
While Go's calling convention isn't covered by the [Go 1 compatibility
promise](https://golang.org/doc/go1compat), it's impossible to write
Go assembly code without depending on it, and there are many important
packages that use Go assembly.
As a result, much of Go's calling convention is effectively public and
must be maintained in a backwards-compatible way.

We propose a way forward based on having multiple calling conventions.
We propose maintaining the existing calling convention and introducing
a new, private calling convention that is explicitly not
backwards-compatible and not accessible to assembly code, with a
mechanism to keep different calling convention transparently
inter-operable.
This same mechanism can be used to introduce other public, stable
calling conventions in the future, but the details of that are outside
the scope of this proposal.

This proposal is *not* about any specific new calling convention.
It's about *enabling* new calling conventions to work in the existing
Go ecosystem.
This is one step in a longer-term plan.


## Background

Language environments depend on *application binary interfaces* (ABIs)
to define the machine-level conventions for operating within that
environment.
One key aspect of an ABI is the *calling convention*, which defines
how function calls in the language operate at a machine-code level.

Go's calling convention specifies how functions pass argument values
and results (on the stack), which registers have fixed functions
(e.g., R10 on ARM is the "g" register) or may be clobbered by a call
(all non-fixed function registers), and how to interact with stack
growth, the scheduler, and the garbage collector.

Go's calling convention as of Go 1.11 is simple and nearly universal
across platforms, but also inefficient and inflexible.
It is rife with opportunities for improving performance.
For example, experiments with [passing arguments and results in
registers](https://golang.org/issue/18597) suggest a 5% performance
win.
Propagating register clobbers up the call graph could avoid
unnecessary stack spills.
Keeping the stack bound in a fixed register could eliminate two
dependent memory loads on every function entry on x86.
Passing dynamic allocation scopes could reduce heap allocations.

And yet, even though the calling convention is invisible to Go
programs, almost every substantive change we've attempted has been
stymied because changes break existing Go *assembly* code.
While there's relatively little Go assembly (roughly 170 kLOC in
public GitHub repositories<sup>*</sup>), it tends to lie at the heart
of important packages like crypto and numerical libraries.

This proposal operates within two key constraints:

1. We can't break existing assembly code, even though it isn't
   technically covered by Go 1 compatibility.
   There's too much of it and it's too important.
   Hence, we can't change the calling convention used by existing
   assembly code.

2. We can't depend on a transition periods after which existing
   assembly would break.
   Too much code simply doesn't get updated, or if it does, it doesn't
   get re-vendored.
   Hence, it's not enough to give people a transition path to a new
   calling convention and some time.
   Existing code must continue to work.

This proposal resolves this tension by introducing multiple calling
conventions.
Initially, we propose two: one is stable, documented, and codifies the
rules of the current calling convention; the other is unstable,
internal, and may change from release to release.

<sup>*</sup> This counts non-comment, non-whitespace lines of code in
unique files. It excludes vendored source and source with a "Go
Authors" copyright notice.


## Proposal

We propose introducing a second calling convention.

* `ABI0` is the current calling convention, which passes arguments and
  results on the stack, clobbers all registers on calls, and has a few
  platform-dependent fixed registers.

* `ABIInternal` is unstable and may change from release to release.
  Initially, it will be identical to `ABI0`, but `ABIInternal` opens
  the door for changes.

Once we're happy with `ABIInternal`, we may "snapshot" it as a new
stable `ABI1`, allowing assembly code to be written against the
presumably faster, new calling convention.
This would not eliminate `ABIInternal`, as `ABIInternal` could later
diverge from `ABI1`, though `ABI1` and `ABIInternal` may be identical
for some time.

A text symbol can provide different definitions for different ABIs.
One of these will be the "native" implementation—`ABIInternal` for
functions defined in Go and `ABI0` for functions defined in
assembly—while the others will be "ABI wrappers" that simply translate
to the ABI of the native implementation and call it.
In the linker, each symbol is already identified with a (name,
version) pair.
The implementation will simply map ABIs to linker symbol versions.

All functions defined in Go will be natively `ABIInternal`, and the Go
compiler will assume all functions provide an `ABIInternal`
implementation.
Hence, all cross-package calls and all indirect calls (closure calls
and interface method calls) will use `ABIInternal`.
If the native implementation of the called function is `ABI0`, this
will call a wrapper, which will call the `ABI0` implementation.
For direct calls, if the compiler knows the target is a native `ABI0`
function, it can optimize that call to use `ABI0` directly, but this
is strictly an optimization.

All functions defined in assembly will be natively `ABI0`, and all
references to text symbols from assembly will use the `ABI0`
definition.
To introduce another stable ABI in the future, we would extend the
assembly symbol syntax with a way to specify the ABI, but `ABI0` must
be assumed for all unqualified symbols for backwards compatibility.

In order to transparently bridge the two (or more) ABIs, we will
extend the assembler with a mode to scan for all text symbol
definitions and references in assembly code, and report these to the
compiler.
When these symbols are referenced or defined, respectively, from Go
code in the same package, the compiler will use the type information
available in Go declarations and function stubs to produce the
necessary ABI wrapper definitions.

The linker will check that all symbol references use the correct ABI
and ultimately keep everything honest.


## Rationale

The above approach allows us to introduce an internal calling
convention without any modifications to any safe Go code, or the vast
majority of assembly-using packages.
This is largely afforded by the extra build step that scans for
assembly symbol definitions and references.

There are two major trade-off axes that lead to different designs.

### Implicit vs explicit

Rather than implicitly scanning assembly code for symbol definitions
and references, we could instead introduce pragma comments that users
could use to explicitly inform the compiler of symbol ABIs.
This would make these ABI boundaries evident in code, but would likely
break many more existing packages.

In order to keep any assembly-using packages working as-is, this
approach would need default rules.
For example, body-less function stubs would likely need to default to
`ABI0`.
Any Go functions called from assembly would still need explicit
annotations, though such calls are rare.
This would cover most assembly-using packages, but function stubs are
also used for Go symbols pushed across package boundaries using
`//go:linkname`.
For link-named symbols, a pragma would be necessary to undo the
default `ABI0` behavior, and would depend on how the target function
was implemented.

Ultimately, there's no set of default rules that keeps all existing
code working.
Hence, this design proposes extracting symbols from assembly source to
derive the correct ABIs in the vast majority of cases.

### Wrappers vs single implementation

In this proposal, a single function can provide multiple entry-points
for different calling conventions.
One of these is the "native" implementation and the others are
intended to translate the calling convention and then invoke the
native implementation.

An alternative would be for each function to provide a single calling
convention and require all calls to that function to follow that
calling convention.
Other languages use this approach, such as C (e.g.,
`fastcall`/`stdcall`/`cdecl`) and Rust (`extern "C"`, etc).
This works well for direct calls, but for direct calls it's also
possible to compile away this proposal's ABI wrapper.
However, it dramatically complicates indirect calls since it requires
the calling convention to become *part of the type*.
Hence, in Go, we would either have to extend the type system, or
declare that only `ABIInternal` functions can be used in closures and
interface satisfaction, both of which are less than ideal.

Using ABI wrappers has the added advantage that calls to a Go function
from Go can use the fastest available ABI, while still allowing calls
via the stable ABI from assembly.

### When to generate wrappers

Finally, there's flexibility in this design around when exactly to
generate ABI wrappers.
In the current proposal, ABI wrappers are always generated in the
package where both the definition and the reference to a symbol
appear.
However, ABI wrappers can be generated anywhere Go type information is
available.

For example, the compiler could generate an `ABIInternal`→`ABI0`
wrapper when an `ABI0` function is stored in a closure or method
table, regardless of which package that happens in.
And the compiler could generate an `ABI0`→`ABIInternal` wrapper when
it encounters an `ABI0` reference from assembly by finding the
function's type either in the current package or via export info from
another package.


## Compatibility

This proposed change does not affect the functioning of any safe Go
code.
It can affect code that goes outside the [compatibility
guidelines](https://golang.org/doc/go1compat), but is designed to
minimize this impact.
Specifically:

1. Unsafe Go code can observe the calling convention, though doing so
   requires violating even the [allowed uses of
   unsafe.Pointer](https://golang.org/pkg/unsafe/#Pointer).
   This does arise in the internal implementation of the runtime and
   in cgo, both of which will have to be adjusted when we actually
   change the calling convention.

2. Cross-package references where the definition and the reference are
   different ABIs may no longer link.

There are various ways to form cross-package references in Go, though
all depends on `//go:linkname` (which is explicitly unsafe) or
complicated assembly symbol naming.
Specifically, the following types of cross-package references may no
longer link:

<table>
<thead>
<tr>
<th colspan="2" rowspan="2"></th>
<th colspan="4">def</th>
</tr>
<tr>
<th>Go</th>
<th>Go+push</th>
<th>asm</th>
<th>asm+push</th>
</tr>
</thead>
<tbody>
<tr>
<th rowspan="4">ref</th>
<th>Go</th>      <td>✓</td><td>✓</td><td>✓</td><td>✗¹</td>
</tr>
<tr>
<th>Go+pull</th> <td>✓</td><td>✓</td><td>✗¹</td><td>✗¹</td>
</tr>
<tr>
<th>asm</th>     <td>✓</td><td>✗²</td><td>✓</td><td>✓</td>
</tr>
<tr>
<th>asm+xref</th><td>✗²</td><td>✗²</td><td>✓</td><td>✓</td>
</tr>
</tbody></table>

In this table "push" refers to a symbol that is implemented in one
package, but its symbol name places it in a different package.
In Go this is accomplished with `//go:linkname` and in assembly this
is accomplished by explicitly specifying the package in a symbol name.
There are a total of two instances of "asm+push" on all of public
GitHub, both of which are already broken under current rules.

"Go+pull" refers to when an unexported symbol defined in one package
is referenced from another package via `//go:linkname`.
"asm+xref" refers to any cross-package symbol reference from assembly.
The vast majority of "asm+xref" references in public GitHub
repositories are to a small set of runtime package functions like
`entersyscall`, `exitsyscall`, and `memmove`.
These are serious abstraction violations, but they're also easy to
keep working.

There are two general groups of link failures in the above table,
indicated by superscripts.

In group 1, the compiler will create an `ABIInternal` reference to a
symbol that may only provide an `ABI0` implementation.
This can be worked-around by ensuring there's a Go function stub for
the symbol in the defining package.
For "asm" definitions this is usually the case anyway, and "asm+push"
definitions do not happen in practice outside the runtime.
In all of these cases, type information is available at the reference
site, so the compiler could record assembly ABI definitions in the
export info and produce the stubs in the referencing package, assuming
the defining package is imported.

In group 2, the assembler will create an `ABI0` reference to a symbol
that may only provide an `ABIInternal` implementation.
In general, calls from assembly to Go are quite rare because they
require either stack maps for the assembly code, or for the Go
function and everything it calls recursively to be `//go:nosplit`
(which is, in general, not possible to guarantee because of
compiler-inserted calls).
This can be worked-around by creating a dummy reference from assembly
in the defining package.
For "asm+xref" references to exported symbols, it would be possible to
address this transparently by using export info to construct the ABI
wrapper when compiling the referer package, again assuming the
defining package is imported.

The situations that cause these link failures are vanishingly rare in
public code corpora (outside of the standard library itself), all
depend on unsafe code, and all have reasonable workarounds.
Hence, we conclude that the potential compatibility issues created by
this proposal are worth the upsides.

### Calling runtime.panic* from assembly

One compatibility issue we found in public GitHub repositories was
references from assembly to `runtime.panic*` functions.
These calls to an unexported function are an obvious violation of
modularity, but also a violation of the Go ABI because the callers
invariably lack a stack map.
If a stack growth or GC were to happen during this call, it would
result in a fatal panic.

In these cases, we recommend wrapping the assembly function in a Go
function that performs the necessary checks and then calls the
assembly function.
Typically, this Go function will be inlined into its caller, so this
will not introduce additional call overhead.

For example, take a function that computes the pair-wise sums of two
slices and requires its arguments to be the same length:

```asm
// func AddVecs(x, y []float64)
TEXT ·AddVecs(SB), NOSPLIT, $16
	// ... check lengths, put panic message on stack ...
    CALL runtime·panic(SB)
```

This should instead be written as a Go function that uses language
facilities to panic, followed by a call to the assembly
implementation that implements the operation:

```go
func AddVecs(x, y []float64) {
    if len(x) != len(y) {
        panic("slices must be the same length")
    }
    addVecsAsm(x, y)
}
```

In this example, `AddVecs` is small enough that it will be inlined, so
there's no additional overhead.


## Implementation

Austin Clements will implement this proposal for Go 1.12.
This will allow the ABI split to soak for a release while the two
calling conventions are in fact identical.
Assuming that goes well, we can move on to changing the internal
calling convention in Go 1.13.

Since both calling conventions will initially be identical, the
implementation will initially use "ABI aliases" rather than full ABI
wrappers.
ABI aliases will be fully resolved by the Go linker, so in the final
binary every symbol will still have one implementation and all calls
(regardless of call ABI) will resolve to that implementation.

The rough implementation steps are as follows:

1. Reserve space in the linker's symbol version numbering to represent
   symbol ABIs.
   Currently, all non-static symbols have version 0, so any linker
   code that depends on this will need to be updated.

2. Add a `-gensymabis` flag to `cmd/asm` that scans assembly sources
   for text symbol definitions and references and produces a "symbol
   ABIs" file rather than assembling the code.

3. Add a `-symabis` flag to `cmd/compile` that accepts this symbol
   ABIs file.

4. Update `cmd/go`, `cmd/dist`, and any other mini-build systems in
   the standard tree to invoke `asm` in `-gensymabis` mode and feed
   the result to `compile`.

5. Add support for recording symbol ABIs and ABI alias symbols to the
   object file format.

6. Modify `cmd/link` to resolve ABI aliases.

7. Modify `cmd/compile` to produce `ABIInternal` symbols for all Go
   functions, produce `ABIInternal`→`ABI0` ABI aliases for Go
   functions referenced from assembly, and produce
   `ABI0`→`ABIInternal` ABI aliases for assembly functions referenced
   from Go.

Once we're ready to modify the internal calling convention, the first
step will be to produce actual ABI wrappers.
We'll then likely want to start with a simple change, such as putting
the stack bound in a fixed register.


## Open issues

There are a few open issues in this proposal.

1. How should tools that render symbols from object files (e.g., `nm`
   and `objdump`) display symbol ABIs?
   With ABI aliases, there's little need to show this (though it can
   affect how a symbol is resolved), but with full ABI wrappers it
   will become more pressing.
   Ideally this would be done in a way that doesn't significantly
   clutter the output.

2. How do we represent symbols with different ABI entry-points in
   platform object files, particularly in shared objects?
   In the initial implementation using ABI aliases, we can simply
   erase the ABI.
   It may be that we need to use minor name mangling to encode the
   symbol ABI in its name (though this does not have to affect the Go
   symbol name).

3. How should ABI wrappers and `go:nosplit` interact?
   In general, the wrapper needs to be `go:nosplit` if and only if the
   wrapped function is `go:nosplit`.
   However, for assembly functions, the wrapper is generated by the
   compiler and the compiler doesn't currently know whether the
   assembly function is `go:nosplit`.
   It could conservatively make wrappers for assembly functions
   `go:nosplit`, or the toolchain could include that information in
   the symabis file.
