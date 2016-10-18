# Proposal: Support for pprof profiler labels

Author: Michael Matloob

Last updated: 18 October 2016

Discussion at https://golang.org/issue/17280.

## Abstract

This document proposes support for adding labels to pprof profiler records.
Labels are a key-value map that is used to distinguish calls of the same
function in different contexts when looking at profiles.

## Background

[Proposal #16093](golang.org/issue/16093) proposes to generate profiles in the
gzipped profile proto format that's now the standard format pprof expects
profiles to be in.
This format supports adding labels to profile records, but currently the Go
profiler does not produce those labels.
We propose adding a mechanism for setting profiler labels in Go.

These profiler labels are attached to profile samples, which correspond to a
snapshot of a goroutine's stack.
Because of this, we need the labels to be associated with a goroutine so that
they can be accessible at profile sampling time, which may occur during memory
allocation, lock acquisition, or in the handler for SIGPROF, an asynchronous
signal.

## Motivation

Profiles contain a limited amount of context for each sample: essentially the
call stack at the time each sample was taken.
But a user profiling their code may need additional context when debugging a
problem: Was there a particular user or RPC or other context-dependent data that
accounted for the code being executed?
This change allows users to annotate profiles with that information for more
fine-grained profiling.

It is natural to use `context.Context` types to store this information, because
their purpose is to hold context-dependent data.
So we've added the `context.DoWithLabels` function which is the intended
mechanism for users to set and unset profiler labels.

Supporting profiler labels necessarily changes the runtime package, because
that's where profiling is implemented.
The runtime package will expose the low-level `SetProfilerLabels` function
primarily for internal use by the context package.
Like the other low-level profiling functions in the runtime, ordinary programs
are not expected to call this API directly, but to use the high-level
`context.DoWithLabels` API.

One goal of the design is to avoid creating a mechanism that could be used to
implement goroutine-local storage.
That's why it's possible to set profile labels but not retrieve them.


## Proposed API

In this proposal, the following function will be added to the
[context](golang.org/pkg/context) package.

    package context

    // DoWithLabels calls f with a copy of the parent context with the
    // given labels added to the parent's label map.
    // Labels should be a slice of key-value pairs.
    // Labels are added to the label map in the order provided and override
    // any previous label with the same key.
    // The combined label map will be set for the duration of the call to f
    // and restored once f returns.
    func DoWithLabels(parent Context, labels [][2]string, f func(ctx Context))

The following types and functions will be added to the
[runtime](golang.org/pkg/runtime) package.
They exist to support the implementation of `context.DoWithLabels`.
As such, they are low level functions that should almost never be used outside
the standard library.

    package runtime

    // ProfileLabels is an immutable map of profiler labels. A nil
    // *ProfileLabels is an empty map of labels.
    // There is intentionally no way to access the profile labels contained
    // inside the ProfLabels because doing so could create a goroutine-local
    // storage mechanism.
    type ProfileLabels struct { /* runtime-internal unexported fields */ }

    // SetProfileLabels associates the specified profile
    // labels with the current goroutine.
    // SetProfileLabels returns the ProfileLabels currently set on
    // the current goroutine.
    func SetProfileLabels(labels *ProfileLabels) *ProfileLabels

    // WithLabels returns a new ProfileLabels with the given labels added.
    // A label overwrites a prior label with the same key.
    func (l *ProfileLabels) WithLabels(labels ...[2]string) *ProfileLabels

    // Labels returns a new slice containing the labels in the ProfileLabels.
    // Labels panics if called on a ProfileLabels returned by SetProfileLabels
    // or derived from one by WithLabels.
    func (l *ProfileLabels) Labels() [][2]string

### `Context` changes

Each `Context` has a set of profiler labels associated with it.
`DoWithLabels` calls `f` with a new context whose labels map is
the the parent context's labels map with the additional label arguments added.
Consider the tree of function calls during an execution of the program,
treating concurrent and deferred calls like any other.  The labels of a
function are those installed by the first call to DoWithLabels found by
walking up from that function toward the root of the tree.  Each profiler
sample records the labels of the currently executing function.

### Runtime changes

The profiler will annotate all profile samples of each goroutine by the set of
labels associated with that goroutine.

The associated set of labels will also be replaced if the user calls `SetProfileLabels` with another
`ProfileLabels` value.

New goroutines inherit the ProfileLabels value set on their creator.

## Compatibility

There are no compatibility issues with this change. The compressed binary format
emitted by the profiler already records labels (see
[proposal 16093](golang.org/issue/16093)), but the profiler does not populate
them.

## Implementation

Because `context` and `runtime` have compatible notions of profile labels,
`context.Context` can simply store a `*runtime.ProfileLabels`. Internally,
`context.Context` can extend its label set directly using `runtime.WithLabels`,
which means there's no performance penalty to using the higher-level context
API.

Initially, `runtime.ProfileLabels` may be implemented as a simple
`map[string]string` that is copied when new labels are added. However, the
specification permits more sophisticated implementations that scale to large
numbers of label changes such as persistent set structures or diff arrays. This
would allow a set of _n_ labels to be built up in at most
O(_n_ log _n_) time.

This change requires the profile signal handler to interact with pointers, which
means it has to interact with the garbage collector.
There are two complications to this:

1. This requires the profile signal handler to save a `*ProfileLabels` in the
CPU profile structure, which is allocated off-heap.
Addressing this will require either adding the CPU profile structure as a new GC
root, or allocating the CPU profile structure in the garbage-collected heap.

2. Normally, writing the `*ProfileLabels` to the CPU profile structure would
require a write barrier, but write barriers are disallowed in a signal handler.
This can be addressed by treating the CPU profile structure similar to stacks,
which also do not have write barriers.
This could mean a STW re-scan of the CPU profile structure, or shading the old
`*ProfileLabels` when `SetProfileLabels` replaces it.

