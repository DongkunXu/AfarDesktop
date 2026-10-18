// Maps macOS virtual key codes (Carbon kVK_*) to RDP scancodes by physical key position.

#ifndef AFAR_KEYMAP_H
#define AFAR_KEYMAP_H

#include <stdint.h>
#include <freerdp/scancode.h>

// Returns RDP_SCANCODE_UNKNOWN for keys without a PC equivalent (fn, for example).
uint32_t afar_scancode_for_mac_keycode(uint16_t keyCode);

#endif
