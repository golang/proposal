# Proposal: Security Policy for Go

Author(s): Jason Buberel

Last updated: 2015-07-31

## Abstract

Go programs are being deployed as part of security-critical applications.
Although Go has a generally good history of being free of security
vulnerabilities, the current process for handling security issues is very
informal. In order to be more transparent and the better coordinate with the
community, I am proposing that the Go project adopt a well-defined security
and vulnerability disclosure policy.

## Background

The Go standard library includes a complete, modern [cryptography
package](http://golang.org/pkg/crypto/). Since the initial release of Go,
there has a single documented security vulnerability [CVE-2014-7189]
(https://web.nvd.nist.gov/view/vuln/detail?vulnId=CVE-2014-7189) in the crypto
package. This is a promising track record, but as Go usage increases the
language and standard library will come under increasing scrutiny by the
security research community.

In order to better manage security issues, a formal security policy for Go
should be established.

Other language and library open source projects have established security
policies. The following policies were reviewed and considered in the creation
of this proposal:

* [Python Security Policy](https://www.python.org/news/security/)
* [Ruby on Rails Security Policy](http://rubyonrails.org/security/)
* [Rust Security Policy](http://www.rust-lang.org/security.html)
* [Webkit Security Policy](https://www.webkit.org/security/)
* [Xen Project Security Policy](http://www.xenproject.org/security-policy.html)

These policies differ in various aspects, but in general there is a common set
of guidelines that are typically established:

* How security issues should be reported
* Who will be responsible for reviewing these reports
* What is the response time promises made for initial review
* Exactly what steps will be followed for handing issues
* What type of embargo period will be applied
* How will communication of issues be handled, both pre- and post-disclosure

It was also suggested that the Go project consider the use of managed security
services, such as [HackerOne](https://hackerone.com/). The consensus of
commenters on this topic was a reluctance to base the Go process on a third-
party system at this time.


## Proposal

Among the existing security policies reviewed, the [Rust
policy](http://www.rust-lang.org/security.html) is considered a good starting
point. Once adopted, this policy will be hosted at
[https://golang.org/security](https://golang.org/security). The details of the
policy are in the Implementation section below.

## Implementation

### Reporting a Security Bug

Safety is one of the core principles of Go, and to that end, we would like to
ensure that Go has a secure implementation. Thank you for taking the time to
responsibly disclose any issues you find.

All security bugs in the Go distribution should be reported by email to
[security@golang.org](mailto:security@golang.org). This list is delivered to a
small security team. Your email will be acknowledged within 24 hours, and
you'll receive a more detailed response to your email within 72 hours
indicating the next steps in handling your report. If you would like, you can
encrypt your report using our PGP key (listed below).

Please use a descriptive subject line for your report email. After the initial
reply to your report, the security team will endeavor to keep you informed of
the progress being made towards a fix and full announcement. As recommended by
RFPolicy, these updates will be sent at least every five days. In reality,
this is more likely to be every 24-48 hours.

If you have not received a reply to your email within 48 hours, or have not
heard from the security team for the past five days, please contact the
following members of the Go security team directly:

* Contact the primary security coordinator - [TBD](mailto:TBD) - [public key]
(TBD)  directly.
* Contact the secondary coordinator - [TBD](mailto:TDB) - [public key](TBD)
directly.
* Post a message to [golang-dev@golang.org](mailto:golang-dev@golang.org) or
[golang-dev web interface]
(https://groups.google.com/forum/#!forum/golang-dev).

Please note that golang-dev@golang.org is a public discussion forum. When
escalating on this list, please do not disclose the details of the issue.
Simply state that you're trying to reach a member of the security team.

### Flagging Existing Issues as Security-related

If you believe that an [existing issue](https://github.com/golang/go/issues)
is security-related, we ask that you send an email to
[security@golang.org](mailto:security@golang.org). The email
should include the issue ID and a short description of why it should be
handled according to this security policy.

### Disclosure Process

The Go project will use the following disclosure process:

1. Once the security report is received it will be assigned a primary handler.
This person will coordinate the fix and release process.
1. The problem will be confirmed and a list of all affected versions is
determined.
1. Code will be audited to find any potential similar problems.
1. If it is determined, in consultation with the submitter, that a CVE-ID is
required the primary handler will be responsible for obtaining it.
1. Fixes will be prepared for the current stable release and the head/master
revision. These fixes will not be committed to the public repository.
1. Details of the issue and patch files will be sent to the
[distros@openwall]
(http://oss-security.openwall.org/wiki/mailing-lists/distros)
mailing list.
1. Three working days following this notification, the fixes will be
applied to the [public repository](https://go.googlesource.com/go) and new
builds deployed to [https://golang.org/dl](https://golang.org/dl)
1. On the date that the fixes are applied, announcements will be sent to
[golang-dev@golang.org](https://groups.google.com/forum/#!forum/golang-dev),
[golang-nuts@golang.org](https://groups.google.com/forum/#!forum/golang-nuts)
and the [oss-security@openwall](http://www.openwall.com/lists/oss-security/).
1. Within 6 hours of the mailing lists being notified, a copy of the advisory
will also be published on the [Go blog](https://blog.golang.org).

This process can take some time, especially when coordination is required with
maintainers of other projects. Every effort will be made to handle the bug in
as timely a manner as possible, however it's important that we follow the
release process above to ensure that the disclosure is handled in a consistent
manner.

For those security issues that include the assignment of a CVE-ID, the issue
will be publicly listed under the ["Golang" product on the CVEDetails
website]
(http://www.cvedetails.com/vulnerability-list/vendor_id-14185/Golang.html)
as well as the [National Vulnerability Disclosure site]
(https://web.nvd.nist.gov/view/vuln/search).

### Receiving Security Updates

The best way to receive security announcements is to subscribe to the [golang-
dev@golang.org](https://groups.google.com/forum/#!forum/golang-dev) mailing
list. Any messages pertaining to a security issue will be prefixed with
`[security]`.


### Comments on This Policy

If you have any suggestions to improve this policy, please send an email to
[golang-dev@golang.org](mailto:golang-dev@golang.org) for discussion.

### Plaintext PGP Key

``` ===== pgp key to be inserted here ==== ```

## Rationale

### Early Disclosure

The Go security policy does not contain a provision for
the early disclosure of vulnerabilities to a small set of "trusted" partners.
The Xen and WebKit policies do contain provisions for this. According to
several members of the security response team at Google (Ben Laurie, Adam
Langly), it is incredibly difficult to retain secrecy of embargoed issues once
they have been shared with even a small number of partners.

### Security Review Team Membership

The Go security policy does not contain formal provisions for nomination or
removal of members of the security review team. WebKit, for example, specifies
how new members can become members of the security review team. This may be
needed for the Go project at some point in the future; it does not seem
necessary at this time.

## Open issues

* PGP key pair needed for security@golang.org address.
* Need to designate a primary and secondary alternative contact.

