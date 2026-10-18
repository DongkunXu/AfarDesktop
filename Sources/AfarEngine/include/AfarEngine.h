// AfarEngine: a small C interface over FreeRDP for the Swift app.
//
// One AfarSession is one RDP connection. It runs FreeRDP on its own thread and reports back
// through AfarCallbacks, invoked on FreeRDP's threads. Callbacks marked "blocking" wait for
// an answer, so the app may show a dialog before returning.
// Every other function may be called from any thread.

#ifndef AFAR_ENGINE_H
#define AFAR_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <IOSurface/IOSurfaceRef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AfarSession AfarSession;

typedef enum {
    AfarStateConnecting = 0,
    AfarStateConnected = 1,
    AfarStateDisconnected = 2,
} AfarState;

// Why a session ended, grouped for presentation.
typedef enum {
    AfarEndedNormally = 0,   // closed by us, or the remote user signed out
    AfarEndedAuthentication, // wrong name or password, account problems
    AfarEndedCertificate,    // the certificate was not accepted
    AfarEndedHostNotFound,   // the name does not resolve
    AfarEndedUnreachable,    // no answer, refused, or the connection could not be secured
    AfarEndedReplaced,       // another client took over the session
    AfarEndedTimeout,        // idle or logon timeout on the server
    AfarEndedServerDenied,   // the server refused this user or client
    AfarEndedNetworkLost,    // an established connection dropped
    AfarEndedOther,
} AfarEndReason;

typedef enum {
    AfarCertificateReject = 0,
    AfarCertificateAcceptAlways = 1,
    AfarCertificateAcceptOnce = 2,
} AfarCertificateDecision;

typedef enum {
    AfarCursorDefault = 0,
    AfarCursorHidden = 1,
    AfarCursorCustom = 2,
} AfarCursorKind;

typedef enum {
    AfarMouseLeft = 0,
    AfarMouseRight = 1,
    AfarMouseMiddle = 2,
    AfarMouseBack = 3,
    AfarMouseForward = 4,
} AfarMouseButton;

// Remote clipboard content handed to the app.
typedef enum {
    AfarClipboardText = 0, // UTF-16LE, may end with a NUL
    AfarClipboardPNG = 1,  // a PNG file
    AfarClipboardDIB = 2,  // a Windows device-independent bitmap (BITMAPINFO + pixels)
} AfarClipboardKind;

// How the server encodes the desktop image.
typedef enum {
    AfarCodecNone = 0, // no graphics updates
    AfarCodecUncompressed,
    AfarCodecPlanar,
    AfarCodecClearCodec,
    AfarCodecRemoteFX,
    AfarCodecProgressive, // RemoteFX Progressive
    AfarCodecAVC420,      // H.264
    AfarCodecAVC444,      // H.264 with full colour resolution (AVC444 and AVC444v2)
    AfarCodecAlpha,
    AfarCodecOther,
} AfarCodec;

typedef struct {
    // Totals since the session started.
    uint64_t bytesReceived; // RDP traffic, inside TLS
    uint64_t bytesSent;
    uint64_t frames;            // desktop images presented
    uint64_t decodeNanoseconds; // spent decoding graphics updates

    // The codec most graphics updates used since the previous call.
    AfarCodec codec;

    // The TCP connection carrying the session, as the system sees it. Valid when
    // `hasConnectionInfo`; totals start again when the session reconnects.
    bool hasConnectionInfo;
    uint32_t roundTripMs; // smoothed
    uint32_t roundTripVarianceMs;
    uint64_t packetsSent;
    uint64_t packetsRetransmitted;
    uint64_t wireBytesReceived;
    uint64_t outOfOrderBytes; // received ahead of a gap, usually a lost packet
} AfarStatistics;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username; // may be NULL: the engine asks through `authenticate`
    const char *domain;   // may be NULL
    const char *password; // may be NULL: the engine asks through `authenticate`

    uint32_t width;  // initial desktop size in pixels
    uint32_t height;
    uint32_t desktopScale; // percent, 100-500: how large the remote desktop draws its UI
    uint32_t deviceScale;  // percent, 100, 140 or 180

    bool fullColor; // offer H.264 with full colour resolution (AVC444), not only AVC420
    bool audio;     // play remote audio on this Mac
    bool clipboard; // share the clipboard

    // Remote Desktop Gateway; NULL host for a direct connection.
    const char *gatewayHost;
    uint16_t gatewayPort;
    const char *gatewayUsername; // NULL: use the computer's credentials for the gateway too
    const char *gatewayDomain;
    const char *gatewayPassword;

    const char *configDirectory; // FreeRDP's own state (accepted certificates)
} AfarConnectParams;

typedef struct {
    const char *host;
    uint16_t port;
    const char *commonName;
    const char *subject;
    const char *issuer;
    const char *fingerprint;
    bool changed; // a different certificate was accepted for this host before
    const char *oldSubject;
    const char *oldIssuer;
    const char *oldFingerprint;
} AfarCertificateInfo;

typedef struct {
    void *context;

    void (*stateChanged)(void *context, AfarState state, uint32_t errorCode, const char *message);

    // The desktop image (BGRA, desktop size) arrives in a surface the app should show as is.
    // `surfaceChanged` reports a new desktop size, `frameUpdated` a new image. The engine keeps
    // writing to a small set of surfaces in turn; retain the one being shown.
    void (*surfaceChanged)(void *context, IOSurfaceRef surface, uint32_t width, uint32_t height);
    void (*frameUpdated)(void *context, IOSurfaceRef surface);

    // blocking
    AfarCertificateDecision (*verifyCertificate)(void *context, const AfarCertificateInfo *info);

    // blocking. Fill in the buffers (NUL-terminated) and return true to continue, false to cancel.
    bool (*authenticate)(void *context, bool gateway, char *username, size_t usernameSize,
                         char *password, size_t passwordSize, char *domain, size_t domainSize);

    // Cursor images are BGRA, premultiplied, in remote pixels. `cursorId` stays valid until
    // `cursorReleased` reports it.
    void (*cursorCreated)(void *context, uint64_t cursorId, const uint8_t *bgra, uint32_t width,
                          uint32_t height, uint32_t hotX, uint32_t hotY);
    void (*cursorReleased)(void *context, uint64_t cursorId);
    void (*cursorChanged)(void *context, AfarCursorKind kind, uint64_t cursorId);

    // The server accepts layout changes from now on.
    void (*displayControlReady)(void *context);

    // Something was copied on the remote computer. `data` is only valid during the call.
    void (*clipboardReceived)(void *context, AfarClipboardKind kind, const uint8_t *data,
                              size_t length);

    // Files were copied on the remote computer; `afar_session_fetch_remote_files` downloads them.
    void (*clipboardFilesOffered)(void *context, uint32_t count, uint64_t totalBytes);
    void (*clipboardFilesProgress)(void *context, uint64_t doneBytes, uint64_t totalBytes);
    void (*clipboardFilesFinished)(void *context, bool success);
} AfarCallbacks;

AfarEndReason afar_end_reason(uint32_t errorCode);

// Must be called once before any session is created.
bool afar_engine_initialize(void);

AfarSession *afar_session_new(const AfarCallbacks *callbacks);
// Starts connecting in the background. Returns false if the session could not be set up.
bool afar_session_connect(AfarSession *session, const AfarConnectParams *params);
// Asks the session to end; `stateChanged(Disconnected)` follows.
void afar_session_disconnect(AfarSession *session);
// Waits for the session thread to finish and frees everything. Never call it from a callback.
void afar_session_free(AfarSession *session);

// Keyboard: macOS virtual key codes (NSEvent.keyCode).
void afar_session_send_key(AfarSession *session, uint16_t macKeyCode, bool down);
// Releases every key and button the remote side still considers pressed.
void afar_session_release_all(AfarSession *session);

// Mouse: positions in remote desktop pixels.
void afar_session_send_mouse_move(AfarSession *session, int32_t x, int32_t y);
void afar_session_send_mouse_button(AfarSession *session, AfarMouseButton button, bool down,
                                    int32_t x, int32_t y);
// Wheel deltas in RDP units (120 per notch); positive is up / right.
void afar_session_send_wheel(AfarSession *session, int32_t vertical, int32_t horizontal,
                             int32_t x, int32_t y);

// Requests a new desktop size. Held back until the server accepts layout changes; repeated
// identical requests are dropped.
void afar_session_request_layout(AfarSession *session, uint32_t width, uint32_t height,
                                 uint32_t desktopScale, uint32_t deviceScale);

// Offers this Mac's clipboard to the remote computer. The engine keeps a copy and answers the
// server's requests from it. `utf8` may be NULL; `png` and `dib` describe the same image and
// may be NULL. Passing all NULL clears the offer.
void afar_session_offer_clipboard(AfarSession *session, const char *utf8, const uint8_t *png,
                                  size_t pngLength, const uint8_t *dib, size_t dibLength);

// Offers files from this Mac. `names` are the paths the remote side sees, relative to the copied
// items with '/' separators; directories come before their contents. Replaces any earlier offer.
void afar_session_offer_files(AfarSession *session, const char *const *paths,
                              const char *const *names, const bool *directories,
                              const uint64_t *sizes, size_t count);

// Downloads the files last announced through `clipboardFilesOffered` into `directory` (created if
// needed). Progress and completion arrive through the callbacks.
bool afar_session_fetch_remote_files(AfarSession *session, const char *directory);
void afar_session_cancel_remote_files(AfarSession *session);

// Reads the session's counters. Meant for one regular reader: `codec` covers the time since the
// previous call.
bool afar_session_get_statistics(AfarSession *session, AfarStatistics *statistics);

#ifdef __cplusplus
}
#endif

#endif
