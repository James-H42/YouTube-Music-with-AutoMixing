import Foundation

/// A client identity presented to InnerTube. Different identities unlock different behaviour:
/// WEB_REMIX is the YouTube Music web app (browse, search, queue), while the native-device
/// identities return direct, unciphered audio URLs from the player endpoint.
struct YouTubeClient {
    var id: String
    var clientName: String
    var clientVersion: String
    var clientId: String
    var userAgent: String
    var osName: String?
    var osVersion: String?
    var deviceMake: String?
    var deviceModel: String?
    var androidSdkVersion: String?
    var platform: String?
    var loginSupported = false
    var includeUserAgentInContext = false
    var useMusicPlayerEndpoint = false
    /// Presents itself as a player embedded in another site.
    var isEmbedded = false
    /// A browser-family identity: its stream addresses are scrambled by the player script and
    /// it expects an attestation (PO) token.
    var isWeb = false
    /// Media requests must use bounded byte ranges of this size.
    var rangeChunkSize = 1_048_576

    static let userAgentWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"

    static let webRemix = YouTubeClient(
        id: "WEB_REMIX",
        clientName: "WEB_REMIX",
        clientVersion: "1.20260707.12.00",
        clientId: "67",
        userAgent: userAgentWeb,
        loginSupported: true
    )

    static let visionOS = YouTubeClient(
        id: "VISIONOS",
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientId: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        osName: "visionOS",
        osVersion: "26.5.23O471",
        deviceMake: "Apple",
        deviceModel: "RealityDevice17,1",
        useMusicPlayerEndpoint: true
    )

    static let androidVR = YouTubeClient(
        id: "ANDROID_VR_1_65_10",
        clientName: "ANDROID_VR",
        clientVersion: "1.65.10",
        clientId: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 "
            + "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        osName: "Android",
        osVersion: "12L",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        androidSdkVersion: "32",
        includeUserAgentInContext: true,
        useMusicPlayerEndpoint: true,
        rangeChunkSize: 524_288
    )

    static let visionOSLegacy = YouTubeClient(
        id: "VISIONOS_0_1",
        clientName: "VISIONOS",
        clientVersion: "0.1",
        clientId: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.5 Safari/605.1.15",
        osName: "VISION_OS",
        osVersion: "1.3",
        deviceMake: "Apple",
        deviceModel: "RealityDevice14,1",
        platform: "MOBILE",
        useMusicPlayerEndpoint: true
    )

    static let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"

    static let web = YouTubeClient(
        id: "WEB", clientName: "WEB", clientVersion: "2.20260708.00.00", clientId: "1",
        userAgent: userAgentWeb, loginSupported: true, isWeb: true
    )

    static let mweb = YouTubeClient(
        id: "MWEB", clientName: "MWEB", clientVersion: "2.20260708.05.00", clientId: "2",
        userAgent: "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)",
        loginSupported: true, includeUserAgentInContext: true, isWeb: true
    )

    static let webEmbedded = YouTubeClient(
        id: "WEB_EMBEDDED_PLAYER", clientName: "WEB_EMBEDDED_PLAYER", clientVersion: "2.20260708.00.00", clientId: "56",
        userAgent: userAgentWeb, loginSupported: true, isEmbedded: true, isWeb: true
    )

    static let tv = YouTubeClient(
        id: "TVHTML5", clientName: "TVHTML5", clientVersion: "7.20260707.07.00", clientId: "7",
        userAgent: tvUserAgent, loginSupported: true, includeUserAgentInContext: true, isWeb: true
    )

    static let tvSimply = YouTubeClient(
        id: "TVHTML5_SIMPLY", clientName: "TVHTML5_SIMPLY", clientVersion: "1.0", clientId: "75",
        userAgent: tvUserAgent, useMusicPlayerEndpoint: true, isWeb: true
    )

    static let tvEmbedded = YouTubeClient(
        id: "TVHTML5_SIMPLY_EMBEDDED_PLAYER", clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER", clientVersion: "2.0", clientId: "85",
        userAgent: tvUserAgent, isEmbedded: true, isWeb: true
    )

    static let webRemixPlayback: YouTubeClient = {
        var client = webRemix
        client.isWeb = true
        return client
    }()

    /// Identities tried, in order, when resolving an audio stream.
    static let playbackClients: [YouTubeClient] = [visionOS, androidVR, visionOSLegacy]

    func context(visitorData: String?, gl: String, hl: String) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "gl": gl,
            "hl": hl,
        ]
        if includeUserAgentInContext { client["userAgent"] = userAgent }
        client["osName"] = osName
        client["osVersion"] = osVersion
        client["deviceMake"] = deviceMake
        client["deviceModel"] = deviceModel
        client["androidSdkVersion"] = androidSdkVersion
        client["platform"] = platform
        client["visitorData"] = visitorData
        var context: [String: Any] = [
            "client": client.compactMapValues { $0 },
            "request": ["internalExperimentFlags": [String](), "useSsl": true],
            "user": ["lockedSafetyMode": false],
        ]
        if isEmbedded { context["thirdParty"] = ["embedUrl": "https://www.reddit.com/"] }
        return context
    }
}
