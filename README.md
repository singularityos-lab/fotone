# Fotone

The web engine of Sinty OS. Fotone tracks WPE WebKit upstream at a pinned release and
adds the Sinty platform: pages render into GPU buffers that `SitWebView` in SIT hands
straight to GSK, with input, theme, keyring, media and sandboxing coming from the
desktop instead of a toolkit port. WebKit itself stays C++; everything Fotone adds is
written in Zig against the C APIs of WPEPlatform and WPE WebKit, and the few hooks the
engine needs live as patches in `patches/`.

## Components

- `upstream/`: the pinned WPE WebKit release, the libwebrtc tree of the same WebKit commit, and the
  ngtcp2, nghttp3, libevent and Opus releases built into the engine, each with its checksum or commit.
- `patches/`: changes applied on top of upstream, one file per change. `patches/series` marks each one
  `upstream` (a generic fix to send to WebKit) or `fotone` (stays in the fork); `zig build upstream`
  copies the first kind to `zig-out/upstream-patches`.
- `platform/`: the Sinty WPEPlatform backend (`libfotone`, `fotone.h`).
- `webview/`: `SitWebView`, the SIT widget that shows a page (`libsitwebview`, `sit/sitwebview.h`).
- `viewer/`: `fotone-viewer`, a window with one `SitWebView`.
- `sandbox/`: `fotone-sandbox`, which confines web processes with Landlock and seccomp before they start.
- `hooks/`: engine-side code the patches call into, linked into WebKit as a static library.
- `ocdm/`: `libocdm`, the OpenCDM interface the engine uses for Encrypted Media. It decrypts
  ClearKey itself and drives the Widevine module, which `SitWebView` downloads from Google
  the first time a site asks for it and the user agrees.
- `engine/`: lookups of the engine's own symbols, shared by the proxies.
- `proxy/`: `libwebkitgtk-6.0.so.4` and `libjavascriptcoregtk-6.0.so.1` with the WebKitGTK 6.0
  binary interface, and `libwebkit2gtk-4.1.so.0` and `libjavascriptcoregtk-4.1.so.0` with the
  WebKitGTK 4.1 one, so existing GTK 4 and GTK 3 applications run on the Fotone engine unchanged.
  The 4.1 library paints pages into its own GTK 3 widget and maps the older API (web contexts,
  JavaScript results, website data flags) onto the engine's.
- `bump/`: `zig build bump` moves `upstream/` to the newest stable WPE WebKit release
  (`FOTONE_BUMP_TO` picks a given one); `zig build engine` then shows which patches still apply.
- `compat/`: `fotone-compat` and `fotone-compat3`, which report the symbols, types, properties,
  signals and basic behaviour of any `libwebkitgtk-6.0` or `libwebkit2gtk-4.1` so the proxies can
  be diffed against WebKitGTK.

Per-site user agents, autoplay policies and engine settings live in `site-exceptions.json`, read from
`$XDG_CONFIG_HOME/fotone` first and then from the system data directories.

`sit_web_view_install_extension` loads an unpacked Manifest V3 extension into every `SitWebView`:
content scripts and styles run in the extension's own script world, `chrome.runtime` messages reach
its service worker, `chrome.storage.local` keeps its data under `$XDG_DATA_HOME/fotone/extensions`,
`chrome.i18n` reads `_locales`, and static `declarativeNetRequest` rule sets become engine content rules.
`fotone-viewer --extension DIR` loads one for testing.

A web app can ask for a window material with `<meta name="sinty-material" content="liquid">`
(`glass` and `blur` also work); on Singularity the window then shows through the page background.

`zig build engine` downloads the pinned release, checks its sha256, applies the patches
and builds WebKit with the Sinty options.

## Build

Zig 0.16, CMake, Ninja, NASM, the ALSA headers and the WPE WebKit build dependencies.

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
