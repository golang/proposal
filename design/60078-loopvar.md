# Proposal: Less Error-Prone Loop Variable Scoping

David Chase \
Russ Cox \
May 2023

Discussion at https://go.dev/issue/60078. \
Pre-proposal discussion at https://go.dev/issue/56010.

## Abstract

Last fall, we had a GitHub discussion at #56010 about changing for
loop variables declared with `:=` from one-instance-per-loop to
one-instance-per-iteration. Based on that discussion and further work
on understanding the implications of the change, we propose that we
make the change in an appropriate future Go version, perhaps Go 1.22
if the stars align, and otherwise a later version.

## Background

This proposal is about changing for loop variable scoping semantics,
so that loop variables are per-iteration instead of per-loop. This
would eliminate accidental sharing of variables between different
iterations, which happens far more than intentional sharing does. The
proposal would fix [#20733](https://go.dev/issue/20733).

Briefly, the problem is that loops like this one don’t do what they
look like they do:

	var ids []*int
	for i := 0; i < 10; i++ {
		ids = append(ids, &i)
	}

That is, this code has a bug. After this loop executes, `ids` contains
10 identical pointers, each pointing at the value 10, instead of 10
distinct pointers to 0 through 9. This happens because the item
variable is per-loop, not per-iteration: `&i` is the same on every
iteration, and `item` is overwritten on each iteration. The usual fix
is to write this instead:

	var ids []*int
	for i := 0; i < 10; i++ {
		i := i
		ids = append(ids, &i)
	}

This bug also often happens in code with closures that capture the
address of item implicitly, like:

	var prints []func()
	for _, v := range []int{1, 2, 3} {
		prints = append(prints, func() { fmt.Println(v) })
	}
	for _, print := range prints {
		print()
	}

This code prints 3, 3, 3, because all the closures print the same v,
and at the end of the loop, v is set to 3. Note that there is no
explicit &v to signal a potential problem. Again the fix is the same:
add v := v.

The same bug exists in this version of the program, with the same fix:

	var prints []func()
	for i := 1; i <= 3; i++ {
		prints = append(prints, func() { fmt.Println(i) })
	}
	for _, print := range prints {
		print()
	}

Another common situation where this bug arises is in subtests using t.Parallel:

	func TestAllEvenBuggy(t *testing.T) {
		testCases := []int{1, 2, 4, 6}
		for _, v := range testCases {
			t.Run("sub", func(t *testing.T) {
				t.Parallel()
				if v&1 != 0 {
					t.Fatal("odd v", v)
				}
			})
		}
	}

This test passes, because each all four subtests check that 6 (the
final test case) is even.

Goroutines are also often involved in this kind of bug, although as
these examples show, they need not be. See also the [Go FAQ
entry](https://go.dev/doc/faq#closures_and_goroutines).

Russ [talked at Gophercon once](https://go.dev/blog/toward-go2#explaining-problems)
about how we need agreement about the existence of a problem before we
move on to solutions. When we examined this issue in the run up to Go 1,
it did not seem like enough of a problem. The general consensus was
that it was annoying but not worth changing. Since then, we suspect
every Go programmer in the world has made this mistake in one program
or another.

We have talked for a long time about redefining these semantics, to
make loop variables _per-iteration_ instead of _per-loop_. That is,
the change would effectively be to add an implicit “x := x” at the
start of every loop body for each iteration variable x, just like
people do manually today. Making this change would remove the bugs
from the programs above.

This proposal does exactly that. Using the `go` version lines in
`go.mod` files, it only applies the new semantics to new programs, so
that existing programs are guaranteed to continue to execute exactly
as before.

Before writing this proposal, we collected feedback in a GitHub
Discussion in October 2022, [#56010](https://go.dev/issue/56010). The
vast majority of the feedback was positive, although a couple people
did say they see no problem with the current semantics and discourage
a change. Here are a few representative quotes from that discussion:

> One thing to notice in this discussion is that even after having this
> problem explained multiple times by different people multiple
> developers were still having trouble understanding exactly what caused
> it and how to avoid it, and even the people that understood the
> problem in one context often failed to notice it would affect other
> types of for loops.
>
> So we could argue that the current semantics make the learning curve for Go steeper.
>
> PS: I have also had problems with this multiple times, once in
> production, thus, I am very in favor of this change even considering
> the breaking aspect of it.
>
> — [@VinGarcia](https://github.com/golang/go/discussions/56010#discussioncomment-3789371)

> This exactly matches my experience. It's relatively easy to understand
> the first example (taking the same address each time), but somewhat
> trickier to understand in the closure/goroutine case. And even when
> you do understand it, one forgets (apparently even Russ forgets!). In
> addition, issues with this often don't show up right away, and then
> when debugging an issue, I find it always takes a while to realize
> that it's "that old loop variable issue again".
>
> — [@benhoyt](https://github.com/golang/go/discussions/56010#discussioncomment-3791004)

> Go's unusual loop semantics are a consistent source of problems and
> bugs in the real world. I've been a professional go developer for
> roughly six years, and I still get bit by this bug, and it's a
> consistent stumbling block for newer Go programmers. I would strongly
> encourage this change.
>
> — [@efronlicht](https://github.com/golang/go/discussions/56010#discussioncomment-3798957)

> I really do not see this as a useful change. These changes always have
> the best intentions, but the reality is that the language works just
> fine now. This well intended change slowly creep in over time, until
> you wind up with the C++ language yet again. If someone can't
> understand a relatively simple design decision like this one, they are
> not going to understand how to properly use channels and other
> language features of Go.
>
> Burying a change to the semantics of the language in go.mod is absolutely bonkers.
>
> — [@hydrogen18](https://github.com/golang/go/discussions/56010#discussioncomment-3851670)

Overall, the discussion included 72 participants and 291 total
comments and replies. As a rough measure of user sentiment, the
discussion post received 671 thumbs up, 115 party, and 198 heart emoji
reactions, and not a single thumbs down reaction.

Russ also presented the idea of making this change at GopherCon 2022,
shortly after the discussion, and then again at Google Open Source
Live's Go Day 2022. Feedback from both talks was entirely positive:
not a single person suggested that we should not make this change.

## Proposal

We propose to change for loop scoping in a future version of Go to be
per-iteration instead of per-loop. For the purposes of this document,
we are calling that version Go 1.30, but the change would land in
whatever version of Go it is ready for. The earliest version of Go
that could include the change would be Go 1.22.

This change includes four major parts:
(1) the language specification,
(2) module-based and file-based language version selection,
(3) tooling to help users in the transition,
(4) updates to other parts of the Go ecosystem.
The implementation of these parts spans the compiler, the `go` command,
the `go` `vet` command, and other tools.

### Language Specification

In <https://go.dev/ref/spec#For_clause>, the text currently reads:

> The init statement may be a short variable declaration, but the post
> statement must not. Variables declared by the init statement are
> re-used in each iteration.

This would be replaced with:

> The init statement may be a short variable declaration (`:=`), but the
> post statement must not. Each iteration has its own separate declared
> variable (or variables). The variable used by the first iteration is
> declared by the init statement. The variable used by each subsequent
> iteration is declared implicitly before executing the post statement
> and initialized to the value of the previous iteration's variable at
> that moment.
>
>     var prints []func()
>     for i := 0; i < 3; i++ {
>         prints = append(prints, func() { println(i) })
>     }
>     for _, p := range prints {
>         p()
>     }
>
>     // Output:
>     // 0
>     // 1
>     // 2
>
> Prior to Go 1.30, iterations shared one set of variables instead of
> having their own separate variables.

(Remember that in this document, we are using Go 1.30 as the placeholder
for the release that will ship the new semantics.)

For precision in this proposal, the spec example would compile to a
form semantically equivalent to this Go program:

	{
		i_outer := 0
		first := true
		for {
			i := i_outer
			if first {
				first = false
			} else {
				i++
			}
			if !(i < 3) {
				break
			}
			prints = append(prints, func() { println(i) })
			i_outer = i
		}
	}

Of course, a compiler can write the code less awkwardly, since it need
not limit the translation output to valid Go source code. In
particular a compiler is likely to have the concept of the current
memory location associated with `i` and be able to update it just
before the post statement.

In <https://go.dev/ref/spec#For_range>, the text currently reads:

> The iteration variables may be declared by the "range" clause using a
> form of short variable declaration (`:=`). In this case their types
> are set to the types of the respective iteration values and their
> scope is the block of the "for" statement; they are re-used in each
> iteration. If the iteration variables are declared outside the "for"
> statement, after execution their values will be those of the last
> iteration.

This would be replaced with:

> The iteration variables may be declared by the "range" clause using a
> form of short variable declaration (`:=`). In this case their types
> are set to the types of the respective iteration values and their
> scope is the block of the "for" statement; each iteration has its own
> separate variables. If the iteration variables are declared outside
> the "for" statement, after execution their values will be those of the
> last iteration.
>
>     var prints []func()
>     for _, s := range []string{"a", "b", "c"} {
>         prints = append(prints, func() { println(s) })
>     }
>     for _, p := range prints {
>         p()
>     }
>
>     // Output:
>     // a
>     // b
>     // c
>
> Prior to Go 1.30, iterations shared one set of variables instead of
> having their own separate variables.

For precision in this proposal, the spec example would compile to a
form semantically equivalent to this Go program:

	{
		var s_outer string
		for _, s_outer = range []string{"a", "b", "c"} {
			s := s_outer
			prints = append(prints, func() { println(s) })
		}
	}

Note that in both 3-clause and range forms, this proposal is a
complete no-op for loops with no `:=` in the loop header and loops
with no variable capture in the loop body. In particular, a loop like
the following example, modifying the loop variable during the loop
body, continues to execute as it always has:

	for i := 0;; i++ {
		if i >= len(s) || s[i] == '"' {
			return s[:i]
		}
		if s[i] == '\\' { // skip escaped char, potentially a quote
			i++
		}
	}

### Language Version Selection

The change in language specification will fix far more programs than
it breaks, but it may break a very small number of programs. To make
the potential breakage completely user controlled, the rollout would
decide whether to use the new semantics based on the `go` line in each
package’s `go.mod` file. This is the same line already used for
enabling language features; for example, to use generics in a package,
the `go.mod` must say `go 1.18` or later. As a special case, for this
proposal, we would use the `go` line for changing semantics instead of
for adding or removing a feature.

Modules that say `go 1.30` or later would have for loops using
per-iteration variables, while modules declaring earlier versions have
for loops with per-loop variables:

<img width="734" alt="Code in modules that say go 1.30 gets per-iteration variable semantics; code in modules that say earlier Go versions gets per-loop semantics." src="https://user-images.githubusercontent.com/104030/193599987-19d8f564-cb40-488e-beaa-5093a4823ee0.png">

This mechanism would allow the change to be [deployed
gradually](https://go.dev/talks/2016/refactor.article) in a given code
base. Each module can update to the new semantics independently,
avoiding a bifurcation of the ecosystem.

The [forward compatibility work in #57001](https://go.dev/issue/57001),
which will land in Go 1.21, ensures that Go 1.21 and later will not
attempt to compile code marked `go 1.30`. Even if this change lands in
Go 1.22, the previous (and only other supported) Go release would be
Go 1.21, which would understand not to compile `go 1.22` code. So code
opting in to the new loop semantics would never miscompile in older Go
releases, because it would not compile at all. If the changes were to
be slated for Go 1.22, it might make sense to issue a Go 1.20 point
release making its `go` command understand not to compile `go 1.22`
code. Strictly speaking, that point release is unnecessary, because if
Go 1.22 has been released, Go 1.20 is unsupported and we don't need to
worry about its behavior. But in practice people do use older Go
releases for longer than they are supported, and if they keep up with
point releases we can help them avoid this potential problem.

The forward compatibility work also allows a per-file language version
selection using `//go:build` directives. Specifically, if a file in a
`go 1.29` module says `//go:build go1.30`, it gets the Go 1.30
language semantics, and similarly if a file in a `go 1.30` module says
`//go:build go1.29`, it gets the Go 1.29 language semantics. This
general rule would apply to loop semantics as well, so the files in a
module could be converted one at a time in a per-file gradual code
repair if necessary.

Vendoring of other Go modules already records the Go version listed in
each vendored module's `go.mod` file, to implement the general
language version selection rule. That existing support would also
ensure that old vendored modules keep their old loop semantics even in
a newer overall module.

### Transition Support Tooling

We expect that this change will fix far more programs than it breaks,
but it will break some programs. The most common programs that break
are buggy tests (see the [“fixes buggy code” section below](#fixes)
for details). Users who observe a difference in their programs need
support to pinpoint the change. We plan to provide two kinds of
support tooling, one static and one dynamic.

The static support tooling is a compiler flag that reports every loop
that is compiling differently due to the new semantics. Our prototype
implementation does a very good job of filtering out loops that are
provably unaffected by the change in semantics, so in a typical
program very few loops are reported. The new compiler flag,
`-d=loopvar=2`, can be invoked by adding an option to the `go` `build`
or `go` `test` command line: either `-gcflags=-d=loopvar=2` for
reports about the current package only, or `-gcflags=all=-d=loopvar=2`
for reports about all packages.

The dynamic support tooling is a new program called bisect that, with
help from the compiler, runs a test repeatedly with different sets of
loops opted in to the new semantics. By using a binary search-like
algorithm, bisect can pinpoint the exact loop or loops that, when
converted to the new semantics, cause a test failure. Once you have a
test that fails with the new semantics but passes with the old
semantics, you run:

	bisect -compile=loopvar go test

We have used this dynamic tooling in a conversion of Google's internal
monorepo to the new loop semantics. The rate of test failure caused by
the change was about 1 in 8,000. Many of these tests took a long time
to run and contained complex code that we were unfamiliar with. The
bisect tool is especially important in this situation: it runs the
search while you are at lunch or doing other work, and when you return
it has printed the source file and line number of the loop that causes
the test failure when compiled with the new semantics. At that point,
it is trivial to rewrite the loop to pre-declare a per-loop variable
and no longer use `:=`, preserving the old meaning even in the new
semantics. We also found that code owners were far more likely to see
the actual problem when we could point to the specific line of code.
As noted in the [“fixes buggy code” section below](#fixes), all but
one of the test failures turned out to be a buggy test.

### Updates to the Go Ecosystem

Other parts of the Go ecosystem will need to be updated to understand
the new loop semantics.

Vet and the golang.org/x/tools/go/analysis framework are being updated
as part of #57001 to have access to the per-file language version
information. Analyses like the vet loopclosure check will need to
tailor their diagnostics based on the language version: in files using
the new semantics, there won't be `:=` loop variable problems anymore.

Other analyzers, like staticcheck and golangci-lint, may need updates
as well. We will notify the authors of those tools and work with them
to make sure they have the information they need.

## Rationale and Compatibility

In most Go design documents, Rationale and Compatibility are two
distinct sections. For this proposal, considerations of compatibility
are so fundamental that it makes sense to address them as part of the
rationale. To be completely clear: _this is a breaking change to Go_.
However, the specifics of how we plan to roll out the change follow
the spirit of the compatibility guidelines if not the “letter of the
law.”

In the [Go 2 transitions document](https://github.com/golang/proposal/blob/master/design/28221-go2-transitions.md#language-changes)
we gave the general rule that language redefinitions like what we just
described are not permitted, giving this very proposal as an example
of something that violates the general rule. We still believe that
that is the right general rule, but we have come to also believe that
the for loop variable case is strong enough to motivate a one-time
exception to that rule. Loop variables being per-loop instead of
per-iteration is the only design decision we know of in Go that makes
programs incorrect more often than it makes them correct. Since it is
the only such design decision, we do not see any plausible candidates
for additional exceptions.

The rest of this section presents the rationale and compatibility
considerations.

### A decade of experience shows the cost of the current semantics

Russ [talked at Gophercon once](https://go.dev/blog/toward-go2#explaining-problems)
about how we need agreement about the existence of a problem before we
move on to solutions. When we examined this issue in the run up to Go
1, it did not seem like enough of a problem. The general consensus was
that it was annoying but not worth changing.

Since then, we suspect every Go programmer in the world has made this
mistake in one program or another. Russ certainly has done it
repeatedly over the past decade, despite being the one who argued for
the current semantics and then implemented them. (Apologies!)

The current cures for this problem are worse than the disease.

We ran a program to process the git logs of the top 14k modules, from
about 12k git repos and looked for commits with diff hunks that were
entirely “x := x” lines being added. We found about 600 such commits.
On close inspection, approximately half of the changes were
unnecessary, done probably either at the insistence of inaccurate
static analysis, confusion about the semantics, or an abundance of
caution. Perhaps the most striking was this pair of changes from
different projects:

```
     for _, informer := range c.informerMap {
+        informer := informer
         go informer.Run(stopCh)
     }
```

```
     for _, a := range alarms {
+        a := a
         go a.Monitor(b)
     }
```

One of these two changes is unnecessary and the other is a real bug
fix, but you can’t tell which is which without more context. (In one,
the loop variable is an interface value, and copying it has no effect;
in the other, the loop variable is a struct, and the method takes a
pointer receiver, so copying it ensures that the receiver is a
different pointer on each iteration.)

And then there are changes like this one, which is unnecessary
regardless of context (there is no opportunity for hidden
address-taking):

```
     for _, scheme := range artifact.Schemes {
+        scheme := scheme
         Runtime.artifactByScheme[scheme.ID] = id
         Runtime.schemesByID[scheme.ID] = scheme
     }
```

This kind of confusion and ambiguity is the exact opposite of the
readability we are aiming for in Go.

People are clearly having enough trouble with the current semantics
that they choose overly conservative tools and adding “x := x” lines
by rote in situations not flagged by tools, preferring that to
debugging actual problems. This is an entirely rational choice, but it
is also an indictment of the current semantics.

We’ve also seen production problems caused in part by these semantics,
both inside Google and at other companies (for example,
[this problem at Let’s Encrypt](https://bugzilla.mozilla.org/show_bug.cgi?id=1619047)).
It seems likely that, world-wide, the current semantics have easily
cost many millions of dollars in wasted developer time and production
outages.

### Old code is unaffected, compiling exactly as before

The go lines in go.mod give us a way to guarantee that all old code is
unaffected, even in a build that also contains new code. Only when you
change your go.mod line do the packages in that module get the new
semantics, and you control that. In general this one reason is not
sufficient, as laid out in the Go 2 transitions document. But it is a
key property that contributes to the overall rationale, with all the
other reasons added in.

### Changing the semantics globally would disallow gradual code repair

As noted earlier, [gradual code repair](https://go.dev/talks/2016/refactor.article)
is an important technique for deploying any potentially breaking
change: it allows focusing on one part of the code base at a time,
instead of having to consider all of it together. The per-module
go.mod go lines and the per-file `//go:build` directives enable
gradual code repair.

Some people have suggested we simply make the change unconditionally
when using Go 1.30, instead of allowing this fine-grained selection.
Given the low impact we expect from the change, this “all at once”
approach may be viable even for sizable code bases. However, it leaves
no room for error and creates the possibility of a large problem that
cannot be broken into smaller problems. A forced global change removes
the safety net that the gradual approach provides. From an engineering
and risk reduction point of view, that seems unwise. The safer, more
gradual path is the better one.

### Changing the semantics is usually a no-op, and when it’s not, it fixes buggy code far more often than it breaks correct code {#fixes}

As mentioned above, we have recently (as of May 2023) enabled the new
loop semantics in Google's internal Go toolchain. In order to do
that, we ran all of our tests, found the specific loops that needed
not to change behavior in order to pass (using `bisect` on each newly
failing test), rewrote the specific loops not to use `:=`, and then
changed the semantics globally. For Google's internal code base, we
did make a global change, even for open-source Go libraries written
for older Go versions. One reason for the global change was pragmatic:
there is of course no code marked as “Go 1.30” in the world now, so if
not for the global change there would be no change at all. Another
reason was that we wanted to find out how much total work it would
require to change all code. The process was still gradual, in the
sense that we tested the entirety of Google's Go code many times with
a compiler flag enabling the change just for our own builds, and fixed
all broken code, before we made the global change that affected all
our users.

People who want to experiment with a global change in their code bases
can build with `GOEXPERIMENT=loopvar` using the current development
copy of Go. That experimental mode will also ship in the Go 1.21
release.

The vast majority of newly failing tests were table-driven tests using
[t.Parallel](https://pkg.go.dev/testing/#T.Parallel). The usual
pattern is to have a test that reduces to something like `TestAllEvenBuggy`
from the start of the document:

```
func TestAllEven(t *testing.T) {
	testCases := []int{1, 2, 4, 6}
	for _, v := range testCases {
		t.Run("sub", func(t *testing.T) {
			t.Parallel()
			if v&1 != 0 {
				t.Fatal("odd v", v)
			}
		})
	}
}
```

This test aims to check that all the test cases are even (they are
not!), but it passes with current Go toolchains. The problem is that
`t.Parallel` stops the closure and lets the loop continue, and then it
runs all the closures in parallel when ‘TestAllEven’ returns. By the
time the if statement in the closure executes, the loop is done, and v
has its final iteration value, 6. All four subtests now continue
executing in parallel, and they all check that 6 is even, instead of
checking each of the test cases. There is no race in this code,
because `t.Parallel` orders all the `v&1` tests after the final update
to `v` during the range loop, so the test passes even using `go test
-race`. Of course, real-world examples are typically much more
complex.

Another common form of this bug is preparing test case data by
building slices of pointers. For example this code, similar to an example at
the start of the document, builds a `[]*int32` for use as a repeated int32
in a protocol buffer:

```
func GenerateTestIDs() {
	var ids []*int32
	for i := int32(0); i < 10; i++ {
		ids = append(ids, &i)
	}
}
```

This loop aims to create a slice of ten different pointers to the
values 0 through 9, but instead it creates a slice of ten of the same
pointer, each pointing to 10.

For any of these loops, there are two useful rewrites. The first is to
remove the use of `:=`. For example:

```
func TestAllEven(t *testing.T) {
	testCases := []int{1, 2, 4, 6}
	var v int // TODO: Likely loop scoping bug!
	for _, v = range testCases {
		t.Run("sub", func(t *testing.T) {
			t.Parallel()
			if v&1 != 0 {
				t.Fatal("odd v", v)
			}
		})
	}
}
```

or


```
func GenerateTestIDs() {
	var ids []*int32
	var i int32 // TODO: Likely loop scoping bug!
	for i = int32(0); i < 10; i++ {
		ids = append(ids, &i)
	}
}
```

This kind of rewrite keeps tests passing even if compiled using the
proposed loop semantics. Of course, most of the time the tests are
passing incorrectly; this just preserves the status quo.

The other useful rewrite is to add an explicit `x := x` assignment, as
discussed in the [Go FAQ](https://go.dev/doc/faq#closures_and_goroutines).
For example:

```
func TestAllEven(t *testing.T) {
	testCases := []int{1, 2, 4, 6}
	for _, v := range testCases {
		v := v // TODO: This makes the test fail. Why?
		t.Run("sub", func(t *testing.T) {
			t.Parallel()
			if v&1 != 0 {
				t.Fatal("odd v", v)
			}
		})
	}
}
```

or


```
func GenerateTestIDs() {
	var ids []*int32
	for i := int32(0); i < 10; i++ {
		i := i // TODO: This makes the test fail. Why?
		ids = append(ids, &i)
	}
}
```

This kind of rewrite makes the test break using the current loop
semantics, and they will stay broken if compiled with the proposed
loop semantics. This rewrite is most useful for sending to the owners
of the code for further debugging.

Out of all the failing tests, only one affected loop was not in
test code. That code looked like:

```
var original *mapping
for _, saved := range savedMappings {
	if saved.start <= m.start && m.end <= saved.end {
		original = &saved
		break
	}
}
...
```

Unfortunately, this code was in a very low-level support program that
is invoked when a program is crashing, and a test checks that the code
contains no allocations or even runtime write barriers. In the old
loop semantics, both `original` and `saved` were function-scoped
variables, so the assignment `original = &saved` does not cause
`saved` to escape to the heap. In the new loop semantics, `saved` is
per-iteration, so `original = &saved` makes it escape the iteration
and therefore require heap allocation. The test failed because the
code is disallowed from allocating, yet it was now allocating. The fix
was to do the first kind of rewrite, declaring `saved` before the loop
and moving it back to function scope.

Similar code might change from allocating one variable per loop to
allocating N variables per loop. In some cases, that extra allocation
is inherent to fixing a latent bug. For example, `GenerateTestIDs`
above is now allocating 10 int32s instead of one – the price of
correctness. In a very frequently executed already-correct loop, the
new allocations may be unnecessary and could potentially cause more
garbage collector pressure and a measurable performance difference. If
so, standard monitoring and allocation profiles (`pprof
--alloc_objects`) should pinpoint the location easily, and the fix is
trivial: declare the variable above the loop. Benchmarking of the
public “bent” bench suite showed no statistically significant
performance difference over all, so we expect most programs to be
unaffected.

Not all the failing tests used code as obvious as the examples above.
One failing test that didn't use t.Parallel reduced to:

```
var once sync.Once
for _, tt := range testCases {
    once.Do(func() {
        http.HandleFunc("/handler", func(w http.ResponseWriter, r *http.Request) {
            w.Write(tt.Body)
        })
    })

    result := get("/handler")
    if result != string(tt.Body) {
        ...
    }
}
```

This strange loop registers an HTTP handler on the first iteration and
then makes a request served by the handler on every iteration. For the
handler to serve the expected data, the `tt` captured by the handler
closure must be the same as the `tt` for the current iteration. With a
per-loop `tt`, that's true. With a per-iteration `tt`, it's not: the
handler keeps using the first iteration's `tt` even in later
iterations, causing the failure.

As difficult as that example may be to puzzle through, it is a
simplified version of the original. The bisect tool pinpointing the
exact loop was a huge help in finding the problem.

Our experience supports the claim that the new semantics fixes buggy
code far more often than it breaks correct code. The new semantics
only caused test failures in about 1 of every 8,000 test packages,
but running the updated Go 1.20 `loopclosure` vet check over our entire
code base flagged tests at a much higher rate: 1 in 400 (20 in 8,000).
The loopclosure checker has no false positives: all the reports are buggy
uses of t.Parallel in our source tree.
That is, about 5% of the flagged tests were like `TestAllEvenBuggy`;
the other 95% were like `TestAllEven`: not (yet) testing what it intended,
but a correct test of correct code even with the loop variable bug fixed.

Of course, there is always the possibility that Google’s tests may not
be representative of the overall ecosystem’s tests in various ways,
and perhaps this is one of them. But there is no indication from this
analysis of _any_ common idiom at all where per-loop semantics are
required. Also, Google's tests include tests of open source Go
libraries that we use, and there were only two failures, both reported
upstream. Finally, the git log analysis points in the same direction:
parts of the ecosystem are adopting tools with very high false
positive rates and doing what the tools say, with no apparent
problems.

To be clear, it _is_ possible to write artificial examples of code
that is “correct” with per-loop variables and “incorrect” with
per-iteration variables but these are contrived.

One example, with credit to Tim King, is a convoluted way to sum the
numbers in a slice:

```
func sum(list []int) int {
	m := make(map[*int]int)
	for _, x := range list {
		m[&x] += x
	}
	for _, sum := range m {
		return sum
	}
	return 0
}
```

In the current semantics there is only one `&x` and therefore only one
map entry. With the new semantics there are many `&x` and many map
entries, so the map does not accumulate a sum.

Another example, with credit to Matthew Dempsky, is a non-racy loop:

```
for i, x := 0, 0; i < 1; i++ {
	go func() { x++ }()
}
```

This loop only executes one iteration (starts just one goroutine), and
`x` is not read or written in the loop condition or post-statement.
Therefore the one created goroutine is the only code reading or
writing `x`, making the program race-free. The rewritten semantics
would have to make a new copy of `x` for the next iteration when it
runs `i++`, and that copying of `x` would race with the `x++` in the
goroutine, making the rewritten program have a race. This example
shows that it is possible for the new semantics to introduce a race
where there was no race before. (Of course, there would be a race in
the old semantics if the loop iterated more than once.)

These examples show that it is technically possible for the
per-iteration semantics to change the correctness of existing code,
even if the examples are contrived. This is more evidence for the
gradual code repair approach.

### Changing 3-clause loops keeps all for loops consistent and fixes real-world bugs

Some people suggested only applying this change to range loops, not
three-clause for loops like `i := 0; i < n; i++`.

Adjusting the 3-clause form may seem strange to C programmers, but the
same capture problems that happen in range loops also happen in
three-clause for loops. Changing both forms eliminates that bug from
the entire language, not just one place, and it keeps the loops
consistent in their variable semantics. That consistency means that if
you change a loop from using range to using a 3-clause form or vice
versa, you only have to think about whether the iteration visits the
same items, not whether a subtle change in variable semantics will
break your code. It is also worth noting that JavaScript is using
per-iteration semantics for 3-clause for loops using let, with no
problems.

In Google's own code base, at least a few of the newly failing tests
were due to buggy 3-clause loops, like in the `GenerateTestIDs` example.
These 3-clause bugs happen less often, but they still happen at a high
enough rate to be worth fixing. The consistency arguments only add to
the case.

### Good tooling can help users identify exactly the loops that need the most scrutiny during the transition

As noted in the [transition discussion](#transition), our experience
analyzing the failures in Google’s Go tests shows that we can use
compiler instrumentation to identify loops that may be compiling
differently, because the compiler thinks the loop variables escape.
Almost all the time, this identifies a very small number of loops, and
one of those loops is right next to the failure. The automated bisect
tool removes even that small amount of manual effort.

### Static analysis is not a viable alternative

Whether a particular loop is “buggy” due to the current behavior
depends on whether the address of an iteration value is taken _and
then that pointer is used after the next iteration begins_. It is
impossible in general for analyzers to see where the pointer lands and
what will happen to it. In particular, analyzers cannot see clearly
through interface method calls or indirect function calls. Different
tools have made different approximations. Vet recognizes a few
definitely bad patterns in its `loopclosure` checker, and we added a
new pattern checking for mistakes using t.Parallel in Go 1.20. To
avoid false positives, `loopclosure` also has many false negatives.
Other checkers in the ecosystem err in the other direction. The commit
log analysis showed some checkers were producing over 90% false
positive rates in real code bases. (That is, when the checker was
added to the code base, the “corrections” submitted at the same time
were not fixing actual problems over 90% of the time in some commits.)

There is no perfect way to catch these bugs statically. Changing the
semantics, on the other hand, eliminates all the bugs.

### Mechanical rewriting to preserve old semantics is possible but mostly unnecessary churn

People have suggested writing a tool that rewrites _every_ for loop
flagged as changing by the compiler, preserving the old semantics by
removing the use of `:=`. Then a person could revert the loop changess
one at a time after careful code examination. A variant of this tool
might simply add a comment to each loop along with a `//go:build
go1.29` directive at the top of the file, leaving less for the person
to undo. This kind of tool is definitely possible to write, but our
experience with real Go code suggests that it would cause far more
churn than is necessary, since 95% of definitely buggy loops simply
became correct loops with the new semantics. The approach also assumes
that careful code examination will identify all buggy code, which in
our experience is an overly optimistic assumption. Even after bisected
test failures proved that specific loops were definitely buggy,
identifying the exact bug was quite challenging. And with the
rewriting tool, you don't even know for sure that the loop is buggy,
just that the compiler would treat it differently.

All in all, we believe that the combination of being able to generate
the compiler's report of changed positions is sufficient on the static
analysis side, along with the bisect tool to track down the source of
recognized misbehaviors. Of course, users who want a rewriting tool
can easily use the compiler's report to write one, especially if the
rewrite only adds comments and `//go:build` directives.

### Changing loop syntax entirely would cause unnecessary churn

We have talked in the past about introducing a different syntax for
loops (for example, #24282), and then giving the new syntax the new
semantics while deprecating the current syntax. Ultimately this would
cause a very significant amount of churn disproportionate to the
benefit: the vast majority of existing loops are correct and do not
need any fixes. In Google's Go source tree, rate of buggy loops was
about 1 per 20,000. It would be a truly extreme response to force an
edit of every for loop that exists today, invalidate all existing
documentation, and then have two different for loops that Go
programmers need to understand for the rest of time, all to fix 1 bad
loop out of 20,000. Changing the semantics to match what people
overwhelmingly already expect provides the same value at far less
cost. It also focuses effort on newly written code, which tends to be
buggier than old code (because the old code has been at least
partially debugged already).

### Disallowing loop variable capture would cause unnecessary churn

Some people have suggested disallowing loop variable captures
entirely, which would certainly make it impossible to write a buggy
loop. Unfortunately, that would also invalidate essentially every Go
program in existence, the vast majority of which are correct. It would
also make loop variables less capable than ordinary variables, which
would be strange. Even if this were just a temporary state, with loop
captures allowed again after the semantic change, that's a huge amount
of churn to catch the 0.005% of for loops that are buggy.

### Experience from C# supports the change

Early versions of C# had per-loop variable scoping for their
equivalent of range loops. C# 5 changed the semantics to be
per-iteration, as in this proposal. (C# 5 did not change the 3-clause
for loop form, in contrast to this proposal.)

In a comment on the GitHub discussion, [@jaredpar reported](https://github.com/golang/go/discussions/56010#discussioncomment-3788526)
on experience with C#. Quoting that comment in full:

> I work on the C# team and can offer perspective here.
>
> The C# 5 rollout unconditionally changed the `foreach` loop variable
> to be per iteration. At the time of C# 5 there was no equivalent to
> Go's putting `go 1.30` in a go.mod file so the only choice was break
> unconditionally or live with the behavior. The loop variable lifetime
> became a bit of a sore point pretty much the moment the language
> introduced lambda expressions for all the reasons you describe. As the
> language grew to leverage lambdas more through features like LINQ,
> `async`, Task Parallel Libraries, etc ... the problem got worse. It
> got so prevalent that the C# team decided the unconditional break was
> justified. It would be much easier to explain the change to the,
> hopefully, small number of customers impacted vs. continuing to
> explain the tricksy behavior to new customers.
>
> This change was not taken lightly. It had been discussed internally
> for several years, [blogs were written about it](https://ericlippert.com/2009/11/12/closing-over-the-loop-variable-considered-harmful-part-one/),
> lots of analysis of customer code, upper management buy off, etc ...
> In end though the change was rather anticlimactic. Yes it did break a
> small number of customers but it was smaller than expected. For the
> customers impacted they responded positively to our justifications and
> accepted the proposed code fixes to move forward.
>
> I'm one of the main people who does customer feedback triage as well
> as someone who helps customers migrating to newer versions of the
> compiler that stumble onto unexpected behavior changes. That gives me
> a good sense of what _pain points_ exist for tooling migration. This
> was a small blip when it was first introduced but quickly faded. Even
> as recently as a few years ago I was helping large code bases upgrade
> from C# 4. While they do hit other breaking changes we've had, they
> rarely hit this one. I'm honestly struggling to remember the last time
> I worked with a customer hitting this.
>
> It's been ~10 years since this change was taken to the language and a
> lot has changed in that time. Projects have a property `<LangVersion>`
> that serves much the same purpose as the Go version in the go.mod
> file. These days when we introduce a significant breaking change we
> tie the behavior to `<LangVersion>` when possible. That helps
> separates the concept for customers of:
>
> 1. Acquiring a new toolset. This comes when you upgrade Visual Studio
> or the .NET SDK. We want these to be _friction free_ actions so
> customers get latest bug / security fixes. This never changes
> `<LangVersion>` so breaks don't happen here.
>
> 2. Moving to a new
> language version. This is an explicit action the customer takes to
> move to a new .NET / C# version. It is understood this has some cost
> associated with it to account for breaking changes.
>
> This separation has been very successful for us and allowed us to make
> changes that would not have been possible in the past. If we were
> doing this change today we'd almost certainly tie the break to a
> `<LangVersion>` update

## Implementation

The actual semantic changes are implemented in the compiler today in
an opt-in basis and form the basis of the experimental data. The
transition support tooling also exists today.

Anyone is welcome to try the change in their own trees to help inform
their understanding of the impact of the change. Specifically:

	go install golang.org/dl/gotip@latest
	gotip download
	GOEXPERIMENT=loopvar gotip test etc

will compile all Go code with the new per-iteration loop variables
(that is, a global change, ignoring `go.mod` settings). To add
compiler diagnostics about loops that are compiling differently:

	GOEXPERIMENT=loopvar gotip build -gcflags=all=-d=loopvar=2

Omit the `all=` to limit the diagnostics to the current package. To
debug a test failure that only happens with per-iteration loop
variables enabled, use:

	go install golang.org/x/tools/cmd/bisect@latest
	bisect -compile=loopvar gotip test the/failing/test

Other implementation work yet to be done includes documentation,
updating vet checks like loopclosure, and coordinating with the
authors of tools like staticcheck and golangci-lint. We should also
update `go fix` to remove redundant `x := x` lines from source files
that have opted in to the new semantics.

### Google testing

As noted above, we have already enabled the new loop semantics for all
code built by Google's internal Go toolchain, with only a small number
of affected tests. We will update this section to summarize any
production problems encountered.

As of May 9, it has been almost a week since the change was enabled,
and there have been no production problems, nor any bug reports of any kind.

### Timeline and Rollout

The general rule for proposals is to avoid speculating about specific
releases that will include a change. The proposal process does not
rush to meet arbitrary deadlines: we will take the time necessary to
make the right decision and, if accepted, to land the right changes
and support. That general rule is why this proposal has been referring
to Go 1.30, as a placeholder for the release that includes the new
loop semantics.

That said, the response to the [preliminary discussion of this idea](https://go.dev/issue/56010)
was enthusiastically positive, and we have no reason to expect a
different reaction to this formal proposal. Assuming that is the case,
it could be possible to ship the change in Go 1.22. Since the
GOEXPERIMENT support will ship in Go 1.21, once the proposal is
accepted and Go 1.21 is released, it would make sense to publish a
short web page explaining the change and encouraging users to try it
in their programs, like the instructions above. If the proposal is
accepted before Go 1.21 is released, that page could be published with
the release, including a link to the page in the Go 1.21 release
notes. Whenever the instructions are published, it would also make
sense to publish a blog post highlighting the upcoming change. It will
in general be good to advertise the change in as many ways as
possible.

## Open issues (if applicable)

### Bazel language version

Bazel's Go support (`rules_go`) does not support setting the language
version on a per-package basis. It would need to be updated to do
that, with gazelle maintaining that information in generated BUILD
files (derived from the `go.mod` files).

### Performance on other benchmark suites

As noted above, there is a potential for new allocations in programs
with the new semantics, which may cause changes in performance.
Although we observed no performance changes in the “bent” benchmark
suite, it would be good to hear reports from others with their own
benchmark suites.

