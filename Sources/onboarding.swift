// 처음 실행 안내. 끝나기 전에는 디스코드를 건드리지 않는다.
// 설명 대신 실제 번역을 먼저 보여 주고, 핵심 버튼은 화면마다 하나, 부탁은 첫 번역이 성공한 뒤에 한다.

import AppKit
import SwiftUI

enum DiscordState {
    case off, needsRestart, ready
}

enum GuideStage: String {
    case waiting, success, pack
}

private struct SampleMessage: Identifiable {
    let id: String // 원문 언어
    let author: String
    let color: Color
    let text: String
    let korean: String? // 번역 기능을 아직 쓸 수 없을 때 보여 줄 예시
}

private let sampleMessages = [
    SampleMessage(id: "en", author: "Alex", color: .blue, text: "Anyone up for a raid tonight?", korean: "오늘 밤 레이드 갈 사람 있어?"),
    SampleMessage(id: "ja", author: "Yuki", color: .pink, text: "明日の夜、一緒にレイドに行きませんか？", korean: "내일 밤에 같이 레이드 가실래요?"),
    SampleMessage(id: "zh", author: "Wei", color: .orange, text: "有人知道这个视频为什么一直导出失败吗？", korean: "이 영상이 왜 계속 내보내기에 실패하는지 아시는 분 있나요?"),
    SampleMessage(id: "ko", author: "민수", color: .green, text: "오늘 저녁에 같이 할 사람 있어요?", korean: nil),
]

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var showsOptions = CommandLine.arguments.contains("--expanded")
    @State private var askedDownload = false
    @State private var translations: [String: String] = [:]
    @State private var samplesDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("외국어 채팅을 바로 읽어요").font(.system(size: 24, weight: .bold))
                Text("디스코드 메시지 아래에 이렇게 번역이 붙어요.")
                    .foregroundStyle(.secondary)
            }
            sampleChannel
            options
            Spacer(minLength: 0)
            notice
            Button(action: primaryAction) {
                Text(primaryTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.downloadRequest != nil)
        }
        .padding(.horizontal, 40)
        .padding(.top, 48)
        .padding(.bottom, 32)
        .frame(width: 520, height: 640)
        .packDownloadTask(model, host: .onboarding)
        .task(id: sampleKey) { await translateSamples() }
    }

    // MARK: 샘플

    private var visibleSamples: [SampleMessage] {
        let target = Locale.Language(identifier: model.target).languageCode?.identifier
        return Array(sampleMessages.filter { $0.id != target }.prefix(3))
    }

    private var sampleKey: String {
        "\(model.target)|\(String(describing: model.modelChoice))|\(model.usesLanguagePacks)|\(model.targetInstalled)"
    }

    private func translateSamples() async {
        translations = [:]
        samplesDone = false
        for sample in visibleSamples {
            let translated = await model.translateSample(sample.text, from: sample.id)
            guard !Task.isCancelled else { return }
            translations[sample.id] = translated ?? (model.target == "ko" ? sample.korean : nil)
        }
        samplesDone = true
    }

    // 디스코드 화면처럼 보이도록 시스템 색이 아니라 디스코드 색을 쓴다.
    private var sampleChannel: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(visibleSamples) { sample in
                HStack(alignment: .top, spacing: 16) {
                    Circle()
                        .fill(sample.color)
                        .frame(width: 32, height: 32)
                        .overlay(Text(String(sample.author.prefix(1))).font(.callout.weight(.semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sample.author).font(.callout.weight(.semibold)).foregroundStyle(.white)
                        Text(sample.text).foregroundStyle(Color(red: 0.86, green: 0.87, blue: 0.88))
                        Text(translations[sample.id] ?? (samplesDone ? "언어팩을 받으면 여기에 번역이 나와요." : "번역 중…"))
                            .font(.callout)
                            .foregroundStyle(Color(red: 0.62, green: 0.65, blue: 0.68))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.19, green: 0.2, blue: 0.22)))
    }

    // MARK: 선택(접어 둠)

    private var currentChoice: String {
        guard model.canChooseModel else { return "언어팩" }
        switch model.modelChoice {
        case nil: return model.usesLanguagePacks ? "자동 (언어팩)" : "자동 (Apple Intelligence)"
        case false?: return "Apple Intelligence"
        case true?: return "언어팩"
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(model.targetName)로 번역 · \(currentChoice)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(showsOptions ? "접기" : "바꾸기") { showsOptions.toggle() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            if showsOptions {
                Picker("번역될 언어", selection: Binding(get: { model.target }, set: { selectLanguage($0) })) {
                    ForEach(model.onboardingLanguages) { Text($0.name).tag($0.id) }
                }
                if model.canChooseModel {
                    Picker("번역 모델", selection: Binding(get: { model.modelChoice }, set: { selectModel($0) })) {
                        Text("자동").tag(Bool?.none)
                        Text("Apple Intelligence").tag(Bool?.some(false))
                        Text("언어팩").tag(Bool?.some(true))
                    }
                    .disabled(model.downloadRequest != nil)
                }
            }
        }
    }

    private func selectLanguage(_ id: String) {
        logLine("온보딩: 언어 변경 \(id)")
        model.select(id)
        askedDownload = false
    }

    private func selectModel(_ value: Bool?) {
        logLine("온보딩: 모델 변경 \(value.map { $0 ? "언어팩" : "Apple Intelligence" } ?? "자동")")
        model.setUsesLanguagePacks(value)
    }

    // MARK: 고지와 버튼

    private var notice: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.targetInstalled, askedDownload {
                Text("「다운로드」를 눌렀다면 뒤에서 받고 있어요. 다 받으면 번역을 시작해요.")
            }
            if model.discordState == .needsRestart {
                Text("지금 켜진 디스코드를 껐다가 다시 켜요. 음성 채널에 있으면 연결이 끊겨요.")
            }
            Text("이 앱으로 켠 디스코드는 꺼질 때까지 디버그 포트가 열려 있어서, 같은 맥의 다른 프로그램이 디스코드 세션에 접근할 수 있어요. 믿을 수 있는 프로그램만 쓰는 맥에서 켜 주세요.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var needsPackFirst: Bool { !model.targetInstalled && !askedDownload }

    private var primaryTitle: String {
        if needsPackFirst { return "언어팩 받기" }
        return model.discordState == .needsRestart ? "다시 시작하고 번역 켜기" : "번역 켜기"
    }

    private func primaryAction() {
        if needsPackFirst {
            logLine("온보딩: 언어팩 받기")
            askedDownload = true
            model.requestDownload(model.target, select: false)
        } else {
            model.finishOnboarding()
        }
    }
}

// MARK: - 첫 번역까지의 안내

// 번역을 켜도 디스코드는 친구 화면으로 열려서 볼 메시지가 없다. 첫 번역이 붙을 때까지 다음 할 일을 알려 주고,
// 성공한 뒤에야 부탁을 하나씩 한다.
struct GuideView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.guideStage {
            case .waiting: waiting
            case .success: success
            case .pack: pack
            case nil: EmptyView()
            }
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .packDownloadTask(model, host: .guide)
    }

    private var waiting: some View {
        HStack(alignment: .top, spacing: 16) {
            ProgressView().controlSize(.small)
            heading("이제 외국어 채널을 열어 보세요", "메시지 아래에 번역이 붙으면 성공이에요.")
        }
    }

    @ViewBuilder private var success: some View {
        heading("첫 번역이 붙었어요", "번역 줄은 디스코드에서 Ctrl+Shift+T로 숨길 수 있어요. 설정은 화면 위쪽 막대의 아이콘에 있어요.")
        if model.loginItem == .enabled {
            buttons(primary: "확인", secondary: nil, primaryAction: model.closeGuide, secondaryAction: {})
        } else {
            Text("맥을 켤 때 번역도 함께 켤까요?").font(.headline)
            if let error = model.loginItemError {
                Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            buttons(primary: "함께 켜기", secondary: "나중에", primaryAction: model.acceptLoginItem, secondaryAction: model.declineLoginItem)
        }
    }

    @ViewBuilder private var pack: some View {
        heading("언어팩을 받으면 훨씬 빨라져요", "방금처럼 긴 글도 거의 바로 번역돼요. 언어마다 한 번만 받으면 돼요.")
        buttons(primary: "언어팩 받기", secondary: "괜찮아요", primaryAction: model.acceptPackHint, secondaryAction: model.declinePackHint)
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buttons(primary: String, secondary: String?, primaryAction: @escaping () -> Void, secondaryAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if let secondary {
                Button(secondary, action: secondaryAction).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(primary, action: primaryAction)
                .buttonStyle(GuidePrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.downloadRequest != nil)
        }
    }
}

// 안내창은 디스코드 쪽 포커스를 뺏지 않아 비활성 상태로 뜬다. 기본 강조 버튼은 비활성 창에서 회색이 되므로 색을 직접 칠한다.
private struct GuidePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}
