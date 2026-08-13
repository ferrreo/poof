# poof

A small [Zig](https://ziglang.org/) project.

## Requirements

- Zig `0.16.0` (see `.cursor/Dockerfile` for the pinned toolchain used by Cloud Agents).

## Build, run, test

```sh
zig build              # compile and install the binary to zig-out/bin/poof
zig build run          # build and run the app
zig build run -- Zig   # pass arguments to the app
zig build test         # run the unit tests
```

## Layout

- `src/main.zig` — executable entry point.
- `src/root.zig` — library module, importable as `@import("poof")`.
- `build.zig` / `build.zig.zon` — build script and package manifest.
