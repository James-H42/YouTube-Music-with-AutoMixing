import Foundation
import WebKit

enum PoTokenError: LocalizedError {
    case challenge(String)
    case script(String)

    var errorDescription: String? {
        switch self {
        case .challenge(let what): "Couldn't prepare YouTube's attestation (\(what))."
        case .script(let what): "YouTube's attestation script failed (\(what))."
        }
    }
}

/// Mints "proof of origin" tokens the way YouTube's own web player does: by running its
/// BotGuard attestation program in a web view. A token vouches that requests come from a real
/// browser session, which is what YouTube asks for when it bot-checks a connection.
///
/// This follows Metrolist's `PoTokenWebView` (itself after NewPipe and BgUtils): fetch a
/// challenge, run it, exchange the result for an integrity token, then mint tokens bound to
/// an identifier (the visitor ID or a video ID). The integrity token lasts some hours, so the
/// web view is kept and reused.
@MainActor
final class PoTokenGenerator: NSObject, WKNavigationDelegate {
    static let shared = PoTokenGenerator()

    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private var webView: WKWebView?
    private var expires = Date.distantPast
    private var loading: CheckedContinuation<Void, Error>?
    private var preparing: Task<Void, Error>?
    /// After a failure, don't try again straight away: each attempt costs two requests.
    private var retryAfter = Date.distantPast

    /// A token bound to `identifier`, in the URL-safe base64 form YouTube expects.
    func token(for identifier: String) async throws -> String {
        try await prepare()
        guard let webView else { throw PoTokenError.script("no web view") }
        do {
            let result = try await webView.callAsyncJavaScript(
                "const token = await obtainPoToken(new Uint8Array(identifier)); return Array.from(token);",
                arguments: ["identifier": Array(identifier.utf8).map(Int.init)], contentWorld: .page
            )
            guard let bytes = result as? [Int], bytes.count > 20 else { throw PoTokenError.script("empty token") }
            return Data(bytes.map { UInt8(truncatingIfNeeded: $0) }).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        } catch {
            // The page may have been torn down by the system; start afresh next time.
            reset()
            throw error
        }
    }

    func reset() {
        webView?.navigationDelegate = nil
        webView = nil
        expires = .distantPast
    }

    private func prepare() async throws {
        if webView != nil, Date() < expires { return }
        if let preparing { return try await preparing.value }
        guard Date() >= retryAfter else { throw PoTokenError.challenge("waiting before another attempt") }
        let task = Task { try await self.build() }
        preparing = task
        defer { preparing = nil }
        do {
            try await task.value
        } catch {
            reset()
            retryAfter = Date().addingTimeInterval(120)
            throw error
        }
    }

    private func build() async throws {
        reset()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        webView = view
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            view.loadHTMLString(Self.page, baseURL: URL(string: "https://www.youtube.com"))
        }

        let challenge = try await Self.challenge(from: request("Create", body: [Self.requestKey]))
        let response = try await view.callAsyncJavaScript(
            "const result = await runBotGuard(data); window.webPoSignalOutput = result.webPoSignalOutput; return result.botguardResponse;",
            arguments: ["data": challenge], contentWorld: .page
        )
        guard let botguardResponse = response as? String, !botguardResponse.isEmpty else { throw PoTokenError.script("no BotGuard response") }

        let integrity = try await request("GenerateIT", body: [Self.requestKey, botguardResponse])
        guard let fields = try JSONSerialization.jsonObject(with: integrity) as? [Any], fields.count >= 2,
              let encoded = fields[0] as? String, let token = Self.decode(encoded), let lifetime = (fields[1] as? NSNumber)?.doubleValue
        else { throw PoTokenError.challenge("integrity token") }
        _ = try await view.callAsyncJavaScript(
            "await createPoTokenMinter(window.webPoSignalOutput, new Uint8Array(token)); return true;",
            arguments: ["token": token.map(Int.init)], contentWorld: .page
        )
        // Leave ten minutes of margin.
        expires = Date().addingTimeInterval(max(60, lifetime - 600))
    }

    private func request(_ method: String, body: [String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/api/jnn/v1/\(method)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        let (data, response) = try await InnerTube.shared.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw PoTokenError.challenge("\(method) returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    /// YouTube's own base64 flavour: URL-safe, with "." for padding.
    private static func decode(_ text: String) -> [UInt8]? {
        var normal = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ".", with: "=")
        while normal.count % 4 != 0 { normal += "=" }
        return Data(base64Encoded: normal).map(Array.init)
    }

    /// Turns the Create response into the object the page's `runBotGuard` expects.
    private static func challenge(from data: Data) async throws -> [String: Any] {
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw PoTokenError.challenge("challenge format") }
        if fields.count > 1, let scrambled = fields[1] as? String {
            // Scrambled form: base64, each byte offset by 97.
            guard let bytes = decode(scrambled),
                  let plain = try JSONSerialization.jsonObject(with: Data(bytes.map { $0 &+ 97 })) as? [Any]
            else { throw PoTokenError.challenge("scrambled challenge") }
            fields = plain
        } else if let inner = fields.first as? [Any] {
            fields = inner
        }
        guard fields.count > 5, let program = fields[4] as? String, let globalName = fields[5] as? String else {
            throw PoTokenError.challenge("challenge fields")
        }
        var script = (fields[1] as? [Any])?.compactMap { $0 as? String }.first
        let address = (fields[2] as? [Any])?.compactMap { $0 as? String }.first
        if script == nil, let address {
            // The interpreter is sometimes given by address instead of inline. Only Google's own.
            let full = address.hasPrefix("//") ? "https:" + address : address
            guard let url = URL(string: full), url.scheme == "https", ["www.google.com", "www.gstatic.com"].contains(url.host ?? "") else {
                throw PoTokenError.challenge("interpreter address")
            }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (body, _) = try await InnerTube.shared.session.data(for: request)
            script = String(data: body, encoding: .utf8)
        }
        guard let script, !script.isEmpty else { throw PoTokenError.challenge("interpreter") }
        return [
            "interpreterJavascript": ["privateDoNotAccessOrElseSafeScriptWrappedValue": script],
            "program": program,
            "globalName": globalName,
        ]
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loading?.resume()
            loading = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            loading?.resume(throwing: error)
            loading = nil
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { reset() }
    }

    /// The BotGuard client page, from Metrolist's `po_token.html` (GPL-3.0).
    private static let page = #"""
<!DOCTYPE html>
<html lang="en"><head><title></title><script>
    /**
     * BotGuard client for generating poTokens.
     * Updated to fix JavaScript 'this' binding issues and match BgUtils v3.2.0 patterns.
     */

    // Global state for BotGuard
    var bgVmFunctions = null;
    var bgVm = null;
    var bgProgram = null;
    var poTokenMinter = null;  // Minter callback - created ONCE during init, reused for all tokens

    function loadBotGuard(challengeData) {
      bgVm = window[challengeData.globalName];
      bgProgram = challengeData.program;
      bgVmFunctions = null;

      if (!bgVm)
        throw new Error('[BotGuardClient]: VM not found in the global object');

      if (!bgVm.a)
        throw new Error('[BotGuardClient]: Could not load program');

      // Use explicit variable capture instead of 'this' to avoid binding issues
      var vmFunctionsCallback = function (
        asyncSnapshotFunction,
        shutdownFunction,
        passEventFunction,
        checkCameraFunction
      ) {
        bgVmFunctions = {
          asyncSnapshotFunction: asyncSnapshotFunction,
          shutdownFunction: shutdownFunction,
          passEventFunction: passEventFunction,
          checkCameraFunction: checkCameraFunction
        };
      };

      // Execute the BotGuard program
      try {
        bgVm.a(bgProgram, vmFunctionsCallback, true, undefined, function () {/** no-op */ }, [ [], [] ]);
      } catch (e) {
        throw new Error('[BotGuardClient]: Failed to execute program: ' + e.message);
      }

      // Wait for vmFunctions to be populated (async callback)
      return new Promise(function (resolve, reject) {
        var attempts = 0;
        var maxAttempts = 10000; // 10 seconds at 1ms intervals
        var checkInterval = setInterval(function () {
          if (bgVmFunctions && bgVmFunctions.asyncSnapshotFunction) {
            clearInterval(checkInterval);
            resolve({
              vmFunctions: bgVmFunctions,
              vm: bgVm,
              program: bgProgram
            });
          } else if (attempts >= maxAttempts) {
            clearInterval(checkInterval);
            reject(new Error('[BotGuardClient]: Timeout waiting for asyncSnapshotFunction'));
          }
          attempts++;
        }, 1);
      });
    }

    /**
     * Takes a snapshot asynchronously using the loaded BotGuard.
     */
    function snapshot(botguard, args) {
      return new Promise(function (resolve, reject) {
        if (!botguard.vmFunctions || !botguard.vmFunctions.asyncSnapshotFunction) {
          return reject(new Error('[BotGuardClient]: Async snapshot function not found'));
        }

        try {
          botguard.vmFunctions.asyncSnapshotFunction(
            function (response) { resolve(response); },
            [
              args.contentBinding,
              args.signedTimestamp,
              args.webPoSignalOutput,
              args.skipPrivacyBuffer
            ]
          );
        } catch (e) {
          reject(new Error('[BotGuardClient]: Snapshot failed: ' + e.message));
        }
      });
    }

    function runBotGuard(challengeData) {
      var interpreterJavascript = challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;

      if (interpreterJavascript) {
        new Function(interpreterJavascript)();
      } else {
        throw new Error('[BotGuardClient]: Could not load VM - no interpreter JavaScript');
      }

      var webPoSignalOutput = [];

      return loadBotGuard({
        globalName: challengeData.globalName,
        program: challengeData.program
      }).then(function (botguard) {
        return snapshot(botguard, { webPoSignalOutput: webPoSignalOutput });
      }).then(function (botguardResponse) {
        return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse };
      });
    }

    /**
     * Creates the poToken minter callback. MUST be called exactly ONCE during initialization,
     * right after runBotGuard completes. The minter is stored globally and reused for all tokens.
     * NOTE: getMinter() may return a Promise, so this function is async.
     * @param webPoSignalOutput - Array from BotGuard containing the minter factory function
     * @param integrityToken - The integrity token (as bytes/Uint8Array)
     * @returns Promise that resolves when minter is ready
     */
    async function createPoTokenMinter(webPoSignalOutput, integrityToken) {

      // Get the minter factory function from webPoSignalOutput
      var getMinter = webPoSignalOutput[0];

      if (!getMinter) {
        throw new Error('PMD:Undefined - webPoSignalOutput[0] is not defined');
      }

      if (typeof getMinter !== 'function') {
        throw new Error('PMD:NotFunction - webPoSignalOutput[0] is not a function, got: ' + typeof getMinter);
      }

      // Create the mint callback by passing the integrity token - THIS MUST ONLY HAPPEN ONCE!
      // NOTE: getMinter() may return a Promise, so we await it
      var mintCallback;
      try {
        var minterResult = getMinter(integrityToken);
        // Handle both sync and async getMinter
        if (minterResult && typeof minterResult.then === 'function') {
          mintCallback = await minterResult;
        } else {
          mintCallback = minterResult;
        }
      } catch (e) {
        throw new Error('GMC:Failed - getMinter() threw: ' + e.message);
      }

      if (!mintCallback) {
        throw new Error('APF:Undefined - mintCallback is undefined');
      }

      if (typeof mintCallback !== 'function') {
        throw new Error('APF:NotFunction - mintCallback is not a function, got: ' + typeof mintCallback);
      }

      // Store the minter globally for reuse
      poTokenMinter = mintCallback;
    }

    /**
     * Mints a poToken using the pre-created minter callback.
     * The minter MUST have been created during initialization via createPoTokenMinter().
     * NOTE: mintCallback() may return a Promise, so this function is async.
     * @param identifier - The identifier to bind the token to (as Uint8Array)
     * @returns Promise<Uint8Array> containing the poToken
     */
    async function obtainPoToken(identifier) {
      if (!poTokenMinter) {
        throw new Error('MNT:NotInit - poTokenMinter was not initialized. Call createPoTokenMinter first.');
      }

      // Mint the token with the identifier
      // NOTE: mintCallback() may return a Promise, so we await it
      var result;
      try {
        var mintResult = poTokenMinter(identifier);
        // Handle both sync and async mintCallback
        if (mintResult && typeof mintResult.then === 'function') {
          result = await mintResult;
        } else {
          result = mintResult;
        }
      } catch (e) {
        throw new Error('MNT:Failed - mintCallback() threw: ' + e.message);
      }

      if (!result) {
        throw new Error('YNJ:Undefined - mint result is undefined');
      }

      if (!(result instanceof Uint8Array)) {
        throw new Error('ODM:Invalid - result is not Uint8Array, got: ' + Object.prototype.toString.call(result));
      }

      // Validate token size (expected 110-128 bytes per BgUtils documentation)
      if (result.length < 100 || result.length > 140) {
        console.warn('[obtainPoToken] Token size ' + result.length + ' bytes may be outside expected range (110-128)');
      }

      return result;
    }
</script></head><body></body></html>
"""#
}
