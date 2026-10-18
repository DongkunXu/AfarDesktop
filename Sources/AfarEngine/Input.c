// Keyboard and mouse input. Every entry point takes the session lock: the app sends input from
// the main thread while FreeRDP connects and disconnects on the session thread.

#include "Internal.h"
#include "Keymap.h"

#include <string.h>

#include <freerdp/input.h>

static rdpInput *input_locked(AfarSession *s) {
    return (s->inputReady && s->context) ? s->context->input : NULL;
}

static UINT16 coordinate(int32_t value) {
    return (UINT16)(value < 0 ? 0 : (value > UINT16_MAX ? UINT16_MAX : value));
}

static void send_scancode_locked(AfarSession *s, rdpInput *input, UINT32 scancode, bool down) {
    const size_t index = (scancode & 0xFF) | ((scancode & KBDEXT) ? 0x100 : 0);
    const bool repeat = down && s->keysDown[index];
    s->keysDown[index] = down;
    (void)freerdp_input_send_keyboard_event_ex(input, down, repeat, scancode);
}

static void send_button_locked(rdpInput *input, AfarMouseButton button, bool down, int32_t x,
                               int32_t y) {
    switch (button) {
        case AfarMouseLeft:
        case AfarMouseRight:
        case AfarMouseMiddle: {
            const UINT16 flag = button == AfarMouseLeft    ? PTR_FLAGS_BUTTON1
                                : button == AfarMouseRight ? PTR_FLAGS_BUTTON2
                                                           : PTR_FLAGS_BUTTON3;
            (void)freerdp_input_send_mouse_event(input, flag | (down ? PTR_FLAGS_DOWN : 0),
                                                 coordinate(x), coordinate(y));
            break;
        }
        case AfarMouseBack:
        case AfarMouseForward: {
            const UINT16 flag = button == AfarMouseBack ? PTR_XFLAGS_BUTTON1 : PTR_XFLAGS_BUTTON2;
            (void)freerdp_input_send_extended_mouse_event(input, flag | (down ? PTR_XFLAGS_DOWN : 0),
                                                          coordinate(x), coordinate(y));
            break;
        }
    }
}

// One wheel PDU carries at most 255 units in a 9-bit two's complement field.
static void send_wheel_axis_locked(rdpInput *input, UINT16 axisFlag, int32_t delta, UINT16 x,
                                   UINT16 y) {
    while (delta != 0) {
        const int32_t step = delta > 255 ? 255 : (delta < -255 ? -255 : delta);
        UINT16 flags = axisFlag;
        if (step < 0)
            flags |= PTR_FLAGS_WHEEL_NEGATIVE | (UINT16)((0x100 + step) & 0xFF);
        else
            flags |= (UINT16)step;
        (void)freerdp_input_send_mouse_event(input, flags, x, y);
        delta -= step;
    }
}

void afar_input_reset_locked(AfarSession *s) {
    memset(s->keysDown, 0, sizeof(s->keysDown));
    s->buttonsDown = 0;
}

void afar_session_send_key(AfarSession *s, uint16_t macKeyCode, bool down) {
    const UINT32 scancode = afar_scancode_for_mac_keycode(macKeyCode);
    if (scancode == RDP_SCANCODE_UNKNOWN)
        return;
    pthread_mutex_lock(&s->lock);
    rdpInput *input = input_locked(s);
    if (input)
        send_scancode_locked(s, input, scancode, down);
    pthread_mutex_unlock(&s->lock);
}

void afar_session_release_all(AfarSession *s) {
    pthread_mutex_lock(&s->lock);
    rdpInput *input = input_locked(s);
    if (input) {
        for (size_t i = 0; i < 512; i++) {
            if (s->keysDown[i])
                send_scancode_locked(s, input, (UINT32)((i & 0xFF) | ((i & 0x100) ? KBDEXT : 0)),
                                     false);
        }
        for (int b = AfarMouseLeft; b <= AfarMouseForward; b++) {
            if (s->buttonsDown & (1u << b))
                send_button_locked(input, (AfarMouseButton)b, false, s->mouseX, s->mouseY);
        }
        s->buttonsDown = 0;
    }
    pthread_mutex_unlock(&s->lock);
}

void afar_session_send_mouse_move(AfarSession *s, int32_t x, int32_t y) {
    pthread_mutex_lock(&s->lock);
    s->mouseX = x;
    s->mouseY = y;
    rdpInput *input = input_locked(s);
    if (input)
        (void)freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, coordinate(x), coordinate(y));
    pthread_mutex_unlock(&s->lock);
}

void afar_session_send_mouse_button(AfarSession *s, AfarMouseButton button, bool down, int32_t x,
                                    int32_t y) {
    pthread_mutex_lock(&s->lock);
    s->mouseX = x;
    s->mouseY = y;
    rdpInput *input = input_locked(s);
    if (input) {
        if (down)
            s->buttonsDown |= 1u << button;
        else
            s->buttonsDown &= ~(1u << button);
        send_button_locked(input, button, down, x, y);
    }
    pthread_mutex_unlock(&s->lock);
}

void afar_session_send_wheel(AfarSession *s, int32_t vertical, int32_t horizontal, int32_t x,
                             int32_t y) {
    pthread_mutex_lock(&s->lock);
    rdpInput *input = input_locked(s);
    if (input) {
        send_wheel_axis_locked(input, PTR_FLAGS_WHEEL, vertical, coordinate(x), coordinate(y));
        send_wheel_axis_locked(input, PTR_FLAGS_HWHEEL, horizontal, coordinate(x), coordinate(y));
    }
    pthread_mutex_unlock(&s->lock);
}
