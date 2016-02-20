# Proposal: Localization support in Go

Discussion at https://golang.org/issue/12750.

## Abstract
This proposal gives a big-picture overview of localization support for
Go, explaining how all pieces fit together.
It is intended as a guide to designing the individual packages and to allow
catching design issues early.

## Background
Localization can be a complex matter.
For many languages, localization is more than just translating an English format
string.
For example, a sentence may change depending on properties of the arguments such
as gender or plurality.
In turn, the rendering of the arguments may be influenced by, for example:
language, sentence context (start, middle, list item, standalone, etc.),
role within the sentence (case: dative, nominative, genitive, etc.),
formatting options, and
user-specific settings, like measurement system.

In other words, the format string is selected based on the arguments and the
arguments may be rendered differently based on the format string, or even the
position within the format string.

A localization framework should provide at least the following features:

1. mark and extract text in code to be translated,
1. injecting translated text received from a translator, and
1. formatting values, such as numbers, currencies, units, names, etc.

Language-specific parsing of values belongs in this list as well,
but we consider it to be out of scope for now.

### Localization in Go
Although we have drawn some ideas for the design from other localization
libraries, the design will inevitably be different in various aspects for Go.

Most frameworks center around the concept of a single user per machine.
This leads to concepts like default locale, per-locale loadable files, etc.
Go applications tend to be multi-user and single static libraries.

Also many frameworks predate CLDR-provided features such as varying values
based on plural and gender.
Retrofitting frameworks to use this data is hard and often results in clunky APIs.
Designing a framework from scratch allows designing with such features in mind.

### Definitions
We call a **message** the abstract notion of some semantic content to be
conveyed to the user.
Each message is identified by a key, which will often be
a fmt- or template-style format string.
A message definition defines concrete format strings for a message
called **variants**.
A single message will have at least one variant per supported language.

A message may take **arguments** to be substituted at given insertion points.
An argument may have 0 or more features.
An argument **feature** is a key-value pair derived from the value of this argument.
Features are used to select the specific variant for a message for a given
language at runtime.
A **feature value** is the value of an argument feature.
The set of possible feature values for an attribute can vary per language.
A **selector** is a user-provided string to select a variant based on a feature
or argument value.

## Proposal
Most messages in Go programs pass through either the fmt or one of the template
packages.
We treat each of these two types of packages separately.

### Package golang.org/x/text/message
Package message has drop-in replacements for most functions in the fmt package.
Replacing one of the print functions in fmt with the equivalent in package
message flags the string for extraction and causes language-specific rendering.

Consider a traditional use of fmt:

```go
fmt.Printf("%s went to %s.", person, city)
```

To localize this message, replace fmt with a message.Printer for a given language:

```go
p := message.NewPrinter(userLang)
p.Printf("%s went to %s.", person, city)
```

To localize all strings in a certain scope, the user could assign such a printer
to `fmt`.

Using the Printf of `message.Printer` has the following consequences:

* it flags the format string for translation,
* the format string is now a key used for looking up translations (the format
  string is still used as a format string in case of a missing translation),
* localizable types, like numbers are rendered corresponding to p's language.


In practice translations will be automatically injected from
a translator-supplied data source.
But let’s do this manually for now.
The following adds a localized variant for Dutch:

```go
message.Set(language.Dutch, "%s went to %s.",  "%s is in %s geweest.")
```

Assuming p is configured with `language.Dutch`, the Printf above will now print
the message in Dutch.

In practice, translators do not see the code and may need more context than just
the format string.
The user may add context to the message by simply commenting the Go code:

```go
p.Printf("%s went to %s.", // Describes the location a person visited.
	person,                // The Person going to the location.
 	city,                  // The location visited.
)
```

The message extraction tool can pick up these comments and pass them to the
translator.

The section on Features and the Rationale chapter present more details on package
message.

### Package golang.org/x/text/{template|html/template}
Templates can be localized by using the drop-in replacement packages of equal name.
They add the following functionality:

* mark to-be-localized text in templates,
* substitute variants of localized text based on the language, and
* use the localized versions of the print builtins, if applicable.

The `msg` action marks text in templates for localization analogous to the
namesake construct in Soy.

Consider code using core’s text/template:

```go
import "text/template"
import "golang.org/x/text/language"

const letter = `
Dear {{.Name}},
{{if .Attended}}
It was a pleasure to see you at the wedding.{{else}}
It is a shame you couldn't make it to the wedding.{{end}}
Best wishes,
Josie
`
// Prepare some data to insert into the template.
type Recipient struct {
	Name     string
	Attended bool
	Language language.Tag
}
var recipients = []Recipient{
	{"Mildred", true, language.English},
	{"Aurélie", false, language.French},
	{"Rens", false, language.Dutch},
}
func main() {
	// Create a new template and parse the letter into it.
	t := template.Must(template.New("letter").Parse(letter))

	// Execute the template for each recipient.
	for _, r := range recipients {
		if err := t.Execute(os.Stdout, r); err != nil {
			log.Println("executing template:", err)
		}
	}
}
```

To localize this program the user may adopt the program as follows:

```go
import "golang.org/x/text/template"

const letter = `
{{msg "Opening of a letter"}}Dear {{.Name}},{{end}}
{{if .Attended}}
{{msg}}It was a pleasure to see you at the wedding.{{end}}{{else}}
{{msg}}It is a shame you couldn't make it to the wedding.{{end}}{{end}}
{{msg "Closing of a letter, followed by name (f)"}}Best wishes,{{end}}
Josie
`
```

and

```go
func main() {
	// Create a new template and parse the letter into it.
	t := template.Must(template.New("letter").Parse(letter))

	// Execute the template for each recipient.
	for _, r := range recipients {
		if err := t.Language(r.Language).Execute(os.Stdout, r); err != nil {
			log.Println("executing template:", err)
		}
	}
}
```

To make this work, we distinguish between normal and language-specific templates.
A normal template behaves exactly like a template in core, but may be associated
with a set of language-specific templates.

A language-specific template differs from a normal template as follows:
It is associated with exactly one normal template, which we call its base template.

1. A Lookup of an associated template will find the first non-empty result of
   a Lookup on:
	1. the language-specific template itself,
	1. recursively, the result of Lookup on the template for the parent language
	   (as defined by language.Tag.Parent) associated with its base template, or
	1. the base template.
1. Any template obtained from a lookup on a language-specific template will itself
   be a language-specific template for the same language.
   The same lookup algorithm applies for such templates.
1. The builtins print, println, and printf will respectively call the Sprint,
   Sprintln, and Sprintf methods of a message.Printer for the associated language.

A top-level template called `Messages` holds all translations of messages
in language-specific templates. This allows registering of variants using
existing methods defined on templates.


```go
dutch := template.Messages.Language(language.Dutch)
template.Must(dutch.New(`Dear {{.Name}},`).Parse(`Lieve {{.Name}},`))
template.Must(dutch.
	New(`It was a pleasure to see you at the wedding.`).
	Parse(`Het was een genoegen om je op de bruiloft te zien.`))
	    // etc.
```

### Package golang.org/x/text/feature
So far we have addressed cases where messages get translated one-to-one in
different languages.
Translations are often not as simple.
Consider the message `"%[1]s went to %[2]"`, which has the arguments P (a person)
and D (a destination).
This one variant suffices for English.
In French, one needs two:

	gender of P is female: "%[1]s est allée à %[2]s.", and
	gender of P is male:   "%[1]s est allé à %[2]s."

The number of variants needed to properly translate a message can vary
wildly per language.
For example, Arabic has six plural forms.
At worst, the number of variants for a language is equal to the Cartesian product
of all possible values for the argument features for this language.

Package feature defines a mechanism for selecting message variants based on
linguistic features of its arguments.
Both the message and template packages allow selecting variants based on features.
CLDR provides data for plural and gender features.
Likewise-named packages in the text repo provide support for each.


An argument may have multiple features.
For example, a list of persons can have both a count attribute (the number of
people in the list) as well as a gender attribute (the combined gender of the
group of people in the list, the determination of which varies per language).

The feature.Select struct defines a mapping of selectors to variants.
In practice, it is created by a feature-specific, high-level wrapper.
For the above example, such a definition may look like:

```go
message.SetSelect(language.French, "%s went to %s",
	gender.Select(1, // Select on gender of the first argument.
		"female", "%[1]s est allée à %[2]s.",
		"other",  "%[1]s est allé à %[2]s."))
```

The "1" in the Select statement refers to the first argument, which was our person.
The message definition now expects the first argument to support the gender feature.
For example:

```go
type Person struct {
	Name string
	gender.Gender
}
person := Person{ "Joe", gender.Male }
p.Printf("%s went to %s.", person, city)
```

The plural package defines a feature type for plural forms.
An obvious consumer is the numbers package.
But any package that has any kind of amount or cardinality (e.g. lists) can use it.
An example usage:

```go
message.SetSelect(language.English, "There are %d file(s) remaining.",
    plural.Select(1,
		"zero",	 "Done!",
		"one",	 "One file remaining",
		"other", "There are %d files remaining."))
```

This works in English because the CLDR category "zero" and "one" correspond
exclusively to the values 0 and 1.
This is not the case, for example, for Serbian, where "one" is really a category
for a broad range of numbers ending in 1 but not 11.
To deal with such cases, we borrow a notation from ICU to support exact matching:

```go
message.SetSelect(language.English, "There are %d file(s) remaining.",
    plural.Select(1,
		"=0",	 "Done!",
		"=1",	 "One file remaining",
		"other", "There are %d files remaining."))
```

Besides "=", and in addition to ICU, we will also support the "<" and ">" comparators.

The template packages would add a corresponding ParseSelect to add translation variants.

### Value formatting
We now move from localizing messages to localizing values.
This is a non-exhaustive list of value type that support localized rendering:

* numbers
* currencies
* units
* lists
* dates (calendars, formatting with spell-out, intervals)
* time zones
* phone numbers
* postal addresses

Each type maps to a separate package that roughly provides the same types:

* Value: encapsulates a value and implements fmt.Formatter.
For example, currency.Value encapsulates the amount, the currency, and
whether it should be rendered as cash, accounting, etc.
* Formatter: a func of the form func(x interface{}) Value that creates or wraps
a Value to be rendered according to the Formatter's purpose.

Since a Formatter leaves the actual printing to the implementation of
fmt.Formatter, the value is not printed until after it is passed to one of the
print methods.
This allows formatting flags, as well as other context information to influence
the rendering.

The State object passed to Format needs to provide more information than
what is passed by fmt.State, namely:

* a `language.Tag`,
* locale settings that a user may override relative to the user locale setting
  (e.g. preferred time format, measurement system),
* sentence context, such as standalone, start-, mid-, or end-of-sentence, and
* formatting options, possibly defined by the translator.

To accommodate this, we either need to define a text repo-specific State
implementation that Format implementations can type assert to or
define a different Formatter interface.

#### Example: Currencies
We consider this pattern applied to currencies. The Value and Formatter type:

```go
// A Formatter associates formatting information with the given value. x may be a
// Currency, a Value, or a number if the Formatter is associated with a default currency.
type Formatter func(x interface{}) Value

func (f Formatter) NumberFormat(f number.Formatter) Formatter
...

var Default Formatter = Formatter(formISO)
var Symbol Formatter = Formatter(formSymbol)
var SpellOut Formatter = Formatter(formSpellOut)

type Value interface {
	amount interface{}
	currency Currency
	formatter *settings
}

// Format formats v. If State is a format.State, the value is formatted
// according to the given language. If State is not language-specific, it will
// use number plus ISO code for values and the ISO code for Currency.
func (v Value) Format(s fmt.State, verb rune)
func (v Value) Amount() interface{}
func (v Value) Float() (float64, error)
func (v Value) Currency() Currency
...
```

Usage examples:

```go
p := message.NewPrinter(language.AmericanEnglish)
p.Printf("You pay %s.", currency.USD.Value(3))                   // You pay USD 3.
p.Printf("You pay %s.", currency.Symbol(currency.USD.Value(3)))  // You pay $3.
p.Printf("You pay %s.", currency.SpellOut(currency.USD.Value(1)) // You pay 1 US Dollar.
spellout := currency.SpellOut.NumberFormat(number.SpellOut)
p.Printf("You pay %s.", spellout(currency.USD.Value(3)))   // You pay three US Dollars.
```

Formatters have option methods for creating new formatters.
Under the hood all formatter implementations use the same settings type, a
pointer of which is included as a field in Value.
So option methods can access a formatter’s settings by formatting a dummy value.

Different types of currency types are available for different localized rounding
and accounting practices.

```go
v := currency.CHF.Value(3.123)
p.Printf("You pay %s.", currency.Cash.Value(v))  // You pay CHF 3.15.

spellCash := currency.SpellOut.Kind(currency.Cash).NumberFormat(number.SpellOut)
p.Printf("You pay %s.", spellCash(v))   // You pay three point fifteen Swiss Francs.
```

The API ensures unused tables are not linked in.
For example, the rather large tables for spelling out numbers and currencies
needed for number.SpellOut and currency.SpellOut are only linked in when
the respective formatters are called.

#### Example: units
Units are like currencies but have the added complexity that the amount and
unit may change per locale.
The Formatter and Value types are analogous to those of Currency.
It defines "constructors" for a selection of unit types.

```go
type Formatter func(x interface{}) Value
var (
	Symbol Formatter = Formatter(formSymbol)
	SpellOut Formatter = Formatter(formSpellOut)
)
// Unit sets the default unit for the formatter. This allows the formatter to
// create values directly from numbers.
func (f Formatter) Unit(u Unit) Formatter

// create formatted values:
func (f Formatter) Value(x interface{}, u Unit) Value
func (f Formatter) Meters(x interface{}) Value
func (f Formatter) KilometersPerHour(x interface{}) Value
…

type Unit int
const SpeedKilometersPerHour Unit = ...

type Kind int
const Speed Kind = ...
```

Usage examples:

```go
p := message.NewPrinter(language.AmericanEnglish)
p.Printf("%d", unit.KilometersPerHour(250))   // 155 mph
```

spelling out the unit names:

```go
p.Print(unit.SpellOut.KilometersPerHour(250)) // 155.343 miles per hour
```

Associating a default unit with a formatter allows it to format numbers directly:

```go
kmh := unit.SpellOut.Unit(unit.SpeedKilometersPerHour)
p.Print(kmh(250)) // 155.343 miles per hour
```

Spell out the number as well:

```go
spellout := unit.SpellOut.NumberFormat(number.SpellOut)
p.Print(spellout.KilometersPerHour(250))
// one hundred fifty-five point three four three miles per hour
```

or perhaps also

```go
p.Print(unit.SpellOut.KilometersPerHour(number.SpellOut(250)))
// one hundred fifty-five point three four three miles per hour
```

Using a formatter, like `number.SpellOut(250)`, just returns a Value wrapped
with the new formatting settings.
The underlying value is retained, allowing its features to select
the proper unit names.

There may be an ambiguity as to which unit to convert to when converting from
US to the metric system.
For example, feet can be converted to meters or centimeters.
Moreover, which one is to prefer may differ per language.
If this is an issue we may consider allowing overriding the default unit to
convert in a message.
For example:

	%[2:unit=km]f

Such a construct would allow translators to annotate the preferred unit override.


## Details and Rationale

### Formatting

The proposed Go API deviates from a common pattern in other localization APIs by
_not_ associating a Formatter with a language.
Passing the language through State has several advantages:

1. the user needs to specify a language for a message only once, which means
	1. less typing,
	1. no possibility of mismatch, and
	1. no need to initialize a formatter for each language (which may mean on
	   every usage),
1. the value is preserved up till selecting the variant, and
1. a string is not rendered until its context is known.

It prevents strings from being rendered prematurely, which, in turn, helps
picking the proper variant and allows translators to pass in options in
formatting strings.
The Formatter construct is a natural way of allowing for this flexibility and
allows for a straightforward and natural API for something that is otherwise
quite complex.

The Value types of the formatting packages conflate data with formatting.
However, formatting types often are strongly correlated to types.
Combining formatting types with values is not unlike associating the time zone
with a Time or rounding information with a number.
Combined with the fact that localized formatting is one of the main purposes
of the text repo, it seems to make sense.

#### Differences from the fmt package
Formatted printing in the message package differs from the equivalent in the
fmt package in various ways:

* An argument may be used solely for its features, or may be unused for
  specific variants.
  It is therefore possible to have a format string that has no
  substitutions even in the presence of arguments.
* Package message dynamically selects a variant based on the
  arguments’ features and the configured language.
  The format string passed to a formatted print method is mostly used as a
  reference or key.
* The variant selection mechanism allows for the definition of variables
  (see the section on package feature).
  It seems unnatural to refer to these by position.
  We contemplate the usage of named arguments for such variables: `%[name]s`.
* Rendered text is always natural language and values render accordingly.
  For example, `[]int{1, 2, 3}` will be rendered, in English, as `"1, 2 and 3"`,
  instead of  `"[1 2 3]"`.
* Formatters may use information about sentence context.
  Such meta data must be derived by automated analysis or supplied by a
  translator.

Considering the differences with fmt we expect package message to do its own
parsing.
Different substitution points of the same argument may require a different State
object to be passed.
Using fmt’s parser would require rewriting such arguments into different forms
and/or exposing more internals of fmt in the API.
It seems more straightforward for package message to do its own parsing.
Nonetheless, we aim to utilize as much of the fmt package as possible.

#### Currency
Currency is its own package.
In most localization APIs the currency formatter is part of the number formatter.
Currency data is large, though, and putting it in its own package
avoids linking it in unnecessarily.
Separating the currency package also allows greater control over options.
Currencies have specific locale-sensitive rounding and scale settings that
may interact poorly with options provided for a number formatter.

#### Units
We propose to have one large package that includes all unit types.
We could split this package up in,  for example, packages for energy, mass,
length, speed etc.
However, there is a lot of overlap in data (e.g. kilometers and kilometers per hour).
Spreading the tables across packages will make sharing data harder.
Also, not all units belong naturally in a specific package.

To mitigate the impact of including large tables, we can have composable modules
of data from which user can compose smaller formatters
(similar to the display package).


### Features

The proposed mechanism for features takes a somewhat different approach
to OS X and ICU.
It allows mitigating the combinatorial explosion that may occur when combining
features while still being legible.

#### Matching algorithm
The matching algorithm returns the first match on a depth-first search on all cases.
We also allow for variable assignment.
We define the following types (in Go-ey pseudo code):

	Select struct {
		Feature  string  	 // identifier of feature type
		Argument interface{} // Argument reference
		Cases []Case         // The variants.
	}
	Case   struct  { Selector string; Value interface{} }
	Var:    struct { Name string; Value interface{} }
	Value: Select or String
	SelectSequence: [](Select or Var)

To select a variant given a set of arguments:


1. Initialize a map m from argument name to argument value.
1. For each v in s:
	1. If v is of type Var, update m[v.Name] = Eval(v.Value, m)
	1. If v is of type Select, then let v be Eval(v, m).
	1. If v is of type string,  return v.

Eval(v, m): Value

1. If v is a string, return it.
1. Let f be the feature value for feature v.Feature of argument v.Argument.
1. For each case in v.Cases,
	1. return Eval(v) if f.Match(case.Selector, f, v.Argument)
1. Return nil (no match)

Match(s, cat, arg): string x string x interface{} // Implementation for numbers.

1. If s[0] == ‘=’ return int(s[1:]) == arg.
1. If s[0] == ‘<’ return int(s[1:]) < arg.
1. If s[0] == ‘>’ return int(s[1:]) > arg.
1. If  s == cat return true.
1. return s == "other"

A simple data structure encodes the entire Select procedure, which makes it
trivially machine-readable, a condition for including it in a translation pipeline.

#### Full Example

Consider the message `"%[1]s invite %[2] to their party"`, where argument 1 an 2
are lists of respectively hosts and guests, and data:


```go
map[string]interface{}{
	"Hosts": []gender.String{
		gender.Male.String("Andy"),
		gender.Female.String("Sheila"),
	},
	"Guests": []string{ "Andy", "Mary", "Bob", "Linda", "Carl", "Danny" },
}
```


The following variant selector covers various cases for different values of the
arguments.
It limits the number of guests listed to 4.

```go
message.SetSelect(en, "%[1]s invite %[2]s and %[3]d other guests to their party.",
	plural.Select(1, // Hosts
		"=0", `There is no party. Move on!`,
		"=1", plural.Select(2, // Guests
			"=0", `%[1]s does not give a party.`,
			"other", plural.Select(3, // Other guests count
				"=0", gender.Select(1, // Hosts
					"female", "%[1]s invites %[2]s to her party.",
					"other ", "%[1]s invites %[2]s to his party."),
				"=1", gender.Select(1, // Hosts
					"female", "%[1]s invites %#[2]s and one other person to her party.",
					"other ", "%[1]s invites %#[2]s and one other person to his party."),
				"other", gender.Select(1, // Hosts
					"female", "%[1]s invites %#[2]s and %[3]d other people to her party.",
					"other ", "%[1]s invites %#[2]s and %[3]d other people to his party.")),
		"other", plural.Select(2, // Guests,
			"=0 ", "%[1]s do not give a party.",
			"other", plural.Select(3, // Other guests count
				"=0", "%[1]s invite %[2]s to their party.",
				"=1", "%[1]s invite %#[2]s and one other person to their party.",
				"other ", "%[1]s invite %#[2]s and %[3]d other people to their party."))))
```

<!-- ```go
template.Language(language.English).
New("{{.Hosts}} invite {{.Guests}} to their party.").
ParseSelect(plural.Select(".Hosts",
	"=0", `There is no party. Move on!`,
	"=1", plural.Select(".Guests",
		"=0", `{{.Hosts}} does not give a party.`,
		"<5", gender.Select(".Hosts",
			"female", `{{.Hosts}} invites {{.Guests}} to her party.`,
			"other ", `{{.Hosts}} invites {{.Guests}} to his party.`),
		"=5", gender.Select(".Hosts",
			"female", `{{.Hosts}} invites {{first 4 .Guests}} and one other
							person to her party.`,
			"other ", `{{.Hosts}} invites {{first 4 .Guests}} and one other
							person to his party.`),
		"other", gender.Select(".Hosts",
			"female", `{{.Hosts}} invites {{first 4 .Guests}} and {{offset 4 .Guests}}
							other people to her party.`,
			"other ", `{{.Hosts}} invites {{first 4 .Guests}} and {{offset 4 .Guests}}
							other people to his party.`),
				),
		"other", plural.Select(".Guests",
			"=0 ", `{{.Hosts}} do not give a party.`,
			"<5 ", `{{.Hosts}} invite {{.Guests}} to their party.`,
			"=5 ", `{{.Hosts}} invite {{first 4 .Guests}} and one other person
							to their party.`,
			"other ", `{{.Hosts}} invite {{first 4 .Guests}} and
							{{offset 4 .Guests}} other people to their party.`)))
``` -->

For English, we have three variables to deal with:
the plural form of the hosts and guests and the gender of the hosts.
Both guests and hosts are slices.
Slices have a plural feature (its cardinality) and gender (based on CLDR data).
We define the flag `#` as an alternate form for lists to drop the comma.

It should be clear how quickly things can blow up with when dealing with
multiple features.
There are 12 variants.
For other languages this could be quite a bit more.
Using the properties of the matching algorithm one can often mitigate this issue.
With a bit of creativity, we can remove the two cases where `Len(Guests) == 0`
and add another select block at the start of the list:



```go
message.SetSelect(en, "%[1]s invite %[2]s and %[3]d other guests to their party.",
	plural.Select(2, "=0", `There is no party. Move on!`),
	plural.Select(1,
		"=0", `There is no party. Move on!`,
		…
```

<!-- ```go
template.Language(language.English).
	New("{{.Hosts}} invite {{.Guests}} to their party.").
	ParseSelect(
		plural.Select(".Guests", "=0", `There is no party. Move on!`),
		plural.Select(".Hosts",
			"=0", `There is no party. Move on!`,
			…
``` -->

The algorithm will return from the first select when `len(Guests) == 0`,
so this case will not have to be considered later.

Using Var we can do a lot better, though:

```go
message.SetSelect(en, "%[1]s invite %[2]s and %[3]d other guests to their party.",
	feature.Var("noParty", "There is no party. Move on!"),
	plural.Select(1, "=0", "%[noParty]s"),
	plural.Select(2, "=0", "%[noParty]s"),

	feature.Var("their", gender.Select(1, "female", "her", "other ", "his")),
 	// Variables may be overwritten.
	feature.Var("their", plural.Select(1, ">1", "their")),
	feature.Var("invite", plural.Select(1, "=1", "invites", "other ", "invite")),

	feature.Var("guests", plural.Select(3, // other guests
		"=0", "%[2]s",
		"=1", "%#[2]s and one other person",
		"other", "%#[2]s and %[3]d other people"),
	feature.String("%[1]s %[invite]s %[guests]s to %[their]s party."))
```

<!--```go
template.Language(language.English).
    New("{{.Hosts}} invite {{.Guests}} to their party.").
    ParseSelect(
		feature.Var("noParty", "There is no party. Move on!"),
		plural.Select(".Hosts", "=0", `{{$noParty}}`),
		plural.Select(".Guests", "=0", `{{$noParty}}`),

		feature.Var("their", gender.Select(".Hosts",
			"female", "her",
			"other ", "his")),
	 	// Variables may be overwritten.
		feature.Var("their", plural.Select(".Hosts", ">1", "their")),
		feature.Var("invite", plural.Select(".Hosts",
			"=1", "invites",
			"other ", "invite")),

		plural.Select(".Guests",
			"<5", `{{.Hosts}} {{$invite}} {{.Guests}} to {{$their}} party.`,
			"=5", `{{.Hosts}} {{$invite}} {{first 4 .Guests}} and one other person
						to {{$their}} party.`,
			"other", `{{.Hosts}} {{$invite}} {{first 4 .Guests | printf  "%#v"}}
						and {{offset 4 .Guests}} other people to {{$their}} party.`))
```-->


This is essentially the same as the example before, but with the use of
variables to reduce the verbosity.
If one always shows all guests, there would only be one variant for describing
the guests attending a party!

#### Comparison to ICU
ICU has a similar approach to dealing with gender and plurals.
The above example roughly translates to:

```
`{num_hosts, plural,
  =0 {There is no party. Move on!}
  other {
    {gender_of_host, select,
      female {
        {num_guests, plural, offset:1
           =0 {{host} does not give a party.}
           =1 {{host} invites {guest} to her party.}
           =2 {{host} invites {guest} and one other person to her party.}
           other {{host} invites {guest} and # other people to her party.}}}
      male {
         {num_guests, plural, offset:1
            =0 {{host} does not give a party.}
            =1 {{host} invites {guest} to his party.}
            =2 {{host} invites {guest} and one other person to his party.}
            other {{host} invites {guest} and # other people to his party.}}}
      other {
         {num_guests, plural, offset:1
           =0 {{host} do not give a party.}
           =1 {{host} invite {guest} to their party.}
           =2 {{host} invite {guest} and one other person to their party.}
           other {{host} invite {guest} and # other people to their party.}}}}}}`
```

Comparison:

* In Go, features are associated with values, instead of passed separately.
* There is no Var construct in ICU.
* Instead the ICU notation is more flexible and allows for notations like:

	```
	"{1, plural,
		zero {Personne ne se rendit}
		one {{0} est {2, select, female {allée} other {allé}}}
		other {{0} sont {2, select, female {allées} other {allés}}}} à {3}"
	```

* In Go, strings can only be assigned to variables or used in leaf nodes of a
  select. We find this to result in more readable definitions.
* The Go notation is fully expressed in terms of Go structs:
	* There is no separate syntax to learn.
	* Most of the syntax is checked at compile time.
	* It is serializable and machine readable without needing another parser.
* In Go, feature types are fully generic.
* Go has no special syntax for constructs like offset (see the third argument
in ICU’s plural select and the "#" for substituting offsets).
We can solve this with pipelines in templates and special interpretation for
flag and verb types for the Format implementation of lists.
* ICU's algorithm seems to prohibit the user of ‘<’ and ‘>’ selectors.

#### Comparison to OS X

OS X recently introduced support for handling plurals and prepared for support
for gender.
The data for selecting variants is stored in the stringsdict file.
This example from the referenced link shows how to vary sentences for
"number of files selected" in English:

```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>%d files are selected</key>
    <dict>
        <key>NSStringLocalizedFormatKey</key>
        <string>%#@num_files_are@ selected</string>
        <key>num_files_are</key>
        <dict>
            <key>NSStringFormatSpecTypeKey</key>
            <string>NSStringPluralRuleType</string>
            <key>NSStringFormatValueTypeKey</key>
            <string>d</string>
            <key>zero</key>
            <string>No file is</string>
            <key>one</key>
            <string>A file is</string>
            <key>other</key>
            <string>%d files are</string>
        </dict>
    </dict>
</dict>
</plist>
```

The equivalent in the proposed Go format:

```go
message.SetSelect(language.English, "%d files are selected",
	feature.Var("numFilesAre", plural.Select(1,
		"zero",  "No file is",
		"one",   "A file is",
		"other", "%d files are")),
	feature.String("%[numFilesAre]s selected"))
```

A comparison between OS X and the proposed design:

* In both cases, the selection of variants can be represented in a data structure.
* OS X does not have a specific API for defining the variant selection in code.
* Both approaches allow for arbitrary feature implementations.
* OS X allows for a similar construct to Var to allow substitution of substrings.
* OS X has extended its printf-style format specifier to allow for named substitutions.
  The substitution string `"%#@foo@"` will substitute the variable foo.
  The equivalent in Go is the less offensive `"%[foo]v"`.

### Code organization
The typical Go deployment is that of a single statically linked binary.
Traditionally, though, most localization frameworks have grouped data in
per-language dynamically-loaded files.
We suggested some code organization methods for both use cases.

#### Example: statically linked package

In the following code, a single file called messages.go contains all collected
translations:

```go
import "golang.org/x/text/message"
func init() {
	for _, e := range entries{
		for _, t := range e {
			message.SetSelect(e.lang, t.key, t.value)
		}
	}
}
type entry struct {
	key   string
	value feature.Value
}
var entries = []struct{
	lang  language.Tag
	entry []entry
}{
	{ language.French, []entry{
		{ "Hello", feature.String("Bonjour") },
		{ "%s went to %s", feature.Select{ … } },
		…
	},
}

```

#### Example: dynamically loaded files

We suggest storing per-language data files in a messages subdirectory:

```go
func NewPrinter(t language.Tag) *message.Printer {
	r, err := os.Open(filepath.Join("messages", t.String() + ".json"))
	// handle error
	cat := message.NewCatalog()
	d := json.NewDecoder(r)
	for {
		var msg struct{ Key string; Value []feature.Value }
		if err := d.Decode(&msg); err == io.EOF {
			break
		} else if err != nil {
			// handle error
		}
		cat.SetSelect(t, msg.Key, msg.Value...)
	}
	return cat.NewPrinter(t)
}
```

## Compatibility

The implementation of the `msg` action will require some modification to core’s
template/parse package.
Such a change would be backward compatible.

## Implementation Plan

Implementation would start with some of the rudimentary package in the text
repo, most notably format.
Subsequently, this allows the implementation of the formatting of some specific
types, like currencies.
The messages package will be implemented first.
The template package is more invasive and will be implemented at a later stage.
Work on infrastructure for extraction messages from templates and print
statements will allow integrating the tools with translation pipelines.
