# Go 1.5 Vendor Experiment

Russ Cox\
based on work by Keith Rarick\
July 2015

[_golang.org/s/go15vendor_](https://golang.org/s/go15vendor)

This document is a revised copy of [https://groups.google.com/forum/#!msg/golang-dev/74zjMON9glU/4lWCRDCRZg0J](https://groups.google.com/forum/#!msg/golang-dev/74zjMON9glU/4lWCRDCRZg0J). See that link for the full mailing list thread and context.

This document was formerly stored on Google Docs at [https://docs.google.com/document/d/1Bz5-UB7g2uPBdOx-rw5t9MxJwkfpx90cqG9AFL0JAYo/edit](https://docs.google.com/document/d/1Bz5-UB7g2uPBdOx-rw5t9MxJwkfpx90cqG9AFL0JAYo/edit).


## Proposal

Based on Keith’s earlier proposal, we propose that, as an experiment for Go 1.5, we add a temporary vendor mode that causes the go command to add these semantics:

> If there is a source directory d/vendor, then, when compiling a source file within the subtree rooted at d, import "p" is interpreted as import "d/vendor/p" if that path names a directory containing at least one file with a name ending in “.go”.
> 
> When there are multiple possible resolutions, the most specific (longest) path wins.
> 
> The short form must always be used: no import path can contain “/vendor/” explicitly.
> 
> Import comments are ignored in vendored packages.

The interpretation of an import depends only on where the source code containing that import sits in the tree.

This proposal uses the word “vendor” instead of “external”, because (1) there is at least one popular vendoring tool (gb) that uses “vendor” and none that we know of that use “external”; (2) “external” sounds like the opposite of “internal”, which is not the right meaning; and (3) in discussions, everyone calls the broader topic vendoring. It would be nice not to bikeshed the name.

As an aside, the terms “internal vendoring” and “external vendoring” have been introduced into some discussions, to make the distinction between systems that rewrite import paths and systems that do not. With the addition of vendor directories to the go command, we hope that this distinction will fade into the past. There will just be vendoring.

**Update, January 2016**: These rules do not apply to the “C” pseudo-package, which is processed earlier than normal import processing. They do, however, apply to standard library packages. If someone wants to vendor (and therefore hide the standard library version of) “math” or even “unsafe”, they can.

**Update, January 2016**: The original text of the first condition above read “as import "d/vendor/p" if that exists”. It has been adjusted to require that the path name a directory containing at least one file with a name ending in .go, so that it is possible to vendor a/b/c without having the parent directory vendor/a/b hide the real a/b.

## Example

The gb project ships an example project called gsftp. It has a gsftp program with three dependencies outside the standard library: golang.org/x/crypto/ssh, golang.org/x/crypto/ssh/agent, and github.com/pkg/sftp.

Adjusting that example to use the new vendor directory, the source tree would look like:

	$GOPATH
	|	src/
	|	|	github.com/constabulary/example-gsftp/
	|	|	|	cmd/
	|	|	|	|	gsftp/
	|	|	|	|	|	main.go
	|	|	|	vendor/
	|	|	|	|	github.com/pkg/sftp/
	|	|	|	|	golang.org/x/crypto/ssh/
	|	|	|	|	|	agent/

The file github.com/constabulary/example-gsftp/cmd/gsftp/main.go says:

	import (
		...
		"golang.org/x/crypto/ssh"
		"golang.org/x/crypto/ssh/agent"
		"github.com/pkg/sftp"
	)

Because github.com/constabulary/example-gsftp/vendor/golang.org/x/crypto/ssh exists and the file being compiled is within the subtree rooted at github.com/constabulary/example-gsftp (the parent of the vendor directory), the source line:

	import "golang.org/x/crypto/ssh"

is compiled as if it were:

	import "github.com/constabulary/example-gsftp/vendor/golang.org/x/crypto/ssh"

(but this longer form is never written).

So the source code in github.com/constabulary/example-gsftp depends on the vendored copy of golang.org/x/crypto/ssh, not one elsewhere in $GOPATH.

In this example, all the dependencies needed by gsftp are (recursively) supplied in the vendor directory, so “go install” does not read any source files outside the gsftp Git checkout. Therefore the gsftp build is reproducible given only the content of the gsftp Git repo and not any other code. And the dependencies need not be edited when copying them into the gsftp repo. And potential users can run “go get github.com/constabulary/example-gsftp/cmd/gsftp” without needing to have an additional vendoring tool installed or special GOPATH configuration.

The point is that adding just the vendor directory mechanism to the go command allows other tools to achieve their goals of reproducible builds and not modifying vendored source code while still remaining compatible with plain “go get”.

## Discussion

There are a few points to note about this. 

The first, most obvious, and most serious is that the resolution of an import must now take into account the location where that import path was found. This is a fundamental implication of supporting vendoring that does not modify source code. However, the resolution of an import already needed to take into account the current GOPATH setting, so import paths were never absolute. This proposal allows the Go community to move from builds that require custom GOPATH configuration beforehand to builds that just work, because the (more limited) configuration is inferred from the conventions of the source file tree. This approach is also in keeping with the rest of the go command.

The second is that this does not attempt to solve the problem of vendoring resulting in multiple copies of a package being linked into a single binary. Sometimes having multiple copies of a library is not a problem; sometimes it is. At least for now, it doesn’t seem that the go command should be in charge of policing or solving that problem.

The final point is that existing tools like godep, nut, and gb will need to change their file tree layouts if they want to take advantage of compatibility with “go get”. However, compatibility with “go get” used to be impossible. Also, combined with eventual agreement on the vendor-spec, it should be possible for the tools themselves to interoperate.

## Deployment

The signals from the Go community are clear: the standard go command must support building source trees in which dependencies have been vendored (copied) without modifications to import paths.

We are well into the Go 1.5 cycle, so caution is warranted. If we put off making any changes, then vendoring tools and “go get” will remain incompatible for the next eight months. On the other hand, if we can make a small, targeted change, then vendoring tools can spend the next eight months experimenting and innovating and possibly converging on a common file tree layout compatible with the go command.

We believe that the experimental proposal above is that small, targeted change. It seems to be the minimal adjustment necessary to support fetching and building vendored, unmodified source code with “go get”. There are many possible extensions or complications we might consider, but for Go 1.5 we want to do as little as possible while remaining useful.

This change will only be enabled if the go command is run with GO15VENDOREXPERIMENT=1 in its environment. The use of the environment variable makes it easy to opt in without rewriting every invocation of the go command.

The new semantics changes the meaning of (breaks) source trees containing directories already named “vendor”. Of the over 60,000 listed on godoc.org, there are fewer than 50 such examples. Putting the new semantics behind the environment variable avoids breaking those trees for now.

If we decide that the vendor behavior is correct, then in a later release (possibly Go 1.6) we would make the vendor behavior default on. Projects containing “vendor” directories could still use “GO15VENDOREXPERIMENT=0” to get the old behavior while they convert their code. In a still later release (possibly Go 1.7) we would remove the use of the environment variable, locking in the vendoring semantics.

Code inside vendor/ subtrees is not subject to import path checking.

The environment variable also enables fetching of git submodules during “go get”. This is meant to allow experiments to understand whether git submodules are an appropriate and useful way to vendor code.

Note that when “go get” fetches a new dependency it never places it in the vendor directory. In general, moving code into or out of the vendor directory is the job of vendoring tools, not the go command.

