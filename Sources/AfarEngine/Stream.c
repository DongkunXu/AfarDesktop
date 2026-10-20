// AfarStream: a TCP connection with optional TLS for the VNC client.
//
// The socket is non-blocking. One thread reads; while it waits it also sends whatever other
// threads queued, so the TLS state is only ever used by the reading thread. A pipe wakes it up
// for new writes and for cancellation.

#include "Internal.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#define READ_BUFFER 65536

struct AfarStream {
    int fd;
    int wake[2]; // [0] polled by the reader, [1] written to wake it
    SSL_CTX *tlsContext;
    SSL *tls;
    atomic_bool cancelled;

    pthread_mutex_t lock; // guards the outgoing queue
    uint8_t *out;
    size_t outLength, outCapacity;

    uint8_t in[READ_BUFFER]; // received, not yet read
    size_t inStart, inEnd;

    _Atomic uint64_t received, sent, waitNanoseconds;
};

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void set_nonblocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

AfarStream *afar_stream_new(void) {
    AfarStream *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->fd = -1;
    if (pipe(s->wake) != 0) {
        free(s);
        return NULL;
    }
    set_nonblocking(s->wake[0]);
    set_nonblocking(s->wake[1]);
    pthread_mutex_init(&s->lock, NULL);
    return s;
}

void afar_stream_free(AfarStream *s) {
    if (!s)
        return;
    if (s->tls)
        SSL_free(s->tls);
    if (s->tlsContext)
        SSL_CTX_free(s->tlsContext);
    if (s->fd >= 0)
        close(s->fd);
    close(s->wake[0]);
    close(s->wake[1]);
    pthread_mutex_destroy(&s->lock);
    free(s->out);
    free(s);
}

static void wake(AfarStream *s) {
    const uint8_t byte = 1;
    (void)write(s->wake[1], &byte, 1); // a full pipe already means "wake up"
}

static void drain_wake(AfarStream *s) {
    uint8_t buffer[64];
    while (read(s->wake[0], buffer, sizeof(buffer)) > 0) {
    }
}

void afar_stream_cancel(AfarStream *s) {
    if (!s)
        return;
    atomic_store(&s->cancelled, true);
    wake(s);
}

// MARK: - Connecting

static AfarStreamStatus connect_address(AfarStream *s, const struct addrinfo *address, int timeoutMs) {
    const int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (fd < 0)
        return AfarStreamFailed;
    set_nonblocking(fd);
    const int on = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));

    if (connect(fd, address->ai_addr, address->ai_addrlen) != 0 && errno != EINPROGRESS) {
        const int error = errno;
        close(fd);
        return error == ECONNREFUSED ? AfarStreamRefused : AfarStreamFailed;
    }
    struct pollfd fds[2] = {{.fd = fd, .events = POLLOUT}, {.fd = s->wake[0], .events = POLLIN}};
    const int ready = poll(fds, 2, timeoutMs);
    if (atomic_load(&s->cancelled)) {
        close(fd);
        return AfarStreamCancelled;
    }
    if (ready <= 0) {
        close(fd);
        return ready == 0 ? AfarStreamTimeout : AfarStreamFailed;
    }
    int error = 0;
    socklen_t length = sizeof(error);
    (void)getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length);
    if (error != 0) {
        close(fd);
        return error == ECONNREFUSED ? AfarStreamRefused
               : error == ETIMEDOUT  ? AfarStreamTimeout
                                     : AfarStreamFailed;
    }
    s->fd = fd;
    return AfarStreamOK;
}

AfarStreamStatus afar_stream_connect(AfarStream *s, const char *host, uint16_t port, int timeoutMs) {
    if (!s || !host || s->fd >= 0)
        return AfarStreamFailed;
    char service[8];
    snprintf(service, sizeof(service), "%u", port);
    const struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM};
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, service, &hints, &addresses) != 0 || !addresses)
        return AfarStreamHostNotFound;

    AfarStreamStatus status = AfarStreamFailed;
    for (const struct addrinfo *a = addresses; a; a = a->ai_next) {
        status = connect_address(s, a, timeoutMs);
        if (status == AfarStreamOK || status == AfarStreamCancelled)
            break;
    }
    freeaddrinfo(addresses);
    return status;
}

// MARK: - Sending and receiving

void afar_stream_write(AfarStream *s, const void *data, size_t length) {
    if (!s || length == 0)
        return;
    pthread_mutex_lock(&s->lock);
    if (s->outLength + length > s->outCapacity) {
        size_t capacity = s->outCapacity ? s->outCapacity : 4096;
        while (capacity < s->outLength + length)
            capacity *= 2;
        uint8_t *grown = realloc(s->out, capacity);
        if (!grown) {
            pthread_mutex_unlock(&s->lock);
            return;
        }
        s->out = grown;
        s->outCapacity = capacity;
    }
    memcpy(s->out + s->outLength, data, length);
    s->outLength += length;
    pthread_mutex_unlock(&s->lock);
    wake(s);
}

// Sends as much of the queue as the socket takes now. `wantWrite` reports that bytes remain.
static AfarStreamStatus flush(AfarStream *s, bool *wantWrite) {
    *wantWrite = false;
    pthread_mutex_lock(&s->lock);
    AfarStreamStatus status = AfarStreamOK;
    while (s->outLength > 0) {
        ssize_t written;
        if (s->tls) {
            written = SSL_write(s->tls, s->out, (int)(s->outLength > INT32_MAX ? INT32_MAX : s->outLength));
            if (written <= 0) {
                const int error = SSL_get_error(s->tls, (int)written);
                if (error == SSL_ERROR_WANT_WRITE || error == SSL_ERROR_WANT_READ)
                    *wantWrite = true;
                else
                    status = AfarStreamClosed;
                break;
            }
        } else {
            written = send(s->fd, s->out, s->outLength, 0);
            if (written < 0) {
                if (errno == EAGAIN || errno == EINTR)
                    *wantWrite = true;
                else
                    status = AfarStreamClosed;
                break;
            }
        }
        memmove(s->out, s->out + written, s->outLength - (size_t)written);
        s->outLength -= (size_t)written;
        atomic_fetch_add(&s->sent, (uint64_t)written);
    }
    pthread_mutex_unlock(&s->lock);
    return status;
}

// Reads whatever the connection has into the buffer, waiting (and sending) as needed.
static AfarStreamStatus fill(AfarStream *s) {
    if (s->inStart == s->inEnd)
        s->inStart = s->inEnd = 0;
    const uint64_t start = now_ns();
    AfarStreamStatus status = AfarStreamOK;
    for (;;) {
        if (atomic_load(&s->cancelled)) {
            status = AfarStreamCancelled;
            break;
        }
        bool wantWrite;
        if ((status = flush(s, &wantWrite)) != AfarStreamOK)
            break;

        // TLS may already hold decrypted data the socket no longer signals.
        if (!s->tls || SSL_pending(s->tls) == 0) {
            struct pollfd fds[2] = {
                {.fd = s->fd, .events = (short)(POLLIN | (wantWrite ? POLLOUT : 0))},
                {.fd = s->wake[0], .events = POLLIN},
            };
            if (poll(fds, 2, -1) < 0 && errno != EINTR) {
                status = AfarStreamFailed;
                break;
            }
            if (fds[1].revents)
                drain_wake(s);
            if (!(fds[0].revents & (POLLIN | POLLHUP | POLLERR)))
                continue;
        }

        uint8_t *target = s->in + s->inEnd;
        const size_t room = READ_BUFFER - s->inEnd;
        ssize_t got;
        if (s->tls) {
            got = SSL_read(s->tls, target, (int)room);
            if (got <= 0) {
                const int error = SSL_get_error(s->tls, (int)got);
                if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE)
                    continue;
                status = AfarStreamClosed;
                break;
            }
        } else {
            got = recv(s->fd, target, room, 0);
            if (got < 0) {
                if (errno == EAGAIN || errno == EINTR)
                    continue;
                status = AfarStreamClosed;
                break;
            }
            if (got == 0) {
                status = AfarStreamClosed;
                break;
            }
        }
        s->inEnd += (size_t)got;
        atomic_fetch_add(&s->received, (uint64_t)got);
        break;
    }
    atomic_fetch_add(&s->waitNanoseconds, now_ns() - start);
    return status;
}

AfarStreamStatus afar_stream_read(AfarStream *s, void *buffer, size_t length) {
    if (!s || s->fd < 0)
        return AfarStreamFailed;
    uint8_t *target = buffer;
    while (length > 0) {
        if (s->inStart == s->inEnd) {
            const AfarStreamStatus status = fill(s);
            if (status != AfarStreamOK)
                return status;
        }
        size_t take = s->inEnd - s->inStart;
        if (take > length)
            take = length;
        memcpy(target, s->in + s->inStart, take);
        s->inStart += take;
        target += take;
        length -= take;
    }
    return AfarStreamOK;
}

// MARK: - TLS

static void describe_certificate(X509 *certificate, AfarPeerCertificate *peer) {
    memset(peer, 0, sizeof(*peer));
    X509_NAME *subject = X509_get_subject_name(certificate);
    X509_NAME_oneline(subject, peer->subject, sizeof(peer->subject));
    X509_NAME_oneline(X509_get_issuer_name(certificate), peer->issuer, sizeof(peer->issuer));
    X509_NAME_get_text_by_NID(subject, NID_commonName, peer->commonName, sizeof(peer->commonName));

    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digestLength = 0;
    if (X509_digest(certificate, EVP_sha256(), digest, &digestLength)) {
        char *p = peer->fingerprint;
        for (unsigned int i = 0; i < digestLength && (size_t)(p - peer->fingerprint) + 3 < sizeof(peer->fingerprint); i++)
            p += snprintf(p, 4, i ? ":%02x" : "%02x", digest[i]);
    }
}

static bool is_address(const char *host) {
    struct in6_addr v6;
    struct in_addr v4;
    return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1;
}

AfarStreamStatus afar_stream_start_tls(AfarStream *s, const char *serverName, bool anonymous,
                                       AfarPeerCertificate *peer) {
    if (!s || s->fd < 0 || s->tls)
        return AfarStreamFailed;

    // Everything queued so far belongs to the plain-text part of the conversation.
    for (;;) {
        bool wantWrite;
        const AfarStreamStatus status = flush(s, &wantWrite);
        if (status != AfarStreamOK)
            return status;
        if (!wantWrite)
            break;
        struct pollfd fds[2] = {{.fd = s->fd, .events = POLLOUT}, {.fd = s->wake[0], .events = POLLIN}};
        (void)poll(fds, 2, -1);
        if (atomic_load(&s->cancelled))
            return AfarStreamCancelled;
    }
    if (s->inStart != s->inEnd)
        return AfarStreamTLSFailed; // the server sent data before the handshake

    s->tlsContext = SSL_CTX_new(TLS_client_method());
    if (!s->tlsContext)
        return AfarStreamTLSFailed;
    SSL_CTX_set_verify(s->tlsContext, SSL_VERIFY_NONE, NULL); // the app decides on the certificate
    SSL_CTX_set_mode(s->tlsContext, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    if (anonymous) {
        // Anonymous suites exist up to TLS 1.2 and only at security level 0.
        SSL_CTX_set_max_proto_version(s->tlsContext, TLS1_2_VERSION);
        if (!SSL_CTX_set_cipher_list(s->tlsContext, "aNULL:!eNULL:@SECLEVEL=0"))
            return AfarStreamTLSFailed;
    }
    s->tls = SSL_new(s->tlsContext);
    if (!s->tls || !SSL_set_fd(s->tls, s->fd))
        return AfarStreamTLSFailed;
    if (!anonymous && serverName && *serverName && !is_address(serverName))
        SSL_set_tlsext_host_name(s->tls, serverName);

    for (;;) {
        const int result = SSL_connect(s->tls);
        if (result == 1)
            break;
        const int error = SSL_get_error(s->tls, result);
        if (error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE) {
            WLog_WARN(TAG, "VNC TLS handshake failed: %s", ERR_reason_error_string(ERR_peek_last_error()));
            return AfarStreamTLSFailed;
        }
        struct pollfd fds[2] = {
            {.fd = s->fd, .events = error == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT},
            {.fd = s->wake[0], .events = POLLIN},
        };
        (void)poll(fds, 2, -1);
        if (atomic_load(&s->cancelled))
            return AfarStreamCancelled;
    }

    if (peer) {
        memset(peer, 0, sizeof(*peer));
        X509 *certificate = SSL_get1_peer_certificate(s->tls);
        if (certificate) {
            describe_certificate(certificate, peer);
            X509_free(certificate);
        }
    }
    return AfarStreamOK;
}

// MARK: - Statistics

void afar_stream_statistics(AfarStream *s, AfarStatistics *out) {
    if (!s || !out)
        return;
    out->bytesReceived = atomic_load(&s->received);
    out->bytesSent = atomic_load(&s->sent);
    (void)afar_tcp_info(s->fd, out);
}

uint64_t afar_stream_wait_nanoseconds(AfarStream *s) {
    return s ? atomic_load(&s->waitNanoseconds) : 0;
}
