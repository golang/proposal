# Proposal: Go general dynamic TLS

Author: Alexander Musman (Advanced Software Technology Lab, Huawei)

Last updated: 2025-01-28

Discussion at [golang.org/issue/71953](https://github.com/golang/go/issues/71953).

## Abstract

The Go runtime currently relies on Thread Local Storage (TLS) to preserve
goroutine state when interacting with C code,
but lacks support for the
general dynamic [TLS model](https://uclibc.org/docs/tls.pdf).
This limitation hinders the use of certain C libraries,
such as Musl,
and restricts loading of Go shared libraries without `LD_PRELOAD`.
We propose extending the Go assembler and linker to support
the general dynamic TLS model,
focusing initially on the Arm64 architecture
on Linux systems.
This enhancement will enable seamless interoperability with
a wider range of C libraries
and improve the flexibility of deploying Go `c-shared` libraries.

## Background

The current Go runtime leverages a Thread Local Storage (TLS) variable
for preserving the current goroutine (`g`)
when interacting with C code.
This is particularly relevant in scenarios such as
CGO interactions
and certain runtime functions like
race detection,
where the code switches to C.
To facilitate this,
Go uses the `runtime.save_g` function
to store the goroutine in the `runtime·tls_g` TLSBSS variable.
The `runtime.load_g` function then retrieves it,
typically upon returning from C code execution.
The Go assembler and linker currently support two TLS access models:
_initial exec_
and _local exec_.
The _local exec_ model is predominantly utilized,
especially in build modes like `exe`,
and is natively supported by the Go linker.
Conversely, the _initial exec_ model requires external linkers
like `bfd-ld`, `lld`, or `gold`
for support.
While the absence of a dynamic TLS model is generally benign with
GlibC—
owing to its adaptable TLS allocation scheme—
this shortcoming becomes problematic with the Musl C library.
Musl's more rigid TLS allocation exposes this limitation,
as highlighted in issue
[golang.org/issue/54805](https://github.com/golang/go/issues/54805).

## Proposal

Introduce general dynamic TLS (Thread Local Storage) support in the Go
assembler/linker,
and update the runtime assembly—
currently the sole user of TLS variables—
to accommodate this model.
Activate this feature in the assembler
with the explicit option `-tls=GD`,
while keeping `-tls=IE` as the default for `shared` mode.
Additionally,
pass `-D=TLS_GD` to enable architecture-specific
macro expansion in the runtime's assembly
when the general dynamic model is employed.
The linker support will depend on external linking,
consistent with the existing initial exec TLS approach.

The `cmd/go` command will enable the general dynamic TLS model by default
in scenarios that require it,
based on the combination of `GOOS`/`GOARCH`
and `buildmode`.
Initially,
this model will be supported by the Arm64 architecture on Linux systems,
specifically for `buildmode=c-shared` and `buildmode=c-archive`.

## Rationale

To enable loading a Go `c-shared` module without relying on `LD_PRELOAD`,
it is essential to support the _general dynamic_ model.
Since the variable resides within the same runtime package as its users,
any relaxation of a _global dynamic_ variable reference to _local dynamic_
is automatically identified and executed by the external linker.
While one could avoid using the `-D` flag by generating the save/restore
of the return address directly in the assembler
(when lowering MOV instruction),
this approach seems less convenient.
It does not explicitly show the clobbered register in the assembly code.
Another consideration would be to modify the runtime functions
that interact with TLS variables to have a stack frame.
However,
this option is not ideal
because these functions are sometimes executed in performance-critical paths,
such as during race detection.

## Compatibility

There is no change in exported APIs.
The build modes affected are `c-shared` and `c-archive`.
Archives built with `c-archive` may be used in a `c-shared` library,
which in turn might be loaded without `LD_PRELOAD`.
The assembler needs to support a new flag `-tls=`,
which allows to choose TLS model explicitly.
This flag will be passed by `cmd/go` and will also be useful
for testing the TLS lowering.
A new relocation type `R_ARM64_TLS_GD` would be needed in objabi,
along with potentially other architecture-specific relocation types.

## Implementation

A prototype of the implementation, is done and tested
with Musl C
for arm64
Linux
(please see [review 644975](https://go-review.googlesource.com/c/go/+/644975)).

### Changes to `cmd/go` for Supported Platforms
For compatible GOOS/GOARCH combinations and applicable build modes,
the following flags are passed to the assembler:
```
-tls=GD -D=TLS_GD
```
These flags allow conditional use of a register to retain
the return address across calls,
as detailed below for arm64.

### Modifications in the Runtime for arm64 Assembly
In assembly code,
specifically for arm64,
we propose updating references to thread-local variable
in `runtime·save_g`/`runtime·load_g`:
```
LOAD_TLS_G_R0        ; get the offset of tls_g from the thread pointer
MRS TPIDR_EL0, R27   ; get the thread pointer into R27
MOVD g, (R0)(R27)    ; use the address in R0+R27
```
The TLS usage occurs in frameless functions,
so we ensure return addresses are preserved across any sequence
involving calls by
using a macro definition as follows:
```
#ifdef TLS_GD
  #define LOAD_TLS_G_R0 \
    MOVD    LR, R25 \
    MOVD    runtime·tls_g(SB), R0 \
    MOVD    R25, LR
#else
  #define LOAD_TLS_G_R0 \
    MOVD    runtime·tls_g(SB), R0
#endif
```

### Assembler Flag Additions and Instruction Lowering
We introduce a `-tls=[IE,LE,GD]` flag in the asm tool.
A new `MOVD` instruction variant, `C_TLS_GD`, is defined,
which lowers to the following four-instruction sequence
using a new `R_ARM64_TLS_GD` relocation type:
```
ADRP var, R0   // Address of the GOT entry
LDR [R0], R27  // Load stub from GOT
ADD #0,R0, R0  // Argument to call
BLR (R27)      // Call, R0 returns offset from TP to variable
```
The `C_TLS_GD` variant would be used for `TLSBSS` symbols
only when a flag `-tls=GD` is passed to assembler.
The default in `shared` mode still remains to be `C_TLS_IE`.

### Linker Enhancements for New Relocation Support
The linker will support the `R_ARM64_TLS_GD` relocation type,
added by the assembler
at the start of the sequence
and relocated for specified TLS symbols
using ELF relocations:
```
ADRP var,  R0  // R_AARCH64_TLSDESC_ADR_PAGE21
LDR [R0], R27  // R_AARCH64_TLSDESC_LD64_LO12_NC
ADD #0,R0, R0  // R_AARCH64_TLSDESC_ADD_LO12_NC
BLR (R27)      // R_AARCH64_TLSDESC_CALL
```
In PIE mode, while `TLS_IE` is optimized to `TLS_LE`
(allowing internal linking),
similar optimization for `TLS_GD` isn't supported
as `-tls=GD` isn't passed to the assembler in this mode.

