# Proposal: Extended backwards compatibility for Go

Russ Cox \
December 2022

Earlier discussion at https://go.dev/issue/55090.

Proposal at https://go.dev/issue/56986.

## Abstract

Go's emphasis on backwards compatibility is one of its key strengths.
There are, however, times when we cannot maintain strict compatibility,
such as when changing sort algorithms or fixing clear bugs,
when existing code depends on the old algorithm or the buggy behavior.
This proposal aims to address many such situations by keeping older Go programs
executing the same way even when built with newer Go distributions.

## Background

This proposal is about backward compatibility, meaning
**new versions of Go compiling older Go code**.
Old versions of Go compiling newer Go code is a separate problem,
with a different solution.
There is not a proposal yet.
For now, see
[the discussion about forward compatibility](https://github.com/golang/go/discussions/55092).

Go 1 introduced Go's [compatibility promise](https://go.dev/doc/go1compat),
which says that old programs will by and large continue to run correctly in new versions of Go.
There is an exception for security problems and certain other implementation overfitting.
For example, code that depends on a given type _not_ implementing a particular interface
may change behavior when the type adds a new method, which we are allowed to do.

We now have about ten years of experience with Go 1 compatibility.
In general it works very well for the Go team and for developers.
However, there are also practices we've developed since then
that it doesn't capture (specifically GODEBUG settings),
and there are still times when developers' programs break.
I think it is worth extending our approach to try to break programs even less often,
as well as to explicitly codify GODEBUG settings
and clarify when they are and are not appropriate.

As background, I've been talking to the Kubernetes team
about their experiences with Go.
It turns out that Go's been averaging about one Kubernetes-breaking
change per year for the past few years.
I don't think Kubernetes is an outlier here:
I expect most large projects have similar experiences.
Once per year is not high, but it's not zero either,
and our goal with Go 1 compatibility is zero.

Here are some examples of Kubernetes-breaking changes that we've made:

 - [Go 1.17 changed net.ParseIP](https://go.dev/doc/go1.17#net)
   to reject addresses with leading zeros, like 0127.0000.0000.0001.
   Go interpreted them as decimal, following some RFCs,
   while all BSD-derived systems interpret them as octal.
   Rejecting them avoids taking part in parser misalignment bugs.
   (Here is an [arguably exaggerated security report](https://github.com/sickcodes/security/blob/master/advisories/SICK-2021-016.md).)

   Kubernetes clusters may have stored configs using such addresses,
   so this bug [required them to make a copy of the parsers](https://github.com/kubernetes/kubernetes/issues/100895)
   in order to keep accessing old data.
   In the interim, they were blocked from updating to Go 1.17.

 - [Go 1.15 changed crypto/x509](https://go.dev/doc/go1.15#commonname)
   not to fall back to a certificate's CN field to find a host name when the SAN field was omitted.
   The old behavior was preserved when using `GODEBUG=x509ignoreCN=0`.
   [Go 1.17 removed support for that setting](https://go.dev/doc/go1.17#crypto/x509).

   The Go 1.15 change [broke a Kubernetes test](https://github.com/kubernetes/kubernetes/pull/93426)
   and [required a warning to users in Kubernetes 1.19 release notes](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.19.md#api-change-4).

    The [Kubernetes 1.23 release notes](https://github.com/kubernetes/kubernetes/blob/776cff391524478b61212dbb6ea48c58ab4359e1/CHANGELOG/CHANGELOG-1.23.md#no-really-you-must-read-this-before-you-upgrade)
    warned users who were using the GODEBUG override that it was gone.

 - [Go 1.18 dropped support for SHA1 certificates](https://go.dev/doc/go1.18#sha1),
   with a `GODEBUG=x509sha1=1` override.
   We announced removal of that setting for Go 1.19
   but changed plans on request from Kubernetes.
   SHA1 certificates are apparently still used by some enterprise CAs
   for on-prem Kubernetes installations.

 - [Go 1.19 changed LookPath behavior](https://go.dev/doc/go1.19#os-exec-path)
   to remove an important class of security bugs,
   but the change may also break existing programs,
   so we included a `GODEBUG=execerrdot=0` override.

   The impact of this change on Kubernetes is still uncertain:
   the Kubernetes developers flagged it as risky enough to warrant further investigation.

These kinds of behavioral changes don't only cause pain for Kubernetes developers and users.
They also make it impossible to update older, long-term-supported versions
of Kubernetes to a newer version of Go.
Those older versions don't have the same access to performance improvements and bug fixes.
Again, this is not specific to Kubernetes.
I am sure lots of projects are in similar situations.

As the examples show, over time we've adopted a practice
of being able to opt out of these risky changes using `GODEBUG` settings.
The examples also show that we have probably been too aggressive
about removing those settings.
But the settings themselves have clearly become an important part of Go's compatibility story.

Other important compatibility-related GODEBUG settings include:

 - `GODEBUG=asyncpreemptoff=1` disables signal-based goroutine preemption, which occasionally uncovers operating system bugs.
 - `GODEBUG=cgocheck=0` disables the runtime's cgo pointer checks.
 - `GODEBUG=cpu.<extension>=off` disables use of a particular CPU extension at run time.
 - `GODEBUG=http2client=0` disables client-side HTTP/2.
 - `GODEBUG=http2server=0` disables server-side HTTP/2.
 - `GODEBUG=netdns=cgo` forces use of the cgo resolver.
 - `GODEBUG=netdns=go` forces use of the Go DNS resolver

Programs that need one to use these can usually set
the GODEBUG variable in `func init` of package main,
but for runtime variables, that's too late:
the runtime reads the variable early in Go program startup,
before any of the user program has run yet.
For those programs, the environment variable must be set in the execution environment.
It cannot be “carried with” the program.

Another problem with the GODEBUGs is that you have to know they exist.
If you have a large system written for Go 1.17 and want to update to Go 1.18's toolchain,
you need to know which settings to flip to keep as close to Go 1.17 semantics as possible.

I believe that we should make it even easier and safer
for large projects like Kubernetes to update to new Go releases.

See also my [talk on this topic at GopherCon](https://www.youtube.com/watch?v=v24wrd3RwGo).

## Proposal

I propose that we formalize and expand our use of GODEBUG to provide
compatibility beyond what is guaranteed by the current
[compatibility guidelines](https://go.dev/doc/go1compat).

Specifically, I propose that we:

1. Commit to always adding a GODEBUG setting for changes
   allowed by the compatibility guidelines but that
   nonetheless are likely to break a significant number of real programs.

2. Guarantee that GODEBUG settings last for at least 2 years (4 releases).
   That is only a minimum; some, like `http2server`, will likely last forever.

3. Provide a runtime/metrics counter `/godebug/non-default-behavior/<name>:events`
   to observe non-default-behavior due to GODEBUG settings.

4. Set the default GODEBUG settings based on the `go` line the main module's go.mod,
   so that updating to a new Go toolchain with an unmodified go.mod
   mimics the older release.

5. Allow overriding specific default GODEBUG settings in the source code for package main
   using one or more lines of the form

       //go:debug <name>=<value>

   The GODEBUG environment variable set when a programs runs
   would continue to override both these lines
   and the default inferred from the go.mod `go` line.
   An unrecognized //go:debug setting is a build error.

6. Adjust the `go/build` API to report these new `//go:debug` lines. Specifically, add this type:

       type Comment struct {
           Pos token.Position
           Text string
       }

   and then in type `Package` we would add a new field

       Directives []Comment

   This field would collect all `//go:*` directives before the package line, not just `//go:debug`,
   in the hopes of supporting any future need for directives.

7. Adjust `go list` output to have a new field `DefaultGODEBUG string` set for main packages,
   reporting the combination of the go.mod-based defaults and the source code overrides,
   as well as adding to `Package` new fields `Directives`, `TestDirectives,` and `XTestDirectives`, all of type `[]string`.

8. Document these commitments as well as how to use GODEBUG in
   the [compatibility guidelines](https://golang.org/doc/go1compat).

## Rationale

The main alternate approach is to keep on doing what we are doing,
without these additions.
That makes it difficult for Kubernetes and other large projects
to update in a timely fashion, which cuts them off from performance improvements
and eventually security fixes.
An alternative way to provide these improvements and fixes would be to
extend Go's release support window to two or more years,
but that would require significantly more work
and would be a serious drag on the Go project overall.
It is better to focus our energy as well as the energy of Go developers
on the latest release.
Making it safer to update to the latest release does just that.

The rest of this section gives the affirmative case for each of the enumerated items
in the previous section.

1. Building on the rest of the compatibility guidelines, this commitment will
   give developers added confidence that they can update to a new Go toolchain
   safely with minimal disruption to their programs.

2. In the past we have planned to remove a GODEBUG after only a single release.
   A single release cycle - six months - may well be too short for some developers,
   especially where the GODEBUGs are adjusting settings that affect external
   systems, like which protocols are used. For example, Go 1.14 (Feb 2020) removed
   NPN support in crypto/tls,
   but we patched it back into Google's internal Go toolchain
   for almost three years while we waited for updates to
   network devices that used NPN.
   Today that would probably be a GODEBUG setting, and it would be
   an example of something that takes a large company more than
   six months to resolve.

3. When a developer is using a GODEBUG override, they need to be able to find out
   whether it is safe to remove the override. Obviously testing is a good first step,
   but production metrics can confirm what testing seems to show.
   If the production systems are reporting zeros for `/godebug/non-default-behavior/<name>`,
   that is strong evidence for the safety of removing that override.

4. Having the GODEBUG settings is not enough. Developers need to be able to determine
   which ones to use when updating to a new Go toolchain.
   Instead of forcing developers to look up what is new from one toolchain to the next,
   setting the default to match the `go` line in `go.mod` keeps the program behavior
   as close to the old toolchain as possible.

5. When developers do update the `go` line to a new Go version, they may still need to
   keep a specific GODEBUG set to mimic an older toolchain.
   There needs to be some way to bake that into the build:
   it's not okay to make end users set an environment variable to run a program,
   and setting the variable in main.main or even main's init can be too late.
   The `//go:debug` lines provide a clear way to set those specific GODEBUGs,
   presumably alongside comments explaining why they are needed and
   when they can be removed.

6. This API is needed for the go command and other tools to scan source files
   and find the new `//go:debug` lines.

7. This provides an easy way for developers to understand which default GODEBUG
   their programs are compiled with. It will be particularly useful when switching
   from one `go` line to another.

8. The compatibility documentation should explain all this so developers know about it.

## Compatibility

This entire proposal is about compatibility.
It does not violate any existing compatibility requirements.

It is worth pointing out that the GODEBUG mechanism is appropriate for security deprecations,
such as the SHA1 retirement, but not security fixes, like changing the version of LookPath
used by tools in the Go distribution. Security fixes need to always apply when building with
a new toolchain, not just when the `go` line has been moved forward.

One of the hard rules of point releases is it really must not break anyone,
because we never want someone to be unable to add an urgent security fix
due to some breakage in that same point release or an earlier one in the sequence.
That applies to the security fixes themselves too.
This means it is up to the authors of the security fix to find a fix
that does not require a GODEBUG.

LookPath is a good example.
There was a reported bug affecting go toolchain programs,
and we fixed the bug by making the LookPath change
in a forked copy of os/exec specifically for those programs.
We left the toolchain-wide fix for a major Go release precisely
because of the compatibility issue.

The same is true of net.ParseIP.
We decided it was an important security-hardening fix but on balance
inappropriate for a point release because of the potential for breakage.

It's hard for me to think of a security problem that would be so critical
that it must be fixed in a point release and simultaneously so broad
that the fix fundamentally must break unaffected user programs as collateral damage.
To date I believe we've always found a way to avoid such a fix,
and I think the onus is on those of us preparing security releases to continue to do that.

## Implementation

Overall the implementation is fairly short and straightforward.
Documentation probably outweighs new code.
Russ Cox, Michael Matloob, and Bryan Millls will do the work.

A complete sketch of the implementation is in
[CL 453618](https://go.dev/cl/453618),
[CL 453619](https://go.dev/cl/453619),
[CL 453603](https://go.dev/cl/453603),
[CL 453604](https://go.dev/cl/453604), and
[CL 453605](https://go.dev/cl/453605).
The sketch does not include tests and documentation.
