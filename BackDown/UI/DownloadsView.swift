import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    let addURL: (URL) -> Void

    @AppStorage(KeepAlive.enabledKey) private var keepAlive = true
    @State private var showAdd = false
    @State private var newURL = ""

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("다운로드 없음")
                            .font(.headline)
                        Text("브라우저에서 파일 링크를 누르거나\n길게 눌러 \"BackDown으로 다운로드\"를 선택하세요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item, speed: manager.speeds[item.id], manager: manager)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        manager.remove(item.id, deleteFile: true)
                                    } label: { Label("삭제", systemImage: "trash") }
                                    Button {
                                        manager.remove(item.id, deleteFile: false)
                                    } label: { Label("목록에서 제거", systemImage: "list.bullet") }
                                    .tint(.gray)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("다운로드")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Toggle("백그라운드 유지 (무음 오디오)", isOn: $keepAlive)
                        Button("완료 항목 목록 정리") { manager.clearCompleted() }
                        Button("파일 앱에서 열기") { openInFiles(manager.downloadsDirectory) }
                    } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let pasteboard = UIPasteboard.general
                        newURL = pasteboard.hasURLs ? (pasteboard.url?.absoluteString ?? "") : ""
                        showAdd = true
                    } label: { Image(systemName: "plus") }
                }
            }
            .alert("URL로 다운로드", isPresented: $showAdd) {
                TextField("https://", text: $newURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("취소", role: .cancel) {}
                Button("다운로드") {
                    if let url = URL(string: newURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        addURL(url)
                    }
                }
            }
            .onChange(of: keepAlive) { _ in KeepAlive.shared.settingsChanged() }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let speed: Double?
    let manager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.title3)
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                actions
                    .buttonStyle(.borderless)
                    .font(.title3)
            }
            if item.state != .completed {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                } else if item.state == .downloading {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(item.state == .failed ? .red : .secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button { UIPasteboard.general.url = item.url } label: { Label("원본 URL 복사", systemImage: "link") }
            if !item.isForeground && item.state != .completed {
                Button { manager.restart(item.id) } label: { Label("처음부터 다시 받기", systemImage: "arrow.counterclockwise") }
            }
            if item.state == .completed {
                Button { openInFiles(manager.downloadsDirectory) } label: { Label("파일 앱에서 보기", systemImage: "folder") }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .downloading, .queued, .waiting:
            if !item.isForeground {
                Button { manager.pause(item.id) } label: { Image(systemName: "pause.circle") }
            }
        case .paused, .failed:
            if !item.isForeground {
                Button { manager.resume(item.id) } label: { Image(systemName: "play.circle") }
            }
        case .completed:
            ShareLink(item: manager.fileURL(for: item)) { Image(systemName: "square.and.arrow.up") }
        }
    }

    private var icon: String {
        switch item.state {
        case .queued, .downloading: return "arrow.down.circle.fill"
        case .waiting: return "clock.arrow.circlepath"
        case .paused: return "pause.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .queued, .downloading: return .accentColor
        case .waiting, .paused: return .orange
        case .failed: return .red
        case .completed: return .green
        }
    }

    private var statusLine: String {
        let received = Self.bytes(item.receivedBytes)
        let sizePart = item.totalBytes > 0 ? "\(received) / \(Self.bytes(item.totalBytes))" : received
        switch item.state {
        case .queued:
            return "대기 중"
        case .downloading:
            var parts = [sizePart]
            if let speed, speed > 0 {
                parts.append("\(Self.bytes(Int64(speed)))/s")
                if item.totalBytes > 0 {
                    let remaining = Double(item.totalBytes - item.receivedBytes) / speed
                    if let eta = Self.duration(remaining) { parts.append("\(eta) 남음") }
                }
            }
            if item.isForeground { parts.append("앱 내 다운로드") }
            return parts.joined(separator: " · ")
        case .waiting:
            return "재시도 대기 (\(item.retryCount)회) · \(item.errorMessage ?? "")"
        case .paused:
            return "일시정지 · \(sizePart)"
        case .failed:
            return "실패: \(item.errorMessage ?? "알 수 없는 오류")"
        case .completed:
            return "완료 · \(Self.bytes(item.totalBytes))"
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds)
    }
}

/// Files 앱을 해당 폴더로 연다
func openInFiles(_ directory: URL) {
    if let url = URL(string: "shareddocuments://" + directory.path) {
        UIApplication.shared.open(url)
    }
}
