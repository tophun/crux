import Foundation
import SwiftData

/// 게시 결과. `contentId`와 외부 식별자의 연결은 로컬에만 존재한다.
public struct PublishRecord: Identifiable, Hashable, Sendable, Codable {
    public enum Target: String, Sendable, Codable {
        case confluence
        case jira
    }

    public var id: UUID
    public var meetingId: UUID
    public var contentId: String?
    public var target: Target
    public var externalId: String
    public var externalKey: String?
    public var url: String
    public var publishedAt: Date

    public init(
        id: UUID = UUID(),
        meetingId: UUID,
        contentId: String? = nil,
        target: Target,
        externalId: String,
        externalKey: String? = nil,
        url: String,
        publishedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.contentId = contentId
        self.target = target
        self.externalId = externalId
        self.externalKey = externalKey
        self.url = url
        self.publishedAt = publishedAt
    }
}

@Model
final class PublishRecordModel {
    @Attribute(.unique) var id: String
    var meetingId: String
    var contentId: String?
    var target: String
    var externalId: String
    var externalKey: String?
    var url: String
    var publishedAt: Date

    init(
        id: String,
        meetingId: String,
        contentId: String?,
        target: String,
        externalId: String,
        externalKey: String?,
        url: String,
        publishedAt: Date
    ) {
        self.id = id
        self.meetingId = meetingId
        self.contentId = contentId
        self.target = target
        self.externalId = externalId
        self.externalKey = externalKey
        self.url = url
        self.publishedAt = publishedAt
    }

    convenience init(_ record: PublishRecord) {
        self.init(
            id: record.id.uuidString,
            meetingId: record.meetingId.uuidString,
            contentId: record.contentId,
            target: record.target.rawValue,
            externalId: record.externalId,
            externalKey: record.externalKey,
            url: record.url,
            publishedAt: record.publishedAt
        )
    }

    var domain: PublishRecord? {
        guard let uuid = UUID(uuidString: id),
              let meeting = UUID(uuidString: meetingId),
              let target = PublishRecord.Target(rawValue: target) else { return nil }
        return PublishRecord(
            id: uuid,
            meetingId: meeting,
            contentId: contentId,
            target: target,
            externalId: externalId,
            externalKey: externalKey,
            url: url,
            publishedAt: publishedAt
        )
    }
}
