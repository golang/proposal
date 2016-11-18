// Copyright 2016 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// package slicebench implements tests to support the analysis in proposal 6282.
// It compares the performance of multi-dimensional slices implemented using a
// single slice and using a struct type.
package slicebench

import (
	"math"
	"math/rand"
	"testing"
)

var (
	m = 300
	n = 400
	k = 200

	lda = k
	ldb = k
	ldc = n
)

var a, b, c []float64

var A, B, C Dense

var aStore, bStore, cStore []float64 // data storage for the variables above

func init() {
	// Initialize the matrices to random data.
	aStore = make([]float64, m*lda)
	for i := range a {
		aStore[i] = rand.Float64()
	}
	bStore = make([]float64, n*ldb)
	for i := range b {
		bStore[i] = rand.Float64()
	}
	cStore = make([]float64, n*ldc)
	for i := range c {
		cStore[i] = rand.Float64()
	}

	a = make([]float64, len(aStore))
	copy(a, aStore)
	b = make([]float64, len(bStore))
	copy(b, bStore)
	c = make([]float64, len(cStore))
	copy(c, cStore)

	// The struct types use the single slices as underlying data.
	A = Dense{lda, m, k, a}
	B = Dense{lda, n, k, b}
	C = Dense{lda, m, n, c}
}

// resetSlices resets the data to their original (randomly generated) values.
// The Dense values share the same undelying data as the single slices, so this
// works for both single slice and struct representations.
func resetSlices(be *testing.B) {
	copy(a, aStore)
	copy(b, bStore)
	copy(c, cStore)
	be.ResetTimer()
}

// BenchmarkNaiveSlices measures a naive implementation of C += A * B^T using
// the single slice representation.
func BenchmarkNaiveSlices(be *testing.B) {
	resetSlices(be)
	for t := 0; t < be.N; t++ {
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
}

// Dense represents a two-dimensional slice with the specified sizes.
type Dense struct {
	stride int
	rows   int
	cols   int
	data   []float64
}

// At returns the element at row i and column j.
func (d *Dense) At(i, j int) float64 {
	if uint(i) >= uint(d.rows) {
		panic("rows out of bounds")
	}
	if uint(j) >= uint(d.cols) {
		panic("cols out of bounds")
	}
	return d.data[i*d.stride+j]
}

// AddSet adds v to the current value at row i and column j.
func (d *Dense) AddSet(i, j int, v float64) {
	if uint(i) >= uint(d.rows) {
		panic("rows out of bounds")
	}
	if uint(j) >= uint(d.cols) {
		panic("cols out of bounds")
	}
	d.data[i*d.stride+j] += v
}

// BenchmarkAddSet measures a naive implementation of C += A * B^T using
// the Dense representation.
func BenchmarkAddSet(be *testing.B) {
	resetSlices(be)
	for t := 0; t < be.N; t++ {
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
}

// AtNP gets the value at row i and column j without panicking if a bounds check
// fails.
func (d *Dense) AtNP(i, j int) float64 {
	if uint(i) >= uint(d.rows) {
		// Corrupt a value in data so the bounds check still has an effect if it
		// fails. This way, the method can be in-lined but the bounds checks are
		// not trivially removable.
		d.data[0] = math.NaN()
	}
	if uint(j) >= uint(d.cols) {
		d.data[0] = math.NaN()
	}
	return d.data[i*d.stride+j]
}

// AddSetNP adds v to the current value at row i and column j without panicking if
// a bounds check fails.
func (d *Dense) AddSetNP(i, j int, v float64) {
	if uint(i) >= uint(d.rows) {
		// See comment in AtNP.
		d.data[0] = math.NaN()
	}
	if uint(j) >= uint(d.cols) {
		d.data[0] = math.NaN()
	}
	d.data[i*d.stride+j] += v
}

// BenchmarkAddSetNP measures C += A * B^T using the Dense representation with
// calls to methods that do not panic. This simulates a compiler that can inline
// the normal At and Set methods.
func BenchmarkAddSetNP(be *testing.B) {
	resetSlices(be)
	for t := 0; t < be.N; t++ {
		for i := 0; i < m; i++ {
			for j := 0; j < n; j++ {
				var t float64
				for l := 0; l < k; l++ {
					t += A.AtNP(i, l) * B.AtNP(j, l)
				}
				C.AddSetNP(i, j, t)
			}
		}
	}
}

// AtNB gets the value at row i and column j without performing any bounds checking.
func (d *Dense) AtNB(i, j int) float64 {
	return d.data[i*d.stride+j]
}

// AddSetNB adds v to the current value at row i and column j without performing
// any bounds checking.
func (d *Dense) AddSetNB(i, j int, v float64) {
	d.data[i*d.stride+j] += v
}

// BenchmarkAddSetNB measures C += A * B^T using the Dense representation with
// calls to methods that do not check bounds. This simulates a compiler that can
// prove the bounds checks redundant and eliminate them.
func BenchmarkAddSetNB(be *testing.B) {
	resetSlices(be)
	for t := 0; t < be.N; t++ {
		for i := 0; i < m; i++ {
			for j := 0; j < n; j++ {
				var t float64
				for l := 0; l < k; l++ {
					t += A.AtNB(i, l) * B.AtNB(j, l)
				}
				C.AddSetNB(i, j, t)
			}
		}
	}
}

// BenchmarkSliceOpt measures an optimized implementation of C += A * B^T using
// the single slice representation.
func BenchmarkSliceOpt(be *testing.B) {
	resetSlices(be)
	for t := 0; t < be.N; t++ {
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
	}
}

// RowViewNB gets the specified row of the Dense without checking bounds.
func (d *Dense) RowViewNB(i int) []float64 {
	return d.data[i*d.stride : i*d.stride+d.cols]
}

// BenchmarkDenseOpt measures an optimized implementation of C += A * B^T using
// the Dense representation.
func BenchmarkDenseOpt(be *testing.B) {
	resetSlices(be)
	for t := 0; t < be.N; t++ {
		for i := 0; i < m; i++ {
			as := A.RowViewNB(i)
			cs := C.RowViewNB(i)
			for j := 0; j < n; j++ {
				bs := b[j*lda:]
				var t float64
				for l, v := range as {
					t += v * bs[l]
				}
				cs[j] += t
			}
		}
	}
}
