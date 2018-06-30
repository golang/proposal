# Proposal: DNS Based Vanity Imports

Author(s): Sam Whited <sam@samwhited.com>

Last updated: 2018-06-30

Discussion at https://golang.org/issue/26160


## Abstract

A new mechanism for performing vanity imports using DNS TXT records.


## Background

Vanity imports allow the servers behind Go import paths to delegate hosting of
a packages source code to another host.
This is done using the HTTP protocol over TLS which means that expired
certificates, problems with bespoke servers, timeouts contacting the server, and
any number of other problems can cause looking up the source to fail.
Running an HTTP server also adds unnecessary overhead and expense that may be
difficult for hobbyists that create popular packages.
To avoid these problems, a new mechanism for looking up vanity imports is
needed.


## Proposal

To create a vanity import using DNS a separate TXT record is created for each
package with the name `go-import.example.net` where `example.net` is the domain
from the package import path.
The record data is the same format that would appear in an HTTP based vanity
imports "content" attribute.
This allows us to easily list all packages with vanity imports under a given
apex domain:

    $ dig +short go-import.golang.org TXT
    "golang.org/x/vgo git https://go.googlesource.com/vgo"
    "golang.org/x/text git https://go.googlesource.com/text"
    …

Because the current system for vanity import paths requires TLS unless the
`-insecure` flag is provided to `go get`, it is desirable to provide similar
security guarantees with DNS.
To this end `go get` should only accept TXT records with a verified DNSSEC
signature unless the `-insecure` flag has been passed.
To determine which package to import the Go tool would search each TXT record
returned for one that starts with the same fully qualified import path that
triggered the lookup.
TXT records for a given domain should be fetched only once when the first
package with a given domain in its import path is found and reused when parsing
other import lines in the same build.


## Rationale

Before we can make an HTTP request (as the current vanity import mechanism
does), or even establish a TLS connection, we must already have performed a DNS
lookup.
Because this happens anyways, it would be ideal to cut out other steps (HTTP,
TLS, etc.) altogether (and the extra problems they bring with them) and store
the information in the DNS record.
Even if vanity imports are deprecated in the near future for ZIP based package
servers ala vgo, backwards compatibility will be needed for some time and any
experience gained here may apply to pointing domains at package servers
(eg. via DNS SRV).

TXT records were chosen instead of a [custom resource record] to simplify
deployment and avoid the overhead of dealing with the IETF.
Because TXT records are limited to 255 characters but the apex domain used by a
package may be significantly longer than this, it is possible that some packages
may not fit in the record.
Since fully qualified package names must be typed in import statements this does
not seem practical or a cause for concern, so it is not addressed here.

[custom resource record]: https://tools.ietf.org/html/rfc6195


## Compatibility

If no TXT records are found for a given domain `go get` should fall back to
using the HTTP-based mechanism.
Having DNS TXT record lookup also lays the groundwork for discovering package
servers in a vgo-based future.


## Implementation

The author of this proposal has started looking into implementing it in the Go
tool, but cannot yet commit to a timeframe for an implementation.


## Open issues

- Does a DNSSEC implementation exist that could be vendored into the Go tool?
