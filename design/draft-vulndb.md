# Design Draft: Go Vulnerability Database

Authors: Roland Shoemaker, Filippo Valsorda

[golang.org/design/draft-vulndb](https://golang.org/design/draft-vulndb)

This is a Draft Design, not a formal Go proposal, since it is a
large change that is still flexible.
The goal of circulating this draft design is to collect feedback
to shape an intended eventual proposal.

## Goal

We want to provide a low-noise, reliable way for Go developers to
be alerted of known security vulnerabilities that affect their
applications.

We aim to build a first-party, curated, consistent database of
security vulnerabilities open to community submissions, and
static analysis tooling to surface only the vulnerabilities that
are likely to affect an application, minimizing false positives.

## The database

The vulnerability database will provide entries for known
vulnerabilities in importable (non-main) Go packages in public
modules.

**Curated dataset.**
The database will be actively maintained by the Go Security team,
and will provide consistent metadata and uniform analysis of the
tracked vulnerabilities, with a focus on enabling not just
detection, but also precise impact assessment.

**Basic metadata.**
Entries will include a database-specific unique identifier for
the vulnerability, affected package and version ranges, a coarse
severity grade, and `GOOS`/`GOARCH` if applicable.
If missing, we will also assign a CVE number.

**Targeting metadata.**
Each database entry will include metadata sufficient to enable
detection of impacted downstream applications with low false
positives.
For example, it will include affected symbols (functions,
methods, types, variables…) so that unaffected consumers can be
identified with static analysis.

**Web pages.**
Each vulnerability will link to a web page with the description
of the vulnerability, remediation instructions, and additional
links.

**Source of truth.**
The database will be maintained as a public git repository,
similar to other Go repositories.
The database entries will be available via a stable protocol (see
“The protocol”).
The contents of the repository itself will be in an internal
format which can change without notice.

**Triage process.**
Candidate entries will be sourced from existing streams (such as
the CVE database, and security mailing lists) as well as
community submissions.
Both will be processed by the team to ensure consistent metadata
and analysis.
*We want to specifically encourage maintainers to report
vulnerabilities in their own modules.*

**Not a disclosure process.**
Note that the goal of this database is tracking known, public
vulnerabilities, not coordinating the disclosure of new findings.

## The protocol

The vulnerability database will be served through a simple,
stable HTTPS and JSON-based protocol.
Vulnerabilities will be grouped by module, and an index file will
list the modules with known vulnerabilities and the last time
each entry has been updated.

The protocol will be designed to be served as a collection of
static files, and cacheable by simple HTTP proxies.
The index allows downloading and hosting a full mirror of the
database to avoid leaking module usage information.

Multiple databases can be fetched in parallel, and their entries
are combined, enabling private and commercial databases.
We’ll aim to use an interoperable format.

## The tooling

The primary consumer of the database and the protocol will be a
Go tool, tentatively `go audit`, which will analyze a module and
report what vulnerabilities it’s affected by.

The tool will analyze what vulnerabilities are likely to affect
the current module not only based on the versions of the
dependencies, but also based on the packages and code paths that
are reachable from a configured set of entry points (functions
and methods).

The precision of this analysis will be configurable.
When available, the tool will provide sample traces of how the
vulnerable code is reachable, to aid in assessing impact and
remediation.

The tool accepts a list of packages and reports the
vulnerabilities that affect them (considering as entry points the
`main` and `init` functions for main packages, and exported
functions and methods for non-main packages).

The tool will also support a `-json` output mode, to integrate
reports in other tools, processes such as CI, and UIs, like how
golang.org/x/tools/go/packages tools use `go list -json`.

### Integrations

Besides direct invocations on the CLI and in CI, we want to make
vulnerability entries and audit reports widely available.
The details of each integration involve some open questions.

**vscode-go** will surface reports for vulnerabilities affecting
the workspace and offer easy version bumps.
*Open question*: can vscode-go invoke `go audit`, or do we need a
tighter integration into `gopls`?

**pkg.go.dev** will show vulnerabilities in the displayed
package, and possibly vulnerabilities in its dependencies.
*Open question*: if we analyze transitive dependencies, what
versions should we consider?

At **runtime**, programs will be able to query reports affecting
the dependencies they were built with through `debug.BuildInfo`.
*Open question*: how should applications handle the fact that
runtime reports will have higher false positives due to lack of
source code access?

In the future, we'll also consider integration into other `go`
tool commands, like `go get` and/or `go test`.

Finally, we hope the entries in the database will flow into other
existing systems that provide vulnerability tracking, with their
own integrations.
