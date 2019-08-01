# Cryptography Principles

Author: Filippo Valsorda\
Last updated: June 2019\
Discussion: [golang.org/issue/32466](https://golang.org/issue/32466)

https://golang.org/design/cryptography-principles

The Go cryptography libraries goal is to *help developers build
secure applications*. Thus, they aim to be **secure**, **safe**,
**practical** and **modern**, in roughly that order.

**Secure**. We aim to provide a secure implementation free of
security vulnerabilities.

> This is achieved through reduced complexity, testing, code
> review, and a focus on readability.  We will only accept
> changes when there are enough maintainer resources to ensure
> their (ongoing) security.

**Safe**. The goal is to make the libraries easy—not just
possible—to use securely, as library misuse is just as dangerous
to applications as vulnerabilities.

> The default behavior should be safe in as many scenarios as
> possible, and unsafe functionality, if at all available,
> should require explicit acknowledgement in the API.
> Documentation should provide guidance on how to choose and use
> the libraries.

**Practical**. The libraries should provide most developers with
a way to securely and easily do what they are trying to do,
focusing on common use cases to stay minimal.

> The target is applications, not diagnostic or testing tools.
> It’s expected that niche and uncommon needs will be addressed
> by third-party projects. Widely supported functionality is
> preferred to enable interoperability with non-Go applications.
>
> Note that performance, flexibility and compatibility are only
> goals to the extent that they make the libraries useful, not as
> absolute values in themselves.

**Modern**. The libraries should provide the best available
tools for the job, and they should keep up to date with progress
in cryptography engineering.

> If functionality becomes legacy and superseded, it should be
> marked as deprecated and a modern replacement should be
> provided and documented.
>
> Modern doesn’t mean experimental. As the community grows, it’s
> expected that most functionality will be implemented by
> third-party projects first, and that’s ok.

Note that this is an ordered list, from highest to lowest
priority. For example, an insecure implementation or unsafe API
will not be considered, even if it enables more use cases or is
more performant.

---

The Go cryptography libraries are the `crypto/...` and
`golang.org/x/crypto/...` packages in the Go standard library
and subrepos.

The specific criteria for what is considered a common use case,
widely supported or superseded are complex and out of scope for
this document.
