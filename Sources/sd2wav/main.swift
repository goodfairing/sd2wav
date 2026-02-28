// ============================================================================
// sd2wav — Sound Designer II to WAV Converter
// ============================================================================
// Converts Digidesign Sound Designer II (.sd2) files to standard WAV files.
//
// SD2 files store raw PCM audio in the "data fork" and metadata (sample rate,
// bit depth, channel count) in the Mac "resource fork". This tool reads both
// forks and produces a standard WAV file.
//
// If the resource fork is missing (common after file transfers), the user can
// supply the audio parameters manually via command-line flags.
//
// Usage:
//   sd2wav <input.sd2> [output.wav]
//   sd2wav <input.sd2> --rate 44100 --bits 16 --channels 2
//   sd2wav --help
// ============================================================================

import Foundation

// MARK: - Configuration & Argument Parsing

/// Holds all the settings for a conversion job
struct ConversionConfig {
    let inputPath: String
    let outputPath: String
    let sampleRate: Int?      // nil = read from resource fork
    let bitDepth: Int?        // nil = read from resource fork
    let channelCount: Int?    // nil = read from resource fork
    let outputFormat: OutputFormat
    let probeMode: Bool       // generate preview clips for each common format
    let probeSeconds: Int     // how many seconds of audio per preview

    enum OutputFormat: String {
        case wav
        case aiff
    }
}

/// Parse command-line arguments into a ConversionConfig
func parseArguments() -> ConversionConfig? {
    let args = Array(CommandLine.arguments.dropFirst()) // drop the program name

    if args.isEmpty || args.contains("--help") || args.contains("-h") {
        printUsage()
        return nil
    }

    var inputPath: String?
    var outputPath: String?
    var sampleRate: Int?
    var bitDepth: Int?
    var channelCount: Int?
    var outputFormat: ConversionConfig.OutputFormat = .wav
    var probeMode = false
    var probeSeconds = 10

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--rate", "-r":
            i += 1
            guard i < args.count, let val = Int(args[i]) else {
                printError("--rate requires a numeric value (e.g. 44100)")
                return nil
            }
            sampleRate = val

        case "--bits", "-b":
            i += 1
            guard i < args.count, let val = Int(args[i]) else {
                printError("--bits requires a numeric value (e.g. 16 or 24)")
                return nil
            }
            bitDepth = val

        case "--channels", "-c":
            i += 1
            guard i < args.count, let val = Int(args[i]) else {
                printError("--channels requires a numeric value (e.g. 1 or 2)")
                return nil
            }
            channelCount = val

        case "--probe", "-p":
            probeMode = true

        case "--probe-seconds":
            i += 1
            guard i < args.count, let val = Int(args[i]), val > 0 else {
                printError("--probe-seconds requires a positive number (e.g. 10)")
                return nil
            }
            probeSeconds = val

        case "--aiff":
            outputFormat = .aiff

        case "--wav":
            outputFormat = .wav

        default:
            if args[i].hasPrefix("-") {
                printError("Unknown option: \(args[i])")
                return nil
            }
            if inputPath == nil {
                inputPath = args[i]
            } else if outputPath == nil {
                outputPath = args[i]
            } else {
                printError("Unexpected argument: \(args[i])")
                return nil
            }
        }
        i += 1
    }

    guard let input = inputPath else {
        printError("No input file specified")
        return nil
    }

    // Default output: same name with .wav or .aiff extension
    let output = outputPath ?? {
        let url = URL(fileURLWithPath: input)
        let ext = outputFormat == .wav ? "wav" : "aiff"
        return url.deletingPathExtension().appendingPathExtension(ext).path
    }()

    return ConversionConfig(
        inputPath: input,
        outputPath: output,
        sampleRate: sampleRate,
        bitDepth: bitDepth,
        channelCount: channelCount,
        outputFormat: outputFormat,
        probeMode: probeMode,
        probeSeconds: probeSeconds
    )
}

func printUsage() {
    let usage = """

    sd2wav — Sound Designer II to WAV/AIFF Converter

    USAGE:
      sd2wav <input.sd2> [output.wav] [options]

    EXAMPLES:
      sd2wav mysong.sd2                        Convert using resource fork metadata
      sd2wav mysong.sd2 mysong.wav             Specify output filename
      sd2wav mysong.sd2 --rate 44100 --bits 16 --channels 2
                                               Manual mode (no resource fork needed)
      sd2wav mysong.sd2 --aiff                 Output as AIFF instead of WAV
      sd2wav mysong.sd2 --probe                Generate preview clips to find the right format

    OPTIONS:
      --rate, -r <Hz>        Sample rate (e.g. 44100, 48000, 96000)
      --bits, -b <depth>     Bit depth (8, 16, or 24)
      --channels, -c <num>   Channel count (1=mono, 2=stereo)
      --wav                  Output as WAV (default)
      --aiff                 Output as AIFF
      --probe, -p            Generate short preview WAVs for common formats
      --probe-seconds <sec>  Length of each preview clip (default: 10)
      --help, -h             Show this help

    NOTES:
      SD2 files store audio parameters in a Mac "resource fork". If the resource
      fork is intact (common on macOS with HFS+/APFS), sd2wav reads it automatically.

      If the resource fork was lost during file transfer, use --rate, --bits, and
      --channels to specify the parameters manually. For most Pro Tools / Sound
      Designer sessions from the 90s-2000s, try: --rate 44100 --bits 16 --channels 2

    """
    print(usage)
}

func printError(_ message: String) {
    // Print to stderr in red (if terminal supports it)
    FileHandle.standardError.write(Data("❌ Error: \(message)\n".utf8))
}

func printInfo(_ message: String) {
    print("  \(message)")
}

// MARK: - Resource Fork Parser

/// The three values we need from the SD2 resource fork
struct SD2Metadata {
    let sampleRate: Int
    let bitDepth: Int
    let channelCount: Int
}

/// Attempt to read SD2 metadata from the resource fork.
///
/// On macOS, resource forks can be accessed in several ways:
/// 1. Native: /path/to/file/..namedfork/rsrc
/// 2. AppleDouble: /path/to/._file  (created when copying to non-HFS volumes)
/// 3. Extended attribute: com.apple.ResourceFork
///
/// The resource fork binary format:
/// ┌──────────────────────────────────────────┐
/// │ Header (256 bytes)                       │
/// │   0..3:   offset to resource data        │
/// │   4..7:   offset to resource map         │
/// │   8..11:  length of resource data        │
/// │   12..15: length of resource map         │
/// ├──────────────────────────────────────────┤
/// │ Resource Data                            │
/// │   Each entry: [4-byte length] [data...]  │
/// ├──────────────────────────────────────────┤
/// │ Resource Map                             │
/// │   Copy of header (16 bytes)              │
/// │   Next map handle (4 bytes)              │
/// │   File ref (2 bytes)                     │
/// │   Attributes (2 bytes)                   │
/// │   Offset to type list (2 bytes)          │
/// │   Offset to name list (2 bytes)          │
/// │   Type List:                             │
/// │     count-1 (2 bytes)                    │
/// │     For each type:                       │
/// │       type code (4 bytes, e.g. 'STR ')   │
/// │       count-1 (2 bytes)                  │
/// │       offset to ref list (2 bytes)       │
/// │     Reference entries:                   │
/// │       resource ID (2 bytes)              │
/// │       name offset (2 bytes)              │
/// │       attributes (1 byte)                │
/// │       data offset (3 bytes)              │
/// │       reserved (4 bytes)                 │
/// └──────────────────────────────────────────┘
///
/// We look for STR resources with IDs:
///   1000 = sample-size (e.g. "16")
///   1001 = sample-rate (e.g. "44100")
///   1002 = channels    (e.g. "2")
///
/// STR format: [1-byte length] [string bytes...]
func readResourceFork(forFileAt path: String) -> SD2Metadata? {
    // Try each method of accessing the resource fork
    let rsrcPaths = [
        path + "/..namedfork/rsrc",                                   // native macOS
        (path as NSString).deletingLastPathComponent + "/._" +
            (path as NSString).lastPathComponent,                      // AppleDouble
    ]

    var rsrcData: Data?

    for rsrcPath in rsrcPaths {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: rsrcPath)), data.count > 256 {
            rsrcData = data
            printInfo("Found resource fork at: \(rsrcPath)")
            break
        }
    }

    // Also try reading via xattr (works on macOS even if namedfork doesn't)
    if rsrcData == nil {
        rsrcData = readResourceForkXattr(path: path)
        if rsrcData != nil {
            printInfo("Found resource fork via extended attribute")
        }
    }

    guard let data = rsrcData else {
        return nil
    }

    return parseResourceFork(data)
}

/// Read resource fork data from the com.apple.ResourceFork extended attribute
func readResourceForkXattr(path: String) -> Data? {
    #if os(macOS)
    let size = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, 0)
    guard size > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: size)
    let bytesRead = getxattr(path, "com.apple.ResourceFork", &buffer, size, 0, 0)
    guard bytesRead > 0 else { return nil }

    return Data(buffer[0..<bytesRead])
    #else
    return nil
    #endif
}

/// Parse the resource fork binary data and extract SD2 metadata
func parseResourceFork(_ data: Data) -> SD2Metadata? {
    guard data.count >= 256 else {
        printInfo("Resource fork too small (\(data.count) bytes)")
        return nil
    }

    // Read header
    let dataOffset = Int(readUInt32BE(data, offset: 0))
    let mapOffset = Int(readUInt32BE(data, offset: 4))
    let dataLength = Int(readUInt32BE(data, offset: 8))
    let mapLength = Int(readUInt32BE(data, offset: 12))

    guard mapOffset + mapLength <= data.count,
          dataOffset + dataLength <= data.count else {
        printInfo("Resource fork header points beyond file bounds")
        return nil
    }

    // Parse the resource map
    // Map starts with a copy of the 16-byte header, then:
    //   +16: next resource map handle (4 bytes) — skip
    //   +20: file reference number (2 bytes) — skip
    //   +22: resource fork attributes (2 bytes) — skip
    //   +24: offset from map start to type list (2 bytes)
    //   +26: offset from map start to name list (2 bytes)
    let typeListOffset = mapOffset + Int(readUInt16BE(data, offset: mapOffset + 24))
    // nameListOffset not needed for our purposes

    // Type list starts with count-1 (2 bytes)
    let typeCount = Int(readUInt16BE(data, offset: typeListOffset)) + 1

    // We need to find 'STR ' resources
    var strRefListOffset: Int?
    var strResourceCount: Int?
    let strType: UInt32 = 0x53545220  // 'STR ' in big-endian

    for t in 0..<typeCount {
        let entryOffset = typeListOffset + 2 + (t * 8)
        guard entryOffset + 8 <= data.count else { break }
        let typeCode = readUInt32BE(data, offset: entryOffset)
        let count = Int(readUInt16BE(data, offset: entryOffset + 4)) + 1
        let refOffset = Int(readUInt16BE(data, offset: entryOffset + 6))

        if typeCode == strType {
            // refOffset is relative to the type list start
            strRefListOffset = typeListOffset + refOffset
            strResourceCount = count
            break
        }
    }

    guard let refListOffset = strRefListOffset, let resCount = strResourceCount else {
        printInfo("No 'STR ' resources found in resource fork")
        return nil
    }

    // Now read each STR reference to find IDs 1000, 1001, 1002
    var sampleSize: Int?
    var sampleRate: Int?
    var channels: Int?

    for r in 0..<resCount {
        let refEntryOffset = refListOffset + (r * 12)
        guard refEntryOffset + 12 <= data.count else { continue }
        let resourceID = Int(readInt16BE(data, offset: refEntryOffset))
        // name offset at +2 (2 bytes) — skip
        // attributes at +4 (1 byte) — skip
        // data offset at +5 (3 bytes, relative to resource data section start)
        let resDataRelOffset = Int(readUInt24BE(data, offset: refEntryOffset + 5))
        let resDataAbsOffset = dataOffset + resDataRelOffset

        // Resource data: first 4 bytes = length, then the data
        guard resDataAbsOffset + 4 <= data.count else { continue }
        let _ = Int(readUInt32BE(data, offset: resDataAbsOffset))  // resource length (unused)
        let resBodyOffset = resDataAbsOffset + 4

        // Parse as STR (Pascal string): first byte = string length, then chars
        guard resBodyOffset + 1 <= data.count else { continue }
        let strLen = Int(data[resBodyOffset])
        guard resBodyOffset + 1 + strLen <= data.count else { continue }
        let strBytes = data[(resBodyOffset + 1)..<(resBodyOffset + 1 + strLen)]
        let strValue = String(data: strBytes, encoding: .ascii) ?? ""

        switch resourceID {
        case 1000:
            sampleSize = Int(strValue)
            printInfo("Resource fork → sample-size (ID 1000): \(strValue)")
        case 1001:
            sampleRate = Int(strValue)
            printInfo("Resource fork → sample-rate (ID 1001): \(strValue)")
        case 1002:
            channels = Int(strValue)
            printInfo("Resource fork → channels (ID 1002): \(strValue)")
        default:
            break // Other STR resources — not relevant
        }
    }

    guard let sr = sampleRate, let ss = sampleSize, let ch = channels else {
        printInfo("Resource fork missing required STR resources")
        if sampleRate == nil { printInfo("  Missing: sample-rate (ID 1001)") }
        if sampleSize == nil { printInfo("  Missing: sample-size (ID 1000)") }
        if channels == nil   { printInfo("  Missing: channels (ID 1002)") }
        return nil
    }

    return SD2Metadata(sampleRate: sr, bitDepth: ss, channelCount: ch)
}

// MARK: - Binary Reading Helpers

func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
    return (UInt32(data[offset]) << 24) |
           (UInt32(data[offset + 1]) << 16) |
           (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
}

func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
    return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

func readInt16BE(_ data: Data, offset: Int) -> Int16 {
    return Int16(bitPattern: readUInt16BE(data, offset: offset))
}

func readUInt24BE(_ data: Data, offset: Int) -> UInt32 {
    return (UInt32(data[offset]) << 16) |
           (UInt32(data[offset + 1]) << 8) |
            UInt32(data[offset + 2])
}

// MARK: - WAV File Writer

/// Write PCM audio data as a WAV file.
///
/// WAV format (RIFF):
/// ┌──────────────────────────────────────────┐
/// │ "RIFF" (4 bytes)                         │
/// │ file size - 8 (4 bytes, little-endian)   │
/// │ "WAVE" (4 bytes)                         │
/// ├──────────────────────────────────────────┤
/// │ "fmt " (4 bytes)                         │
/// │ chunk size = 16 (4 bytes, LE)            │
/// │ audio format = 1/PCM (2 bytes, LE)       │
/// │ channels (2 bytes, LE)                   │
/// │ sample rate (4 bytes, LE)                │
/// │ byte rate (4 bytes, LE)                  │
/// │ block align (2 bytes, LE)                │
/// │ bits per sample (2 bytes, LE)            │
/// ├──────────────────────────────────────────┤
/// │ "data" (4 bytes)                         │
/// │ data size (4 bytes, LE)                  │
/// │ audio samples... (little-endian PCM)     │
/// └──────────────────────────────────────────┘
///
/// IMPORTANT: SD2 stores samples as big-endian, WAV needs little-endian.
/// For 16-bit audio, we must byte-swap each sample pair.
/// For 8-bit audio, endianness doesn't matter (single byte).
/// For 24-bit audio, we swap each 3-byte group.
func writeWAV(pcmData: Data, metadata: SD2Metadata, outputPath: String) throws {
    let channels = UInt16(metadata.channelCount)
    let sampleRate = UInt32(metadata.sampleRate)
    let bitsPerSample = UInt16(metadata.bitDepth)
    let bytesPerSample = bitsPerSample / 8
    let blockAlign = channels * bytesPerSample
    let byteRate = sampleRate * UInt32(blockAlign)
    let dataSize = UInt32(pcmData.count)
    let fileSize = 36 + dataSize  // everything after "RIFF" + size field

    var wav = Data()
    wav.reserveCapacity(Int(44 + dataSize))

    // RIFF header
    wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
    wav.append(uint32LE: fileSize)
    wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"

    // fmt chunk
    wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
    wav.append(uint32LE: 16)                            // chunk size
    wav.append(uint16LE: 1)                             // PCM format
    wav.append(uint16LE: channels)
    wav.append(uint32LE: sampleRate)
    wav.append(uint32LE: byteRate)
    wav.append(uint16LE: blockAlign)
    wav.append(uint16LE: bitsPerSample)

    // data chunk header
    wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
    wav.append(uint32LE: dataSize)

    // Convert PCM data from big-endian (SD2) to little-endian (WAV)
    let convertedPCM = convertEndianness(pcmData, bytesPerSample: Int(bytesPerSample))
    wav.append(convertedPCM)

    try wav.write(to: URL(fileURLWithPath: outputPath))
}

// MARK: - AIFF File Writer

/// Write PCM audio data as an AIFF file.
///
/// AIFF format (IFF):
/// ┌──────────────────────────────────────────┐
/// │ "FORM" (4 bytes)                         │
/// │ file size - 8 (4 bytes, big-endian)      │
/// │ "AIFF" (4 bytes)                         │
/// ├──────────────────────────────────────────┤
/// │ "COMM" (4 bytes)                         │
/// │ chunk size = 18 (4 bytes, BE)            │
/// │ channels (2 bytes, BE)                   │
/// │ sample frames (4 bytes, BE)              │
/// │ sample size in bits (2 bytes, BE)        │
/// │ sample rate as 80-bit extended (10 bytes)│
/// ├──────────────────────────────────────────┤
/// │ "SSND" (4 bytes)                         │
/// │ chunk size (4 bytes, BE)                 │
/// │ offset (4 bytes, BE) = 0                 │
/// │ block size (4 bytes, BE) = 0             │
/// │ audio samples... (big-endian PCM)        │
/// └──────────────────────────────────────────┘
///
/// AIFF is also big-endian, so no byte-swapping needed from SD2!
func writeAIFF(pcmData: Data, metadata: SD2Metadata, outputPath: String) throws {
    let channels = UInt16(metadata.channelCount)
    let sampleRate = metadata.sampleRate
    let bitsPerSample = UInt16(metadata.bitDepth)
    let bytesPerSample = Int(bitsPerSample) / 8
    let totalSampleFrames = UInt32(pcmData.count / (Int(channels) * bytesPerSample))

    let commChunkSize: UInt32 = 18
    let ssndDataSize = UInt32(pcmData.count)
    let ssndChunkSize = ssndDataSize + 8  // +8 for offset & blockSize fields
    let formSize = 4 + (8 + commChunkSize) + (8 + ssndChunkSize)  // "AIFF" + chunks

    var aiff = Data()
    aiff.reserveCapacity(Int(12 + 8 + commChunkSize + 8 + ssndChunkSize))

    // FORM header
    aiff.append(contentsOf: [0x46, 0x4F, 0x52, 0x4D])  // "FORM"
    aiff.append(uint32BE: formSize)
    aiff.append(contentsOf: [0x41, 0x49, 0x46, 0x46])  // "AIFF"

    // COMM chunk
    aiff.append(contentsOf: [0x43, 0x4F, 0x4D, 0x4D])  // "COMM"
    aiff.append(uint32BE: commChunkSize)
    aiff.append(uint16BE: channels)
    aiff.append(uint32BE: totalSampleFrames)
    aiff.append(uint16BE: bitsPerSample)
    aiff.append(contentsOf: doubleToExtended80(Double(sampleRate)))

    // SSND chunk
    aiff.append(contentsOf: [0x53, 0x53, 0x4E, 0x44])  // "SSND"
    aiff.append(uint32BE: ssndChunkSize)
    aiff.append(uint32BE: 0)  // offset
    aiff.append(uint32BE: 0)  // blockSize
    aiff.append(pcmData)      // already big-endian, no conversion needed!

    try aiff.write(to: URL(fileURLWithPath: outputPath))
}

/// Convert a Double to 80-bit IEEE 754 extended precision (big-endian)
/// This is needed for the sample rate field in AIFF COMM chunks.
func doubleToExtended80(_ value: Double) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: 10)

    if value == 0 {
        return result
    }

    var val = value
    var sign: UInt16 = 0
    if val < 0 {
        sign = 0x8000
        val = -val
    }

    // Decompose into mantissa and exponent
    let exponent = Int(floor(log2(val)))
    let mantissa = val / pow(2.0, Double(exponent))
    // mantissa is now in [1.0, 2.0)

    let biasedExponent = UInt16(exponent + 16383) | sign

    // Convert mantissa to 64-bit integer (1.63 fixed point)
    let mantissaInt = UInt64(mantissa * pow(2.0, 63.0))

    result[0] = UInt8(biasedExponent >> 8)
    result[1] = UInt8(biasedExponent & 0xFF)
    result[2] = UInt8((mantissaInt >> 56) & 0xFF)
    result[3] = UInt8((mantissaInt >> 48) & 0xFF)
    result[4] = UInt8((mantissaInt >> 40) & 0xFF)
    result[5] = UInt8((mantissaInt >> 32) & 0xFF)
    result[6] = UInt8((mantissaInt >> 24) & 0xFF)
    result[7] = UInt8((mantissaInt >> 16) & 0xFF)
    result[8] = UInt8((mantissaInt >> 8) & 0xFF)
    result[9] = UInt8(mantissaInt & 0xFF)

    return result
}

// MARK: - Endianness Conversion

/// Swap byte order of PCM samples from big-endian (SD2) to little-endian (WAV)
func convertEndianness(_ data: Data, bytesPerSample: Int) -> Data {
    if bytesPerSample == 1 {
        return data  // 8-bit samples don't need swapping
    }

    var result = Data(count: data.count)

    data.withUnsafeBytes { srcBuffer in
        result.withUnsafeMutableBytes { dstBuffer in
            let src = srcBuffer.bindMemory(to: UInt8.self)
            let dst = dstBuffer.bindMemory(to: UInt8.self)

            if bytesPerSample == 2 {
                // 16-bit: swap each pair of bytes
                let end = data.count & ~1  // round down to even
                for i in stride(from: 0, to: end, by: 2) {
                    dst[i]     = src[i + 1]
                    dst[i + 1] = src[i]
                }
            } else if bytesPerSample == 3 {
                // 24-bit: reverse each 3-byte group
                let end = data.count - (data.count % 3)  // round down to multiple of 3
                for i in stride(from: 0, to: end, by: 3) {
                    dst[i]     = src[i + 2]
                    dst[i + 1] = src[i + 1]
                    dst[i + 2] = src[i]
                }
            }
        }
    }

    return result
}

// MARK: - Data Extension for Binary Writing

extension Data {
    mutating func append(uint16LE value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32LE value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint16BE value: UInt16) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32BE value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

// MARK: - Probe Mode

/// Common format configurations to try, ordered from most to least likely
let probeConfigs: [(rate: Int, bits: Int, channels: Int, label: String)] = [
    (44100, 16, 2, "16bit-44k-stereo"),
    (48000, 16, 2, "16bit-48k-stereo"),
    (44100, 24, 2, "24bit-44k-stereo"),
    (48000, 24, 2, "24bit-48k-stereo"),
    (44100, 16, 1, "16bit-44k-mono"),
    (48000, 16, 1, "16bit-48k-mono"),
    (44100, 24, 1, "24bit-44k-mono"),
    (96000, 24, 2, "24bit-96k-stereo"),
]

/// Generate short preview WAV clips for each common format so the user can
/// listen and figure out which parameters are correct.
///
/// The previews are taken from the middle of the file (not the start) because
/// many recordings begin with silence, which wouldn't help you tell formats apart.
func runProbe(pcmData: Data, inputPath: String, seconds: Int) {
    let inputURL = URL(fileURLWithPath: inputPath)
    let baseName = inputURL.deletingPathExtension().lastPathComponent
    let outputDir = inputURL.deletingLastPathComponent()
        .appendingPathComponent("\(baseName)_probes")

    // Create the probes folder
    do {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    } catch {
        printError("Could not create probe folder: \(error.localizedDescription)")
        exit(1)
    }

    print("")
    printInfo("Generating \(seconds)-second preview clips...")
    printInfo("Folder: \(outputDir.path)")
    print("")

    var generated = 0

    for config in probeConfigs {
        let bytesPerFrame = (config.bits / 8) * config.channels
        let totalFrames = pcmData.count / bytesPerFrame

        // Skip configurations that don't divide evenly (likely wrong)
        let remainder = pcmData.count % bytesPerFrame
        if remainder != 0 { continue }

        // Skip if file would be unreasonably short (less than 1 second)
        let durationSecs = Double(totalFrames) / Double(config.rate)
        if durationSecs < 1.0 { continue }

        // Take the preview from ~30% into the file to skip initial silence
        let previewFrames = min(totalFrames, config.rate * seconds)
        let startFrame = min(totalFrames / 3, totalFrames - previewFrames)
        let startByte = startFrame * bytesPerFrame
        let endByte = min(startByte + (previewFrames * bytesPerFrame), pcmData.count)

        let previewData = pcmData[startByte..<endByte]

        let metadata = SD2Metadata(
            sampleRate: config.rate,
            bitDepth: config.bits,
            channelCount: config.channels
        )

        let mins = Int(durationSecs) / 60
        let secs = Int(durationSecs) % 60
        let filename = "probe_\(config.label).wav"
        let outputPath = outputDir.appendingPathComponent(filename).path

        do {
            try writeWAV(pcmData: Data(previewData), metadata: metadata, outputPath: outputPath)
            printInfo("  ✅ \(filename)  (full file would be \(mins)m \(secs)s)")
            generated += 1
        } catch {
            printInfo("  ❌ \(filename)  — write failed: \(error.localizedDescription)")
        }
    }

    print("")
    printInfo("Generated \(generated) preview clips in:")
    printInfo("  \(outputDir.path)")
    print("")
    printInfo("Listen to each one — the correct format will sound normal.")
    printInfo("Wrong formats will sound like static, chipmunks, or slow-motion.")
    print("")
    printInfo("Once you've found the right one, convert the full file:")
    printInfo("  sd2wav \(inputPath) --rate <rate> --bits <bits> --channels <ch>")
    print("")
}

// MARK: - Main Conversion Logic

func convert() {
    guard let config = parseArguments() else {
        // parseArguments() returned nil — either --help was shown (exit 0) or there was an error (exit 1)
        let isHelp = CommandLine.arguments.contains("--help") ||
                     CommandLine.arguments.contains("-h") ||
                     CommandLine.arguments.count == 1
        exit(isHelp ? 0 : 1)
    }

    let inputURL = URL(fileURLWithPath: config.inputPath)

    // Verify input file exists
    guard FileManager.default.fileExists(atPath: config.inputPath) else {
        printError("File not found: \(config.inputPath)")
        exit(1)
    }

    print("")
    print("  ┌─────────────────────────────────────────────┐")
    print("  │  sd2wav — Sound Designer II Converter        │")
    print("  └─────────────────────────────────────────────┘")
    print("")
    printInfo("Input:  \(inputURL.lastPathComponent)")

    // Read the audio data (data fork)
    guard let pcmData = try? Data(contentsOf: inputURL) else {
        printError("Could not read input file")
        exit(1)
    }

    printInfo("Data fork size: \(formatBytes(pcmData.count))")
    print("")

    // Probe mode: generate preview clips and exit
    if config.probeMode {
        runProbe(pcmData: pcmData, inputPath: config.inputPath, seconds: config.probeSeconds)
        exit(0)
    }

    // Determine audio parameters
    var metadata: SD2Metadata

    if let rate = config.sampleRate, let bits = config.bitDepth, let ch = config.channelCount {
        // User provided all parameters manually
        metadata = SD2Metadata(sampleRate: rate, bitDepth: bits, channelCount: ch)
        printInfo("Using manual parameters:")
    } else {
        // Try to read from resource fork
        printInfo("Looking for resource fork...")
        if let rsrcMeta = readResourceFork(forFileAt: config.inputPath) {
            metadata = SD2Metadata(
                sampleRate: config.sampleRate ?? rsrcMeta.sampleRate,
                bitDepth: config.bitDepth ?? rsrcMeta.bitDepth,
                channelCount: config.channelCount ?? rsrcMeta.channelCount
            )
            printInfo("Audio parameters from resource fork:")
        } else {
            print("")
            printError("No resource fork found! The file may have lost its metadata")
            printError("during transfer from a Mac.")
            print("")
            printInfo("Option 1 — Specify parameters manually:")
            printInfo("  sd2wav \(config.inputPath) --rate 44100 --bits 16 --channels 2")
            print("")
            printInfo("Option 2 — Generate preview clips to find the right format:")
            printInfo("  sd2wav \(config.inputPath) --probe")
            print("")
            printInfo("Common configurations:")
            printInfo("  CD quality:     --rate 44100 --bits 16 --channels 2")
            printInfo("  DAT quality:    --rate 48000 --bits 16 --channels 2")
            printInfo("  Hi-res:         --rate 96000 --bits 24 --channels 2")
            printInfo("  Mono:           --rate 44100 --bits 16 --channels 1")
            print("")

            // Show educated guesses based on file size
            printInfo("Based on file size (\(formatBytes(pcmData.count))):")
            for (rate, bits, ch, label) in [
                (44100, 16, 2, "16-bit/44.1k stereo"),
                (48000, 16, 2, "16-bit/48k stereo"),
                (44100, 24, 2, "24-bit/44.1k stereo"),
                (48000, 24, 2, "24-bit/48k stereo"),
                (44100, 16, 1, "16-bit/44.1k mono"),
            ] as [(Int, Int, Int, String)] {
                let bytesPerFrame = (bits / 8) * ch
                let frames = pcmData.count / bytesPerFrame
                let seconds = Double(frames) / Double(rate)
                let mins = Int(seconds) / 60
                let secs = Int(seconds) % 60
                printInfo("  \(label): \(mins)m \(secs)s")
            }
            print("")
            exit(1)
        }
    }

    // Validate parameters
    guard [8, 16, 24].contains(metadata.bitDepth) else {
        printError("Unsupported bit depth: \(metadata.bitDepth) (expected 8, 16, or 24)")
        exit(1)
    }

    guard metadata.channelCount >= 1 && metadata.channelCount <= 64 else {
        printError("Invalid channel count: \(metadata.channelCount)")
        exit(1)
    }

    guard metadata.sampleRate > 0 && metadata.sampleRate <= 384000 else {
        printError("Invalid sample rate: \(metadata.sampleRate)")
        exit(1)
    }

    // Calculate and display audio info
    let bytesPerFrame = (metadata.bitDepth / 8) * metadata.channelCount
    let totalFrames = pcmData.count / bytesPerFrame
    let durationSecs = Double(totalFrames) / Double(metadata.sampleRate)
    let minutes = Int(durationSecs) / 60
    let seconds = Int(durationSecs) % 60

    print("")
    printInfo("Sample rate:  \(metadata.sampleRate) Hz")
    printInfo("Bit depth:    \(metadata.bitDepth)-bit")
    printInfo("Channels:     \(metadata.channelCount) (\(metadata.channelCount == 1 ? "mono" : metadata.channelCount == 2 ? "stereo" : "\(metadata.channelCount)-channel"))")
    printInfo("Duration:     \(minutes)m \(seconds)s (\(totalFrames) sample frames)")
    print("")

    // Check if data size makes sense
    let remainder = pcmData.count % bytesPerFrame
    if remainder != 0 {
        printInfo("⚠️  Warning: data size is not an exact multiple of frame size.")
        printInfo("   \(remainder) trailing bytes will be ignored.")
        printInfo("   This might mean the parameters are wrong — double-check!")
        print("")
    }

    // Write output file
    let formatName = config.outputFormat == .wav ? "WAV" : "AIFF"
    printInfo("Writing \(formatName) file...")

    do {
        switch config.outputFormat {
        case .wav:
            try writeWAV(pcmData: pcmData, metadata: metadata, outputPath: config.outputPath)
        case .aiff:
            try writeAIFF(pcmData: pcmData, metadata: metadata, outputPath: config.outputPath)
        }

        let outputSize = try FileManager.default.attributesOfItem(atPath: config.outputPath)[.size] as? Int ?? 0
        printInfo("Output: \(config.outputPath)")
        printInfo("Size:   \(formatBytes(outputSize))")
        print("")
        printInfo("✅ Done!")
        print("")
    } catch {
        printError("Failed to write output: \(error.localizedDescription)")
        exit(1)
    }
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) bytes" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}

// MARK: - Entry Point

convert()
