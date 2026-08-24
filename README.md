# Vid2GIF

A blazingly fast, native macOS video → GIF converter. Zero dependencies — pure Swift on AVFoundation, VideoToolbox, and SwiftUI.

![](https://img.shields.io/badge/platform-macOS%2014%2B-blue) ![](https://img.shields.io/badge/deps-none-brightgreen)

![Vid2GIF](assets/screenshot.png)

## Why it's fast

- **Hardware decode**: frames come off the VideoToolbox H.264/HEVC decoder, never a software path.
- **GPU scale + resample**: `AVAssetReaderVideoCompositionOutput` scales to the output size and resamples to the target frame rate in one GPU-composited pass.
- **Custom GIF89a encoder**: median-cut global palette, 15-bit nearest-color lookup table, hand-rolled LZW — no ImageIO, no ffmpeg.
- **Inter-frame delta encoding**: only changed pixels are stored (with a changed-region bounding box + transparency). Screen recordings shrink ~7×.

Measured on an Apple Silicon Mac: a 36-second 2182×1464 screen recording converts to a 640px 15fps GIF (536 frames) in **2.9 seconds** — ~12× realtime.

## The live preview

The preview pane shows the *actual encoded GIF* — real palette, real dithering, real timing — and regenerates automatically (debounced) whenever you touch a setting or trim handle, with the exact output file size in the corner. No export-and-check loop; what you see is byte-for-byte what you save.

## Features

- Drag & drop or ⌘O to open (MOV, MP4, M4V, and anything else AVFoundation reads)
- Filmstrip timeline with draggable trim handles and playhead scrubbing
- Keyboard: **Space** play/pause · **I**/**O** set in/out points · **←**/**→** frame step · **⌘E** export
- Output width presets, 10–30 fps, 0.25–4× playback speed
- 64/128/256 colors; Bayer (ordered), Floyd–Steinberg (diffusion), or no dithering
- Loop-forever toggle and "optimize static areas" (delta encoding) toggle
- Result card with animated preview — drag it straight into Slack, or Reveal/Copy

## Build & run

```bash
make run        # builds build/Vid2GIF.app and opens it
```

## CLI

The same engine is scriptable:

```bash
.build/release/Vid2GIF convert input.mov output.gif \
  --width 640 --fps 15 --start 2.5 --end 8 --speed 1.5 \
  --colors 256 --dither bayer
```

Flags: `--width` `--fps` `--start` `--end` `--speed` `--colors` `--dither bayer|fs|none` `--no-loop` `--no-delta`.

## Architecture

```
Sources/Vid2GIF/
├── Engine/
│   ├── FrameSource.swift    # AVAssetReader + GPU composition (decode/scale/resample)
│   ├── Palette.swift        # median-cut quantizer + RGB555 lookup table
│   ├── Quantizer.swift      # Bayer / Floyd–Steinberg / none → palette indices
│   ├── LZWEncoder.swift     # GIF-flavor LZW (12-bit, variable width)
│   ├── GIFWriter.swift      # GIF89a streaming writer, delta frames, timing
│   └── GIFExporter.swift    # two-pass orchestration (palette pass → encode pass)
├── App/                     # AppDelegate, AppModel (state, player, live preview)
├── UI/                      # SwiftUI: editor, timeline, controls, export views
└── CLI.swift                # headless convert command
```

Export is two passes: pass 1 samples ~24 frames via `AVAssetImageGenerator` to build a global palette; pass 2 streams every frame through quantize → LZW → disk, so memory stays flat regardless of clip length.

## Credits

Developed by [Neo Mohsenvand](https://github.com/NeoVand). UI icons from [HugeIcons](https://hugeicons.com) (free set, MIT), vendored as SVGs in `Sources/Vid2GIF/Icons/`.
