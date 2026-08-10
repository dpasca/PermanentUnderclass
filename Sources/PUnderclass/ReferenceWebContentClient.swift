import AppKit
import Foundation

struct ReferenceWebContent: Equatable, Sendable {
    let requestedURL: String
    let resolvedURL: String
    let title: String
    let content: String
    let provider: ReferenceWebProvider
    let fetchedAt: Date
}

enum ReferenceWebContentError: LocalizedError, Equatable {
    case invalidURL
    case allProvidersFailed(exaKeyAvailable: Bool, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a complete http:// or https:// URL."
        case let .allProvidersFailed(exaKeyAvailable, detail):
            if exaKeyAvailable {
                "Jina Reader, direct fetch, and Exa could not read this page. \(detail)"
            } else {
                "Jina Reader and direct fetch could not read this page. Add an Exa key in API Keys to try the optional fallback. \(detail)"
            }
        }
    }
}

struct ReferenceWebContentClient: Sendable {
    static let jinaEndpoint = URL(string: "https://r.jina.ai/")!
    static let exaEndpoint = URL(string: "https://api.exa.ai/contents")!
    static let maximumCharacters = 80_000

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(
        url rawURL: String,
        exaAPIKey: String = ""
    ) async throws -> ReferenceWebContent {
        let sourceURL = try Self.validatedURL(rawURL)
        var failures: [String] = []

        do {
            return try await fetchWithJina(sourceURL)
        } catch {
            failures.append("Jina: \(error.localizedDescription)")
        }
        try Task.checkCancellation()

        do {
            return try await fetchDirectly(sourceURL)
        } catch {
            failures.append("Direct: \(error.localizedDescription)")
        }
        try Task.checkCancellation()

        let key = exaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                return try await fetchWithExa(sourceURL, apiKey: key)
            } catch {
                failures.append("Exa: \(error.localizedDescription)")
            }
        }

        throw ReferenceWebContentError.allProvidersFailed(
            exaKeyAvailable: !key.isEmpty,
            detail: failures.joined(separator: " ")
        )
    }

    static func validatedURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.count <= 2_048,
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false,
            url.user == nil,
            url.password == nil
        else {
            throw ReferenceWebContentError.invalidURL
        }
        return url
    }

    private func fetchWithJina(_ sourceURL: URL) async throws
        -> ReferenceWebContent
    {
        let request = try Self.jinaRequest(for: sourceURL)

        let (data, response) = try await session.data(for: request)
        let httpResponse = try Self.successfulResponse(response, data: data)
        guard
            let rawText = String(data: data, encoding: .utf8),
            let content = Self.usableContent(rawText)
        else {
            throw URLError(.cannotDecodeContentData)
        }
        return ReferenceWebContent(
            requestedURL: sourceURL.absoluteString,
            resolvedURL: sourceURL.absoluteString,
            title: Self.jinaTitle(from: rawText)
                ?? httpResponse.suggestedFilename
                ?? sourceURL.host
                ?? "Web source",
            content: content,
            provider: .jinaReader,
            fetchedAt: Date()
        )
    }

    static func jinaRequest(for sourceURL: URL) throws -> URLRequest {
        guard let readerURL = URL(
            string: jinaEndpoint.absoluteString + sourceURL.absoluteString
        ) else {
            throw ReferenceWebContentError.invalidURL
        }
        var request = URLRequest(url: readerURL)
        request.timeoutInterval = 35
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("markdown", forHTTPHeaderField: "X-Respond-With")
        request.setValue("none", forHTTPHeaderField: "X-Retain-Images")
        request.setValue("12000", forHTTPHeaderField: "X-Max-Tokens")
        request.setValue(
            "visible-content",
            forHTTPHeaderField: "X-Respond-Timing"
        )
        return request
    }

    private func fetchDirectly(_ sourceURL: URL) async throws
        -> ReferenceWebContent
    {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 20
        request.setValue(
            "text/html, text/plain, application/json, application/xhtml+xml",
            forHTTPHeaderField: "Accept"
        )
        let (data, response) = try await session.data(for: request)
        let httpResponse = try Self.successfulResponse(response, data: data)
        guard data.count <= 5_000_000 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let decoded = Self.directText(data: data, response: httpResponse)
        guard let decoded, let content = Self.usableContent(decoded) else {
            throw URLError(.cannotDecodeContentData)
        }
        return ReferenceWebContent(
            requestedURL: sourceURL.absoluteString,
            resolvedURL: httpResponse.url?.absoluteString
                ?? sourceURL.absoluteString,
            title: sourceURL.host ?? "Web source",
            content: content,
            provider: .direct,
            fetchedAt: Date()
        )
    }

    private func fetchWithExa(
        _ sourceURL: URL,
        apiKey: String
    ) async throws -> ReferenceWebContent {
        var request = URLRequest(url: Self.exaEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.exaRequestBody(urls: [sourceURL.absoluteString])

        let (data, response) = try await session.data(for: request)
        _ = try Self.successfulResponse(response, data: data)
        return try Self.parseExaResponse(
            data,
            requestedURL: sourceURL.absoluteString,
            fetchedAt: Date()
        )
    }

    static func exaRequestBody(urls: [String]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "urls": urls,
                "text": true,
                "maxAgeHours": 24
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func parseExaResponse(
        _ data: Data,
        requestedURL: String,
        fetchedAt: Date
    ) throws -> ReferenceWebContent {
        guard
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let result = (root["results"] as? [[String: Any]])?.first,
            let rawText = result["text"] as? String,
            let content = usableContent(rawText)
        else {
            throw URLError(.cannotParseResponse)
        }
        return ReferenceWebContent(
            requestedURL: requestedURL,
            resolvedURL: result["url"] as? String ?? requestedURL,
            title: (result["title"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nonempty ?? URL(string: requestedURL)?.host ?? "Web source",
            content: content,
            provider: .exa,
            fetchedAt: fetchedAt
        )
    }

    private static func successfulResponse(
        _ response: URLResponse,
        data: Data
    ) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(response.statusCode) else {
            let detail = String(data: data.prefix(400), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ReferenceWebContent",
                code: response.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: detail?.nonempty
                        ?? "HTTP \(response.statusCode)"
                ]
            )
        }
        return response
    }

    private static func usableContent(_ rawText: String) -> String? {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 120 else { return nil }
        return normalized.count > maximumCharacters
            ? String(normalized.prefix(maximumCharacters))
            : normalized
    }

    private static func directText(
        data: Data,
        response: HTTPURLResponse
    ) -> String? {
        let mimeType = response.mimeType?.lowercased() ?? ""
        if mimeType == "text/html" || mimeType == "application/xhtml+xml" {
            return try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            ).string
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func jinaTitle(from text: String) -> String? {
        for line in text.split(separator: "\n", maxSplits: 8) {
            let value = String(line)
            guard value.hasPrefix("Title:") else { continue }
            return String(value.dropFirst("Title:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonempty
        }
        return nil
    }
}

private extension String {
    var nonempty: String? {
        isEmpty ? nil : self
    }
}
