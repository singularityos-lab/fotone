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
