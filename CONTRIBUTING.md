# Contributing to Fotone

## Rules
- Upstream stays as it is. Fotone code is Zig against the WPEPlatform and WPE WebKit C APIs;
  C++ is touched only through a patch in `patches/` when no C API reaches the behaviour.
- One patch per change, each small enough to carry across an upstream bump. Generic fixes
  go upstream to WebKit as well.
- Bumping `upstream/wpewebkit` means a new release, its sha256, and every patch still
  applying cleanly.
- Platform code is tested in its own file with `zig build test`.

LGPL-2.1-or-later; by contributing you agree to the [CLA](CLA.md).

## Device- and environment-specific code

Code that exists only because of a specific device, architecture, firmware or environment must be marked on the line above it:

```
DEVICE-FIX(<scope>): <what breaks without this>
```

- `<scope>` is one of: `arm64`, `x86_64`, `uno-q`, `jetson`, `msm`, `nvidia`, `intel`, `amd`, `no-tpm`, `vm`, `u-boot`, `uefi`. A new scope is added to this list in the same pull request that first uses it.
- The text states what fails on that device without the code, not what the code does.
- Use the comment syntax of the file's language.
- This covers driver names, hardware probes, architecture constants, firmware quirks, boot-chain differences and anything gated on a specific environment.
- A pull request that adds or changes such code without the marker is not merged.
- `git grep -n "DEVICE-FIX("` lists every marker in the repository.
