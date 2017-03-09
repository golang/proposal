# Proposal: XML Stream

Author(s): Sam Whited <sam@samwhited.com>

Last updated: 2017-03-09

Discussion at https://golang.org/issue/19480


## Abstract

The `encoding/xml` package contains an API for tokenizing an XML stream, but no
API exists for processing or manipulating the resulting token stream.
This proposal describes such an API.


## Background

The [`encoding/xml`][encoding/xml] package contains APIs for tokenizing an XML
stream and decoding that token stream into native data types.
Once unmarshaled, the data can then be manipulated and transformed.
However, this is not always ideal.
If we cannot change the type we are unmarshaling into and it does not match the
XML format we are attempting to deserialize, eg. if the type is defined in a
separate package or cannot be modified for API compatibility reasons, we may
have to first unmarshal into a type we control, then copy each field over to the
original type; this is cumbersome and verbose.
Unmarshaling into a struct is also lossy.
As stated in the XML package:

> Mapping between XML elements and data structures is inherently flawed:
> an XML element is an order-dependent collection of anonymous values, while a
> data structure is an order-independent collection of named values.

This means that transforming the XML stream itself cannot necessarily be
accomplished by deserializing into a struct and then reserializing the struct
back to XML; instead it requires manipulating the XML tokens directly.
This may require re-implementing parts of the XML package, for instance, when
renaming an element the start and end tags would have to be matched in user code
so that they can both be transformed to the new name.

To address these issues, an API for manipulating the token stream itself, before
marshaling or unmarshaling occurs, is necessary.
Ideally, such an API should allow for the composition of complex XML
transformations from simple, well understood building blocks.
The transducer pattern, widely available in functional languages, matches these
requirements perfectly.

Transducers (also called, transformers, adapters, etc.) are iterators that
provide a set of operations for manipulating the data being iterated over.
Common transducer operations include Map, Reduce, Filter, etc. and these
operations are are already widely known and understood.


## Proposal

The proposed API introduces two concepts that do not already exist in the
`encoding/xml` package:

```go
// A Tokenizer is anything that can decode a stream of XML tokens, including an
// xml.Decoder.
type Tokenizer interface {
	Token() (xml.Token, error)
	Skip() error
}

// A Transformer is a function that takes a Tokenizer and returns a new
// Tokenizer which outputs a transformed token stream.
type Transformer func(src Tokenizer) Tokenizer
```

Common transducer operations will also be included:


```go
// Inspect performs an operation for each token in the stream without
// transforming the stream in any way.
// It is often injected into the middle of a transformer pipeline for debugging.
func Inspect(f func(t xml.Token)) Transformer {}

// Map transforms the tokens in the input using the given mapping function.
func Map(mapping func(t xml.Token) xml.Token) Transformer {}

// Remove returns a Transformer that removes tokens for which f matches.
func Remove(f func(t xml.Token) bool) Transformer {}
```

Because Go does not provide a generic iterator concept, this (and all
transducers in the Go libraries) are domain specific, meaning operations that
only make sense when discussing XML tokens can also be included:

```go
// RemoveElement returns a Transformer that removes entire elements (and their
// children) if f matches the elements start token.
func RemoveElement(f func(start xml.StartElement) bool) Transformer {}
```


## Rationale

Transducers are commonly used in functional programming and in languages that
take inspiration from functional programming languages, including Go.
Examples include [Clojure transducers][clojure/transducer], [Rust
adapters][rust/adapter], and the various "Transformer" types used throughout Go,
such as in the [`golang.org/x/text/transform`][transform] package.
Because transducers are so widely used (and already used elsewhere in Go), they
are well understood.


## Compatibility

This proposal introduces two new exported types and 4 exported functions that
would be covered by the compatibility promise.
A minimal set of Transformers is proposed, but others can be added at a later
date without breaking backwards compatibility.


## Implementation

A version of this API is already implemented in the
[`mellium.im/xmlstream`][xmlstream] package.
If this proposal is accepted, the author volunteers to copy the relevant parts
to the correct location before the 1.9 (or 1.10, depending on the length of this
proposal process) planning cycle closes.


## Open issues

- Where does this API live?
  It could live in the `encoding/xml` package itself, in another package (eg.
  `encoding/xml/stream`) or, temporarily or permanently, in the subrepos:
  `golang.org/x/xml/stream`.
- A Transformer for removing attributes from `xml.StartElement`'s was originally
  proposed as part of this API, but its implementation is more difficult to do
  efficiently since each use of `RemoveAttr` in a pipeline would need to iterate
  over the `xml.Attr` slice separately.
- Existing APIs in the XML package such as `DecodeElement` require an
  `xml.Decoder` to function and could not be used with the Tokenizer interface
  used in this package.
  A compatibility API may be needed to create a new Decoder with an underlying
  tokenizer.
  This would require that the new functionality reside in the `encoding/xml`
  package.
  Alternatively, general Decoder methods could be reimplemented in a new package
  with the Tokenizer API.


[encoding/xml]: https://golang.org/pkg/encoding/xml/
[clojure/transducer]: https://clojure.org/reference/transducers
[rust/adapter]: https://doc.rust-lang.org/std/iter/#adapters
[transform]: https://godoc.org/golang.org/x/text/transform
[xmlstream]: https://godoc.org/mellium.im/xmlstream
