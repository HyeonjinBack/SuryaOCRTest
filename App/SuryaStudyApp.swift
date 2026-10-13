import SwiftUI

@main
struct SuryaStudyApp: App {
    @StateObject private var store = StudyStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onAppear { store.startup() }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("PDF 열기…") { store.choosePDF() }
                    .keyboardShortcut("o")
                    .disabled(store.isBusy)
                Button("예제 PDF 열기") { store.loadSample() }
                    .disabled(store.isBusy)
            }
            CommandGroup(after: .saveItem) {
                Button("추출 결과 JSON 내보내기…") { store.exportJSON() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.result == nil || store.isBusy)
            }
            CommandMenu("문서 추출") {
                Button("현재 페이지 추출") { store.recognizeCurrentPage() }
                    .keyboardShortcut("r")
                    .disabled(store.document == nil || !store.modelReady || store.isBusy)
                Button("추출 취소") { store.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!store.isBusy)
            }
        }
    }
}
