# Proposal: Structured Logging

Author: Jonathan Amsterdam

Date: 2022-10-19

Issue: https://go.dev/issue/56345

Discussion: https://github.com/golang/go/discussions/54763

Preliminary implementation: https://go.googlesource.com/exp/+/refs/heads/master/slog

Package documentation: https://pkg.go.dev/golang.org/x/exp/slog

We propose adding structured logging with levels to the standard library, to
reside in a new package with import path `log/slog`.

Structured logging is the ability to output logs with machine-readable
structure, typically key-value pairs, in addition to a human-readable message.
Structured logs can be parsed, filtered, searched and analyzed faster and more
reliably than logs designed only for people to read.
For many programs that aren't run directly by a user, like servers, logging is
the main way for developers to observe the detailed behavior of the system, and
often the first place they go to debug it.
Logs therefore tend to be voluminous, and the ability to search and filter them
quickly is essential.

In theory, one can produce structured logs with any logging package:
```
log.Printf(`{"message": %q, "count": %d}`, msg, count)
```
In practice, this is too tedious and error-prone, so structured logging packages
provide an API for expressing key-value pairs.
This proposal contains such an API.

We also propose generalizing the logging "backend."
The `log` package provides control only over the `io.Writer` that logs are
written to.
In the new package, every logger has a handler that can process a log event
however it wishes.
Although it is possible to have a structured logger with a fixed backend (for
instance, [zerolog] outputs only JSON), having a flexible backend provides
several benefits: programs can display the logs in a variety of formats, convert
them to an RPC message for a network logging service, store them for later
processing, and add to or modify the data.

Lastly, the design incorporates levels in a way that accommodates both
traditional named levels and [logr]-style verbosities.

The goals of this design are:

- Ease of use.
  A survey of the existing logging packages shows that programmers
  want an API that is light on the page and easy to understand.
  This proposal adopts the most popular way to express key-value pairs:
  alternating keys and values.

- High performance.
  The API has been designed to minimize allocation and locking.
  It provides an alternative to alternating keys and values that is
  more cumbersome but faster (similar to [Zap]'s `Field`s).

- Integration with runtime tracing.
  The Go team is developing an improved runtime tracing system.
  Logs from this package will be incorporated seamlessly
  into those traces, giving developers the ability to correlate their program's
  actions with the behavior of the runtime.

## What does success look like?

Go has many popular structured logging packages, all good at what they do.
We do not expect developers to rewrite their existing third-party structured
logging code to use this new package.
We expect existing logging packages to coexist with this one for the foreseeable
future.

We have tried to provide an API that is pleasant enough that users will prefer it to existing
packages in new code, if only to avoid a dependency.
(Some developers may find the runtime tracing integration compelling.)
We also expect newcomers to Go to encounter this package before
learning third-party packages, so they will likely be most familiar with it.

But more important than any traction gained by the "frontend" is the promise of
a common "backend."
An application with many dependencies may find that it has linked in many
logging packages.
When all the logging packages support the standard handler interface proposed here,
then the application can create a single handler and install it once
for each logging library to get consistent logging across all its dependencies.
Since this happens in the application's main function, the benefits of a unified
backend can be obtained with minimal code churn.
We expect that this proposal's handlers will be implemented for all popular logging
formats and network protocols, and that every common logging framework will
provide a shim from their own backend to a handler.
Then the Go logging community can work together to build high-quality backends
that all can share.

## Prior Work

The existing `log` package has been in the standard library since the release of
Go 1 in March 2012. It provides formatted logging, but not structured logging or
levels.

[Logrus](https://github.com/Sirupsen/logrus), one of the first structured
logging packages, showed how an API could add structure while preserving the
formatted printing of the `log` package. It uses maps to hold key-value pairs,
which is relatively inefficient.

[Zap] grew out of Uber's frustration with the slow log times of their
high-performance servers. It showed how a logger that avoided allocations could
be very fast.

[Zerolog] reduced allocations even further, but at the cost of reducing the
flexibility of the logging backend.

All the above loggers include named levels along with key-value pairs. [Logr]
and Google's own [glog] use integer verbosities instead of named levels,
providing a more fine-grained approach to filtering high-detail logs.

Other popular logging packages are Go-kit's
[log](https://pkg.go.dev/github.com/go-kit/log), HashiCorp's [hclog], and
[klog](https://github.com/kubernetes/klog).

## Design

### Overview

Here is a short program that uses some of the new API:

```
import "log/slog"

func main() {
    slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr)))
    slog.Info("hello", "name", "Al")
    slog.Error("oops", "err", net.ErrClosed, "status", 500)
    slog.LogAttrs(slog.LevelError, "oops",
        slog.Any("err", net.ErrClosed), slog.Int("status", 500))
}
```

This program generates the following output on standard error:

```
time=2022-10-24T16:05:48.054-04:00 level=INFO msg=hello name=Al
time=2022-10-24T16:05:48.054-04:00 level=ERROR err="use of closed network connection" msg=oops status=500
time=2022-10-24T16:05:48.054-04:00 level=ERROR err="use of closed network connection" msg=oops status=500
```

It begins by setting the default logger to one that writes log records in an
easy-to-read format similar to [logfmt].
(There is also a built-in handler for JSON.)

If the `slog.SetDefault` line is omitted,
the output is sent to the standard log package,
producing mostly structured output:

```
2022/10/24 16:07:00 INFO hello name=Al
2022/10/24 16:07:00 ERROR oops err="use of closed network connection" status=500
2022/10/24 16:07:00 ERROR oops  err="use of closed network connection" status=500
```

The program outputs three log messages augmented with key-value pairs.
The first logs at the Info level, passing a single key-value pair along with the
message.
The second logs at the Error level, passing two key-value pairs.

The third produces the same output as the second, but more efficiently.
Functions like `Any` and `Int` construct `slog.Attr` values, which are key-value
pairs that avoid memory allocation for most values.

### Main Types

The `slog` package contains three main types:

- `Logger` is the frontend, providing output methods like `Info` and `LogAttrs` that
  developers call to produce logs.

- Each call to a `Logger` output method creates a `Record`.

- The `Record` is passed to a `Handler` for output.

We cover these bottom-up, beginning with `Handler`.

### Handlers

A `Handler` describes the logging backend.
It handles log records produced by a `Logger`.

A typical handler may print log records to standard error, or write them to
a file, database or network service, or perhaps augment them with additional attributes and
pass them on to another handler.

```
type Handler interface {
	// Enabled reports whether the handler handles records at the given level.
	// The handler ignores records whose level is lower.
	// It is called early, before any arguments are processed,
	// to save effort if the log event should be discarded.
	// The Logger's context is passed so Enabled can use its values
	// to make a decision. The context may be nil.
	Enabled(context.Context, Level) bool

	// Handle handles the Record.
	// It will only be called if Enabled returns true.
	//
	// The first argument is the context of the Logger that created the Record,
	// which may be nil.
	// It is present solely to provide Handlers access to the context's values.
	// Canceling the context should not affect record processing.
	// (Among other things, log messages may be necessary to debug a
	// cancellation-related problem.)
	//
	// Handle methods that produce output should observe the following rules:
	//   - If r.Time is the zero time, ignore the time.
	//   - If an Attr's key is the empty string and the value is not a group,
	//     ignore the Attr.
	//   - If a group's key is empty, inline the group's Attrs.
	//   - If a group has no Attrs (even if it has a non-empty key),
	//     ignore it.
	Handle(ctx context.Context, r Record) error

	// WithAttrs returns a new Handler whose attributes consist of
	// both the receiver's attributes and the arguments.
	// The Handler owns the slice: it may retain, modify or discard it.
	WithAttrs(attrs []Attr) Handler

	// WithGroup returns a new Handler with the given group appended to
	// the receiver's existing groups.
	// The keys of all subsequent attributes, whether added by With or in a
	// Record, should be qualified by the sequence of group names.
	//
	// How this qualification happens is up to the Handler, so long as
	// this Handler's attribute keys differ from those of another Handler
	// with a different sequence of group names.
	//
	// A Handler should treat WithGroup as starting a Group of Attrs that ends
	// at the end of the log event. That is,
	//
	//     logger.WithGroup("s").LogAttrs(level, msg, slog.Int("a", 1), slog.Int("b", 2))
	//
	// should behave like
	//
	//     logger.LogAttrs(level, msg, slog.Group("s", slog.Int("a", 1), slog.Int("b", 2)))
	//
	// If the name is empty, WithGroup returns the receiver.
	WithGroup(name string) Handler
}
```

The `slog` package provides two handlers, one for simple textual output and one
for JSON. They are described in more detail below.

### The `Record` Type

A Record holds information about a log event.

```
type Record struct {
	// The time at which the output method (Log, Info, etc.) was called.
	Time time.Time

	// The log message.
	Message string

	// The level of the event.
	Level Level

	// The program counter at the time the record was constructed, as determined
	// by runtime.Callers. If zero, no program counter is available.
	//
	// The only valid use for this value is as an argument to
	// [runtime.CallersFrames]. In particular, it must not be passed to
	// [runtime.FuncForPC].
	PC uintptr

	// Has unexported fields.
}
```

Records have two methods for accessing the sequence of `Attr`s. This API allows
an efficient implementation of the `Attr` sequence that avoids copying and
minimizes allocation.

```
func (r Record) Attrs(f func(Attr))
    Attrs calls f on each Attr in the Record.

func (r Record) NumAttrs() int
    NumAttrs returns the number of attributes in the Record.
```

So that other logging backends can wrap `Handler`s, it is possible to construct
a `Record` directly and add attributes to it:

```
func NewRecord(t time.Time, level Level, msg string, pc uintptr) Record
    NewRecord creates a Record from the given arguments. Use Record.AddAttrs to
    add attributes to the Record.

    NewRecord is intended for logging APIs that want to support a Handler as a
    backend.

func (r *Record) AddAttrs(attrs ...Attr)
    AddAttrs appends the given Attrs to the Record's list of Attrs. It resolves
    the Attrs before doing so.

func (r *Record) Add(args ...any)
    Add converts the args to Attrs as described in Logger.Log, then appends the
    Attrs to the Record's list of Attrs. It resolves the Attrs before doing so.
```

Copies of a `Record` share state. A `Record` should not be modified after
handing out a copy to it. Use `Clone` for that:

```
func (r Record) Clone() Record
    Clone returns a copy of the record with no shared state. The original record
    and the clone can both be modified without interfering with each other.
```

### The `Attr` and `Value` Types

An `Attr` is a key-value pair.

```
type Attr struct {
	Key   string
	Value Value
}
```

There are convenience functions for constructing `Attr`s with various value
types, as well as `Equal` and `String` methods.

```
func Any(key string, value any) Attr
    Any returns an Attr for the supplied value. See Value.AnyValue for how
    values are treated.

func Bool(key string, v bool) Attr
    Bool returns an Attr for a bool.

func Duration(key string, v time.Duration) Attr
    Duration returns an Attr for a time.Duration.

func Float64(key string, v float64) Attr
    Float64 returns an Attr for a floating-point number.

func Group(key string, as ...Attr) Attr
    Group returns an Attr for a Group Value. The caller must not subsequently
    mutate the argument slice.

    Use Group to collect several Attrs under a single key on a log line, or as
    the result of LogValue in order to log a single value as multiple Attrs.

func Int(key string, value int) Attr
    Int converts an int to an int64 and returns an Attr with that value.

func Int64(key string, value int64) Attr
    Int64 returns an Attr for an int64.

func String(key, value string) Attr
    String returns an Attr for a string value.

func Time(key string, v time.Time) Attr
    Time returns an Attr for a time.Time. It discards the monotonic portion.

func Uint64(key string, v uint64) Attr
    Uint64 returns an Attr for a uint64.

func (a Attr) Equal(b Attr) bool
    Equal reports whether a and b have equal keys and values.

func (a Attr) String() string
```

A `Value` can represent any Go value, but unlike type `any`, it can represent
most small values without an allocation.
In particular, integer types and strings, which account for the vast
majority of values in log messages, do not require allocation.
The default version of `Value` uses package `unsafe` to store any value in three
machine words.
The version without `unsafe` requires five.

There are constructor functions for common types, and a general one,
`AnyValue`, that dispatches on its argument type.

```
type Value struct {
	// Has unexported fields.
}

func AnyValue(v any) Value
    AnyValue returns a Value for the supplied value.

    Given a value of one of Go's predeclared string, bool, or (non-complex)
    numeric types, AnyValue returns a Value of kind String, Bool, Uint64, Int64,
    or Float64. The width of the original numeric type is not preserved.

    Given a time.Time or time.Duration value, AnyValue returns a Value of kind
    TimeKind or DurationKind. The monotonic time is not preserved.

    For nil, or values of all other types, including named types whose
    underlying type is numeric, AnyValue returns a value of kind AnyKind.

func BoolValue(v bool) Value
    BoolValue returns a Value for a bool.

func DurationValue(v time.Duration) Value
    DurationValue returns a Value for a time.Duration.

func Float64Value(v float64) Value
    Float64Value returns a Value for a floating-point number.

func GroupValue(as ...Attr) Value
    GroupValue returns a new Value for a list of Attrs. The caller must not
    subsequently mutate the argument slice.

func Int64Value(v int64) Value
    Int64Value returns a Value for an int64.

func IntValue(v int) Value
    IntValue returns a Value for an int.

func StringValue(value string) Value
    String returns a new Value for a string.

func TimeValue(v time.Time) Value
    TimeValue returns a Value for a time.Time. It discards the monotonic
    portion.

func Uint64Value(v uint64) Value
    Uint64Value returns a Value for a uint64.
```

Extracting Go values from a `Value` is reminiscent of `reflect.Value`: there is
a `Kind` method that returns an enum of type `Kind`, and a method for each `Kind`
that returns the value or panics if it is the wrong kind.

```
type Kind int
    Kind is the kind of a Value.

const (
	AnyKind Kind = iota
	BoolKind
	DurationKind
	Float64Kind
	Int64Kind
	StringKind
	TimeKind
	Uint64Kind
	GroupKind
	LogValuerKind
)

func (v Value) Any() any
    Any returns v's value as an any.

func (v Value) Bool() bool
    Bool returns v's value as a bool. It panics if v is not a bool.

func (a Value) Duration() time.Duration
    Duration returns v's value as a time.Duration. It panics if v is not a
    time.Duration.

func (v Value) Equal(w Value) bool
    Equal reports whether v and w have equal keys and values.

func (v Value) Float64() float64
    Float64 returns v's value as a float64. It panics if v is not a float64.

func (v Value) Group() []Attr
    Group returns v's value as a []Attr. It panics if v's Kind is not GroupKind.

func (v Value) Int64() int64
    Int64 returns v's value as an int64. It panics if v is not a signed integer.

func (v Value) Kind() Kind
    Kind returns v's Kind.

func (v Value) LogValuer() LogValuer
    LogValuer returns v's value as a LogValuer. It panics if v is not a
    LogValuer.

func (v Value) Resolve() Value
    Resolve repeatedly calls LogValue on v while it implements LogValuer, and
    returns the result. If the number of LogValue calls exceeds a threshold, a
    Value containing an error is returned. Resolve's return value is guaranteed
    not to be of Kind LogValuerKind.

func (v Value) String() string
    String returns Value's value as a string, formatted like fmt.Sprint.
    Unlike the methods Int64, Float64, and so on, which panic if v is of the
    wrong kind, String never panics.

func (v Value) Time() time.Time
    Time returns v's value as a time.Time. It panics if v is not a time.Time.

func (v Value) Uint64() uint64
    Uint64 returns v's value as a uint64. It panics if v is not an unsigned
    integer.
```

#### The LogValuer interface

A LogValuer is any Go value that can convert itself into a Value for
logging.

This mechanism may be used to defer expensive operations until they are
needed, or to expand a single value into a sequence of components.

```
type LogValuer interface {
	LogValue() Value
}
```


`Value.Resolve` can be used to call the `LogValue` method.

```
func (v Value) Resolve() Value
    Resolve repeatedly calls LogValue on v while it implements LogValuer, and
    returns the result. If the number of LogValue calls exceeds a threshold, a
    Value containing an error is returned. Resolve's return value is guaranteed
    not to be of Kind LogValuerKind.
```

The Attrs passed to a `Handler.WithAttrs`, and the Attrs obtained
via `Record.Attrs`, have already been resolved, that is, replaced
with a call to `Resolve`.

As an example of `LogValuer`, a type could obscure its value in log output like
so:

```
type Password string

func (p Password) LogValue() slog.Value {
    return slog.StringValue("REDACTED")
}
```

### Loggers

A Logger records structured information about each call to its Log, Debug,
Info, Warn, and Error methods. For each call, it creates a `Record` and passes
it to a `Handler`.
```
type Logger struct {
	// Has unexported fields.
}
```

A `Logger` consists of a `Handler`. Use `New` to create `Logger` with a
`Handler`, and the `Handler` method to retrieve it.

```
func New(h Handler) *Logger
    New creates a new Logger with the given Handler.

func (l *Logger) Handler() Handler
    Handler returns l's Handler.
```

There is a single, global default `Logger`.
It can be set and retrieved with the `SetDefault` and
`Default` functions.

```
func SetDefault(l *Logger)
    SetDefault makes l the default Logger. After this call, output from the
    log package's default Logger (as with log.Print, etc.) will be logged at
    LevelInfo using l's Handler.

func Default() *Logger
    Default returns the default Logger.
```

The `slog` package works to ensure consistent output with the `log` package.
Writing to `slog`'s default logger without setting a handler will write
structured text to `log`'s default logger.
Once a handler is set with `SetDefault`, as in the example above, the default
`log` logger will send its text output to the structured handler.

#### Output methods

`Logger`'s output methods produce log output by constructing a `Record` and
passing it to the `Logger`'s handler.
There are two output methods for each of four most common levels, one which
takes a context and one which doesn't. There is also a `Log` method
that takes any level, and a `LogAttrs` method that accepts only `Attr`s as an
optimization, both of which take a context.

These methods first call `Handler.Enabled` to see if they should proceed.

Each of these methods has a corresponding top-level function that uses the
default logger.

The context is passed to Handler.Enabled and Handler.Handle. Handlers sometimes
need to retrieve values from a context, tracing spans being a prime example.

We will provide a vet check for the methods that take a list of `any` arguments
to catch problems with missing keys or values.


```
func (l *Logger) Log(ctx context.Context, level Level, msg string, args ...any)
    Log emits a log record with the current time and the given level and
    message. The Record's Attrs consist of the Logger's attributes followed by
    the Attrs specified by args.

    The attribute arguments are processed as follows:
      - If an argument is an Attr, it is used as is.
      - If an argument is a string and this is not the last argument, the
        following argument is treated as the value and the two are combined into
        an Attr.
      - Otherwise, the argument is treated as a value with key "!BADKEY".

func (l *Logger) LogAttrs(ctx context.Context, level Level, msg string, attrs ...Attr)
    LogAttrs is a more efficient version of Logger.Log that accepts only Attrs.

func (l *Logger) Debug(msg string, args ...any)
    Debug logs at LevelDebug.

func (l *Logger) Info(msg string, args ...any)
    Info logs at LevelInfo.

func (l *Logger) Warn(msg string, args ...any)
    Warn logs at LevelWarn.

func (l *Logger) Error(msg string, args ...any)
    Error logs at LevelError.

func (l *Logger) DebugCtx(ctx context.Context, msg string, args ...any)
    DebugCtx logs at LevelDebug with the given context.

func (l *Logger) InfoCtx(ctx context.Context, msg string, args ...any)
    InfoCtx logs at LevelInfo with the given context.

func (l *Logger) WarnCtx(ctx context.Context, msg string, args ...any)
    WarnCtx logs at LevelWarn with the given context.

func (l *Logger) ErrorCtx(ctx context.Context, msg string, args ...any)
    ErrorCtx logs at LevelError with the given context.
```

Loggers can have attributes as well, added by the `With` method.

```
func (l *Logger) With(args ...any) *Logger
    With returns a new Logger that includes the given arguments, converted to
    Attrs as in Logger.Log. The Attrs will be added to each output from the
    Logger.

    The new Logger's handler is the result of calling WithAttrs on the
    receiver's handler.
```

### Groups

Although most attribute values are simple types like strings and integers,
sometimes aggregate or composite values are desired.
For example, consider

```
type Name struct {
    First, Last string
}
```

To handle values like this we include `GroupKind` for groups of Attrs.
To log a `Name` `n` as a group, we could write

```
slog.Info("message",
    slog.Group("name",
        slog.String("first", n.First),
        slog.String("last", n.Last),
    ),
)
```

Handlers should qualify a group's members by its name.
What "qualify" means depends on the handler.
A handler that supports recursive data, like the
built-in `JSONHandler`, can use the group name as a key to a nested object:

```
"name": {"first": "Ren", "last": "Hoek"}
```

Handlers that use a flat output representation, like the built-in `TextHandler`,
could prefix the group member's keys with the group name.
This is `TextHandler`'s output:

```
name.first=Ren name.last=Hoek
```

If the author of the `Name` type wanted to arrange matters so that `Name`s
always logged in this way, they could implement the `LogValuer` interface discussed
[above](#the-logvaluer-interface):

```
func (n Name) LogValue() slog.Value {
    return slog.GroupValue(
        slog.String("first", n.First),
        slog.String("last", n.Last),
    )
}
```

Now, if `n` is a `Name`, the log line

```
slog.Info("message", "name", n)
```

will render exactly like the example with an explicit `slog.Group` above.

#### Logger groups

Sometimes it is useful to qualify all the attribute keys from a Logger.
For example, an application may be composed of multiple subsystems, some of
which may use the same attribute keys.
Qualifying each subsystem's keys is one way to avoid duplicates.
This can be done with `Logger.WithGroup`.
Duplicate keys can be avoided by handing each subsystem a `Logger` with a
different group.


```
func (l *Logger) WithGroup(name string) *Logger
    WithGroup returns a new Logger that starts a group. The keys of all
    attributes added to the Logger will be qualified by the given name.
```

### Levels

A Level is the importance or severity of a log event. The higher the level,
the more important or severe the event.

```
type Level int
```

The `slog` package provides names for common levels.

The level numbers below don't really matter too much. Any system can map
them to another numbering scheme if it wishes. We picked them to satisfy
three constraints.

First, we wanted the default level to be Info. Since Levels are ints,
Info is the default value for int, zero.

Second, we wanted to make it easy to work with verbosities instead of levels.
As discussed above,
some logging packages like [glog] and [Logr] use verbosities instead, where
a verbosity of 0 corresponds to the Info level and higher values represent less
important messages.
Negating a verbosity converts it into a Level. To use a verbosity of `v` with
this design, pass `-v` to `Log` or `LogAttrs`.

Third, we wanted some room between levels to accommodate schemes with
named levels between ours. For example, Google Cloud Logging defines a
Notice level between Info and Warn. Since there are only a few of these
intermediate levels, the gap between the numbers need not be large.
Our gap of 4 matches OpenTelemetry's mapping. Subtracting 9 from an
OpenTelemetry level in the DEBUG, INFO, WARN and ERROR ranges converts it to
the corresponding slog Level range. OpenTelemetry also has the names TRACE
and FATAL, which slog does not. But those OpenTelemetry levels can still be
represented as slog Levels by using the appropriate integers.

```
const (
	LevelDebug Level = -4
	LevelInfo  Level = 0
	LevelWarn  Level = 4
	LevelError Level = 8
)
```

The `Leveler` interface generalizes `Level`, so that a `Handler.Enabled`
implementation can vary its behavior. One way to get dynamic behavior
is to use `LevelVar`.

```
type Leveler interface {
	Level() Level
}
    A Leveler provides a Level value.

    As Level itself implements Leveler, clients typically supply a Level value
    wherever a Leveler is needed, such as in HandlerOptions. Clients who need to
    vary the level dynamically can provide a more complex Leveler implementation
    such as *LevelVar.

func (l Level) Level() Level
    Level returns the receiver. It implements Leveler.

type LevelVar struct {
	// Has unexported fields.
}
    A LevelVar is a Level variable, to allow a Handler level to change
    dynamically. It implements Leveler as well as a Set method, and it is safe
    for use by multiple goroutines. The zero LevelVar corresponds to LevelInfo.

func (v *LevelVar) Level() Level
    Level returns v's level.

func (v *LevelVar) Set(l Level)
    Set sets v's level to l.

func (v *LevelVar) String() string
```

### Provided Handlers

The `slog` package includes two handlers, which behave similarly except for
their output format. `TextHandler` emits attributes as `KEY=VALUE`, and
`JSONHandler` writes line-delimited JSON objects.
Both can be configured using a `HandlerOptions`.
A zero `HandlerOptions` consists entirely of default values.

```
type HandlerOptions struct {
	// When AddSource is true, the handler adds a ("source", "file:line")
	// attribute to the output indicating the source code position of the log
	// statement. AddSource is false by default to skip the cost of computing
	// this information.
	AddSource bool

	// Level reports the minimum record level that will be logged.
	// The handler discards records with lower levels.
	// If Level is nil, the handler assumes LevelInfo.
	// The handler calls Level.Level for each record processed;
	// to adjust the minimum level dynamically, use a LevelVar.
	Level Leveler

	// ReplaceAttr is called to rewrite each non-group attribute before it is logged.
	// The attribute's value has been resolved (see [Value.Resolve]).
	// If ReplaceAttr returns an Attr with Key == "", the attribute is discarded.
	//
	// The built-in attributes with keys "time", "level", "source", and "msg"
	// are passed to this function, except that time is omitted
	// if zero, and source is omitted if AddSource is false.
	//
	// The first argument is a list of currently open groups that contain the
	// Attr. It must not be retained or modified. ReplaceAttr is never called
	// for Group attributes, only their contents. For example, the attribute
	// list
	//
	//     Int("a", 1), Group("g", Int("b", 2)), Int("c", 3)
	//
	// results in consecutive calls to ReplaceAttr with the following arguments:
	//
	//     nil, Int("a", 1)
	//     []string{"g"}, Int("b", 2)
	//     nil, Int("c", 3)
	//
	// ReplaceAttr can be used to change the default keys of the built-in
	// attributes, convert types (for example, to replace a `time.Time` with the
	// integer seconds since the Unix epoch), sanitize personal information, or
	// remove attributes from the output.
	ReplaceAttr func(groups []string, a Attr) Attr
}
```

## Interoperating with Other Log Packages

As stated earlier, we expect that this package will interoperate with other log
packages.

One way that could happen is for another package's frontend to send
`slog.Record`s to a `slog.Handler`.
For instance, a `logr.LogSink` implementation could construct a `Record` from a
message and list of keys and values, and pass it to a `Handler`.
That is facilitated by `NewRecord`, `Record.Add` and `Record.AddAttrs`,
described above.

Another way for two log packages to work together is for the other package to
wrap its backend as a `slog.Handler`, so users could write code with the `slog`
package's API but connect the results to an existing `logr.LogSink`, for
example.
This involves writing a `slog.Handler` that wraps the other logger's backend.
Doing so doesn't seem to require any additional support from this package.

## Testing Package

To verify that a Handler's behavior matches the specification, we propose
a package testing/slogtest with one exported function:

```
// TestHandler tests a [slog.Handler].
// If TestHandler finds any misbehaviors, it returns an error for each,
// combined into a single error with errors.Join.
//
// TestHandler installs the given Handler in a [slog.Logger] and
// makes several calls to the Logger's output methods.
//
// The results function is invoked after all such calls.
// It should return a slice of map[string]any, one for each call to a Logger output method.
// The keys and values of the map should correspond to the keys and values of the Handler's
// output. Each group in the output should be represented as its own nested map[string]any.
//
// If the Handler outputs JSON, then calling [encoding/json.Unmarshal] with a `map[string]any`
// will create the right data structure.
func TestHandler(h slog.Handler, results func() []map[string]any) error
```

## Acknowledgements

Ian Cottrell's ideas about high-performance observability, captured in the
`golang.org/x/exp/event` package, informed a great deal of the design and
implementation of this proposal.

Seth Vargo’s ideas on logging were a source of motivation and inspiration. His
comments on an earlier draft helped improve the proposal.

Michael Knyszek explained how logging could work with runtime tracing.

Tim Hockin helped us understand logr's design choices, which led to significant
improvements.

Abhinav Gupta helped me understand Zap in depth, which informed the design.

Russ Cox provided valuable feedback and helped shape the final design.

Alan Donovan's CL reviews greatly improved the implementation.

The participants in the [GitHub
discussion](https://github.com/golang/go/discussions/54763) helped us confirm we
were on the right track, and called our attention to important features we had
overlooked (and have since added).

[zerolog]: https://pkg.go.dev/github.com/rs/zerolog
[Zerolog]: https://pkg.go.dev/github.com/rs/zerolog
[logfmt]: https://pkg.go.dev/github.com/kr/logfmt
[zap]: https://pkg.go.dev/go.uber.org/zap
[logr]: https://pkg.go.dev/github.com/go-logr/logr
[Logr]: https://pkg.go.dev/github.com/go-logr/logr
[hclog]: https://pkg.go.dev/github.com/hashicorp/go-hclog
[glog]: https://pkg.go.dev/github.com/golang/glog

## Appendix: API

```
package slog

Package slog provides structured logging, in which log records include a
message, a severity level, and various other attributes expressed as key-value
pairs.

It defines a type, Logger, which provides several methods (such as Logger.Info
and Logger.Error) for reporting events of interest.

Each Logger is associated with a Handler. A Logger output method creates a
Record from the method arguments and passes it to the Handler, which decides how
to handle it. There is a default Logger accessible through top-level functions
(such as Info and Error) that call the corresponding Logger methods.

A log record consists of a time, a level, a message, and a set of key-value
pairs, where the keys are strings and the values may be of any type. As an
example,

    slog.Info("hello", "count", 3)

creates a record containing the time of the call, a level of Info, the message
"hello", and a single pair with key "count" and value 3.

The Info top-level function calls the Logger.Info method on the default Logger.
In addition to Logger.Info, there are methods for Debug, Warn and Error levels.
Besides these convenience methods for common levels, there is also a Logger.Log
method which takes the level as an argument. Each of these methods has a
corresponding top-level function that uses the default logger.

The default handler formats the log record's message, time, level, and
attributes as a string and passes it to the log package.

    2022/11/08 15:28:26 INFO hello count=3

For more control over the output format, create a logger with a different
handler. This statement uses New to create a new logger with a TextHandler that
writes structured records in text form to standard error:

    logger := slog.New(slog.NewTextHandler(os.Stderr))

TextHandler output is a sequence of key=value pairs, easily and unambiguously
parsed by machine. This statement:

    logger.Info("hello", "count", 3)

produces this output:

    time=2022-11-08T15:28:26.000-05:00 level=INFO msg=hello count=3

The package also provides JSONHandler, whose output is line-delimited JSON:

    logger := slog.New(slog.NewJSONHandler(os.Stdout))
    logger.Info("hello", "count", 3)

produces this output:

    {"time":"2022-11-08T15:28:26.000000000-05:00","level":"INFO","msg":"hello","count":3}

Both TextHandler and JSONHandler can be configured with a HandlerOptions.
There are options for setting the minimum level (see Levels, below), displaying
the source file and line of the log call, and modifying attributes before they
are logged.

Setting a logger as the default with

    slog.SetDefault(logger)

will cause the top-level functions like Info to use it. SetDefault also updates
the default logger used by the log package, so that existing applications that
use log.Printf and related functions will send log records to the logger's
handler without needing to be rewritten.

# Attrs and Values

An Attr is a key-value pair. The Logger output methods accept Attrs as well as
alternating keys and values. The statement

    slog.Info("hello", slog.Int("count", 3))

behaves the same as

    slog.Info("hello", "count", 3)

There are convenience constructors for Attr such as Int, String, and Bool for
common types, as well as the function Any for constructing Attrs of any type.

The value part of an Attr is a type called Value. Like an [any], a Value can
hold any Go value, but it can represent typical values, including all numbers
and strings, without an allocation.

For the most efficient log output, use Logger.LogAttrs. It is similar to
Logger.Log but accepts only Attrs, not alternating keys and values; this allows
it, too, to avoid allocation.

The call

    logger.LogAttrs(nil, slog.LevelInfo, "hello", slog.Int("count", 3))

is the most efficient way to achieve the same output as

    slog.Info("hello", "count", 3)

Some attributes are common to many log calls. For example, you may wish to
include the URL or trace identifier of a server request with all log events
arising from the request. Rather than repeat the attribute with every log call,
you can use Logger.With to construct a new Logger containing the attributes:

    logger2 := logger.With("url", r.URL)

The arguments to With are the same key-value pairs used in Logger.Info.
The result is a new Logger with the same handler as the original, but additional
attributes that will appear in the output of every call.

# Levels

A Level is an integer representing the importance or severity of a log event.
The higher the level, the more severe the event. This package defines constants
for the most common levels, but any int can be used as a level.

In an application, you may wish to log messages only at a certain level or
greater. One common configuration is to log messages at Info or higher levels,
suppressing debug logging until it is needed. The built-in handlers can be
configured with the minimum level to output by setting [HandlerOptions.Level].
The program's `main` function typically does this. The default value is
LevelInfo.

Setting the [HandlerOptions.Level] field to a Level value fixes the handler's
minimum level throughout its lifetime. Setting it to a LevelVar allows the level
to be varied dynamically. A LevelVar holds a Level and is safe to read or write
from multiple goroutines. To vary the level dynamically for an entire program,
first initialize a global LevelVar:

    var programLevel = new(slog.LevelVar) // Info by default

Then use the LevelVar to construct a handler, and make it the default:

    h := slog.HandlerOptions{Level: programLevel}.NewJSONHandler(os.Stderr)
    slog.SetDefault(slog.New(h))

Now the program can change its logging level with a single statement:

    programLevel.Set(slog.LevelDebug)

# Groups

Attributes can be collected into groups. A group has a name that is used to
qualify the names of its attributes. How this qualification is displayed depends
on the handler. TextHandler separates the group and attribute names with a dot.
JSONHandler treats each group as a separate JSON object, with the group name as
the key.

Use Group to create a Group Attr from a name and a list of Attrs:

    slog.Group("request",
        slog.String("method", r.Method),
        slog.Any("url", r.URL))

TextHandler would display this group as

    request.method=GET request.url=http://example.com

JSONHandler would display it as

    "request":{"method":"GET","url":"http://example.com"}

Use Logger.WithGroup to qualify all of a Logger's output with a group name.
Calling WithGroup on a Logger results in a new Logger with the same Handler as
the original, but with all its attributes qualified by the group name.

This can help prevent duplicate attribute keys in large systems, where
subsystems might use the same keys. Pass each subsystem a different Logger with
its own group name so that potential duplicates are qualified:

    logger := slog.Default().With("id", systemID)
    parserLogger := logger.WithGroup("parser")
    parseInput(input, parserLogger)

When parseInput logs with parserLogger, its keys will be qualified with
"parser", so even if it uses the common key "id", the log line will have
distinct keys.

# Contexts

Some handlers may wish to include information from the context.Context that is
available at the call site. One example of such information is the identifier
for the current span when tracing is is enabled.

The Logger.Log and Logger.LogAttrs methods take a context as a first argument,
as do their corresponding top-level functions.

Although the convenience methods on Logger (Info and so on) and the
corresponding top-level functions do not take a context, the alternatives ending
in "Ctx" do. For example,

    slog.InfoCtx(ctx, "message")

It is recommended to pass a context to an output method if one is available.

# Advanced topics

## Customizing a type's logging behavior

If a type implements the LogValuer interface, the Value returned from its
LogValue method is used for logging. You can use this to control how values
of the type appear in logs. For example, you can redact secret information
like passwords, or gather a struct's fields in a Group. See the examples under
LogValuer for details.

A LogValue method may return a Value that itself implements LogValuer. The
Value.Resolve method handles these cases carefully, avoiding infinite loops and
unbounded recursion. Handler authors and others may wish to use Value.Resolve
instead of calling LogValue directly.

## Wrapping output methods

The logger functions use reflection over the call stack to find the file name
and line number of the logging call within the application. This can produce
incorrect source information for functions that wrap slog. For instance,
if you define this function in file mylog.go:

    func Infof(format string, args ...any) {
        slog.Default().Info(fmt.Sprintf(format, args...))
    }

and you call it like this in main.go:

    Infof(slog.Default(), "hello, %s", "world")

then slog will report the source file as mylog.go, not main.go.

A correct implementation of Infof will obtain the source location (pc) and
pass it to NewRecord. The Infof function in the package-level example called
"wrapping" demonstrates how to do this.

## Working with Records

Sometimes a Handler will need to modify a Record before passing it on to another
Handler or backend. A Record contains a mixture of simple public fields (e.g.
Time, Level, Message) and hidden fields that refer to state (such as attributes)
indirectly. This means that modifying a simple copy of a Record (e.g. by calling
Record.Add or Record.AddAttrs to add attributes) may have unexpected effects
on the original. Before modifying a Record, use [Clone] to create a copy that
shares no state with the original, or create a new Record with NewRecord and
build up its Attrs by traversing the old ones with Record.Attrs.

## Performance considerations

If profiling your application demonstrates that logging is taking significant
time, the following suggestions may help.

If many log lines have a common attribute, use Logger.With to create a Logger
with that attribute. The built-in handlers will format that attribute only once,
at the call to Logger.With. The Handler interface is designed to allow that
optimization, and a well-written Handler should take advantage of it.

The arguments to a log call are always evaluated, even if the log event is
discarded. If possible, defer computation so that it happens only if the value
is actually logged. For example, consider the call

    slog.Info("starting request", "url", r.URL.String())  // may compute String unnecessarily

The URL.String method will be called even if the logger discards Info-level
events. Instead, pass the URL directly:

    slog.Info("starting request", "url", &r.URL) // calls URL.String only if needed

The built-in TextHandler will call its String method, but only if the log event
is enabled. Avoiding the call to String also preserves the structure of the
underlying value. For example JSONHandler emits the components of the parsed
URL as a JSON object. If you want to avoid eagerly paying the cost of the String
call without causing the handler to potentially inspect the structure of the
value, wrap the value in a fmt.Stringer implementation that hides its Marshal
methods.

You can also use the LogValuer interface to avoid unnecessary work in disabled
log calls. Say you need to log some expensive value:

    slog.Debug("frobbing", "value", computeExpensiveValue(arg))

Even if this line is disabled, computeExpensiveValue will be called. To avoid
that, define a type implementing LogValuer:

    type expensive struct { arg int }

    func (e expensive) LogValue() slog.Value {
        return slog.AnyValue(computeExpensiveValue(e.arg))
    }

Then use a value of that type in log calls:

    slog.Debug("frobbing", "value", expensive{arg})

Now computeExpensiveValue will only be called when the line is enabled.

The built-in handlers acquire a lock before calling io.Writer.Write to ensure
that each record is written in one piece. User-defined handlers are responsible
for their own locking.

CONSTANTS

const (
	// TimeKey is the key used by the built-in handlers for the time
	// when the log method is called. The associated Value is a [time.Time].
	TimeKey = "time"
	// LevelKey is the key used by the built-in handlers for the level
	// of the log call. The associated value is a [Level].
	LevelKey = "level"
	// MessageKey is the key used by the built-in handlers for the
	// message of the log call. The associated value is a string.
	MessageKey = "msg"
	// SourceKey is the key used by the built-in handlers for the source file
	// and line of the log call. The associated value is a string.
	SourceKey = "source"
)
    Keys for "built-in" attributes.


FUNCTIONS

func Debug(msg string, args ...any)
    Debug calls Logger.Debug on the default logger.

func DebugCtx(ctx context.Context, msg string, args ...any)
    DebugCtx calls Logger.DebugCtx on the default logger.

func Error(msg string, args ...any)
    Error calls Logger.Error on the default logger.

func ErrorCtx(ctx context.Context, msg string, args ...any)
    ErrorCtx calls Logger.ErrorCtx on the default logger.

func Info(msg string, args ...any)
    Info calls Logger.Info on the default logger.

func InfoCtx(ctx context.Context, msg string, args ...any)
    InfoCtx calls Logger.InfoCtx on the default logger.

func Log(ctx context.Context, level Level, msg string, args ...any)
    Log calls Logger.Log on the default logger.

func LogAttrs(ctx context.Context, level Level, msg string, attrs ...Attr)
    LogAttrs calls Logger.LogAttrs on the default logger.

func NewLogLogger(h Handler, level Level) *log.Logger
    NewLogLogger returns a new log.Logger such that each call to its Output
    method dispatches a Record to the specified handler. The logger acts as a
    bridge from the older log API to newer structured logging handlers.

func SetDefault(l *Logger)
    SetDefault makes l the default Logger. After this call, output from the
    log package's default Logger (as with log.Print, etc.) will be logged at
    LevelInfo using l's Handler.

func Warn(msg string, args ...any)
    Warn calls Logger.Warn on the default logger.

func WarnCtx(ctx context.Context, msg string, args ...any)
    WarnCtx calls Logger.WarnCtx on the default logger.


TYPES

type Attr struct {
	Key   string
	Value Value
}
    An Attr is a key-value pair.

func Any(key string, value any) Attr
    Any returns an Attr for the supplied value. See [Value.AnyValue] for how
    values are treated.

func Bool(key string, v bool) Attr
    Bool returns an Attr for a bool.

func Duration(key string, v time.Duration) Attr
    Duration returns an Attr for a time.Duration.

func Float64(key string, v float64) Attr
    Float64 returns an Attr for a floating-point number.

func Group(key string, as ...Attr) Attr
    Group returns an Attr for a Group Value. The caller must not subsequently
    mutate the argument slice.

    Use Group to collect several Attrs under a single key on a log line, or as
    the result of LogValue in order to log a single value as multiple Attrs.

func Int(key string, value int) Attr
    Int converts an int to an int64 and returns an Attr with that value.

func Int64(key string, value int64) Attr
    Int64 returns an Attr for an int64.

func String(key, value string) Attr
    String returns an Attr for a string value.

func Time(key string, v time.Time) Attr
    Time returns an Attr for a time.Time. It discards the monotonic portion.

func Uint64(key string, v uint64) Attr
    Uint64 returns an Attr for a uint64.

func (a Attr) Equal(b Attr) bool
    Equal reports whether a and b have equal keys and values.

func (a Attr) String() string

type Handler interface {
	// Enabled reports whether the handler handles records at the given level.
	// The handler ignores records whose level is lower.
	// It is called early, before any arguments are processed,
	// to save effort if the log event should be discarded.
	// If called from a Logger method, the first argument is the context
	// passed to that method, or context.Background() if nil was passed
	// or the method does not take a context.
	// The context is passed so Enabled can use its values
	// to make a decision.
	Enabled(context.Context, Level) bool

	// Handle handles the Record.
	// It will only be called Enabled returns true.
	// The Context argument is as for Enabled.
	// It is present solely to provide Handlers access to the context's values.
	// Canceling the context should not affect record processing.
	// (Among other things, log messages may be necessary to debug a
	// cancellation-related problem.)
	//
	// Handle methods that produce output should observe the following rules:
	//   - If r.Time is the zero time, ignore the time.
	//   - If r.PC is zero, ignore it.
	//   - If an Attr's key is the empty string and the value is not a group,
	//     ignore the Attr.
	//   - If a group's key is empty, inline the group's Attrs.
	//   - If a group has no Attrs (even if it has a non-empty key),
	//     ignore it.
	Handle(context.Context, Record) error

	// WithAttrs returns a new Handler whose attributes consist of
	// both the receiver's attributes and the arguments.
	// The Handler owns the slice: it may retain, modify or discard it.
	// [Logger.With] will resolve the Attrs.
	WithAttrs(attrs []Attr) Handler

	// WithGroup returns a new Handler with the given group appended to
	// the receiver's existing groups.
	// The keys of all subsequent attributes, whether added by With or in a
	// Record, should be qualified by the sequence of group names.
	//
	// How this qualification happens is up to the Handler, so long as
	// this Handler's attribute keys differ from those of another Handler
	// with a different sequence of group names.
	//
	// A Handler should treat WithGroup as starting a Group of Attrs that ends
	// at the end of the log event. That is,
	//
	//     logger.WithGroup("s").LogAttrs(level, msg, slog.Int("a", 1), slog.Int("b", 2))
	//
	// should behave like
	//
	//     logger.LogAttrs(level, msg, slog.Group("s", slog.Int("a", 1), slog.Int("b", 2)))
	//
	// If the name is empty, WithGroup returns the receiver.
	WithGroup(name string) Handler
}
    A Handler handles log records produced by a Logger..

    A typical handler may print log records to standard error, or write them to
    a file or database, or perhaps augment them with additional attributes and
    pass them on to another handler.

    Any of the Handler's methods may be called concurrently with itself or
    with other methods. It is the responsibility of the Handler to manage this
    concurrency.

    Users of the slog package should not invoke Handler methods directly.
    They should use the methods of Logger instead.

type HandlerOptions struct {
	// When AddSource is true, the handler adds a ("source", "file:line")
	// attribute to the output indicating the source code position of the log
	// statement. AddSource is false by default to skip the cost of computing
	// this information.
	AddSource bool

	// Level reports the minimum record level that will be logged.
	// The handler discards records with lower levels.
	// If Level is nil, the handler assumes LevelInfo.
	// The handler calls Level.Level for each record processed;
	// to adjust the minimum level dynamically, use a LevelVar.
	Level Leveler

	// ReplaceAttr is called to rewrite each non-group attribute before it is logged.
	// The attribute's value has been resolved (see [Value.Resolve]).
	// If ReplaceAttr returns an Attr with Key == "", the attribute is discarded.
	//
	// The built-in attributes with keys "time", "level", "source", and "msg"
	// are passed to this function, except that time is omitted
	// if zero, and source is omitted if AddSource is false.
	//
	// The first argument is a list of currently open groups that contain the
	// Attr. It must not be retained or modified. ReplaceAttr is never called
	// for Group attributes, only their contents. For example, the attribute
	// list
	//
	//     Int("a", 1), Group("g", Int("b", 2)), Int("c", 3)
	//
	// results in consecutive calls to ReplaceAttr with the following arguments:
	//
	//     nil, Int("a", 1)
	//     []string{"g"}, Int("b", 2)
	//     nil, Int("c", 3)
	//
	// ReplaceAttr can be used to change the default keys of the built-in
	// attributes, convert types (for example, to replace a `time.Time` with the
	// integer seconds since the Unix epoch), sanitize personal information, or
	// remove attributes from the output.
	ReplaceAttr func(groups []string, a Attr) Attr
}
    HandlerOptions are options for a TextHandler or JSONHandler. A zero
    HandlerOptions consists entirely of default values.

func (opts HandlerOptions) NewJSONHandler(w io.Writer) *JSONHandler
    NewJSONHandler creates a JSONHandler with the given options that writes to
    w.

func (opts HandlerOptions) NewTextHandler(w io.Writer) *TextHandler
    NewTextHandler creates a TextHandler with the given options that writes to
    w.

type JSONHandler struct {
	// Has unexported fields.
}
    JSONHandler is a Handler that writes Records to an io.Writer as
    line-delimited JSON objects.

func NewJSONHandler(w io.Writer) *JSONHandler
    NewJSONHandler creates a JSONHandler that writes to w, using the default
    options.

func (h *JSONHandler) Enabled(_ context.Context, level Level) bool
    Enabled reports whether the handler handles records at the given level.
    The handler ignores records whose level is lower.

func (h *JSONHandler) Handle(_ context.Context, r Record) error
    Handle formats its argument Record as a JSON object on a single line.

    If the Record's time is zero, the time is omitted. Otherwise, the key is
    "time" and the value is output as with json.Marshal.

    If the Record's level is zero, the level is omitted. Otherwise, the key is
    "level" and the value of Level.String is output.

    If the AddSource option is set and source information is available, the key
    is "source" and the value is output as "FILE:LINE".

    The message's key is "msg".

    To modify these or other attributes, or remove them from the output,
    use [HandlerOptions.ReplaceAttr].

    Values are formatted as with encoding/json.Marshal, with the following
    exceptions:
      - Floating-point NaNs and infinities are formatted as one of the strings
        "NaN", "+Inf" or "-Inf".
      - Levels are formatted as with Level.String.
      - HTML characters are not escaped.

    Each call to Handle results in a single serialized call to io.Writer.Write.

func (h *JSONHandler) WithAttrs(attrs []Attr) Handler
    WithAttrs returns a new JSONHandler whose attributes consists of h's
    attributes followed by attrs.

func (h *JSONHandler) WithGroup(name string) Handler

type Kind int
    Kind is the kind of a Value.

const (
	KindAny Kind = iota
	KindBool
	KindDuration
	KindFloat64
	KindInt64
	KindString
	KindTime
	KindUint64
	KindGroup
	KindLogValuer
)
func (k Kind) String() string

type Level int
    A Level is the importance or severity of a log event. The higher the level,
    the more important or severe the event.

const (
	LevelDebug Level = -4
	LevelInfo  Level = 0
	LevelWarn  Level = 4
	LevelError Level = 8
)
    Second, we wanted to make it easy to use levels to specify logger verbosity.
    Since a larger level means a more severe event, a logger that accepts events
    with smaller (or more negative) level means a more verbose logger. Logger
    verbosity is thus the negation of event severity, and the default verbosity
    of 0 accepts all events at least as severe as INFO.

    Third, we wanted some room between levels to accommodate schemes with
    named levels between ours. For example, Google Cloud Logging defines a
    Notice level between Info and Warn. Since there are only a few of these
    intermediate levels, the gap between the numbers need not be large.
    Our gap of 4 matches OpenTelemetry's mapping. Subtracting 9 from an
    OpenTelemetry level in the DEBUG, INFO, WARN and ERROR ranges converts it to
    the corresponding slog Level range. OpenTelemetry also has the names TRACE
    and FATAL, which slog does not. But those OpenTelemetry levels can still be
    represented as slog Levels by using the appropriate integers.

    Names for common levels.

func (l Level) Level() Level
    Level returns the receiver. It implements Leveler.

func (l Level) MarshalJSON() ([]byte, error)
    MarshalJSON implements encoding/json.Marshaler by quoting the output of
    Level.String.

func (l Level) MarshalText() ([]byte, error)
    MarshalText implements encoding.TextMarshaler by calling Level.String.

func (l Level) String() string
    String returns a name for the level. If the level has a name, then that
    name in uppercase is returned. If the level is between named values, then an
    integer is appended to the uppercased name. Examples:

        LevelWarn.String() => "WARN"
        (LevelInfo+2).String() => "INFO+2"

func (l *Level) UnmarshalJSON(data []byte) error
    UnmarshalJSON implements encoding/json.Unmarshaler It accepts any string
    produced by Level.MarshalJSON, ignoring case. It also accepts numeric
    offsets that would result in a different string on output. For example,
    "Error-8" would marshal as "INFO".

func (l *Level) UnmarshalText(data []byte) error
    UnmarshalText implements encoding.TextUnmarshaler. It accepts any string
    produced by Level.MarshalText, ignoring case. It also accepts numeric
    offsets that would result in a different string on output. For example,
    "Error-8" would marshal as "INFO".

type LevelVar struct {
	// Has unexported fields.
}
    A LevelVar is a Level variable, to allow a Handler level to change
    dynamically. It implements Leveler as well as a Set method, and it is safe
    for use by multiple goroutines. The zero LevelVar corresponds to LevelInfo.

func (v *LevelVar) Level() Level
    Level returns v's level.

func (v *LevelVar) MarshalText() ([]byte, error)
    MarshalText implements encoding.TextMarshaler by calling Level.MarshalText.

func (v *LevelVar) Set(l Level)
    Set sets v's level to l.

func (v *LevelVar) String() string

func (v *LevelVar) UnmarshalText(data []byte) error
    UnmarshalText implements encoding.TextUnmarshaler by calling
    Level.UnmarshalText.

type Leveler interface {
	Level() Level
}
    A Leveler provides a Level value.

    As Level itself implements Leveler, clients typically supply a Level value
    wherever a Leveler is needed, such as in HandlerOptions. Clients who need to
    vary the level dynamically can provide a more complex Leveler implementation
    such as *LevelVar.

type LogValuer interface {
	LogValue() Value
}
    A LogValuer is any Go value that can convert itself into a Value for
    logging.

    This mechanism may be used to defer expensive operations until they are
    needed, or to expand a single value into a sequence of components.

type Logger struct {
	// Has unexported fields.
}
    A Logger records structured information about each call to its Log, Debug,
    Info, Warn, and Error methods. For each call, it creates a Record and passes
    it to a Handler.

    To create a new Logger, call New or a Logger method that begins "With".

func Default() *Logger
    Default returns the default Logger.

func New(h Handler) *Logger
    New creates a new Logger with the given non-nil Handler and a nil context.

func With(args ...any) *Logger
    With calls Logger.With on the default logger.

func (l *Logger) Debug(msg string, args ...any)
    Debug logs at LevelDebug.

func (l *Logger) DebugCtx(ctx context.Context, msg string, args ...any)
    DebugCtx logs at LevelDebug with the given context.

func (l *Logger) Enabled(ctx context.Context, level Level) bool
    Enabled reports whether l emits log records at the given context and level.

func (l *Logger) Error(msg string, args ...any)
    Error logs at LevelError.

func (l *Logger) ErrorCtx(ctx context.Context, msg string, args ...any)
    ErrorCtx logs at LevelError with the given context.

func (l *Logger) Handler() Handler
    Handler returns l's Handler.

func (l *Logger) Info(msg string, args ...any)
    Info logs at LevelInfo.

func (l *Logger) InfoCtx(ctx context.Context, msg string, args ...any)
    InfoCtx logs at LevelInfo with the given context.

func (l *Logger) Log(ctx context.Context, level Level, msg string, args ...any)
    Log emits a log record with the current time and the given level and
    message. The Record's Attrs consist of the Logger's attributes followed by
    the Attrs specified by args.

    The attribute arguments are processed as follows:
      - If an argument is an Attr, it is used as is.
      - If an argument is a string and this is not the last argument, the
        following argument is treated as the value and the two are combined into
        an Attr.
      - Otherwise, the argument is treated as a value with key "!BADKEY".

func (l *Logger) LogAttrs(ctx context.Context, level Level, msg string, attrs ...Attr)
    LogAttrs is a more efficient version of Logger.Log that accepts only Attrs.

func (l *Logger) Warn(msg string, args ...any)
    Warn logs at LevelWarn.

func (l *Logger) WarnCtx(ctx context.Context, msg string, args ...any)
    WarnCtx logs at LevelWarn with the given context.

func (l *Logger) With(args ...any) *Logger
    With returns a new Logger that includes the given arguments, converted
    to Attrs as in Logger.Log and resolved. The Attrs will be added to each
    output from the Logger. The new Logger shares the old Logger's context. The
    new Logger's handler is the result of calling WithAttrs on the receiver's
    handler.

func (l *Logger) WithGroup(name string) *Logger
    WithGroup returns a new Logger that starts a group. The keys of all
    attributes added to the Logger will be qualified by the given name. The new
    Logger shares the old Logger's context.

    The new Logger's handler is the result of calling WithGroup on the
    receiver's handler.

type Record struct {
	// The time at which the output method (Log, Info, etc.) was called.
	Time time.Time

	// The log message.
	Message string

	// The level of the event.
	Level Level

	// The program counter at the time the record was constructed, as determined
	// by runtime.Callers. If zero, no program counter is available.
	//
	// The only valid use for this value is as an argument to
	// [runtime.CallersFrames]. In particular, it must not be passed to
	// [runtime.FuncForPC].
	PC uintptr

	// Has unexported fields.
}
    A Record holds information about a log event. Copies of a Record share
    state. Do not modify a Record after handing out a copy to it. Use
    Record.Clone to create a copy with no shared state.

func NewRecord(t time.Time, level Level, msg string, pc uintptr) Record
    NewRecord creates a Record from the given arguments. Use Record.AddAttrs to
    add attributes to the Record.

    NewRecord is intended for logging APIs that want to support a Handler as a
    backend.

func (r *Record) Add(args ...any)
    Add converts the args to Attrs as described in Logger.Log, then appends the
    Attrs to the Record's list of Attrs. It resolves the Attrs before doing so.

func (r *Record) AddAttrs(attrs ...Attr)
    AddAttrs appends the given Attrs to the Record's list of Attrs. It resolves
    the Attrs before doing so.

func (r Record) Attrs(f func(Attr))
    Attrs calls f on each Attr in the Record. The Attrs are already resolved.

func (r Record) Clone() Record
    Clone returns a copy of the record with no shared state. The original record
    and the clone can both be modified without interfering with each other.

func (r Record) NumAttrs() int
    NumAttrs returns the number of attributes in the Record.

type TextHandler struct {
	// Has unexported fields.
}
    TextHandler is a Handler that writes Records to an io.Writer as a sequence
    of key=value pairs separated by spaces and followed by a newline.

func NewTextHandler(w io.Writer) *TextHandler
    NewTextHandler creates a TextHandler that writes to w, using the default
    options.

func (h *TextHandler) Enabled(_ context.Context, level Level) bool
    Enabled reports whether the handler handles records at the given level.
    The handler ignores records whose level is lower.

func (h *TextHandler) Handle(_ context.Context, r Record) error
    Handle formats its argument Record as a single line of space-separated
    key=value items.

    If the Record's time is zero, the time is omitted. Otherwise, the key is
    "time" and the value is output in RFC3339 format with millisecond precision.

    If the Record's level is zero, the level is omitted. Otherwise, the key is
    "level" and the value of Level.String is output.

    If the AddSource option is set and source information is available, the key
    is "source" and the value is output as FILE:LINE.

    The message's key "msg".

    To modify these or other attributes, or remove them from the output,
    use [HandlerOptions.ReplaceAttr].

    If a value implements encoding.TextMarshaler, the result of MarshalText is
    written. Otherwise, the result of fmt.Sprint is written.

    Keys and values are quoted with strconv.Quote if they contain Unicode space
    characters, non-printing characters, '"' or '='.

    Keys inside groups consist of components (keys or group names) separated by
    dots. No further escaping is performed. If it is necessary to reconstruct
    the group structure of a key even in the presence of dots inside components,
    use [HandlerOptions.ReplaceAttr] to escape the keys.

    Each call to Handle results in a single serialized call to io.Writer.Write.

func (h *TextHandler) WithAttrs(attrs []Attr) Handler
    WithAttrs returns a new TextHandler whose attributes consists of h's
    attributes followed by attrs.

func (h *TextHandler) WithGroup(name string) Handler

type Value struct {
	// Has unexported fields.
}
    A Value can represent any Go value, but unlike type any, it can represent
    most small values without an allocation. The zero Value corresponds to nil.

func AnyValue(v any) Value
    AnyValue returns a Value for the supplied value.

    If the supplied value is of type Value, it is returned unmodified.

    Given a value of one of Go's predeclared string, bool, or (non-complex)
    numeric types, AnyValue returns a Value of kind String, Bool, Uint64, Int64,
    or Float64. The width of the original numeric type is not preserved.

    Given a time.Time or time.Duration value, AnyValue returns a Value of kind
    KindTime or KindDuration. The monotonic time is not preserved.

    For nil, or values of all other types, including named types whose
    underlying type is numeric, AnyValue returns a value of kind KindAny.

func BoolValue(v bool) Value
    BoolValue returns a Value for a bool.

func DurationValue(v time.Duration) Value
    DurationValue returns a Value for a time.Duration.

func Float64Value(v float64) Value
    Float64Value returns a Value for a floating-point number.

func GroupValue(as ...Attr) Value
    GroupValue returns a new Value for a list of Attrs. The caller must not
    subsequently mutate the argument slice.

func Int64Value(v int64) Value
    Int64Value returns a Value for an int64.

func IntValue(v int) Value
    IntValue returns a Value for an int.

func StringValue(value string) Value
    StringValue returns a new Value for a string.

func TimeValue(v time.Time) Value
    TimeValue returns a Value for a time.Time. It discards the monotonic
    portion.

func Uint64Value(v uint64) Value
    Uint64Value returns a Value for a uint64.

func (v Value) Any() any
    Any returns v's value as an any.

func (v Value) Bool() bool
    Bool returns v's value as a bool. It panics if v is not a bool.

func (a Value) Duration() time.Duration
    Duration returns v's value as a time.Duration. It panics if v is not a
    time.Duration.

func (v Value) Equal(w Value) bool
    Equal reports whether v and w have equal keys and values.

func (v Value) Float64() float64
    Float64 returns v's value as a float64. It panics if v is not a float64.

func (v Value) Group() []Attr
    Group returns v's value as a []Attr. It panics if v's Kind is not KindGroup.

func (v Value) Int64() int64
    Int64 returns v's value as an int64. It panics if v is not a signed integer.

func (v Value) Kind() Kind
    Kind returns v's Kind.

func (v Value) LogValuer() LogValuer
    LogValuer returns v's value as a LogValuer. It panics if v is not a
    LogValuer.

func (v Value) Resolve() Value
    Resolve repeatedly calls LogValue on v while it implements LogValuer, and
    returns the result. If v resolves to a group, the group's attributes' values
    are also resolved. If the number of LogValue calls exceeds a threshold, a
    Value containing an error is returned. Resolve's return value is guaranteed
    not to be of Kind KindLogValuer.

func (v Value) String() string
    String returns Value's value as a string, formatted like fmt.Sprint.
    Unlike the methods Int64, Float64, and so on, which panic if v is of the
    wrong kind, String never panics.

func (v Value) Time() time.Time
    Time returns v's value as a time.Time. It panics if v is not a time.Time.

func (v Value) Uint64() uint64
    Uint64 returns v's value as a uint64. It panics if v is not an unsigned
    integer.


package slogtest

FUNCTIONS

func TestHandler(h slog.Handler, results func() []map[string]any) error
    TestHandler tests a slog.Handler. If TestHandler finds any misbehaviors,
    it returns an error for each, combined into a single error with errors.Join.

    TestHandler installs the given Handler in a slog.Logger and makes several
    calls to the Logger's output methods.

    The results function is invoked after all such calls. It should return
    a slice of map[string]any, one for each call to a Logger output method.
    The keys and values of the map should correspond to the keys and values of
    the Handler's output. Each group in the output should be represented as its
    own nested map[string]any.

    If the Handler outputs JSON, then calling encoding/json.Unmarshal with a
    `map[string]any` will create the right data structure.
```
