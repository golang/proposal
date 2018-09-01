# Proposal: Raw XML Token

Author(s): Sam Whited <sam@samwhited.com>

Last updated: 2018-09-01

Discussion at https://golang.org/issue/26756

CL at https://golang.org/cl/127435


## Abstract

This proposal defines a mechanism by which users can emulate the `,innerxml`
struct tag using XML tokens.


## Background

When using the `"*Encoder".EncodeToken` API to write tokens to an XML stream,
it is currently not possible to fully emulate the behavior of `Marshal`.
Specifically, there is no functionality that lets users output XML equivalent to
the `,innerxml` struct tag which inserts raw, unescaped, XML into the output.
For example, consider the following:

    e := xml.NewEncoder(os.Stdout)
    e.Encode(struct {
        XMLName xml.Name `xml:"raw"`
        Inner   string   `xml:",innerxml"`
        }{
    Inner: `<test:test xmlns:test="urn:example:golang"/>`,
    })
    // Output: <raw><test:test xmlns:test="urn:example:golang"/></raw>

This cannot be done with the token based output because all token types are
currently escaped.
For example, attempting to output the raw XML as character data results in the
following:

    e.EncodeToken(xml.CharData(rawOut))
    e.Flush()
    // &lt;test:test xmlns:test=&#34;urn:example:golang&#34;&gt;


## Proposal

The proposed API introduces an XML pseudo-token: `RawXML`.

```go
// RawXML represents some data that should be passed through without escaping.
// Like a struct field with the ",innerxml" tag, RawXML is written to the
// stream verbatim and is not subject to the usual escaping rules.
type RawXML []byte

// Copy creates a new copy of RawXML.
func (r RawXML) Copy() RawXML { … }
```


## Rationale

When attempting to match the output of legacy XML encoders which may produce
broken escaping, or match the output of XML encoders that support features that
are not currently supported by the [`encoding/xml`] package such as namespace
prefixes it is often desirable to use `,rawxml`.
However, if the user is primarily using the token stream API, it may not be
desirable to switch between encoding tokens and encoding native structures which
is cumbersome and forces a call to `Flush`.

Being able to generate the same output from both the SAX-like and DOM-like APIs
would also allow future proposals the option of fully unifying the two APIs by
creating an encoder equivalent to the `NewTokenDecoder` function.


## Compatibility

This proposal introduces one new exported type that would be covered by the
compatibility promise.


## Implementation

Implementation of this proposal is trivial, comprising some 5 lines of code
(excluding tests and comments).
[CL 127435] has been created to demonstrate the concept.


## Open issues

None.


[`encoding/xml`]: https://golang.org/pkg/encoding/xml/
[CL 127435]: https://golang.org/cl/127435
