# Go 1.18 Implementation of Generics via Dictionaries and Gcshape Stenciling


This document describes the implementation of generics via dictionaries and
gcshape stenciling in Go 1.18.  It provides more concrete and up-to-date
information than described in the [Gcshape design document](https://github.com/golang/proposal/blob/master/design/generics-implementation-gcshape.md)

The compiler implementation of generics (after typechecking) focuses mainly on creating instantiations of generic functions and methods that will execute with arguments that have concrete types. In order to avoid creating a different function instantiation for each invocation of a generic function/method with distinct type arguments (which would be pure stenciling), we pass a **dictionary** along with every call to a generic function/method. The [dictionary](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-dictionaries.md) provides relevant information about the type arguments that allows a single function instantiation to run correctly for many distinct type arguments.


However, for simplicity (and performance) of implementation, we do not have a single compilation of a generic function/method for all possible type arguments. Instead, we share an instantiation of a generic function/method among sets of type arguments that have the same gcshape.


## Gcshapes

A **gcshape** (or **gcshape grouping**) is a collection of types that can all share the same instantiation of a generic function/method in our implementation when specified as one of the type arguments. So, for example, in the case of a generic function with a single type parameter, we only need one function instantiation for all type arguments in the same [gcshape](https://github.com/golang/proposal/blob/master/design/generics-implementation-gcshape.md) grouping. Similarly, for a method of a generic type with a single type parameter, we only need one instantiation for all type arguments (of the generic type) in the same gcshape grouping. A **gcshape type** is a specific type that we use in the implementation in such an instantiation to fill in for all types of the gcshape grouping.


We are currently implementing gcshapes in a fairly fine-grained manner. Two concrete types are in the same gcshape grouping if and only if they have the same underlying type or they are both pointer types. We are intentionally defining gcshapes such that we don’t ever need to include any operator methods (e.g. the implementation of the “+” operator for a specified type arg) in a dictionary. In particular, fundamentally different built-in types such as `int` and `float64` are never in the same gcshape. Even `int16` and `int32` have distinct operations (notably left and right shift), so we don’t put them in the same gcshape. Similarly, we intend that all types in a gcshape will always implement builtin methods (such as `make` / `new` / `len` ) in the same way. We could include some very closely related built-in types (such as `uint` and `uintptr`) in the same gcshape, but are not currently doing that. This is already implied by our current fine-grain gcshapes, but we also always want an interface type to be in a different gcshape from a non-interface type (even if the non-interface type has the same two-field structure as an interface type). Interface types behave very differently from non-interface types in terms of calling methods, etc.


We currently name each gcshape type based on the unique string representation (as implemented in `types.LinkString`) of its underlying type. We put all shape types in a unique builtin-package “`go.shape`”. For implementation reasons (see next section), we happen to include in the name of a gcshape type the index of the gcshape argument in the type parameter list. So, a type with underlying type “string” would correspond to a gcshape type named “`go.shape.string_0`” or “`go.shape.string_1`”, depending on whether the type is used as the first or second type argument of a generic function or type. All pointer types are named after a single example type `*uint8`, so the names of gcshapes for pointer shapes are `go.shape.*uint8_0`, `go.shape.*uint8_1`, etc.


We refer to an instantiation of a generic function or method for a specific set of shape type arguments as a **shape instantiation**.

## Dictionary Format

Each dictionary is statically defined at compile-time. A dictionary corresponds to a call site in a program where a specific generic function/method is called with a specific set of concrete type arguments. A dictionary is needed whenever a generic function/method is called, regardless if called from a non-generic or generic function/method. A dictionary is currently named after the fully-qualified generic function/method name being called and the names of the concrete type arguments. Two example dictionary names are `main..dict.Map[int,bool]` and `main..dict.mapCons[int,bool].Apply)`. These are the dictionaries needed for a call or reference to `main.Map[int, bool]()` and `rcvr.Apply()`, where `rcvr` has type `main.mapCons[int, bool]`. The dictionary contains the information needed to execute a gcshape-based instantiation of that generic function/method with those concrete type arguments. Dictionaries with the same name are fully de-duped (by some combination of the compiler and the linker).


We can gather information on the expected format of a dictionary by analyzing the shape instantiation of a generic function/method.  We analyze an instantiation, instead of the generic function/method itself, because the required dictionary entries can depend on the shape arguments - notably whether a shape argument is an interface type or not.  It is important that the instantiation has been “transformed” enough that all implicit interface conversions (`OCONVIFACE`) have been made explicit.  Explicit or implicit interface conversions (in particular, conversions to non-empty interfaces) may require an extra entry in the dictionary.


In order to create the dictionary entries, we often need to substitute the shape type arguments with the real type arguments associated with the dictionary.  The shape type arguments must therefore be fully distinguishable, even if several of the type arguments happen to have the same shape (e.g. they are both pointer types).  Therefore, as mentioned above, we actually add the index of the type parameter to the shape type, so that different type arguments can be fully distinguished correctly.


The types of entries in a dictionary are as follows:

* **The list of the concrete type arguments of the generic function/method**
   * Types in the dictionary are always the run-time type descriptor (a pointer to `runtime._type`)
* **The list of all (or needed) derived types**, which appear in or are implicit in some way in the generic function/method, substituted with the concrete type arguments.  
   * That is, the list of concrete types that are specifically derived from the type parameters of the function/method (e.g. `*T`, `[]T`, `map[K, V]`, etc) and used in some way in the generic function/method.
   * We currently use the derived types for several cases where we need the runtime type of an expression.  These cases include explicit or implicit conversions to an empty interface, and type assertions and type switches, where the type of the source value is an empty interface.
   * The derived type and type argument entries are also used at run time by the debugger to determine the concrete type of arguments and local variables.  At compile time, information about the type argument and derived type dictionary entries is emitted with the DWARF info.  For each argument or local variable that has a parameterized type, the DWARF info also indicates the dictionary entry that will contain the concrete type of the argument or variable. 
* **The list of all sub-dictionaries**:
   * A sub-dictionary is needed for a generic function/method call inside a generic function/method, where the type arguments of the inner call depend on the type parameters of the outer function.  Sub-dictionaries are similarly needed for function/method values and method expressions that refer to generic functions/methods.
   * A sub-dictionary entry points to the normal top-level dictionary that is needed to execute the called function/method with the required type arguments, as substituted using the type arguments of the dictionary of the outer function. 
* **Any specific itabs needed for conversion to a specific non-empty interface** from a type param or derived type.  There are currently four main cases where we use dictionary-derived itabs.  In all cases, the itab must come from the dictionary, since it depends on the type arguments of the current function.
   * For all explicit or implicit `OCONVIFACE` calls from a non-interface type to a non-empty interface.  The itab is used to create the destination interface.
   * For all method calls on a type parameter (which must be to a method in the type parameter’s bound).  This method call is implemented as a conversion of the receiver to the type bound interface, and hence is handled similarly to an implicit `OCONVIFACE` call.
   * For all type assertions from a non-empty interface to a non-interface type.  The itab is needed to implement the type assertion.
   * For type switch cases that involve a non-interface type derived from the type params, where the value being switched on has a non-empty interface type.  As with type assertions, the itab is needed to implement the type switch.


We have decided that closures in generic functions/methods that reference generic values/types should use the same dictionary as their containing function/method. Therefore, a dictionary for an instantiated function/method should include all the entries needed for all bodies of the closures it contains as well.


The current implementation may have duplicate subdictionary entries and/or duplicate itab entries. The entries can clearly be deduplicated and shared with a bit more work in the implementation. For some unusual cases, there may also be some unused dictionary entries that could be optimized away.


### Non-monomorphisable Functions

Our choice to compute all dictionaries and sub-dictionaries at compile time does mean that there are some programs that we cannot run. We must have a dictionary for each possible instantiation of a generic function/method with specific concrete types. Because we require all dictionaries to be created statically at compile-time, there must be a finite, known set of types that are used for creating function/method instantiations. Therefore, we cannot handle programs that, via recursion of generic functions/methods, can create an unbounded number of distinct types (typically by repeated nesting of a generic type). A typical example is shown in [issue #48018](https://github.com/golang/go/issues/48018). These types of programs are often called **non-monomorphisable**. If we could create dictionaries (and instantiations of generic types) dynamically at run-time, then we might be able to handle some of these cases of non-monomorphisable code.


## Function and method instantiations


A compile-time instantiation of a generic function or method of a generic type is created for a specific set of gcshape type arguments. As mentioned above, we sometimes call such an instantiation a **shape instantiation**. We determine on-the-fly during compilation which shape instantiations need to be created, as described below in “Compiler processing for calls to generic functions and methods”. Given a set of gcshape type arguments, we create an instantiated function or method by substituting the shape type arguments for the corresponding type parameters throughout the function/method body and header. The function body includes any closures contained in the function.


During the substitution, we also “transform” any relevant nodes. The old typechecker (the `typecheck` package) not only determined the type of every node in a function or declaration, but also did a variety of transformations of the code, usually to a more specific node operation, but also to make explicit nodes for any implicit operations (such as conversions). These transformations often cannot be done until the exact type of the operands are known. So, we delay applying these transformations to generic functions during the noding process. Instead, we apply the transforms while doing the type substitution to create an instantiation. A number of these transformations include adding implicit `OCONVIFACE` nodes. It is important that all `OCONVIFACE` nodes are represented explicitly before determining the dictionary format of the instantiation.


When creating an instantiated function/method, we also automatically add a dictionary parameter “.dict” as the first parameter, preceding even the method receiver.


We have a hash table of shape instantiations that have already been created during this package compilation, so we do not need to create the same instantiation repeatedly. Along with the instantiated function itself, we also save some extra information that is needed for the dictionary pass described below. This includes the format of the dictionary associated with the instantiation and other information that is only accessible from the generic function (such as the bounds of the type params) or is hard to access directly from the instantiation body. We compute this extra information (dictionary format, etc.) as the final step of creating an instantiation.

### Naming of functions, methods, and dictionaries

In the compiler, the naming of generic and instantiated functions and methods is as follows:


* generic function - just the name (with no type parameters), such as Max
* instantiated function - the name with the type argument, such as `Max[int]` or `Max[go.shape.int_0]`.
* generic method - the receiver type with the type parameter that is used in the method definition, and the method name, such as `(*value[T]).Set`.  (As a reminder, a method cannot have any extra type parameters besides the type parameters of its receiver type.)
* instantiated method - the receiver type with the type argument, and the method name, such as `(*value[int]).Set` or `(*value[go.shape.string_0]).Set`.


Currently, because the compiler is using only dictionaries (never pure stenciling), the only function names that typically appear in the executable are the function and methods instantiated by shape types. Some methods instantiated by concrete types can appear if there are required itabs that must include references to these fully-instantiated methods (see the "Itab dictionary wrappers" section just below)


Dictionaries are named similarly to the associated instantiated function or method, but with “.dict” preprended. So, examples include: `.dict.Max[float64]` and `.dict.(*value[int]).get` . A dictionary is always defined for a concrete set of types, so there are never any type params or shape types in a dictionary name.


The concrete type names that are included in instantiated function and method names, as well as dictionary names, are fully-specified (including the package name, if not the builtin package). Therefore, the instantiated function, instantiated method, and dictionary names are uniquely specified. Therefore, they can be generated on demand in any package, as needed, and multiple instances of the same function, method, or dictionary will automatically be de-duplicated by the linker.

### Itab dictionary wrappers

For direct calls of generic functions or methods of generic types, the compiler automatically adds an extra initial argument, which is the required dictionary, when calling the appropriate shape instantiation. That dictionary may be either a reference to a static dictionary (if the concrete types are statically known) or to a sub-dictionary of the containing function’s dictionary. If a function value, method value, or method expression is created, then the compiler will automatically create a closure that calls the appropriate shape instantiation with the correct dictionary when the function or method value or method expression is called. A similar closure wrapper is needed when generating each entry of the itab of a fully-instantiated generic type, since an itab entry must be a function that takes the appropriate receiver and other arguments, but no dictionary.


## Compiler processing for calls to generic functions and methods


Most of the generics-specific processing happens in the front-end of the compiler.
* Types2 typechecker (new) - the types2-typechecker is a new typechecker which can do complete validation and typechecking of generic programs.  It is written to be independent of the rest of the compiler, and passes the typechecking information that it computes to the rest of the compiler in a set of maps.


* Noder pass (pre-existing, but completely rewritten to use the type2 typechecker information) - the noder pass creates the ir.Node representation of all functions/methods in the current package.  We create node representations for both generic and non-generic functions. We use information from the types2-typechecker to set the type of each Node.  Various nodes in generic functions may have types that depend on the type parameters.  For non-generic functions, we do the normal transformations associated with the old typechecker, as mentioned above.  We do not do the transformations for generic functions, since many of the transformations are dependent on concrete type information.


During noding, we record each fully-instantiated non-interface type that already exists in the source code.  For example, any function (generic or non-generic) might happen to specify a variable of type ‘`List[int]`’.  We do the same thing when importing a needed function body (either because it is a generic function that will be instantiated or because it is needed for inlining).


The body of an exportable generic function is always exported, since an exported generic function may be called and hence need to be instantiated in any other package in which it is referenced.  Similarly, the bodies of the methods of an exportable generic type are also always exported, since we need to instantiate these methods whenever the generic type is instantiated.  Unexported generic functions and types may need to be exported if they are referenced by an inlinable function (see `crawler.go`)


* Scan pass (new) - a pass over all non-generic functions and instantiated functions that looks for references to generic functions/methods.  At any such reference, it creates the required shape instantiation (if not yet created during the current compilation) and transforms the reference to use the shape instantiation and pass in the appropriate dictionary.  The scan pass is executed repeatedly over all newly created instantiated functions/methods, until there are no more instantiations that have been created.
   * At the beginning of each iteration of the scan pass, we create all the instantiated methods and dictionaries needed for each fully-instantiated type that has been seen since the last iteration of the scan pass (or from the noder pass, in the case of the first iteration of the scan pass).  This ensures that the required method instantiations will be available when creating runtime type descriptors and itabs, including the itabs needed in dictionaries.
   * For each reference to a generic function/method in a function being scanned, we determine the GC shapes of the type arguments.  If we haven’t already created the needed instantiation with those shape arguments, we create the instantiation by doing a substitution of types on the generic function header and body.  The generic function may be from another package, in which case we need to import its function body.  Once we have created the instantiation, we can then determine the format of the associated dictionary.  We replace the reference to the generic function/method with a call (possibly in a closure) to the required instantiation with the required dictionary argument. If the reference is in a non-generic function, then the required dictionary argument will be a top-level static dictionary.  If the reference is in a shape instantiation, then the dictionary argument will be a sub-dictionary entry from the dictionary of the containing function.  We compute top-level dictionaries (and all their required sub-dictionaries, recursively) on demand as needed using the dictionary format information.
   * As with the noder pass, we record any new fully-instantiated non-interface type that is created.  In the case of the scan pass, this type will be created because of type substitution.  Typically, it will be for dictionary entries for derived types.  If we were doing pure stenciling in some cases, then it would happen analogously when creating the concrete types in a purely stenciled function (no dictionaries).


* Dictionary pass (new) - a pass over all instantiated functions/methods that transforms operations that require a dictionary entry.  These operations include calls to a method of a type parameter’s bound, conversion of a parameterized type to an interface, and type assertions and type switches on a parameterized type.  This pass must be separate (after the scan pass), since we must determine the dictionary format for the instantiation before doing any of these transformations.  The dictionary pass typically transforms these operations to access a specific entry in the dictionary (which is either a runtime type or an itab) and then use that entry in a specific way.


There is an interesting phase ordering problem with respect to inlining. Currently, we try to do all of the processing for generics right after noding, so there is minimal effect on the rest of the compiler. We have mostly succeeded - after the dictionary pass, instantiated functions are treated as normal type-checked code and can be further processed and optimized normally. However, the inlining pass can introduce new code via a newly inlined function, and that new code may reference a variable with a new instantiated type and call methods on that variable or store the variable in an interface. So, we may potentially need to create new instantiations during the inlining pass.


However, we can avoid the phase ordering problem if, when we export the body of an inlineable function that references an instantiated type I, we also export any needed information related to type I. That way, we will have the necessary information during inlining in a new package without fully re-creating the instantiated type I. One approach would be to fully export such a fully-instantiated type I. But that approach is overly complicated and changes the export format in an ugly way. The approach that works out most cleanly (and that we used) is to just export the shape instantiations and dictionaries needed for the methods of I. The type I and the wrappers for the methods of I will be re-created (and de-duped) on the importing side, but there will be no need for any extra instantiation pass (to create shape instantiations or dictionaries), since the needed instantiations and dictionaries will already be available for import.
