import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class StudyStore: ObservableObject {
    @Published var document: PDFDocument?
    @Published var documentURL: URL?
    @Published var pageIndex = 0
    @Published var isBusy = false
    @Published var status = "PDF를 선택하거나 예제 문서를 열어 시작하세요."
    @Published var result: OCRPageResult?
    @Published var errorMessage: String?
    @Published var selectedBlockID: String?
    @Published var modelReady = false
    @Published var modelStatus = "모델 확인 중"

    var pageCount: Int { document?.pageCount ?? 0 }

    private var service: NativeOCRService?
    private var task: Task<Void, Never>?
    private var scopedURL: URL?
    private var started = false
    private var smokeMode = false
    private var smokeCancel = false
    private var isPresentingPanel = false
    private var pageCache: [Int: OCRPageResult] = [:]

    func startup() {
        guard !started else { return }
        started = true
        if let modelURL = Bundle.main.url(forResource: "surya-2", withExtension: "gguf", subdirectory: "Models"),
           let projectorURL = Bundle.main.url(forResource: "surya-2-mmproj", withExtension: "gguf", subdirectory: "Models") {
            service = NativeOCRService(modelURL: modelURL, projectorURL: projectorURL)
            modelReady = true
            modelStatus = "온디바이스 모델 준비됨"
        } else {
            modelStatus = "모델 파일이 없습니다"
            errorMessage = "개발용 모델 준비가 필요합니다. Scripts/prepare_dependencies.py를 실행한 뒤 다시 빌드하세요."
        }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        smokeMode = arguments.contains("--smoke-test")
        smokeCancel = arguments.contains("--smoke-cancel")
        if arguments.contains("--sample") || smokeMode || smokeCancel { loadSample() }
        if smokeMode || smokeCancel {
            recognizeCurrentPage()
        }
        #endif
    }

    func choosePDF() {
        guard !isBusy, !isPresentingPanel else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "논문 열기"
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openDocument(at: url, securityScoped: true)
        }
    }

    func loadSample() {
        guard !isBusy else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SuryaStudy/sample.pdf")
            try SampleDocument.write(to: url)
            openDocument(at: url, securityScoped: false)
        } catch { errorMessage = error.localizedDescription }
    }

    private func openDocument(at url: URL, securityScoped: Bool) {
        let hasAccess = securityScoped && url.startAccessingSecurityScopedResource()
        guard let opened = PDFDocument(url: url), !opened.isLocked, opened.pageCount > 0 else {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
            errorMessage = "PDF를 열 수 없습니다. 암호화 여부와 파일 형식을 확인하세요."
            return
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = hasAccess ? url : nil
        documentURL = url
        document = opened
        pageIndex = 0
        pageCache.removeAll()
        result = nil
        selectedBlockID = nil
        errorMessage = nil
        status = "문서를 열었습니다. 현재 페이지를 추출하세요."
    }

    func selectPage(_ index: Int) {
        guard !isBusy, index >= 0, index < pageCount else { return }
        pageIndex = index
        result = pageCache[index]
        selectedBlockID = nil
        status = result == nil ? "현재 페이지를 추출할 수 있습니다." : "이 페이지의 추출 결과를 표시합니다."
    }

    func selectBlock(_ id: String) { selectedBlockID = id }

    func recognizeCurrentPage() {
        guard !isBusy, let url = documentURL, let service else {
            if smokeMode || smokeCancel { finishSmoke(success: false, detail: "Document or models unavailable") }
            return
        }
        let index = pageIndex
        isBusy = true
        errorMessage = nil
        result = nil
        selectedBlockID = nil
        status = "페이지 이미지를 준비하고 있습니다…"
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuryaStudy/\(UUID().uuidString)", isDirectory: true)
        let imageURL = workDirectory.appendingPathComponent("page.png")
        task = Task {
            defer {
                isBusy = false
                task = nil
                try? FileManager.default.removeItem(at: workDirectory)
            }
            do {
                let render = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                    guard let pdf = PDFDocument(url: url) else {
                        throw NativeOCRError.message("처리할 PDF를 다시 열 수 없습니다.")
                    }
                    return try PDFRenderer.render(document: pdf, pageIndex: index, to: imageURL, dpi: 144)
                }.value
                try Task.checkCancellation()
                status = "모델을 준비하고 페이지를 읽고 있습니다…"
                let start = Date()
                let html = try await service.recognize(imageURL: render.url) { [weak self] count in
                    Task { @MainActor in
                        guard let self, self.isBusy, self.task?.isCancelled != true else { return }
                        self.status = "문서 내용을 추출하고 있습니다… \(count) 토큰"
                        if self.smokeCancel && count == 1 { self.cancel() }
                    }
                }
                try Task.checkCancellation()
                let parsed = try SuryaHTMLParser.parse(html, pageIndex: index,
                    imageWidth: render.pixelWidth, imageHeight: render.pixelHeight,
                    elapsedSeconds: Date().timeIntervalSince(start))
                result = parsed
                pageCache[index] = parsed
                status = "\(parsed.blocks.count)개 영역 추출 완료 · \(String(format: "%.1f", parsed.elapsedSeconds))초"
                NSLog("SURYA_RESULT blocks=%ld elapsed=%.2f page=%ld", parsed.blocks.count, parsed.elapsedSeconds, index + 1)
                if smokeMode {
                    let text = parsed.blocks.map(\.text).joined(separator: "\n")
                    let success = text.localizedCaseInsensitiveContains("Surya Local OCR Check") && text.contains("42")
                    finishSmoke(success: success, detail: text)
                }
            } catch is CancellationError {
                status = "추출을 취소했습니다."
                if smokeCancel { finishSmoke(success: true, detail: "Cancellation reached native engine") }
                else if smokeMode { finishSmoke(success: false, detail: "Unexpected cancellation") }
            } catch {
                status = "추출을 완료하지 못했습니다."
                errorMessage = error.localizedDescription
                if smokeMode || smokeCancel { finishSmoke(success: false, detail: error.localizedDescription) }
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        status = "취소하는 중입니다…"
        task?.cancel()
        service?.cancel()
    }

    func exportJSON() {
        guard let result, !isBusy, !isPresentingPanel else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(documentURL?.deletingPathExtension().lastPathComponent ?? "document")-page-\(result.pageIndex + 1).json"
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.save(result, to: url)
        }
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            errorMessage = "파일 대화상자를 표시할 앱 창을 찾을 수 없습니다."
            return
        }
        isPresentingPanel = true
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.isPresentingPanel = false
            completion(response)
        }
    }

    private func save(_ result: OCRPageResult, to url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(result).write(to: url, options: .atomic)
            status = "JSON 결과를 저장했습니다."
        } catch { errorMessage = error.localizedDescription }
    }

    private func finishSmoke(success: Bool, detail: String) {
        NSLog("SURYA_SMOKE_%@: %@", success ? "PASS" : "FAIL", detail)
        // Test mode exits only after output has been produced. Normal launches stay open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(success ? 0 : 1) }
    }
}
