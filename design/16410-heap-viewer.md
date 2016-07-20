# Proposal: Go Heap Dump Viewer

Author(s): Michael Matloob

Last updated: 20 July 2016

Discussion at https://golang.org/issue/16410

## Abstract

This proposal is for a heap dump viewer for Go programs. This proposal will provide a
web-based, graphical viewer as well as packages for analyzing and understanding heap
dumps.

## Background

Sometimes Go programs use too much memory and the programmer wants to know why. Profiling
gives the programmer statistical information about rates of allocation, but doesn't gives
a specific concrete snapshot that can explain why a variable is live or how many
instances of a given type are live.

There currently exists a tool written by Keith Randall
that takes heap dumps produced by `runtime/debug.WriteHeapDump` and converts them into
the hprof format which can be understood by those Java heap analysis tools, but there
are some issues with the tool in its current state. First, the tool is
out of sync with the heaps dumped by Go. In addition, that tool got its type information from
data structures maintained by the GC algorithm, but as the GC has advanced, it has been
storing less and less type information over time. Because of those issues, we'll have to
make major changes to the tool or perhaps rewrite the whole thing.

Also, the process of getting a heap analysis on the screen from a running Go program involves
multiple tools and dependencies, and is more complicated than it needs to be. There should
be a simple and fast "one-click" solution to make it as easy as possible to understand
what's happening in a program's heap.

## Proposal

TODO(matloob): Some of the details are still fuzzy, but here's the general outline of a solution:

We'll use ELF core dumps as the source format for our heap analysis tools. We would build packages that would use the
debug information in the DWARF section of the dump to find the roots and reconstruct type
information for as much of the program as it can. Implementing this will likely involve improving
the DWARF data produced by the compiler.

Windows doesn't traditionally use core files, and darwin uses mach-o as its core dump format,
so we'll have to provide a mechanism for users on those platforms to extract ELF core dumps
from their programs.

We'd use those packages to build a graphical web-based tool for viewing and analyzing heap dumps.
The program would be pointed to a core dump and would serve a graphical web app that could be used
to analyze the heap.

Ideally, there will be a 'one-click' solution to get from running program to dump. One possible way
to do this would be to add a library to expose a special HTTP handler. Requesting the page would that
would trigger a core dump to a user-specified location on disk while the program's running, and start
the heap dump viewer program.

## Rationale

TODO(matloob): More through discussion.

The primary rationale for this feature is that users want to understand the memory usage of their programs
and we don't currently provide convenient ways of doing that. Adding a heap dump viewer will allow us to
do that.

### Heap dump format

There are three candidates for the format our tools will consume: the current format output by
the Go heap dumper, the hprof format, and the ELF format proposed here.

The advantage of using the current format is that we already have tools that produce it and consume it. But the format
is non-standard and requires a strong dependence between the heap viewer and the runtime. That's been one
of the problems with the current viewer. And the format produced by the runtime has changed slightly in each
of the last few Go releases because it's tightly coupled with the Go runtime.

The advantage of the hprof format is that there already exist many tools for analyzing hprof dumps.
It will be a good idea to consider this format more throughly before making a decision. On the
other hand many of those tools are neither polished nor easy to use. We can probably build
better tools tailored for Go without great effort.

The advantage of understanding ELF is that we can use the same tools to look at cores produced when a program
OOMs (at least on Linux) as we do to examine heap dumps. Another benefit is that some cluster
environments already collect and store core files when programs fail in production. Reusing this
machinery would help Go programmers in those environments. And there already exist tools that grab core dumps
so we might be able to reduce the amount of code in the runtime for producing dumps.

## Compatibility

As long as the compiler can output all necessary data needed to reconstruct type information for the heap
in the DWARF data, we won't need to have a strong dependency on the Go distribution. The code can live in a subrepo
not subject to the Go compatibility guarantee.

## Implementation

The implementation will broadly consist of three parts: First, support in the compiler and runtime for dumping
all the data needed by the viewer; second, 'backend' tools that understand the format; and third, a 'frontend'
viewer for those tools.

### Compiler and Runtime Work

TODO(matloob): more details

The compiler work will mostly be a consist of filling any holes in the DWARF data that we need to recover type
information of data in the heap.

If we decide to use ELF cores, we may need runtime support for dumping cores, especially on platforms that
don't dump cores in ELF format.

### Heap libraries and viewer

We will provide a reusable library that decodes a core file as a Go object graph with partial type information. 
Users can build their own tools based on this low-level library, but we also provide a web-based graphical tool for
viewing and querying heap graphs.

These are some of the types of queries we aim to answer with the heap viewer:
* Show a histogram of live variables grouped by typed
* Which variables account for the most memory?
* What is a path from a GC root to this variable?
* How much memory would become garbage if this variable were to become unreachable
  or this pointer to become nil?
* What are the inbound/outbound pointer edges to this node (variable)?
* How much memory is used by a variable, considering padding, alignment, and span size?

## Open issues (if applicable)

Most of this proposal is open at this point, including:
* the heap dump format
* the design and implementation of the backend packages
* the tools we use to build the frontend client.