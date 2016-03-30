# Type Functions

This is a proposal for adding generics to Go, written by Ian Lance
Taylor in June, 2010.
This proposal will not be adopted.
It is being presented as an example for what a complete generics
proposal must cover.

## Defining a type function

We introduce _type functions_.
A type function is a named type with zero or more parameters.
The syntax for declaring a type function is:

```
type name(param1, param2, ...) definition
```

Each parameter to a type function is simply an identifier.
The _definition_ of the type function is any type, just as with an
ordinary type declaration.
The definition of a type function may use the type parameters any
place a type name may appear.

```
type Vector(t) []t
```

## Using a type function

Any use of a type function must provide a value for each type
parameter.
The value must itself be a type, though in some cases the exact type
need not be known at compile time.

We say that a specific use of a type function is concrete if all the
values passed to the type function are concrete.
All predefined types are concrete and all type literals composed using
only concrete types are concrete.
A concrete type is known statically at compile time.

```
type VectorInt Vector(int)      // Concrete.
```

When a type function is used outside of a func or the definition of a
type function, it must be concrete.
That is, global variables and constants are required to have concrete
types.

In this example:

```
var v Vector(int)
```

the name of the type of the variable `v` will be `Vector(int)`, and
the value of v will have the representation of `[]int`.
If `Vector(t)` has any methods, they will be attached to the type of
`v` \(methods of type functions are discussed further below\).

## Generic types

A type function need not be concrete when used as the type of a
function receiver, parameter, or result, or anywhere within a
function.
A specific use of a type function that is not concrete is known as
generic.
A generic type is not known at compile time.

A generic type is named by using a type function with one or more
unbound type parameters, or by writing a type function with parameters
attached to generic types.
When writing an unbound type parameter, it can be ambiguous whether
the intent is to use a concrete type or whether the intent is to use
an unbound parameter.
This ambiguity is resolved by using the `type` keyword after each
unbound type parameter.

\(Another way would be to use a different syntax for type variables.
For example, `$t`.  This has the benefit of keeping the grammar
simpler and not needing to worry about where types are introduced
vs. used.\)

```
func Bound(v Vector(int))
func Unbound(v Vector(t type))
```

The `type` keyword may also be used without invoking a type function:

```
func Generic(v t type) t
```

In this example the return type is the same as the parameter type.
Examples below show cases where this can be useful.

A value (parameter, variable, etc.) with a generic type is represented
at runtime as a generic value.
A generic value is a dynamic type plus a value of that type.
The representation of a generic value is thus the same as the
representation of an empty interface value.
However, it is important to realize that the dynamic type of a generic
value may be an interface type.
This of course can never happen with an ordinary interface value.

Note that if `x` is a value of type `Vector(t)`, then although `x` is
a generic value, the elements of the slice are not.
The elements have type `t`, even though that type is not known.
That is, boxing a generic value only occurs at the top level.

## Generic type identity

Two generic types are identical if they have the same name and the
parameters are identical.
This can only be determined statically at compile time if the names
are the same.
For example, within a function, `Vector(t)` is identical to
`Vector(t)` if both `t` identifiers denote the same type.
`Vector(int)` is never identical to `Vector(float)`.
`Vector(t)` may or may not be identical to `Vector(u)`;
identity can only be determined at runtime.

Checking type identity at runtime is implemented by walking through
the definition of each type and comparing each component.
At runtime all type parameters are known, so no ambiguity is possible.
If any literal or concrete type is different, the types are different.

## Converting a value of concrete type to a generic type

Sometimes it is necessary to convert a value of concrete type to a
generic type.
This is an operation that may fail at run time.
This is written as a type assertion: `v.(t)`.
This will verify at runtime that the concrete type of `v` is identical
to the generic type `t`.

\(Open issue: Should we use a different syntax for this?\)

\(Open issue: In some cases we will want the ability to convert an
untyped constant to a generic type.
This would be a runtime operation that would have to implement the
rules for conversions between numeric types.
How should this conversion be written?
Should we simply use `N`, as in `v / 2`?
The problem with that syntax is that the runtime conversion can fail
in some cases, at least when `N` is not in the range 0 to 127 inclusive.
The same objection applies to T(n).
That suggests N.(t), but that looks weird.\)

\(Open issue: It is possible that we will want the ability to convert
a value from a known concrete type to a generic type.
This would also require a runtime conversion.
I'm not sure whether this is necessary or not.
What would be the syntax for this?\)

## Generic value operations

A function that uses generic values is only compiled once.
This is different from C++ templates.

The only operations permitted on a generic value are those implied by
its type function.
Some operations will require extra work at runtime.

### Declaring a local variable with generic type.

This allocates a new generic value with the appropriate dynamic type.
Note that in the general case the dynamic type may need to be
constructed at runtime, as it may itself be a type function with
generic arguments.

### Assigning a generic value

As with any assignment, this is only permitted if the types are
identical.
The value is copied as appropriate.
This is much like assignment of values of empty interface type.

### Using a type assertion with a generic value

Programs may use type assertions with generic values just as with
interface values.
The type assertion succeeds if the target type is identical to the
value's dynamic type.
In general this will require a runtime check of type identity as
described above.

\(Open issue: Should it be possible to use a type assertion to convert
a generic value to a generic type, or only to a concrete type?
Converting to a generic type is a somewhat different operation from
a standard type assertion.
Should it use a different syntax?\)

### Using a type switch with a generic value

Programs may use type switches with generic values just as with
interface values.

### Using a conversion with a generic value

Generic values may only be converted to types with identical
underlying types.
This is only permitted when the compiler can verify at compile time
that the conversion is valid.
That is, a conversion to a generic type T is only permitted if the
definition of T is identical to the definition of the generic type of
the value.

```
        var v Vector(t)
        a := Vector(t)(v)    // OK.
        type MyVector(t) []t
        b := MyVector(t)(v)  // OK.
        c := MyVector(u)(v)  // OK iff u and t are known identical types.
        d := []int(v)        // Not OK.
```

### Taking the address of a generic value

Programs may always take the address of a generic value.
If the generic value has type `T(x)` this produces a generic value of
type `*T(x)`.
The new type may be constructed at runtime.

### Indirecting through a generic value

If a generic value has a generic type that is a pointer `*T`, then a
program may indirect through the generic value.
This will be similar to a call to `reflect.PtrValue.Elem`.
The result will be a new generic value of type `T`.

### Indexing or slicing a generic value

If a generic value has a generic type that is a slice or array, then a
program may index or slice the generic value.
This will be similar to a call to `reflect.ArrayValue.Elem` or
`reflect.SliceValue.Elem` or `reflect.SliceValue.Slice` or
`reflect.MakeSlice`.
In particular, the operation will require a multiplication by the size
of the element of the slice, where the size will be fetched from the
dynamic type.
The result will be a generic value of the element type of the slice or
array.

### Range over a generic value

If a generic value has a generic type that is a slice or array, then a
program may use range to loop through the generic value.

### Maps

Similarly, if a generic value has a generic type that is a map,
programs may index into the map, check whether an index is present,
assign a value to the map, range over a map.

### Channels

Similarly, if a generic value has a generic type that is a channel,
programs may send and receive values of the appropriate generic type,
and range over the channel.

### Functions

If a generic value has a generic type that is a function, programs may
call the function.
Where the function has parameters which are generic types, the
arguments must have identical generic type or a type assertion much be
used.
This is similar to `reflect.Call`.

### Interfaces

If a generic value has a generic type that is an interface, programs
may call methods on the interface.
This is much like calling a function.
Note that a type assertion on a generic value may return an interface
type, unlike a type assertion on an interface value.
This in turn means that a double type assertion is meaningful.

```
        a.(InterfaceType).(int)
```

### Structs

If a generic value has a generic type that is a struct, programs may
get and set struct fields.
In general this requires finding the description of the field in the
dynamic type to discover the appropriate concrete type and field
offsets.

### That is all

Operations that are not explicitly permitted for a generic value are
forbidden.

### Scope of generic type parameters

When a generic type is used, the names of the type parameters have
scope.
The generic type normally provides the type of some name; the scope of
the unbound type parameters is the same as the scope of that name.
In cases where the generic type does not provide the type of some
name, then the unbound type parameters have no scope.
Within the scope of an unbound type parameter, it may be used as a
generic type.

```
func Head(v Vector(t type)) {
        var first t
        first = v[0]
}
```

### Scopes of function parameters

In order to make this work nicely, we change the scope of function
receivers, parameters, and results.
We now define their scope to start immediately after they are defined,
rather than starting in the body of the function.
This means that a function parameter may refer to the unbound type
parameters of an earlier function parameter.

```
func SetHead(v Vector(t type), e t) t {
        v[0] = e
        return e
}
```

The main effect of this change in scope will be to change the
behaviour of cases where a function parameter has the same name as a
global type, and that global type was used to define a subsequent
function parameter.

\(The alternate notation approach would instead define that the
variables only persist for the top-level statement in which they
appear, so that

```
func SetHead(v Vector($t), e $t) $t { ... }
```

doesn't have to worry about which t is the declaration (the ML
approach).
Another alternative is to do what C++ does and explicitly introduce
them.

```
generic(t) func SetHead(v Vector(t), e t) t { ... } ]
```

\)

### Function call argument type checking

As can be seen by the previous example, it is possible to use generic
types to write functions in which two parameters have related types.
These types are checked at the point of the function call.
If the types at the call site are concrete, the type checking is
always done by the compiler.
If the types are generic, then the function call is only permitted if
the argument types are identical to the parameter types.
The arguments are matched against the required types from left to
right, determining bindings for the unbound type parameters.
Any failure of binding causes the compiler to reject the call with a
type error.
Any case where one unbound type parameter is matched to a different
unbound type parameter causes the compiler to reject the call with a
type error.
In those cases, the call site must use an explicit type assertion,
checked at run time, so that the call can be type checked at compile
time.

```
        var vi Vector(int)
        var i int
        SetHead(vi, 1)          // OK
        SetHead(vi, i)          // OK
        var vt Vector(t)
        var i1 t
        SetHead(vt, 1)          // OK?  Unclear.  See above.
        SetHead(vt, i)          // Not OK; needs syntax
        SetHead(vt, i1)         // OK
        var i2 q                // q is another generic type
        SetHead(vt, q)          // Not OK
        SetHead(vt, q.(t))      // OK (may fail at run time)
```

### Function result types

The result type of a function can be a generic type.
The result will be returned to the caller as a generic value.
If the call site uses concrete types, then the result type can often
be determined at compile time.
The compiler will implicitly insert a type assertion to the expected
concrete type.
This type assertion can not fail, because the function will have
ensured that the result has the matching type.
In other cases, the result type may be a generic type, in which case
the returned generic value will be handled like any other generic
value.

### Making one function parameter the same type as another

Sometime we want to say that two function parameters have the same
type, or that a result parameter has the same type as a function
parameter, without specifying the type of that parameter.
This can be done like this:

```
func Choose(which bool, a t type, b t) t
```

\(Or func `Choose(which bool, a $t, b $t) $t`\)

The argument `a` is passed as generic value and binds the type
parameter `t` to `a`'s type.
The caller must ensure that `b` has the same type as `a`.
`b` will then also be passed as a generic value.
The result will be returned as a generic value; it must again have the
same type.

Another example:

```
type Slice(t) []t
func Repeat(x t type, n int) Slice(t) {
        a := make(Slice(t), n)
        for i := range a {
                a[i] = x
        }
        return a
}
```

\(Or `func Repeat(x $t, n int) []$t { ... }`\)

### Nested generic types

It is of course possible for the argument to a generic type to itself
be a generic type.
The above rules are intended to permit this case.

```
type Pair(a, b) struct {
        first a
        second b
}
func Sum(a Pair(Vector(t type), Vector(t))) Vector(t)
```

Note that the first occurrence of `t` uses the `type` keyword to
declare it as an unbound type parameter.
The second and third occurrences do not, which means that they are the
type whose name is `t`.
The scoping rules mean that that `t` is the same as the one bound by the
first use of Vector.
When this function is called, the type checking will match `t` to the
argument to the first `Vector`, and then require that the same `t`
appear as the argument to the second `Vector`.

### Unknown generic types

Note that it is possible to have a generic value whose type can not be
named.
This can happen when a result variable has a generic type.

```
func Unknown() t type
```

Now if one writes

```
x := Unknown()
```

then x is a generic value of unknown and unnamed type.
About all you can do with such a value is assign it using `:=` and use
it in a type assertion or type switch.
The only way that `Unknown` could return a value would be to use some
sort of conversion.

### Methods on generic types

A generic type may have methods.
When a generic type is used as a receiver, the arguments must all be
simple unbound names.
Any time a value of this generic type is created, whether the value is
generic or concrete, it will acquire all the methods defined on the
generic type.
When calling these methods, the receiver will of course be passed as a
generic value.

```
func (v Vector(t type)) At(int i) t {
        return v[i]
}

func (v Vector(t type)) Set(i int, x t) {
        v[i] = x
}
```

A longer example:

```
package hashmap

type bucket(keytype, valtype) struct {
        next *bucket(keytype, valtype)
        key keytype
        val valtype
}

type Hashfn(keytype) func(keytype) uint

type Eqfn(keytype) func(keytype, keytype) bool

type Hashmap(keytype, valtype) struct {
        hashfn Hashfn(keytype)
        eqfn Eqtype(keytype)
        buckets []bucket(keytype, valtype)
        entries int
}

func New(hashfn Hashfn(keytype type), eqfn Eqfn(keytype),
         _ valtype type) *Hashmap(keytype, valtype) {
        return &Hashmap(k, v){hashfn, eqfn,
                make([]bucket(keytype, valtype), 16),
                0}
}

// Note that the dummy valtype parameter in the New function
// exists only to get valtype into the function signature.
// This feels wrong.

func (p *Hashmap(keytype type, vvaltype type))
          Lookup(key keytype) (found bool, val valtype) {
        h := p.hashfn(key) % len(p.buckets)
        for b := buckets[h]; b != nil; b = b.next {
                if p.eqfn(key, b.key) {
                        return true, b.val
                }
        }
        return
}
```

In the alternate syntax:

```
package hash

type bucket($key, $val) struct {
        next *bucket($key, val)
        key $key
        val $val
}

type Map($key, $val) struct {
        hash func($key) uint
        eq func($key, $key) bool
        buckets []bucket($key, $val)
        entries int
}

func New(hash func($key) uint, eq func($key, $key) bool, _ $val)
                *Map($key, $val) {
        return &Map($key, $val){
                hash,
                eq,
                make([]bucket($key, $val), 16),
                0,
        }
}

// Again note dummy $val in the arguments to New.
```

## Concepts

In order to make type functions more precise, we can additionally
permit the definition of the type function to specify an interface.
This means that whenever the type function is used, the argument is
required to satisfy the interface.
In homage to the proposed but not accepted C++0x notion, we call this
a concept.

```
type PrintableVector(t Stringer) []t
```

Now `PrintableVector` may only be used with a type that implements the
interface `Stringer`.
This in turn means that given a value whose type is the parameter to
`PrintableVector`, a program may call the `String` method on that
value.

```
func Concat(p PrintableVector(t type)) string {
        s := ""
        for _, v := range p {
                s += v.String()
        }
        return s
}
```

Attempting to pass `[]int` to `Concat` will cause the compiler to
issue a type checking error.
But if `MyInt` has a `String` method, then calling `Concat` with
`[]MyInt` will succeed.

The interface restriction may also be used with a parameter whose type
is a generic type:

```
func Print(a t type Stringer)
```

This example is not useful, as it is pretty much equivalent to passing
a value of type Stringer, but there is a useful example below.

Concepts specified in type functions are type checked as usual.
If the compiler does not know statically that the type implements the
interface, then the type check fails.
In such cases an explicit type assertion is required.

```
func MyConcat(v Vector(t type)) string {
        if pv, ok := v.(PrintableVector(t)); ok {
                return Concat(pv)
        }
        return "unprintable"
}
```

\(Note that this does a type assertion to a generic type.  Should it
use a different syntax?\)

The concept must be an interface type, but it may of course be a
generic interface type.
When using a generic interface type as a concept, the generic
interface type may itself use as an argument the type parameter which
it is restricting.

```
type Lesser(t) interface {
        Less(t) bool
}
func Min(a, b t type Lesser(t)) t {
        if a.Less(b) {
                return a
        }
        return b
}
```

\(`type Mintype($t Lesser($t)) $t`\)

This is complex but useful. OK, the function `Min` is not all that
useful, but this looks better when we write

```
func Sort(v Vector(t type Lesser(t)))
```

which can sort any Vector whose element type implements the Lesser
interface.

## A note on operator methods

You will have noticed that there is no way to use an operator with a
generic value.
For example, you can not add two generic values together.
If we implement operator methods, then it will be possible to use this
in conjunction with the interface restrictions to write simple generic
code which uses operators.
While operator methods are of course a separate extension, I think
it's important to ensure that they can work well with generic values.

```
type Addable(t) interface {
        Binary+(t) t
}
type AddableSlice(t Addable(t)) []t
func Sum(v AddableSlice) t {
        var sum t
        for _, v := range v {
                sum = sum + v
        }
        return sum
}
```

## Some comparisons to C++ templates

Obviously the big difference between this proposal and C++ templates
is that C++ templates are compiled separately.
This has various consequences.
Some C++ template features that can not be implemented using type
functions:

* C++ templates permit data structures to be instantiated differently for different component types.
* C++ templates may be instantiated for constants, not just for types.
* C++ permits specific instantiations for specific types or constants.

The advantages of type functions are:

* Faster compile time.
* No need for two-phase name lookup.  Only the scope of the definition is relevant, not the scope of use.
* Clear syntax for separating compile-time errors from run-time errors.  Avoids complex compile-time error messages at the cost of only detecting some problems at runtime.
* Concepts also permit clear compile time errors.

In general, C++ templates have the advantages and disadvantages of
preprocessor macros.

## Summary

This proposal will not be adopted.
It's basically terrible.

The syntax is confusing: ```MyVector(t)(v)``` looks like two function
calls, but it's actually a type conversion to a type function.

The notion of an unbound type parameter is confusing, and the
syntax (a trailing `type` keyword) only increases that confusion.

Types in Go refer to themselves.
The discussion of type identity does not discuss this.
It means that comparing type identity at run time, such as in a type
assertion, requires avoiding loops.
Generic type assertions look like ordinary type assertions, but are
not constant time.

The need to pass an instance of the value type to `hashmap.New` is a
symptom of a deeper problem.
This proposal is trying to treat generic types like interface types,
but interface types have a simple common representation and generic
types do not.
Value representations should probably be expressed in the type system,
not inferred at run time.

The proposal suggests that generic functions can be compiled once.
It also claims that generic types can have methods.
If I write

```
type Vector(t) []t

func (v Vector(t)) Read(b []t) (int, error) {
	return copy(b, v), nil
}
```

then `Vector(byte)` should implement `io.Reader`.
But `Vector(t).Read` is going to be implemented using a generic value,
while `io.Reader` expects a concrete value.
Where is the code that translates from the generic value to the
concrete value?
