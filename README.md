# sd2wav — Sound Designer II Converter

Converts Digidesign Sound Designer II (.sd2) files to WAV or AIFF.

## Building

Open Terminal, `cd` to this folder, and run:

```bash
swift build -c release
```

The compiled binary will be at `.build/release/sd2wav`.

You can copy it somewhere convenient:

```bash
cp .build/release/sd2wav /usr/local/bin/
```

## Usage

**If the resource fork is intact** (file lives on a Mac volume):

```bash
./sd2wav mysong.sd2
```

**If the resource fork is missing** (file was transferred from another system):

```bash
./sd2wav mysong.sd2 --rate 44100 --bits 16 --channels 2
```

**Output as AIFF instead of WAV:**

```bash
./sd2wav mysong.sd2 --aiff
```

**Specify the output filename:**

```bash
./sd2wav mysong.sd2 converted.wav
```

## Common Formats

Most Sound Designer II files from Pro Tools sessions in the 90s–2000s used:

| Setting | Typical value |
|---------|---------------|
| Sample rate | 44100 or 48000 Hz |
| Bit depth | 16 or 24 |
| Channels | 2 (stereo) or 1 (mono) |

If you're not sure, run `sd2wav` without parameters — it'll show you duration
estimates for common configurations so you can pick the one that makes sense.

## How It Works

SD2 files store raw PCM audio in the "data fork" and metadata (sample rate,
bit depth, channels) in the Mac "resource fork". This tool reads both and
produces a standard WAV or AIFF file.

For WAV output, the big-endian PCM samples are byte-swapped to little-endian.
For AIFF output, no byte-swapping is needed (both SD2 and AIFF are big-endian).
