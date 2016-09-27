# Proposal: Natural XML

Author(s): Sam Whited <sam@samwhited.com>

Last updated: 2016-09-27

Discussion at https://golang.org/issue/13504.


## Abstract

The `encoding/xml` API is arguably difficult to work with.
In order to fix these issues, a more natural API is needed that acts on nodes in
a tree like structure instead of directly on the token stream.


## Background

XML parsers generally operate in one of two modes of operation, a "DOM style"
mode in which entire documents are parsed into a tree-like data structure, the
"Document Object Model" (DOM), and an event-driven "SAX style" mode  (Simple API
for XML) in which tokens are streamed one at a time and only handled if they
would trigger a callback or event.
The benefit of a DOM style node is that all information contained in the XML is
rapidly accessible and can be accessed at will, whereas in a SAX style mode
only information at the current parse location is readily available and other
arrangements have to be made to store previously visible information.
However, the SAX style mode generally provides a relatively small and stable
memory footprint, while the DOM style mode requires parsers to load an entire
document into memory.

Go currently supports a hybrid approach to this situation: entire documents or
elements may be read into native data structures, or individual tokens may be
read off the wire and handled directly by the application.
This works well for simple elements where the entire structure is known, but for
XML with an arbitrary format it forces use of the low-level token stream APIs
directly which is error prone and cumbersome.


## Proposal

Having a higher level tree-like API will allow users to manipulate arbitrary XML
in a more natural way that is compatible with Go's hybrid SAX and DOM style
approach to parsing XML.


### Implementation

An interface originally [suggested][167632824] by RSC is proposed:

[167632824]: https://github.com/golang/go/issues/13504#issuecomment-167632824


```go
// An Element represents the complete parse of a single XML element.
type Element struct {
	StartElement
	Child []Child
}

// A Child is an interface holding one of the element child types:
// *Element, CharData, or Comment.
type Child interface{}
```

The `*Element` type will implement `xml.Marshaler` and `xml.Unmarshaler` to make
it compatible with the existing  `(*xml.Encoder) Encode` and `(*xml.Decoder)
Decode` methods for situations where entire XML elements should be consumed.
This makes it compatible with both styles of XML parsing in Go.
For example, an entire element could be unmarshaled simply:

```go
el := xml.Element{}
err := d.Decode(&el)
```

Or specific children could be unmarshaled:

```go
tok, _ := d.Token()
el := xml.Element{StartElement: tok.(StartElement)}

// Only unmarshal the child named "body"
for ; err == nil; tok, err = d.Token() {
	if start, ok := tok.(StartElement); ok && start.Name.Local == "body" {
		child := xml.Child{}
		_ = xml.DecodeElement(&child, start)
		el.Child = append(el.Child, child)
	}
}
```

The author volunteers to complete this work in the next release cycle with
enough time left after this proposal is accepted and conservatively estimates
that a week of work would be required to complete the changes, including tests.
The changes themselves are relatively easy and this lengthy estimate is mostly
because the authors time is limited to evenings and weekends.
If someone who's job permitted them to work on Go were to accept the task, the
work could almost certainly be completed much quicker.


## Rationale

For large XML documents or streams that cannot be parsed all at once, the given
approach does make parsing less complicated since we still have to iterate over
the token stream.
It may be possible to fix this by adding new methods to the `*xml.Encode` and
`*xml.Decode` types specifically for dealing with elements, but the author
deems that the benefit is not worth the added complexity to the XML package.
The current solution is simple and does not preclude adding a more robust
Element based API at a later date.


## Compatibility

This proposal does not introduce any changes that would break compatibility
with existing code.
It adds two types which would need to be covered under the compatibility
promise in the future.


## Open issues (if applicable)

* For elements with large numbers of children, accessing a specific child via
  a slice may be slow.
  Using a map would be a simple fix, but this makes accessing arrays with few
  elements slower (the crossover is somewhere around 10 elements in a very
  informal benchmark).
  Using a trie or some other appropriate tree-like structure can give us the
  best of both worlds, but adds a great deal of complexity that is almost
  certainly not worth it.
  It may, however, be worth not making the children slice public (and using
  accessor methods instead) so that the implementation could easily be switched
  out at a later date.
