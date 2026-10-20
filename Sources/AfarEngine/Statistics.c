// Connection statistics: traffic, frames, decoding time and the health of the TCP connection.

#include "Internal.h"

#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <time.h>

#include <freerdp/channels/rdpgfx.h>
#include <freerdp/gdi/gfx.h>

// MARK: - Socket

static int tcp_connect(rdpContext *context, rdpSettings *settings, const char *hostname, int port,
                       DWORD timeout) {
    AfarSession *s = afar_session_of(context);
    const int fd = s->counters.tcpConnect(context, settings, hostname, port, timeout);
    atomic_store(&s->counters.socket, fd);
    return fd;
}

bool afar_statistics_attach(AfarSession *s) {
    atomic_store(&s->counters.socket, -1);
    const rdpTransportIo *io = freerdp_get_io_callbacks(s->context);
    if (!io || !io->TCPConnect)
        return false;
    rdpTransportIo hooked = *io;
    s->counters.tcpConnect = io->TCPConnect;
    hooked.TCPConnect = tcp_connect;
    return freerdp_set_io_callbacks(s->context, &hooked);
}

void afar_statistics_connection_closed(AfarSession *s) {
    atomic_store(&s->counters.socket, -1);
}

// MARK: - Graphics

static AfarCodec codec_of(UINT16 codecId) {
    switch (codecId) {
        case RDPGFX_CODECID_UNCOMPRESSED: return AfarCodecUncompressed;
        case RDPGFX_CODECID_PLANAR: return AfarCodecPlanar;
        case RDPGFX_CODECID_CLEARCODEC: return AfarCodecClearCodec;
        case RDPGFX_CODECID_CAVIDEO: return AfarCodecRemoteFX;
        case RDPGFX_CODECID_CAPROGRESSIVE:
        case RDPGFX_CODECID_CAPROGRESSIVE_V2: return AfarCodecProgressive;
        case RDPGFX_CODECID_AVC420: return AfarCodecAVC420;
        case RDPGFX_CODECID_AVC444:
        case RDPGFX_CODECID_AVC444v2: return AfarCodecAVC444;
        case RDPGFX_CODECID_ALPHA: return AfarCodecAlpha;
        default: return AfarCodecOther;
    }
}

static UINT surface_command(RdpgfxClientContext *gfx, const RDPGFX_SURFACE_COMMAND *command) {
    const rdpGdi *gdi = gfx->custom;
    AfarSession *s = afar_session_of(gdi->context);
    const uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const UINT rc = s->counters.surfaceCommand(gfx, command);
    atomic_fetch_add_explicit(&s->counters.decodeNanoseconds,
                              clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->counters.codecUse[codec_of(command->codecId)], 1,
                              memory_order_relaxed);
    return rc;
}

// Called once FreeRDP's GDI has taken over the graphics channel.
void afar_statistics_graphics_connected(AfarSession *s, RdpgfxClientContext *gfx) {
    if (!gfx->SurfaceCommand || gfx->SurfaceCommand == surface_command)
        return;
    s->counters.surfaceCommand = gfx->SurfaceCommand;
    gfx->SurfaceCommand = surface_command;
}

// MARK: - Reading

bool afar_tcp_info(int fd, AfarStatistics *out) {
    struct tcp_connection_info info;
    socklen_t length = sizeof(info);
    if (fd < 0 || getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &length) != 0)
        return false;
    out->hasConnectionInfo = true;
    out->roundTripMs = info.tcpi_srtt;
    out->roundTripVarianceMs = info.tcpi_rttvar;
    out->packetsSent = info.tcpi_txpackets;
    out->packetsRetransmitted = info.tcpi_txretransmitpackets;
    out->wireBytesReceived = info.tcpi_rxbytes;
    out->outOfOrderBytes = info.tcpi_rxoutoforderbytes;
    return true;
}

bool afar_session_get_statistics(AfarSession *s, AfarStatistics *out) {
    if (!s || !out)
        return false;
    *out = (AfarStatistics){0};

    // FreeRDP counts traffic on the session thread without a lock; an aligned 64-bit read is at
    // worst one update behind.
    UINT64 received = 0, sent = 0;
    if (freerdp_get_stats(s->context->rdp, &received, &sent, NULL, NULL)) {
        out->bytesReceived = received;
        out->bytesSent = sent;
    }
    out->frames = atomic_load_explicit(&s->counters.frames, memory_order_relaxed);
    out->decodeNanoseconds = atomic_load_explicit(&s->counters.decodeNanoseconds, memory_order_relaxed);

    uint32_t most = 0;
    out->codec = AfarCodecNone;
    for (int i = AfarCodecNone + 1; i < AFAR_CODECS; i++) {
        const uint32_t uses = atomic_exchange_explicit(&s->counters.codecUse[i], 0, memory_order_relaxed);
        if (uses > most) {
            most = uses;
            out->codec = (AfarCodec)i;
        }
    }

    (void)afar_tcp_info(atomic_load(&s->counters.socket), out);
    return true;
}
