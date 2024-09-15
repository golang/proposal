# x/crypto/ssh/v2

Author(s): Nicola Murino, Filippo Valsorda

## Motivation

In [65269](https://github.com/golang/go/issues/65269) we discussed migrating the `x/crypto` packages and thus also `x/crypto/ssh` to the standard library and the proposal was accepted.

The package `x/crypto/ssh` is one of the most used package in `x/crypto` and so it is stable and works well.
However, over the years we have accumulated several sub-optimal implementations to keep backward compatibility and we have realized that some interfaces are not implemented outside the packages itself and therefore can be removed.

The ssh server implementation does not have an high-level API similar to net/http `ListenAndServe` and this may be confusing for new users.

Furthermore, to have more consistency with the standard library APIs, we should rewrite the API that returns Go channels.

In v2 we can also remove deprecated API (e.g. DSA support).

For client and server APIs we want to have both a high-level and a low-level API to provide an easy way to handle the most common use cases, but also to enable our users to handle more advanced use cases by using the low-level API.

This means that we cannot merge `x/crypto/ssh` as is, the changes described here will lead to a v2.

### Proposal

The proposal is to add this new v2 to `x/cryoto/ssh` initially and then move it to the standard library.

`golang/x/crypto/ssh/v2` will become a wrapper for the package in the standard library once `v2` is merged.

See the following docs for full details and example:

- [ssh](./68723/ssh.html)
- [agent](./68723/agent/agent.html)
- [knownhosts](./68723/knownhosts/knownhosts.html)

### Interfaces removal

#### Remove Conn interface

The [Conn](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/connection.go#L50) interface is unlikely to be used outside the `ssh` package. Implementing it means also implementing the ssh connection protocol. We can remove this interface and just use [connection](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/connection.go#L88), its implementation, internally.

#### Convert ConnMetadata to a struct

The [ConnMetadata](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/connection.go#L24) interface holds metadata for the connection and after removing the `Conn` interface it can be converted to a struct so we don't have to add an interface extension each time we need to add a new method here. It was previosuly an interface because part of the `Conn` interface.

#### Convert Channel and NewChannel to structs

The [Channel](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/channel.go#L49) and [NewChannel](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/channel.go#L28) interfaces can be converted to structs after removing the `Conn` interface. They previously were interface because returned by methods in `Conn` interface.

### Add a context to the low lever server API

Our `Server` implementation provide a low level API, [NewServerConn](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/server.go#L205) to create a server connection from a `net.Conn`. This API starts an SSH handshake and can block if the provided `net.Conn` does not have a deadline. We'll update this API by adding a context so it is most clear that it can block. There is an open [proposal](https://github.com/golang/go/issues/66823) for this change. In v2 we can add the context directly without adding the `NewServerConnContext` variant.

### Add context to high level client API

Add a context to the high level API to create a client.

```go
Dial(ctx context.Context, network, addr string, config *ClientConfig) (*Client, error)
```

This means we can also remove the `Timeout` field from the [ClientConfig](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/client.go#L241) struct.

### Rename ServerConfig to Server

We have a [ServerConfig](https://github.com/golang/crypto/blob/a6a393ffd658b286f64f141b06cbd94e516d3a64/ssh/server.go#L63) struct but not a `Server` struct, the current `ServerConfig` is quit similar to `http.Server` and since we also plan to add some high-level API to our ssh server, see below, it makes sense to rename `ServerConfig` to just `Server`.

### New common interfaces and handler functions

SSH package is all around Requests and Channels so we can add some commom interfaces to reuse in our client and server implementation.

```go
// ChannelHandler defines the interface to handle new channel requests.
type ChannelHandler interface {
    NewChannel(ch *NewChannel)
}

// RequestHandler defines the interface to handle new [Request].
type RequestHandler interface {
    NewRequest(req *Request)
}

// ChannelHandlerFunc is an adapter to allow the use of ordinary function as
// [ChannelHandler]. If f is a function with the appropriate signature,
// ChannelHandlerFunc(f) is a [ChannelHandler] that calls f.
type ChannelHandlerFunc func(ch *NewChannel)

// RequestHandlerFunc is an adapter to allow the use of ordinary function as
// [RequestHandler]. If f is a function with the appropriate signature,
// RequestHandlerFunc(f) is a [RequestHandler] that calls f.
type RequestHandlerFunc func(req *Request)
```

### High-level Server API

The SSH server lacks high-level APIs, users should manually handle listening for new connections and creating SSH server connections. This may confuse new users or users coming from `net.http`, we should provide a well-know server pattern like `net.http`.

The proposal is to add the following high level APIs:

```go
func (s *Server) Serve(l net.Listener) error
func (s *Server) ListenAndServe(addr string) error
func (s *Server) Close() error
```

we also need to add some new fields to the `Server` struct

```go
type Server struct {
    ....
    // HandshakeTimeout defines the timeout for the initial handshake, as milliseconds.
    HandshakeTimeout int

    // ConnectionFailed, if non-nil, is called to report handshake errors.
    ConnectionFailed func(c net.Conn, err error)

    // ConnectionAdded, if non-nil, is called when a client connects, by
    // returning an error the connection will be refused.
    ConnectionAdded func(c net.Conn) error

    // ClientHandler defines the handler for authenticated clients. It is called
    // if the handshake is successfull. The handler must serve requests and
    // channels using [ServerConn.Handle].
    ClientHandler ClientHandler
}

// ClientHandler defines the interface to handle authenticated server
// connections.
type ClientHandler interface {
    // HandleClient is called after the handshake completes and a client
    // authenticates with the server.
    HandleClient(conn *ServerConn)
}

// ClientHandlerFunc is an adapter to allow the use of ordinary function as
// [ClientHandler]. If f is a function with the appropriate signature,
// ClientHandlerFunc(f) is a [ClientHandler] that calls f.
type ClientHandlerFunc func(conn *ServerConn)
```

Usage example for high-level API:

```go
server := &ssh.Server{
    Password: func(conn ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) {
        ...
    },
    ConnectionFailed: func(c net.Conn, err error) {
        ...
    },
    ConnectionAdded: func(c net.Conn) error {
        ...
    },
    ClientHandler: ssh.ClientHandlerFunc(func(conn *ssh.ServerConn) {
        conn.Handle(
                ssh.ChannelHandlerFunc(func(newChannel *ssh.NewChannel) {
                    ....
                }),
                ssh.RequestHandlerFunc(func(req *ssh.Request) {
                    ....
                }))
            }),
}

server.AddHostKey(ed25519Key)

if err := server.ListenAndServe(":3022"); err != nil {
    panic(err)
}
```

### Refactor API returning channels

In the `ssh` package we have several APIs returning Go channels, this is not common in the standard library so we should change some APIs and instead of returning something like `(chans <-chan NewChannel, reqs <-chan *Request)` we'll add an `Handle` method to `ServerConn`, `ClientConn` and `Channel` implementation:

```go
// Handle must be called to handle requests and channels. Handle blocks. If
// channelHandler is nil channels will be rejected. If requestHandler is nil,
// requests will be discarded.
func (c *ServerConn) Handle(channelHandler ChannelHandler, requestHandler RequestHandler) error

// Handle must be called to handle requests and channels if you want to handle a
// [ClientConn] yourself without building a [Client] using [NewClient]. Handle
// blocks. If channelHandler is nil channels will be rejected. If requestHandler
// is nil, requests will be discarded.
func (c *ClientConn) Handle(channelHandler ChannelHandler, requestHandler RequestHandler) error

// Handle must be called to handle channel's requests. Handle blocks. If
// requestHandler is nil, requests will be discarded.
func (c *Channel) Handle(handler RequestHandler) error
```

We can also remove the `DiscardRequests` package level method because channels and requests are now automatically discarded if a nil handler is passed to the `Handle` methods.

### Remove Callback suffix from Client and Server configs

Client and Server configs have fields like these:

```go
PasswordCallback func(conn ConnMetadata, password []byte) (*Permissions, error)

BannerCallback BannerCallback
```

Adding the `Callback` suffix is quite unusal in the standard library, we should remove this suffix like this:

```go
Password func(conn ConnMetadata, password []byte) (*Permissions, error)

Banner BannerCallback
```

## Remove NewSignerFromKey, rename NewSignerFromSigner to NewSigner

Currently we have the following APIs to create a `Signer`.

```go
// NewSignerFromSigner takes any crypto.Signer implementation and
// returns a corresponding Signer interface. This can be used, for
// example, with keys kept in hardware modules.
func NewSignerFromSigner(signer crypto.Signer) (Signer, error)

// NewSignerFromKey takes an *rsa.PrivateKey, *dsa.PrivateKey,
// *ecdsa.PrivateKey or any other crypto.Signer and returns a
// corresponding Signer instance. ECDSA keys must use P-256, P-384 or
// P-521. DSA keys must use parameter size L1024N160.
func NewSignerFromKey(key interface{}) (Signer, error)
```

`NewSignerFromKey` is required to handle `dsa.PrivateKey`, since DSA will be removed, we can also remove `NewSignerFromKey` and rename `NewSignerFromSigner` in `NewSigner`.

```go
// NewSigner takes any crypto.Signer implementation and returns a corresponding
// Signer interface. This can be used, for example, with keys kept in hardware
// modules.
func NewSigner(signer crypto.Signer) (Signer, error)
```

### Extend Signer interface

Initially the `Signer` interface was very simple and did not allow to specify the algorithm to use for signing or to list the supported signing algorithms, so to maintain backward compatibility we extended it.

```go
// A Signer can create signatures that verify against a public key.
//
// Some Signers provided by this package also implement MultiAlgorithmSigner.
type Signer interface {
    // PublicKey returns the associated PublicKey.
    PublicKey() PublicKey

    // Sign returns a signature for the given data. This method will hash the
    // data appropriately first. The signature algorithm is expected to match
    // the key format returned by the PublicKey.Type method (and not to be any
    // alternative algorithm supported by the key format).
    Sign(rand io.Reader, data []byte) (*Signature, error)
}

// An AlgorithmSigner is a Signer that also supports specifying an algorithm to
// use for signing.
//
// An AlgorithmSigner can't advertise the algorithms it supports, unless it also
// implements MultiAlgorithmSigner, so it should be prepared to be invoked with
// every algorithm supported by the public key format.
type AlgorithmSigner interface {
    Signer

    // SignWithAlgorithm is like Signer.Sign, but allows specifying a desired
    // signing algorithm. Callers may pass an empty string for the algorithm in
    // which case the AlgorithmSigner will use a default algorithm. This default
    // doesn't currently control any behavior in this package.
    SignWithAlgorithm(rand io.Reader, data []byte, algorithm string) (*Signature, error)
}

// MultiAlgorithmSigner is an AlgorithmSigner that also reports the algorithms
// supported by that signer.
type MultiAlgorithmSigner interface {
    AlgorithmSigner

    // Algorithms returns the available algorithms in preference order. The list
    // must not be empty, and it must not include certificate types.
    Algorithms() []string
}
```

Extending existing implementations to add these additional methods is quite simple so we may evaluate to change the interface in v2.

```go
// A Signer can create signatures that verify against a public key.
//
// Some Signers provided by this package also implement MultiAlgorithmSigner.
type Signer interface {
    // PublicKey returns the associated PublicKey.
    PublicKey() PublicKey

    // Sign returns a signature for the given data. This method will hash the
    // data appropriately first. The signature algorithm is expected to match
    // the key format returned by the PublicKey.Type method (and not to be any
    // alternative algorithm supported by the key format).
    Sign(rand io.Reader, data []byte) (*Signature, error)

    // SignWithAlgorithm is like Signer.Sign, but allows specifying a desired
    // signing algorithm. Callers may pass an empty string for the algorithm in
    // which case the AlgorithmSigner will use a default algorithm. This default
    // doesn't currently control any behavior in this package.
    SignWithAlgorithm(rand io.Reader, data []byte, algorithm string) (*Signature, error)
 
    // Algorithms returns the available algorithms in preference order. The list
    // must not be empty, and it must not include certificate types.
    Algorithms() []string
}
```

Suppose you have a signer implementation supporting a single algorithm like this.

```go
type mySigner struct {}

func (s *mySigner) Type() string

func (s *mySigner) Marshal() []byte

func (s *mySigner) Verify(data []byte, sig *Signature) error

func (s *mySigner) Sign(rand io.Reader, data []byte) (*Signature, error)
```

To implement the new `Signer` interface, you have to add the `Algorithms() []string` method that return the supported algorithm and the `SignWithAlgorithm(rand io.Reader, data []byte, algorithm string) (*Signature, error)` that just check that the specified algporithm is valid and then call the existing `Sign` method.

### Agent

Remove the method `SignWithFlags` from `ExtendedAgent` so that the `ExtendedAgent` interface only handle extensions.
We keep both `Sign` and `SignWithFlags` so that `Sign` can also be used to implement the `ssh.Signer` interface.

```go
// Agent represents the capabilities of an ssh-agent.
type Agent interface {
    // List returns the identities known to the agent.
    List() ([]*Key, error)

    // Sign has the agent sign the data using a protocol 2 key as defined
    // in [PROTOCOL.agent] section 2.6.2.
    Sign(key ssh.PublicKey, data []byte) (*ssh.Signature, error)

    // SignWithFlags signs like Sign, but allows for additional flags to be sent/received.
    SignWithFlags(key ssh.PublicKey, data []byte, flags SignatureFlags) (*ssh.Signature, error)

    // Add adds a private key to the agent.
    Add(key AddedKey) error

    // Remove removes all identities with the given public key.
    Remove(key ssh.PublicKey) error

    // RemoveAll removes all identities.
    RemoveAll() error

    // Lock locks the agent. Sign and Remove will fail, and List will empty an empty list.
    Lock(passphrase []byte) error

    // Unlock undoes the effect of Lock
    Unlock(passphrase []byte) error

    // Signers returns signers for all the known keys.
    Signers() ([]ssh.Signer, error)
}

type ExtendedAgent interface {
    Agent

    // Extension processes a custom extension request. Standard-compliant agents are not
    // required to support any extensions, but this method allows agents to implement
    // vendor-specific methods or add experimental features. See [PROTOCOL.agent] section 4.7.
    // If agent extensions are unsupported entirely this method MUST return an
    // ErrExtensionUnsupported error. Similarly, if just the specific extensionType in
    // the request is unsupported by the agent then ErrExtensionUnsupported MUST be
    // returned.
    //
    // In the case of success, since [PROTOCOL.agent] section 4.7 specifies that the contents
    // of the response are unspecified (including the type of the message), the complete
    // response will be returned as a []byte slice, including the "type" byte of the message.
    Extension(extensionType string, contents []byte) ([]byte, error)
}
```

### Add PrivateKeySigner

`PrivateKeySigner` is a `Signer` that can also return the associated `crypto.Signer`.
This means `ParseRawPrivateKey` and `ParseRawPrivateKeyWithPassphrase` can be private now because `ParsePrivateKey` and `ParsePrivateKeyWithPassphrase` return both a `Signer` and a `crypto.Signer`.

```go
// PrivateKeySigner is a [ssh.Signer] that can also return the associated
// [crypto.Signer].
type PrivateKeySigner struct {
    Signer
}

func (k *PrivateKeySigner) CryptoSigner() crypto.Signer

func ParsePrivateKey(pemBytes []byte) (*PrivateKeySigner, error)

func ParsePrivateKeyWithPassphrase(pemBytes, passphrase []byte) (*PrivateKeySigner, error)
```

### Add MarshalPrivateKeyOptions

Instead of passing options as function parameters to `MarshalPrivateKey` add a struct for options.

```go
// MarshalPrivateKeyOptions defines the available options to Marshal a private
// key in OpenSSH format.
type MarshalPrivateKeyOptions struct {
    Comment    string
    Passphrase string
    SaltRounds int
}
```

And change `MarshalPrivateKey` like this.

```go
func MarshalPrivateKey(key crypto.PrivateKey, options MarshalPrivateKeyOptions) (*pem.Block, error)
```

This way we can remove `MarshalPrivateKeyWithPassphrase` because the passphrase is now an option. We can easily add support for other options, for example making salt rounds confgurable, see [golang/go#68700](https://github.com/golang/go/issues/68700).

### Deprecated API and algorithms removal

We'll remove DSA support, see [here](https://lists.mindrot.org/pipermail/openssh-unix-announce/2024-January/000156.html) for DSA status in OpenSSH, it is already disabled by default and will be removed in January, 2025.

The following deprecated constants will be removed.

```go
const (
    // Deprecated: use CertAlgoRSAv01.
    CertSigAlgoRSAv01 = CertAlgoRSAv01
    // Deprecated: use CertAlgoRSASHA256v01.
    CertSigAlgoRSASHA2256v01 = CertAlgoRSASHA256v01
    // Deprecated: use CertAlgoRSASHA512v01.
    CertSigAlgoRSASHA2512v01 = CertAlgoRSASHA512v01
)

const (
    // Deprecated: use KeyAlgoRSA.
    SigAlgoRSA = KeyAlgoRSA
    // Deprecated: use KeyAlgoRSASHA256.
    SigAlgoRSASHA2256 = KeyAlgoRSASHA256
    // Deprecated: use KeyAlgoRSASHA512.
    SigAlgoRSASHA2512 = KeyAlgoRSASHA512
)
```

The `terminal` package is deprecated and will be removed.
The `test` and `testdata` packages will be moved to `internal`.
