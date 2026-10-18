// The desktop image, the remote cursor and the display control channel.

#include "Internal.h"

#include <stdlib.h>
#include <string.h>

#include <freerdp/channels/disp.h>
#include <freerdp/codec/color.h>
#include <freerdp/graphics.h>

typedef struct {
    rdpPointer pointer;
    uint64_t id;
} AfarPointer;

// MARK: - Surfaces

static IOSurfaceRef create_surface(uint32_t width, uint32_t height) {
    const int32_t bpe = 4;
    const int32_t w = (int32_t)width, h = (int32_t)height;
    const int32_t fourcc = 'BGRA';
    CFNumberRef nw = CFNumberCreate(NULL, kCFNumberSInt32Type, &w);
    CFNumberRef nh = CFNumberCreate(NULL, kCFNumberSInt32Type, &h);
    CFNumberRef nb = CFNumberCreate(NULL, kCFNumberSInt32Type, &bpe);
    CFNumberRef nf = CFNumberCreate(NULL, kCFNumberSInt32Type, &fourcc);
    const void *keys[] = {kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement,
                          kIOSurfacePixelFormat};
    const void *values[] = {nw, nh, nb, nf};
    CFDictionaryRef props = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);
    CFRelease(nw);
    CFRelease(nh);
    CFRelease(nb);
    CFRelease(nf);
    return surface;
}

// Copies a region of the FreeRDP framebuffer into a surface.
static void blit(IOSurfaceRef surface, rdpGdi *gdi, int32_t x, int32_t y, int32_t w, int32_t h) {
    if (!gdi->primary_buffer)
        return;
    const int32_t sw = (int32_t)IOSurfaceGetWidth(surface);
    const int32_t sh = (int32_t)IOSurfaceGetHeight(surface);
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > sw) w = sw - x;
    if (y + h > sh) h = sh - y;
    if (w <= 0 || h <= 0)
        return;

    uint8_t *dst = IOSurfaceGetBaseAddress(surface);
    const size_t dstStride = IOSurfaceGetBytesPerRow(surface);
    const uint8_t *src = gdi->primary_buffer;
    const size_t srcStride = gdi->stride;
    for (int32_t row = y; row < y + h; row++)
        memcpy(dst + (size_t)row * dstStride + (size_t)x * 4,
               src + (size_t)row * srcStride + (size_t)x * 4, (size_t)w * 4);
}

static void release_buffers(AfarSession *s) {
    for (int i = 0; i < AFAR_SURFACES; i++) {
        if (s->buffers[i].surface)
            CFRelease(s->buffers[i].surface);
        s->buffers[i] = (AfarBuffer){0};
    }
}

static void mark_stale(AfarSession *s, const GDI_RGN *rect) {
    for (int i = 0; i < AFAR_SURFACES; i++) {
        AfarBuffer *b = &s->buffers[i];
        if (b->staleAll)
            continue;
        if (b->staleCount == AFAR_MAX_STALE)
            b->staleAll = true;
        else
            b->stale[b->staleCount++] = *rect;
    }
}

// Brings the next surface up to date and hands it to the app.
static void present(AfarSession *s, bool resized) {
    rdpGdi *gdi = s->context->gdi;
    AfarBuffer *b = &s->buffers[s->nextBuffer];
    if (!b->surface)
        return;
    s->nextBuffer = (s->nextBuffer + 1) % AFAR_SURFACES;

    IOSurfaceLock(b->surface, 0, NULL);
    if (b->staleAll) {
        blit(b->surface, gdi, 0, 0, (int32_t)IOSurfaceGetWidth(b->surface),
             (int32_t)IOSurfaceGetHeight(b->surface));
    } else {
        for (uint32_t i = 0; i < b->staleCount; i++)
            blit(b->surface, gdi, b->stale[i].x, b->stale[i].y, b->stale[i].w, b->stale[i].h);
    }
    IOSurfaceUnlock(b->surface, 0, NULL);
    b->staleCount = 0;
    b->staleAll = false;

    if (resized && s->cb.surfaceChanged)
        s->cb.surfaceChanged(s->cb.context, b->surface, (uint32_t)IOSurfaceGetWidth(b->surface),
                             (uint32_t)IOSurfaceGetHeight(b->surface));
    else if (!resized && s->cb.frameUpdated)
        s->cb.frameUpdated(s->cb.context, b->surface);
    if (!resized)
        atomic_fetch_add_explicit(&s->counters.frames, 1, memory_order_relaxed);
}

static bool replace_surfaces(AfarSession *s, uint32_t width, uint32_t height) {
    release_buffers(s);
    for (int i = 0; i < AFAR_SURFACES; i++) {
        s->buffers[i].surface = create_surface(width, height);
        if (!s->buffers[i].surface) {
            release_buffers(s);
            return false;
        }
        s->buffers[i].staleAll = true;
    }
    s->nextBuffer = 0;
    present(s, true);
    return true;
}

// MARK: - Painting

static BOOL begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd) {
        HGDI_WND hwnd = gdi->primary->hdc->hwnd;
        hwnd->invalid->null = TRUE;
        hwnd->ninvalid = 0;
    }
    return TRUE;
}

static BOOL end_paint(rdpContext *context) {
    AfarSession *s = afar_session_of(context);
    rdpGdi *gdi = context->gdi;
    if (!s || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
        return TRUE;

    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (hwnd->invalid->null)
        return TRUE;

    if (hwnd->ninvalid > 0) {
        for (UINT32 i = 0; i < hwnd->ninvalid; i++)
            mark_stale(s, &hwnd->cinvalid[i]);
    } else {
        mark_stale(s, hwnd->invalid);
    }
    present(s, false);
    return TRUE;
}

static BOOL desktop_resize(rdpContext *context) {
    AfarSession *s = afar_session_of(context);
    rdpSettings *settings = context->settings;
    const UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    const UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, w, h))
        return FALSE;
    return replace_surfaces(s, w, h);
}

// MARK: - Cursor

static BOOL pointer_new(rdpContext *context, rdpPointer *pointer) {
    AfarSession *s = afar_session_of(context);
    AfarPointer *p = (AfarPointer *)pointer;
    p->id = ++s->nextCursorId;
    if (pointer->width == 0 || pointer->height == 0)
        return TRUE;

    const size_t size = 4ull * pointer->width * pointer->height;
    uint8_t *bgra = calloc(1, size);
    if (!bgra)
        return FALSE;
    const BOOL ok = freerdp_image_copy_from_pointer_data(
        bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width, pointer->height, pointer->xorMaskData,
        pointer->lengthXorMask, pointer->andMaskData, pointer->lengthAndMask, pointer->xorBpp,
        &context->gdi->palette);
    if (ok && s->cb.cursorCreated)
        s->cb.cursorCreated(s->cb.context, p->id, bgra, pointer->width, pointer->height,
                            pointer->xPos, pointer->yPos);
    free(bgra);
    return ok;
}

static void pointer_free(rdpContext *context, rdpPointer *pointer) {
    AfarSession *s = afar_session_of(context);
    if (s && s->cb.cursorReleased)
        s->cb.cursorReleased(s->cb.context, ((AfarPointer *)pointer)->id);
}

static void report_cursor(rdpContext *context, AfarCursorKind kind, uint64_t id) {
    AfarSession *s = afar_session_of(context);
    if (s->cb.cursorChanged)
        s->cb.cursorChanged(s->cb.context, kind, id);
}

static BOOL pointer_set(rdpContext *context, rdpPointer *pointer) {
    if (pointer->width == 0 || pointer->height == 0)
        report_cursor(context, AfarCursorHidden, 0);
    else
        report_cursor(context, AfarCursorCustom, ((AfarPointer *)pointer)->id);
    return TRUE;
}

static BOOL pointer_set_null(rdpContext *context) {
    report_cursor(context, AfarCursorHidden, 0);
    return TRUE;
}

static BOOL pointer_set_default(rdpContext *context) {
    report_cursor(context, AfarCursorDefault, 0);
    return TRUE;
}

static BOOL pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    // The server moving the local pointer would fight the user; ignore it.
    (void)context;
    (void)x;
    (void)y;
    return TRUE;
}

// MARK: - Lifecycle

BOOL afar_display_attach(rdpContext *context) {
    AfarSession *s = afar_session_of(context);
    if (!gdi_init(context->instance, PIXEL_FORMAT_BGRA32))
        return FALSE;

    const rdpPointer pointer = {
        .size = sizeof(AfarPointer),
        .New = pointer_new,
        .Free = pointer_free,
        .Set = pointer_set,
        .SetNull = pointer_set_null,
        .SetDefault = pointer_set_default,
        .SetPosition = pointer_set_position,
    };
    graphics_register_pointer(context->graphics, &pointer);

    context->update->BeginPaint = begin_paint;
    context->update->EndPaint = end_paint;
    context->update->DesktopResize = desktop_resize;

    rdpSettings *settings = context->settings;
    return replace_surfaces(s, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                            freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
}

void afar_display_detach(AfarSession *s) {
    if (s->context->gdi)
        gdi_free(s->context->instance);
    release_buffers(s);
}

// MARK: - Display control

static UINT send_layout_locked(AfarSession *s, const AfarLayout *layout) {
    if (!s->disp || !s->dispReady || !s->disp->SendMonitorLayout)
        return CHANNEL_RC_OK;
    if (memcmp(layout, &s->lastLayout, sizeof(*layout)) == 0)
        return CHANNEL_RC_OK;

    DISPLAY_CONTROL_MONITOR_LAYOUT monitor = {0};
    monitor.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    monitor.Width = layout->width;
    monitor.Height = layout->height;
    monitor.Orientation = ORIENTATION_LANDSCAPE;
    monitor.DesktopScaleFactor = layout->desktopScale;
    monitor.DeviceScaleFactor = layout->deviceScale;
    const UINT rc = s->disp->SendMonitorLayout(s->disp, 1, &monitor);
    if (rc == CHANNEL_RC_OK)
        s->lastLayout = *layout;
    return rc;
}

static UINT display_control_caps(DispClientContext *disp, UINT32 maxMonitors, UINT32 factorA,
                                 UINT32 factorB) {
    (void)maxMonitors;
    (void)factorA;
    (void)factorB;
    AfarSession *s = disp->custom;
    pthread_mutex_lock(&s->lock);
    s->dispReady = true;
    if (s->hasPendingLayout) {
        s->hasPendingLayout = false;
        (void)send_layout_locked(s, &s->pendingLayout);
    }
    pthread_mutex_unlock(&s->lock);
    if (s->cb.displayControlReady)
        s->cb.displayControlReady(s->cb.context);
    return CHANNEL_RC_OK;
}

void afar_display_channel_connected(AfarSession *s, DispClientContext *disp) {
    disp->custom = s;
    disp->DisplayControlCaps = display_control_caps;
    pthread_mutex_lock(&s->lock);
    s->disp = disp;
    pthread_mutex_unlock(&s->lock);
}

void afar_display_channel_disconnected(AfarSession *s) {
    pthread_mutex_lock(&s->lock);
    s->disp = NULL;
    s->dispReady = false;
    memset(&s->lastLayout, 0, sizeof(s->lastLayout));
    pthread_mutex_unlock(&s->lock);
}

void afar_session_request_layout(AfarSession *s, uint32_t width, uint32_t height,
                                 uint32_t desktopScale, uint32_t deviceScale) {
    // MS-RDPEDISP: width must be even, both within 200...8192.
    width &= ~1u;
    if (width < DISPLAY_CONTROL_MIN_MONITOR_WIDTH) width = DISPLAY_CONTROL_MIN_MONITOR_WIDTH;
    if (width > DISPLAY_CONTROL_MAX_MONITOR_WIDTH) width = DISPLAY_CONTROL_MAX_MONITOR_WIDTH;
    if (height < DISPLAY_CONTROL_MIN_MONITOR_HEIGHT) height = DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
    if (height > DISPLAY_CONTROL_MAX_MONITOR_HEIGHT) height = DISPLAY_CONTROL_MAX_MONITOR_HEIGHT;

    const AfarLayout layout = {width, height, desktopScale, deviceScale};
    pthread_mutex_lock(&s->lock);
    if (s->dispReady) {
        (void)send_layout_locked(s, &layout);
    } else {
        s->pendingLayout = layout;
        s->hasPendingLayout = true;
    }
    pthread_mutex_unlock(&s->lock);
}
