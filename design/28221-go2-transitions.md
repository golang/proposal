# Proposal: Go 2 transition

Author: Ian Lance Taylor

Last update: October 15, 2018

## Abstract

A proposal for how to make incompatible changes from Go 1 to Go 2
while breaking as little as possible.

## Background

Currently the Go language and standard libraries are covered by the
[Go 1 compatibility guarantee](https://golang.org/doc/go1compat).
The goal of that document was to promise that new releases of Go would
not break existing working programs.

Among the goals for the Go 2 process is to consider changes to the
language and standard libraries that will break the guarantee.
Since Go is used in a distributed open source environment, we cannot
rely on a [flag
day](http://www.catb.org/jargon/html/F/flag-day.html).
We must permit the interoperation of different packages written using
different versions of Go.

Every language goes through version transitions.
As background, here are some notes on what other languages have done.
Feel free to skip the rest of this section.

### C

C language versions are driven by the ISO standardization process.
C language development has paid close attention to backward
compatibility.
After the first ISO standard, C90, every subsequent standard has
maintained strict backward compatibility.
Where new keywords have been introduced, they are introduced in a
namespace reserved by C90 (an underscore followed by an uppercase
ASCII letter) and are made more accessible via a `#define` macro in a
header file that did not previously exist (examples are `_Complex`,
defined as `complex` in `<complex.h>`, and `_Bool`, defined as `bool`
in `<stdbool.h>`).
None of the basic language semantics defined in C90 have changed.

In addition, most C compilers provide options to define precisely
which version of the C standard the code should be compiled for (for
example, `-std=c90`).
Most standard library implementations support feature macros that may
be #define’d before including the header files to specify exactly
which version of the library should be provided (for example,
`_ISOC99_SOURCE`).
While these features have had bugs, they are fairly reliable and are
widely used.

A key feature of these options is that code compiled at different
language/library versions can in general all be linked together and
work as expected.

The first standard, C90, did introduce breaking changes to the
previous C language implementations, known informally as K&R C.
New keywords were introduced, such as `volatile` (actually that might
have been the only new keyword in C90).
The precise implementation of integer promotion in integer expressions
changed from unsigned-preserving to value-preserving.
Fortunately it was easy to detect code using the new keywords due to
compilation errors, and easy to adjust that code.
The change in integer promotion actually made it less surprising to
naive users, and experienced users mostly used explicit casts to
ensure portability among systems with different integer sizes, so
while there was no automatic detection of problems not much code broke
in practice.

There were also some irritating changes.
C90 introduced trigraphs, which changed the behavior of some string
constants.
Compilers adapted with options like -no-trigraphs and -Wtrigraphs.

More seriously, C90 introduced the notion of undefined behavior, and
declared that programs that invoked undefined behavior might take
any action.
In K&R C, the cases that C90 described as undefined behavior were
mostly treated as what C90 called implementation-defined behavior: the
program would take some non-portable but predictable action.
Compiler writers absorbed the notion of undefined behavior, and
started writing optimizations that assumed that the behavior would not
occur.
This caused effects that surprised people not fluent in the C
standard.
I won’t go into the details here, but one example of this (from my
blog) is [signed overflow](http://www.airs.com/blog/archives/120).

C of course continues to be the preferred language for kernel
development and the glue language of the computing industry.
Though it has been partially replaced by newer languages, this is not
because of any choices made by new versions of C.

The lessons I see here are:

* Backward compatibility matters.
* Breaking compatibility in small ways is OK, as long as people can
  spot the breakages through compiler options or compiler errors.
* Compiler options to select specific language/library versions are
  useful, provided code compiled using different options can be linked
  together.
* Unlimited undefined behavior is confusing for users.

### C++

C++ language versions are also now driven by the ISO standardization process.
Like C, C++ pays close attention to backward compatibility.
C++ has been historically more free with adding new keywords (there
are 10 new keywords in C++11).
This works out OK because the newer keywords tend to be relatively
long (`constexpr`, `nullptr`, `static_assert`) and compilation errors
make it easy to find code using the new keywords as identifiers.

C++ uses the same sorts of options for specifying the standard version
for language and libraries as are found in C.
It suffers from the same sorts of problems as C with regard to
undefined behavior.

An example of a breaking change in C++ was the change in the scope of
a variable declared in the initialization statement of a for loop.
In the pre-standard versions of C++, the scope of the variable
extended to the end of the enclosing block, as though it were declared
immediately before the for loop.
During the development of the first C++ standard, C++98, this was
changed so that the scope was only within the for loop itself.
Compilers adapted by introducing options like `-ffor-scope` so that
users could control the expected scope of the variable (for a period
of time, when compiling with neither `-ffor-scope` nor
`-fno-for-scope`, the GCC compiler used the old scope but warned about
any code that relied on it).

Despite the relatively strong backward compatibility, code written in
new versions of C++, like C++11, tends to have a very different feel
than code written in older versions of C++.
This is because styles have changed to use new language and library
features.
Raw pointers are less commonly used, range loops are used rather than
standard iterator patterns, new concepts like rvalue references and
move semantics are used widely, and so forth.
People familiar with older versions of C++ can struggle to understand
code written in new versions.

C++ is of course an enormously popular language, and the ongoing
language revision process has not harmed its popularity.

Besides the lessons from C, I would add:

* A new version may have a very different feel while remaining
  backward compatible.

### Java

I know less about Java than about the other languages I discuss, so
there may be more errors here and there are certainly more biases.

Java is largely backward compatible at the byte-code level, meaning
that Java version N+1 libraries can call code written in, and
compiled by, Java version N (and N-1, N-2, and so forth).
Java source code is also mostly backward compatible, although they do
add new keywords from time to time.

The Java documentation is very detailed about potential compatibility
issues when moving from one release to another.

The Java standard library is enormous, and new packages are added at
each new release.
Packages are also deprecated from time to time.
Using a deprecated package will cause a warning at compile time (the
warning may be turned off), and after a few releases the deprecated
package will be removed (at least in theory).

Java does not seem to have many backward compatibility problems.
The problems are centered on the JVM: an older JVM generally will not
run newer releases, so you have to make sure that your JVM is at least
as new as that required by the newest library you want to use.

Java arguably has something of a forward compatibility problem in
that JVM bytecodes present a higher level interface than that of a
CPU, and that makes it harder to introduce new features that cannot
be directly represented using the existing bytecodes.

This forward compatibility problem is part of the reason that Java
generics use type erasure.
Changing the definition of existing bytecodes would have broken
existing programs that had already been compiled into bytecode.
Extending bytecodes to support generic types would have required a
large number of additional bytecodes to be defined.

This forward compatibility problem, to the extent that it is a
problem, does not exist for Go.
Since Go compiles to machine code, and implements all required run
time checks by generating additional machine code, there is no similar
forward compatibility issue.

But, in general:

* Be aware of how compatibility issues may restrict future changes.

### Python

Python 3.0 (also known as Python 3000) started development in 2006 and
was initially released in 2008.
In 2018 the transition is still incomplete.
Some people continue to use Python 2.7 (released in 2010).
This is not a path we want to emulate for Go 2.

The main reason for this slow transition appears to be lack of
backward compatibility.
Python 3.0 was intentionally incompatible with earlier versions of
Python.
Notably, `print` was changed from a statement to a function, and
strings were changed to use Unicode.
Python is often used in conjunction with C code, and the latter change
meant that any code that passed strings from Python to C required
tweaking the C code.

Because Python is an interpreted language, and because there is no
backward compatibility, it is impossible to mix Python 2 and Python
3 code in the same program.
This means that for a typical program that uses a range of libraries,
each of those libraries must be converted to Python 3 before the
program can be converted.
Since programs are in various states of conversion, libraries must
support Python 2 and 3 simultaneously.

Python supports statements of the form `from __future__ import
FEATURE`.
A statement like this changes the interpretation of the rest of the
file in some way.
For example, `from __future__ import print_function` changes `print`
from a statement (as in Python 2) to a function (as in Python 3).
This can be used to take incremental steps toward new language
versions, and to make it easier to share the same code among different
language versions.

So, we knew it already, but:

* Backward compatibility is essential.
* Compatibility of the interface to other languages is important.
* Upgrading to a new version is limited by the version that your
  libraries support.

### Perl

The Perl 6 development process began in 2000.
The first stable version of the Perl 6 spec was announced in 2015.
This is not a path we want to emulate for Go 2.

There are many reasons for this slow path.
Perl 6 was intentionally not backward compatible: it was meant to fix
warts in the language.
Perl 6 was intended to be represented by a spec rather than, as with
previous versions of Perl, an implementation.
Perl 6 started with a set of change proposals, but then continued to
evolve over time, and then evolve some more.

Perl supports `use feature` which is similar to Python's `from
__future__ import`.
It changes the interpretation of the rest of the file to use a
specified new language feature.

* Don’t be Perl 6.
* Set and meet deadlines.
* Don’t change everything at once.

## Proposal

### Language changes

Pedantically speaking, we must have a way to speak about specific
language versions.
Each change to the Go language first appears in a Go release.
We will use Go release numbers to define language versions.
That is the only reasonable choice, but it can be confusing because
standard library changes are also associated with Go release numbers.
When thinking about compatibility, it will be necessary to
conceptually separate the Go language version from the standard
library version.

As an example of a specific change, type aliases were first available
in Go language version 1.9.
Type aliases were an example of a backward compatible language change.
All code written in Go language versions 1.0 through 1.8 continued to
work the same way with Go language 1.9.
Code using type aliases requires Go language 1.9 or later.

#### Language additions

Type aliases are an example of an addition to the language.
Code using the type alias syntax `type A = B` did not compile with Go
versions before 1.9.

Type aliases, and other backward compatible changes since Go 1.0, show
us that for additions to the language it is not necessary for packages
to explicitly declare the minimum language version that they require.
Some packages changed to use type aliases.
When such a package was compiled with Go 1.8 tools, the package failed
to compile.
The package author can simply say: upgrade to Go 1.9, or downgrade to
an earlier version of the package.
None of the Go tools need to know about this requirement; it's implied
by the failure to compile with older versions of the tools.

It's true of course that programmers need to understand language
additions, but the the tooling does not.
Neither the Go 1.8 tools nor the Go 1.9 tools need to explicitly know
that type aliases were added in Go 1.9, other than in the limited
sense that the Go 1.9 compiler will compile type aliases and the Go
1.8 compiler will not.
That said, the possibility of specifying a minimum language version to
get better error messages for unsupported language features is
discussed below.

#### Language removals

We must also consider language changes that simply remove features
from the language.
For example, [issue 3939](http://golang.org/issue/3939) proposes that
we remove the conversion `string(i)` for an integer value `i`.
If we make this change in, say, Go version 1.20, then packages that
use this syntax will stop compiling in Go 1.20.
(If you prefer to restrict backward incompatible changes to new major
versions, then replace 1.20 by 2.0 in this discussion; the problem
remains the same.)

In this case, packages using the old syntax have no simple recourse.
While we can provide tooling to convert pre-1.20 code into working
1.20 code, we can't force package authors to run those tools.
Some packages may be unmaintained but still useful.
Some organizations may want to upgrade to 1.20 without having to
requalify the versions of packages that they rely on.
Some package authors may want to use 1.20 even though their packages
now break, but do not have time to modify their package.

These scenarios suggest that we need a mechanism to specify the
maximum version of the Go language with which a package can be built.

Importantly, specifying the maximum version of the Go language should
not be taken to imply the maximum version of the Go tools.
The Go compiler released with Go version 1.20 must be able to build
packages using Go language 1.19.
This can be done by adding an option to cmd/compile (and, if
necessary, cmd/asm and cmd/link) along the lines of the `-std` option
supported by C compilers.
When cmd/compile sees the option, perhaps `-lang=go1.19`, it will
compile the code using the Go 1.19 syntax.

This requires cmd/compile to support all previous versions, one way or
another.
If supporting old syntaxes proves to be troublesome, the `-lang`
option could perhaps be implemented by passing the code through a
convertor from the old version to the current.
That would keep support of old versions out of cmd/compile proper, and
the convertor could be useful for people who want to update their
code.
But it is unlikely that supporting old language versions will be a
significant problem.

Naturally, even though the package is built with the language version
1.19 syntax, it must in other respects be a 1.20 package: it must link
with 1.20 code, be able to call and be called by 1.20 code, and so
forth.

The go tool will need to know the maximum language version so that it
knows how to invoke cmd/compile.
Assuming we continue with the modules experiment, the logical place
for this information is the go.mod file.
The go.mod file for a module M can specify the maximum language
version for the packages that it defines.
This would be honored when M is downloaded as a dependency by some
other module.

The maximum language version is not a minimum language version.
If a module require features in language 1.19, but can be built with
1.20, we can say that the maximum language version is 1.20.
If we build with Go release 1.19, we will see that we are at less than
the maximum, and simply build with language version 1.19.
Maximum language versions greater than that supported by the current
tools can simply be ignored.
If we later build with Go release 1.21, we will build the module with
`-lang=go1.20`.

This means that the tools can set the maximum language version
automatically.
When we use Go release 1.30 to release a module, we can mark the
module as having maximum language version 1.30.
All users of the module will see this maximum version and do the right
thing.

This implies that we will have to support old versions of the language
indefinitely.
If we remove a language feature after version 1.25, version 1.26 and
all later versions will still have to support that feature if invoked
with the `-lang=go1.25` option (or `-lang=go1.24` or any other earlier
version in which the feature is supported).
Of course, if no `-lang` option is used, or if the option is
`-lang=go1.26` or later, the feature will not be available.
Since we do not expect wholesale removals of existing language
features, this should be a manageable burden.

I believe that this approach suffices for language removals.

#### Minimum language version

For better error messages it may be useful to permit the module file
to specify a minimum language version.
This is not required: if a module uses features introduced in
language version 1.N, then building it with 1.N-1 will fail at compile
time.
This may be confusing, but in practice it will likely be obvious what
the problem is.

That said, if modules can specify a minimum language version, the go
tool could produce an immediate, clear error message when building
with 1.N-1.

The minimum language version could potentially be set by the compiler
or some other tool.
When compiling each file, see which features it uses, and use that to
determine the minimum version.
It need not be precisely accurate.

This is just a suggestion, not a requirement.
It would likely provide a better user experience as the language
changes.

#### Language redefinitions

The Go language can also change in ways that are not additions or
removals, but are instead changes to the way a specific language
construct works. 
For example, in Go 1.1 the size of the type `int` on 64-bit hosts
changed from 32 bits to 64 bits.
This change was relatively harmless, as the language does not specify
the exact size of `int`.
Potentially, though, some Go 1.0 programs continued to compile with Go
1.1 but stopped working.

A redefinition is a case where we have code that compiles successfully
with both versions 1.N and version 1.M, where M > N, and where the
meaning of the code is different in the two versions.
For example, [issue 20733](https://golang.org/issue/20733) proposes
that variables in a range loop should be redefined in each iteration.
Though in practice this change seems more likely to fix programs than
to break them, in principle this change might break working programs.

Note that a new keyword normally cannot cause a redefinition, though
we must be careful to ensure that that is true before introducing
one.
For example, if we introduce the keyword `check` as suggested in [the
error handling draft
design](https://go.googlesource.com/proposal/+/master/design/go2draft-error-handling.md),
and we permit code like `check(f())`, that might seem to be a
redefinition if `check` is defined as a function in the same package.
But after the keyword is introduced, any attempt to define such a
function will fail.
So it is not possible for code using `check`, under whichever meaning,
to compile with both version 1.N and 1.M.
The new keyword can be handled as a removal (of the non-keyword use of
`check`) and an addition (of the keyword `check`).

In order for the Go ecosystem to survive a transition to Go 2, we must
minimize these sorts of redefinitions.
As discussed earlier, successful languages have generally had
essentially no redefinitions beyond a certain point.

The complexity of a redefinition is, of course, that we can no longer
rely on the compiler to detect the problem.
When looking at a redefined language construct, the compiler cannot
know which meaning is meant.
In the presence of redefined language constructs, we cannot determine
the maximum language version.
We don't know if the construct is intended to be compiled with the old
meaning or the new.

The only possibility would be to let programmers set the language
version.
In this case it would be either a minimum or maximum language
version, as appropriate.
It would have to be set in such a way that it would not be
automatically updated by any tools.
Of course, setting such a version would be error prone.
Over time, a maximum language version would lead to surprising
results, as people tried to use new language features, and failed.

I think the only feasible safe approach is to not permit language
redefinitions.

We are stuck with our current semantics.
This doesn't mean we can't improve them.
For example, for [issue 20733](https://golang.org/issue/20733), the
range issue, we could change range loops so that taking the address of
a range parameter, or referring to it from a function literal, is
forbidden.
This would not be a redefinition; it would be a removal.
That approach might eliminate the bugs without the potential of
breaking code unexpectedly.

#### Build tags

Build tags are an existing mechanism that can be used by programs to
choose which files to compile based on the release.

Build tags name release versions, which look just like language
versions, but, speaking pedantically, are different.
In the discussion above we've talked about using Go release 1.N to
compile code with language version 1.N-1.
That is not possible using build tags.

Build tags can be used to set the maximum or a minimum release, or
both, that will be used to compile a specific file.
They can be a convenient way to take advantage of language changes
that are only available after a certain version; that is, they can be
used to set a minimum language version when compiling a file.

As discussed above, though, what is most useful for language changes
is the ability to set a maximum language version.
Build tags don't provide that in a useful way.
If you use a build tag to set your current release version as your
maximum version, your package will not build with later releases.
Setting a maximum language version is only possible when it is set to
a version before the current release, and is coupled with an alternate
implementation that is used for the later versions.
That is, if you are building with 1.N, it's not helpful to use a build
tag of `!1.N+1`.
You could use a build tag of `!1.M` where `M < N`, but in almost all
cases you will then need a separate file with a build tag of `1.M+1`.

Build tags can be used to handle language redefinitions: if there is a
language redefinition at language version `1.N`, programmers can write
one file with a build tag of `!1.N` using the old semantics and a
different file with a build tag of `1.N` using the new semantics.
However, these duplicate implementations are a lot of work, it's hard
to know in general when it is required, and it would be easy to make a
mistake.
The availability of build tags is not enough to overcome the earlier
comments about not permitting any language redefinitions.

#### import "go2"

It would be possible to add a mechanism to Go similar to Python's
`from __future__ import` and Perl's `use feature`.
For example, we could use a special import path, such as `import
"go2/type-aliases"`.
This would put the required language features in the file that uses
them, rather than hidden away in the go.mod file.

This would provide a way to describe the set of language additions
required by the file.
It's more complicated, because instead of relying on a language
version, the language is broken up into separate features.
There is no obvious way to ever remove any of these special imports,
so they will tend to accumulate over time.
Python and Perl avoid the accumulation problem by intentionally making
a backward incompatible change.
After moving to Python 3 or Perl 6, the accumulated feature requests
can be discarded.
Since Go is trying to avoid a large backward incompatible change,
there would be no clear way to ever remove these imports.

This mechanism does not address language removals.
We could introduce a removal import, such as `import
"go2/no-int-to-string"`, but it's not obvious why anyone would ever
use it.
In practice, there would be no way to ever remove language features,
even ones that are confusing and error-prone.

This kind of approach doesn't seem suitable for Go.

### Standard library changes

One of the benefits of a Go 2 transition is the chance to release some
of the standard library packages from the Go 1 compatibility
guarantee.
Another benefit is the chance to move many, perhaps most, of the
packages out of the six month release cycle.
If the modules experiment works out it may even be possible to start
doing this sooner rather than later, with some packages on a faster
cycle.

I propose that the six month release cycle continue, but that it be
treated as a compiler/runtime release cycle.
We want Go releases to be useful out of the box, so releases will
continue to include the current versions of roughly the same set of
packages that they contain today.
However, many of those packages will actually be run on their own
release cycles.
People using a given Go release will be able to explicitly choose to
use newer versions of the standard library packages.
In fact, in some cases they may be able to use older versions of the
standard library packages where that seems useful.

Different release cycles would require more resources on the part of
the package maintainers.
We can only do this if we have enough people to manage it and enough
testing resources to test it.

We could also continue using the six month release cycle for
everything, but make the separable packages available separately for
use with different, compatible, releases.

#### Core standard library

Still, some parts of the standard library must be treated as core
libraries.
These libraries are closely tied to the compiler and other tools, and
must strictly follow the release cycle.
Neither older nor newer versions of these libraries may be used.

Ideally, these libraries will remain on the current version 1.
If it seems necessary to change any of them to version 2, that will
have to be discussed on a case by case basis.
At this time I see no reason for it.

The tentative list of core libraries is:

* os/signal
* plugin
* reflect
* runtime
* runtime/cgo
* runtime/debug
* runtime/msan
* runtime/pprof
* runtime/race
* runtime/tsan
* sync
* sync/atomic
* testing
* time
* unsafe

I am, perhaps optimistically, omitting the net, os, and syscall
packages from this list.
We'll see what we can manage.

#### Penumbra standard library

The penumbra standard library consists of those packages that are
included with a release but are maintained independently.
This will be most of the current standard library.
These packages will follow the same discipline as today, with the
option to move to a v2 where appropriate.
It will be possible to use `go get` to upgrade or, possibly, downgrade
these standard library packages.
In particular, fixes can be made as minor releases separately from the
six month core library release cycle.

The go tool will have to be able to distinguish between the core
library and the penumbra library.
I don't know precisely how this will work, but it seems feasible.

When moving a standard library package to v2, it will be essential to
plan for programs that use both v1 and v2 of the package.
Those programs will have to work as expected, or if that is impossible
will have to fail cleanly and quickly.
In some cases this will involve modifying the v1 version to use an
internal package that is also shared by the v2 package.

Standard library packages will have to compile with older versions of
the language, at least the two previous release cycles that we
currently support.

#### Removing packages from the standard library

The ability to support `go get` of standard library packages will
permit us to remove packages from the releases.
Those packages will continue to exist and be maintained, and people
will be able to retrieve them if they need them.
However, they will not be shipped by default with a Go release.

This will include packages like

* index/suffixarray
* log/syslog
* net/http/cgi
* net/http/fcgi

and perhaps other packages that do not seem to be widely useful.

We should in due course plan a deprecation policy for old packages, to
move these packages to a point where they are no longer maintained.
The deprecation policy will also apply to the v1 versions of packages
that move to v2.

Or this may prove to be too problematic, and we should never deprecate
any existing package, and never remove them from the standard
releases.

## Go 2

If the above process works as planned, then in an important sense
there never will be a Go 2.
Or, to put it a different way, we will slowly transition to new
language and library features.
We could at any point during the transition decide that now we are
Go 2, which might be good marketing.
Or we could just skip it (there has never been a C 2.0, why have a Go
2.0?).

Popular languages like C, C++, and Java never have a version 2.
In effect, they are always at version 1.N, although they use different
names for that state.
I believe that we should emulate them.
In truth, a Go 2 in the full sense of the word, in the sense of an
incompatible new version of the language or core libraries, would not
be a good option for our users.
A real Go 2 would, perhaps unsurprisingly, be harmful.
