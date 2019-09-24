# Proposal: Low-cost defers through inline code, and extra funcdata to manage the panic case

Author(s): Dan Scales, Keith Randall, and Austin Clements
(with input from many others, including Russ Cox and Cherry Zhang)

Last updated: 2019-09-23

Discussion at https://golang.org/issue/34481

General defer performance discussion at https://golang.org/issue/14939.

## Abstract

As of Go 1.13, most `defer` operations take about 35ns (reduced from about 50ns
in Go 1.12).
In contrast, a direct call takes about 6ns.
This gap incentivizes engineers to eliminate `defer` operations from hot code
paths, which takes away time from more productive tasks, leads to less
maintainable code (e.g., if a `panic` is later introduced, the "optimization" is
no longer correct), and discourages people from using a language feature when it
would otherwise be an appropriate solution to a problem.

We propose a way to make most `defer` calls no more expensive than open-coding the
call, hence eliminating the incentives to shy away from using this language
feature to its fullest extent.


## Background

Go 1.13 implements the `defer` statement by calling into the runtime to push a
"defer object" onto the defer chain.
Then, in any function that contains `defer` statements, the compiler inserts a
call to `runtime.deferreturn` at every function exit point to unwind that
function's defers.
Both of these cause overhead: the defer object must be populated with function
call information (function pointer, arguments, closure information, etc.) when
it is added to the chain, and `deferreturn` must find the right defers to
unwind, copy out the call information, and invoke the deferred calls.
Furthermore, this inhibits compiler optimizations like inlining, since the defer
functions are called from the runtime using the defer information.

When a function panics, the runtime runs the deferred calls on the defer chain
until one of these calls `recover` or it exhausts the chain, resulting in a
fatal panic.
The stack itself is *not* unwound unless a deferred call recovers.
This has the important property that examining the stack from a deferred call
run during a panic will include the panicking frame, even if the defer was
pushed by an ancestor of the panicking frame.

In general, this defer chain is necessary since a function can defer an
unbounded or dynamic number of calls that must all run when it returns.
For example, a `defer` statement can appear in a loop or an `if` block.
This also means that, in general, the defer objects must be heap-allocated,
though the runtime uses an allocation pool to reduce the cost of the allocation.

This is notably different from exception handling in C++ or Java, where the
applicable set of `except` or `finally` blocks can be determined statically at
every program counter in a function.
In these languages, the non-exception case is typically inlined and exception
handling is driven by a side table giving the locations of the `except` and
`finally` blocks that apply to each PC.

However, while Go's `defer` mechanism permits unbounded calls, the vast majority
of functions that use `defer` invoke each `defer` statement at most once, and do
not invoke `defer` in a loop.
Go 1.13 adds an [optimization](https://golang.org/cl/171758) to stack-allocate
defer objects in this case, but they must still be pushed and popped from the
defer chain.
This applies to 363 out of the 370 static defer sites in the `cmd/go` binary and
speeds up this case by 30% relative to heap-allocated defer objects.

This proposal combines this insight with the insights used in C++ and Java to
make the non-panic case of most `defer` operations no more expensive than the
manually open-coded case, while retaining correct `panic` handling.


## Requirements

While the common case of defer handling is simple enough, it can interact in
often non-obvious ways with things like recursive panics, recover, and stack
traces.
Here we attempt to enumerate the requirements that any new defer implementation
should likely satisfy, in addition to those in the language specification for
[Defer statements](https://golang.org/ref/spec#Defer_statements) and [Handling
panics](https://golang.org/ref/spec#Handling_panics).

1. Executing a `defer` statement logically pushes a deferred function call onto
   a per-goroutine stack.
   Deferred calls are always executed starting from the top of this stack (hence
   in the reverse order of the execution of `defer` statements).
   Furthermore, each execution of a `defer` statement corresponds to exactly one
   deferred call (except in the case of program termination, where a deferred
   function may not be called at all).

2. Defer calls are executed in one of two ways.
   Whenever a function call returns normally, the runtime starts popping and
   executing all existing defer calls for that stack frame only (in reverse order
   of original execution).
   Separately, whenever a panic (or a call to Goexit) occurs, the runtime starts
   popping and executing all existing defer calls for the entire defer stack.
   The execution of any defer call may be interrupted by a panic within the
   execution of the defer call.

3. A program may have multiple outstanding panics, since a recursive (second)
   panic may occur during any of the defer calls being executed during the
   processing of the first panic.
   A previous panic is “aborted” if the processing of defers by the new panic
   reaches the frame where the previous panic was processing defers when the new
   panic happened.
   When a defer call returns that did a successful `recover` that applies to a
   panic, the stack is immediately unwound to the frame which contains the defer
   that did the recover call, and any remaining defers in that frame are
   executed.
   Normal execution continues in the preceding frame (but note that normal
   execution may actually be continuing a defer call for an outer panic).
   Any panic that has not been recovered or aborted must still appear on the
   caller stack.
   Note that the first panic may never continue its defer processing, if the
   second panic actually successfully runs all defer calls, but the original
   panic must appear on the stack during all the processing by the second panic.

4. When a defer call is executed because a function is returning normally
   (whether there are any outstanding panics or not), the call site of a
   deferred call must appear to be the function that invoked `defer` to push
   that function on the defer stack, at the line where that function is
   returning.
   A consequence of this is that, if the runtime is executing deferred calls in
   panic mode and a deferred call recovers, it must unwind the stack immediately
   after that deferred call returns and before executing another deferred call.

5. When a defer call is executed because of an explicit panic, the call stack of
   a deferred function must include `runtime.gopanic` and the frame that
   panicked (and its callers) immediately below the deferred function call.
   As mentioned, the call stack must also include any outstanding previous
   panics.
   If a defer call is executed because of a run-time panic, the same condition
   applies, except that `runtime.gopanic` does not necessarily need to be on the
   stack.
   (In the current gc-go implementation, `runtime.gopanic` does appear on
   the stack even for run-time panics.)

## Proposal

We propose optimizing deferred calls in functions where every `defer` is
executed at most once (specifically, a `defer` may be on a conditional path, but
is never in a loop in the control-flow graph).
In this optimization, the compiler assigns a bit for every `defer` site to
indicate whether that defer had been reached or not.
The `defer` statement itself simply sets the corresponding bit and stores all
necessary arguments in specific stack slots.
Then, at every exit point of the function, the compiler open-codes each deferred
call, protected by (and clearing) each corresponding bit.

For example, the following:

```go
defer f1(a)
if cond {
 defer f2(b)
}
body...
```

would compile to

```go
deferBits |= 1<<0
tmpF1 = f1
tmpA = a
if cond {
 deferBits |= 1<<1
 tmpF2 = f2
 tmpB = b
}
body...
exit:
if deferBits & 1<<1 != 0 {
 deferBits &^= 1<<1
 tmpF2(tmpB)
}
if deferBits & 1<<0 != 0 {
 deferBits &^= 1<<0
 tmpF1(tmpA)
}
```

In order to ensure that the value of `deferBits` and all the tmp variables are
available in case of a panic, these variables must be allocated explicit stack
slots and the stores to deferBits and the tmp variables (`tmpF1`, `tmpA`, etc.)
must write the values into these stack slots.
In addition, the updates to `deferBits` in the defer exit code must explicitly
store the `deferBits` value to the corresponding stack slot.
This will ensure that panic processing can determine exactly which defers have
been executed so far.

However, the defer exit code can still be optimized significantly in many cases.
We can refer directly to the `deferBits` and tmpA ‘values’ (in the SSA sense),
and these accesses can therefore be optimized in terms of using existing values
in registers, propagating constants, etc.
Also, if the defers were called unconditionally, then constant propagation may
in some cases to eliminate the checks on `deferBits` (because the value of
`deferBits` is known statically at the exit point).

If there are multiple exits (returns) from the function, we can either duplicate
the defer exit code at each exit, or we can have one copy of the defer exit code
that is shared among all (or most) of the exits.
Note that any sharing of defer-exit code code may lead to less specific line
numbers (which don’t indicate the exact exit location) if the user happens to
look at the call stack while in a call made by the defer exit code.

For any function that contains a defer which could be executed more than once
(e.g. occurs in a loop), we will fall back to the current way of handling
defers.
That is, we will create a defer object at each defer statement and push it on to
the defer chain.
At function exit, we will call deferreturn to execute an active defer objects
for that function.
We may similarly revert to the defer chain implementation if there are too many
defers or too many function exits.
Our goal is to optimize the common cases where current defers overheads show up,
which is typically in small functions with only a small number of defers
statements.

## Panic processing

Because no actual defer records have been created, panic processing is quite
different and somewhat more complex in the open-coded approach.
When generating the code for a function, the compiler also emits an extra set of
`FUNCDATA` information that records information about each of the open-coded
defers.
For each open-coded defer, the compiler emits `FUNCDATA` that specifies the
exact stack locations that store the function pointer and each of the arguments.
It also emits the location of the stack slot containing `deferBits`.
Since stack frames can get arbitrarily large, the compiler uses a varint
encoding for the stack slot offsets.

In addition, for all functions with open-coded defers, the compiler adds a small
segment of code that does a call to `runtime.deferreturn` and then returns.
This code segment is not reachable by the main code of the function, but is used
to unwind the stack properly when a panic is successfully recovered.

To handle a `panic`, the runtime conceptually walks the defer chain in parallel
with the stack in order to interleave execution of pushed defers with defers in
open-coded frames.
When the runtime encounters an open-coded frame `F` executing function `f`, it
executes the following steps.

1. The runtime reads the funcdata for function `f` that contains the open-defer
   information.

2. Using the information about the location in frame `F` of the stack slot for
   `deferBits`, the runtime loads the current value of `deferBits` for this
   frame.
   The runtime processes each of the active defers, as specified by the value of
   `deferBits`, in reverse order.

3. For each active defer, the runtime loads the function pointer for the defer
   call from the appropriate stack slot.
   It also builds up an argument frame by copying each of the defer arguments
   from its specified stack slot to the appropriate location in the argument
   frame.
   It then updates `deferBits` in its stack slot after masking off the bit for
   the current defer.
   Then it uses the function pointer and argument frame to call the deferred
   function.

4. If the defer call returns normally without doing a recovery, then the runtime
   continues executing active defer calls for frame F until all active defer
   calls have finished.

5. If any defer call returns normally but has done a successful recover, then
   the runtime stops processing defers in the current frame.
   There may or may not be any remaining defers to process.
   The runtime then arranges to jump to the `deferreturn` code segment and
   unwind the stack to frame `F`, by simultaneously setting the PC to the
   address of the `deferreturn` segment and setting the SP to the appropriate
   value for frame `F`.
   The `deferreturn` code segment then calls back into the runtime.
   The runtime can now process any remaining active defers from frame `F`.
   But for these defers, the stack has been appropriately unwound and the defer
   appears to be called directly from function `f`.
   When all defers for the frame have finished, the deferreturn finishes and the
   code segment returns from frame F to continue execution.

If a deferred call in step 3 itself panics, the runtime starts its normal panic
processing again.
For any frame with open-coded defers that has already run some defers, the
deferBits value at the specified stack slot will always accurately reflect the
remaining defers that need to be run.

The processing for `runtime.Goexit` is similar.
The main difference is that there is no panic happening, so there is no need to
check for or do special handling for recovery in `runtime.Goexit`.
A panic could happen while running defer functions for `runtime.Goexit`, but
that will be handled in `runtime.gopanic`.

## Rationale

One other approach that we extensively considered (and prototyped) also has
inlined defer code for the normal case, but actual executes the defer exit code
directly even in the panic case.
Executing the defer exit code in the panic case requires duplication of stack
frame F and some complex runtime code to start execution of the defer exit code
using this new duplicated frame and to regain control when the defer exit code
complete.
The required runtime code for this approach is much more architecture-dependent
and seems to be much more complex (and possibly fragile).


## Compatibility

This proposal does not change any user-facing APIs, and hence satisfies the [compatibility
guidelines](https://golang.org/doc/go1compat).

## Implementation

An implementation has been mostly done.
The change is [here](https://go-review.googlesource.com/c/go/+/190098/6).
Comments on the design or implementation are very welcome.

Some miscellaneous implementation details:

1. We need to restrict the number of defers in a function to the size of the
   deferBits bitmask.
   To minimize code size, we currently make deferBits to be 8 bits, and don’t do
   open-coded defers if there are more than 8 defers in a function.
   If there are more than 8 defers in a function, we revert to the standard
   defer chain implementation.

2. The deferBits variable and defer arguments variables (such as `tmpA`) must be
   declared (via `OpVarDef`) in the entry block, since the unconditional defer
   exit code at the bottom of the function will access them, so these variables
   are live throughout the entire function.
   (And, of course, they can be accessed by panic processing at any point within
   the function that might cause a panic.)
   For any defer argument stack slots that are pointers (or contain pointers),
   we must initialize those stack slots to zero in the entry block.
   The initialization is required for garbage collection, which doesn’t know
   which of these defer arguments are active (i.e. which of the defer sites have
   been reached, but the corresponding defer call has not yet happened)

3. Because the `deferreturn` code segment is disconnected from the rest of the
   function, it would not normally indicate that any stack slots are live.
   However, we want the liveness information at the `deferreturn` call to
   indicate that all of the stack slots associated with defers (which may
   include pointers to variables accessed by closures) and all of the return
   values are live.
   We must explicitly set the liveness for the `deferreturn` call to be the same
   as the liveness at the first defer call on the defer exit path.
