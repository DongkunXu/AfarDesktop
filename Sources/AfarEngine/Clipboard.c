// Clipboard sharing over the cliprdr channel (MS-RDPECLIP): text, images and files in both
// directions. Files are handled in ClipboardFiles.c.
//
// Local text and images are copied when the app offers them and served from that copy on
// request. Remote text and images are fetched as soon as the server announces them, in the
// richest format it offers; remote files are only listed until the app asks for them.

#include "Internal.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <winpr/string.h>
#include <winpr/user.h>

// Our ids for registered formats; registered format ids are chosen by each side.
#define AFAR_FORMAT_PNG 0xC0A1
#define AFAR_FORMAT_FILES 0xC0A2
static const char kPngFormat[] = "PNG";
static const char kFilesFormat[] = "FileGroupDescriptorW";

static AfarClipboard *clip(CliprdrClientContext *channel) {
    return &((AfarSession *)channel->custom)->clipboard;
}

static void clear_local_locked(AfarClipboard *c) {
    free(c->text);
    free(c->png);
    free(c->dib);
    c->text = c->png = c->dib = NULL;
    c->textLength = c->pngLength = c->dibLength = 0;
    afar_files_clear_local_locked(c);
}

// Announces what this Mac currently offers.
static void send_format_list_locked(AfarClipboard *c) {
    if (!c->channel || !c->ready)
        return;
    CLIPRDR_FORMAT formats[4] = {0};
    UINT32 count = 0;
    if (c->localFileCount)
        formats[count++] = (CLIPRDR_FORMAT){.formatId = AFAR_FORMAT_FILES, .formatName = (char *)kFilesFormat};
    if (c->text)
        formats[count++] = (CLIPRDR_FORMAT){.formatId = CF_UNICODETEXT};
    if (c->png)
        formats[count++] = (CLIPRDR_FORMAT){.formatId = AFAR_FORMAT_PNG, .formatName = (char *)kPngFormat};
    if (c->dib)
        formats[count++] = (CLIPRDR_FORMAT){.formatId = CF_DIB};

    CLIPRDR_FORMAT_LIST list = {0};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = count;
    list.formats = formats;
    (void)c->channel->ClientFormatList(c->channel, &list);
}

// MARK: - Server messages

static UINT monitor_ready(CliprdrClientContext *channel, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    AfarClipboard *c = clip(channel);

    CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED |
                           CB_FILECLIP_NO_FILE_PATHS | CB_HUGE_FILE_SUPPORT_ENABLED;
    CLIPRDR_CAPABILITIES caps = {0};
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;

    pthread_mutex_lock(&c->lock);
    (void)channel->ClientCapabilities(channel, &caps);
    c->ready = true;
    // The protocol expects a format list right after the capabilities, even an empty one.
    send_format_list_locked(c);
    pthread_mutex_unlock(&c->lock);
    return CHANNEL_RC_OK;
}

static UINT server_capabilities(CliprdrClientContext *channel, const CLIPRDR_CAPABILITIES *caps) {
    AfarClipboard *c = clip(channel);
    for (UINT32 i = 0; i < caps->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET *set = &caps->capabilitySets[i];
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL &&
            set->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN) {
            pthread_mutex_lock(&c->lock);
            c->serverFlags = ((const CLIPRDR_GENERAL_CAPABILITY_SET *)set)->generalFlags;
            pthread_mutex_unlock(&c->lock);
        }
    }
    return CHANNEL_RC_OK;
}

static bool named(const CLIPRDR_FORMAT *format, const char *name) {
    return format->formatName && strcasecmp(format->formatName, name) == 0;
}

static UINT server_format_list(CliprdrClientContext *channel, const CLIPRDR_FORMAT_LIST *list) {
    AfarClipboard *c = clip(channel);

    uint32_t files = 0, text = 0, png = 0, dib = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        const CLIPRDR_FORMAT *format = &list->formats[i];
        if (format->formatId == CF_UNICODETEXT)
            text = format->formatId;
        else if (format->formatId == CF_DIB)
            dib = format->formatId;
        else if (named(format, kFilesFormat))
            files = format->formatId;
        else if (named(format, kPngFormat) || named(format, "image/png"))
            png = format->formatId;
    }

    CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    (void)channel->ClientFormatListResponse(channel, &response);

    // Copied files also come with their names as text; the files are what was meant.
    const uint32_t wanted = files ? files : (text ? text : (png ? png : dib));

    pthread_mutex_lock(&c->lock);
    const bool cancelled = c->download.active;
    afar_files_clear_remote_locked(c); // the remote clipboard changed
    c->requestedFormat = wanted;
    c->serverPngFormat = png;
    c->serverFileFormat = files;
    pthread_mutex_unlock(&c->lock);
    AfarSession *s = channel->custom;
    if (cancelled && s->cb.clipboardFilesFinished)
        s->cb.clipboardFilesFinished(s->cb.context, false);
    if (!wanted)
        return CHANNEL_RC_OK;

    CLIPRDR_FORMAT_DATA_REQUEST request = {0};
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = wanted;
    return channel->ClientFormatDataRequest(channel, &request);
}

static UINT server_format_list_response(CliprdrClientContext *channel,
                                        const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)channel;
    (void)response;
    return CHANNEL_RC_OK;
}

static UINT server_format_data_request(CliprdrClientContext *channel,
                                       const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    AfarClipboard *c = clip(channel);
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;

    pthread_mutex_lock(&c->lock);
    const uint8_t *data = NULL;
    size_t length = 0;
    BYTE *files = NULL;
    switch (request->requestedFormatId) {
        case CF_UNICODETEXT:
            data = c->text;
            length = c->textLength;
            break;
        case CF_DIB:
            data = c->dib;
            length = c->dibLength;
            break;
        case AFAR_FORMAT_PNG:
            data = c->png;
            length = c->pngLength;
            break;
        case AFAR_FORMAT_FILES: {
            UINT32 filesLength = 0;
            if (afar_files_serialize_locked(c, &files, &filesLength)) {
                data = files;
                length = filesLength;
            }
            break;
        }
        default:
            break;
    }
    if (data && length <= UINT32_MAX) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)length;
        response.requestedFormatData = data;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    const UINT rc = channel->ClientFormatDataResponse(channel, &response);
    pthread_mutex_unlock(&c->lock);
    free(files);
    return rc;
}

static UINT server_format_data_response(CliprdrClientContext *channel,
                                        const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    AfarSession *s = channel->custom;
    AfarClipboard *c = &s->clipboard;
    if ((response->common.msgFlags & CB_RESPONSE_FAIL) || !response->requestedFormatData)
        return CHANNEL_RC_OK;

    pthread_mutex_lock(&c->lock);
    const uint32_t format = c->requestedFormat;
    const uint32_t png = c->serverPngFormat;
    const uint32_t files = c->serverFileFormat;
    c->requestedFormat = 0;
    pthread_mutex_unlock(&c->lock);

    if (format != 0 && format == files) {
        afar_files_remote_list(s, response->requestedFormatData, response->common.dataLen);
        return CHANNEL_RC_OK;
    }

    AfarClipboardKind kind;
    if (format == CF_UNICODETEXT)
        kind = AfarClipboardText;
    else if (format == CF_DIB)
        kind = AfarClipboardDIB;
    else if (format != 0 && format == png)
        kind = AfarClipboardPNG;
    else
        return CHANNEL_RC_OK;

    if (s->cb.clipboardReceived)
        s->cb.clipboardReceived(s->cb.context, kind, response->requestedFormatData,
                                response->common.dataLen);
    return CHANNEL_RC_OK;
}

// MARK: - Lifecycle

void afar_clipboard_init(AfarSession *s) {
    pthread_mutex_init(&s->clipboard.lock, NULL);
    s->clipboard.download.fd = -1;
}

void afar_clipboard_channel_connected(AfarSession *s, CliprdrClientContext *channel) {
    channel->custom = s;
    channel->MonitorReady = monitor_ready;
    channel->ServerCapabilities = server_capabilities;
    channel->ServerFormatList = server_format_list;
    channel->ServerFormatListResponse = server_format_list_response;
    channel->ServerFormatDataRequest = server_format_data_request;
    channel->ServerFormatDataResponse = server_format_data_response;
    channel->ServerFileContentsRequest = afar_files_serve;
    channel->ServerFileContentsResponse = afar_files_receive;
    pthread_mutex_lock(&s->clipboard.lock);
    s->clipboard.channel = channel;
    s->clipboard.ready = false;
    pthread_mutex_unlock(&s->clipboard.lock);
}

void afar_clipboard_channel_disconnected(AfarSession *s) {
    pthread_mutex_lock(&s->clipboard.lock);
    s->clipboard.channel = NULL;
    s->clipboard.ready = false;
    s->clipboard.requestedFormat = 0;
    afar_files_clear_remote_locked(&s->clipboard);
    pthread_mutex_unlock(&s->clipboard.lock);
}

void afar_clipboard_destroy(AfarSession *s) {
    clear_local_locked(&s->clipboard);
    afar_files_clear_remote_locked(&s->clipboard);
    pthread_mutex_destroy(&s->clipboard.lock);
}

// MARK: - Offering local content

void afar_session_offer_clipboard(AfarSession *s, const char *utf8, const uint8_t *png,
                                  size_t pngLength, const uint8_t *dib, size_t dibLength) {
    AfarClipboard *c = &s->clipboard;
    pthread_mutex_lock(&c->lock);
    clear_local_locked(c);
    if (utf8) {
        size_t characters = 0;
        WCHAR *text = ConvertUtf8ToWCharAlloc(utf8, &characters);
        if (text) {
            c->text = (uint8_t *)text;
            c->textLength = (characters + 1) * sizeof(WCHAR); // includes the NUL, as Windows does
        }
    }
    if (png && pngLength && (c->png = malloc(pngLength))) {
        memcpy(c->png, png, pngLength);
        c->pngLength = pngLength;
    }
    if (dib && dibLength && (c->dib = malloc(dibLength))) {
        memcpy(c->dib, dib, dibLength);
        c->dibLength = dibLength;
    }
    send_format_list_locked(c);
    pthread_mutex_unlock(&c->lock);
}

void afar_session_offer_files(AfarSession *s, const char *const *paths, const char *const *names,
                              const bool *directories, const uint64_t *sizes, size_t count) {
    AfarClipboard *c = &s->clipboard;
    pthread_mutex_lock(&c->lock);
    clear_local_locked(c);
    if (paths && names && directories && sizes &&
        !afar_files_set_local_locked(c, paths, names, directories, sizes, count))
        afar_files_clear_local_locked(c);
    send_format_list_locked(c);
    pthread_mutex_unlock(&c->lock);
}
