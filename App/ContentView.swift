import SwiftUI
import PDFKit
import Combine

private enum ResultMode: String, CaseIterable {
    case blocks = "텍스트"
    case source = "원본 HTML"
}

private final class ResultPresentation: ObservableObject {
    @Published var mode: ResultMode = .blocks
}

struct ContentView: View {
    @ObservedObject var store: StudyStore
    @StateObject private var presentation = ResultPresentation()

    var body: some View {
        VStack(spacing: 0) {
            documentHeader
            Divider()
            HSplitView {
                documentPane
                    .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                resultPane
                    .frame(minWidth: 370, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 980, minHeight: 660)
        .navigationTitle("Surya Study")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: store.choosePDF) {
                    Label("PDF 열기", systemImage: "folder")
                }
                .help("논문 PDF 열기 (⌘O)")
                .disabled(store.isBusy)
                .accessibilityIdentifier("openPDF")

                Button(action: store.loadSample) {
                    Label("예제", systemImage: "doc.text")
                }
                .help("예제 PDF로 문서 추출 확인")
                .disabled(store.isBusy)
                .accessibilityIdentifier("loadSample")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isBusy {
                    Button(action: store.cancel) {
                        Label("취소", systemImage: "stop.circle")
                    }
                    .accessibilityIdentifier("cancelRecognition")
                } else {
                    Button(action: store.recognizeCurrentPage) {
                        Label("현재 페이지 추출", systemImage: "text.viewfinder")
                    }
                    .disabled(store.document == nil || !store.modelReady)
                    .help("Surya로 현재 페이지의 텍스트와 구조 추출 (⌘R)")
                    .accessibilityIdentifier("recognizePage")
                }

                Button(action: store.exportJSON) {
                    Label("JSON 내보내기", systemImage: "square.and.arrow.up")
                }
                .disabled(store.result == nil || store.isBusy)
                .help("현재 추출 결과를 JSON 파일로 저장")
                .accessibilityIdentifier("exportJSON")
            }
        }
        .alert("문서를 처리할 수 없습니다", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var documentHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.documentURL?.lastPathComponent ?? "논문 문서 추출")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(store.document == nil
                     ? "PDF를 열고, 페이지의 텍스트와 구조를 확인하세요."
                     : "\(store.pageCount)페이지 · PDF 원문과 Surya 추출 결과")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            Label("이 Mac에서 처리", systemImage: "desktopcomputer")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var documentPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("원문", systemImage: "doc")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if store.document != nil {
                    Button {
                        store.selectPage(store.pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("이전 페이지")
                    .disabled(store.pageIndex <= 0 || store.isBusy)
                    .accessibilityLabel("이전 페이지")
                    .accessibilityIdentifier("previousPage")

                    Text("\(store.pageIndex + 1) / \(store.pageCount)")
                        .font(.subheadline.monospacedDigit())
                        .frame(minWidth: 64)
                        .accessibilityLabel("전체 \(store.pageCount)페이지 중 \(store.pageIndex + 1)페이지")
                        .accessibilityIdentifier("pageIndicator")

                    Button {
                        store.selectPage(store.pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("다음 페이지")
                    .disabled(store.pageIndex + 1 >= store.pageCount || store.isBusy)
                    .accessibilityLabel("다음 페이지")
                    .accessibilityIdentifier("nextPage")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .frame(height: 48)
            Divider()
            if let document = store.document {
                PDFReaderView(
                    document: document,
                    pageIndex: store.pageIndex,
                    selectedBlock: selectedBlock,
                    imageWidth: store.result?.imageWidth ?? 0,
                    imageHeight: store.result?.imageHeight ?? 0,
                    onPageChange: { index in
                        if store.pageIndex != index { store.selectPage(index) }
                    }
                )
                .allowsHitTesting(!store.isBusy)
                .accessibilityIdentifier("pdfReader")
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 52, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        Text("논문을 펼쳐 보세요")
                            .font(.title3.weight(.semibold))
                        Text("PDF 한 페이지의 본문, 제목, 표를\nSurya로 추출하는 온디바이스 실험입니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    HStack {
                        Button("PDF 열기…", action: store.choosePDF)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("openPDFEmptyState")
                        Button("예제로 시작", action: store.loadSample)
                            .accessibilityIdentifier("loadSampleEmptyState")
                    }
                    .disabled(store.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    private var resultPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("추출 결과", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let result = store.result {
                    Text("\(result.blocks.count)개 영역 · \(result.elapsedSeconds, specifier: "%.1f")초")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            Divider()

            if let result = store.result {
                Picker("결과 표시 방식", selection: $presentation.mode) {
                    ForEach(ResultMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(16)
                .accessibilityIdentifier("resultMode")

                if presentation.mode == .blocks {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if result.blocks.isEmpty {
                                Text("이 페이지에서 텍스트 영역이 추출되지 않았습니다. 원본 HTML을 확인해 보세요.")
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                            }
                            ForEach(result.blocks, id: \.id) { block in
                                blockCard(block)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    .accessibilityIdentifier("extractedBlocks")
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(result.rawHTML.isEmpty ? "출력된 HTML이 없습니다." : result.rawHTML)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                    .accessibilityIdentifier("rawHTML")
                }
                Divider()
                Label("영역을 선택하면 원문의 위치를 표시합니다.", systemImage: "viewfinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 16) {
                    if store.isBusy {
                        ProgressView()
                            .controlSize(.large)
                        Text("현재 페이지를 읽고 있습니다")
                            .font(.headline)
                        Text("모델을 처음 불러올 때는 시간이 걸릴 수 있습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 38, weight: .ultraLight))
                            .foregroundStyle(.tertiary)
                        Text("원문을 읽을 준비")
                            .font(.headline)
                        Text("PDF를 연 뒤 ‘현재 페이지 추출’을 누르세요.\n읽기 순서에 따라 텍스트 영역을 보여 줍니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func blockCard(_ block: OCRBlock) -> some View {
        let isSelected = store.selectedBlockID == block.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                store.selectBlock(block.id)
            } label: {
                HStack {
                    Text(displayLabel(block.label))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if block.bbox != nil {
                        Label("원문 위치", systemImage: "scope")
                            .font(.caption)
                    }
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayLabel(block.label)) 원문 위치 선택")
            .accessibilityIdentifier("block_\(block.id)")

            Text(block.text.isEmpty ? "텍스트가 없는 영역" : block.text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Text(store.status)
                .lineLimit(1)
                .accessibilityIdentifier("processingStatus")
            Spacer(minLength: 20)
            Label(store.modelReady ? "Surya 준비됨" : "모델 확인 필요", systemImage: store.modelReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(store.modelReady ? Color.secondary : Color.orange)
                .help(store.modelStatus)
                .accessibilityLabel(store.modelStatus)
                .accessibilityIdentifier("modelStatus")
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(.bar)
    }

    private var selectedBlock: OCRBlock? {
        guard let result = store.result,
              result.pageIndex == store.pageIndex,
              let id = store.selectedBlockID else { return nil }
        return result.blocks.first { $0.id == id }
    }

    private func displayLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "text", "paragraph": return "본문"
        case "title": return "제목"
        case "sectionheader", "section-header", "section_header", "heading": return "소제목"
        case "table": return "표"
        case "formula", "equation": return "수식"
        case "figure", "picture", "image": return "그림"
        case "caption": return "캡션"
        case "listitem", "list-item", "list_item": return "목록"
        case "pageheader", "page-header", "page_header": return "머리말"
        case "pagefooter", "page-footer", "page_footer": return "꼬리말"
        case "footnote": return "각주"
        case "reference": return "참고문헌"
        default: return value.isEmpty ? "텍스트" : value
        }
    }
}
