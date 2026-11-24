import Foundation

enum DownloadState: String, Codable {
    case queued
    case downloading
    case waiting    // 네트워크 오류 후 자동 재시도 대기
    case paused
    case failed
    case completed
    case merging    // 분할 다운로드 조각을 하나로 합치는 중
}

/// 분할(멀티 커넥션) 다운로드의 한 조각. 바이트 범위는 [start, end] (end 포함).
struct DownloadSegment: Codable, Equatable {
    var start: Int64
    var end: Int64
    var done = false
    var retries = 0

    var length: Int64 { end - start + 1 }
}

struct DownloadItem: Codable, Identifiable, Equatable {
    let id: UUID
    var url: URL
    var headers: [String: String]
    var fileName: String
    /// 파일명이 서버(Content-Disposition)에서 확정됐는지. 아니면 완료 시 응답 기준으로 다시 정한다.
    var nameFromServer: Bool
    var state: DownloadState
    var receivedBytes: Int64 = 0
    /// 0 이하이면 전체 크기 모름
    var totalBytes: Int64 = 0
    var errorMessage: String?
    var retryCount: Int = 0
    /// WKDownload(앱 내) 폴백 다운로드. 앱이 죽으면 이어받기 불가.
    var isForeground: Bool = false
    var createdAt = Date()
    var completedAt: Date?
    /// nil이면 단일 연결 다운로드, 있으면 Range 요청 여러 개로 병렬 다운로드
    var segments: [DownloadSegment]? = nil
    /// 조각 요청에 If-Range로 붙일 ETag/Last-Modified (도중에 파일이 바뀌면 감지)
    var validator: String? = nil

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var isActive: Bool {
        state == .queued || state == .downloading || state == .waiting || state == .merging
    }
}
