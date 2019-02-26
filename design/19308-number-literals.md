# Proposal: Go 2 Number Literal Changes

Russ Cox\
Robert Griesemer

Last updated: March 6, 2019

[golang.org/design/19308-number-literals](https://golang.org/design/19308-number-literals)

Discussion at:

   - [golang.org/issue/19308](https://golang.org/issue/19308) (binary integer literals) 
   - [golang.org/issue/12711](https://golang.org/issue/12711) (octal integer literals) 
   - [golang.org/issue/28493](https://golang.org/issue/28493) (digit separator)
   - [golang.org/issue/29008](https://golang.org/issue/29008) (hexadecimal floating point)

## Abstract

We propose four related changes to number literals in Go:

  1. Add binary integer literals, as in 0b101.
  2. Add alternate octal integer literals, as in 0o377.
  3. Add hexadecimal floating-point literals, as in 0x1p-1021.
  4. Allow _ as a digit separator in number literals.

## Background

Go adopted C’s number literal syntax and in so doing
joined a large group of widely-used languages
that all broadly agree about how numbers are written.
The group of such “C-numbered languages” includes at least
C, C++, C#, Java, JavaScript, Perl, PHP, Python, Ruby, Rust, and Swift. 

In the decade since Go’s initial design,
nearly all the C-numbered languages have extended
their number literals to add one or more of the four changes in this proposal.
Extending Go in the same way makes it easier for developers
to move between these languages, eliminating an unnecessary rough edge
without adding significant complexity to the language.

### Binary Integer Literals

The idea of writing a program’s integer literals in binary is quite old,
dating back at least to 
[PL/I (1964)](http://www.bitsavers.org/pdf/ibm/npl/320-0908_NPL_Technical_Report_Dec64.pdf), which used `'01111000'B`.

In C’s lineage,
[CPL (1966)](http://www.ancientgeek.org.uk/CPL/CPL_Elementary_Programming_Manual.pdf)
supported decimal, binary, and octal integers.
Binary and octal were introduced by an underlined 2 or 8 prefix.
[BCPL (1967)](http://web.eah-jena.de/~kleine/history/languages/Richards-BCPL-ReferenceManual.pdf) removed binary but retained octal,
still introduced by an 8 (it’s unclear whether the 8 was underlined or followed by a space).
[B (1972)](https://www.bell-labs.com/usr/dmr/www/kbman.html)
introduced the leading zero syntax for octal, as in `0377`.
[C as of 1974](http://cm.bell-labs.co/who/dmr/cman74.pdf) had only decimal and octal.
Hexadecimal `0x12ab` had been added by the time
[K&R (1978)](http://www.ccapitalia.net/descarga/docs/1978-ritchie-the-c-programming-language.pdf)
was published.
Possibly the earliest use of the exact `0b01111000` syntax was in
[Caml Light 0.5 (1992)](https://discuss.ocaml.org/t/the-origin-of-the-0b-01-notation/3180/2),
which was written in C and borrowed `0x12ab` for hexadecimal.

Binary integer literals using the `0b01111000` syntax were added in
[C++14 (2014)](http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2012/n3472.pdf),
[C# 7.0 (2017)](https://blogs.msdn.microsoft.com/dotnet/2017/03/09/new-features-in-c-7-0/),
[Java 7 (2011)](https://docs.oracle.com/javase/7/docs/technotes/guides/language/binary-literals.html),
[JavaScript ES6 (2015)](http://www.ecma-international.org/ecma-262/6.0/#sec-literals-numeric-literals),
[Perl 5.005\_55 (1998)](https://perl5.git.perl.org/perl.git/commitdiff/4f19785bce4da39a768aa6210f1f97ab4c0600dd),
[PHP 5.4.0 (2012)](http://php.net/manual/en/language.types.integer.php),
[Python 2.6 (2008)](https://docs.python.org/2.7/whatsnew/2.6.html#pep-3127-integer-literal-support-and-syntax),
[Ruby 1.4.0 (1999)](https://github.com/ruby/ruby/blob/v1_4_0/ChangeLog#L647),
[Rust 0.1 or earlier (2012)](https://github.com/rust-lang/rust/blob/release-0.1/doc/rust.md#integer-literals),
and
[Swift 1.0 or earlier (2014)](https://carlosicaza.com/swiftbooks/SwiftLanguage.pdf).

The syntax is a leading `0b` prefix followed by some number of 0s and 1s.
There is no corresponding character escape sequence
(that is, no `'\b01111000'` for `'x'`, since `'\b'` is already used for backspace, U+0008).
Most languages also updated their integer parsing and formatting routines to support binary forms as well.

Although C++14 added binary integer literals, C itself has not, [as of C18](http://www.open-std.org/jtc1/sc22/wg14/www/abq/c17_updated_proposed_fdis.pdf).

### Octal Integer Literals

As noted earlier, octal was the
most widely-used form for writing bit patterns 
in the early days of computing
(after binary itself).
Even though octal today is far less common,
B’s introduction of `0377` as syntax for octal carried forward into
C, C++, Go, Java, JavaScript, Python, Perl, PHP, and Ruby.
But because programmers don't see octal much,
it sometimes comes as a surprise that
`01234` is not 1234 decimal or that `08` is a syntax error.

[Caml Light 0.5 (1992)](https://discuss.ocaml.org/t/the-origin-of-the-0b-01-notation/3180/2),
mentioned above
as possibly the earliest language with `0b01111000` for binary,
may also have been the first to use the analogous notation `0o377` for octal.

[JavaScript ES3 (1999)](https://www.ecma-international.org/publications/files/ECMA-ST-ARCH/ECMA-262,%203rd%20edition,%20December%201999.pdf)
technically removed support for `0377` as octal,
but of course allowed implementations to continue recognizing them.
[ES5 (2009)](https://www.ecma-international.org/publications/files/ECMA-ST-ARCH/ECMA-262%205th%20edition%20December%202009.pdf)
added “strict mode,” in which, among other restrictions, octal literals are disallowed entirely
(`0377` is an error, not decimal).
[ES6 (2015)](https://www.ecma-international.org/ecma-262/6.0/index.html#sec-literals-numeric-literals)
introduced the `0o377` syntax, allowed even in strict mode.

[Python’s initial release (1991)](https://www.python.org/download/releases/early/)
used `0377` syntax for octal.
[Python 3 (2008)](https://docs.python.org/3.0/reference/lexical_analysis.html#integer-and-long-integer-literals)
changed the syntax to `0o377`,
removing the `0377` syntax (`0377` is an error, not decimal).
[Python 2.7 (2010)](https://docs.python.org/2.7/reference/lexical_analysis.html#integer-and-long-integer-literals)
backported `0o377` as an alternate octal syntax (`0377` is still supported).

[Rust (2012)](https://github.com/rust-lang/rust/blob/release-0.1/doc/rust.md#integer-literals)
initially had no octal syntax but added `0o377` in 
[Rust 0.9 (2014)](https://github.com/rust-lang/rust/blob/0.9/doc/rust.md#integer-literals).
[Swift’s initial release (2014)](https://carlosicaza.com/swiftbooks/SwiftLanguage.pdf) used `0o377` for octal.
Both Rust and Swift allow decimals to have leading zeros (`0377` is decimal 377),
creating a potential point of confusion for programmers coming from
other C-numbered languages.

### Hexadecimal Floating-Point

The exact decimal floating-point literal syntax of C and its successors (`1.23e4`)
appears to have originated at IBM in
[Fortran (1956)](https://archive.computerhistory.org/resources/text/Fortran/102649787.05.01.acc.pdf),
some time after the 
[1954 draft](https://archive.computerhistory.org/resources/text/Fortran/102679231.05.01.acc.pdf).
The syntax was not used in
[Algol 60 (1960)](http://web.eah-jena.de/~kleine/history/languages/Algol60-Naur.pdf)
but was adopted by [PL/I (1964)](http://www.bitsavers.org/pdf/ibm/npl/320-0908_NPL_Technical_Report_Dec64.pdf)
and
[Algol 68 (1968)](http://web.eah-jena.de/~kleine/history/languages/Algol68-Report.pdf),
and it spread from those into many other languages.

Hexadecimal floating-point literals appear to have originated in
[C99 (1999)](http://www.open-std.org/jtc1/sc22/WG14/www/docs/n1256.pdf),
spreading to
[C++17 (2017)](http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2016/p0245r0.html),
[Java 5 (2004)](http://psc.informatik.uni-jena.de/languages/Java/javaspec-3.pdf)
[Perl 5.22 (2015)](https://perldoc.perl.org/perl5220delta.html#Floating-point-parsing-has-been-improved),
and
[Swift's initial release (2014)](https://carlosicaza.com/swiftbooks/SwiftLanguage.pdf).
[IEEE 754-2008](http://www.dsc.ufcg.edu.br/~cnum/modulos/Modulo2/IEEE754_2008.pdf)
also added hexadecimal floating-point literals, citing C99.

All these languages use the syntax `0x123.fffp5`,
where the “`pN`” specifies a decimal number interpreted as a power of two:
`0x123.fffp5` is (0x123 + 0xfff/0x1000) x 2^5.
In all languages, the exponent is required: `0x123.fff` is not a valid hexadecimal floating-point literal.

The fraction may be omitted, as in `0x1p-1000`.
C, C++, Java, Perl, and the IEEE 754-2008 standard
allow omitting the digits before or after the hexadecimal point:
`0x1.p0` and `0x.fp0` are valid hexadecimal floating-point literals
just as `1.` and `.9` are valid decimal literals.
Swift requires digits on both sides of a decimal or hexadecimal point;
that is, in Swift, `0x1.p0`, `0x.fp0`, `1.`, and `.9` are all invalid.

Adding hexadecimal floating-point literals also requires adding library support.
C99 added the `%a` and `%A` `printf` formats for formatting and `%a` for scanning.
It also redefined `strtod` to accept hexadecimal floating-point values.
The other languages made similar changes.

C# (as of C# 7.3, which has [no published language specification](https://github.com/dotnet/csharplang/issues/64)),
JavaScript (as of [ES8](https://www.ecma-international.org/ecma-262/8.0/index.html#sec-literals-numeric-literals)),
PHP (as of [PHP 7.3.0](http://php.net/manual/en/language.types.float.php)),
Python (as of [Python 3.7.2](https://docs.python.org/3/reference/lexical_analysis.html#floating-point-literals)),
Ruby (as of [Ruby 2.6.0](https://docs.ruby-lang.org/en/2.6.0/syntax/literals_rdoc.html#label-Numbers)),
and
Rust (as of [Rust 1.31.1](https://doc.rust-lang.org/stable/reference/tokens.html#floating-point-literals))
do not support hexadecimal floating-point literals.

### Digit Separators

Allowing the use of an underscore to separate digits in a number literal into groups dates back at least to
[Ada 83](http://archive.adaic.com/standards/83rat/html/ratl-02-01.html#2.1), possibly earlier.

A digit-separating underscore was added to
[C# 7.0 (2017)](https://blogs.msdn.microsoft.com/dotnet/2017/03/09/new-features-in-c-7-0/),
[Java 7 (2011)](https://docs.oracle.com/javase/7/docs/technotes/guides/language/underscores-literals.html),
[Perl 2.0 (1988)](https://perl5.git.perl.org/perl.git/blob/378cc40b38293ffc7298c6a7ed3cd740ad79be52:/toke.c#l1021),
[Python 3.6 (2016)](https://www.python.org/dev/peps/pep-0515/),
[Ruby 1.0 or earlier (1998)](https://github.com/ruby/ruby/blob/v1_0/parse.y#L2282),
[Rust 0.1 or earlier (2012)](https://github.com/rust-lang/rust/blob/release-0.1/doc/rust.md#integer-literals),
and
[Swift 1.0 or earlier (2014)](https://carlosicaza.com/swiftbooks/SwiftLanguage.pdf).

C has not yet added digit separators as of C18.
C++14 uses
[single-quote as a digit separator](http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2013/n3781.pdf)
to avoid an ambiguity with C++11 user-defined integer suffixes
that might begin with underscore.
JavaScript is
[considering adding underscore as a digit separator](https://github.com/tc39/proposal-numeric-separator)
but ran into a similar problem with user-defined suffixes.
PHP [considered but decided against](https://wiki.php.net/rfc/number_format_separator) adding digit separators.

The design space for a digit separator feature reduces to four questions:
(1) whether to accept a separator immediately after the single-digit octal `0` base prefix, as in `0_1`;
(2) whether to accept a separator immediately after non-digit base prefixes like `0b`, `0o`, and `0x`, as in `0x_1`;
(3) whether to accept multiple separators in a row, as in `1__2`; and
(4) whether to accept trailing separators, as in `1_`.
(Note that a “leading separator” would create a variable name, as in _1.)
These four questions produce sixteen possible approaches.

Case 0b0001:
If the name “digit separator” is understood literally,
so that each underscore must separate (appear between) digits,
then the answers should be that `0_1` is allowed but `0x_1`, `1__2`, and `1_` are all disallowed.
This is the approach taken by
[Ada 83](http://archive.adaic.com/standards/83lrm/html/lrm-02-04.html#2.4)
(using `8#123#` for octal and so avoiding question 1),
[C++14](http://eel.is/c++draft/lex.icon),
[Java 7](https://docs.oracle.com/javase/7/docs/technotes/guides/language/underscores-literals.html),
and 
[Swift](https://docs.swift.org/swift-book/ReferenceManual/LexicalStructure.html#ID415)
(using only `0o` for octal and thereby also avoiding question 1).

Case 0b0011: 
If we harmonize the treatment of the `0` octal base prefix
with the `0b`, `0o`, and `0x` base prefixes by allowing a digit separator
between a base prefix and leading digit,
then the answers are that `0_1` and `0x_1` are allowed but `1__2` and `1_` are disallowed.
This is the approach taken in
[Python 3.6](https://www.python.org/dev/peps/pep-0515/#literal-grammar) and
[Ruby 1.8.0](https://github.com/ruby/ruby/blob/v1_8_0/parse.y#L3723).

Case 0b0111:
If we allow runs of multiple separators as well, that allows `0_1`, `0x_1`,
and `1__2`, but not `1_`.
This is the approach taken in
[C# 7.2](https://github.com/dotnet/csharplang/blob/master/proposals/csharp-7.2/leading-separator.md)
and
[Ruby 1.6.2](https://github.com/ruby/ruby/blob/v1_6_2/parse.y#L2779).

Case 0b1111:
If we then also accept trailing digit separators,
the implementation becomes trivial: ignore digit separators wherever they appear.
[Perl](https://perl5.git.perl.org/perl.git/blob/378cc40b38293ffc7298c6a7ed3cd740ad79be52:/toke.c#l1021)
takes this approach,
as does [Rust](https://swift.godbolt.org/z/1f72LH).

Other combinations have been tried:
[C# 7.0](https://github.com/dotnet/csharplang/blob/master/proposals/csharp-7.0/digit-separators.md)
used 0b0101 (`0x_1` and `1_` disallowed)
before moving to case 0b1110 in
[C# 7.2](https://github.com/dotnet/csharplang/blob/master/proposals/csharp-7.2/leading-separator.md).
[Ruby 1.0](https://github.com/ruby/ruby/blob/v1_0/parse.y#L2282)
used 0b1110 (only `0_1` disallowed)
and
[Ruby 1.3.1](https://github.com/ruby/ruby/blob/v1_3_1_/parse.y#L2779)
used 0b1101 (only `0x_1` disallowed),
before Ruby 1.6.2 tried 0b0111 and Ruby 1.8.0 settled on 0b0011.

A similar question arises for whether to allow underscore between
a decimal point and a decimal digit in a floating-point number,
or between the literal `e` and the exponent.
We won’t enumerate the cases here, but again languages
make surprising choices.
For example, in Rust, `1_.2` is valid but `1._2` is not.

## Proposal

We propose to add binary integer literals,
to add octal `0o377` as an alternate octal literal syntax,
to add hexadecimal floating-point literals,
and to add underscore as a base-prefix-or-digit separator
(case 0b0011 above; see rationale below),
along with appropriate library support.
Finally, to fit the existing imaginary literals seemlessly
into the new number literals, we propose that the imaginary
suffix `i` may be used on any (non-imaginary) number literal.

### Language Changes

The definitions in https://golang.org/ref/spec#Letters_and_digits add:

>     binary_digit = "0" | "1" .

The https://golang.org/ref/spec#Integer_literals section would be amended to read:


> An integer literal is a sequence of digits representing an integer constant. 
> An optional prefix sets a non-decimal base:
> 0, 0o, or 0O for octal, 0b or 0B for binary, 0x or 0X for hexadecimal.
> A single 0 is considered a decimal zero.
> In hexadecimal literals, letters a-f and A-F represent values 10 through 15.
> For readability, an underscore may appear after a base prefix or
> between successive digits; such underscores do not change the literal value.
>
>     int_lit        = decimal_lit | binary_lit | octal_lit | hex_lit .
>     decimal_lit    = "0" | ( "1" … "9" ) [ [ "_" ] decimal_digits ] .
>     binary_lit     = "0" ( "b" | "B" ) [ "_" ] binary_digits .
>     octal_lit      = "0" [ "o" | "O" ] [ "_" ] octal_digits .
>     hex_lit        = "0" ( "x" | "X" ) [ "_" ] hex_digits .
>     
>     decimal_digits = decimal_digit { [ "_" ] decimal_digit } .
>     binary_digits  = binary_digit { [ "_" ] binary_digit } .
>     octal_digits   = octal_digit { [ "_" ] octal_digit } .
>     hex_digits     = hex_digit { [ "_" ] hex_digit } .
>
>     42
>     4_2
>     0600
>     0_600
>     0o600
>     0O600       // second character is capital letter 'O'
>     0xBadFace
>     0xBad_Face
>     0x_67_7a_2f_cc_40_c6
>     170141183460469231731687303715884105727
>     170_141183_460469_231731_687303_715884_105727
>     
>     _42         // an identifier, not an integer literal
>     42_         // invalid: _ must separate successive digits
>     4__2        // invalid: only one _ at a time
>     0_xBadFace  // invalid: _ must separate successive digits

The https://golang.org/ref/spec#Floating-point_literals section would be amended to read:


> A floating-point literal is a decimal or hexadecimal representation 
> of a floating-point constant.
> A decimal floating-point literal consists of
> an integer part (decimal digits),
> a decimal point,
> a fractional part (decimal digits)
> and an exponent part (e or E followed by an optional sign and decimal digits).
> One of the integer part or the fractional part may be elided;
> one of the decimal point or the exponent part may be elided.
> A hexadecimal floating-point literal consists of
> a 0x or 0X prefix,
> an integer part (hexadecimal digits),
> a decimal point,
> a fractional part (hexadecimal digits),
> and an exponent part (p or P followed by an optional sign and decimal digits).
> One of the integer part or the fractional part may be elided;
> the decimal point may be elided as well, but the exponent part is required.
> (This syntax matches the one given in
> [IEEE 754-2008](https://doi.org/10.1109/IEEESTD.2008.4610935) §5.12.3.)
> For readability, an underscore may appear after a base prefix or
> between successive digits; such underscores do not change the literal value.
>
>
>     float_lit         = decimal_float_lit | hex_float_lit .
>     
>     decimal_float_lit = decimal_digits "." [ decimal_digits ] [ decimal_exponent ] |
>                         decimal_digits decimal_exponent |
>                         "." decimal_digits [ decimal_exponent ] .
>     decimal_exponent  = ( "e" | "E" ) [ "+" | "-" ] decimal_digits .
>     
>     hex_float_lit     = "0" ( "x" | "X" ) hex_mantissa hex_exponent .
>     hex_mantissa      = [ "_" ] hex_digits "." [ hex_digits ] |
>                         [ "_" ] hex_digits |
>                         "." hex_digits .
>     hex_exponent      = ( "p" | "P" ) [ "+" | "-" ] decimal_digits .
>
>
>     0.
>     72.40
>     072.40       // == 72.40
>     2.71828
>     1.e+0
>     6.67428e-11
>     1E6
>     .25
>     .12345E+5
>     1_5.         // == 15.0
>     0.15e+0_2    // == 15.0
>     
>     0x1p-2       // == 0.25
>     0x2.p10      // == 2048.0
>     0x1.Fp+0     // == 1.9375
>     0X.8p-0      // == 0.5
>     0X_1FFFP-16  // == 0.1249847412109375
>     0x15e-2      // == 0x15e - 2 (integer subtraction)
>     
>     0x.p1        // invalid: mantissa has no digits
>     1p-2         // invalid: p exponent requires hexadecimal mantissa
>     0x1.5e-2     // invalid: hexadecimal mantissa requires p exponent
>     1_.5         // invalid: _ must separate successive digits
>     1._5         // invalid: _ must separate successive digits
>     1.5_e1       // invalid: _ must separate successive digits
>     1.5e_1       // invalid: _ must separate successive digits
>     1.5e1_       // invalid: _ must separate successive digits


The syntax in https://golang.org/ref/spec#Imaginary_literals section would be amended to read:


> An imaginary literal represents the imaginary part of a complex constant.
> It consists of an integer or floating-point literal followed by the lower-case
> letter i.
> The value of an imaginary literal is the value of the respective
> integer or floating-point literal multiplied by the imaginary unit i.
> 
>     imaginary_lit = (decimal_digits | int_lit | float_lit) "i" .
> 
> For backward-compatibility, an imaginary literal's integer part consisting
> entirely of decimal digits (and possibly underscores) is considered a decimal
> integer, not octal, even if it starts with a leading 0.
> 
>     0i
>     0123i         // == 123i for backward-compatibility
>     0o123i        // == 0o123 * 1i == 83i
>     0xabci        // == 0xabc * 1i == 2748i
>     0.i
>     2.71828i
>     1.e+0i
>     6.67428e-11i
>     1E6i
>     .25i
>     .12345E+5i
>     0x1p-2i       // == 0x1p-2 * 1i == 0.25i

### Library Changes

In [`fmt`](https://golang.org/pkg/fmt/),
[`Printf`](https://golang.org/pkg/fmt/#Printf) with `%#b`
will format an integer argument in binary with a leading `0b` prefix.
Today, [`%b` already formats an integer in binary](https://play.golang.org/p/3MPBPo2sZu9)
with no prefix;
[`%#b` does the same](https://play.golang.org/p/wwPshrf3oae)
but is rejected by `go` `vet`, including during `go` `test`,
so redefining `%#b` will not break vetted, tested programs.

`Printf` with `%#o` is already defined to format an
integer argument in octal with a leading `0` (not `0o`) prefix,
and all the other available format flags have defined effects too.
It appears no change is possible here.
Clients can use `0o%o`, at least for non-negative arguments.

`Printf` with `%x`
will format a floating-point argument in hexadecimal floating-point syntax.
(Today, `%x` on a floating-point argument formats as a `%!x` error 
and also provokes a vet error.)
[`Scanf`](https://golang.org/pkg/fmt/#Scanf) will accept
both decimal and hexadecimal floating-point forms
where it currently accepts decimal.

In [`go/scanner`](https://golang.org/pkg/go/scanner/),
the implementation must change to understand the
new syntax, but the public API needs no changes.
Because [`text/scanner`](https://golang.org/pkg/text/scanner/)
recognizes Go’s number syntax as well,
it will be updated to add the new numbers too.

In [`math/big`](https://golang.org/pkg/math/big/),
[`Int.SetString`](https://golang.org/pkg/math/big/#Int.SetString)
with `base` set to zero accepts binary integer literals already;
it will change to recognize the new octal prefix and the underscore digit separator.
[`ParseFloat`](https://golang.org/pkg/math/big/#ParseParse) and
[`Float.Parse`](https://golang.org/pkg/math/big/#Float.Parse) with `base` set to zero,
[`Float.SetString`](https://golang.org/pkg/math/big/#Float.SetString),
and [`Rat.SetString`](https://golang.org/pkg/math/big/#Rat.SetString) each
accept binary integer literals and hexadecimal floating-point literals already;
they will change to recognize the new octal prefix and the underscore digit separator.
Calls using non-zero bases will continue to reject inputs with underscores.

In [`strconv`](https://golang.org/pkg/strconv/),
[`ParseInt`](https://golang.org/pkg/strconv/#ParseInt)
and
[`ParseUint`](https://golang.org/pkg/strconv/#ParseUint)
will change behavior.
When the `base` argument is zero,
they will recognize binary literals like `0b0111`
and also allow underscore as a digit separator.
Calls using non-zero bases will continue to reject inputs with underscores.
[`ParseFloat`](https://golang.org/pkg/strconv/#ParseFloat)
will change to accept hexadecimal floating-point literals and
the underscore digit separator.
[`FormatFloat`](https://golang.org/pkg/strconv/#FormatFloat)
will add a new format `x` to generate hexadecimal floating-point.

In [`text/template/parse`](https://golang.org/pkg/text/template/parse),
`(*lex).scanNumber` will need to recognize the three new syntaxes.
This will provide the new literals to both
[`html/template`](https://golang.org/pkg/html/template/)
and
[`text/template`](https://golang.org/pkg/html/template/).

### Tool Changes

Gofmt will understand the new syntax once
[`go/scanner`](https://golang.org/pkg/go/scanner/)
is updated.
For legibility, 
gofmt will also rewrite capitalized base prefixes `0B`, `0O`, and `0X`
and exponent prefixes `E` and `P`
to their lowercase equivalents `0b`, `0o`, `0x`, `e`, and `p`.
This is especially important for `0O377` vs `0o377`.

To avoid introducing incompatibilities into 
otherwise backward-compatible code,
gofmt will not rewrite `0377` to `0o377`.
(Perhaps in a few years we will be able to consider doing that.)

## Rationale

As discussed in the background section,
the choices being made in this proposal
match those already made in Go's broader language family.
Making these same changes to Go is useful on its own
and avoids unnecessary lexical differences with the
other languages.
This is the primary rationale for all four changes.

### Octal Literals

We considered using `0o377` in the initial design of Go,
but we decided that even if Go used `0o377`
for octal, it would have to reject `0377` as invalid syntax
(that is, Go could not accept `0377` as decimal 377),
to avoid an unpleasant surprise for programmers coming
from C, C++, Java, Python 2, Perl, PHP, Ruby, and so on.
Given that `0377` cannot be decimal,
it seemed at the time unnecessary
and gratuitously different to avoid it for octal.
It still seemed that way in 2015, when the issue
was raised as [golang.org/issue/12711](https://golang.org/issue/12711).

Today, however, it seems clear that there is agreement
among at least the newer C-numbered languages
for `0o377` as octal (either alone or in addition to `0377`).
Harmonizing Go’s octal integer syntax with these languages
makes sense for the same reasons as harmonizing
the binary integer and hexadecimal floating-point syntax.

For backwards compatibility,
we must keep the existing `0377` syntax in Go 1,
so Go will have two octal integer syntaxes,
like Python 2.7 and non-strict JavaScript.
As noted earlier, 
after a few years, once there are no supported Go releases
missing the `0o377` syntax,
we could consider changing
`gofmt` to at least reformat `0377` to `0o377` for clarity.

### Arbitrary Bases

Another obvious change is to consider
arbitrary-radix numbers, like Algol 68’s `2r101`.
Perhaps the form most in keeping with Go’s history
would be to allow `BxDIGITS` where `B` is the base,
as in `2x0101`, `8x377`, and `16x12ab`,
where `0x` becomes an alias for `16x`.
We considered this in the initial design of Go,
but it seemed gratuitously
different from the common C-numbered languages,
and it would still not let us interpret `0377` as decimal.
It also seemed that very few programs would be
aided by being able to write numbers in, say,
base 3 or base 36.
That logic still holds today,
reinforced by the weight of existing Go usage.
Better to add only the syntaxes that other languages use.
For discussion, see [golang.org/issue/28256](https://golang.org/issue/28256).

### Library Changes

In the library changes, the various number parsers
are changed to accept underscores only in the base-detecting case.
For example:

    strconv.ParseInt("12_34",   0, 0)   // decimal with underscores
    strconv.ParseInt("0b11_00", 0, 0)   // binary with underscores
    strconv.ParseInt("012_34",  0, 0)   // 01234 (octal)
    strconv.ParseInt("0o12_34", 0, 0)   // 0o1234 (octal)
    strconv.ParseInt("0x12_34", 0, 0)   // 0x1234 (hexadecimal)
 
    strconv.ParseInt("12_34",  10, 0)   // error: fixed base cannot use underscores
    strconv.ParseInt("11_00",   2, 0)   // error: fixed base cannot use underscores
    strconv.ParseInt("12_34",   8, 0)   // error: fixed base cannot use underscores
    strconv.ParseInt("12_34",  16, 0)   // error: fixed base cannot use underscores

Note that the fixed-base case also rejects base prefixes (and always has):

    strconv.ParseInt("0b1100",  2, 0)   // error: fixed base cannot use base prefix
    strconv.ParseInt("0o1100",  8, 0)   // error: fixed base cannot use base prefix
    strconv.ParseInt("0x1234", 16, 0)   // error: fixed base cannot use base prefix

The rationale for rejecting underscores when the base is known
is the same as the rationale for rejecting base prefixes:
the caller is likely to be parsing a substring of a larger
input and would not appreciate the “flexibility.”
For example, parsing hex bytes two digits at a time
might use `strconv.ParseInt(input[i:i+2], 16, 8)`,
and parsers for various text formats
use `strconv.ParseInt(field, 10, 64)` 
to parse a plain decimal number.
These use cases should not be required to guard
against underscores in the inputs themselves.

On the other hand,
uses of `strconv.ParseInt` and `strconv.ParseUint` with `base` argument zero
already accept decimal, octal `0377`, and hexadecimal literals,
so they will start accepting the new binary and octal literals
and digit-separating underscores.
For example, command line flags defined with `flag.Int` will start
accepting these inputs.
Similarly, uses of `strconv.ParseFloat`, like `flag.Float64`
or the conversion of string-typed database entries to `float64` 
in [`database/sql`](https://golang.org/pkg/database/sql/),
will start accepting hexadecimal floating-point literals
and digit-separating underscores.

### Digit Separators

The main bike shed to paint is the detail about
where exactly digit separators are allowed.
Following discussion on [golang.org/issue/19308](https://golang.org/issue/19308),
and matching the latest versions of Python and Ruby,
this proposal adopts the rule
that each digit separator must separate
a digit from the base prefix or another digit:
`0_1`, `0x_1`, and `1_2` are all allowed, while `1__2` and `1_` are not.

## Compatibility

The syntaxes being introduced here were all previously invalid,
either syntactically or semantically.
For an example of the latter,
`0x1.fffp-2` parses in current versions of Go
as the value `0x1`’s `fffp` field minus two.
Of course, integers have no fields, so while this program
is syntactically valid, it is still semantically invalid.

The changes to numeric parsing functions like
`strconv.ParseInt` and `strconv.ParseFloat`
mean that programs that might have failed before
on inputs like `0x1.fffp-2` or `1_2_3` will now succeed.
Some users may be surprised.
Part of the rationale with limiting the changes
to calls using `base` zero is to limit the potential surprise
to those cases that already accepted multiple syntaxes.

## Implementation

The implementation requires:

  - Language specification changes, detailed above.
  - Library changes, detailed above.
  - Compiler changes, in gofrontend and cmd/compile/internal/syntax.
  - Testing of compiler changes, library changes, and gofmt.

Robert Griesemer and Russ Cox plan to split the work
and aim to have all the changes ready at the start of the Go 1.13 cycle,
around February 1.

As noted in our blog post
[“Go 2, here we come!”](https://blog.golang.org/go2-here-we-come),
the development cycle will serve as a way to collect experience about
these new features and feedback from (very) early adopters.

At the release freeze, May 1, we will revisit the proposed features
and decide whether to include them in Go 1.13.

