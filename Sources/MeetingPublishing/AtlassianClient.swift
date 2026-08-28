import Foundation
import MeetingCore

/// Atlassian Cloud REST 클라이언트.
///
/// HTTP는 `MeetingPublishing` 안에서만 나간다(`AtlassianClient`, `SlackClient`).
/// 회의 오디오·전사문·근거 타임스탬프는 여기까지 오지 않는다(타입에 담을 수 없다).
/// 로깅에서 Authorization 헤더와 토큰은 항상 제외한다.
public actor AtlassianClient {
    private let credentials: AtlassianCredentials
    private let session: URLSession
    private let log: (@Sendable (String) -> Void)?

    public init(
        credentials: AtlassianCredentials,
        session: URLSession = .shared,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.session = session
        self.log = log
    }

    // MARK: - Confluence

    /// Space 키로 숫자 spaceId를 찾는다. v2 페이지 생성은 키가 아니라 id를 요구한다.
    public func confluenceSpaceId(key: String) async throws -> String {
        let response = try await send(
            method: "GET",
            path: "/wiki/api/v2/spaces",
            query: [URLQueryItem(name: "keys", value: key), URLQueryItem(name: "limit", value: "1")]
        )
        guard let results = response["results"] as? [[String: Any]], let first = results.first else {
            throw PublishError.spaceNotFound(key)
        }
        if let id = first["id"] as? String {
            return id
        }
        if let id = first["id"] as? Int {
            return String(id)
        }
        throw PublishError.invalidResponse("spaceId 없음")
    }

    public struct CreatedPage: Sendable {
        public var id: String
        public var title: String
        public var version: Int
        public var url: String
    }

    /// Confluence 페이지를 만든다. body는 storage format(HTML)이다.
    public func createConfluencePage(
        spaceId: String,
        title: String,
        storageBody: String,
        parentId: String? = nil
    ) async throws -> CreatedPage {
        var payload: [String: Any] = [
            "spaceId": spaceId,
            "status": "current",
            "title": title,
            "body": ["representation": "storage", "value": storageBody]
        ]
        if let parentId {
            payload["parentId"] = parentId
        }

        let response = try await send(method: "POST", path: "/wiki/api/v2/pages", body: payload)
        return try parsePage(response, fallbackTitle: title)
    }

    /// 페이지 본문을 갱신한다. Jira 이슈 키를 사후에 붙일 때 쓴다.
    public func updateConfluencePage(
        pageId: String,
        title: String,
        storageBody: String,
        currentVersion: Int
    ) async throws -> CreatedPage {
        let payload: [String: Any] = [
            "id": pageId,
            "status": "current",
            "title": title,
            "body": ["representation": "storage", "value": storageBody],
            "version": ["number": currentVersion + 1, "message": "회의록 Jira 링크 추가"]
        ]
        let response = try await send(method: "PUT", path: "/wiki/api/v2/pages/\(pageId)", body: payload)
        return try parsePage(response, fallbackTitle: title)
    }

    private func parsePage(_ response: [String: Any], fallbackTitle: String) throws -> CreatedPage {
        let id: String
        if let value = response["id"] as? String {
            id = value
        } else if let value = response["id"] as? Int {
            id = String(value)
        } else {
            throw PublishError.invalidResponse("페이지 id 없음")
        }

        let version = (response["version"] as? [String: Any])?["number"] as? Int ?? 1
        let links = response["_links"] as? [String: Any]
        let webui = links?["webui"] as? String
        let base = links?["base"] as? String ?? "https://\(credentials.site)/wiki"
        let url = webui.map { base + $0 } ?? "https://\(credentials.site)/wiki/pages/\(id)"

        return CreatedPage(
            id: id,
            title: response["title"] as? String ?? fallbackTitle,
            version: version,
            url: url
        )
    }

    // MARK: - Jira

    public struct CreatedIssue: Sendable {
        public var id: String
        public var key: String
        public var url: String
    }

    /// Jira 이슈를 만든다. description은 ADF JSON이다.
    public func createJiraIssue(
        projectKey: String,
        summary: String,
        descriptionADF: [String: Any],
        issueTypeName: String,
        accountId: String?,
        dueDate: String?,
        priorityName: String?
    ) async throws -> CreatedIssue {
        var fields: [String: Any] = [
            "project": ["key": projectKey],
            "summary": summary,
            "issuetype": ["name": issueTypeName],
            "description": descriptionADF
        ]
        if let accountId {
            fields["assignee"] = ["accountId": accountId]
        }
        if let dueDate {
            fields["duedate"] = dueDate
        }
        if let priorityName {
            fields["priority"] = ["name": priorityName]
        }

        let response = try await send(method: "POST", path: "/rest/api/3/issue", body: ["fields": fields])
        guard let id = response["id"] as? String, let key = response["key"] as? String else {
            throw PublishError.invalidResponse("이슈 id/key 없음")
        }
        return CreatedIssue(id: id, key: key, url: "https://\(credentials.site)/browse/\(key)")
    }

    /// 이메일 또는 이름으로 accountId를 찾는다. 찾지 못하면 nil (담당자를 임의로 정하지 않는다).
    public func findJiraAccountId(query: String) async throws -> String? {
        let response = try await sendArray(
            method: "GET",
            path: "/rest/api/3/user/search",
            query: [URLQueryItem(name: "query", value: query), URLQueryItem(name: "maxResults", value: "5")]
        )
        let candidates = response.compactMap { $0 as? [String: Any] }
        if let exact = candidates.first(where: {
            ($0["emailAddress"] as? String)?.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return exact["accountId"] as? String
        }
        if let displayMatch = candidates.first(where: {
            ($0["displayName"] as? String)?.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return displayMatch["accountId"] as? String
        }
        return candidates.count == 1 ? candidates[0]["accountId"] as? String : nil
    }

    /// Jira 이슈에 Confluence 페이지 링크를 붙인다.
    public func addJiraRemoteLink(issueKey: String, url: String, title: String) async throws {
        _ = try await send(
            method: "POST",
            path: "/rest/api/3/issue/\(issueKey)/remotelink",
            body: ["object": ["url": url, "title": title]]
        )
    }

    /// 연결 확인용. 사용자 자신의 정보를 읽는다.
    public func verifyConnection() async throws -> String {
        let response = try await send(method: "GET", path: "/rest/api/3/myself")
        return response["displayName"] as? String ?? response["accountId"] as? String ?? "확인됨"
    }

    // MARK: - HTTP

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard let baseURL = credentials.baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else {
            throw PublishError.missingCredentials("사이트 주소가 올바르지 않습니다: \(credentials.site)")
        }
        if let query, !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw PublishError.missingCredentials("요청 주소를 만들 수 없습니다.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        // 로그에는 메서드와 경로만 남긴다. 헤더·본문은 남기지 않는다.
        log?("\(method) \(path)")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PublishError.invalidResponse("HTTP 응답이 아닙니다.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(decoding: data.prefix(500), as: UTF8.self)
            throw PublishError.api(status: http.statusCode, message: message)
        }
        return data
    }

    private func send(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let data = try await perform(request(method: method, path: path, query: query, body: body))
        if data.isEmpty {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw PublishError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let dictionary = object as? [String: Any] {
            return dictionary
        }
        return ["value": object]
    }

    private func sendArray(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil
    ) async throws -> [Any] {
        let data = try await perform(request(method: method, path: path, query: query))
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array
    }
}
