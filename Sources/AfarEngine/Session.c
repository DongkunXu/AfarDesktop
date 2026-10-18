// Session lifecycle: settings, the connection thread, authentication and certificates.

#include "Internal.h"

#include <stdlib.h>
#include <string.h>

#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/channels.h>
#include <freerdp/utils/helpers.h>
#include <winpr/synch.h>

// MARK: - Channels

static void channel_connected(void *ctx, const ChannelConnectedEventArgs *e) {
    AfarSession *s = afar_session_of(ctx);
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
        afar_display_channel_connected(s, e->pInterface);
    else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
        afar_clipboard_channel_connected(s, e->pInterface);
    else
        freerdp_client_OnChannelConnectedEventHandler(ctx, e);

    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
        afar_statistics_graphics_connected(s, e->pInterface);
}

static void channel_disconnected(void *ctx, const ChannelDisconnectedEventArgs *e) {
    AfarSession *s = afar_session_of(ctx);
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
        afar_display_channel_disconnected(s);
    else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
        afar_clipboard_channel_disconnected(s);
    else
        freerdp_client_OnChannelDisconnectedEventHandler(ctx, e);
}

// MARK: - Authentication and certificates

static BOOL authenticate(freerdp *instance, char **username, char **password, char **domain,
                         rdp_auth_reason reason) {
    AfarSession *s = afar_session_of(instance->context);
    if (!s->cb.authenticate)
        return FALSE;

    const bool gateway = reason == GW_AUTH_HTTP || reason == GW_AUTH_RDG || reason == GW_AUTH_RPC;
    char user[512] = {0}, pass[512] = {0}, dom[512] = {0};
    if (*username)
        strlcpy(user, *username, sizeof(user));
    if (*domain)
        strlcpy(dom, *domain, sizeof(dom));

    const bool proceed = s->cb.authenticate(s->cb.context, gateway, user, sizeof(user), pass,
                                            sizeof(pass), dom, sizeof(dom));
    if (proceed) {
        free(*username);
        free(*password);
        free(*domain);
        *username = strdup(user);
        *password = strdup(pass);
        *domain = dom[0] ? strdup(dom) : NULL;
    }
    memset(pass, 0, sizeof(pass));
    return proceed ? TRUE : FALSE;
}

static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                const char *common_name, const char *subject, const char *issuer,
                                const char *fingerprint, DWORD flags) {
    (void)flags;
    AfarSession *s = afar_session_of(instance->context);
    if (!s->cb.verifyCertificate)
        return AfarCertificateReject;
    const AfarCertificateInfo info = {
        .host = host, .port = port, .commonName = common_name, .subject = subject,
        .issuer = issuer, .fingerprint = fingerprint, .changed = false,
    };
    return (DWORD)s->cb.verifyCertificate(s->cb.context, &info);
}

static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                        const char *common_name, const char *subject,
                                        const char *issuer, const char *fingerprint,
                                        const char *old_subject, const char *old_issuer,
                                        const char *old_fingerprint, DWORD flags) {
    (void)flags;
    AfarSession *s = afar_session_of(instance->context);
    if (!s->cb.verifyCertificate)
        return AfarCertificateReject;
    const AfarCertificateInfo info = {
        .host = host, .port = port, .commonName = common_name, .subject = subject,
        .issuer = issuer, .fingerprint = fingerprint, .changed = true,
        .oldSubject = old_subject, .oldIssuer = old_issuer, .oldFingerprint = old_fingerprint,
    };
    return (DWORD)s->cb.verifyCertificate(s->cb.context, &info);
}

// The client library's defaults read from the terminal; a GUI app has none.
static BOOL present_gateway_message(freerdp *instance, UINT32 type, BOOL isDisplayMandatory,
                                    BOOL isConsentMandatory, size_t length, const WCHAR *message) {
    (void)instance;
    (void)type;
    (void)isDisplayMandatory;
    (void)isConsentMandatory;
    (void)length;
    (void)message;
    return TRUE;
}

static BOOL choose_smartcard(freerdp *instance, SmartcardCertInfo **certs, DWORD count,
                             DWORD *choice, BOOL gateway) {
    (void)instance;
    (void)certs;
    (void)count;
    (void)choice;
    (void)gateway;
    return FALSE;
}

static BOOL get_access_token(freerdp *instance, AccessTokenType type, char **token, size_t count,
                             ...) {
    (void)instance;
    (void)type;
    (void)count;
    *token = NULL;
    return FALSE;
}

static int logon_error_info(freerdp *instance, UINT32 data, UINT32 type) {
    (void)instance;
    WLog_INFO(TAG, "logon error info %s [%s]", freerdp_get_logon_error_info_data(data),
              freerdp_get_logon_error_info_type(type));
    return 1;
}

// MARK: - Connection lifecycle

static BOOL pre_connect(freerdp *instance) {
    rdpSettings *settings = instance->context->settings;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
        return FALSE;
    return PubSub_SubscribeChannelConnected(instance->context->pubSub, channel_connected) >= 0 &&
           PubSub_SubscribeChannelDisconnected(instance->context->pubSub, channel_disconnected) >= 0;
}

static BOOL post_connect(freerdp *instance) {
    AfarSession *s = afar_session_of(instance->context);
    if (!afar_display_attach(instance->context))
        return FALSE;

    pthread_mutex_lock(&s->lock);
    s->inputReady = true;
    pthread_mutex_unlock(&s->lock);

    if (s->cb.stateChanged)
        s->cb.stateChanged(s->cb.context, AfarStateConnected, 0, NULL);
    return TRUE;
}

static void post_disconnect(freerdp *instance) {
    rdpContext *context = instance->context;
    AfarSession *s = afar_session_of(context);

    pthread_mutex_lock(&s->lock);
    s->inputReady = false;
    afar_input_reset_locked(s);
    pthread_mutex_unlock(&s->lock);

    PubSub_UnsubscribeChannelConnected(context->pubSub, channel_connected);
    PubSub_UnsubscribeChannelDisconnected(context->pubSub, channel_disconnected);
    afar_display_detach(s);
    afar_statistics_connection_closed(s);
}

static BOOL client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->AuthenticateEx = authenticate;
    instance->VerifyCertificateEx = verify_certificate;
    instance->VerifyChangedCertificateEx = verify_changed_certificate;
    instance->PresentGatewayMessage = present_gateway_message;
    instance->ChooseSmartcard = choose_smartcard;
    instance->GetAccessToken = get_access_token;
    instance->LogonErrorInfo = logon_error_info;
    return TRUE;
}

static void *session_thread(void *arg) {
    AfarSession *s = arg;
    freerdp *instance = s->context->instance;

    if (s->cb.stateChanged)
        s->cb.stateChanged(s->cb.context, AfarStateConnecting, 0, NULL);

    if (freerdp_connect(instance)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {0};
        while (!freerdp_shall_disconnect_context(s->context)) {
            const DWORD count = freerdp_get_event_handles(s->context, handles, ARRAYSIZE(handles));
            if (count == 0)
                break;
            if (WaitForMultipleObjects(count, handles, FALSE, INFINITE) == WAIT_FAILED)
                break;
            if (!freerdp_check_event_handles(s->context))
                break;
        }
    }

    const UINT32 error = freerdp_get_last_error(s->context);
    freerdp_disconnect(instance);

    if (s->cb.stateChanged) {
        const char *message =
            error == FREERDP_ERROR_SUCCESS ? NULL : freerdp_get_last_error_string(error);
        s->cb.stateChanged(s->cb.context, AfarStateDisconnected, error, message);
    }
    return NULL;
}

// MARK: - Public interface

AfarEndReason afar_end_reason(uint32_t code) {
    switch (code) {
        case FREERDP_ERROR_SUCCESS:
        case FREERDP_ERROR_CONNECT_CANCELLED:
        case FREERDP_ERROR_RPC_INITIATED_DISCONNECT:
        case FREERDP_ERROR_RPC_INITIATED_LOGOFF:
        case FREERDP_ERROR_RPC_INITIATED_DISCONNECT_BY_USER:
        case FREERDP_ERROR_LOGOFF_BY_USER:
            return AfarEndedNormally;
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
        case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
        case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
        case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
        case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
        case FREERDP_ERROR_SERVER_FRESH_CREDENTIALS_REQUIRED:
            return AfarEndedAuthentication;
        case FREERDP_ERROR_DNS_ERROR:
        case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
            return AfarEndedHostNotFound;
        case FREERDP_ERROR_CONNECT_FAILED:
        case FREERDP_ERROR_TLS_CONNECT_FAILED:
        case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED:
        case FREERDP_ERROR_MCS_CONNECT_INITIAL_ERROR:
        case FREERDP_ERROR_CONNECT_TARGET_BOOTING:
            return AfarEndedUnreachable;
        case FREERDP_ERROR_DISCONNECTED_BY_OTHER_CONNECTION:
            return AfarEndedReplaced;
        case FREERDP_ERROR_IDLE_TIMEOUT:
        case FREERDP_ERROR_LOGON_TIMEOUT:
        case FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT:
            return AfarEndedTimeout;
        case FREERDP_ERROR_SERVER_DENIED_CONNECTION:
        case FREERDP_ERROR_SERVER_INSUFFICIENT_PRIVILEGES:
        case FREERDP_ERROR_INSUFFICIENT_PRIVILEGES:
        case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
        case FREERDP_ERROR_CONNECT_CLIENT_REVOKED:
            return AfarEndedServerDenied;
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
            return AfarEndedNetworkLost;
        default:
            return AfarEndedOther;
    }
}

bool afar_engine_initialize(void) {
    static bool initialized = false;
    if (initialized)
        return true;
    if (!freerdp_setApplicationDetails("Afar Desktop", "AfarDesktop", -1))
        return false;
    // A GUI app has no terminal: send FreeRDP's warnings and errors to the system log
    // (visible in Console.app). WLOG_APPENDER and WLOG_LEVEL in the environment still win.
    wLog *root = WLog_GetRoot();
    if (!getenv("WLOG_APPENDER"))
        (void)WLog_SetLogAppenderType(root, WLOG_APPENDER_SYSLOG);
    if (!getenv("WLOG_LEVEL"))
        (void)WLog_SetLogLevel(root, WLOG_WARN);
    initialized = true;
    return true;
}

AfarSession *afar_session_new(const AfarCallbacks *callbacks) {
    AfarSession *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->cb = *callbacks;
    pthread_mutex_init(&s->lock, NULL);
    afar_clipboard_init(s);

    RDP_CLIENT_ENTRY_POINTS entry = {0};
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entry.ContextSize = sizeof(AfarContext);
    entry.ClientNew = client_new;

    s->context = freerdp_client_context_new(&entry);
    if (!s->context) {
        afar_clipboard_destroy(s);
        pthread_mutex_destroy(&s->lock);
        free(s);
        return NULL;
    }
    ((AfarContext *)s->context)->session = s;
    return s;
}

static bool set_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *value) {
    return value == NULL || freerdp_settings_set_string(settings, key, value);
}

static bool configure_gateway(rdpSettings *settings, const AfarConnectParams *p) {
    if (!p->gatewayHost)
        return freerdp_settings_set_bool(settings, FreeRDP_GatewayEnabled, FALSE);
    const bool sameCredentials = p->gatewayUsername == NULL;
    return freerdp_settings_set_bool(settings, FreeRDP_GatewayEnabled, TRUE) &&
           freerdp_settings_set_string(settings, FreeRDP_GatewayHostname, p->gatewayHost) &&
           freerdp_settings_set_uint32(settings, FreeRDP_GatewayPort,
                                       p->gatewayPort ? p->gatewayPort : 443) &&
           freerdp_settings_set_uint32(settings, FreeRDP_GatewayUsageMethod, TSC_PROXY_MODE_DIRECT) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpTransport, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayRpcTransport, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, sameCredentials) &&
           set_string(settings, FreeRDP_GatewayUsername, p->gatewayUsername) &&
           set_string(settings, FreeRDP_GatewayDomain, p->gatewayDomain) &&
           set_string(settings, FreeRDP_GatewayPassword, p->gatewayPassword);
}

bool afar_session_connect(AfarSession *s, const AfarConnectParams *p) {
    if (!s || s->threadStarted || !p || !p->host)
        return false;
    rdpSettings *settings = s->context->settings;

    const bool ok =
        freerdp_settings_set_string(settings, FreeRDP_ServerHostname, p->host) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, p->port ? p->port : 3389) &&
        set_string(settings, FreeRDP_Username, p->username) &&
        set_string(settings, FreeRDP_Domain, p->domain) &&
        set_string(settings, FreeRDP_Password, p->password) &&
        set_string(settings, FreeRDP_ConfigPath, p->configDirectory) &&
        configure_gateway(settings, p) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, p->width) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, p->height) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, p->desktopScale) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, p->deviceScale) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
        freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
        // H.264 is decoded by VideoToolbox (Vendor/patches). AVC444 keeps text and colour sharp;
        // AVC420 halves the colour detail and the data.
        freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, p->fullColor) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, p->fullColor) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE) &&
        // Display control serves both window-sized and fixed desktops: the size agreed at
        // connect time is capped, the channel lifts the cap afterwards.
        freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT) &&
        freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, p->audio) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, p->clipboard) &&
        freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE);
    if (!ok || !afar_statistics_attach(s))
        return false;

    pthread_mutex_lock(&s->lock);
    s->lastLayout = (AfarLayout){p->width, p->height, p->desktopScale, p->deviceScale};
    pthread_mutex_unlock(&s->lock);

    if (freerdp_client_start(s->context) != 0)
        return false;
    if (pthread_create(&s->thread, NULL, session_thread, s) != 0)
        return false;
    s->threadStarted = true;
    return true;
}

void afar_session_disconnect(AfarSession *s) {
    if (s && s->context)
        freerdp_abort_connect_context(s->context);
}

void afar_session_free(AfarSession *s) {
    if (!s)
        return;
    if (s->threadStarted) {
        freerdp_abort_connect_context(s->context);
        pthread_join(s->thread, NULL);
        (void)freerdp_client_stop(s->context);
    }
    freerdp_client_context_free(s->context);
    afar_clipboard_destroy(s);
    pthread_mutex_destroy(&s->lock);
    free(s);
}
