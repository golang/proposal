# Proposal: emit DWARF inlining info in the Go compiler

Author(s): Than McIntosh

Last updated: 2017-10-23

Discussion at: https://golang.org/issue/22080

# Abstract

In Go 1.9, the inliner was enhanced to support mid-stack inlining, including
tracking of inlines in the PC-value table to enable accurate tracebacks (see
[proposal](https://golang.org/issue/19348)).
The mid-stack inlining proposal included plans to enhance DWARF generation to
emit inlining records, however the DWARF support has yet to be implemented.
This document outlines a proposal for completing this work.

# Background

This section discusses previous work done on the compiler related to inlining
and related to debug info generation, and outlines the what we want to see in
terms of generated DWARF.

### Source position tracking

As part of the mid-stack inlining work, the Go compiler's source position
tracking was enhanced, giving it the ability to capture the inlined call stack
for an instruction created during an inlining operation.
This additional source position information is then used to create an
inline-aware PC-value table (readable by the runtime) to provide accurate
tracebacks, but is not yet being used to emit DWARF inlining records.

### Lexical scopes

The Go compiler also incorporates support for emitting DWARF lexical scope
records, so as to provide information to the debugger on which instance of a
given variable name is in scope at a given program point.
This feature is currently only operational when the user is compiling with "-l
-N" passed via -gcflags; these options disable inlining and turn off most
optimizations.
The scoping implementation currently relies on disabling the inliner; to enable
scope generation in combination with inlining would require a separate effort.

### Enhanced variable location tracking

There is also work being done to enable more accurate DWARF location lists for
function parameters and local variables.
This better value tracking is currently checked in but not enabled by default,
however the hope is to make this the default behavior for all compilations.

### Compressed source positions, updates during inlining

The compiler currently uses a compressed representation for source position
information.
AST nodes and SSA names incorporate a compact
[`src.XPos`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/internal/src/xpos.go#L11)
object of the form

```
type XPos struct {
	index int32    // index into table of PosBase objects
	lico
}
```

where
[`src.PosBase`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/internal/src/pos.go#L130)
contains source file info and a line base:

```
type PosBase struct {
	pos         Pos
	filename    string // file name used to open source file, for error messages
	absFilename string // absolute file name, for PC-Line tables
	symFilename string // cached symbol file name
	line        uint   // relative line number at pos
	inl         int    // inlining index (see cmd/internal/obj/inl.go)
}
```

In the struct above, `inl` is an index into the global inlining
tree (maintained as a global slice of
[`obj.InlinedCall`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/internal/obj/inl.go#L46)
objects):

```
// InlinedCall is a node in an InlTree.
type InlinedCall struct {
	Parent int      // index of parent in InlTree or -1 if outermost call
	Pos    src.XPos // position of the inlined call
	Func   *LSym    // function that was inlined
}
```

When the inliner replaces a call with the body of an inlinable procedure, it
creates a new `inl.InlinedCall` object based on the call, then a new
`src.PosBase` referring to the InlinedCall's index in the global tree.
It then rewrites/updates the src.XPos objects in the inlined blob to refer to
the new `src.PosBase` (this process is described in more detail in the
[mid-stack inlining design
document](https://golang.org/design/19348-midstack-inlining)).

### Overall existing framework for debug generation

DWARF generation is split between the Go compiler and Go linker; the top-level
driver routine for debug generation is
[`obj.populateDWARF`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/internal/obj/objfile.go#L485).
This routine makes a call back into
[`gc.debuginfo`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/compile/internal/gc/pgen.go#L304)
(via context pointer), which collects information on variables and scopes for a
function, then invokes
[`dwarf.PutFunc`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/internal/dwarf/dwarf.go#L687)
to create what amounts to an abstract version of the DWARF DIE chain for the
function itself and its children (formals, variables, scopes).

The linker starts with the skeleton DIE tree emitted by the compiler, then uses
it as a guide to emit the actual DWARF .debug_info section.
Other DWARF sections (`.debug_line`, `.debug_frame`) are emitted as well
based on non-DWARF-specific data structures (for example, the PCLN table).

### Mechanisms provided by the DWARF standard for representing inlining info

The DWARF specification provides details on how compilers can capture and
encapsulate information about inlining.
See section 3.3.8 of the DWARF V4 standard for a start.

If a routine X winds up being inlined, the information that would ordinarily get
placed into the subprogram DIE is divided into two partitions: the abstract
attributes such as name, type (which will be the same regardless of whether
we're talking about an inlined function body or an out-of-line function body),
and concrete attributes such as the location for a variable, hi/lo PC or PC
ranges for a function body.

The abstract items are placed into an "abstract" subprogram instance, then each
actual instance of a function body is given a "concrete" instance, which refers
back to its parent abstract instance.
This can be seen in more detail in the "how the generated DWARF should look"
section below.

# Example

```
    package s

    func Leaf(lx, ly int) int {
        return (lx << 7) ^ (ly >> uint32(lx&7))
    }

    func Mid(mx, my int) int {
        var mv [10]int
        mv[mx&3] += 2
        return mv[my&3] + Leaf(mx+my, my-mx)
    }

    func Top(tq int) int {
        var tv [10]int
        tr := Leaf(tq-13, tq+13)
        tv[tq&3] = Mid(tq, tq*tq)
        return tr + tq + tv[tr&3]
    }
```

If the code above is compiled with the existing compiler and the resulting DWARF
inspected, there is a single DW_TAG_subprogram DIE for `Top`, with variable DIEs
reflecting params and (selected) locals for that routine.
Two of the stack-allocated locals from the inlined routines (Mid and Leaf)
survive in the DWARF, but other inlined variables do not:

```
  DW_TAG_subprogram {
     DW_AT_name:           s.Top
     ...
     DW_TAG_variable {
       DW_AT_name:         tv
       ...
     }
     DW_TAG_variable {
       DW_AT_name:         mv
       ...
     }
     DW_TAG_formal_parameter {
       DW_AT_name:         tq
       ...
     }
     DW_TAG_formal_parameter {
       DW_AT_name:         ~r1
       ...
     }
```

There are also subprogram DIE's for the out-of-line copies of `Leaf` and `Mid`,
which look similar (variable DIEs for locals and params with stack locations).

When enhanced DWARF location tracking is turned on, in addition to more accurate
variable location expressions within `Top`, there are additional DW_TAG_variable
entries for variable such as "lx" and "ly" corresponding those values within the
inlined body of `Leaf`.
Since these vars are directly parented by `Top` there is no way to disambiguate
the various instances of a var such as "lx".

# How the generated DWARF should look

As mentioned above, emitting DWARF records that capture inlining decisions
involves splitting the subprogram DIE for a given function into two pieces, a
single "abstract instance" (containing location-independent info) and then a set
of "concrete instances", one for each instantiation of the function.

Here is a representation of how the generated DWARF should look for the example
above.
First, the abstract subprogram instance for `Leaf`.
No high/lo PC, no locations, for variables etc (these are provided in concrete
instances):

```
   DW_TAG_subprogram {   // offset: D1
      DW_AT_name:            s.Leaf
      DW_AT_inline : DW_INL_inlined (not declared as inline but inlined)
      ...
      DW_TAG_formal_parameter {   // offset: D2
         DW_AT_name:         lx
         DW_AT_type:         ...
      }
      DW_TAG_formal_parameter {    // offset: D3
         DW_AT_name:         ly
         DW_AT_type:         ...
      }
      ...
   }
```

Next we would expect to see a concrete subprogram instance for `s.Leaf`, corresponding to the out-of-line copy of the function (which may wind up being eliminated by the linker if all calls are inlined).
This DIE refers back to its abstract parent via the DW_AT_abstract_origin
attribute, then fills in location details (such as hi/lo PC, variable locations,
etc):

```
   DW_TAG_subprogram {
      DW_AT_abstract_origin:  // reference to D1 above
      DW_AT_low_pc         : ...
      DW_AT_high_pc        : ...
      ...
      DW_TAG_formal_parameter {
         DW_AT_abstract_origin: // reference to D2 above
         DW_AT_location:        ...
      }
      DW_TAG_formal_parameter {
         DW_AT_abstract_origin: // reference to D3 above
         DW_AT_location:        ...
      }
      ...
   }
```

Similarly for `Mid`, there would be an abstract subprogram instance:

```
   DW_TAG_subprogram {   // offset: D4
      DW_AT_name:            s.Mid
      DW_AT_inline : DW_INL_inlined (not declared as inline but inlined)
      ...
      DW_TAG_formal_parameter {    // offset: D5
         DW_AT_name:         mx
         DW_AT_type:         ...
      }
      DW_TAG_formal_parameter {    // offset: D6
         DW_AT_name:         my
         DW_AT_type:         ...
      }
      DW_TAG_variable {         // offset: D7
         DW_AT_name:         mv
         DW_AT_type:         ...
      }
   }
```

Then a concrete subprogram instance for out-of-line copy of `Mid`.
Note that incorporated into the concrete instance for `Mid` we also see an
inlined instance for `Leaf`.
This DIE (with tag DW_TAG_inlined_subroutine) contains a reference to the
abstract subprogram DIE for `Leaf`, also attributes for the file and line of
the callsite that was inlined:

```
   DW_TAG_subprogram {
      DW_AT_abstract_origin: // reference to D4 above
      DW_AT_low_pc         : ...
      DW_AT_high_pc        : ...
      DW_TAG_formal_parameter {
         DW_AT_abstract_origin: // reference to D5 above
         DW_AT_location:        ...
      }
      DW_TAG_formal_parameter {
         DW_AT_abstract_origin: // reference to D6 above
         DW_AT_location:        ...
      }
      DW_TAG_variable {
         DW_AT_abstract_origin: // reference to D7 above
         DW_AT_location:        ...
      }
      // inlined body of 'Leaf'
      DW_TAG_inlined_subroutine {
         DW_AT_abstract_origin: // reference to D1 above
         DW_AT_call_file: 1
         DW_AT_call_line: 10
         DW_AT_ranges         : ...
         DW_TAG_formal_parameter {
            DW_AT_abstract_origin: // reference to D2 above
            DW_AT_location:        ...
         }
         DW_TAG_formal_parameter {
            DW_AT_abstract_origin: // reference to D3 above
            DW_AT_location:        ...
         }
        ...
      }
   }
```

Finally we would expect to see a subprogram instance for `s.Top`.
Note that since `s.Top` is not inlined, we would have a single subprogram DIE
(as opposed to an abstract instance DIE and a concrete instance DIE):

```
   DW_TAG_subprogram {
      DW_AT_name:            s.Top
      DW_TAG_formal_parameter {
         DW_AT_name:         tq
         DW_AT_type:         ...
      }
      ...
      // inlined body of 'Leaf'
      DW_TAG_inlined_subroutine {
         DW_AT_abstract_origin: // reference to D1 above
         DW_AT_call_file: 1
         DW_AT_call_line: 15
         DW_AT_ranges         : ...
         DW_TAG_formal_parameter {
            DW_AT_abstract_origin: // reference to D2 above
            DW_AT_location:        ...
         }
         DW_TAG_formal_parameter {
            DW_AT_abstract_origin: // reference to D3 above
            DW_AT_location:        ...
         }
         ...
      }
      DW_TAG_variable {
         DW_AT_name:         tr
         DW_AT_type:         ...
      }
      DW_TAG_variable {
         DW_AT_name:      tv
         DW_AT_type:      ...
      }
      // inlined body of 'Mid'
      DW_TAG_inlined_subroutine {
         DW_AT_abstract_origin: // reference to D4 above
         DW_AT_call_file: 1
         DW_AT_call_line: 16
         DW_AT_low_pc         : ...
         DW_AT_high_pc        : ...
         DW_TAG_formal_parameter {
            DW_AT_abstract_origin: // reference to D5 above
            DW_AT_location:        ...
         }
         DW_TAG_formal_parameter {
            DW_AT_abstract_origin: // reference to D6 above
            DW_AT_location:        ...
         }
         DW_TAG_variable {
            DW_AT_abstract_origin: // reference to D7 above
            DW_AT_location:        ...
         }
         // inlined body of 'Leaf'
         DW_TAG_inlined_subroutine {
            DW_AT_abstract_origin: // reference to D1 above
            DW_AT_call_file: 1
            DW_AT_call_line: 10
            DW_AT_ranges         : ...
            DW_TAG_formal_parameter {
               DW_AT_abstract_origin: // reference to D2 above
               DW_AT_location:        ...
            }
            DW_TAG_formal_parameter {
               DW_AT_abstract_origin: // reference to D3 above
               DW_AT_location:        ...
            }
            ...
         }
      }
   }
```

# Outline of proposed changes

### Changes to the inliner

The inliner manufactures new temporaries for each of the inlined functions
formal parameters; it then creates code to assign the correct "actual"
expression to each temp, and finally walks the inlined body to replace formal
references with temp references.
For proper DWARF generation, we need to have a way to associate each of these
temps with the formal from which it was derived.
It should be possible to create such an association by making sure the temp has
the correct src pos (which refers to the callsite) and by giving the temp the
same name as the formal.

### Changes to debug generation

For the abbreviation table
([`dwarf.dwAbbrev`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/internal/dwarf/dwarf.go#L245)
array), we will need to add abstract and concrete versions of the
DW_TAG_subprogram abbrev entry used for functions to the abbrev list.
top

For a given function,
[`dwarf.PutFunc`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/internal/dwarf/dwarf.go#L687)
will need to emit either an ordinary subprogram DIE (if the function was never
inlined) or an abstract subprogram instance followed by a concrete subprogram
instance, corresponding to the out-of-line version of the function.

It probably makes sense to define a new `dwarf.InlinedCall` type; this will be a
struct holding information on the result of an inlined call in a function:

```
type InlinedCall struct {
    Children []*InlinedCall
    InlIndex int // index into ctx.InlTree
}
```

Code can be added (presumably in `gc.debuginfo`) that collects a tree of
`dwarf.InlinedCall` objects corresponding to the functions inlined into the
current function being emitted.
This tree can then be used to drive creation of concrete inline instances as
children of the subprogram DIE of the function being emitted.

There will need to be code written that assigns variables and instructions
(progs/PCs) to specific concrete inlined routine instances, similar to what is
being done currently with scopes in
[`gc.assembleScopes`](https://github.com/golang/go/blob/release-branch.go1.9/src/cmd/compile/internal/gc/scope.go#L29).

One wrinkle in that the existing machinery for creating intra-DWARF references
(attributes with form DW_FORM_ref_addr) assumes that the target of the reference
is a top-level DIE with an associated symbol (type, function, etc).
This assumption no longer holds for DW_AT_abstract_origin references to formal
parameters (where the param is a sub-attribute of a top-level DIE).
Some new mechanism will need to be invented to capture this flavor of reference.

### Changes to the linker

There will probably need to be a few changes to the linker to accommodate
abstract origin references, but for the most part I think the bulk of the work
will be done in the compiler.

# Compatibility

The DWARF constructs proposed here require DWARF version 4, however the compiler
is already emitting DWARF V4 as of 1.9.

# Implementation

Plan is for thanm@ to implement this in go 1.10 timeframe.

# Prerequisite Changes

N/A

# Preliminary Results

No data available yet.
Expectation is that this will increase the load module size due to the
additional DWARF records, but not clear to what degree.

# Open issues

Once lexical scope tracking is enhanced to work for regular (not '-l -N')
compilation, we'll want to integrate inlined instance records with scopes (e.g.
if the topmost callsite in question is nested within a scope, then the top-level
inlined instance DIE should be parented by the appropriate scope DIE).
