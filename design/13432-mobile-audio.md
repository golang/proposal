# Proposal: Audio for Mobile

Author: Jaana Burcu Dogan

With input from David Crawshaw, Hyang-Ah Kim and Andrew Gerrand.

Last updated: November 30, 2015

Discussion at https://golang.org/issue/13432.

## Abstract

This proposal suggests core abstractions to support audio decoding
and playback on mobile devices.

## Background

In the scope of the Go mobile project, an audio package that supports
decoding and playback is a top priority. The current status of audio
support under x/mobile is limited to OpenAL bindings and an experimental
high-level audio player that is backed by OpenAL.

The experimental audio package fails to
- provide high level abstractions to represents audio and audio processors,
- implement a memory-efficient playback model,
- implement decoders (e.g. an mp3 decoder),
- support live streaming or other networking audio sources.

In order to address these concerns, I am proposing core abstractions and
a minimal set of features based on the proposed abstractions to provide
decoding and playback support.

## Proposal

I (Burcu Dogan) surveyed the top iOS and Android apps for audio features.
Three major categories with majorly different requirements have revealed
as a result of the survey. A good audio package shouldn't address the
different class of requirements with isolated audio APIs, but must introduce
common concepts and types that could be the backbone of both high- and low-
level audio packages. This is how we will enable users to expand their audio
capabilities by partially delegating their work to lower-level layers of the
audio package without having to rewrite their entire audio stack.

### Features considered
This section briefly explains the features required in order to support common
audio requirements of the mobile applications. The abstractions we introduce
today should be extendable to meet a majority of the features listed below in
the long run.

#### Playback
Single or multi-channel playback with player controls such as play, pause,
stop, etc. Games use a looping sample as the background music -- looping
functionality is also essential. Multiple playback instances are needed. Most
games require a background audio track and one-shot audio effects on the
foreground.

#### Decoding
Codec library and decoding support. Most radio-like apps and music players
need to play a variety of audio sources. Codec support in the parity of
AudioUnit on iOS and OpenMAX on Android is good to have.

#### Remote streaming
Audio players, radios and tools that streams audio need to be able to work
with remote audio sources. HTTP Live Streaming works on both platforms but
used to be inefficient on Android devices.

#### Synchronization and composition
- Synchronization between channels/players
- APIs that allow developers to schedule the playback, frame-level timers
- Mixers, multiple channels need to be multiplexed into a single device buffer
- Music software apps that require audio composition and filtering features

#### Playlist features
Music players and radios require playlisting features, so the users can queue,
unqueue tracks on the player. Player also need shuffling and repeating
features.

More information on the classification of the audio apps based on the features
listed above is available at Appendix: Audio Apps Classification.

### Goals

#### Short-term goals

- Playback of generated data (such as a PCM sine wave).
- Playback of an audio asset.
- Playback from streaming network sources.
- Core interfaces to represent decoders.
- Initial decoder implementations, ideally delegating the decoding to the
- system codecs (OpenMax for Android and AudioUnit for iOS).
- Basic play functions such as play (looping and one-shot), stop, pause,
gain control.
- Prefetching before user invokes playback.

#### Longer-term goals
- Multi channel playback (Playing multiple streams at the same time.)
- Multi channel synchronization and an internal clock
- Composition and filtering (mixing of multiple signals, low-pass filter,
reverb, etc)
- Tracklisting features to queue, unqueue multiple sources to a player;
playback features such as prefetching the next song

### Non-goals
- Audio capture. Recording and encoding audio is not in the roadmap initially.
Both could be added to the package without touching any API surface.
- Dependency on the visual frame rate. This feature requires the audio
scheduler to work in cooperation with the graphics layer and currently not
in our radar.

### Core abstractions

The section proposes the core interfaces and abstractions to represent audio,
audio sources and decoding primitives. The goal of introducing and agreeing on
the core abstractions is to be able to extend the audio package features in
the light of the considered features listed above without breaking the APIs.

####  Clip
The audio package will represent audio data as linear PCM formatted in-memory
audio chuncks. A fundamental interface, Clip, will define how to consume audio
data and how audio attributes (such as bit and sample rate) are reported to
the consumers of an audio media source.

Clip is is a small window into the underlying audio data.

```
// FrameInfo represents the frame-level information.
type FrameInfo struct {
    // Channels represent the number of audio channels
    // (e.g. 1 for mono, 2 for stereo).
    Channels int

    // Bit depth is the number of bits used to represent
    // a single sample.
    BitDepth int

    // Sample rate is the number of samples to be played
    // at each second.
    SampleRate int64
}

// Clip represents linear PCM formatted audio.
// Clip can seek and read a small number of frames to allow users to
// consume a small section of the underlying audio data.
//
// Frames return audio frames up to a number that can fit into the buf.
// n is the total number of returned frames.
// err is io.EOF if there are no frames left to read.
//
// FrameInfo returns the basic frame information about the clip audio.
//
// Seek seeks (offset*framesize*channels) byte in the source audio data.
// Seeking to negative offsets are illegal.
// An error is returned if the offset is out of the bounds of the
// audio data source.
//
// Size returns the total number of bytes of the underlying audio data.
// TODO(jbd): Support cases where size is unknown?
type Clip interface {
    Frames(buf []byte) (n int, err error)
    Seek(offset int64) (error)
    FrameInfo() FrameInfo
    Size() int64
}
```

#### Decoders
Decoders take any arbitrary input and is responsible to output a clip.
TODO(jbd): Proposal should also mention how the decoders will be organized.
e.g. image package's support for png, jpeg, gif, etc decoders.

```
// Decoder that reads from a Reader and converts the input
// to a PCM clip output.
func Decode(r io.ReadSeeker) (Clip, error) {
  panic("not implemented")
}

// A decoder that decodes the given data WAV byte slice and decodes it
// into a PCM clip output. An error is returned if any of the decoding
// steps fail. (e.g. ClipInfo cannot be determined from the WAV header.)
func DecodeWAVBytes(data []byte) (Clip, error) {
  panic("not implemented")
}

```

#### Clip sources
Any arbitrary valid audio data source can be converted into a clip. Examples
of clip sources are networking streams, file assets and in-memory buffers.

```
// NewBufferClip converts a buffer to a Clip.
func NewBufferClip(buf []byte, info FrameInfo) Clip {
    panic("not implemented")
}

// NewRemoteClip converts the HTTP live streaming media
// source into a Clip.
func NewRemoteClip(url string) (Clip, error) {
    panic("not implemented")
}
```

#### Players

A player plays a series of clips back-to-back, provides basic control
functions (play, stop, pause, seek, etc).

Note: Currently, x/mobile/exp/audio package provides an experimental and
highly immature player. With the introduction of the new core interfaces, we
will break the API surface in order to bless the new abstractions.

```
// NewPlayer returns a new Player. It initializes the underlying
// audio devices and the related resources.
// A player can play multiple clips back-to-back. Players will begin
// prefetching the next clip to provide a smooth and uninterrupted
// playback.
func NewPlayer(c ...Clip) (*Player, error)
```

## Compatibility

No compatibility issues.

## Implementation

The current scope of the implementation will be restricted to meet the
requirements listed in the "Short-term goals" sections.

The interfaces will be contributed by Burcu Dogan. The implementation of the
decoders and playback is a team effort and requires additional planning.

The audio package has no dependencies to the next Go releases and therefore
doesn't have to fit in the Go release cycle.

## Open issues

- WAV and AIFF both support float PCM values even though the use of float
values is unpopular. Should we consider supporting float values? Float values
mean more expensive encoding and decoding. Even if float values are supported,
they must be optional -- not the primary type to represent values.
- Decoding on desktop. The package will use the system codec libraries
provided by Android and iOS on mobile devices. It is not possible to provide
feature parity for desktop envs in the scope of decoding.
- Playback on desktop. The playback may directly use AudioUnit on iOS, and
libmedia (or stagefright) on Android. The media libraries on the desktop are
highly fragmented and cross-platform libraries are third-party dependencies.
It is unlikely that we can provide an audio package that works out of the box
on desktop if we don't write an audio backend for each platform.
- Hardware acceleration. Should we allow users to bypass the decoders and
stream to the device buffer in the longer term? The scope of the audio package
is primarily mobile devices (which case-by-case supports hardware
acceleration). But if the package will cover beyond the mobile, we should
consider this case.
- Seeking on variable bit rate encoded audio data is hard without a seek table.

## Appendix: Audio Apps Classification

Classification of the audio apps are based on thet survey results mentioned
above. This section summarizes which features are highly related to each other.

### Class A
Class A mostly represents games that require to play a background sound (in
looping mode or not) and occasionally need to play one-shot audio effects fit
in this category.
- Single channel player with looping audio
- Buffering audio files entirely in memory is efficient enough, audio files
are small
- Timing of the playback doesn’t have to be precise, latency is neglectable

### Class B
Class B represents games with advanced audio. Most apps that fit in this
category are using advanced audio engines as their audio backend.
- Multi channel player
- Synchronization between channels/players
- APIs that allow developers to schedule the playback, such as frame-level
timers
- Low latency, timing of the playback needs to be precise
- Mixers, multiple channels need to be multiplexed into a single device buffer
- Music software apps require audio composition, filtering, etc

### Class C
Class C represents the media players.
- Remote streaming
- Playlisting features, multitrack playback features such as prefetching and cross fading
- High-level player controls such as looping and shuffling
- Good decoder support
