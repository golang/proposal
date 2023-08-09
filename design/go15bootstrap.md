# Go 1.5 Bootstrap Plan

Russ Cox \
January 2015 \
golang.org/s/go15bootstrap \
([comments on golang-dev](https://groups.google.com/d/msg/golang-dev/3bTIOleL8Ik/D8gICLOiUJEJ))

## Abstract

Go 1.5 will use a toolchain written in Go (at least in part). \
Question: how do you build Go if you need Go built already? \
Answer: building Go 1.5 will require having Go 1.4 available.

[**Update, 2023.** This plan was originally published as a Google document. For easier access, it was converted to Markdown in this repository in 2023. Later versions of Go require newer bootstrap toolchains. See [go.dev/issue/52465](https://go.dev/issue/52465) for those details.]

## Background

We have been planning for a year now to eliminate all C programs from the Go source tree. The C compilers (5c, 6c, 8c, 9c) have already been removed. The remaining C programs will be converted to Go: they are the Go compilers ([golang.org/s/go13compiler](https://go.dev/s/go13compiler)), the assemblers, the linkers ([golang.org/s/go13linker](https://go.dev/s/go13linker)), and cmd/dist. If these programs are written in Go, that introduces a bootstrapping problem when building completely from source code: you need a working Go toolchain in order to build a Go toolchain.

## Proposal

To build Go 1.x, for x ≥ 5, it will be necessary to have Go 1.4 (or newer) installed already, in $GOROOT_BOOTSTRAP. The default value of $GOROOT_BOOTSTRAP is $HOME/go1.4. In general we'll keep using Go 1.4 as the bootstrap base version for as long as possible. The toolchain proper (compiler, assemblers, linkers) will need to be buildable with Go 1.4, whether by restricting their feature use to what is in Go 1.4 or by using build tags.

For comparison with what will follow, the old build process for Go 1.4 is:

1. Build cmd/dist with gcc (or clang).
2. Using dist, build compiler toolchain with gcc (or clang)
3. NOP
4. Using dist, build cmd/go (as go_bootstrap) with compiler toolchain.
5. Using go_bootstrap, build the remaining standard library and commands.

The new build process for Go 1.x (x ≥ 5) will be:

1. Build cmd/dist with Go 1.4.
2. Using dist, build Go 1.x compiler toolchain with Go 1.4.
3. Using dist, rebuild Go 1.x compiler toolchain with itself.
4. Using dist, build Go 1.x cmd/go (as go_bootstrap) with Go 1.x compiler toolchain.
5. Using go_bootstrap, build the remaining Go 1.x standard library and commands.

There are two changes.

The first change is that we replace gcc (or clang) with Go 1.4.

The second change is the introduction of step 3, which rebuilds the Go 1.x compiler toolchain with itself. The 6g built in Step 2 is a Go 1.x compiler built using Go 1.4 libraries and compilers. The 6g built in Step 3 is the same Go 1.x compiler, but built using Go 1.x libraries and compilers. If Go 1.x has changed the format of debug info or some other detail of the binaries, it may matter to tools whether 6g is a Go 1.4 binary or a Go 1.x binary. If Go 1.x has introduced any performance or stability improvements in the libraries, the compiler in Step 3 will be faster or more stable than the compiler in Step 2. Of course, if Go 1.x is buggier, the 6g built in Step 3 will also be buggier, so it will be possible to disable step 3 for debugging.

Step 3 could make make.bash take longer. As an upper bound on the slowdown, the current build process steps 1-4 take 20 seconds on my MacBook Pro, out of the total 40 seconds required for make.bash. In the new process, I can’t see step 3 adding more than 50% to the make.bash run time, and I expect it would be significantly less than that. On the other hand, the C compilations being replaced are very I/O heavy; two Go compilations might still be faster, especially on I/O-constrained ARM devices. In any event, if make.bash does slow down, I will speed up run.bash at least as much, so that all.bash time does not increase.

## New Ports

Bootstrapping makes new ports a little more complex. It was possible in the past to check out the Go tree on a new system and run all.bash to build the toolchain (and it would fail, and you’d make some edits, and try again). Now, it will not be possible to run all.bash until that system is fully supported by Go.

For Go 1.x (x ≥ 5), new ports will have to be done by cross-compiling test binaries on a working system, copying the binaries over to the target, and running and debugging them there. This is already well-supported by all.bash via the go\_$GOOS\_$GOARCH\_exec scripts (see ‘go help run’). Once all.bash can be run in that mode, the resulting compilers and libraries can be copied to the target system and used directly.

Once a port works well enough that the compilers and linkers can run on the target machine, the script bootstrap.bash (run on an old system) will prepare a GOROOT_BOOTSTRAP directory for use on the new system.

## Deployment

Today we are still using the Go 1.4 build process above.

The first step in the transition will be to convert cmd/dist itself to Go and change make.bash to use Go 1.4 to build cmd/dist. That replaces “gcc (or clang)” with “Go 1.4” in step 1 of the build and changes nothing else. This will mainly exercise the integration of Go 1.4 into the build.

After that first step, we can convert the remaining C programs in whatever order makes sense. Each conversion will require minor modifications to cmd/dist to build the Go version instead of the C version. I am not sure whether the new linker or the new assemblers will be converted first. I expect the Go compiler to be converted last.

We will probably do the larger conversions on the dev.cc branch and merge into master at good checkpoints, so that multiple people can work on the conversion (coordinated via Git) but able to break certain builds for long amounts of time without affecting other developers. This is similar to what we did for dev.cc and dev.garbage in 2014.

Go 1.5 will require Go 1.4 to build. The goal is to convert all the C programs—the Go compiler, the linker, the assemblers, and cmd/dist—for Go 1.5. We may not reach that goal, but certainly some of that list will be converted.

