import AfarEngine

/// Maps macOS virtual key codes to what VNC sends: an X11 keysym, chosen by physical key
/// position on a US layout (as the RDP client maps scancodes), and, for servers that take them,
/// the XT scancode, which lets the server apply its own keyboard layout.
enum VNCKeymap {
    struct Key {
        var keysym: UInt32
        /// With Shift held; 0 when Shift does not change the keysym.
        var shifted: UInt32 = 0
    }

    static func key(for macKeyCode: UInt16) -> Key? {
        table[macKeyCode]
    }

    static func scancode(for macKeyCode: UInt16) -> UInt32 {
        afar_xt_keycode_for_mac_keycode(macKeyCode)
    }

    static let shiftKeys: Set<UInt16> = [0x38, 0x3C]

    private static func character(_ lower: Character, _ upper: Character) -> Key {
        // Latin-1 characters have keysyms equal to their code points.
        Key(keysym: lower.unicodeScalars.first!.value, shifted: upper.unicodeScalars.first!.value)
    }

    private static let table: [UInt16: Key] = {
        var t: [UInt16: Key] = [:]
        let letters: [(UInt16, Character)] = [
            (0x00, "a"), (0x01, "s"), (0x02, "d"), (0x03, "f"), (0x04, "h"), (0x05, "g"), (0x06, "z"),
            (0x07, "x"), (0x08, "c"), (0x09, "v"), (0x0B, "b"), (0x0C, "q"), (0x0D, "w"), (0x0E, "e"),
            (0x0F, "r"), (0x10, "y"), (0x11, "t"), (0x1F, "o"), (0x20, "u"), (0x22, "i"), (0x23, "p"),
            (0x25, "l"), (0x26, "j"), (0x28, "k"), (0x2D, "n"), (0x2E, "m"),
        ]
        for (code, letter) in letters { t[code] = character(letter, Character(letter.uppercased())) }
        let symbols: [(UInt16, Character, Character)] = [
            (0x12, "1", "!"), (0x13, "2", "@"), (0x14, "3", "#"), (0x15, "4", "$"), (0x17, "5", "%"),
            (0x16, "6", "^"), (0x1A, "7", "&"), (0x1C, "8", "*"), (0x19, "9", "("), (0x1D, "0", ")"),
            (0x1B, "-", "_"), (0x18, "=", "+"), (0x21, "[", "{"), (0x1E, "]", "}"), (0x2A, "\\", "|"),
            (0x29, ";", ":"), (0x27, "'", "\""), (0x2B, ",", "<"), (0x2F, ".", ">"), (0x2C, "/", "?"),
            (0x32, "`", "~"), (0x0A, "<", ">"), // ISO section key
        ]
        for (code, plain, shifted) in symbols { t[code] = character(plain, shifted) }

        let special: [(UInt16, UInt32)] = [
            (0x24, 0xFF0D), (0x30, 0xFF09), (0x31, 0x0020), (0x33, 0xFF08), (0x35, 0xFF1B), // return tab space backspace escape
            (0x37, 0xFFEB), (0x36, 0xFFEC), // command: Super_L, Super_R
            (0x38, 0xFFE1), (0x3C, 0xFFE2), (0x39, 0xFFE5), // shift, caps lock
            (0x3A, 0xFFE9), (0x3D, 0xFFEA), (0x3B, 0xFFE3), (0x3E, 0xFFE4), // option (Alt), control
            (0x72, 0xFF63), (0x73, 0xFF50), (0x74, 0xFF55), (0x75, 0xFFFF), (0x77, 0xFF57), (0x79, 0xFF56), // insert home pgup delete end pgdn
            (0x7B, 0xFF51), (0x7C, 0xFF53), (0x7D, 0xFF54), (0x7E, 0xFF52), // arrows
            (0x6E, 0xFF67), // menu
            (0x41, 0xFFAE), (0x43, 0xFFAA), (0x45, 0xFFAB), (0x47, 0xFF7F), (0x4B, 0xFFAF), // keypad . * + clear(num lock) /
            (0x4C, 0xFF8D), (0x4E, 0xFFAD), (0x51, 0xFFBD), // keypad enter - =
            (0x52, 0xFFB0), (0x53, 0xFFB1), (0x54, 0xFFB2), (0x55, 0xFFB3), (0x56, 0xFFB4),
            (0x57, 0xFFB5), (0x58, 0xFFB6), (0x59, 0xFFB7), (0x5B, 0xFFB8), (0x5C, 0xFFB9), // keypad digits
            (0x48, 0x1008_FF13), (0x49, 0x1008_FF11), (0x4A, 0x1008_FF12), // volume up, down, mute
        ]
        for (code, keysym) in special { t[code] = Key(keysym: keysym) }

        // F1...F20 are consecutive keysyms from 0xFFBE.
        let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                                      0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (index, code) in functionKeys.enumerated() { t[code] = Key(keysym: 0xFFBE + UInt32(index)) }
        return t
    }()
}
