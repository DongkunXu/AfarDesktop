// Files over the clipboard (MS-RDPECLIP FileGroupDescriptorW / FileContents).
//
// Local files are announced as descriptors and read on demand when the server asks for a size or
// a byte range. Remote files are listed when the server announces them and downloaded only when
// the app asks, one range after another, into a directory the app chooses.

#include "Internal.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/file.h>
#include <winpr/string.h>

#define AFAR_RANGE_SIZE (4u * 1024u * 1024u)

// Windows FILETIME: 100 ns ticks since 1601.
static FILETIME filetime_from_unix(time_t seconds) {
    const uint64_t ticks = ((uint64_t)seconds + 11644473600ull) * 10000000ull;
    return (FILETIME){.dwLowDateTime = (DWORD)ticks, .dwHighDateTime = (DWORD)(ticks >> 32)};
}

// MARK: - Local files

void afar_files_clear_local_locked(AfarClipboard *c) {
    for (uint32_t i = 0; i < c->localFileCount; i++)
        free(c->localFiles[i].path);
    free(c->localFiles);
    c->localFiles = NULL;
    c->localFileCount = 0;
}

bool afar_files_set_local_locked(AfarClipboard *c, const char *const *paths,
                                 const char *const *names, const bool *directories,
                                 const uint64_t *sizes, size_t count) {
    if (count == 0 || count > UINT32_MAX)
        return false;
    c->localFiles = calloc(count, sizeof(AfarLocalFile));
    if (!c->localFiles)
        return false;
    for (size_t i = 0; i < count; i++) {
        AfarLocalFile *file = &c->localFiles[i];
        file->path = strdup(paths[i]);
        if (!file->path) {
            c->localFileCount = (uint32_t)i;
            afar_files_clear_local_locked(c);
            return false;
        }
        c->localFileCount = (uint32_t)i + 1;

        FILEDESCRIPTORW *d = &file->descriptor;
        d->dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_WRITESTIME | FD_PROGRESSUI;
        d->dwFileAttributes = directories[i] ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
        d->nFileSizeHigh = directories[i] ? 0 : (DWORD)(sizes[i] >> 32);
        d->nFileSizeLow = directories[i] ? 0 : (DWORD)sizes[i];
        struct stat info;
        if (stat(paths[i], &info) == 0)
            d->ftLastWriteTime = filetime_from_unix(info.st_mtime);

        // Windows separates path components with backslashes.
        char *windowsName = strdup(names[i]);
        if (!windowsName)
            return false;
        for (char *p = windowsName; *p; p++)
            if (*p == '/')
                *p = '\\';
        const SSIZE_T written = ConvertUtf8ToWChar(windowsName, d->cFileName, ARRAYSIZE(d->cFileName));
        free(windowsName);
        if (written < 0)
            return false;
    }
    return true;
}

bool afar_files_serialize_locked(AfarClipboard *c, BYTE **data, UINT32 *length) {
    if (c->localFileCount == 0)
        return false;
    FILEDESCRIPTORW *list = calloc(c->localFileCount, sizeof(FILEDESCRIPTORW));
    if (!list)
        return false;
    for (uint32_t i = 0; i < c->localFileCount; i++)
        list[i] = c->localFiles[i].descriptor;
    // The file-related flags both sides announced (FreeRDP refuses without stream support).
    const UINT32 flags = c->serverFlags & (CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS |
                                           CB_HUGE_FILE_SUPPORT_ENABLED);
    const UINT rc = cliprdr_serialize_file_list_ex(flags, list, c->localFileCount, data, length);
    free(list);
    return rc == CHANNEL_RC_OK;
}

static bool read_range(const char *path, uint64_t offset, uint32_t wanted, BYTE **data,
                       uint32_t *length) {
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    BYTE *buffer = malloc(wanted ? wanted : 1);
    ssize_t total = 0;
    while (buffer && (uint32_t)total < wanted) {
        const ssize_t n = pread(fd, buffer + total, wanted - (uint32_t)total, (off_t)offset + total);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        total += n;
    }
    close(fd);
    if (!buffer)
        return false;
    *data = buffer;
    *length = (uint32_t)total;
    return true;
}

UINT afar_files_serve(CliprdrClientContext *channel, const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    AfarSession *s = channel->custom;
    AfarClipboard *c = &s->clipboard;

    CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    response.streamId = request->streamId;

    BYTE sizeBuffer[8];
    BYTE *range = NULL;

    pthread_mutex_lock(&c->lock);
    char *path = request->listIndex < c->localFileCount ? strdup(c->localFiles[request->listIndex].path) : NULL;
    pthread_mutex_unlock(&c->lock);

    if (path && (request->dwFlags & FILECONTENTS_SIZE)) {
        struct stat info;
        if (stat(path, &info) == 0) {
            const uint64_t size = (uint64_t)info.st_size;
            for (int i = 0; i < 8; i++)
                sizeBuffer[i] = (BYTE)(size >> (8 * i));
            response.common.msgFlags = CB_RESPONSE_OK;
            response.cbRequested = 8;
            response.common.dataLen = 8;
            response.requestedData = sizeBuffer;
        }
    } else if (path && (request->dwFlags & FILECONTENTS_RANGE)) {
        const uint64_t offset = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
        uint32_t length = 0;
        if (read_range(path, offset, request->cbRequested, &range, &length)) {
            response.common.msgFlags = CB_RESPONSE_OK;
            response.cbRequested = length;
            response.common.dataLen = length;
            response.requestedData = range;
        }
    }
    free(path);
    const UINT rc = channel->ClientFileContentsResponse(channel, &response);
    free(range);
    return rc;
}

// MARK: - Remote files

static void finish_download_locked(AfarClipboard *c) {
    if (c->download.fd >= 0)
        close(c->download.fd);
    free(c->download.directory);
    c->download = (AfarDownload){.fd = -1};
}

void afar_files_clear_remote_locked(AfarClipboard *c) {
    free(c->remoteFiles);
    c->remoteFiles = NULL;
    c->remoteFileCount = 0;
    finish_download_locked(c);
}

static uint64_t descriptor_size(const FILEDESCRIPTORW *d) {
    return ((uint64_t)d->nFileSizeHigh << 32) | d->nFileSizeLow;
}

static bool is_directory(const FILEDESCRIPTORW *d) {
    return (d->dwFlags & FD_ATTRIBUTES) && (d->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
}

void afar_files_remote_list(AfarSession *s, const BYTE *data, UINT32 length) {
    AfarClipboard *c = &s->clipboard;
    FILEDESCRIPTORW *files = NULL;
    UINT32 count = 0;
    if (cliprdr_parse_file_list(data, length, &files, &count) != CHANNEL_RC_OK || count == 0) {
        free(files);
        return;
    }
    uint64_t total = 0;
    for (UINT32 i = 0; i < count; i++)
        if (!is_directory(&files[i]))
            total += descriptor_size(&files[i]);

    pthread_mutex_lock(&c->lock);
    afar_files_clear_remote_locked(c);
    c->remoteFiles = files;
    c->remoteFileCount = count;
    pthread_mutex_unlock(&c->lock);

    if (s->cb.clipboardFilesOffered)
        s->cb.clipboardFilesOffered(s->cb.context, count, total);
}

// The local path for a remote name: inside the download directory, with "..", empty and
// absolute components dropped so a hostile list cannot write elsewhere.
static char *local_path(const char *directory, const WCHAR *name) {
    char *utf8 = ConvertWCharNToUtf8Alloc(name, 260, NULL);
    if (!utf8)
        return NULL;
    size_t size = strlen(directory) + strlen(utf8) + 2;
    char *path = malloc(size);
    if (!path) {
        free(utf8);
        return NULL;
    }
    strlcpy(path, directory, size);
    char *saveptr = NULL;
    for (char *part = strtok_r(utf8, "\\/", &saveptr); part; part = strtok_r(NULL, "\\/", &saveptr)) {
        if (strcmp(part, ".") == 0 || strcmp(part, "..") == 0 || part[0] == '\0')
            continue;
        strlcat(path, "/", size);
        strlcat(path, part, size);
    }
    free(utf8);
    return path;
}

static void make_parent_directories(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            (void)mkdir(path, 0755);
            *p = '/';
        }
    }
}

// Requests the next range, opening the next file when the current one is complete.
// Returns false when every file is done or on failure (`*failed` tells which).
static bool request_next_locked(AfarClipboard *c, bool *failed) {
    *failed = false;
    AfarDownload *d = &c->download;
    while (d->index < c->remoteFileCount) {
        const FILEDESCRIPTORW *file = &c->remoteFiles[d->index];
        if (d->fd < 0) {
            char *path = local_path(d->directory, file->cFileName);
            if (!path) {
                *failed = true;
                return false;
            }
            make_parent_directories(path);
            if (is_directory(file)) {
                (void)mkdir(path, 0755);
                free(path);
                d->index++;
                continue;
            }
            d->fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
            free(path);
            if (d->fd < 0) {
                *failed = true;
                return false;
            }
            d->offset = 0;
            d->fileSize = descriptor_size(file);
        }
        if (d->offset >= d->fileSize) {
            close(d->fd);
            d->fd = -1;
            d->index++;
            continue;
        }

        const uint64_t remaining = d->fileSize - d->offset;
        CLIPRDR_FILE_CONTENTS_REQUEST request = {0};
        request.common.msgType = CB_FILECONTENTS_REQUEST;
        request.streamId = ++d->streamId;
        request.listIndex = d->index;
        request.dwFlags = FILECONTENTS_RANGE;
        request.nPositionLow = (UINT32)d->offset;
        request.nPositionHigh = (UINT32)(d->offset >> 32);
        request.cbRequested = remaining < AFAR_RANGE_SIZE ? (UINT32)remaining : AFAR_RANGE_SIZE;
        if (c->channel->ClientFileContentsRequest(c->channel, &request) != CHANNEL_RC_OK) {
            *failed = true;
            return false;
        }
        return true;
    }
    return false;
}

UINT afar_files_receive(CliprdrClientContext *channel, const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
    AfarSession *s = channel->custom;
    AfarClipboard *c = &s->clipboard;

    pthread_mutex_lock(&c->lock);
    AfarDownload *d = &c->download;
    if (!d->active || response->streamId != d->streamId) {
        pthread_mutex_unlock(&c->lock);
        return CHANNEL_RC_OK; // a reply to a cancelled transfer
    }

    bool failed = (response->common.msgFlags & CB_RESPONSE_FAIL) || d->fd < 0;
    if (!failed && response->cbRequested > 0) {
        size_t written = 0;
        while (written < response->cbRequested) {
            const ssize_t n = write(d->fd, response->requestedData + written, response->cbRequested - written);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0) {
                failed = true;
                break;
            }
            written += (size_t)n;
        }
        d->offset += response->cbRequested;
        d->done += response->cbRequested;
    } else if (!failed) {
        d->offset = d->fileSize; // the file is shorter than announced
    }

    bool more = false;
    if (!failed)
        more = request_next_locked(c, &failed);
    const uint64_t done = d->done, total = d->total;
    if (!more)
        finish_download_locked(c);
    pthread_mutex_unlock(&c->lock);

    if (more) {
        if (s->cb.clipboardFilesProgress)
            s->cb.clipboardFilesProgress(s->cb.context, done, total);
    } else if (s->cb.clipboardFilesFinished) {
        s->cb.clipboardFilesFinished(s->cb.context, !failed);
    }
    return CHANNEL_RC_OK;
}

bool afar_session_fetch_remote_files(AfarSession *s, const char *directory) {
    AfarClipboard *c = &s->clipboard;
    pthread_mutex_lock(&c->lock);
    finish_download_locked(c);
    bool started = false, failed = false;
    const bool hasFiles = c->remoteFileCount > 0;
    if (c->channel && hasFiles && directory) {
        c->download.directory = strdup(directory);
        c->download.active = c->download.directory != NULL;
        for (uint32_t i = 0; i < c->remoteFileCount; i++)
            if (!is_directory(&c->remoteFiles[i]))
                c->download.total += descriptor_size(&c->remoteFiles[i]);
        if (c->download.active) {
            (void)mkdir(directory, 0755);
            started = request_next_locked(c, &failed);
        }
        if (!started)
            finish_download_locked(c);
    }
    pthread_mutex_unlock(&c->lock);

    // Only directories or empty files: complete at once.
    if (!started && !failed && hasFiles && s->cb.clipboardFilesFinished)
        s->cb.clipboardFilesFinished(s->cb.context, true);
    return started || !failed;
}

void afar_session_cancel_remote_files(AfarSession *s) {
    pthread_mutex_lock(&s->clipboard.lock);
    finish_download_locked(&s->clipboard);
    pthread_mutex_unlock(&s->clipboard.lock);
}
