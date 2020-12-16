# Proposal: go:wasmexport directive

Author: Francesco Guardiani

Last updated: 2020-12-17

Discussion at https://golang.org/issue/42372.

## Abstract

The goal of this proposal is to add a new compiler directive `go:wasmexport` to
export Go functions when compiling to WebAssembly.

This directive is similar to the `go:wasmimport` directive proposed in
https://golang.org/issue/38248.

## Background

Wasm is a technology that allows users to execute instructions inside virtual
machines sandboxed by default, that is the Wasm user by default cannot interact
with the external world and viceversa.

Wasm can be used in very different contexts and, recently, it's becoming more
and more used as a technology to extend, at runtime, software running outside
browsers.

In order to do that, the extensible software provides to the "extension
developers" ad-hoc libraries to develop Wasm modules.

Thanks to an ABI well-defined, the extensible software will be able to access to
the compiled Wasm module and execute the extension logic.

Some systems that adopt this extension mechanism include
[Istio](https://istio.io/latest/docs/concepts/wasm/) and
[OPA](https://www.openpolicyagent.org/docs/v0.21.1/wasm/).

In order to use Wasm modules in such environments, the developer should be able
to define which Go functions can be accessible from the outside and what host
functions can be accessible from within the Wasm module.

While the latter need is already covered and implemented by the issue
https://golang.org/issue/38248, this proposal tries to address the former need.

### An example extension module

As a complete example, assume there is a system that triggers some signals and
that can be extended to develop applications based on these signals.

The extension module is intended to be used just as "signal handler", maybe with
some lifecycle methods (e.g. start and stop) to prepare the environment and to
teardown it.

The extension module, from a host perspective, is an actor that needs to be
invoked on every this use case the module

When the host wants to start using the module, the `start` export is invoked.

`start` in its logic spawns, using the `go` instruction, a goroutine that loops
on a global channel, like:

```go
for event := range eventsch {
  // Process events
}
```

Then each export eventually push messages in this `eventsch`:

```go
eventsch <- value
```

When `process_a` export is invoked, the value will be pushed inside the
`eventsch` and the goroutine spawned by `start` will catch it.

In other words, the interaction between host and module looks like this:

![](https://user-images.githubusercontent.com/6706544/98349379-34159400-201a-11eb-8417-5d728ce141ca.png)

## Proposal

### Interface

A new directive will allow users to define what functions should be exported in
the Wasm module produced by the Go compiler. Given this code:

```go
//go:wasmexport hello_world
func HelloWorld() {
  println("Hello world!")
}
```

The compiler will produce this Wasm module:

```shell
% wasm-nm -e sample/main.wasm
e run
e resume
e getsp
e hello_world
```

Note that the first 3 exports are the default hardcoded exports of Go ABI.

### Execution

Every time the module executor (also called host) will invoke the `hello_world`
export, a new goroutine is spawned and immediately executed to run the
instructions in `HelloWorld`.

This wakes up the goroutine scheduler, which will try to run all the goroutines
up to the point when they are all parked.

When all goroutines are parked, the `hello_world` export will complete its
execution and return the return value of `HelloWorld` back to the host.

### Types

The exported function can contain in its signature (parameters and return value)
only Wasm supported types.

## Rationale

## Relation with `syscall/js.FuncOf`

The functionality of defining exports already exists in Go, through the Go JS
ABI. The cons of `syscall/js.FuncOf` are that is not idiomatic for Wasm users
and assumes that the host is a Javascript environment.

Because of the issues described above, It's complicated to support, from the
extensible system perspective, Wasm Go modules, because it requires "faking" a
Javascript environment to integrate with the Go ABI.

### Relation with Wasm threads proposal

This approach doesn't mandate any particular interaction style between host and
module, nor the underlying threading system the host uses to execute the module.

In fact, as of today, every Wasm module just assumes the underlying execution
environment, that is the virtual machine that executes Wasm instructions, as
sequential. There is no notion of parallelism.

There is a proposal in the Wasm community, called
[Wasm threads proposal](https://github.com/webassembly/threads), that allows
Wasm virtual machines to be able to process instructions in parallel.

The Go project could, at some point, evolve to support the Wasm Threads
proposal, exposing an interface to execute the goroutine scheduler on multiple
threads.

This might affect or not (depending on the future decisions) the execution model
of the export, but without effectively changing the semantics from the user
point of view, nor the interface described above.

For example, assume Go implements the goroutine scheduler on multiple Wasm
threads, from the user perspective there is no semantic difference if the export
function `hello_world` returns after all goroutines are parked or if it just
returns as soon as `HelloWorld` completes.

### Relation with Wasm interface types proposal

The
[Wasm interface types proposal](https://github.com/WebAssembly/interface-types/blob/master/proposals/interface-types/Explainer.md)
aims to provide higher level typing in Wasm modules for imports and exports.

Thanks to the _Wasm interface types_, we might be able in future to allow users
to extend the set of supported types in the imports and exports signatures.

## Compatibility

Like https://golang.org/issue/38248, the `go:wasmexport` directive will not be
covered by Go's compatibility promise as long as the Wasm architecture itself is
not considered stable.

## Implementation

The implementation involves:

1. Implement the `go:wasmexport` directive in the compiler and test the proper
   compilation to a Wasm module including the export
2. Implement the execution model of `go:wasmexport`
3. (Optional) Remove the hardcoded exports and convert them to use the
   `go:wasmexport` directive

The step (1) should look very similar to the work already done for the
`go:wasmimport` directive, available
[here](https://go-review.googlesource.com/c/go/+/252828/).

Step (2) will mostly require refactoring the runtime code already available to
implement [`syscall/js.FuncOf`](https://golang.org/pkg/syscall/js/#FuncOf) (e.g.
`runtime/rt0_js_wasm.s`), in order to generalize it to any export (and not just
the built-in ones).

Step (3) might be required or not, depending on the outcome of step (2), in
order to keep a correct implementation of the Go JS ABI, without changing its
behaviours.

## Open issues (if applicable)

- Should we allow users to control whether to execute all goroutines up to when
  they're parked or to return immediately after the exported Go function (e.g.
  `helloWorld`) completes?
