# Generics — Problem Overview

Russ Cox\
August 27, 2018

## Introduction

This overview and the accompanying
[detailed draft design](go2draft-contracts.md)
are part of a collection of [Go 2 draft design documents](go2draft.md).
The overall goal of the Go 2 effort is to address
the most significant ways that Go fails to scale
to large code bases and large developer efforts.

The Go team, and in particular Ian Lance Taylor,
has been investigating and discussing possible designs for "generics"
(that is, parametric polymorphism; see note below)
since before Go’s first open source release.
We understood from experience with C++ and Java
that the topic was rich and complex and would take
a long time to understand well enough to design a good solution.
Instead of attempting that at the start,
we spent our time on features more directly applicable to Go’s initial target
of networked system software (now "cloud software"),
such as concurrency, scalable builds, and low-latency garbage collection.

After the release of Go 1, we continued to explore various possible
designs for generics, and in April 2016 we
[released those early designs](https://go.googlesource.com/proposal/+/master/design/15292-generics.md#),
discussed in detail below.
As part of re-entering "design mode" for the Go 2 effort, we are again
attempting to find a design for generics that we feel fits well into
the language while providing enough of the flexibility and
expressivity that users want.

Some form of generics was one of the top two requested features in both the
[2016](https://blog.golang.org/survey2016-results) and
[2017](https://blog.golang.org/survey2017-results)
Go user surveys (the other was package management).
The Go community maintains a
"[Summary of Go Generics Discussions](https://docs.google.com/document/d/1vrAy9gMpMoS3uaVphB32uVXX4pi-HnNjkMEgyAHX4N4/view#heading=h.vuko0u3txoew)"
document.

Many people have concluded (incorrectly) that the Go team’s position
is "Go will never have generics." On the contrary, we understand the
potential generics have, both to make Go far more flexible and
powerful and to make Go far more complicated.
If we are to add generics, we want to do it in a way that gets as much
flexibility and power with as little added complexity as possible.

_Note on terminology_: Generalization based on type parameters was
called parametric polymorphism when it was
[first identified in 1967](http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.332.3161&rep=rep1&type=pdf)
and for decades thereafter in the functional programming community.
The [GJ proposal](http://homepages.inf.ed.ac.uk/wadler/papers/gj-oopsla/gj-oopsla-letter.pdf),
which led to adding parametric polymorphism in Java 5, changed the
terminology first to "genericity" and eventually to "generics".
All imperative languages since Java that have added support for
parametric polymorphism have called it "generics." We make no
distinction between the terms, but it is important to emphasize that
"generics" means more than just generic data containers.

## Problem

To scale Go to large code bases and developer efforts, it is important that code reuse work well.
Indeed, one early focus for Go was simply to make sure that programs consisting of many independent packages built quickly, so that code reuse was not too expensive.
One of Go’s key distinguishing features is its approach to interfaces, which are also targeted directly at code reuse.
Specifically, interfaces make it possible to write abstract implementations of algorithms that elide unnecessary detail.
For example,
[container/heap](https://godoc.org/container/heap)
provides heap-maintenance algorithms as ordinary functions that operate on a
[heap.Interface](https://godoc.org/container/heap#Interface),
making them applicable to any backing storage, not just a slice of values.
This can be very powerful.

At the same time, most programmers who want a priority queue
don’t want to implement the underlying storage for it and then invoke the heap algorithms.
They would prefer to let the implementation manage its own array,
but Go does not permit expressing that in a type-safe way.
The closest one can come is to make a priority queue of `interface{}` values
and use type assertions after fetching each element.
(The standard [`container/list`](https://golang.org/pkg/container/list)
and [`container/ring`](https://golang.org/pkg/container/ring) implementations take this approach.)

Polymorphic programming is about more than data containers.
There are many general algorithms we might want to implement
as plain functions that would apply to a variety of types,
but every function we write in Go today must apply to only a single type.
Examples of generic functions we’d like to write include:

	// Keys returns the keys from a map.
	func Keys(m map[K]V) []K

	// Uniq filters repeated elements from a channel,
	// returning a channel of the filtered data.
	func Uniq(<-chan T) <-chan T

	// Merge merges all data received on any of the channels,
	// returning a channel of the merged data.
	func Merge(chans ...<-chan T) <-chan T

	// SortSlice sorts a slice of data using the given comparison function.
	func SortSlice(data []T, less func(x, y T) bool)

[Doug McIlroy has suggested](https://golang.org/issue/26282) that Go add two new
channel primitives `splice` and `clone`.
These could be implemented as polymorphic functions instead.

The
"[Go should have generics](https://go.googlesource.com/proposal/+/master/design/15292-generics.md#)" proposal
and the "[Summary of Go Generics Discussions](https://docs.google.com/document/d/1vrAy9gMpMoS3uaVphB32uVXX4pi-HnNjkMEgyAHX4N4/view#heading=h.vuko0u3txoew)"
contain additional discussion of the problem.

## Goals

Our goal is to address the problem of writing Go libraries that
abstract away needless type detail, such as the examples in the
previous section, by allowing parametric polymorphism with type
parameters.

In particular, in addition to the expected container types, we aim to
make it possible to write useful libraries for manipulating arbitrary
map and channel values, and ideally to write polymorphic functions
that can operate on both `[]byte` and `string` values.

It is not a goal to enable other kinds of parameterization, such as
parameterization by constant values.
It is also not a goal to enable specialized implementations of
polymorphic definitions, such as defining a general `vector<T>` and a
special-case `vector<bool>` using bit-packing.

We want to learn from and avoid the problems that generics have caused
for C++ and in Java (described in detail in the section about other
languages, below).

To support
[software engineering over time](https://research.swtch.com/vgo-eng),
generics for Go must record constraints on type parameters explicitly,
to serve as a clear, enforced agreement between caller and
implementation.
It is also critical that the compiler report clear errors when a
caller does not meet those constraints or an implementation exceeds
them.

Polymorphism in Go must fit smoothly into the surrounding language,
without awkward special cases and without exposing implementation
details.
For example, it would not be acceptable to limit type parameters to
those whose machine representation is a single pointer or single word.
As another example, once the general `Keys(map[K]V) []K` function
contemplated above has been instantiated with `K` = `int` and `V` = `string`,
it must be treated semantically as equivalent to a hand-written
non-generic function.
In particular it must be assignable to a variable of type `func(map[int]string) []int`.

Polymorphism in Go should be implementable both at compile time (by
repeated specialized compilation, as in C++) and at run time, so that
the decision about implementation strategy can be left as a decision
for the compiler and treated like any other compiler optimization.
This flexibility would address the
[generic dilemma](https://research.swtch.com/generic) we’ve discussed
in the past.

Go is in large part a language that is straightforward and
understandable for its users.
If we add polymorphism, we must preserve that.

## Draft Design

This section quickly summarizes the draft design, as a basis for
high-level discussion and comparison with other approaches.

The draft design adds a new syntax for introducing a type parameter
list in a type or function declaration: `(type` <_list of type names_>`)`.
For example:

	type List(type T) []T

	func Keys(type K, V)(m map[K]V) []K

Uses of a parameterized declaration supply the type arguments using ordinary call syntax:

	var ints List(int)

	keys := Keys(int, string)(map[int]string{1:"one", 2: "two"})

The generalizations in these examples require nothing of the types `T`,
`K`, and `V`: any type will do.
In general an implementation may need to constrain the possible types
that can be used.
For example, we might want to define a `Set(T)`, implemented as a list
or map, in which case values of type `T` must be able to be compared for
equality.
To express that, the draft design introduces the idea of a named
**_contract_**.
A contract is like a function body illustrating the operations the
type must support.
For example, to declare that values of type `T` must be comparable:

	contract Equal(t T) {
		t == t
	}

To require a contract, we give its name after the list of type parameters:

	type Set(type T Equal) []T

	// Find returns the index of x in the set s,
	// or -1 if x is not contained in s.
	func (s Set(T)) Find(x T) int {
		for i, v := range s {
			if v == x {
				return i
			}
		}
		return -1
	}

As another example, here is a generalized `Sum` function:

	contract Addable(t T) {
		t + t
	}

	func Sum(type T Addable)(x []T) T {
		var total T
		for _, v := range x {
			total += v
		}
		return total
	}

Generalized functions are invoked with type arguments
to select a specialized function and then invoked again with their value arguments:

	var x []int
	total := Sum(int)(x)

As you might expect, the two invocations can be split:

	var x []int
	intSum := Sum(int) // intSum has type func([]int) int
	total := intSum(x)

The call with type arguments can be omitted, leaving only the call with values,
when the necessary type arguments can be inferred from the values:

	var x []int
	total := Sum(x) // shorthand for Sum(int)(x)

More than one type parameter is also allowed in types, functions, and contracts:

	contract Graph(n Node, e Edge) {
		var edges []Edge = n.Edges()
		var nodes []Node = e.Nodes()
	}

	func ShortestPath(type N, E Graph)(src, dst N) []E

The contract is applied by default to the list of type parameters, so that `(type T Equal)` is shorthand for `(type T Equal(T))`,
and `(type N, E Graph)` is shorthand for `(type N, E Graph(N, E))`.

For details, see the [draft design](go2draft-contracts.md).

## Discussion and Open Questions

This draft design is meant only as a starting point for community discussion.
We fully expect the details to be revised based on feedback and especially experience reports.
This section outlines some of the questions that remain to be answered.

Our previous four designs for generics in Go all had significant problems, which we identified very quickly.
The current draft design appears to avoid the problems in the earlier ones: we’ve spent about half a year discussing and refining it so far and still believe it could work.
While we are not formally proposing it today, we think it is at least a good enough starting point for a community discussion with the potential to lead to a formal proposal.

Even after six months of (not full time) discussion, the design is still in its earliest stages.
We have written a parser but no type checker and no implementation.
It will be revised as we learn more about it.
Here we identify a few important things we are unsure about, but there are certainly more.

**Implied constraints**.
One of the examples above applies to maps of arbitrary key and value type:

	func Keys(type K, V)(m map[K]V) []K {
		...
	}

But not all types can be used as key types,
so this function should more precisely be written as:

	func Keys(type K, V Equal(K))(m map[K]V) []K {
		...
	}

It is unclear whether that precision about
`K` should be required of the user or inferred
from the use of `map[K]V` in the function signature.

**Dual implementation**.
We are hopeful that the draft design satisfies the
"dual-implementation" constraint mentioned above,
that every parameterized type or function can be implemented
either by compile-time or run-time type substitution,
so that the decision becomes purely a compiler optimization, not one of semantic significance.
But we have not yet confirmed that.

One consequence of the dual-implementation constraint
is that we have not included support for type parameters in method declarations.
The most common place where these arise is in modeling functional operations on general containers.
It is tempting to allow:

	// A Set is a set of values of type T.
	type Set(type T) ...

	// Apply applies the function f to each value in the set s,
	// returning a set of the results.
	func (s Set(T)) Apply(type U)(f func(T) U) Set(U)  // NOT ALLOWED!

The problem here is that a value of type `Set(int)`
would require an infinite number of `Apply` methods to be available at runtime,
one for every possible type `U`, all discoverable by reflection and type assertions.
They could not all be compiled ahead of time.
An earlier version of the design allowed generic methods but then disallowed their visibility in reflection and interface satisfaction, to avoid forcing the run-time implementation of generics.
Disallowing generalized methods entirely seemed cleaner than allowing them with these awkward special cases.
Note that it is still possible to write `Apply` as a top-level function:

	func Apply(type T, U)(s Set(T), f func(T) U) Set(U)

Working within the intersection of compile-time and run-time implementations also requires being able to reject parameterized functions or types that cause generation of an arbitrary (or perhaps just very large) number of additional types.
For example, here are a few unfortunate programs:

	// OK
	type List(type T) struct {
		elem T
		next *List(T)
	}

	// NOT OK - Implies an infinite sequence of types as you follow .next pointers.
	type Infinite(type T) struct {
		next *Infinite(Infinite(T))
	}

	// BigArray(T)(n) returns a nil n-dimensional slice of T.
	// BigArray(int)(1) returns []int
	// BigArray(int)(2) returns [][]int
	// ...
	func BigArray(type T)(n int) interface{} {
		if n <= 1 || n >= 1000000000 {
			return []T(nil)
		}
		return BigArray([]T)(n-1)
	}

It is unclear what the algorithm is for deciding which programs to accept and which to reject.

**Contract bodies**.
Contracts are meant to look like little functions.
They use a subset of function body syntax,
but the actual syntax is much more limited than just "any Go code" (see the full design for details).
We would like to understand better if it is feasible to allow any valid function body as a contract body.
The hard part is defining precisely which generic function bodies are allowed by a given contract body.

There are parallels with the C++ concepts design (discussed in detail below): the definition of a C++ concept started out being exactly a function body illustrating the necessary requirements, but over time the design changed to use a more limited list of requirements of a specific form.
Clearly it was not workable in C++ to support arbitrary function bodies.
But Go is a simpler language than C++ and it may be possible here.
We would like to explore whether it is possible to implement contract body syntax as exactly function body syntax and whether that would be simpler for users to understand.

**Feedback**.
The most useful general feedback would be examples of interesting uses that are enabled or disallowed by the draft design.
We’d also welcome feedback about the points above, especially based on experience type-checking or implementing generics in other languages.

We are most uncertain about exactly what to allow in contract bodies, to make them as easy to read and write for users while still being sure the compiler can enforce them as limits on the implementation.
That is, we are unsure about the exact algorithm to deduce the properties required for type-checking a generic function from a corresponding contract.
After that we are unsure about the details of a run-time-based (as opposed to compile-time-based) implementation.

Feedback on semantics and implementation details is far more useful and important than feedback about syntax.

We are collecting links to feedback at
[golang.org/wiki/Go2GenericsFeedback](https://golang.org/wiki/Go2GenericsFeedback).

## Designs in Other Languages

It is worth comparing the draft design with those in real-world use, either now or in the past.
We are not fluent programmers in many of these languages.
This is our best attempt to piece together the history, including links to references, but we would welcome corrections about the syntax, semantics, or history of any of these.

The discussion of other language designs in this section focuses on the specification of type constraints and also implementation details and problems, because those ended up being the two most difficult parts of the Go draft design for us to work out.
They are likely the two most difficult parts of any design for parametric polymorphism.
In retrospect, we were biased too much by experience with C++ without concepts and Java generics. We would have been well-served to spend more time with CLU and C++ concepts earlier.

We’ll use the `Set`, `Sum`, and `ShortestPath` examples above as points of comparison throughout this section.

### ML, 1975

ML was the first typed language to incorporate polymorphism.

Christopher Strachey is usually given credit for introducing the term parametric polymorphism in his 1967 survey, "[Fundamental Concepts in Programming Languages](http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.332.3161&rep=rep1&type=pdf)."

Robin Milner’s 1978 paper "[A Theory of Type Polymorphism in Programming](https://courses.engr.illinois.edu/cs421/sp2013/project/milner-polymorphism.pdf)" introduced an algorithm to infer the most general types of polymorphic function bodies, instead of forcing the use of concrete types.
Milner had already implemented his algorithm for the ML language as part of the Edinburgh LCF system.
He wanted to be able to write the kinds of general functions possible in LISP, but in a typed language.

ML inferred constraints and for that matter the types themselves from the untyped function body.
But the inference was limited - there were no objects, classes, methods, or operators, just values (including function values).
There was not even equality checking.

Milner
[suggested adding "equality types"](http://www.lfcs.inf.ed.ac.uk/reports/87/ECS-LFCS-87-33/ECS-LFCS-87-33.pdf) in 1987, distinguishing a type variable with no constraints (`'t`) from a type variable that must represent a type allowing equality checks (`''t`).

The
[Standard ML of New Jersey compiler](https://www.cs.princeton.edu/research/techreps/TR-097-87) (1987) implements polymorphic functions by arranging that every value is
[represented as a single machine word](https://www.cs.princeton.edu/research/techreps/TR-142-88).
That uniformity of representation, combined with the near-complete lack of type constraints, made it possible to use one compiled body for all invocations.
Of course, boxing has its own allocation time and space overheads.

The
[MLton whole-program optimizing compiler](http://mlton.org/History) (1997) specializes polymorphic functions at compile time.

### CLU, 1977

The research language CLU, developed by Barbara Liskov’s group at MIT, was the first to introduce what we would now recognize as modern generics.
(CLU also introduced iterators and abstract data types.)

[CLU circa 1975](http://csg.csail.mit.edu/CSGArchives/memos/Memo-112-1.pdf) allowed defining parameterized types without constraints, much like in ML.
To enable implementing a generic set despite the lack of constraints, all types were required to implement an equal method.

By 1977,
[CLU had introduced "where clauses"](https://web.eecs.umich.edu/~weimerw/2008-615/reading/liskov-clu-abstraction.pdf) to constrain parameterized types, allowing the set implementation to make its need for `equal` explicit.
CLU also had operator methods, so that `x == y` was syntactic sugar for `t$equal(x, y)` where `t` is the type of both `x` and `y`.

	set = cluster [t: type] is create, member, size, insert, delete, elements
	        where t has equal: proctype (t, t) returns (bool)
	    rep = array[t]
	    % implementation of methods here, using == on values of type t
	end set

The more complex graph example is still simple in CLU:

	shortestpath = proc[node, edge: type] (src, dst: node) returns array[edge]
	        where node has edges: proctype(node) returns array[edge],
	              edge has nodes: proctype(edge) returns array[node]
	    ...
	end shortestpath

The 1978 paper "[Aspects of Implementing CLU](http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.106.3516&rep=rep1&type=pdf)" discusses the compile-time versus run-time implementations of parameterized generics and details CLU's run-time-only approach.
The "BigArray" function shown earlier is also taken from this paper (translated to Go, of course).

All the ingredients for modern generics are here: syntax for declaring generalized types and functions, syntax for invoking them, a simple constraint syntax, and a well thought-out implementation.
There was no inference of type parameters.
The CLU designers found it helpful to see all substitutions made explicitly.

In her 1992 retrospective  "[A History of CLU](http://citeseerx.ist.psu.edu/viewdoc/download;jsessionid=F5D7C821199F22C5D30A51F155DB9D23?doi=10.1.1.46.9499&rep=rep1&type=pdf)," Liskov observed, "CLU was way ahead of its time in its solution for parameterized modules.
Even today, most languages do not support parametric polymorphism, although there is growing recognition of the need for it."

### Ada, 1983

Ada clearly lifted many ideas from CLU, including the approach for exceptions and parametric polymorphism, although not the elegant syntax.
Here is an example generic squaring function from the
[Ada 1983 spec](https://swtch.com/ada-mil-std-1815a.pdf), assembled from pages 197, 202, and 204 of the PDF.
The generic declaration introduces a parameterized "unit" and then the function declaration appears to come separately:

	generic
		type ITEM Is private;
		with function "*"(U, V ITEM) return ITEM is <>;
	function SQUARING(X : ITEM) return ITEM;

	function SQUARING(X : ITEM) return ITEM is
	begin
		return X*X;
	end;

Interestingly, this definition introduces a function SQUARING parameterized by both the type ITEM and the * operation.
If instantiated using type INTEGER, the * operation is taken from that type:

	function SQUARE is new SQUARING (INTEGER);

But the * operation can also be substituted directly, allowing definition of a matrix squarer using the MATRIX-PRODUCT function.
These two instantiations are equivalent:

	function SQUARE is new SQUARING (ITEM -> MATRIX, "*'" => MATRIX-PRODUCT);
	function SQUARE is new SQUARING (MATRIX, MATRIX-PRODUCT);

We have not looked into how Ada generics were implemented.

The initial Ada design contest
[ran from 1975-1980 or so](https://www.red-gate.com/simple-talk/opinion/geek-of-the-week/tucker-taft-geek-of-the-week/), resulting eventually in the Ada 83 standard in 1983.
We are not sure exactly when generics were added.

### C++, 1991

[C++ introduced templates](http://www.stroustrup.com/hopl-almost-final.pdf) in 1991, in the Cfront 3.0 release.
The implementation was always by compile-time macro expansion, and there were no "where clauses" or other explicit constraints.

	template<typename T>

	class Set {
		...
		void Add(T item) {
			...
		}
	};

	template<typename T>
	T Sum(x vector<T>) {
		T s;
		for(int i = 0; i < x.size(); i++) {
			s += x[i];
		}
		return s;
	}

Instead, if a template was invoked with an inappropriate type, such as a Sum<char*>, the compiler reported a type-checking error in the middle of the invoked function’s body.
This was not terribly user-friendly and soured many developers on the idea of parametric polymorphism.
The lack of type constraints enabled the creation of the STL and transformed C++ into a wholly different language than it had been.
Then the problem became how to add explicit type constraints sufficiently expressive to allow all the tricks used in the STL.

Programmers worked around the lack of constraints by establishing conventions for expressing them.
Stroustrup’s 1994 book
[The Design and Evolution of C++](http://www.stroustrup.com/dne.html) gives some examples.
The first option is to define constraints as classes:

	template <class T> class Comparable {
		T& operator=(const T&);
		int operator==(const T&, const T&);
		int operator<=(const T&, const T&);
		int operator<(const T&, const T&);
	};
	template <class T : Comparable>
		class vector {
			// ...
		};

Unfortunately, this requires the original type `T` to explicitly derive from `Comparable`.
Instead, Stroustrup suggested writing a function, conventionally named `constraints`, illustrating the requirements:

	template<class T> class X {
		// ...
		void constraints(T* tp)
		{	             // T must have:
			B* bp = tp;  //   an accessible base B
			tp->f();     //   a member function f
			T a(l);      //   a constructor from int
			a = *tp;     //   assignment
			// ...
		}
	};

Compiler errors would at least be simple, targeted, and reported as a problem with `X<T>::constraints`.
Of course, nothing checked that other templates used only the features of T illustrated in the constraints.

In 2003, Stroustrup proposed formalizing this convention as
[C++ concepts](http://www.stroustrup.com/N1522-concept-criteria.pdf).
The feature was intended for C++0x (eventually C++11 (2011)) but
[removed in 2009](http://www.drdobbs.com/cpp/the-c0x-remove-concepts-decision/218600111).
Concepts were published as a
[separate ISO standard in 2015](https://www.iso.org/standard/64031.html), shipped in GCC, and were intended for C++17 (2017)
[but removed in 2016](http://honermann.net/blog/2016/03/06/why-concepts-didnt-make-cxx17/).
They are now intended for C++20 (2020).

The 2003 proposal gives this syntax:

	concept Element {
		constraints(Element e1, Element e2) {
			bool b = e1<e2;  // Elements can be compared using <
			swap(e1,e2);     // Elements can be swapped
		}
	};

By 2015, the syntax had changed a bit but the underlying idea was still the same.
Stroustrup’s 2015 paper "[Concepts: The Future of Generic Programming, or How to design good concepts and use them well](http://www.stroustrup.com/good_concepts.pdf)" presents as an example a concept for having equality checking.
(In C++, `==` and `!=` are unrelated operations so both must be specified.)

	template<typename T>
	concept bool Equality_comparable =
	requires (T a, T b) {
		{ a == b } -> bool; // compare Ts with ==
		{ a != b } -> bool; // compare Ts with !=
	};

A requires expression evaluates to true if each of the listed requirements is satisfied, false otherwise.
Thus `Equality_comparable<T>` is a boolean constant whose value depends on `T`.

Having defined the predicate, we can define our parameterized set:

	template<Equality_comparable T>
	class Set {
		...
	};

	Set<int> set;
	set.Add(1);

Here the `<Equality_comparable T>` introduces a type variable `T` with the constraint that `Equality_comparable<T> == true`.
The class declaration above is shorthand for:

	template<typename T>
		requires Equality_comparable<T>
	class Set {
		...
	};

By allowing a single concept to constrain a group of related types, the C++ concept proposal makes it easy to define our shortest path example:

	template<typename Node, typename Edge>
	concept bool Graph =
		requires(Node n, Edge e) {
			{ n.Edges() } -> vector<Edge>;
			{ e.Nodes() } -> vector<Node>;
		};

	template<typename Node, Edge>
		requires Graph(Node, Edge)
	vector<Edge> ShortestPath(Node src, Node dst) {
		...
	}

### Java, 1997-2004

In 1997, Martin Odersky and Philip Wadler introduced
[Pizza](http://pizzacompiler.sourceforge.net/doc/pizza-language-spec.pdf), a strict superset of Java, compiled to Java bytecodes, adding three features from functional programming: parametric polymorphism, higher-order functions, and algebraic data types.

In 1998, Odersky and Wadler, now joined by Gilad Bracha and David Stoutamire, introduced
[GJ](http://homepages.inf.ed.ac.uk/wadler/papers/gj-oopsla/gj-oopsla-letter.pdf), a Pizza-derived Java superset targeted solely at parametric polymorphism, now called generics.
The GJ design was adopted with minor changes in Java 5, released in 2004.

As seen in the example, this design uses interfaces to express type constraints, with the result that parameterized interfaces must be used to create common self-referential constraints such as having an equal method that checks two items of the same type for equality.
In CLU this constraint was written directly:

	set = cluster[t: type] ...
	        where t has equal: proctype(t, t) returns bool

 In Java 5, the same constraint is written indirectly, by first defining `Equal<T>`:

	interface Equal<T> {
		boolean equal(T o);
	}

Then the constraint is `T implements Equal<T>` as in:

	class Set<T implements Equal<T>> {
		...
		public void add(T o) {
			...
		}
	}

	Set<int> set;
	set.add(1);

This is Java’s variant of the C++ "[curiously recurring template pattern](https://en.wikipedia.org/wiki/Curiously_recurring_template_pattern)" and is a common source of confusion (or at least rote memorization) among Java programmers first learning generics.

The graph example is even more complex:

	interface Node<Edge> {
		List<Edge> Edges()
	}

	interface Edge<Node> {
		List<Node> Nodes()
	}

	class ShortestPath<N implements Node<E>, E implements Edge<N>> {
		static public List<Edge> Find(Node src, dst) {
			...
		}
	}

Java 4 and earlier had provided untyped, heterogeneous container classes like `List` and `Set` that used the non-specific element type `Object`.
Java 5 generics aimed to provide type parameterization for those legacy containers.
The originals became `List<Object>` and `Set<Object>`, but now programmers could also write `List<String>`, `List<Set<String>>`, and so on.

The implementation was by "type erasure," converting to the original untyped containers, so that at runtime there were only the unparameterized implementations `List` and `Set` (of `Object`).

Because the implementation needed to be memory-compatible with `List<Object>`, which is to say a list of pointers, Java value types like `int` and `boolean` could not be used as type parameters: no `List<int>`.
Instead there is `List<Integer>`, in which each element becomes an class object instead of a plain `int`, with all the associated memory and allocation overhead.

Because of the erasure, reflection on these values, including dynamic type checks using `instanceof`, has no information about the expected type of elements.
Reflection and code written using untyped collections like `List` or `Set` therefore served as back doors to bypass the new type system.
The inability to use `instanceof` with generics introduced other rough edges, such as not being able to define parameterized exception classes, or more precisely being able to throw an instance of a parameterized class but not catch one.

Angelika Langer has written an
[extensive FAQ](http://www.angelikalanger.com/GenericsFAQ/JavaGenericsFAQ.html), the size of which gives a sense of the complexity of Java generics.

Java 10 may add runtime access to type parameter information.

Experience watching the Java generics story unfold, combined with discussions with some of the main players, was the primary reason we avoided tackling any sort of generics in the first version of Go.
Since much of the complexity arose from the design being boxed in by pre-existing container types, we mostly avoided adding container types to the standard library ([`container/list`](https://golang.org/pkg/container/list)
and [`container/ring`](https://golang.org/pkg/container/ring) are the exceptions, but they are not widely used).

Many developers associate Java generics first with the complexity around container types.
That complexity, combined with the fact that Java lacks the concept of a plain function (such as `Sum`) as opposed to methods bound to a class, led to the common belief that generics means parameterized data structures, or containers, ignoring parameterized functions.
This is particularly ironic given the original inspiration from functional programming.

### C#, 1999-2005

C#, and more broadly the .NET Common Language Runtime (CLR), added
[support for generics](https://msdn.microsoft.com/en-us/library/ms379564(v=vs.80).aspx) in C# 2.0, released in 2005 and the culmination of
[research beginning in 1999](http://mattwarren.org/2018/03/02/How-generics-were-added-to-.NET/).

The syntax and definition of type constraints mostly follows Java’s, using parameterized interfaces.

Learning from the Java generics implementation experience, C# removes many of the rough edges.
It makes parameterization information available at runtime, so that reflection can distinguish `List<string>` from `List<List<string>>`.
It also allows parameterization to use basic types like int, so that `List<int>` is valid and efficient.

### D, 2002

D
[added templates in D 0.40](https://wiki.dlang.org/Language_History_and_Future), released in September 2002.
We have not tracked down the original design to see how similar it was to the current templates.
The current D template mechanism allows parameterizing a block of arbitrary code:

	template Template(T1, T2) {
		... code using T1, T2 ...
	}

The block is instantiated using `Template!` followed by actual types, as in `Template!(int, float64)`.
It appears that instantiation is always at compile-time, like in C++.
If a template contains a single declaration of the same name, the usage is shortened:

	template Sum(T) {
		T Sum(T[] x) {
			...
		}
	}

	int[] x = ...
	int sum = Sum!(int)(x) // short for Sum!(int).Sum(x)

This code compiles and runs, but it can be made clearer by adding an
[explicit constraint on `T`](https://dlang.org/concepts.html) to say that it must support equality:

	template hasEquals(T) {
		const hasEquals = __traits(compiles, (T t) {
			return t == t;
		});
	}

	template Sum(T) if (hasEquals!(T)) {
		T Sum(T []x) {
			...
		}
	}

The `__traits(compiles, ...)` construct is a variant of the C++ concepts idea (see C++ discussion above).

As in C++, because the constraints can be applied to a group of types, defining `Graph` does not require mutually-recursive gymnastics:

	template isGraph(Node, Edge) {
		const isGraph = __traits(compiles, (Node n, Edge e) {
			Edge[] edges = n.Edges();
			Node[] nodes = e.Nodes();
		});
	}

	template ShortestPath(Node, Edge)
			if (isGraph!(Node, Edge)) {
		Edge[] ShortestPath(Node src, Node dst) {
			...
		}
	}

### Rust, 2012

Rust
[included generics in version 0.1](https://github.com/rust-lang/rust/blob/master/RELEASES.md#version-01--2012-01-20), released in 2012.

Rust defines generics with syntax similar to C#, using traits (Rust’s interfaces) as type constraints.

Rust avoids Java’s and C#'s curiously-recurring interface pattern for direct self-reference by introducing a `Self` type.
For example, the protocol for having an `Equals` method can be written:

	pub trait Equals {
		fn eq(&self, other: &Self) -> bool;
		fn ne(&self, other: &Self) -> bool;
	}

(In Rust, `&self` denotes the method's receiver variable, written without an explicit type; elsewhere in the function signature, `&Self` can be used to denote the receiver type.)

And then our `Set` type can be written:

	struct Set<T: Equals> {
		...
	}

This is shorthand for

	struct Set<T> where T: Equals {
		...
	}

The graph example still needs explicitly mutually-recursive traits:

	pub trait Node<Edge> {
		fn edges(&self) -> Vec<Edge>;
	}
	pub trait Edge<Node> {
		fn nodes(&self) -> Vec<Node>;
	}

	pub fn shortest_path<N, E>(src: N, dst: N) -> Vec<E>
			where N: Node<E>, E: Edge<N> {
		...
	}

In keeping with its "no runtime" philosophy, Rust implements generics by compile-time expansion, like C++ templates.

### Swift, 2017

Swift added generics in Swift 4, released in 2017.

The
[Swift language guide](https://docs.swift.org/swift-book/LanguageGuide/Generics.html) gives an example of sequential search through an array, which requires that the type parameter `T` support equality checking. (This is a popular example; it dates back to CLU.)

	func findIndex<T: Equatable>(of valueToFind: T, in array:[T]) -> Int? {
		for (index, value) in array.enumerated() {
			if value == valueToFind {
				return index
			}
		}
		return nil
	}

Declaring that `T` satisfies the
[`Equatable`](https://developer.apple.com/documentation/swift/equatable) protocol makes the use of `==` in the function body valid.
`Equatable` appears to be a built-in in Swift, not possible to define otherwise.

Like Rust, Swift avoids Java’s and C#'s curiously recurring interface pattern for direct self-reference by introducing a `Self` type.
For example, the protocol for having an `Equals` method is:

	protocol EqualsMethod {
		func Equals(other: Self) -> Bool
	}

Protocols cannot be parameterized, but declaring "associated types" can be used for the same effect:

	protocol Node {
		associatedtype Edge;
		func Edges() -> [Edge];
	}
	protocol Edge {
		associatedtype Node;
		func Nodes() -> [Node];
	}

	func ShortestPath<N: Node, E: Edge>(src: N, dst: N) -> [E]
			where N.Edge == E, E.Node == N {
		...
	}

Swift’s default implementation of generic code is by single compilation with run-time substitution, via "[witness tables](https://www.reddit.com/r/swift/comments/3r4gpt/how_is_swift_generics_implemented/cwlo64w/?st=jkwrobje&sh=6741ba8b)".
The compiler is allowed to compile specialized versions of generic code as an optimization, just as we would like to do for Go.

## Earlier Go Designs

As noted above, the Go team, and in particular Ian Lance Taylor, has been investigating and discussing possible designs for "generics" since before the open source release.
In April 2016, we
[published the four main designs](https://go.googlesource.com/proposal/+/master/design/15292-generics.md) we most seriously considered (before the current one).
Looking back over the designs and comparing them to the current draft design, it is helpful to focus on four features that varied in the designs over time: syntax, type constraints, type inference, and implementation strategy.

**Syntax**.
How are generic types, funcs, or methods declared? How are generic types, funcs, or methods used?

**Type Constraints**.
How are type constraints defined?

**Type Inference**.
When can explicit function call type instantiations be omitted (inferred by the compiler)?

**Implementation**.
Is compile-time substitution required? Is run-time substitution required? Are both required? Can the compiler choose one or the other as it sees fit?

### [Type Functions](https://go.googlesource.com/proposal/+/master/design/15292/2010-06-type-functions.md), June 2010

The first design we explored was based on the idea of a "type function."

**Syntax.** "Type function" was the name for the syntax for a parameterized type.

	type Vector(T) []T

Every use of a type function had to specify concrete instantiations for the type variables, as in

	type VectorInt Vector(int)

Func definitions introduced type parameters implicitly by use of a type function or explicitly by use of an argument of type "`<name> type`", as in:

	func Sum(x Vector(T type)) T

	func Sum(x []T type) T

**Constraints.**
Type constraints were specified by optional interface names following the type parameter:

	type PrintableVector(T fmt.Stringer) []T

	func Print(x T type fmt.Stringer)

To allow use of operators like addition in generic code, this proposal relied upon a separate proposal to introduce "operator methods" (as in CLU), which would in turn make them available in interface definitions.

**Inference.** There were no function call type instantiations.
Instead there was an algorithm for determining the type instantiations, with no explicit fallback when the algorithm failed.

**Implementation.** Overall the goal was to enable writing complex type-independent code once, at a run-time cost: the implementation would always compile only a generic version of the code, which would be passed a type descriptor to supply necessary details.
This would make generics unsuitable for high-performance uses or even trivial uses like `Min` and `Max`.

If type `Vector(T)` defined a method `Read(b []T) (int, error)`, it was unclear how the generic `Read` implementation specialized to byte would necessarily be compatible in calling convention with `io.Reader`.

The proposal permitted the idea of unbound type parameters
that seemed to depend on unspecified runtime support, producing "generic values".
The doc uses as an example:

	func Unknown() T type

	x := Unknown()

It was not clear exactly what this meant or how it would be implemented.
Overall it seemed that the need for the concept of a "generic value" was an indicator that something was not quite right.

### [Generalized Types](https://go.googlesource.com/proposal/+/master/design/15292/2011-03-gen.md), March 2011

The next design we explored was called "generalized types," although type parameters applied equally to types and functions.

**Syntax.** A type variable was introduced by the syntax `gen [T]` before a declaration and instantiated by listing the types in square brackets after the declared name.

	gen[T] type Vector []T

	type VectorInt Vector[int]

	gen[T] func Sum(x []T) T

	gen[T] func Sum(x Vector[T]) T

	sum := Sum[int]([]int{1,2,3})

    gen[T1, T2] MakePair(x T1, y T2) Pair[T1, T2]

As an aside, we discussed but ultimately rejected reserving `gen` or `generic` as keywords for Go 1 in anticipation of adopting some proposal like this.
It is interesting to note that the current design avoids the need for any such keyword and does not seem to suffer for it.

**Constraints.** The type variable could be followed by an interface name:

	gen [T Stringer] type PrintableVector []T

	gen [T Stringer] func Print(x T)

The proposal suggested adding language-defined method names for operators, so that `Sum` could be written:

    gen [T] type Number interface {
    	Plus(T) T
    }

    gen [T Number[T]] func Sum(x []T) T {
    	var total T
    	for _, v := range x {
    		total = total.Plus(v)
    	}
    	return total
    }

**Inference.** This proposal defined a simple left-to-right greedy unification of the types of the function call arguments with the types of the generic parameter list.
The current proposal is non-greedy: it unifies the types, and then verifies that all type parameters were unified to the same type.
The reason the earlier proposal used a greedy algorithm was to handle untyped constants; in the current proposal untyped constants are handled by ignoring them in the first pass and doing a second pass if required.

**Implementation.** This proposal noted that every actual value in a running Go program would have a concrete type.
It eliminated the "generic values" of the previous proposal.

This was the first proposal that aimed to support both generic and specialized compilation, with an appropriate choice made by the compiler.
(Because the proposal was never implemented, it is unclear whether it would have achieved that goal.)

### [Generalized Types II](https://go.googlesource.com/proposal/+/master/design/15292/2013-10-gen.md), October 2013

This design was an adaptation of the previous design, at that point two years old, with only one significant change.
Instead of getting bogged down in specifying interfaces, especially interfaces for operators, the design discarded type constraints entirely.
This allowed writing `Sum` with the usual `+` operator instead of a new `.Plus` method:

	gen[T] func Sum(x []T) T {
		s := T(0)
		for _, v := range x {
			s += v
		}
		return s
	}

As such, it was the first generics design that did not call for operator methods as well.

Unfortunately, the design did not explain exactly how constraints could be inferred and whether that was even feasible.
Worse, if contracts are not written down, there’s no way to ensure that an API does not change its requirements accidentally and therefore break clients unexpectedly.

### [Type Parameters](https://go.googlesource.com/proposal/+/master/design/15292/2013-12-type-params.md), December 2013

This design kept most of the semantics of the previous design but introduced new syntax.
It dropped the gen keyword and moved the type-variable-introducing brackets after the func or type keyword, as in:

	type [T] Vector []T

	type VectorInt Vector[int]

	func [T] Sum(x []T) T

	func [T] Sum(x Vector[T]) T

	sum := Sum[int]([]int{1,2,3})

	func [T1, T2] MakePair(x T1, y T2) Pair[T1, T2]

This design retained the implicit constraints of the previous one, but now with a much longer discussion of exactly how to infer restrictions from function bodies.
It was still unclear if the approach was workable in practice, and it seemed clearly incomplete.
The design noted ominously:

> The goal of the restrictions listed above is not to try to handle every possible case.
> It is to provide a reasonable and consistent approach to type checking of parameterized functions and preliminary type checking of types used to instantiate those functions.
>
> It’s possible that future compilers will become more restrictive; a parameterized function that can not be instantiated by any type argument is invalid even if it is never instantiated, but we do not require that every compiler diagnose it.
> In other words, it’s possible that even if a package compiles successfully today, it may fail to compile in the future if it defines an invalid parameterized function.

Still, after many years of struggling with explicit enumerations of type constraints, "just look at the function body" seemed quite attractive.

