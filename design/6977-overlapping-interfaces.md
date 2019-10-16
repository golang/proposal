# Proposal: Permit embedding of interfaces with overlapping method sets

Author: Robert Griesemer

Last update: 2019-10-16

Discussion at [golang.org/issue/6977](https://golang.org/issue/6977).

## Summary

We propose to change the language spec such that embedded interfaces may have overlapping method sets.

## Background

An interface specifies a [method set](https://golang.org/ref/spec#Method_sets). One constraint on method sets is that when specifying an interface, each interface method must have a [unique](https://golang.org/ref/spec#Uniqueness_of_identifiers) non-[blank](https://golang.org/ref/spec#Blank_identifier) name.

For methods that are _explicitly_ declared in the interface, this constraint has served us well. There is little reason to explicitly declare the same method more than once in an interface; doing so is at best confusing and likely a typo or copy-paste bug.

But it is easy for multiple embedded interfaces to declare the same method. For example, we might want to (but cannot today) write:

```Go
	type ReadWriteCloser interface {
		io.ReadCloser
		io.WriteCloser
	}
```

This phrasing is invalid Go because it adds the same `Close` method to the interface twice, breaking the uniqueness constraint.

Definitions in which embedding breaks the uniqueness constraint arise naturally for various reasons, including embedded interfaces not under programmer control, diamond-shaped interface embeddings, and other valid design choices; see the discussion below and [issue #6977](http://golang.org/issue/6977) for examples. In general it may not be possible or reasonable to ensure that embedded interfaces do not have overlapping method sets. Today, the only recourse in this situation is to fall back to spelling out the interfaces one method at a time, creating duplication and potential for drift between definitions.

Allowing methods contributed by embedded interfaces to duplicate other methods in the interface would make these natural definitions valid Go, with no runtime implication and only trivial compiler changes.

## Proposal

Currently, in the section on [Interface types](https://golang.org/ref/spec#Interface_types), the language specification states:

> An interface `T` may use a (possibly qualified) interface type name `E` in place of a method specification. This is called _embedding_ interface `E` in `T`; it adds all (exported and non-exported) methods of `E` to the interface `T`.

We propose to change this to:

> An interface `T` may use a (possibly qualified) interface type name `E` in place of a method specification. This is called _embedding_ interface `E` in `T`. The method set of  `T` is the _union_ of the method sets of `T`’s explicitly declared methods and of `T`’s embedded interfaces.

And to add the following paragraph:

> A _union_ of method sets contains the (exported and non-exported) methods of each method set exactly once, and methods with the same names must have identical signatures.

Alternatively, this new paragraph could be added to the section on [Method sets](https://golang.org/ref/spec#Method_sets).

## Examples

As before, it will not be permitted to _explicitly_ declare the same method multiple times:

```Go
type I interface {
	m()
	m()  // invalid; m was already explicitly declared
}
```

The current spec permits multiple embeddings of an _empty_ interface:

```Go
type E interface {}
type I interface { E; E }  // always been valid
```

With this proposal, multiple embeddings of the same interface is generalized to _any_ (not just the empty) interface:

```Go
type E interface { m() }
type I interface { E; E }  // becomes valid with this proposal
```

If different embedded interfaces provide a method with the same name, their signatures must match, otherwise the embedding interface is invalid:

```Go
type E1 interface { m(x int) bool }
type E2 interface { m(x float32) bool }
type I  interface { E1; E2 }  // invalid since E1.m and E2.m have the same name but different signatures
```

## Discussion

A more restricted approach might disallow embedded interfaces from overlapping with the method set defined by the explicitly declared methods of the embedding interface since it is always possible to not declare those “extra” methods. Or in other words, one can always remove explicitly declared methods if they are added via an embedded interface. We believe that would make this language change less robust. For example, consider a hypothetical database API for holding personnel data. A person’s record might be accessible through an interface:

```Go
type Person interface {
	Name() string
	Age() int
	...
}
```

A client might have a more specific implementation storing employees, which are also Persons:

```Go
type Employee interface {
	Person
	Level() int
	…
	String() string
}
```

An Employee happens to have a `String` method to ease debugging. If the underlying DB API changes and somebody adds a `String` method to Person, the Employee interface would become invalid, because now `String` would be a duplicated method in `Employee`. To make it work again, one would have to remove the `String` method from the `Employee` interface.

Changing the language to ignore duplicated methods that arise from embedding enables more graceful code evolution (in this case, `Person` adding a String method without breaking `Employee`).

Permitting method sets to overlap with the embedding interface is also a bit simpler to describe in the spec, which helps with keeping the added complexity small.

In summary, we believe that allowing interfaces to have overlapping method sets removes a pain point for many programmers without adding undue complexity to the language and at a minor cost in the implementation.

## Compatibility

This is a backward-compatible language change; any valid existing program will remain valid. This proposal simply expands the set of interfaces that may be embedded in another interface.

## Implementation

The implementation requires:

- Adjusting the compiler’s type-checker to allow overlapping embedded interfaces.
- Adjusting `go/types` analogously.
- Adjusting the Go spec as outlined earlier.
- Adjusting gccgo accordingly (type-checker).
- Testing the changes by adding new tests.

No library changes are required. In particular, reflect only allows listing the methods in an interface; it does not expose information about embedding or other details of the interface definition.

Robert Griesemer will do the spec and `go/types` changes including additional tests, and (probably) also the `cmd/compile` compiler changes. We aim to have all the changes ready at the start of the [Go 1.14 cycle](https://golang.org/wiki/Go-Release-Cycle), around August 1, 2019.

Separately, Ian Lance Taylor will look into the gccgo changes, which is released according to a different schedule.

As noted in our [“Go 2, here we come!” blog post](https://blog.golang.org/go2-here-we-come), the development cycle will serve as a way to collect experience about these new features and feedback from (very) early adopters.

At the release freeze, November 1, we will revisit this proposed feature and decide whether to include it in Go 1.14.

**Update**: These changes were implemented around the beginning of August 2019. The [`cmd/compile` compiler changes](https://golang.org/cl/187519) were done by Matthew Dempsky and turned out to be small. The [`go/types` changes](https://golang.org/cl/191257) required a rewrite of the way type checking of interfaces was implemented because the old code was not easily adjustable to the new semantics. That rewrite led to a significant simplification with a code savings of approx. 400 lines. This proposal forced the rewrite, but the proposal was not the reason for the code savings; the rewrite would have been beneficial either way. (Had the rewrite been done before and independently of this proposal, the change required would have been as small as it was for `cmd/compile` since the relevant code in `go/types` and the compiler closely corresponds.)

## Apendix: A typical example

Below is [an example](https://golang.org/issues/6977#issuecomment-218985935) by [Hasty Granbery](https://github.com/hasty); this example is representative for a common situation - diamond shaped embedding graphs - where people run into problems with the status quo. A few more examples can be found in [issue 6977](https://golang.org/issue/6977). 

In this specific scenario, various different database APIs are defined via interfaces to fully hide the implementation and to simplify testing (it's easy to install a mock implementation in the interface). A typical interface might be:

```Go
package user

type Database interface {
    GetAccount(accountID uint64) (model.Account, error)
}
```

A few other packages may want to be able to fetch accounts under some circumstances, so they require their databases to have all of `user.Database`'s methods:

```Go
package device

type Database interface {
    user.Database
    SaveDevice(accountID uint64, device model.Device) error
}
```

```Go
package wallet

type Database interface {
    user.Database
    ReadWallet(accountID uint64) (model.Wallet, error)
}
```

Finally, there is a package that needs both the `device` and `wallet` `Database`:

```Go
package shopping

type Database interface {
    device.Database
    wallet.Database
    Buy(accountID uint64, deviceID uint64) error
}
```

Since both `device.Database` and `wallet.Database` have the `GetAccount` method, `shopping.Database` is invalid with the current spec. If this proposal is accepted, this code will become valid.
