import Foundation
import IOBluetooth
import Darwin

// Line-buffer stdout so progress is visible when the output is piped.
setvbuf(stdout, nil, _IOLBF, 0)

/// Default Bluetooth address (empty = auto-detect paired StickerPix).
let defaultAddress = ""

struct Options {
    var address = defaultAddress
    var command = "status"
    var attempts = 8
    var timeout = 45.0
    var copies = 1
    var inputs: [String] = []
    /// When set, override the cut orientation.
    var reverseCutterAxes: Bool?
    /// Print raw JSON alongside the summary.
    var raw = false
    /// Pick this many stickers at random from `randomDirectory`.
    var randomCount = 0
    /// Directory to pick random stickers from.
    var randomDirectory: String?
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    var commandSeen = false

    // Options may appear before or after the command and its arguments.
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--address", "-a":
            options.address = args.isEmpty ? options.address : args.removeFirst()
        case "--attempts", "-n":
            options.attempts = args.isEmpty ? options.attempts : (Int(args.removeFirst()) ?? options.attempts)
        case "--timeout", "-t":
            options.timeout = args.isEmpty ? options.timeout : (Double(args.removeFirst()) ?? options.timeout)
        case "--copies", "-c":
            options.copies = args.isEmpty ? options.copies : (Int(args.removeFirst()) ?? options.copies)
        case "--cut-orientation":
            guard !args.isEmpty else { break }
            switch args.removeFirst() {
            case "reversed": options.reverseCutterAxes = true
            case "direct": options.reverseCutterAxes = false
            default: break
            }
        case "--raw":
            options.raw = true
        case "--random":
            options.randomCount = args.isEmpty ? options.randomCount : (Int(args.removeFirst()) ?? options.randomCount)
            if !args.isEmpty, !args[args.startIndex].hasPrefix("-") {
                options.randomDirectory = args.removeFirst()
            }
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            if arg.hasPrefix("-") { break }
            if !commandSeen {
                options.command = arg
                commandSeen = true
            } else {
                options.inputs.append(arg)
            }
        }
    }
    return options
}

func printUsage() {
    print("""
    cricut-bt — talk to a Cricut StickerPix Print+Cut over Bluetooth

    USAGE
      cricut-bt status [--address <MAC>] [--attempts N] [--timeout SECONDS]
      cricut-bt discover

    COMMANDS
      status     Connect, handshake, and print the printer's properties
      discover   List the RFCOMM services the printer advertises
      cut        Convert a sticker PNG into a PLT cut file (no printer needed)
      sheet      Build a print sheet: <out.jpg> <out.plt> <sticker.png> ...
      sheet-layout  Build a print sheet from a hand-arranged layout: <layout.stickersheet> <out.jpg> <out.plt>
      preview    Draw a cut file back over its print sheet: <sheet.jpg> <sheet.plt> <out.png>
      print      Print and cut a prepared sheet: <sheet.jpg> <sheet.plt>
      probe      Open a channel and report what the printer sends
      props      Query printer properties by name
      selftest   Exercise the protocol against an in-memory mock printer

    OPTIONS
      -a, --address    Bluetooth address (default: auto-detect paired StickerPix)
      -n, --attempts   Connection attempts before giving up (default 8)
      -t, --timeout    Seconds to wait for each reply (default 45)
      -c, --copies     Copies to print (default 1)
      --cut-orientation reversed|direct
                      Override the cut orientation (default: reversed)
    """)
}

func discover(_ device: IOBluetoothDevice) {
    print("device: \(device.name ?? "?")  paired=\(device.isPaired())  connected=\(device.isConnected())")
    guard let records = device.services else {
        print("SDP browse failed — printer may be off or out of range.")
        return
    }
    print("\nSDP services (\(records.count)):")
    for record in records {
        let r = record as! IOBluetoothSDPServiceRecord
        var channelID: BluetoothRFCOMMChannelID = 0
        let hasChannel = r.getRFCOMMChannelID(&channelID) == kIOReturnSuccess
        print("  name=\(r.getServiceName())")
        print("     serialPort=\(r.matchesUUID16(0x1101))  rfcommChannel=\(hasChannel ? "\(channelID)" : "n/a")")
    }
}

/// Connect with retries: the printer refuses new RFCOMM sessions while a
/// previous one is still winding down, and the advertised channel id can
/// change between attempts.
func connect(_ options: Options) -> (BluetoothTransport, PrinterSession)? {
    for attempt in 1...options.attempts {
        guard let device = BluetoothTransport.device(address: options.address) else {
            if options.address.isEmpty {
                print("no paired StickerPix found — pair it in System Settings → Bluetooth or pass --address <MAC>.")
            } else {
                print("printer \(options.address) is not in the paired-device list.")
            }
            return nil
        }

        if device.isConnected() {
            device.closeConnection()
            Thread.sleep(forTimeInterval: 3)
        }

        // The advertised channel id has been seen to differ between queries
        // and the printer has refused connections on a channel that SDP
        // reported moments earlier, so probe the RFCOMM port range as well.
        // The advertised channels come first because they are the likely ones.
        var channels = BluetoothTransport.serialPortChannels(on: device)
        for candidate in 1...30 where !channels.contains(BluetoothRFCOMMChannelID(candidate)) {
            channels.append(BluetoothRFCOMMChannelID(candidate))
        }

        for channelID in channels {
            let transport = BluetoothTransport()
            let rc = transport.open(device: device, channelID: channelID)
            guard rc == kIOReturnSuccess else {
                transport.close(device: device)
                continue
            }

            let session = PrinterSession(device: device, transport: transport)
            do {
                try session.handshake(timeout: options.timeout)
                print("connected on RFCOMM channel \(channelID), handshake accepted")
                return (transport, session)
            } catch {
                print("attempt \(attempt): channel \(channelID) handshake failed — \(error)")
                transport.close(device: device)
            }
        }

        print("attempt \(attempt): no channel accepted a session")
        Thread.sleep(forTimeInterval: 6)
    }
    print("could not establish a session after \(options.attempts) attempts.")
    return nil
}

func status(_ options: Options) {
    guard let (transport, session) = connect(options) else { exit(1) }
    defer { transport.close(device: session.device) }

    let groups: [[String]] = [
        ["printer-state", "printer-sub-state", "printer-state-alerts"],
        ["model", "firmware-revision", "bt-fw_ver", "serial-number"],
        ["ribbon-info", "auto-off-interval"],
    ]
    for group in groups {
        do {
            let result = try session.properties(group)
            print("\(group.joined(separator: ", ")):")
            print("  \(describe(result))")
        } catch {
            print("\(group.joined(separator: ", ")):")
            print("  error: \(error)")
        }
    }
}

/// Query arbitrary printer properties by name.
func props(_ options: Options) {
    guard !options.inputs.isEmpty else {
        print("usage: cricut-bt props <name> [name ...]")
        exit(2)
    }
    guard let (transport, session) = connect(options) else { exit(1) }
    defer { transport.close(device: session.device) }

    do {
        let result = try session.properties(options.inputs)
        print("\(options.inputs.joined(separator: ", ")):")
        print("  \(describe(result))")
        if options.raw {
            let encoded = try JSONSerialization.data(withJSONObject: result ?? [:], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

/// Print and cut a sheet of stickers.
func printSheet(_ options: Options) {
    guard options.inputs.count >= 2 else {
        print("usage: cricut-bt print <sheet.jpg> <sheet.plt> [--copies N]")
        exit(2)
    }
    let jpegPath = options.inputs[0]
    let pltPath = options.inputs[1]

    guard let image = FileManager.default.contents(atPath: jpegPath),
          let cut = FileManager.default.contents(atPath: pltPath) else {
        print("error: could not read the sheet files")
        exit(1)
    }

    let sheet = PrintSheet(image: image,
                           cut: cut,
                           cutCount: 0,
                           name: (jpegPath as NSString).lastPathComponent)

    guard let (transport, session) = connect(options) else { exit(1) }
    defer { transport.close(device: session.device) }

    print("sheet: \(jpegPath) (\(image.count) bytes) + \(pltPath) (\(cut.count) bytes)")
    print("upload: \(sheet.fragmentCount) fragments")

    do {
        let info = try JobRunner.submit(session: session,
                                        sheet: sheet,
                                        copies: options.copies,
                                        progress: { print("  \($0)") })
        print("job finished: \(info)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

/// Pick sticker PNGs at random from a directory.
struct StickerPicker {
    static func randomPNGs(in directory: String, count: Int) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        let pngs = entries
            .filter { $0.lowercased().hasSuffix(".png") }
            .filter { !($0.hasPrefix(".") || $0.lowercased().hasPrefix("gemini_generated")) }
            .map { (directory as NSString).appendingPathComponent($0) }
            .sorted()
        guard !pngs.isEmpty else { return [] }
        // Take a random subset, keeping the order stable within one run.
        return Array(pngs.shuffled().prefix(count))
    }
}

/// Build a print sheet: JPEG plus PLT cut file, without touching the printer.
func sheet(_ options: Options) {
    var inputs = options.inputs
    guard inputs.count >= 2 else {
        print("usage: cricut-bt sheet <out.jpg> <out.plt> <sticker.png> [sticker.png ...]")
        print("       cricut-bt sheet <out.jpg> <out.plt> --random <N> <dir>")
        exit(2)
    }
    let jpegPath = inputs[0]
    let pltPath = inputs[1]
    inputs.removeFirst(2)

    // `--random N <dir>` picks N stickers at random from a directory.
    var stickers = inputs
    if let directory = options.randomDirectory {
        let picked = StickerPicker.randomPNGs(in: directory, count: options.randomCount)
        guard !picked.isEmpty else {
            print("error: no PNGs found in \(directory)")
            exit(1)
        }
        stickers.append(contentsOf: picked)
        print("picked \(picked.count) sticker(s) from \(directory):")
        for path in picked { print("  \(path)") }
    }

    guard !stickers.isEmpty else {
        print("usage: cricut-bt sheet <out.jpg> <out.plt> <sticker.png> [sticker.png ...]")
        exit(2)
    }
    var profile = SheetProfile.standard
    if let reversed = options.reverseCutterAxes {
        profile.reverseCutterAxes = reversed
        print("cut orientation: \(reversed ? "reversed" : "direct")")
    }
    do {
        let count = try SheetRenderer.build(stickerPNGs: stickers,
                                            jpegPath: jpegPath,
                                            pltPath: pltPath,
                                            profile: profile)
        print("wrote \(jpegPath) and \(pltPath) with \(count) contour(s)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

/// Open an RFCOMM channel and report what the printer sends, without doing a
/// full handshake. Useful for checking whether the printer is awake.
func probe(_ options: Options) {
    guard let device = BluetoothTransport.device(address: options.address) else {
        print("printer \(options.address) is not in the paired-device list.")
        exit(1)
    }
    print("device: \(device.name ?? "?") paired=\(device.isPaired()) connected=\(device.isConnected())")

    let channels = BluetoothTransport.serialPortChannels(on: device)
    print("Serial Port channels: \(channels)")

    guard let channelID = channels.first else {
        print("no Serial Port service advertised")
        exit(2)
    }

    let transport = BluetoothTransport()
    let rc = transport.open(device: device, channelID: channelID)
    print("open channel \(channelID) -> rc=\(rc)")
    guard rc == kIOReturnSuccess else { exit(3) }

    print("sending hello…")
    transport.write(Frame.build(command: Frame.Command.hello, body: Data("hello".utf8)))

    let deadline = Date().addingTimeInterval(options.timeout)
    while Date() < deadline {
        if let frame = transport.readFrame(timeout: 2) {
            print("  frame: channel=\(frame.channel) command=0x\(String(frame.command, radix: 16)) "
                  + "payloadType=\(frame.payloadType) flags=0x\(String(frame.flags, radix: 16)) "
                  + "body=\(frame.body.hexString())")
        }
    }
    transport.close(device: device)
    print("probe finished")
}

/// Draw the cut file back over a print sheet, to check the two agree.
func preview(_ options: Options) {
    guard options.inputs.count == 3 else {
        print("usage: cricut-bt preview <sheet.jpg> <sheet.plt> <out.png>")
        exit(2)
    }
    do {
        let count = try SheetRenderer.renderPreview(sheetJPEG: options.inputs[0],
                                                    pltPath: options.inputs[1],
                                                    pngPath: options.inputs[2])
        print("wrote \(options.inputs[2]) with \(count) contour(s)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

/// Turn a sticker PNG into a PLT cut file, without touching the printer.
func cut(_ options: Options) {
    guard options.inputs.count == 2 else {
        print("usage: cricut-bt cut <sticker.png> <out.plt>")
        exit(2)
    }
    do {
        let count = try SheetBuilder.buildCutFile(pngPath: options.inputs[0], pltPath: options.inputs[1])
        print("wrote \(options.inputs[1]) with \(count) contour(s)")
        print(try SheetBuilder.describe(pngPath: options.inputs[0]))
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

func describe(_ value: Any?) -> String {
    switch value {
    case nil: return "null"
    case let s as String: return s
    case let b as Bool: return b ? "true" : "false"
    case let n as NSNumber: return n.stringValue
    case let list as [Any]: return list.map { describe($0) }.joined(separator: ", ")
    case let dict as [String: Any]:
        return dict.map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ")
    default: return String(describing: value!)
    }
}

// MARK: - Entry point

let options = parseOptions()

// Only commands that talk to the printer touch Bluetooth. Offline commands
// (sheet, sheet-layout, preview, cut, selftest) must not: the first IOBluetooth
// call can block on a macOS permission prompt, which would hang a sheet build.
switch options.command {
case "discover":
    guard let device = BluetoothTransport.device(address: options.address) else {
        print("printer \(options.address) is not in the paired-device list.")
        exit(1)
    }
    discover(device)
case "status":
    status(options)
case "cut":
    cut(options)
case "sheet":
    sheet(options)
case "sheet-layout":
    sheetFromLayout(options)
case "preview":
    preview(options)
case "print":
    printSheet(options)
case "probe":
    probe(options)
case "props":
    props(options)
case "selftest":
    exit(runSelfTest())
default:
    print("unknown command '\(options.command)'\n")
    printUsage()
    exit(2)
}
