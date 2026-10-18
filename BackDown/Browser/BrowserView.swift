import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var addressFocused: Bool
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("주소 또는 검색어", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        model.go(draft)
                        addressFocused = false
                    }
                if addressFocused {
                    Button("취소") {
                        addressFocused = false
                        draft = model.addressText
                    }
                } else if model.isLoading {
                    Button { model.webView.stopLoading() } label: { Image(systemName: "xmark") }
                } else {
                    Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .opacity(model.isLoading ? 1 : 0)

            WebViewContainer(webView: model.webView)

            Divider()
            HStack {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                Spacer()
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                Spacer()
                Button {
                    if let url = model.webView.url {
                        model.download(url: url, suggestedName: nil, referer: nil)
                    }
                } label: { Image(systemName: "arrow.down.circle") }
                Spacer()
                if let url = model.webView.url {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                } else {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
                }
                Spacer()
                Button { model.goHome() } label: { Image(systemName: "house") }
            }
            .font(.title3)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 64)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .onAppear { draft = model.addressText }
        .onChange(of: model.addressText) { newValue in
            if !addressFocused { draft = newValue }
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
