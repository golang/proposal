# Proposal: Ignore tags in struct type conversions

Author: [Robert Griesemer](gri@golang.org)

Created: June 16, 2016

Last updated: June 16, 2016

Discussion at [issue 16085](https://golang.org/issue/16085)

## Abstract

This document proposes to relax struct conversions such that struct tags are
ignored.
An alternative to the proposal is to add a new function reflect.StructCopy
that could be used instead.

## Background

The [spec](https://codereview.appspot.com/1698043) and corresponding
[implementation change](https://golang.org/cl/1667048) submitted almost
exactly six years ago made [struct tags](https://golang.org/ref/spec#Struct_types)
an integral part of a struct type by including them in the definition of struct
[type identity](https://golang.org/ref/spec#Type_identity) and indirectly in
struct [type conversions](https://golang.org/ref/spec#Conversions).

In retrospect, this change may have been overly restrictive with respect to
its impact on struct conversions, given the way struct tag use has evolved
over the years.
A common scenario is the conversion of struct data coming from, say a database,
to an _equivalent_ (identical but for its tags) struct that can be JSON-encoded,
with the JSON encoding defined by the respective struct tags.
For an example of such a type, see
https://github.com/golang/text/blob/master/unicode/cldr/xml.go#L6.

The way struct conversions are defined, it is not currently possible to convert
a value from one struct type to an equivalent one.
Instead, every field must be copied manually, which leads to more source text,
and less readable and possibly less efficient code.
The code must also be adjusted every time the involved struct types change.

[Issue 6858](https://github.com/golang/go/issues/6858) discusses this in more detail.
rsc@golang and r@golang suggest that we might be able to relax the rules for
structs such that struct tags are ignored for conversions, but not for struct
identity.

## Proposal

The spec states a set of rules for conversions.
The following rules apply to conversions of struct values (among others):

A non-constant value x can be converted to type T if:
- x's type and T have identical underlying types
- x's type and T are unnamed pointer types and their pointer base types have identical underlying types

The proposal is to change these two rules to:

A non-constant value x can be converted to type T if:
- x's type and T have identical underlying types _if struct tags are ignored (recursively)_
- x's type and T are unnamed pointer types and their pointer base types have identical underlying types _if struct tags are ignored (recursively)_

Additionally, package reflect is adjusted (Type.ConvertibleTo, Value.Convert)
to match this language change.

In other words, type identity of structs remains unchanged, but for the purpose
of struct conversions, type identity is relaxed such that struct tags are
ignored.

## Compatibility and impact

This is is a backward-compatible language change since it loosens an existing
restriction:
Any existing code will continue to compile with the same meaning (*), and some
code that currently is invalid will become valid.

Programs that manually copy all fields from one struct to another struct with
identical type but for the (type name and) tags, will be able to use a single
struct conversion instead.

More importantly, with this change two different (type) views of the same
struct value become possible via pointers of different types.
For instance, given:

	type jsonPerson struct {
		name `json:"name"`
	}

	type xmlPerson struct {
		name `xml:"name"`
	}

we will be able to access a value of *jsonPerson type

	person := new(jsonPerson)
	// some code that populates person

as an *xmlPerson:

	alias := (*xmlPerson)(person)
	// some code that uses alias

This may eliminate the need to copy struct values just to change the tags.

Type identity and conversion tests are also available programmatically, via
the reflect package.
The operations of Type.ConvertibleTo and Value.Convert will be relaxed for
structs with different (or absent) tags:

Type.ConvertibleTo will return true for some arguments where it currently
returns false.
This may change the behavior of programs depending on this method.

Value.Convert will convert struct values for which the operation panicked
before.
This will only affect programs that relied on (recovered from) that panic.

(*) r@golang points out that a program that is using tags to prevent
(accidental or deliberate) struct conversion would lose that mechanism.
Interestingly, package reflect appears to make such use (see type rtype),
but iant@golang points out that one could obtain the same effect by adding
differently typed zero-sized fields to the respective structs.

## Discussion

From a language spec point of view, changing struct type identity (rather
than struct conversions only) superficially looks like a simpler, cleaner,
and more consistent change: For one, it simplifies the spec, while only
changing struct conversions requires adding an additional rule.

iant@golang points out (https://github.com/golang/go/issues/11661) that
leaving struct identity in place doesn’t make much difference in practice:
It is already impossible to assign or implicitly convert between two
differently named struct types.
Unnamed structs are rare, and if accidental conversion is an issue, one can
always introduce a named struct.

On the other hand, runtime type descriptors (used by reflect.Type, interfaces,
etc) are canonical, so identical types have the same type descriptor.
The descriptor provides struct field tags, so identical types must have
identical tags.
Thus we cannot at this stage separate struct field tags from the notion of
type identity.

To summarize: Relaxing struct conversions only but leaving struct type
identity unchanged is sufficient to enable one kind of data conversion
that is currently overly tedious, and it doesn’t require larger and more
fundamental changes to the run time.
The change may cause a hopefully very small set of programs, which depend
on package reflect’s conversion-related API, to behave differently.

## Open question

Should tags be ignored at the top-level of a struct only, or recursively
all the way down?
For instance, given:

```
type T1 struct {
	x int
	p *struct {
		name string `foo`
	}
}

type T2 struct {
	x int
	p *struct {
		name string `bar`
	}
}

var t1 T1
```

Should the conversion T2(t1) be legal? If tags are only ignored for the
fields of T1 and T2, conversion is not permitted since the tags attached
to the type of the p field are different.
Alternatively, if tags are ignored recursively, conversion is permitted.

On the other hand, if the types were defined as:

```
type T1 struct {
	x int
	p *P1
}

type T2 struct {
	x int
	p *P2
}

```
where P1 and P2 are identical structs but for their tags, the conversion
would not be permitted either way since the p fields have different types
and thus T1 and T2 have different underlying types.

The proposal suggests to ignore tags recursively, “all the way down”.
This seems to be the more sensible approach given the stated goal, which
is to make it easier to convert from one struct type to another, equivalent
type with different tags.
For an example where this matters, see https://play.golang.org/p/U73K50YXYk.

Furthermore, it is always possible to prevent unwanted conversions by
introducing named types, but it would not be possible to enable those
conversions otherwise.

On the other hand, the current implementation of reflect.Value.Convert
will make recursive ignoring of struct tags more complicated and expensive.
crawshaw@golang points out that one could easily use a cache inside the
reflect package if necessary for performance.

## Implementation

An (almost) complete implementation is in https://golang.org/cl/24190/;
with a few pieces missing for the reflect package change.

## Alternatives to the language change

Even a backward-compatible language change needs to meet a high bar before
it can be considered.
It is not yet clear that this proposal satisfies that criteria.

One alternative is to do nothing.
That has the advantage of not breaking anything and also doesn’t require
any implementation effort on the language/library side.
But it means that in some cases structs have to be explicitly converted
through field-by-field assignment.

Another alternative that actually addresses the problem is to provide a
library function.
For instance, package reflect could provide a new function

```
func CopyStruct(dst, src Value, mode Mode)
```

which could be used to copy struct values that have identical types but
for struct tags.
A mode argument might be used to control deep or shallow copy, and perhaps
other modalities.
A deep copy (following pointers) would be a useful feature that the spec
change by itself does not enable.

The cost of using a CopyStruct function instead of a direct struct conversion
is the need to create two reflect.Values, invoking CopyStruct, and (inside
CopyStruct) the cost to verify type identity but for tags.
Copying the actual data needs to be done both in CopyStruct but also with a
direct (language-based) conversion.
The type verification is likely the most expensive step but identity of
struct types (with tags ignored) could be cached.
On the other hand, adonovan@golang points out that the added cost may not
matter in significant ways since these kinds of struct copies often sit
between a database request and an HTTP response.

The functional difference between the proposed spec change and a new
reflect.CopyStruct function is that with CopyStruct an actual copy has to
take place (as is the case now).
The spec change on the other hand permits both approaches: a (copying)
conversion of struct values, or pointers to different struct types that
point to the same struct value via a pointer conversion.
The latter may eliminate a copy of data in the first place.
