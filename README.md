# Fotone

The web engine of Sinty OS. Fotone tracks WPE WebKit upstream at a pinned release and
adds the Sinty platform: pages render into GPU buffers that `SitWebView` in SIT hands
straight to GSK, with input, theme, keyring, media and sandboxing coming from the
desktop instead of a toolkit port. WebKit itself stays C++; everything Fotone adds is
written in Zig against the C APIs of WPEPlatform and WPE WebKit, and the few hooks the
engine needs live as patches in `patches/`.

## Components

- `upstream/`: the pinned WPE WebKit release and its checksum.
- `patches/`: changes applied on top of upstream, one file per change.
- `platform/`: the Sinty WPEPlatform backend (`libfotone`, `fotone.h`).

`zig build engine` downloads the pinned release, checks its sha256, applies the patches
and builds WebKit with the Sinty options.

## Build

Zig 0.16, CMake, Ninja and the WPE WebKit build dependencies.

    zig build engine
    zig build
    zig build test

## License

LGPL-2.1-or-later, see [LICENSE](LICENSE). Contributions are covered by the [CLA](CLA.md).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on Fotone. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
