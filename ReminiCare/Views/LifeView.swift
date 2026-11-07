import ReminiCareKit
import SwiftUI

struct LifeView: View {
    let onDone: () -> Void
    @State private var session = LifeSession.live()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ScrollView([.vertical]) {
                stage(width: width)
                    .padding(.horizontal, width < 600 ? 20 : 52)
                    .padding(.vertical, 18)
                    .frame(width: width)
                    .frame(minHeight: max(geometry.size.height, 720))
            }
            .scrollBounceBehavior(.basedOnSize)
            .animation(.easeInOut(duration: 0.28), value: session.stage)
        }
        .background(Color.white)
        .navigationBarBackButtonHidden()
        .logToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task {
                        await session.leave()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.backward").font(.system(size: 26, weight: .semibold))
                }
                .accessibilityLabel("返回")
            }
        }
        .task { await session.initialize() }
        .onDisappear { Task { await session.leave() } }
        .onChange(of: scenePhase) { _, phase in
            AppLog.shared.record(.app, .warning, detail: phase == .active ? "foreground" : "background")
            if phase != .active { Task { await session.interruptAudio() } }
        }
    }

    @ViewBuilder
    private func stage(width: CGFloat) -> some View {
        switch session.stage {
        case .topicLoading:
            if let error = session.errorMessage {
                Button(error) { Task { await session.initialize() } }.font(.system(size: 26))
            } else {
                LoadingStage(message: "正在準備今天的回憶主題", width: width)
            }
        case .topicSelection: TopicSelectionStage(session: session, width: width)
        case .introduction: IntroductionStage(session: session, width: width)
        case .question: QuestionStage(session: session, width: width)
        case .imageGenerating: LoadingStage(message: "正在把回憶變成照片…", width: width)
        case .evaluation: EvaluationStage(session: session, width: width)
        case .revisionRecording: RevisionStage(session: session, width: width)
        case .revisionGenerating: LoadingStage(message: "正在調整照片…", width: width)
        case .summary: SummaryStage(session: session, width: width, onDone: onDone)
        }
    }
}

private struct LoadingStage: View {
    let message: String
    let width: CGFloat
    var body: some View {
        VStack(spacing: 36) {
            Spacer()
            ProgressView().controlSize(.extraLarge).tint(Theme.yellow)
            Text(message).font(.system(size: Theme.action(width))).multilineTextAlignment(.center)
            Spacer()
        }
    }
}

private struct TopicSelectionStage: View {
    let session: LifeSession
    let width: CGFloat
    var body: some View {
        VStack(spacing: 28) {
            Text("今天想聊什麼？").font(.system(size: Theme.title(width)))
            if let warning = session.topicWarning {
                Label("LLM 未成功，已使用本地題庫：\(warning)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(red: 0.48, green: 0.24, blue: 0))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 1, green: 0.95, blue: 0.88), in: RoundedRectangle(cornerRadius: 16))
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: width < 600 ? 1 : 4)
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(session.topics) { topic in
                    TopicCard(topic: topic, width: width) { session.selectTopic(topic) }
                }
            }
            Spacer()
            PillButton(label: "我想聊別的") { await session.refreshTopics() }
        }
    }
}

private struct TopicCard: View {
    let topic: ReminiscenceTopic
    let width: CGFloat
    let select: () -> Void
    @State private var showAttribution = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .aspectRatio(width < 600 ? 2 : 0.85, contentMode: .fit)
                        .overlay {
                            if let url = topic.imageURL, let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Theme.placeholder.overlay(Image(systemName: "photo").font(.system(size: 62)).foregroundStyle(Theme.muted))
                            }
                        }
                        .clipped()
                    if topic.attribution != nil {
                        Button { showAttribution = true } label: {
                            Image(systemName: "info.circle").font(.system(size: 22)).foregroundStyle(.white)
                                .padding(8).background(.black.opacity(0.58), in: Circle())
                        }
                        .padding(8)
                        .accessibilityLabel("圖片來源與授權")
                    }
                }
                Text(topic.title)
                    .font(.system(size: Theme.body(width), weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(18)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 31))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .alert("圖片來源與授權", isPresented: $showAttribution, presenting: topic.attribution) { attribution in
            if let url = URL(string: attribution.originalUrl), url.scheme == "https" {
                Link("查看原圖", destination: url)
            }
            if let url = URL(string: attribution.licenseUrl), url.scheme == "https" {
                Link("查看授權", destination: url)
            }
            Button("關閉", role: .cancel) {}
        } message: { attribution in
            Text([
                attribution.title,
                topic.illustrative ? "示意照片：用於引導回憶，並非當年的歷史照片。" : nil,
                "作者：\(attribution.creator)", "來源：\(attribution.source)", "授權：\(attribution.license)",
            ].compactMap { $0 }.joined(separator: "\n"))
        }
    }
}

private struct LanguageSelector: View {
    let session: LifeSession
    var body: some View {
        HStack(spacing: 14) {
            ForEach(SpeechLanguage.allCases, id: \.self) { language in
                Button {
                    Task { await session.replayLanguage(language) }
                } label: {
                    Text(language.rawValue)
                        .font(.system(size: 21))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(session.selectedLanguage == language ? Theme.yellow : Theme.languagePill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Warnings, retry buttons and recognition progress.
private struct TranscriptionFeedback: View {
    let session: LifeSession
    var body: some View {
        VStack(spacing: 8) {
            if let warning = session.audioWarning {
                Text(warning).font(.system(size: 20)).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if session.canRetryLastStep {
                Button("重試處理", systemImage: "arrow.clockwise") { Task { await session.retryLastStep() } }
            }
            if session.isTranscribing {
                ProgressView().frame(maxWidth: 320)
                Text("辨識中 \(session.transcriptionComplete)/\(session.transcriptionTotal)").font(.system(size: 20))
            }
            if session.stage == .introduction, let error = session.errorMessage {
                Text(error).font(.system(size: 18)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if session.canRetryTranscription {
                Button(session.hasInterruptedRecording ? "辨識保留的錄音" : "重試辨識", systemImage: "arrow.clockwise") {
                    Task { await session.retryTranscription() }
                }
            }
        }
    }
}

private struct IntroductionStage: View {
    let session: LifeSession
    let width: CGFloat
    @State private var editing: ParticipantAddress?
    @State private var editingRevision = 0

    var body: some View {
        let state = session.introductionState
        VStack(spacing: 0) {
            Spacer()
            Text("請大家介紹自己").font(.system(size: Theme.title(width))).multilineTextAlignment(.center)
            Text(session.currentElderName.isEmpty ? "我叫＿＿＿＿" : "稱呼您：\(session.currentElderName)")
                .font(.system(size: Theme.action(width)))
                .padding(.horizontal, 42).padding(.vertical, 18)
                .background(Theme.paleYellow, in: RoundedRectangle(cornerRadius: 32))
                .padding(.top, 34)
            if state == .confirmed || (state == .ready && session.errorMessage != nil) {
                Button("修改稱呼", systemImage: "pencil") {
                    editingRevision = session.introductionRevision
                    editing = ParticipantAddress.fromDisplayName(session.currentElderName)
                }
                .font(.system(size: 24))
                .padding(.top, 8)
                Text("確認稱呼正確後，按「下一位」或「開始聊天」。").font(.system(size: 20))
            }
            TranscriptionFeedback(session: session).padding(.top, 40)
            Group {
                if state == .processing {
                    ProgressView().controlSize(.large).tint(Theme.yellow)
                } else if state == .confirmed {
                    HStack(spacing: 28) {
                        RoundAction(label: "下一位", systemImage: "person.badge.plus") { session.addNextParticipant() }
                        RoundAction(label: "開始聊天", systemImage: "bubble.left.fill") { await session.finishIntroduction() }
                    }
                } else if state == .recording {
                    RoundAction(label: "說完了", systemImage: "stop.fill") { await session.stopRecording() }
                } else {
                    RoundAction(label: session.canRetryTranscription ? "重新錄音" : "開始介紹", systemImage: "mic.fill") {
                        await session.startIntroductionRecording()
                    }
                }
            }
            .padding(.top, 12)
            Spacer()
        }
        .sheet(item: Binding(get: { editing.map(EditingAddress.init) }, set: { editing = $0?.address })) { item in
            ParticipantAddressSheet(initial: item.address) { address in
                session.correctParticipantAddress(address, revision: editingRevision)
            }
        }
    }
}

private struct EditingAddress: Identifiable {
    let address: ParticipantAddress
    var id: String { address.displayName }
}

private struct RecordButton: View {
    let session: LifeSession
    let start: () async -> Void
    var body: some View {
        RoundAction(
            label: session.isRecording ? "說完了" : (session.canRetryTranscription ? "重新錄音" : "開始說"),
            systemImage: session.isRecording ? "stop.fill" : "mic.fill"
        ) {
            if session.isRecording { await session.stopRecording() } else { await start() }
        }
    }
}

private struct QuestionStage: View {
    let session: LifeSession
    let width: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            LanguageSelector(session: session)
            TranscriptionFeedback(session: session)
            Spacer(minLength: 24)
            Text(session.currentQuestion)
                .font(.system(size: Theme.action(width)))
                .lineSpacing(8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34).padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .background(Theme.paleYellow, in: RoundedRectangle(cornerRadius: 32))
            if let error = session.errorMessage {
                Text(error).font(.system(size: 18)).foregroundStyle(.red).padding(.top, 16)
            }
            Spacer(minLength: 24)
            if session.isRecording {
                Text("錄音中 \(session.recordSeconds) 秒").font(.system(size: Theme.body(width))).foregroundStyle(Theme.muted)
            }
            RecordButton(session: session) { await session.startAnswerRecording() }.padding(.top, 16)
            Button("不想繼續聊") { Task { await session.finishSession() } }
                .font(.system(size: 22)).foregroundStyle(Theme.muted).padding(.top, 18)
        }
    }
}

private struct EvaluationStage: View {
    let session: LifeSession
    let width: CGFloat
    var body: some View {
        let compact = width < 900
        let controls = VStack(spacing: 0) {
            LanguageSelector(session: session)
            Text(session.hasExtension ? "這樣像嗎？" : "這張照片像您的回憶嗎？")
                .font(.system(size: Theme.title(width)))
                .multilineTextAlignment(.center)
                .padding(.top, 32)
            HStack(spacing: 24) {
                RoundAction(label: "像", systemImage: "hand.thumbsup.fill") { await session.chooseLike() }
                RoundAction(label: "不太像", systemImage: "slider.horizontal.3") { session.chooseDislike() }
            }
            .padding(.top, 46)
            Button("不想繼續聊") { Task { await session.finishSession() } }
                .font(.system(size: 22)).foregroundStyle(Theme.muted).padding(.top, 18)
        }
        if compact {
            VStack(spacing: 24) {
                MemoryImage(url: session.currentImageURL)
                controls
            }
        } else {
            HStack(spacing: 46) {
                MemoryImage(url: session.currentImageURL).frame(maxWidth: .infinity)
                controls.frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct RevisionStage: View {
    let session: LifeSession
    let width: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            LanguageSelector(session: session)
            TranscriptionFeedback(session: session)
            Spacer(minLength: 24)
            Text("哪裡不太像呢？").font(.system(size: Theme.title(width)))
            Text(session.canEditImage ? "我會依照您的描述修改這張照片" : "目前的服務不支援原圖編輯，會重新產生一張照片")
                .font(.system(size: Theme.body(width))).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.top, 18)
            if let error = session.errorMessage {
                Text(error).font(.system(size: 18)).foregroundStyle(.red).padding(.top, 16)
            }
            Spacer(minLength: 24)
            if session.isRecording {
                Text("錄音中 \(session.recordSeconds) 秒").font(.system(size: Theme.body(width)))
            }
            RecordButton(session: session) { await session.startRevisionRecording() }.padding(.top, 16)
        }
    }
}

private struct SummaryStage: View {
    let session: LifeSession
    let width: CGFloat
    let onDone: () -> Void
    var body: some View {
        let info = VStack(alignment: .leading, spacing: 18) {
            Text("今天的回憶").font(.system(size: Theme.title(width))).padding(.bottom, 8)
            line("主題", session.selectedTopic?.title ?? "懷舊時光")
            line("分享者", session.elderNames.isEmpty ? "未留名" : session.elderNames.joined(separator: "、"))
            line("關鍵字", session.keywords.isEmpty ? "一起聊天的溫暖時光" : session.keywords.joined(separator: "、"))
        }
        VStack(spacing: 24) {
            if width < 600 {
                info
                MemoryImage(url: session.currentImageURL)
            } else {
                HStack(spacing: 42) {
                    info.frame(maxWidth: .infinity, alignment: .leading)
                    MemoryImage(url: session.currentImageURL).frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            PillButton(label: session.isSaving ? "保存中…" : "保存今天的回憶", disabled: session.isSaving) {
                if await session.saveMemory() { onDone() }
            }
            if let error = session.errorMessage {
                Text(error).font(.system(size: 20)).foregroundStyle(.red)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        Text("\(label)：\(value)").font(.system(size: Theme.body(width))).lineSpacing(6)
    }
}
