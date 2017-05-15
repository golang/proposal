# Proposal: Support for pprof profiler labels

Author: Michael Matloob

Last updated: 15 May 2017 (to reflect actual implementation)

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
their purpose is to hold context-dependent data. So the `runtime/pprof` package
API adds labels to and changes labels on opaque `context.Context` values.

Supporting profiler labels necessarily changes the runtime package, because
that's where profiling is implemented.
The `runtime` package will expose internal hooks to package `runtime/pprof` which
it uses to implement its `Context`-based API.

One goal of the design is to avoid creating a mechanism that could be used to
implement goroutine-local storage.
That's why it's possible to set profile labels but not retrieve them.


## API

The following types and functions will be added to the
[runtime/pprof](golang.org/pkg/runtime/pprof) package.

    package pprof

    // SetGoroutineLabels sets the current goroutine's labels to match ctx.
    // This is a lower-level API than Do, which should be used instead when possible.
    func SetGoroutineLabels(ctx context.Context) {
        ctxLabels, _ := ctx.Value(labelContextKey{}).(*labelMap)
        runtime_setProfLabel(unsafe.Pointer(ctxLabels))
    }

    // Do calls f with a copy of the parent context with the
    // given labels added to the parent's label map.
    // Each key/value pair in labels is inserted into the label map in the
    // order provided, overriding any previous value for the same key.
    // The augmented label map will be set for the duration of the call to f
    // and restored once f returns.
    func Do(ctx context.Context, labels LabelSet, f func(context.Context)) {
        defer SetGoroutineLabels(ctx)
        ctx = WithLabels(ctx, labels)
        SetGoroutineLabels(ctx)
        f(ctx)
    }

    // LabelSet is a set of labels.
    type LabelSet struct {
        list []label
    }

    // Labels takes an even number of strings representing key-value pairs
    // and makes a LabelList containing them.
    // A label overwrites a prior label with the same key.
    func Labels(args ...string) LabelSet {
        if len(args)%2 != 0 {
            panic("uneven number of arguments to pprof.Labels")
        }
        labels := LabelSet{}
        for i := 0; i+1 < len(args); i += 2 {
            labels.list = append(labels.list, label{key: args[i], value: args[i+1]})
        }
        return labels
    }

    // Label returns the value of the label with the given key on ctx, and a boolean indicating
    // whether that label exists.
    func Label(ctx context.Context, key string) (string, bool) {
        ctxLabels := labelValue(ctx)
        v, ok := ctxLabels[key]
        return v, ok
    }

    // ForLabels invokes f with each label set on the context.
    // The function f should return true to continue iteration or false to stop iteration early.
    func ForLabels(ctx context.Context, f func(key, value string) bool) {
        ctxLabels := labelValue(ctx)
        for k, v := range ctxLabels {
            if !f(k, v) {
                break
            }
        }
    }

### `Context` changes

Each `Context` may have a set of profiler labels associated with it.
`Do` calls `f` with a new context whose labels map is
the the parent context's labels map with the additional label arguments added.
Consider the tree of function calls during an execution of the program,
treating concurrent and deferred calls like any other.  The labels of a
function are those installed by the first call to DoWithLabels found by
walking up from that function toward the root of the tree.  Each profiler
sample records the labels of the currently executing function.

### Runtime changes

The profiler will annotate all profile samples of each goroutine by the set of
labels associated with that goroutine.

Two hooks in the runtime, `func runtime_setProfLabel(labels unsafe.Pointer)` and
`func runtime_getProfLabel() unsafe.Pointer` are linknamed
into `runtime/pprof` and are used for setting and getting profile labels from the
current goroutine. These functions are only accessible from `runtime/pprof`, which
prevents them from being misused to implement a Goroutine-local storage facility.
The profile label implementation structure is left opaque to the runtime.

`runtime.CPUProfile` is deprecated. `runtime_pprof_readProfile`,
another runtime function linknamed into `runtime/pprof`, is added as a way for `runtime/pprof` to retrieve the raw label-annotated profile data.

New goroutines inherit the labels set on their creator.

## Compatibility

There are no compatibility issues with this change. The compressed binary format
emitted by the profiler already records labels (see
[proposal 16093](golang.org/issue/16093)), but the profiler does not populate
them.

## Implementation

`context.Context` will have an internal label set representation associated with it.
This leaves the option open to change the implementation in the future to improve
the performance characteristics of using profiler labels.

The initial implementation of the label set is a
`map[string]string` that is copied when new labels are added. However, the
specification permits more sophisticated implementations that scale to large
numbers of label changes such as persistent set structures or diff arrays. This
would allow a set of _n_ labels to be built up in at most
O(_n_ log _n_) time.

This change requires the profile signal handler to interact with pointers, which
means it has to interact with the garbage collector.
There are two complications to this:

1. This requires the profile signal handler to save the label set structure in the
CPU profile structure, which is allocated off-heap.
Addressing this will require either adding the CPU profile structure as a new GC
root, or allocating the CPU profile structure in the garbage-collected heap.

2. Normally, writing the label set structure to the CPU profile structure would
require a write barrier, but write barriers are disallowed in a signal handler.
This can be addressed by treating the CPU profile structure similar to stacks,
which also do not have write barriers.
This could mean a STW re-scan of the CPU profile structure, or shading the old
label set structure when `SetGoroutineLabels` replaces it.

