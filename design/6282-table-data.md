# Proposal: Multi-dimensional slices

Author(s): Brendan Tracey, with input from the gonum team

Last updated: November 17th, 2016

## Abstract

This document proposes a generalization of Go slices from one to multiple
dimensions.
This language change makes slices more naturally suitable for applications such
as image processing, matrix computations, gaming, etc.

Arrays-of-arrays(-of-arrays-of...) are continuous in memory and rectangular but
are not dynamically sized.
Slice-of-slice(-of-slice-of...) are dynamically sized but are not
continuous in memory and do not have a uniform length in each dimension.
The generalized slice described here is an N-dimensional rectangular data
structure with continuous storage and a dynamically sized length and capacity
in each dimension.

This proposal defines slicing, indexing, and assignment, and provides extended
definitions for `make`, `len`, `cap`, `copy` and `range`.

## Nomenclature
This document extends the notion of a slice to include rectangular data.
As such, a multi-dimensional slice is properly referred to as simply a "slice".
When necessary, this document uses 1d-slice to refer to Go slices as they are
today, and nd-slice to refer to a slice in more than one dimension.

## Previous discussions

This document is self-contained, and prior discussions are not necessary for
understanding the proposal.
They are referenced here solely to provide a history of discussion on the subject.
Note that in a previous iteration of this document, an nd-slice was referred to as
a "table", and that many changes have been made since these earlier discussions.

### About this proposal

1. [Issue 6282 -- proposal: spec: multidimensional slices](https://golang.org/issue/6282)
2. [gonum-dev thread:](https://groups.google.com/forum/#!topic/gonum-dev/NW92HV_W_lY%5B1-25%5D)
3. [golang-nuts thread: Proposal to add tables (two-dimensional slices) to go](https://groups.google.com/forum/#!topic/golang-nuts/osTLUEmB5Gk%5B1-25%5D)
4. [golang-dev thread: Table proposal (2-D slices) on go-nuts](https://groups.google.com/forum/#!topic/golang-dev/ec0gPTfz7Ek)
5. [golang-dev thread: Table proposal next steps](https://groups.google.com/forum/#!searchin/golang-dev/proposal$20to$20add$20tables/golang-dev/T2oH4MK5kj8/kOMHPR5YpFEJ)
6. [Robert Griesemer proposal review:](https://go-review.googlesource.com/#/c/24271/) which suggested name change from "tables" to just "slices", and suggested referring to down-slicing as simply indexing.

### Other related threads

- [golang-nuts thread -- Multi-dimensional arrays for Go. It's time](https://groups.google.com/forum/#!topic/golang-nuts/Q7lwBDPmQh4%5B1-25%5D)
- [golang-nuts thread -- Multidimensional slices for Go: a proposal](https://groups.google.com/forum/#!topic/golang-nuts/WwQOuYJm_-s)
- [golang-nuts thread -- Optimizing a classical computation in Go](https://groups.google.com/forum/#!topic/golang-nuts/ScFRRxqHTkY)
- [Issue 13253 -- proposal: spec: strided slices](https://github.com/golang/go/issues/13253) Alternate proposal relating to multi-dimensional slices (closed)

## Background

Go presently lacks multi-dimensional slices.
Multi-dimensional arrays can be constructed, but they have fixed dimensions: a
function that takes a multi-dimensional array of size 3x3 is unable to handle an
array of size 4x4.
Go currently provides slices to allow code to be written for lists of unknown
length, but similar functionality does not exist for multiple dimensions;
slices only work in a single dimension.

One very important concept with this layout is a Matrix.
Matrices are hugely important in many sections of computing.
Several popular languages have been designed with the goal of making matrices
easy (MATLAB, Julia, and to some extent Fortran) and significant effort has been
spent in other languages to make matrix operations fast (Lapack, Intel
MKL, ATLAS, Eigpack, numpy).
Go was designed with speed and concurrency in mind, and so Go should be a great
language for numeric applications, and indeed, scientific programmers are using Go
despite the lack of support from the standard library for scientific computing.
While the gonum project has a [matrix library](https://github.com/gonum/matrix)
that provides a significant amount of functionality, the results are problematic
for reasons discussed below.
As both a developer and a user of the gonum matrix library, I can confidently
say that not only would implementation and maintenance be much easier with this
extension to slices, but also that using matrices would change from being
somewhat of a pain to being enjoyable to use.

The desire for good matrix support is a motivation for this proposal, but
matrices are not synonymous with 2d-slices.
A matrix is composed of real or complex numbers and has well-defined operations
(multiplication, determinant, Cholesky decomposition).
2d-slices, on the other hand, are merely a rectangular data container. Slices can
be of any dimension, hold any data type and do not have any of the additional
semantics of a matrix.
A matrix can be constructed on top of a 2d-slice in an external package.

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
represented by an n-dimensional array or a slice of an nd-slice.
Two-dimensional slices are especially well suited for representing the game board
of tile-based games.

Go is a great general-purpose language, and allowing users to slice a
multi-dimensional array will increase the sphere of projects for which Go is ideal.

### Language Workarounds

There are several possible ways to emulate a rectangular data structure, each
with its own downsides.
This section discusses data in two dimensions, but similar problems exist for
higher dimensional data.

#### 1. Slice of slices

Perhaps the most natural way to express a two-dimensional slice in Go is to use
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
It does not represent data where all of the minor dimension slices are of
equal length.
Secondly, a slice of slices has a significant amount of computational overhead
because accessing an element of a sub-slice means indirecting through a pointer
(the pointer to the slice's underlying array).
Many programs in numerical computing are dominated by the cost of matrix
operations (linear solve, singular value decomposition), and optimizing these
operations is the best way to improve performance.
Likewise, any unnecessary cost is a direct unnecessary slowdown.
On modern machines, pointer-chasing is one of the slowest operations.
At best, the pointer might be in the L1 cache.
Even so, keeping that pointer in the cache increases L1 cache pressure, slowing
down other code.
If the pointer is not in the L1 cache, its retrieval is considerably slower than
address arithmetic; at worst, it might be in main memory, which has a latency on
the order of a hundred times slower than address arithmetic.
Additionally, what would be redundant bounds checks in a true 2d-slice are
necessary in a slice of slice as each slice could have a different length, and
some common operations like 2-d slicing are expensive on a slice of slices but
are cheap in other representations.

#### 2. Single slice

A second representation option is to contain the data in a single slice, and
maintain auxiliary variables for the size of the 2d-slice.
The main benefit of this approach is speed.
A single slice avoids some of the cache and index bounds concerns listed above.
However, this approach has several major downfalls.
The auxiliary size variables must be managed by hand and passed between
different routines.
Every access requires hand-writing the data access multiplication as well as hand
-written bounds checking (Go ensures that data is not accessed beyond the slice,
but not that the row and column bounds are respected).
Furthermore, it is not clear from the data representation whether the 2d-slice
is to be accessed in "row major" or "column major" format

	v := a[i*stride + j]     // Row major a[i,j]
	v := a[i + j*stride]     // Column major a[i,j]

In order to correctly and safely represent a slice-backed rectangular structure,
one needs four auxiliary variables: the number of rows, number of columns, the
stride, and also the ordering of the data since there is currently no "standard"
choice for data ordering.
A community accepted ordering for this data structure would significantly ease
package writing and improve package inter-operation, but relying on library
writers to follow unenforced convention is a recipe for confusion and incorrect
code.

#### 3. Struct type

A third approach is to create a struct data type containing a data slice and all
of the data access information.
The data is then accessed through method calls.
This is the approach used by [go.matrix](https://github.com/skelterjohn/go.matrix)
and gonum/matrix.

The struct representation contains the information required for single-slice
based access, but disallows direct access to the data slice.
Instead, method calls are used to access and assign values.

	type Dense struct {
		stride int
		rows   int
		cols   int
		data   []float64
	}

	func (d *Dense) At(i, j int) float64 {
		if uint(i) >= uint(d.rows) {
			panic("rows out of bounds")
		}
		if uint(j) >= uint(d.cols) {
			panic("cols out of bounds")
		}
		return d.data[i*d.stride+j]
	}

	func (d *Dense) Set(i, j int, v float64) {
		if uint(i) >= uint(d.rows) {
			panic("rows out of bounds")
		}
		if uint(j) >= uint(d.cols) {
			panic("cols out of bounds")
		}
		d.data[i*d.stride+j] = v
	}

From the user's perspective:

	v := m.At(i, j)
	m.Set(i, j, v)

The major benefits to this approach are that the data are encapsulated correctly
-- the data are presented as a rectangle, and panics occur when either dimension
is accessed out of bounds -- and that the defining package can efficiently implement
common operations (multiplication, linear solve, etc.) since it can access the
data directly.

This representation, however, suffers from legibility issues.
The At and Set methods when used in simple expressions are not too bad; they are
a couple of extra characters, but the behavior is still clear.
Legibility starts to erode, however, when used in more complicated expressions

	// Set the third column of a matrix to have a uniform random value
	for i := 0; i < nCols; i++ {
		m.Set(i, 2, (bounds[1] - bounds[0])*rand.Float64() + bounds[0])
	}
	// Perform a matrix add-multiply, c += a .* b  (.* representing element-
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
	// Perform a matrix add-multiply, c += a .* b
	for i := 0; i < nRows; i++ {
		for j := 0; j < nCols; j++{
			c[i,j] += a[i,j] * b[i,j]
		}
	}

As will be discussed below, this representation also requires a significant API
surface to enable performance for code outside the defining package.

### Performance

This section discusses the relative performance of the approaches.

#### 1. Slice of slice

The slice of slices approach, as discussed above, has fundamental performance
limitations due to data non-locality.
It requires `n` pointer indirections to get to an element of an `n`-dimensional
slice, while in a multi-dimensional slice it only requires one.

#### 2. Single slice

The single-slice implementation, in theory, has performance identical to
generalized slices.
In practice, the details depend on the specifics of the implementation.
Bounds checking can be a significant portion of runtime for index-heavy code,
and a lot of effort has gone to removing redundant bounds checks in the SSA
compiler.
These checks can be proved redundant for both nd-slices and the single slice
representation, and there is no fundamental performance difference in theory.
In practice, for the single slice representation the compiler needs to prove that
the combination `i*stride + j` is in bounds, while for an nd-slice the compiler
just needs to prove that `i` and `j` are individually within bounds (since the
compiler knows it maintains the correct stride).
Both are feasible, but the latter is simpler, especially with the proposed
extensions to range.

#### 3. Struct type

The performance story for the struct type is more complicated.
Code within the implementing package can access the slice directly, and so the
discussion is identical to the above.
A user-implemented multi-dimensional slice based on a struct can be made as
efficient as the single slice representation, but it requires more than the
simple methods suggested above.
The code for the benchmarks can be found [here](https://play.golang.org/p/yx6ODaIqPl).
The "(BenchmarkXxx)" parenthetical below refer to these benchmarks.
All benchmarks were performed using Go 1.7.3.
A table at the end summarizes the results.
The example for performance comparison will be the function `C += A*B^T`.
This is a simpler version of the "General Matrix Multiply" at the core of many
numerical routines.

First consider a single-slice implementation (BenchmarkNaiveSlices), which
will be similar to the optimal performance.

	// Compute C += A*B^T, where C is an m×n matrix, A is an m×k matrix, and B
	// is an n×k matrix
	func MulTrans(m, n, k int, a, b, c []float64, lda, ldb, ldc int){
		for i := 0; i < m; i++ {
			for j := 0; j < n; j++ {
				var t float64
				for l := 0; l < k; l++ {
					t += a[i*lda+l] * b[j*lda+l]
				}
				c[i*ldc+j] += t
			}
		}
	}

We can add an "AddSet" method (BenchmarkAddSet), and translate the above code
into the struct representation.

	// Compute C += A*B^T, where C is an m×n matrix, A is an m×k matrix, and B
	// is an n×k matrix
	func MulTrans(A, B, C Dense) {
		for i := 0; i < m; i++ {
			for j := 0; j < n; j++ {
				var t float64
				for l := 0; l < k; l++ {
					t += A.At(i, l) * B.At(j, l)
				}
				C.AddSet(i, j, t)
			}
		}
	}

This translation is 500% slower, a very significant cost.

The reason for this significant penalty is that the Go compiler does not
currently inline methods that can panic, and the accessors contain panic calls
as part of the manual index bounds checks.
The next benchmark simulates a compiler with this restriction removed (BenchmarkAddSetNP)
by replacing the `panic` calls in the accessor methods with setting the first
data element to NaN (this is not good code, but it means the current Go compiler
can inline the method calls and the bounds checks still affect program execution
and so cannot be trivially removed).
This significantly decreases the running time, reducing the gap from 500% to only 35%.

The final cause of the performance gap is bounds checking.
The benchmark is modified so the bounds checks are removed, simulating a compiler
with better proving capability than the current compiler.
Further, the benchmark is run with `-gcflags=-B` (BenchmarkAddSetNB).
This closes the performance gap entirely (and also improves the single slice
implementation by 15%).

However, the initial single slice implementation can be significantly improved
as follows (BenchmarkSliceOpt).

	for i := 0; i < m; i++ {
		as := a[i*lda : i*lda+k]
		cs := c[i*ldc : i*ldc+n]
		for j := 0; j < n; j++ {
			bs := b[j*lda : j*lda+k]
			var t float64
			for l, v := range as {
				t += v * bs[l]
			}
			cs[j] += t
		}
	}

This reduces the cost by another 40% on top of the bounds check removal.

Similar performance using a struct representation can be achieved with a
"RowView" method (BenchmarkDenseOpt)

	func (d *Dense) RowView(i int) []float64 {
		if uint(i) >= uint(d.rows) {
			panic("rows out of bounds")
		}
		return d.data[i*d.stride : i*d.stride+d.cols]
	}

This again closes the gap with the single slice representation.

The conclusion is that the struct representation can eventually be as efficient
as the single slice representation.
Bridging the gap requires a compiler with better inlining ability and superior
bounds checking elimination.
On top of a better compiler, a suite of methods are needed on Dense to support
efficient operations.
The RowView method let range be used, and the "operator methods" (AddSet, AtSet
SubSet, MulSet, etc.) reduce the number of accesses.

Compare the final implementation using a struct

	for i := 0; i < m; i++ {
		as := A.RowView(i)
		cs := C.RowView(i)
		for j := 0; j < n; j++ {
			bs := b[j*lda:]
			var t float64
			for l, v := range as {
				t += v * bs[l]
			}
			cs[j] += t
		}
	}

with that of the nd-slice implementation using the syntax proposed here

	for i, as := range a {
		cs := c[i]
		for j, bs := range b {
			var t float64
			for l, v := range as {
				t += v * bs[l]
			}
		}
		cs[j] += t
	}

The indexing performed by RowView happens safely and automatically using range.
There is no need for the "OpSet" methods since they are automatic with slices.
Compiler optimizations are less necessary as the operations are already inlined,
and range eliminated most of the bounds checks.
Perhaps most importantly, the code snippet above is the most natural way to code
the function using nd-slices, and it is also the most efficient way to code it.
Efficient code is a consequence of good code when nd-slices are available.

| Benchmark                  | MulTrans (ms) |
| -------------------------- | :-----------: |
| Naive slice                |  41.0         |
| Struct + AddSet            | 207           |
| Struct + Inline            |  56.0         |
| Slice + No Bounds (NB)     |  34.9         |
| Struct + Inline + NB       |  34.1         |
| Slice + NB + Subslice (SS) |  21.6         |
| Struct + Inilne + NB + SS  |  20.6         |

### Recap

The following table summarizes the current state of affairs with 2d data in go

|                | Correct Representation | Access/Assignment Convenience | Speed |
| -------------: | :--------------------: | :---------------------------: | :---: |
| Slice of slice | X                      | ✓                             | X     |
| Single slice   | X                      | X                             | ✓     |
| Struct type    | ✓                      | X                             | X     |

In general, we would like our codes to be

1. Easy to use
2. Not error-prone
3. Performant

At present, an author of numerical code must choose *one*.
The relative importance of these priorities will be application-specific, which
will make it hard to establish one common representation.
This lack of consistency will make it hard for packages to inter-operate.
Improvements to the compiler will reduce the performance penalty for using the
correct representation, but even then many methods are required to achieve optimal
performance.
A language built-in meets all three goals, enabling code that is
simultaneously clearer and more efficient.
Generalized slices allow gophers to write simple, fast, and correct numerical
and graphics code.

## Proposal

The proposed changes are described first here in the Proposal section.
The rationale for the specific design choices is discussed afterward in the
Discussion section.

### Syntax

Just as `[]T` is shorthand for a slice, `[,]T` is shorthand for a two-dimensional
slice, `[,,]T` a three-dimensional slice, etc.

### Allocation

A slice may be constructed either using the make built-in or via a literal.
The elements are guaranteed to be stored in a continuous slice, and are
guaranteed to be stored in "row-major" order.
Specifically, for a 2d-slice, the underlying data slice first contains all
elements in the first row, followed by all elements in the second row, etc.
Thus, the 5x3 table

	00 01 02 03 04
	10 11 12 13 14
	20 21 22 23 24

is stored as

	[00, 01, 02, 03, 04, 10, 11, 12, 13, 14, 20, 21, 22, 23, 24]

Similarly, for a 3d-slice with lengths m, n, and p, the data is arranged as

	[t111, t112, ... t11p, t121, ..., t12n, ... t211 ... , t2np, ... tmnp]

#### Making a multi-dimensional slice

A new N-dimensional slice (of generic type) may be allocated by using the make
command with a mandatory argument of a [N]int specifying the length in each
dimension, followed by an optional [N]int specifying the capacity in each
dimension.
If the capacity argument is not present, each capacity is defaulted to its
respective length argument.
These act like the length and capacity for slices, but on a per-dimension basis.
The slice will be filled with the zero value of the type

	s := make([,]T, [2]int{m, n}, [2]int{maxm, maxn})
	t := make([,]T, [...]int{m, n})
	s2 := make([,,]T, [...]int{m, n, p}, [...]int{maxm, maxn, maxp})
	t2 := make([,,]T, [3]int{m, n, p})

Calling make with a zero length or capacity is allowed, and is equivalent to
creating an equivalently sized multi-dimensional array and slicing it
(described fully below).
In the following code

	u := make([,,,]float32, [4]int{0, 6, 4, 0})
	v := [0][6][4][0]float32{}
	w := v[0:0, 0:6, 0:4, 0:0]

u and w both have lengths and capacities of [4]int{0, 6, 4, 0), and the
underlying data slice has 0 elements.

#### Slice literals

A slice literal can be constructed using nested braces

	u := [,]T{{x, y, z}, {a, b, c}}
	v := [,,]T{{{1, 2, 3, 4}, {5, 6, 7, 8}}, {{9, 10, 11, 12}, {13, 14, 15, 16}}}

The size of the slice will depend on the size of the brace sets, outside in.
For example, in a 2d-slice the number of rows is equal to the number of sets of
braces, and the number of columns is equal to the number of elements within
each set of braces.
In a 3d-slice, the length of the first dimension is the number of sets of brace
sets, etc.
Above, u has length [2, 3], and v has length [2, 2, 4].
It is a compile-time error if each element in a brace layer does not contain the
same number of elements.
Like normal slices and arrays, key-element literal construction is allowed.
For example, the two following constructions yield the same result

	[,]int{{0:1, 2:0},{1:1, 2:0}, {2:1}}
	[,]int{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

### Slicing

Slicing occurs by using the normal 2 or 3 index slicing rules in each dimension,
`i:j` or `i:j:k`.
The same panic rules as 1d-slices apply (`0 <= i <= j <= k <= capacity in that dim`).
Like slices, this updates the length and capacity in the respective dimensions

	a := make([,]int, [2]int{10, 2}, [2]int{10, 15})
	b := a[1:3, 3:5:6]

A multi-dimensional array may be sliced to create an nd-slice.
In

	var array [8][5]int
	b := array[2:6, 3:5]

`b` is a slice with lengths 4 and 2, capacities 6 and 2, and a stride of 5.

Represented graphically, the original `var a [8][5]int` is

	00 01 02 03 04
	10 11 12 13 14
	20 21 22 23 24
	30 31 32 33 34
	40 41 42 43 44
	50 51 52 53 54
	60 61 62 63 64
	70 71 72 73 74

After slicing, with `b := a[2:6, 3:5]`

	-- -- -- -- --
	-- -- -- -- --
	-- -- -- 23 24
	-- -- -- 33 34
	-- -- -- 43 44
	-- -- -- 53 54
	-- -- -- -- --
	-- -- -- -- --

where the numbered elements are those still visible to the slice.
The underlying data slice is

	[23 24 -- -- -- 33 34 -- -- -- 43 44 -- -- -- 53 54]

### Indexing

The simplest form of an index expression specifies a single integer index for
the left-most (outer-most) dimension of a slice, followed by 3-value (min, max,
cap) slice expressions for each of the inner dimensions.
This operation returns a slice with one dimension removed.
The returned slice shares underlying with the original slice, but with a new
offset and updated lengths and capacities.
As a shorthand, multiple indexing expressions may be combined into one.
That is `t[1,2,:]` is equivalent to `t[1,:,:][2,:]`, and , `t[5,4,1,2:4]` is equivalent
to `t[5,:,:,:][4,:,:][1,:][2:4]`

It follows that specifying all of the indices gets a single element of the slice.

An important consequence of the indexing rules is that the "indexed dimensions"
must be the leftmost ones, and the "sliced dimensions" must be the rightmost ones.

Examples:

Continuing the example above, `b[1,:]` returns the slice []int{33, 34}.

Other example statements:

	v := s[3,:] // v has type []T
	v := s[0, 1:3, 1:4:5]  // v has type [,]T
	v := s[:,:,2] // Compile error: specified dimension must be the leftmost
	v := s[5]  // v has type T
	v := s[1,:,:][2,:][0] // v has type T
	v := s[1,2,0] // v has type T

### Assignment

Assignment acts as it does in Go today.
The statement `s[i] = x` puts the value `x` into position `i` of the slice.

An index operation can be combined with an assignment operation to assign to a
higher-dimensional slice.

	s[1,:,:][0,:][2] = x

For convenience, the slicing and access expressions can be elided.

	s[1,0,2] = x // equivalent to the above

If any index is negative or if it is greater than or equal to the length
in that dimension, a runtime panic occurs.
Other combination operators are valid (assuming the slice is of correct type)

	t := make([,]float64, [2]int{2,3})
	t[1,2] = 6
	t[1,2] *= 2   // Now contains 12
	t[3,3] = 4    // Runtime panic, out of bounds (possiby a compile-time error
	              // if all indices are constants)

### Reshaping

A new built-in `reshape` allows the data in a 1d slice to be re-interpreted as a
higher dimensional slice in constant time.
The pseudo-signature is `func reshape(s []T, [N]int) [,...]T` where `N`
is an integer greater than one, and [,...]T is a slice of dimension `N`.
The returned slice shares the same underlying data as the input slice, and is
interpreted in the layout discussed in the "Allocation" section.
The product of the elements in the `[N]int` must be less than the length of the
input slice or a run-time panic will occur.

	s := []float64{0, 1, 2, 3, 4, 5, 6, 7}
	t := reshape(s, [2]int{4,2})
	fmt.Println(t[2,0]) // prints 4
	t[1,0] = -2
	t2 := reshape(s, [...]int{2,2,2})
	fmt.Println(t3[0,1,0]) // prints -2
	t3 := reshape(s, [...]int{2,2,2,2}) // runtime panic: reshape length mismatch

### Unpack

A new built-in `unpack` returns the underlying data slice and strides from a
higher dimensional slice.
The pseudo-signature is `func unpack(s [,...]T) ([]T, [N-1]int)`, where
[,...T] is a slice of dimension `N > 1`.
The returned array is the strides of the table.
The returned slice has the same underlying data as the input table.
The first element of the returned slice is the first accessible element of the
slice (element 0 in the underlying data), and the last element of the
returned slice is the last accessible element of the table.
For example, in a 2d-slice the end of the returned slice is element
`stride*len(s)[0]+len(s)[1]`

	t := [,]float64{{1,0,0},{0,1,0},{0,0,1}}
	t2 := t[:2,:2]
	s, stride := unpack(t2)
	fmt.Println(stride) // prints 3
	fmt.Println(s) // prints [1 0 0 0 1 0 0 0]
	s[2] = 6
	fmt.Println(t[0,2]) // prints 6


### Length / Capacity

Like slices, the `len` and `cap` built-in functions can be used on slices of
higher dimension.
Len and cap take in a slice and return a [N]int representing the lengths/
capacities in the dimensions of the slice.
If the slice is one-dimensional, an `int` is returned, not a `[1]int`.

	lengths := len(t)    // lengths is a [2]int
	nRows := len(t)[0]
	nCols := len(t)[1]
	maxElems := cap(t)[0] * cap(t)[1]

### Copy

The built-in `copy` will be changed to allow two slices of equal dimension.
Copy returns an `[N]int` specifying the number of elements that were copied in each
dimension.
For a 1d-slice, an `int` will be returned instead of a `[1]int`.

	n := copy(dst, src)   // n is a [N]int

Copy will copy all of the elements in the sub-slice from the first dimension to
`min(len(dst)[0], len(src)[0])` the second dimension to
`min(len(dst)[1], len(src)[1])`, etc.

	dst := make([,]int, [2]int{6, 8})
	src := make([,]int, [2]int{5, 10})
	n := copy(dst, src) // n == [2]int{5, 8}
	fmt.Println("All destination elements were overwritten:", n == len(dst))

Indexing can be used to copy data between slices of different dimension.

	s := []int{0, 0, 0, 0, 0}
	t := [,]int{{1,2,3}, {4,5,6}, {7,8,9}, {10,11,12}}
	copy(s, t[1,:])    // Copies all the whole second row of the slice
	fmt.Println(s)  // prints [4 5 6 0 0]
	copy(t[2,:], t[1,:]) // copies the second row into the third row

### Range

A range statement loops over the outermost dimension of a slice.
The "value" on the left hand side is the `n-1` dimensional slice with the first
element indexed.
That is,

	for i, v := range s {

	}

is identical to

	for i := 0; i < len(s)[0]; i++ {
		v := s[i,:, ...]
	}

for multi-dimensional slices (and i < len(s) for one-dimensional ones).

#### Examples

Two-dimensional slices.

	// Sum the rows of a 2d-slice
	rowsum := make([]int, len(t)[0])
	for i, s = range t{
		for _, v = range s{
			rowsum[i] += v
		}
	}

	// Sum the columns of a 2d-slice
	colsum := make([]int, len(t)[1])
	for i := range colsum {
		for j, v := range t[i, :]{
			colsum[j] += v
		}
	}

	// Matrix-matrix multiply (given existing slices a and b)
	c := make([,]float64, len(a)[0], len(b)[1])
	for i, sa := range a {
		for k, va := range sa {
			for j, vb := range b[k,:] {
				c[i,j] += va * vb
			}
		}
	}

Higher-dimensional slices

	t3 := [,,]int{{{1, 2, 3, 4}, {5, 6, 7, 8}}, {{9, 10, 11, 12}, {13, 14, 15, 16}}}
	for i, t2 := range t3 {
		fmt.Println(i, t2) // i ranges from 0 to 1, v is a [,]int
	}
	for j, s := range t3[1,:,:] {
		fmt.Println(i, s) // j ranges from 0 to 1, s is a []int
	}
	for k, v := range t[1,0,:] {
		fmt.Println(i, v) // k ranges from 0 to 3, v is an int
	}

	// Sum all of the elements
	var sum int
	for _, t2 := range t3 {
		for _, s := range t2 {
			for _, v := range s {
				sum += v
			}
		}
	}

### Reflect

Package reflect will have additions to support generalized slices.
In particular, enough will be added to enable calling C libraries with 2d-slice
data, as there is a large body of C libraries for numerical and graphics work.
Eventually, it will probably be desirable for reflect to add functions to
support multidimensional slices (MakeSliceN, SliceNOf, SliceN, etc.).
The exact signatures of these methods can be decided upon at a later date.

## Discussion

This section describes the rationale for the design choices made above, and
contrasts them with possible alternatives.

### Data Layout

Programming languages differ on the choice of row-major or column-major layout.
In Go, row-major ordering is forced by the existing semantics of arrays-of-arrays.
Furthermore, having a specific layout is more important than the exact choice so
that code authors can reason about data layout for optimal performance.

### Discussion -- Reshape

There are several use cases for reshaping, as discussed in the
[strided slices proposal](https://github.com/golang/go/issues/13253).
However, reshaping slices of arbitrary dimension (as proposed in the previous link)
does not compose with slicing (discussed more below).
This proposal allows for the common use case of transforming between linear and
multi-dimensional data while still allowing for slicing in the normal way.

The biggest question is if the input slice to reshape should be exactly as large
as necessary, or if it only needs to be "long enough".
The "long enough" behavior saves a slicing operation, and seems to better match
the behavior of `copy`.

Another possible syntax for reshape is discussed in
[issue 395](https://github.com/golang/go/issues/395).
Instead of a new built-in, one could use `t := s.([m1,m2,...,mn]T)`, where s
is of type `[]T`, and the returned type is `[,...]T` with
`len(t) == [n]int{m1, m2, ..., mn}`.
As discussed in #395, the `.()` syntax is typically reserved for type assertions.
This isn't strictly overloaded, since []T is not an interface, but it could be
confusing to have similar syntax represent similar ideas.
The difference between s.([,]T) and s.([m,n]T) may be too large for how similar
the expressions appear -- the first asserts that the value stored in the
interface `s` is a [,]T, while the second reshapes a `[]T` into a `[,]T` with
lengths equal to `m` and `n`.
A built-in function avoids these subtleties, and better matches the proposed
`unpack` built-in.

### Discussion -- Unpack

Like `reshape`, `unpack` is useful for manipulating slices in higher dimensions.
One major use-case is the allowing copy-free manipulation of data in a slice.
For example,

	// Strided presents data as a `strided slice`, where elements are not
	// contiguous in memory.
	type Strided struct {
		data []T
		len int
		stride int
	}

	func (s Strided) At(i int) T {
		return data[i*stride]
	}

	func GetCol(s [,]T, i int) Strided {
		data, stride := unpack(s)
		return Strided {data[i:], stride}
	}

See the indexing discussion section for more uses of this type.

Unpack is also necessary to pass slices to C code (and others) without copying data.
Using the `len` and `unpack` built-in functions provides enough information to
make such a call.
An example function is `Dgeqrf` which computes the QR factorization of a matrix.
The C signature is (roughly)

	dgeqrf(int m, int n, double* a, int lda)

A Go-wrapper to this function could be implemented as

	// Dgeqrf computes the QR factorization in-place using a call through cgo to LAPACK_e
	func Dgeqrf(d Dense) {
		l := len(d)
		data, stride := unpack(d)
		C.dgeqrf((C.int)(l[0]), (C.int)(l[1]), (*C.double)(&data[0]), (C.int)(stride))
	}

Such a wrapper is impossible without unpack, as it is otherwise impossible to
extract the underlying []float64 and strides without using unsafe.

Finally, `unpack` allows users to reshape higher-dimensional slices between one
another.
The user must check that the slice has not been viewed for this operation to
have the expected behavior.

	// Reshape23 reshapes a 2d slice into a 3d slice of the specified size. The
	// major dimension of a must not have been sliced
	func Reshape23(a [,]int, sz [3]int) [,,]int {
		data, stride := unpack(a)
		if stride != len(a)[0]{
			panic("a has been viewed")
		}
		return reshape(data, sz)
	}

### Indexing

A controversial aspect of the proposal is that indexing is asymmetric.
That is, an index expression has to be the left-most element

	t[1,:,:] // allowed
	t[:,:,1] // not allowed

The second expression is disallowed in this proposal so that the rightmost
(innermost) dimension always has a stride of 1 to match existing 1d-slice
semantics.
A proposal that enables symmetric indexing, such as `t[0,:,1]`, requires the
returned 1d object to contain a stride.
This is incompatible with Go slices today, but perhaps there could be a better
proposal nevertheless.
Let us examine possible alternatives.

It seems any proposal must address this issue in one of the following ways.

0. Accept the asymmetry (this proposal)
1. Do not add a higher-dimensional rectangular structure (Go today)
2. Disallow asymmetry by forbidding indexing
3. Modify the implementation of current Go slices to be strided
4. Add "strided slices" as a distinct type in the language

Option 1: This proposal, of course, feels that a multi-dimensional rectangular
structure is a good addition to the language (see Background section).
While multi-dimensional slices add some complexity to the language, this proposal
is an natural extension to slice semantics.
There are very few new rules to learn once the basics of slices are understood.
The generalization of slices decreases the complexity of many specific algorithms,
and so this proposal believes Go is improved on the whole with this generalization.

Option 2: One alternative is to keep the generalization of slices
proposed here, but eliminate asymmetry by disallowing indexing in all
dimensions, even the leftmost.
Under this kind of proposal, accessing a specific element of a slice is allowed

	v := s[0,1,2]

but not selecting a full sub-slice

	v := s[0,:,:]

While this is possible, it eliminates two major benefits of the indexing behavior
proposed here.

First, indexing allows for copy-free passing of data subsections to algorithms that
require a lower-dimensional slice.
For example,

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

Second, indexing, as specified, provides a very clear definition of `range` on
slices.
Without generalized indexing, it is unclear how `range` should behave or what the
syntax should be.
These benefits seem sufficient to include indexing in a proposal.

Option 3: Perhaps instead of generalizing Go slices as they are today, we should
change the implementation of 1d slices to be strided.
This would of course have to wait for Go 2, but a multi-dimensinal slice would
then naturally have `N` strides instead of `N-1`, and indexing can happen along
any dimension.

It seems that this change would not be beneficial.
First of all, there is a lot of code which relies on the assumption that slices
are contiguous.
All of this code would need to be re-written if the implementation of slices
were modified.
More importantly, it's not clear that the basic operation of accessing a strided
slice could be made as efficient as accessing a contiguous slice, since a strided
slice requires an additional multiplication by the stride.
Additionally, contiguous data makes optimization such as SIMD much easier.
Increasing the cost of all Go programs just to allow generalized indexing does
not seem like a good trade, and even programs that do use indexing may be slower
overall because of these extra costs.
It seems that having a linear data structure that is guaranteed to be contiguous
is very useful for compatibility and efficiency reasons.

Option 4: The last possibility is to abandon the idea of Go slices as the 1d case,
and instead build a proposal around a "strided slice" type.
In such a proposal, a "strided slice" is another 1d data structure in Go, that is
like a slice, except the data is strided rather than contiguous.
Here we will refer to such a type as `[:]T`.
Higher dimensional slices would really be higher dimensional strided slices,
`[::]T`, `[::::]T`, containing `N` strides rather than `N-1`.
This allows for indexing in any dimension, for example `t[:,1]` would return a
`[:]T`.
The syntactic sugar is clearly nice, but do the benefits outweigh the costs?

The benefit of such a type is to allow copy-free access to a column.
However, as stated in the `unpack` discussion section, it is already possible to
get access along a single column by implementing a Strided-like type.
Such a type could be (and is) implemented in a matrix library, for example

	type Vector struct {
		data []float64
		len int
		stride int
	}

	type Dense [,]float64

	// ColView returns a Vector whose elements are the i^th column of the receiver
	func (d Dense) ColView(i) Vector {
		s, stride := unpack(d)
		return Vector{
			data: s,
			len: len(d)[1],
			stride: stride,
		}
	}

	// Trace returns a Vector whose elements are the trace of the receiver
	func (d Dense) Trace() Vector {
		s, stride := unpack(d)
		return Vector{
			data: s,
			len: len(d)[0],
			stride: stride+1,
		}
	}

The `Vector` type can be used to construct higher-level functions.

	// Dot computes the dot product of two vectors
	func Dot(a, b Vector) float64 {
		if a.Len() != b.Len() {
			panic("vector length mismatch")
		}
		dot := a.At(0) * b.At(0)
		for i := 1; i < a.Len(); i++ {
			dot += a.At(i) * b.At(i)
		}
		return dot
	}

	// Mul returns the multiplication of matrices a and b.
	func Mul(a, b Dense) Dense {
		c := make(Dense, [2]int{len(a)[0], len(b)[1]})
		for i := range c {
			for j := range c[0]{
				c[i,j] = Dot(a.RowView(i), b.ColView(j))
			}
		}
		return c
	}

Thus, we can see that most of the behavior in strided slices is implementable
under the current proposal.
It seems that Vector has costs relative to traditional Go slices: indexing is
more expensive, and it is not immediately obvious where an API should use
`Vector` and where an API should use `[]float64`.
While these costs are real, these costs are also present with strided slices.
There are remaining benefits to a built-in strided slice type, but they are
mostly syntax.
It's easier to write `s[:,0]` than use a strided type, Go doesn't have generics
requiring a separate Strided type for each `T`, and range could not work on a
Strided type.
It's also likely easier to implement bounds checking elimination when the compiler
fully controls the data.

These benefits are not insignificant, but there are also costs in adding a `[:]T`
to the language.
A major cost is the plain addition of a new generic type.
Go is built on implementing a small set of orthogonal features that compose together
cleanly.
Strided slices are far from orthogonal with Go slices; they have almost exactly
the same function in the language.
Beyond that, the benefits to slices seem to be tempered by other consequences
of their implementation.
One argument for strided slices is to eliminate the cognitive dissonance in being
able to slice in one dimension but not another.
But, we also have to consider the cognitive complexity of additional language
features, and their interactions with built-in types.
Strided slices are almost identical to Go slices, but with small incompatibilites.
A user would have to learn the interactions between `[]T` and `[:]T` in terms of
assignability and/or conversions, the behavior of `copy`, `append`, etc.
Learning all of these rules is likely more difficult than learning that indexing
is asymmetric.
Finally, while strided slices arguably reduce the costs to column viewing, they
increase the costs in other areas like C interoperability.
Tools like LAPACK only allow matrices with an inner stride of 1, so strided slice
data would need extra allocation and copying before calls to Lapack, potentially
limiting some of the savings.
It seems the costs of a strided-slice built-in type outweigh their benefits,
especially in the presence of relatively easy language workarounds under the
current proposal.

It thus seems that even if we were designing Go from scratch today, we would still
want the proposed behavior here, where we accept the limitations of asymmetric
indexing to keep a smaller, more orthogonal language.

### Use of [N]int for Predefined Functions

This document proposes that `make`, `len`, `copy`, etc. accept and return `[N]int`.
This section describes possible alternatives, and defends this choice.

For the `len` built-in, it seems like there are four possible choices.

1. `lengths := len(t)     // returns [N]int` (this proposal)
2. `length := len(t, 0)   // returns the length of the slice along the first dimension`
3. `len(t[0,:]) or len(t[ ,:]) // returns the length along the second dimension`
4. `m, n, p, ... := len(t)`

The main uses of `len` either require a specific length from a slice (as in a
for statement), or getting all of the lengths of a slice (size comparison).
We would thus like to make both operations easy.

Option 3 can be ruled out immediately, as it require special parsing syntax to
account for zero-length dimensions.
For example, the expression `len(t[0,:])` blows up if the table has length 0
in the first dimension (and how else would you know the length except with `len`?.

Option 2 seems strictly inferior to option 1.
Getting an individual length is almost exactly the same in both cases, compare
`len(t)[1]` and `len(t,1)`, except getting all of the sizes is much harder in
option 1.

This leaves options 1 and 4.
They both return all lengths, and it is easy to use a specific length.
However, option 1 seems easier to work with in several ways.
The full lengths of slices are much easier to compare:

	if len(s) != len(t){...}

vs.

	ms, ns := len(s)
	mt, nt := len(t)
	if ms != mt || ns != nt {...}

It is also easier to compare a specific dimension

	if len(s)[0] != len(t)[0]{...}

vs

	ms, _ := len(s)
	mt, _ := len(t)
	if ms != mt {...}

Option 1 is also easier in a for loop

	for j := 0; j < len(s)[1]; j++ {...}

vs.

	_, n := len(s)
	for j := 0; j < n; j++ {...}

All of the examples above are in two-dimensions, which is arguably the best case
scenario for option 4.
Option 1 scales as the dimensions get higher, while option 4 does not.
Comparing a single length for a [,,,]T we see

	if len(s)[1] != len(t)[1]

vs.

	_, ns, _, _ := len(s)
	_, nt, _, _ := len(t)
	if ns != nt {...}

Comparing all lengths is much worse.

Based on `len` alone, it seems that option 1 is much worse.
Let us look at the interactions with the other predeclared functions.

First of all, it seems clear that the predeclared functions should all use
similar syntax, if possible.
If option 1 is used, then `make` should accept `[N]int`, and copy should return
an `[N]int`, while if option 4 is used `make` should accept individual arguments
as in

	make([,]T, len1, len2, cap1, cap2)

and `copy` should return individual arguments

	m,n := copy(s,t)

The simplest case of using `make` with known dimensions seems slightly better
for option 4.

	make([,]T, m, n)

is nicer than

	make([,]T, [2]int{m,n})

However, this seems like the only case where it is nicer.
If `m` and `n` are coming as arguments in a function, it may frequently be easier
to pass a `[2]int`, at which point option 4 forces

	make([,]T, lens[0], lens[1])

It is debatable in two dimensions, but in higher dimensions it seems clear that
passing a `[5]int` is easier than 5 individual dimensions, at which point

	make([,,,,]T, lens)

is much easier than

	make([,,,,]T, lens[0], lens[1], lens[2], lens[3], lens[4])

There are other common operations we should consider.
Making the same size slice is much easier under option 1

	make([,]T, len(s))

vs.

	m, n := len(s)
	make([,]T, m, n)

Or consider making the receiver for a matrix multiplication

	l := [2]int{len(a)[0], len(b)[1]}
	c := make([,]T, l)

vs.

	m, _ := len(a)
	_, n := len(b)
	c := make([,]T, m, n)

Finally, compare a grow-like operation.

	l := len(a)
	l[0] *= 2
	l[1] *= 2
	b := make([,]T, l)

vs.

	m, n := len(a)
	m *= 2
	n *= 2
	c := make([,]T, m, n)

The only example where option 4 is significantly better than option 1 is using
`make` with variables that already exist individually.
In all other cases, option 1 is at least as good as option 4, and in many cases
option 1 is significantly nicer.
It seems option 1 is preferable overall.

### Range

This behavior is a natural extension to the idea of range as looping over a
linear index.

Other ideas were considered, but all are significantly more complicated.
For instance, in a previous iteration of this draft, new syntax was introduced
for range clauses.
An alternate possibility is that range should loop over all elements of the slice,
not just the major dimension.
First of all, it not clear what the "index" portion of the clause should be.
If an `[N]int` is returned, as for the predeclared functions, it seems annoying
to use.

	// Apply a linear transformation to each element.
	for i, v := range t {
		t[i[0],i[1],i[2]] = 3*v + 4
	}

Perhaps each index should be individually returned, as in

	for i, j, k, v := range t {
		t[i,j,k] = 3*v + 4
	}

which seems okay, but it could be hard to tell if the final value is an index or
an element.
The bigger problem is that this definition of range means that it is required
to write a for-loop to index over the major dimension, an extremely common
operation.
The proposed range syntax enables ranging over all elements (using multiple range
statements), and makes ranging over the major dimension easy.

## Compatibility

This change is fully backward compatible with the Go1 spec.

## Implementation

A slice can be implemented in Go with the following data structure

	type Slice struct {
		Data       uintptr
		Len        [N]int
		Cap        [N]int
		Stride     [N-1]int
	}

As special cases, the 1d-slice representation would be as now, and a 2d-slice
would have the `Stride` field as an `int` instead of a `[1]int`.

Access and assignment can be performed using the strides.
For a two-dimensional slice, `t[i,j]` gets the element at `i*stride + j` in the
array pointed to by the Data uintptr.
More generally, `t[i0,i1,...,iN-2,iN-1]` gets the element at

	i0 * stride[0] + i1 * stride[1] + ... + iN-2 * stride[N-2] + iN-1

When a new slice is allocated, `Stride` is set to `Cap[N-1]`.

Slicing is as simple as updating the pointer, lengths, and capacities.

	t[i0:j0:k0, i1:j1:k1, ..., iN-1:jN-1:kN-1]

causes `Data` to update to the element indexed by `[i0,i1,...,iN-1]`,
`Len[d] = jd - id`, `Cap[d] = kd - id`, and Stride is unchanged.

## Implementation Schedule

Help is needed to determine the when and who for the implementation of this
proposal.
The gonum team would translate the code in gonum/matrix, gonum/blas,
and gonum/lapack to assist with testing the implementation.

## Non-goals

This proposal intentionally omits several suggested behaviors.
This is not to say those proposals can't ever be added (nor does it imply that
they will be added), but that they provide additional complications and can be
part of a separate proposal.

### Append

This proposal does not allow append to be used with higher-dimensional slices.
It seems natural that one could, say, append a [,]T to the "end" of a [,,]T,
but the interaction with slicing is tricky.
If a new slice is allocated, does it fill in the gaps with zero values?

### Arithmetic Operators

Some have called for slices to support arithmetic operators (+, -, *) to also
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
needs a rectangular data structure, the extension of slices to higher dimensions,
built into the language as a foundation for more advanced libraries.
This proposal describes a behavior for slices which is a strict improvement over
the options currently available.
It will be faster than the single-slice representation (index optimization and
range), more convenient than the slice of slice representation (range, copy,
len), and will provide a correct representation of the data that is more compile-
time verifiable than the struct representation.
The desire for slices is not driven by syntax and ease-of-use, though that is a
huge benefit, but instead a request for safety and speed; the desire to build
"simple, reliable, and efficient software".

|                | Correct Representation | Access/Assignment Convenience | Speed |
| -------------: | :--------------------: | :---------------------------: | :---: |
| Slice of slice | X                      | ✓                             | X     |
| Single slice   | X                      | X                             | ✓     |
| Struct type    | ✓                      | X                             | X     |
| Built-in       | ✓                      | ✓                             | ✓     |

## Open issues

1. In the discussion, it was mentioned that adding a SliceHeader2 is a bad idea.
This can be removed from the proposal, but some other mechanism should be added
that allows data in 2d-slices to be passed to C.
It has been suggested that the type

	type NDimSliceHeader struct {
    	Data   unsafe.Pointer
    	Stride []int  // len(N-1)
    	Len    []int  // len(N)
    	Cap    []int  // len(N)
    }

would be sufficient.
2. The "reshaping" syntax as discussed above.
3. In a slice literal, if part of the slice is specified with a key-element literal,
does the whole expression need to use key-element syntax?
4. Given the presence of `unshape`, is there any use for three-element syntax?