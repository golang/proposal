# Go 1.3 Linker Overhaul

Russ Cox \
November 2013 \
golang.org/s/go13linker

## Abstract

The linker is one of the slowest parts of building and running a typical Go program. To address this, we plan to split the linker into two pieces. Perhaps one can be written in Go.

[**Update, 2023.** This plan was originally published as a Google document. For easier access, it was converted to Markdown in this repository in 2023. Later work overhauled the linker a second time, greatly improving its structure, efficiency, and code quality. This document has only minor historical value now.]

## Background

The linker has always been the slowest part of the Plan 9 toolchain, and it is now the slowest part of the Go toolchain. Ken Thompson’s [overview of the toolchain](http://plan9.bell-labs.com/sys/doc/compiler.html) concludes:

> The new compilers compile quickly, load slowly, and produce medium quality object code. The compilers are relatively portable, requiring but a couple of weeks’ work to produce a compiler for a different computer. For Plan 9, where we needed several compilers with specialized features and our own object formats, this project was indispensable. It is also necessary for us to be able to freely distribute our compilers with the Plan 9 distribution.
>
> Two problems have come up in retrospect. The first has to do with the division of labor between compiler and loader. Plan 9 runs on multi-processors and as such compilations are often done in parallel. Unfortunately, all compilations must be complete before loading can begin. The load is then single-threaded. With this model, any shift of work from compile to load results in a significant increase in real time. The same is true of libraries that are compiled infrequently and loaded often. In the future, we may try to put some of the loader work back into the compiler.

That document was written in the early 1990s. The future is here.

## Proposed Plan

The current linker performs two separable tasks. First, it translates an input stream of pseudo-instructions into executable code and data blocks, along with a list of relocations. Second, it deletes dead code, merges what’s left into a single image, resolves relocations, and generates a few whole-program data structures such as the [runtime symbol table](http://golang.org/s/go12symtab).

The first part can be factored out into a library - liblink - that can be linked into the assemblers and compilers. The object files written by 6a, 6c, or 6g and so on would be written by liblink and then contain executable code and data blocks and relocations, the result of the first half of the current linker.

The second part can be handled by what’s left of the linker after extracting liblink. That remaining program which would read the new object files and complete the link. That linker is a small amount of code, the bulk of it architecture-independent. It is possible that it could be merged into a single architecture-independent program invoked as “go tool ld”. It is even possible that it could be rewritten in Go, making it easy to parallelize large links. (See the section below for how to bootstrap.)

To start, we will focus on getting the new split working with C code. The exploration of using Go will happen only once the rest of the change is done.

To avoid churn in the usage of the tools, the generated object files will keep the existing suffixes .5, .6, .8. Perhaps in Go 1.3 we will even include shim programs named 5l, 6l, and 8l that invoke the new linker. These shim programs would be retired in Go 1.4.

## Object Files

The new split requires a new object file format. The current objects contain pseudo-instruction streams, but the new objects will contain executable code and data blocks along with relocations.

A natural question is whether we should adopt an existing object file format, such as ELF. At first, we will use a custom format. A Go-specific linker is required to build runtime data structures like the symbol table, so even if we used ELF object files we could not reuse a standard ELF linker. ELF files are also considerably more general and ELF semantics considerably more complex than the Go-specific linker needs. A custom, less general object file format should be simpler to generate and simpler to consume. On the other hand, ELF can be processed by standard tools like readelf, objdump, and so on. Once the dust has settled, though, and we know exactly what we need from the format, it is worth looking at whether the use of ELF makes sense.

The details of the new object file are not yet worked out. The rest of this section lists some design considerations.

 - Obviously the files should be as simple as possible. With few exceptions, anything that can be done in the library half of the linker should be. Possible surprises include the stack split code being done in the library half, which makes object files OS-specific, although they already are due to OS-specific Go code in packages, and the software floating point work being done in the library half, making ARM object files GOARM-specific (today nothing GOARM-specific is done until the linker runs).
 - We should make sure that object files are usable via mmap. This would reduce copying during I/O. It may require changing the Go runtime to simply panic, not crash, on SIGSEGV on non-nil addresses.
 - Pure Go packages consist of a single object file generated by invoking the Go compiler once on the complete set of Go source files. That object file is then wrapped in an archive. We should arrange that a single object file is also a valid archive file, so that in that common case there is no wrapping step needed.

## Bootstrapping

If the new Go linker is written in Go, there is a bootstrapping problem: how do you link the linker? There are two approaches.

The first approach is to maintain a bootstrap list of CLs. The first CL in the sequence would have the current linker, written in C. Each subsequent step would be a CL containing a new linker that can be linked using the previous linker. The final binaries resulting from the sequence can be made available for download. The sequence need not be too long and could be made to coincide with milestones. For example, we could arrange that the Go 1.3 linker can be compiled as a Go 1.2 program, the Go 1.4 linker can be compiled as a Go 1.3 program, and so on. The recorded sequence makes it possible to re-bootstrap if needed but also provides a way to defend against the [Trusting Trust problem](http://cm.bell-labs.com/who/ken/trust.html). Another way to bootstrap would be to compile gccgo and use it to build the Go 1.3 linker.

The second approach is to keep the C linker even after we have a better one written in Go, and to keep both mostly feature-equivalent. The version written in C only needs to keep enough features to link the one written in Go. It needs to pick up some object files, merge them, and write out an executable. There’s no need for cgo support, no need for external linking, no need for shared libraries, no need for performance. It should be a relatively modest amount of code (perhaps just a few thousand lines) and should not need to change very often. The C version would be built and used during make.bash but not installed. This approach is easier for other developers building Go from source.

It doesn’t matter much which approach we take, just that there is at least one viable approach. We can decide once things are further along.
