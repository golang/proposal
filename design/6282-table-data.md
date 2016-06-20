# Proposal: Design proposal for 'Tables', multi-dimensional slices

Author(s): Brendan Tracey, with input from the gonum team

Last updated: July 15th, 2016

## Abstract

This document proposes the addition of multi-dimensional slices to Go.
It is proposed that this data structure be called a "table", and will be
referred to as such from now on.
Tables can be an underlying data type for many applications, including matrix
manipulations, image processing, and 2-D gaming.

A table represents an N-dimensional rectangular data structure with continuous
storage.
Each dimension of a table has a dynamically sized length and capacity.
Arrays-of-arrays(-of-arrays-of...) are continuous in memory and rectangular but
are not dynamically sized.
Slice-of-slice(-of-slice-of...) are dynamically sized but are not
continuous in memory and do not have a uniform length in each dimension.

The table structure proposed here is a multi-dimensional slice of a
multi-dimensional array.
A table in N dimensions is accessed with N indices where each dimension is
bounds checked for safety.
This proposal defines syntax for accessing and slicing, provides definitions for
`make`, `len`, `cap`, `copy` and `range`, and discusses some additions to package
reflect.

## Previous discussions

This proposal is a self-contained document, and these discussions are not
necessary for understanding the proposal.
These are here to provide a history of discussion on the subject.

### About this proposal

(Note that many changes have been made since the earlier discussions)
1. [Issue 6282 -- proposal: spec: multidimensional slices:](https://golang.org/issue/6282.)
2. [gonum-dev thread:](https://groups.google.com/forum/#!topic/gonum-dev/NW92HV_W_lY%5B1-25%5D)
3. [golang-nuts thread: Proposal to add tables (two-dimensional slices) to go](https://groups.google.com/forum/#!topic/golang-nuts/osTLUEmB5Gk%5B1-25%5D)
4. [golang-dev thread: Table proposal (2-D slices) on go-nuts](https://groups.google.com/forum/#!topic/golang-dev/ec0gPTfz7Ek)
5. [golang-dev thread: Table proposal next steps](https://groups.google.com/forum/#!searchin/golang-dev/proposal$20to$20add$20tables/golang-dev/T2oH4MK5kj8/kOMHPR5YpFEJ)

### Other related threads

[golang-nuts thread -- Multi-dimensional arrays for Go. It's time](https://groups.google.com/forum/#!topic/golang-nuts/Q7lwBDPmQh4%5B1-25%5D)
[golang-nuts thread -- Multidimensional slices for Go: a proposal](https://groups.google.com/forum/#!topic/golang-nuts/WwQOuYJm_-s)
[golang-nuts thread -- Optimizing a classical computation in Go](https://groups.google.com/forum/#!topic/golang-nuts/ScFRRxqHTkY)

## Background

Go presently lacks multi-dimensional slices.
Multi-dimensional arrays can be constructed, but they have fixed dimensions: a
function that takes a multidimensional array of size 3x3 is unable to handle an
array of size 4x4.
Go provides slices to allow code to be written for lists of unknown length, but
a similar functionality does not exist for multiple dimensions; there is no built
-in "table" type.

One very important concept with this layout is a Matrix.
Matrices are hugely important in many sections of computing.
Several popular languages have been designed with the goal of making matrices
easy (MATLAB, Julia, and to some extent Fortran) and significant effort has been
spent in other languages to make matrix operations fast and easy (Lapack, Intel
MLK, ATLAS, Eigpack, numpy).
Go was designed with speed and concurrency in mind, and so Go should be a great
language for computation, and indeed, scientific programmers are using Go
despite the lack of support from the standard library for scientific computing.
While the gonum project has a matrix library that provides a significant amount
of functionality, the results are problematic for reasons discussed below.
As both a developer and a user of the gonum matrix library, I can confidently
say that not only would implementation and maintenance be much easier with a
table type, but also that using matrices would change from being somewhat of a
pain to being enjoyable to use.

The desire for good matrix support is the motivation for this proposal, but
matrices are not synonymous with tables. A matrix is composed of real or complex
numbers and has well-defined operations (multiply, determinant, Cholesky
decomposition).
Tables, on the other hand, are merely a rectangular data container. A table can
be of any dimension, hold any data type and do not have any of the additional
semantics of a matrix.
A matrix can be constructed on top of a table in an external package.

A rectangular data container can find use throughout the Go ecosystem.
A partial list is

1. Image processing: An image canvas can be represented as a rectangle of colors.
Here the ability to efficiently slice in multiple dimensions is important.
2. Machine learning: Typically feature vectors are represented as a row of a
matrix. Each feature vector has the same length, and so the additional safety of
a full rectangular data structure is useful.
Additionally, many fitting algorithms (such as linear regression) give this
rectangular data the additional semantics of a matrix, so easy interoperability
is very useful.
3. Game development: Go is becoming increasingly popular for the development
of games.
A player-specific section of a two or three dimensional space can be well
represented by an n-dimensional array or table that has been sliced.
Tile-based games are especially well represented as a slice, not only for
depicting the field of action, but the copy semantics are especially useful
for dealing with sprites.

Go is a great general-purpose language, and allowing users to slice a
multi-dimensional array will increase the sphere of projects for which Go is ideal.
In the end, tables are the pragmatic choice for supporting rectangular data.

### Language Workarounds

There are several possible ways to emulate a rectangular data structure, each
with its own downsides.
This section discusses data in two dimensions, but similar problems exist for
higher dimensional data.

#### 1. Slice of slices

Perhaps the most natural way to express a two-dimensional table in Go is to use
a slice of slices (for example `[][]float64`).
This construction allows convenient accessing and assignment using the
traditional slice access

	v := s[i][j]
	s[i][j] = v

This representation has two major problems.
First, a slice of slices, on its own, has no guarantees about the size of the
slices in the minor dimension.
Routines must either check that the lengths of the inner slices are all equal,
or assume that the dimensions are equal (and accept possible bounds errors).
This approach is error-prone for the user and unnecessarily burdensome for the
implementer.
In short, a slice of slices represents exactly that; a slice of arbitrary length
slices.
It does not represent a table where all of the minor dimension slices are of
equal length
Secondly, a slice of slices has a significant amount of computational overhead.
Many programs in numerical computing are dominated by the cost of matrix
operations (linear solve, singular value decomposition), and optimizing these
operations is the best way to improve performance.
Likewise, any unnecessary cost is a direct unnecessary slowdown.
On modern machines, pointer-chasing is one of the slowest operations.
At best, the pointer might be in the L1 cache, and retrieval from the L1 cache
has a latency similar to that of the multiplication that address arithmetic
requires.
Even so, keeping that pointer in the cache increases L1 cache pressure, slowing
down other code.
If the pointer is not in the L1 cache, its retrieval is considerably slower than
address arithmetic; at worst, it might be in main memory, which has a latency on
the order of a hundred times slower than address arithmetic.
Additionally, what would be redundant bounds checks in a true table are
necessary in a slice of slice as each slice could have a different length, and
some common operations like taking a subtable (the 2-d equivalent of slicing)
are expensive on a slice of slice but are cheap in other representations.

#### 2. Single array

A second representation option is to contain the data in a single slice, and
maintain auxiliary variables for the size of the table.
The main benefit of this approach is speed.
A single array avoids the cache and bounds concerns listed above.
However, this approach has several major downfalls.
The auxiliary size variables must be managed by hand and passed between
different routines.
Every access requires hand-writing the data access multiplication as well as hand
-written bounds checking (Go ensures that data is not accessed beyond the array,
but not that the row and column bounds are respected).
Not only is hand-written access error prone, but the integer multiply-add is
much slower than compiler support for access.
Furthermore, it is not clear from the data representation whether the table
is to be accessed in "row major" or "column major" format

	v := a[i*stride + j]     // Row major a[i,j]
	v := a[i + j*stride]     // Column major a[i,j]

In order to correctly and safely represent a slice-backed table, one needs four
auxiliary variables: the number of rows, number of columns, the stride, and also
the ordering of the data since there is currently no "standard" choice for data
ordering.
A community accepted ordering for this data structure would significantly ease
package writing and improve package inter-operation, but relying on library
writers to follow unenforced convention is ripe for confusion and incorrect code.

#### 3. Struct type

A third approach is to create a struct data type containing a data slice and all
of the data access information.
The data is then accessed through method calls.
This is the approach used by go.matrix and gonum/matrix.

	type RawMatrix struct {
		Order
		Rows, Cols  int
		Stride      int
		Data        []float64
	}

	type Dense struct {
		mat RawMatrix
	}

	func (m *Dense) At(r, c int) float64{
		if r < 0 || r >= m.mat.Rows{
			panic("rows out of bounds")
		}
		if c < 0 || c >= m.mat.Cols{
			panic("cols out of bounds")
		}
		return m.mat.Data[r*m.mat.Stride + c]
	}

	func (m *Dense) Set(r, c int, v float64) {
		if r < 0 || r >= m.mat.Rows{
			panic("rows out of bounds")
		}
		if c < 0 || c >= m.mat.Cols{
			panic("cols out of bounds")
		}
		m.mat.Data[r*m.mat.Stride+c] = v
	}

From the user's perspective:

	v := m.At(i, j)
	m.Set(i, j, v)

The major benefits to this approach are that the data are encapsulated correctly
-- the structure is presented as a table, and panics occur when either dimension
is accessed out of bounds -- and that speed is preserved when doing common
matrix operations (such as multiplication), as they can operate on the slice
directly.

The problems with this approach are convenience of use and speed of execution
for uncommon operations.
The At and Set methods when used in simple expressions are not too bad; they are
a couple of extra characters, but the behavior is still clear.
Legibility starts to erode, however, when used in more complicated expressions

	// Set the third column of a matrix to have a uniform random value
	for i := 0; i < nCols; i++ {
		m.Set(i, 2, (bounds[1] - bounds[0])*rand.Float64() + bounds[0])
	}
	// Perform a matrix  add-multiply, c += a .* b  (.* representing element-
	// wise multiplication)
	for i := 0; i < nRows; i++ {
		for j := 0; j < nCols; j++{
			c.Set(i, j, c.At(i,j) + a.At(i,j) * b.At(i,j))
		}
	}

The above code segments are much clearer when written as an expression and
assignment

	// Set the third column of a matrix to have a uniform random value
	for i := 0; i < nRows; i++ {
		m[i,2] = (bounds[1] - bounds[0]) * rand.Float64() + bounds[0]
	}
	// Perform a matrix element-wise add-multiply, c += a .* b
	for i := 0; i < nRows; i++ {
		for j := 0; j < nCols; j++{
			c[i,j] += a[i,j] * b[i,j]
		}
	}

In addition, going through three data structures for accessing and assignment is
slow (public Dense struct, then private RawMatrix struct, then RawMatrix.Data
slice).
This is a problem when performing matrix manipulation not provided by the matrix
library (and it is impossible to provide support for everything one might wish
to do with a matrix).
The user is faced with the choice of either accepting the performance penalty (
up to 10x), or extracting the underlying RawMatrix, and indexing the underlying
slice directly (thus removing the safety provided by the Dense type).
The decision to not break type safety can come with significant full-program
cost; there are many codes where matrix operations dominate computational cost (
consider a 10x slowdown when accessing millions of matrix elements).

### Benchmarks

Two benchmarks were created to compare the representations: 1) a traditional
matrix multiply, and 2) summing elements of the matrix that meet certain
qualifications. The code can be found [here](http://play.golang.org/p/VsL5HGNYT4).
Six benchmarks show the speed of multiplying a 200x300 times a 300x400 matrix,
and the summation is of the 200x300 matrix.
The first three benchmarks present the simple implementation of the algorithm
given the representation.
The final three benchmarks are provided for comparison, and show optimizations
to the code at the sacrifice of some code simplicity and legibility.

Benchmark times for Partial Sum and Matrix Multiply.
Benchmarking performed on OSX 2.7 GHz Intel Core i7 using Go 1.5.1.
Times are scaled so that the single slice representation has a value of 1.

| Representation         | Partial sum | Matrix Multiply |
| ---------------------  | :---------: | :-------------: |
| Single slice           | 1.00        | 1.00            |
| Slice of slice         | 1.10        | 1.51            |
| Struct                 | 2.33        | 8.32            |
| Struct no bounds       | 1.08        | 1.96            |
| Struct no bounds no ptr| 1.12        | 4.47            |
| Single slice resliced  | 0.80        | 0.76            |
| Slice of slice cached  | 0.82        | 0.77            |
| Slice of slice range   | 0.80        | 0.74            |

And with -gcflags = -B

| Representation         | Partial sum | Matrix Multiply |
| ---------------------  | :---------: | :-------------: |
| Single slice           | 0.95        | 0.95            |
| Slice of slice         | 1.10        | 1.33            |
| Struct                 | 2.35        | 8.20            |
| Struct no bounds       | 1.13        | 1.81            |
| Struct no bounds no ptr| 1.11        | 4.48            |
| Single slice resliced  | 0.83        | 0.59            |
| Slice of slice cached  | 0.83        | 0.58            |
| Slice of slice range   | 0.77        | 0.56            |

For the simple implementations, the single slice representation is the fastest
by a significant margin.
Notably, the struct representation -- the only representation that presents a
correct model of the data and the one which is least error-prone -- has a
significant speed penalty, being 8 (!) times slower for the matrix multiply.
The additional benchmarks show that significant speed increases through
optimization of array indexing and by avoiding some unnecessary bounds checks (
issue 5364).
A native table implementation would allow even more efficient data access by
allowing accessing via increment rather than integer multiplication.
This would improve upon even the optimized benchmarks.
In the future, Go compilers will add vectorization to provide huge speed
improvements to numerical code.
Vectorization opportunities are much more easily recognized with a table type
where the data is controlled by the implementation than in any of the
alternate representation choices.
For the single slice representation, the compiler must actually analyze the
indexing integer multiply to confirm there is no overflow and that the
elements are accessed in order.
In the slice of slice representation, the compiler must confirm that all slice
lengths are equal, which may require non-local code analysis, and
vectorization will be more difficult with non-contiguous data.
In the struct representation, the actual slice index is behind a function call
and a private field, so not only would the compiler need all of the same
analysis for the single-slice case, but now must also inline a function call
that contains out-of-package private data.
A native table type provides immediate speed improvements and opens to the
door for further easily-recognizable optimization opportunities.

### Recap

The following table summarizes the current state of affairs with tables in go

|                | Correct Representation | Access/Assignment Convenience | Speed |
| -------------: | :--------------------: | :---------------------------: | :---: |
| Slice of slice | X                      | ✓                             | X     |
| Single slice   | X                      | X                             | ✓     |
| Struct type    | ✓                      | X                             | X     |

In general, we would like our codes to be

1. Easy to use
2. Not error-prone
3. Performant

At present, an author of numerical code must choose one.
The relative importance of these priorities will be application-specific, which
will make it hard to establish one common representation.
This lack of consistency will make it hard for packages to interoperate.
The addition of a language built-in allows all three goals to be met
simultaneously which eliminates this tradeoff, and allows gophers to write
simple, fast, and correct numerical and graphics code.

## Proposal

The proposal is to add a new built-in generic type, a "table" into the language.
It is a multi-dimensional analog to a slice.
The term "table" is chosen because the proposed new type is just a data
container.
The term "matrix" implies the ability to do other mathematical operations (which
will not be implemented at the language level).
One may multiply a matrix; one may not multiply a table.
Just as `[]T` is shorthand for a slice, `[,]T` is shorthand for a two-dimensional
table, `[,,]T` a three-dimensional table, etc. (as will be clear later).

### Syntax (spec level specification)

### Allocation:

A new table may be constructed either using the make built-in or as a table
literal.
The elements are guaranteed to be stored in a continuous array, and are
guaranteed to be stored in "row-major" order, which matches the existing layout
of two-dimensional arrays in Go.
Specifically, for a two-dimensional table t with m rows and n columns, the
elements are laid out as

	[t11, t12, ... t1n, t21, t22, ... t2n ... , tm1, ... tmn]

Similarly, for a three-dimensional table with lengths m, n, and p, the data is
arranged as

	[t111, t112, ... t11p, t121, ..., t12n, ... t211 ... , t2np, ... tmnp]

Row major is the only acceptable layout. Tables can be constructed as
multi-dimensional arrays which have been sliced, and the spec guarantees that
multi-dimensional arrays are in row-major order.
Furthermore, guaranteeing a specific order allows code authors to reason about
data layout for optimal performance.

#### Using make:

A new N-dimensional table (of generic type) may be allocated by using the make
command with a mandatory argument of a [N]int specifying the length in each
dimension, followed by an optional [N]int specifying the capacity in each
dimension (rationale described in "Length / Capacity" section).
If the capacity argument is not present, each capacity is defaulted to its
respective length argument.
These act like the length and capacity for slices, but on a per-dimension basis.
The table will be filled with the zero value of the type

	s := make([,]T, [2]int{m, n}, [2]int{maxm, maxn})
	t := make([,]T, [...]int{m, n})
	s2 := make([,,]T, [...]int{m, n, p}, [...]int{maxm, maxn, maxp})
	t2 := make([,,]T, [3]int{m, n, p})

Calling make with a zero length or capacity is allowed, and is equivalent to
creating an equivalently sized multi-dimensional array and slicing it.
In the following code

	u := make([,,,]float32, [4]int{0, 6, 4, 0})
	v := [0][6][4][0]float32{}
	w := v[0:0, 0:6, 0:4, 0:0]

u and w have the same behavior.
Specifically, the length and capacities for both are 0, 6, 4, and 0 in the
dimensions, and the underlying data array contains 0 elements.

#### Table literals

A table literal can be constructed using nested braces

	u := [,]T{{x, y, z}, {a, b, c}}
	v := [,,]T{{{1, 2, 3, 4}, {5, 6, 7, 8}}, {{9, 10, 11, 12}, {13, 14, 15, 16}}}

The size of the table will depend on the size of the brace sets, outside in.
For example, in a two-dimensional table the number of rows is equal to the number
of sets of braces, the number of columns is equal to the number of elements within
each set of braces.
In a three-dimensional table, the length of the first dimension is the number
of sets of brace sets, etc.
Above, u has length [2, 3], and v has length [2, 2, 4].
It is a compile-time error if each brace layer does not contain the same number of
elements.
Like normal slices and arrays, key-element literal construction is allowed.
For example, the two following constructions yield the same result

	[,]int{{0:1, 2:0},{1:1, 2:0}, {2:1}}
	[,]int{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

### Access/ Assignment
An element of a table can be accessed with [idx0, idx1, ...] syntax, and can be
assigned to similarly.

	var v T
	v = t2[m,n]
	t3[m,n,p] = v

If any index is negative or if it is greater than or equal to the length
in that dimension, a runtime panic occurs.
Other combination operators are valid (assuming the table is of correct type)

	t := make([,]float64, [2]int{2,3})
	t[1,2] = 6
	t[1,2] *= 2   // Now contains 12
	t[3,3] = 4    // Runtime panic, out of bounds (possible compile-time with
	              // constants)

### Slicing

A table can be sliced using the normal 2 or 3 index slicing rules in each
dimension, `i:j` or `i:j:k`.
The same panic rules as slices apply (`0 <= i <= j <= k`, must be less than the
capacity).
Like slices, this updates the length and capacity in the respective
dimensions

	a := make([,]int, [2]int{10, 2}, [2]int{10, 15})
	b := a[1:3, 3:5:6]

A multi-dimensional array may be sliced to create a table.
In

	array := [10][5]int
	t := array[2:6, 3:5]

t is a table with lengths 4 and 2, capacities 5 and 10, and a stride of 5.

### Down-slicing

An n-dimensional table may be "down-sliced" into a `k < n` dimensional table.
This is similar to regular slicing, in that certain elements are no longer
directly accessible, but is dissimilar to regular slicing in that the returned
type is different from the sliced type.

A down-slicing statement consists of a single index in the beginning `n-k`
dimensions, and three-element slice syntax in the remaining `k` dimensions.
In other words, the rules are asymmetric in that the leading dimensions contain
single element indices, while the minor dimensions have three-element slice syntax.
The returned table shares an underlying data slice with the sliced table, but
with a new offset and updated lengths and capacities.

	t2 := t[1,:] // t2 has type []T and contains the elements of the second row of t
	t3 := t[4,7,:] // t3 has type []T and contains the elements of the 5th row
	               // and 8th column of t.
	t4 := t[3, 1:3, 1:5:6] // t3 has type [,]T
	t5 := t[:,:,2] // Compile error: left-most indices must be specified

Like slice expressions, either tables or multi-dimensional arrays may be down-sliced.
Note that the limiting cases of down-slicing match other behaviors of tables.
In the case where `k == n`, down-slicing is identical to regular slicing, and in
the case where `k == 0`, down-slicing is just table access.

#### Discussion

Down-slicing increases the integration between tables and slices, and tables
of different sizes with themselves.
Down-slicing allows for copy-free passing of subsections of data to algorithms
which require a lower-sized table or slice. For example,

	func mean(s []float64) float64 {
		var m float64
		for _, v := range s {
			m += v
		}
		return m / float64(len(s))
	}

	func means(t [,]float64) []float64 {
		m := make([]float64, len(t)[0]) // syntax discussed below
		for i := range m {
			m[i] = mean(t[i,:])
		}
		return m
	}

A downside of this behavior is that the semantics are asymetric, in that
sub-slices of a table can only be taken in certain dimensions.
However, this is the only reasonable choice given how slices work in Go.
The other two possibilities are to

1. Modify the slice implementation to add a stride field
2. Have a "1-D table" type which is the same as a slice but has a stride

Option 1 would have huge ramifications on Go programs.
It would add memory and cost to such a fundamental data structure, not to mention
require changes to most low-level libraries.
Option 2 is, in my opinion, harmful to the language.
It will cause a gap between the codes that support strided slices and the codes
that support non-strided slices, and may cause duplication of effort to support
both forms (`2^N` effort in the worst case).
On the whole, it will make the language less cohesive.
Thus, any proposal that allows down-slicing has to be asymmetric to work with
Go as it is today.
Despite the asymmetry, the increase in language congruity merits the inclusion
of down-slicing within the proposal.

### Reshaping

A new built-in `reshape` allows the data in a slice to be re-interpreted as a
higher dimensional table in constant time.
The pseudo-signature is `func reshape(s []T, [N]int) [,...]T` where `N`
is an integer greater than one, and [,...]T is a table of dimension `N`.
The returned table shares the same underlying data as the input slice, and is
interpreted in the layout discussed in the "Allocation" section.
The product of the elements in the `[N]int` must equal the length of the input
slice or a run-time panic will occur.

	s := []float64{0, 1, 2, 3, 4, 5, 6, 7}
	t := reshape(s, [2]int{4,2})
	fmt.Println(t[2,0]) // prints 4
	t[1,0] = -2
	t2 := reshape(s, [...]int{2,2,2})
	fmt.Println(t3[0,1,0]) // prints -2
	t3 := reshape(s, [...]int{2,2,2,2}) // runtime panic: reshape length mismatch

#### Discussion

There are several use cases for reshaping, as discussed in the
[strided slices proposal](https://github.com/golang/go/issues/13253).
However, arbitrary reshaping (as proposed in the previous link) does not compose
with table slicing (discussed more below).
This proposal allows for the common use case of transforming between linear and
multi-dimensional data while still allowing for slicing in the normal way.

Another possible syntax for reshape is discussed in
[issue 395](https://github.com/golang/go/issues/395).
Instead of a new built-in, one could use `t := s.([m1,m2,...,mn]T)`, where s
is of type `[]T`, and the returned type is `[,...]T` with
`len(t) == [n]int{m1, m2, ..., mn}`.
As discussed in #395, the .() syntax is typically reserved for interface assertions.
This isn't strictly overloaded, since []T is not an interface, but it could be
confusing to have similar syntax represent similar ideas.
The difference between s.([,]T) and s.([m,n]T) may be too large for how similar
the expressions appear -- the first asserts that the value stored in the
interface `s` is a [,]T, while the second reshapes a `[]T` into a `[,]T` with
lengths equal to `m` and `n`.
Initial discussion seems to suggest a new built-in is preferred to these
subtleties.

This proposal intentionally excludes the inverse operation, `unshape`.
Extracting the linear data from a table is not compatible with slicing, as slicing
makes the visible data no longer contiguous.
If a user wants to re-interpret the data in several different sizes, the user
can just maintain the original []T.

### Length / Capacity

Like slices, the `len` and `cap` built-in functions can be used on a table.
Len and cap take in a table and return a [N]int representing the lengths/
capacities in the dimensions of the table.

	lengths := len(t)    // lengths is a [2]int
	nRows := len(t)[0]
	nCols := len(t)[1]
	maxElems := cap(t)[0] * cap(t)[1]

#### Discussion

This behavior keeps the natural definitions of len and cap.
There are four possible syntax choices

	lengths := len(t)     // returns [N]int
	length := len(t, 0)   // returns the length of the table along the first
	                      // dimension
	len(t[0,:]) or len(t[ ,:]) // returns the length along the second dimension
	m, n, p, ... := len(t)

The first behavior is preferable to the other three.
In the first syntax, it is easy to get any particular dimension (access the
array) and if the array index is a constant, it is verifiable and optimizable at
compile-time.
Second, it is easy to compare the lengths and capacities of the array with

	len(x) == len(y)

Finally, this behavior interacts well with make

	t2 := make([,,]T, len(t), cap(t))

The second representation seems strictly worse than the first representation.
While it is easy to obtain a specific dimension length of the table, one cannot
compare the full table lengths directly.
One has to do

	len(x,0) == len(y, 0) && len(x,1) == len(y,1) && len(x,2) == len(y,2) && ...

Additionally, now the call to length requires a check that the second argument
is less than the dimension of the table, and may panic if that check fails.
There doesn't seem to be any benefit gained by allowing this failure.

The third syntax possibility has the same weaknesses as the second. It's hard to
compare table sizes, it can possibly fail at runtime, and does not mesh with make.

The fourth option will always succeed, but again, it's hard to compare the full
lengths of the tables

	mx, nx, px, ... := len(x)
	my, ny, py, ... := len(y)
	rx == ry && cx == cy && px == py && ...

Additionally, it's hard to get any one specific length.
Such an ability is useful in for loops, for example

	for i := 0; i < len(t)[0]; i++ {
	}

Lastly, this behavior does not extend well to higher dimensional tables.
For a 5-dimensional table,

	r1, r2, r3, r4, r5 := len([,,,,]int{})

is pretty silly. It would be much better to return a `[5]int`.

### Copy

The built-in `copy` will be changed to allow two tables of equal dimension.
Copy returns an `[N]int` specifying the number of elements that were copied in each
dimension.

	n := copy(dst, src)   // n is a [N]int

Copy will copy all of the elements in the subtable from the first dimension to
`min(len(dst)[0], len(src)[0])` the second dimension to
`min(len(dst)[1], len(src)[1])`, etc.

	dst := make([,]int, [2]int{6, 8})
	src := make([,]int, [2]int{5, 10})
	n := copy(dst, src) // n == [2]int{5, 8}
	fmt.Println("All destination elements were overwritten:", n == len(dst))

Down-slicing can be used to copy data between tables of different dimension.

	slice := []int{0, 0, 0, 0, 0}
	table := [,]int{{1,2,3}, {4,5,6}, {7,8,9}, {10,11,12}}
	copy(slice, table[1,:])    // Copies all the whole second row of the table
	fmt.Println(slice)  // prints [4 5 6 0 0]
	copy(table[2,:], table[1,:]) // copies the second row into the third row

#### Discussion

For similar reasons as `len` and `cap`, returning an [N]int is the best option.

### Range

Range allows for efficient iteration along a fixed axis of the table,
for example the (elements of the) third column.

The expression list on the left hand side of the range clause may have one or
two items that represent the index and the table value along the fixed location
respectively.
This fixed dimension is specified similarly to copy above -- one dimension of
the table has a single integer specifying the row or column to loop over, and
the other dimension has a two-index slice syntax.
Optionally, if there is only one element in the expression list, the fixed
integer may be omitted (see examples).
It is a compile-time error if the left hand expression list has two elements
but the fixed integer is omitted.
It is also a compile-time error if the specifying integer on the right hand side
is a negative constant, and a runtime panic will occur if the fixed integer is out of bounds of the
table in that dimension.
To help with legibility, gofmt will format such that there is a space between
the comma and the bracket when the fixed index is omitted, i.e. `[:, ]` and
`[ ,:]`, not `[:,]` and `[,:]`.

#### Examples

Two-dimensional tables.

	table := [,]int{{1,2,3} , {4,5,6}, {7,8,9}, {10,11,12}}
	for i, v := range table[2,:]{
		fmt.Println(i, v)  // i ranges from 0 to 2, v will be 7,8,9
		                   // (values of 3rd row)
	}
	for i, v := range table[:,0]{
		fmt.Println(i, v)  // i ranges from 0 to 3, v will be 1,4,7,10
		                   // (values of 1st column)
	}
	for i := range table[:, ]{
		fmt.Println(i) // i ranges from 0 to 3
	}
	for i, v := range table[:, ]{ // compile time error, no column specified
		fmt.Println(i)
	}
	// Sum the rows of the table
	rowsum := make([]int, len(table)[1])
	for i = range table[:, ]{
		for _, v = range table[i,:]{
			rowsum[i] += v
		}
	}
	// Matrix-matrix multiply (given existing tables a and b)
	c := make([,]float64, len(a)[0], len(b)[1])
	for i := range a[:, ]{
		for k, va := range a[i,:] {
			for j, vb := range b[k,:] {
				c[i,j] += va * vb
			}
		}
	}

Higher-dimensional tables

	table := [,,]int{{{1, 2, 3, 4}, {5, 6, 7, 8}}, {{9, 10, 11, 12}, {13, 14, 15, 16}}}
	for i, v := range [1,:,3]{
		fmt.Println(i, v) // i ranges from 0 to 1, v will be 12, 16
	}
	for i := range [ , ,:]{
		fmt.Println(i) // i ranges from 0 to 3
	}

#### Discussion

This description of range mimics that of slices.
It permits a range clause with one or two values, where the type of the second
value is the same as that of the elements in the table.
This is far superior to ranging over the rows or columns themselves (rather than
the elements in a single row or column).
Such a proposal (where the value is `[]T` instead of just `T`) would have O(n) run
time in the length of the table dimension and could create significant extra
garbage.

Much of the proposed range behavior follows naturally from the specification
of down-slicing and the behavior of range over slices.
In particular, the line

	for i, v := range t[0,:]

follows the proposed behavior here without any additional specification.
The behavior specified here is special in two ways.
First, this range behavior does not require an index to be specified in the
down-slicing-like expression.
This is discussed in detail below.
Second, the "range + down-slicing" discussed above can only be used to range
over the minor dimension in the table.
It is very common to want to loop over the other dimensions as well.
It is of course possible to loop over the major dimension without a range
statement

	for i := 0; i < len(t)[0]; i++ {}

but these kinds of loops seem sufficiently common to merit special treatment,
especially since it reduces the asymmetry in the dimensions.

The option to omit specific dimensions is necessary to allow for nice
behavior when the length of the table is zero in the relevant dimension.
One may sum the elements in a slice as follows:

	sum := 0
	for _, v := range s {
		sum += v
	}

This works for any slice including nil and those with length 0.
With the ability to omit, similar code also works for nil tables and tables with
zero length in any or all of the dimensions:

	sum := 0
	for i := range t[:, ]{
		for j, v := range t[i,:]{
			sum += v
		}
	}

Were it mandatory to specify a particular column, one would have to replace
`t[:,]` with `t[:,0]` in the first range clause.
If `len(t,0) == 0`, this would panic.
It would thus be necessary to add in an extra length check before the range
statements to avoid such a panic.

There is an argument about the legibility of the syntax, however this should not
be a problem for most programmers.
There are four ways one may range over a two-dimensional table:

1. `for i := range t[:, ]`
2. `for j := range t[ ,:]`
3. `for j, v := range t[i,:]`
4. `for i, v := range t[:,j]`

These all seem reasonably distinct from one another.
With the gofmt space enforcement, It's clear which side of the comma the colon
is on, and it's clear whether or not a value is present.
Furthermore, anyone attempting to read code involving tables will need to know
which dimension is being looped over, and anyone debugging such code will
immediately check that the the correct dimension has been looped over.

Lastly, this range syntax is very robust to user error.
All of the following are compile errors:

	for i := range t            // error: no table axis specified.
	for i, v := range t[:, ]    // error: column unspecified when ranging with
								// index and value.
	for i := range t[ , ]       // error: no ranging dimension specified

It can be seen that while the omission is technically optional, it does not
complicate programs.
An unnecessary omission has no effect on program behavior as long as the index
is in-bounds, and disallowed omissions are compile-time errors.

Instead of the optional omission, using an underscore was also considered, for
example,

	for i := range t[:,_]

This has the benefit that the programmer must specify something for every
dimension, and this usage matches the spirit of underscore in that "the specific
column doesn't matter".
This was rejected for fear of overloading underscore, but remains a possibility
if such overloading is acceptable.
Similarly, "-" could be used, but is overloaded with subtraction.

A third option considered was to make the rule that there is only a runtime
panic when the table is accessed, even if the fixed integer is out of bounds.
This would avoid the zero length issue, `for i := range t[0,:]` never needs a
table element, and so would not panic.
However, this introduces its own issues. Does `for i, _ := range t[0,:]` panic?
The lack of consistency is very undesirable.

## Compatibility

This change is fully backward compatible with the Go1 spec.

## Implementation

A table can be implemented in Go with the following data structure

	type Table struct {
		Data       uintptr
		Stride     [N-1]int
		Len        [N]int
		Cap        [N]int
	}

As a special case, a two-dimensional table would have the `Stride` field as an
`int` instead of a `[1]int`.

Access and assignment can be performed using the strides.
For a two-dimensional table, `t[i,j]` gets the element at `i*stride + j` in the
array pointed to by the Data uintptr.
More generally, `t[i0,i1,...,iN-2,iN-1]` gets the element at

	i0 * stride[0] + i1 * stride[1] + ... + iN-2 * stride[N-2] + iN-1

When a new table is allocated, `Stride` is set to `Cap[N-1]`.

A table slice is as simple as updating the pointer, lengths, and capacities.

	t[i0:j0:k0, i1:j1:k1, ..., iN-1:jN-1:kN-1]

causes `Data` to update to the element indexed by `[i0,i1,...,iN-1]`,
`Len[d] = jd - id`, `Cap[d] = kd - id`, and Stride is unchanged.

### Reflect

Package reflect will add reflect.TableHeader2 (like reflect.SliceHeader and
reflect.StringHeader).

	type TableHeader2 struct {
		Data       uintptr
		Stride     int
		Len        [2]int
		Cap        [2]int
	}

The same caveats can be placed on TableHeader2 as the other Header types.
If it is possible to provide more guarantees, that would be great, as there
exists a large body of C libraries written for numerical work, with lots of time
spent in getting the codes to run efficiently.
Being able to call these codes directly is a huge benefit for doing numerical
work in Go (for example, the gonum and biogo matrix libraries have options for
calling a third party BLAS libraries for tuned matrix math implementations).
A new reflect.Kind will also need to be added, and many existing functions will
need to be modified to support the type.
Eventually, it will probably be desirable for reflect to add functions to
support the new type (MakeTable, TableOf, SliceTable, etc.).
The exact signatures of these methods can be decided upon at a later date.

### Implementation Schedule

Help is needed to determine the when and who for the implementation of this
proposal.
The gonum team would translate the code in gonum/matrix, gonum/blas,
and gonum/lapack to assist with testing the implementation.

### Non-goals

This proposal intentionally omits several suggested behaviors.
This is not to say those proposals can't ever be added (nor does it imply that
they will be added), but that they provide additional complications and can be
part of a separate proposal.

### Append

This proposal does not allow append to be used with tables.
This is mainly a matter of syntax.
Can you append a table to a table or just add to a single dimension at a time?
What would the syntax be?

### Arithmetic Operators

Some have called for tables to support arithmetic operators (+, -, *) to also
work on `[,]Numeric` (`int`, `float64`, etc.), for example

	a := make([,]float64, 1000, 3000)
	b := make([,]float64, 3000, 2000)
	c := a*b

While operators can allow for very succinct code, they do not seem to fit in Go.
Go's arithmetic operators only work on numeric types, they don't work on slices.
Secondly, arithmetic operators in Go are all fast, whereas the operation above
is many orders of magnitude more expensive than a floating point multiply.
Finally, multiplication could either mean element-wise multiplication, or
standard matrix multiplication.
Both operations are needed in numerical work, so such a proposal would require
additional operators to be added (such as `.*`).
Especially in terms of clock cycles per character, `c.Mul(a,b)` is not that bad.

## Conclusion

Matrices are widely used in numerical algorithms, and have been used in
computing arguably even before there were computers.
With time and effort, Go could be a great language for numerical computing (for
all of the same reasons it is a great general-purpose language), but first it
needs a rectangular data structure, a "table", built into the language as a
foundation for more advanced libraries.
This proposal describes a behavior for tables which is a strict improvement over
the options currently available.
It will be faster than the single-slice representation (index optimization and
range), more convenient than the slice of slice representation (range, copy,
len), and will provide a correct representation of the data that is more compile-
time verifiable than the struct representation.
The desire for tables is not driven by syntax and ease-of-use, though that is a
huge benefit, but instead a request for safety and speed; the desire to build
"simple, reliable, and efficient software".

|                | Correct Representation | Access/Assignment Convenience | Speed |
| -------------: | :--------------------: | :---------------------------: | :---: |
| Slice of slice | X                      | ✓                             | X     |
| Single slice   | X                      | X                             | ✓     |
| Struct type    | ✓                      | X                             | X     |
| Built-in       | ✓                      | ✓                             | ✓     |

## Open issues

1. In the discussion, it was mentioned that adding a TableHeader is a bad idea.
This can be removed from the proposal, but some other mechanism should be added
that allows data in tables to be passed to C.
2. The "reshaping" syntax as discussed above.