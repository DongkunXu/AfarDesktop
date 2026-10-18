// Shared between the engine's source files; not part of the public interface.

#ifndef AFAR_INTERNAL_H
#define AFAR_INTERNAL_H

#include "AfarEngine.h"

#include <pthread.h>
#include <stdatomic.h>

#include <freerdp/client.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/log.h>
#include <freerdp/transport_io.h>
#include <winpr/shell.h>

#define TAG CLIENT_TAG("afar")

typedef struct {
    rdpClientContext common;
    AfarSession *session;
} AfarContext;

typedef struct {
    uint32_t width, height, desktopScale, deviceScale;
} AfarLayout;

// The desktop image is presented through a small ring of surfaces: the engine writes into one
// the window is not showing, then hands it over. Each surface remembers the regions that
// changed since it was last written, so a frame copies only what that surface is missing.
#define AFAR_SURFACES 3
#define AFAR_MAX_STALE 64

typedef struct {
    IOSurfaceRef surface;
    GDI_RGN stale[AFAR_MAX_STALE];
    uint32_t staleCount;
    bool staleAll;
} AfarBuffer;

typedef struct {
    char *path;
    FILEDESCRIPTORW descriptor;
} AfarLocalFile;

// A download of the files the server announced, one range at a time.
typedef struct {
    bool active;
    char *directory;
    uint32_t index;    // file being fetched
    uint64_t offset;   // within that file
    uint64_t fileSize;
    int fd;            // -1 when no file is open
    uint32_t streamId; // of the request in flight
    uint64_t done, total;
} AfarDownload;

// What this Mac currently offers on the remote clipboard, and what the server offers.
typedef struct {
    pthread_mutex_t lock;
    CliprdrClientContext *channel;
    bool ready; // the server sent Monitor Ready

    uint32_t serverFlags; // general capability flags the server announced

    // Local content, copied when the app announces it (UTF-16LE text, PNG, DIB) or, for
    // files, described and read from disk on request.
    uint8_t *text;
    size_t textLength;
    uint8_t *png;
    size_t pngLength;
    uint8_t *dib;
    size_t dibLength;
    AfarLocalFile *localFiles;
    uint32_t localFileCount;

    // The server format being fetched and the server's ids for image and file formats.
    uint32_t requestedFormat;
    uint32_t serverPngFormat;
    uint32_t serverFileFormat;

    // Files the server announced, and their download.
    FILEDESCRIPTORW *remoteFiles;
    uint32_t remoteFileCount;
    AfarDownload download;
} AfarClipboard;

// Counters behind afar_session_get_statistics: written on FreeRDP's threads, read on the app's.
// Two FreeRDP functions are wrapped to collect them: the TCP connect (to learn the socket) and
// the GDI's surface command handler (to time decoding and see the codec).
#define AFAR_CODECS (AfarCodecOther + 1)

typedef struct {
    pTCPConnect tcpConnect;
    pcRdpgfxSurfaceCommand surfaceCommand;
    _Atomic int socket; // -1 when there is none
    _Atomic uint64_t frames;
    _Atomic uint64_t decodeNanoseconds;
    _Atomic uint32_t codecUse[AFAR_CODECS]; // graphics updates since the last reading
} AfarCounters;

struct AfarSession {
    AfarCallbacks cb;
    rdpContext *context;

    pthread_t thread;
    bool threadStarted;

    // Guards input and display control: requests arrive from the app's threads.
    pthread_mutex_t lock;
    bool inputReady;
    DispClientContext *disp;
    bool dispReady;
    AfarLayout lastLayout;
    AfarLayout pendingLayout;
    bool hasPendingLayout;
    bool keysDown[512]; // indexed by RDP scancode (extended bit folded into bit 8)
    uint32_t buttonsDown;
    int32_t mouseX, mouseY;

    AfarClipboard clipboard;
    AfarCounters counters;

    // Touched only on the session thread.
    AfarBuffer buffers[AFAR_SURFACES];
    uint32_t nextBuffer;
    uint64_t nextCursorId;
};

static inline AfarSession *afar_session_of(rdpContext *context) {
    return context ? ((AfarContext *)context)->session : NULL;
}

// Display.c
BOOL afar_display_attach(rdpContext *context);
void afar_display_detach(AfarSession *s);
void afar_display_channel_connected(AfarSession *s, DispClientContext *disp);
void afar_display_channel_disconnected(AfarSession *s);

// Clipboard.c
void afar_clipboard_init(AfarSession *s);
void afar_clipboard_channel_connected(AfarSession *s, CliprdrClientContext *channel);
void afar_clipboard_channel_disconnected(AfarSession *s);
void afar_clipboard_destroy(AfarSession *s);

// ClipboardFiles.c (all *_locked functions expect the clipboard lock to be held)
void afar_files_clear_local_locked(AfarClipboard *c);
bool afar_files_set_local_locked(AfarClipboard *c, const char *const *paths, const char *const *names,
                                 const bool *directories, const uint64_t *sizes, size_t count);
bool afar_files_serialize_locked(AfarClipboard *c, BYTE **data, UINT32 *length);
void afar_files_clear_remote_locked(AfarClipboard *c);
void afar_files_remote_list(AfarSession *s, const BYTE *data, UINT32 length);
UINT afar_files_serve(CliprdrClientContext *channel, const CLIPRDR_FILE_CONTENTS_REQUEST *request);
UINT afar_files_receive(CliprdrClientContext *channel, const CLIPRDR_FILE_CONTENTS_RESPONSE *response);

// Input.c
void afar_input_reset_locked(AfarSession *s);

// Statistics.c
bool afar_statistics_attach(AfarSession *s);
void afar_statistics_graphics_connected(AfarSession *s, RdpgfxClientContext *gfx);
void afar_statistics_connection_closed(AfarSession *s);

#endif
