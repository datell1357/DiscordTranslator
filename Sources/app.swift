// 앱 껍데기: 설정 저장, 번역 언어 목록, 로그인 항목, 새 버전 알림, 설정 창, 상단 막대.

import AppKit
import FoundationModels
import ServiceManagement
import SwiftUI
import Translation

// 언어를 쓸 수 있는지는 언어 쌍으로만 물을 수 있어서, 번역될 언어마다 기준으로 삼을 원문 언어를 정한다.
func referenceSource(for target: String) -> Locale.Language {
    Locale.Language(identifier: Locale.Language(identifier: target).languageCode?.identifier == "en" ? "ko" : "en")
}
// 시험은 상단 막대 아이콘과 창 없이 돌려 사용자 화면을 가리지 않는다.
let isHeadless = CommandLine.arguments.contains("--headless") || optionValue("--attach") != nil

@MainActor var appDelegate: AppDelegate?

// MARK: - 설정

struct AppSettings: Codable, Equatable {
    var targetLanguage: String?
    var restartWithoutAsking: Bool?
    var usesLanguagePacks: Bool?
    var onboardingPending: Bool? // 안내를 끝내지 않고 앱을 끄면 다음에 다시 띄운다.
    var packHintShown: Bool? // 언어팩 제안은 한 번만 한다.
}

struct LanguageChoice: Identifiable, Hashable {
    let id: String
    let name: String

    init(id: String) {
        self.id = id
        // 앱 글자가 한국어뿐이라 언어 이름도 한국어로 쓴다. 「zh」로는 간체인지 알 수 없다.
        let display = id == "zh" ? "zh-Hans" : id
        name = Locale(identifier: "ko").localizedString(forIdentifier: display) ?? id
    }
}

enum AppStatus: Equatable {
    case starting
    case waitingForLanguage
    case translating
    case discordOff
    case discordWithoutTranslation

    var text: String {
        switch self {
        case .starting: "시작하는 중"
        case .waitingForLanguage: "번역 언어를 기다리는 중"
        case .translating: "번역 중"
        case .discordOff: "디스코드가 꺼져 있어요"
        case .discordWithoutTranslation: "디스코드가 번역 없이 켜져 있어요"
        }
    }
}

enum DownloadHost {
    case settings, onboarding, guide
}

private enum AppleIntelligenceState {
    case available, notReady, off

    static func read() -> AppleIntelligenceState {
        if let path = optionValue("--fake-ai") { // 시험용
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return text.hasPrefix("available") ? .available : text.hasPrefix("notReady") ? .notReady : .off
        }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.modelNotReady): return .notReady
        default: return .off
        }
    }
}

struct AvailableUpdate: Equatable {
    let version: String
    let page: URL
}

// MARK: - 앱 상태

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var installed: [LanguageChoice] = []
    @Published private(set) var downloadable: [LanguageChoice] = []
    @Published private(set) var packs: [LanguageChoice] = []
    @Published private(set) var installedPacks: Set<String> = []
    @Published private(set) var downloadingPack: String?
    @Published private(set) var downloadHost: DownloadHost?
    @Published private(set) var target = "ko"
    @Published private(set) var targetInstalled = false
    @Published private(set) var update: AvailableUpdate?
    @Published private(set) var loginItem = SMAppService.mainApp.status
    @Published private(set) var loginItemError: String?
    @Published var status = AppStatus.starting
    @Published var discordAction: DiscordAction? // 설정 창 상태 줄에 띄울 디스코드 버튼
    @Published var downloadRequest: TranslationSession.Configuration?

    let paths: Paths
    let isFirstRun: Bool
    private var settingsDate: Date?
    var onUpdateChange: (() -> Void)?
    var onDiscordAction: (() -> Void)?
    private var pendingDownload: String?
    private var pendingDownloadDeadline: Date?
    private var appleIntelligenceUsable = AppleIntelligenceState.read() != .off
    private var appleIntelligenceOffChecks = 0
    @Published private var modelChangeDeadline: Date?
    @Published private(set) var isOnboarding = false
    @Published private(set) var discordState = DiscordState.off
    @Published private(set) var guideStage: GuideStage?
    private var onboardingApprovedAt: Date?
    private var onboardingDone: CheckedContinuation<Void, Never>?
    private var onboardingWindow: NSWindow?
    private var onboardingStartedAt = Date()
    private var firstTranslationStartedAt = Date()
    private var guideWindow: NSWindow?
    private var packHintSource: Locale.Language?
    private var window: NSWindow?
    private let updateHTTP = URLSession(configuration: .ephemeral)

    init(paths: Paths) {
        self.paths = paths
        let data = try? Data(contentsOf: paths.settings)
        let loaded = data.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        settings = loaded
        isFirstRun = data == nil || loaded.onboardingPending == true
        settingsDate = Self.modificationDate(paths.settings)
    }

    var readyLanguage: String? { targetInstalled ? target : nil }
    var restartWithoutAsking: Bool { settings.restartWithoutAsking ?? false }

    // Apple Intelligence를 쓸 수 있는 맥(macOS 26.4 이상)만 두 모델 중에 고른다. 그 밖의 맥은 언어팩 모델뿐이다.
    var canChooseModel: Bool {
        guard #available(macOS 26.4, *), !CommandLine.arguments.contains("--no-apple-intelligence") else { return false }
        return appleIntelligenceUsable
    }
    // 잠깐 안 되는 것과 정말 꺼진 것을 가른다. 잠깐 끊겼다고 번역을 초기화하면 화면이 전부 다시 번역된다.
    // 모델을 준비하는 중이면 끈 것이 아니니 기다린다.
    private func updateAppleIntelligence() {
        guard AppleIntelligenceState.read() == .off else {
            appleIntelligenceOffChecks = 0
            appleIntelligenceUsable = true
            return
        }
        appleIntelligenceOffChecks += 1
        if appleIntelligenceOffChecks >= 3 { appleIntelligenceUsable = false }
    }

    // 언어팩이 꼭 있어야 번역할 수 있는 경우.
    private var requiresPacks: Bool {
        CommandLine.arguments.contains("--low-latency") || !canChooseModel || settings.usesLanguagePacks == true
    }
    // 고른 적이 없으면 고른 언어의 언어팩이 있을 때 언어팩을 쓴다. 약 16배 빠르고 번역이 뒤지지 않았다(11-05 측정).
    var usesLanguagePacks: Bool {
        requiresPacks || (settings.usesLanguagePacks == nil && installedPacks.contains(target))
    }
    var modelChoice: Bool? { settings.usesLanguagePacks } // nil은 자동
    var targetHasPack: Bool { installedPacks.contains(target) }
    var modelMode: ModelMode {
        if requiresPacks { return .packs }
        return settings.usesLanguagePacks == false ? .appleIntelligence : .automatic
    }
    // 로그인 때 켜 두었다면 디스코드를 꺼도 남아 있다가, 다음에 켜질 때 번역 모드로 바꾼다.
    // 시험(창 없는 실행)은 이 맥의 실제 로그인 항목 설정을 따르지 않는다.
    var staysAfterDiscord: Bool { (!isHeadless && SMAppService.mainApp.status == .enabled) || CommandLine.arguments.contains("--resident") }
    var targetName: String { LanguageChoice(id: target).name }
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    // 고른 언어가 아직 없을 때도 선택 칸이 비지 않도록 목록에 넣는다.
    var pickerLanguages: [LanguageChoice] {
        installed.contains { $0.id == target } ? installed : [LanguageChoice(id: target)] + installed
    }

    // MARK: 설정 파일

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @discardableResult
    func reloadSettingsIfChanged() -> Bool {
        let date = Self.modificationDate(paths.settings)
        guard date != settingsDate else { return false }
        settingsDate = date
        if let data = try? Data(contentsOf: paths.settings),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = loaded
            if let language = loaded.targetLanguage { target = language }
        }
        return true
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: paths.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: paths.settings, options: .atomic)
        settingsDate = Self.modificationDate(paths.settings)
    }

    func rememberFirstRunChoice() {
        settings.targetLanguage = target
        saveSettings()
    }

    func select(_ id: String) {
        settings.targetLanguage = id
        saveSettings()
        target = id
        targetInstalled = installed.contains { $0.id == id }
    }

    func setRestartWithoutAsking(_ value: Bool) {
        settings.restartWithoutAsking = value
        saveSettings()
    }

    var waitsForPackModel: Bool { modelChangeDeadline != nil }

    // 언어팩이 없는 채로 바꾸면 번역이 멈추므로, 다 받은 뒤에 바꾼다.
    // 받기 창을 닫아도 내려받기는 뒤에서 계속되니, 창이 닫힌 뒤에도 얼마간 기다린다.
    func setUsesLanguagePacks(_ value: Bool?) {
        if value == true, !installedPacks.contains(target) {
            modelChangeDeadline = Date().addingTimeInterval(30 * 60)
            requestDownload(target, select: false)
            return
        }
        modelChangeDeadline = nil
        settings.usesLanguagePacks = value
        saveSettings()
        Task { await refreshLanguages() }
    }

    // MARK: 번역 언어

    private func fakeStatuses(packs: Bool) -> [String: LanguageAvailability.Status]? {
        guard let path = optionValue(packs ? "--fake-packs" : "--fake-languages") else { return nil }
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        let table = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] } ?? [:]
        return table.mapValues { $0 == "installed" ? .installed : .supported }
    }

    private func allStatuses(packs: Bool) async -> [String: LanguageAvailability.Status] {
        if let fake = fakeStatuses(packs: packs) { return fake }
        let availability = translationAvailability(packs: packs)
        var result: [String: LanguageAvailability.Status] = [:]
        for language in await availability.supportedLanguages {
            let id = language.minimalIdentifier
            result[id] = await availability.status(from: referenceSource(for: id), to: language)
        }
        return result
    }

    // 영어는 지역별로 여러 개 나오는데 번역될 언어로는 하나면 된다.
    private func isCandidate(_ id: String) -> Bool {
        Locale.Language(identifier: id).languageCode?.identifier != "en" || id == "en"
    }

    private func defaultLanguage(among ids: Set<String>) -> String {
        for preferred in Locale.preferredLanguages {
            let language = Locale.Language(identifier: preferred)
            if ids.contains(language.minimalIdentifier) { return language.minimalIdentifier }
            if let code = language.languageCode?.identifier, ids.contains(code) { return code }
        }
        return "ko"
    }

    func refreshLanguages() async {
        let byName = { (ids: [String]) in
            ids.map(LanguageChoice.init(id:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let packStatuses = await allStatuses(packs: true).filter { isCandidate($0.key) }
        packs = byName(packStatuses.filter { $0.value == .installed || $0.value == .supported }.map(\.key))
        installedPacks = Set(packStatuses.filter { $0.value == .installed }.map(\.key))
        if let deadline = modelChangeDeadline {
            if installedPacks.contains(settings.targetLanguage ?? target) {
                modelChangeDeadline = nil
                settings.usesLanguagePacks = true
                saveSettings()
            } else if Date() > deadline {
                modelChangeDeadline = nil
            }
        }

        // 자동일 때는 언어팩이 없는 언어도 Apple Intelligence로 옮길 수 있으니 목록에서 빼지 않는다.
        let candidates = requiresPacks ? packStatuses : await allStatuses(packs: false).filter { isCandidate($0.key) }
        installed = byName(candidates.filter { $0.value == .installed }.map(\.key))
        downloadable = byName(candidates.filter { $0.value == .supported }.map(\.key))
        target = settings.targetLanguage ?? defaultLanguage(among: Set(candidates.keys))
        targetInstalled = (usesLanguagePacks ? packStatuses[target] : candidates[target]) == .installed
        if let pendingDownload, installed.contains(where: { $0.id == pendingDownload }) {
            self.pendingDownload = nil
            select(pendingDownload)
        } else if let deadline = pendingDownloadDeadline, Date() > deadline {
            // 받기 창을 그냥 닫았다면 한참 뒤에 다른 일로 받았을 때 번역 언어가 갑자기 바뀌면 안 된다.
            pendingDownload = nil
            pendingDownloadDeadline = nil
        }
    }

    private func status(of id: String, packs: Bool) async -> LanguageAvailability.Status? {
        if let fake = fakeStatuses(packs: packs) { return fake[id] }
        return await translationAvailability(packs: packs).status(from: referenceSource(for: id), to: Locale.Language(identifier: id))
    }

    // 전체 목록은 언어마다 조회해 비싸므로, 평소에는 고른 언어만 확인한다.
    // 자동 모델이 언어팩을 받거나 지운 것을 바로 알도록 언어팩 상태도 함께 본다.
    func refreshTarget() async {
        updateAppleIntelligence()
        let id = target
        let packStatus = await status(of: id, packs: true)
        if packStatus == .installed {
            installedPacks.insert(id)
        } else {
            installedPacks.remove(id)
        }
        let current = usesLanguagePacks ? packStatus : await status(of: id, packs: false)
        guard id == target else { return } // 조회하는 사이 언어를 바꿨으면 다음 차례에 다시 본다.
        targetInstalled = current == .installed
    }

    // 받기 창은 요청한 창 하나에만 뜨게 한다. 창마다 작업이 걸리면 먼저 끝난 쪽이 다른 쪽을 취소한다.
    func requestDownload(_ id: String, select: Bool = true, source: Locale.Language? = nil, host: DownloadHost? = nil) {
        pendingDownload = select ? id : nil
        pendingDownloadDeadline = select ? Date().addingTimeInterval(30 * 60) : nil
        downloadingPack = id
        downloadHost = host ?? (isOnboarding ? .onboarding : .settings)
        let language = Locale.Language(identifier: id)
        let from = source ?? referenceSource(for: id)
        if #available(macOS 26.4, *) {
            downloadRequest = .init(source: from, target: language, preferredStrategy: .lowLatency)
        } else {
            downloadRequest = .init(source: from, target: language)
        }
    }

    func downloadFinished() async {
        downloadRequest = nil
        downloadingPack = nil
        downloadHost = nil
        await refreshLanguages()
        if guideStage == .pack { closeGuide() }
    }

    func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 로그인 항목

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            logLine("로그인 항목 변경 실패: \(error.localizedDescription)")
            loginItemError = "변경하지 못했어요. 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 시도해 주세요."
        }
        loginItem = SMAppService.mainApp.status
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: 디스코드 재시작 승인

    func confirmRestart(title: String, detail: String) -> Bool {
        // 안내 마지막에 다시 시작을 눌렀으면 또 묻지 않는다. 언어팩을 기다리다 한참 뒤에 갑자기 끄면 안 되니 바로 다음에만 쓴다.
        if let approved = onboardingApprovedAt {
            onboardingApprovedAt = nil
            if Date().timeIntervalSince(approved) < 30 {
                logLine("안내에서 승인: \(title)")
                return true
            }
        }
        if restartWithoutAsking {
            logLine("묻지 않고 다시 시작: \(title)")
            return true
        }
        if let answer = optionValue("--prompt-answer") {
            logLine("확인 창(시험): \(title)")
            return answer == "yes"
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "다시 시작")
        alert.addButton(withTitle: "취소")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "앞으로 묻지 않고 다시 시작"
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on { setRestartWithoutAsking(true) }
        return confirmed
    }

    // MARK: 새 버전 알림

    // 내려받기까지 하지는 않고, 새 버전이 있다는 것만 상단 막대 아이콘에 표시한다.
    func runUpdateChecks() async {
        while true {
            await checkForUpdate()
            try? await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
        }
    }

    func checkForUpdate() async {
        // 시험은 주소를 직접 줄 때만 확인해서 GitHub에 요청을 보내지 않는다.
        let published = isHeadless ? nil : Bundle.main.object(forInfoDictionaryKey: "KRTReleasesURL") as? String
        let address = optionValue("--update-url") ?? published
        guard let feed = address.flatMap(URL.init(string:)) else { return }
        var request = URLRequest(url: feed)
        request.setValue("DiscordTranslator/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await updateHTTP.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String,
              let page = (release["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https" else {
            logLine("새 버전 확인 실패")
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard latest.compare(appVersion, options: .numeric) == .orderedDescending else {
            setUpdate(nil)
            return
        }
        logLine("새 버전 있음: \(latest)")
        setUpdate(AvailableUpdate(version: latest, page: page))
    }

    private func setUpdate(_ value: AvailableUpdate?) {
        update = value
        onUpdateChange?()
    }

    func openUpdatePage() {
        if let update { NSWorkspace.shared.open(update.page) }
    }

    // MARK: 설정 창

    var isWindowVisible: Bool { window?.isVisible == true }

    func showWindow(activates: Bool = true) {
        guard !isHeadless else { return }
        if isOnboarding {
            NSApplication.shared.activate(ignoringOtherApps: true)
            onboardingWindow?.makeKeyAndOrderFront(nil)
            return
        }
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: self)))
            created.title = "디스코드 번역"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        loginItem = SMAppService.mainApp.status
        Task { await refreshLanguages() }
        guard activates else {
            window?.orderFrontRegardless()
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: 처음 실행 안내

    // 고를 수 있는 언어 전부. 언어팩이 아직 없는 언어도 여기서 받을 수 있다.
    var onboardingLanguages: [LanguageChoice] {
        let ids = Set(installed.map(\.id) + packs.map(\.id) + [target])
        return ids.map(LanguageChoice.init(id:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func refreshDiscordState() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: discordBundleID)
        if running.isEmpty {
            discordState = .off
        } else {
            discordState = running.contains { debugPort(ofProcess: $0.processIdentifier) != nil } ? .ready : .needsRestart
        }
    }

    func runOnboarding() async {
        isOnboarding = true
        settings.onboardingPending = true
        onboardingStartedAt = Date()
        refreshDiscordState()
        logLine("온보딩: 시작")
        if let answer = optionValue("--onboarding-answer") {
            // 시험용: 창 대신 2초 뒤에 같은 동작을 한다.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if answer != "auto" { setUsesLanguagePacks(answer == "pack") }
                finishOnboarding()
            }
        } else {
            let created = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: self)))
            created.title = "디스코드 번역"
            created.styleMask = [.titled, .closable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.delegate = appDelegate
            created.center()
            onboardingWindow = created
            showWindow()
        }
        // 내려받기가 끝났는지, 디스코드를 껐다 켰는지 따라간다.
        Task {
            while isOnboarding {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard isOnboarding else { return }
                await refreshLanguages()
                refreshDiscordState()
            }
        }
        await withCheckedContinuation { onboardingDone = $0 }
    }

    // 맥의 번역 기능으로 샘플을 실제로 옮긴다. 아직 쓸 수 없으면 nil.
    func translateSample(_ text: String, from sourceID: String) async -> String? {
        guard modelMode != .packs || targetInstalled else { return nil }
        let source = Locale.Language(identifier: sourceID)
        let language = Locale.Language(identifier: target)
        for packs in modelMode == .automatic ? [true, false] : [modelMode == .packs] {
            guard await translationAvailability(packs: packs).status(from: source, to: language) == .installed else { continue }
            return try? await makeTranslationSession(source: source, target: language, packs: packs).translate(text).targetText
        }
        return nil
    }

    func finishOnboarding() {
        guard isOnboarding else { return }
        isOnboarding = false
        settings.onboardingPending = nil
        rememberFirstRunChoice()
        onboardingApprovedAt = Date()
        firstTranslationStartedAt = Date()
        logLine("온보딩: 번역 켜기 \(Int(Date().timeIntervalSince(onboardingStartedAt)))초")
        onboardingWindow?.close()
        onboardingWindow = nil
        showGuide(.waiting)
        onboardingDone?.resume()
        onboardingDone = nil
    }

    func windowClosed(_ closed: NSWindow?) {
        if closed === onboardingWindow, isOnboarding {
            logLine("온보딩: 끝내지 않고 닫음 \(Int(Date().timeIntervalSince(onboardingStartedAt)))초")
            NSApplication.shared.terminate(nil)
        } else if closed === guideWindow, let stage = guideStage {
            logLine("안내: 닫음(\(stage.rawValue))")
            guideStage = nil
            guideWindow = nil
        }
    }

    // MARK: 첫 번역까지의 안내

    private func showGuide(_ stage: GuideStage) {
        guideStage = stage
        loginItem = SMAppService.mainApp.status
        guard !isHeadless else { return }
        if guideWindow == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: GuideView(model: self)))
            created.title = "디스코드 번역"
            created.styleMask = [.titled, .closable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.isMovableByWindowBackground = true
            created.level = .floating // 디스코드가 켜져도 가려지지 않게 한다.
            created.delegate = appDelegate
            guideWindow = created
        }
        // 내용 크기가 정해진 뒤에 오른쪽 위로 옮긴다.
        DispatchQueue.main.async { [weak self] in
            guard let self, let guide = self.guideWindow, let screen = NSScreen.main?.visibleFrame else { return }
            guide.setFrameOrigin(NSPoint(x: screen.maxX - guide.frame.width - 24, y: screen.maxY - guide.frame.height - 24))
            guide.orderFrontRegardless()
        }
    }

    func closeGuide() {
        guideStage = nil
        guideWindow?.close()
        guideWindow = nil
    }

    // 실제 메시지에 번역이 처음 전달된 순간. 부탁은 이 뒤에 한다.
    func translationDelivered() {
        guard guideStage == .waiting else { return }
        logLine("온보딩: 첫 번역 \(Int(Date().timeIntervalSince(firstTranslationStartedAt)))초")
        showGuide(.success)
    }

    func acceptLoginItem() {
        logLine("안내: 로그인 시작 수락")
        setLoginItem(true)
        if loginItemError == nil { closeGuide() }
    }

    func declineLoginItem() {
        logLine("안내: 로그인 시작 나중에")
        closeGuide()
    }

    // 자동 모델이 긴 글을 오래 번역했을 때 한 번만 언어팩을 권한다.
    func slowTranslationSeen(source: Locale.Language) {
        guard modelMode == .automatic, canChooseModel, settings.packHintShown != true, guideStage == nil, !isOnboarding else { return }
        settings.packHintShown = true
        saveSettings()
        packHintSource = source
        logLine("안내: 언어팩 제안(\(source.minimalIdentifier))")
        showGuide(.pack)
    }

    func acceptPackHint() {
        logLine("안내: 언어팩 수락")
        requestDownload(target, select: false, source: packHintSource, host: .guide)
    }

    func declinePackHint() {
        logLine("안내: 언어팩 괜찮아요")
        closeGuide()
    }

    // 창을 띄우지 않고 화면을 그림으로 남긴다. 사용자 화면을 가리지 않고 확인하기 위한 옵션.
    func renderSettings(to path: String) async {
        await render(SettingsView(model: self), to: path)
    }

    func renderOnboarding(to path: String) async {
        refreshDiscordState()
        await render(OnboardingView(model: self), to: path, wait: 3)
    }

    func renderGuide(_ stage: GuideStage, to path: String) async {
        guideStage = stage
        // 로그인 시작을 이미 켠 맥에서도 묻는 화면을 그림으로 볼 수 있게 한다.
        loginItem = CommandLine.arguments.contains("--pretend-login-off") ? .notRegistered : SMAppService.mainApp.status
        await render(GuideView(model: self), to: path)
    }

    private func render(_ view: some View, to path: String, wait: Double = 0.5) async {
        // 화면 밖 창은 활성 창이 아니라 강조 버튼이 회색으로 그려진다. 실제로 뜬 창과 같게 활성 상태로 그린다.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.controlActiveState, .key))
        let holder = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: host.fittingSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        holder.backgroundColor = .windowBackgroundColor
        holder.contentView = host
        holder.orderFrontRegardless() // 화면 밖이라 보이지 않는다. 앞에 놓아야 샘플 번역 같은 작업이 돈다.
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 설정 화면

struct SettingsView: View {
    @ObservedObject var model: AppModel

    // 스크롤 없이 다 보이도록 나타나는 줄만큼 창을 늘린다.
    private var height: CGFloat {
        let wanted = 830 + (model.downloadable.isEmpty ? 0 : 48) + (model.canChooseModel ? 48 : 0) + (model.targetInstalled ? 0 : 136)
        return CGFloat(min(wanted, 860)) // 더 길면 창 안에서 스크롤한다.
    }

    @State private var showsPacks = CommandLine.arguments.contains("--show-packs")

    var body: some View {
        Form {
            Section {
                statusRow
                if !model.targetInstalled { missingLanguage }
            }

            Section {
                Picker("번역될 언어", selection: Binding(get: { model.target }, set: { model.select($0) })) {
                    ForEach(model.pickerLanguages) { Text($0.name).tag($0.id) }
                }
                if !model.downloadable.isEmpty {
                    Menu("다른 언어 받기") {
                        ForEach(model.downloadable) { language in
                            Button(language.name) { model.requestDownload(language.id) }
                        }
                    }
                    .disabled(model.downloadRequest != nil)
                }
                if model.canChooseModel {
                    Picker("번역 모델", selection: Binding(get: { model.modelChoice }, set: { model.setUsesLanguagePacks($0) })) {
                        Text("자동 (\(model.usesLanguagePacks ? "언어팩" : "Apple Intelligence"))").tag(Bool?.none)
                        Text("Apple Intelligence").tag(Bool?.some(false))
                        Text("언어팩").tag(Bool?.some(true))
                    }
                    .disabled(model.downloadRequest != nil)
                }
            } header: {
                Text("번역")
            } footer: {
                Text(model.waitsForPackModel
                    ? "「다운로드」를 눌렀다면 다 받은 뒤 언어팩 모델로 바뀌어요. 그때까지는 지금 모델로 번역해요."
                    : !model.canChooseModel
                        ? "다른 언어 메시지를 이 언어로 옮겨요. 언어팩을 받은 언어만 옮겨요."
                        : model.targetHasPack
                            ? "다른 언어 메시지를 이 언어로 옮겨요. 자동은 언어팩이 있는 언어는 언어팩으로, 나머지는 Apple Intelligence로 옮겨요."
                            : "다른 언어 메시지를 이 언어로 옮겨요. 언어팩을 받으면 그 언어는 훨씬 빨라져요.")
            }

            Section {
                LabeledContent("받은 언어팩 \(model.installedPacks.count)개") {
                    Button(showsPacks ? "접기" : "언어별로 보기") { showsPacks.toggle() }
                }
                if showsPacks {
                    ForEach(model.packs) { pack in
                        LabeledContent(pack.name) { packStatus(pack) }
                    }
                }
                LabeledContent("언어팩 지우기") {
                    Button("시스템 설정 열기") { model.openLanguageSettings() }
                }
            } header: {
                Text("언어팩")
            } footer: {
                Text("받은 언어팩은 맥의 다른 앱과 함께 써요. 애플이 앱에서 지우는 기능을 제공하지 않아, 언어 및 지역의 「번역 언어…」에서 제거해요. 제거하면 여기에도 반영돼요.")
            }

            Section {
                Toggle("로그인할 때 시작", isOn: Binding(get: { model.loginItem == .enabled }, set: { model.setLoginItem($0) }))
                if model.loginItem == .requiresApproval {
                    Button("시스템 설정에서 허용하기") { model.openLoginItemSettings() }
                }
                if let error = model.loginItemError {
                    Text(error).foregroundStyle(.secondary)
                }
                Toggle("묻지 않고 디스코드 다시 시작", isOn: Binding(get: { model.restartWithoutAsking }, set: { model.setRestartWithoutAsking($0) }))
            } header: {
                Text("실행")
            } footer: {
                Text("디스코드가 번역 없이 켜져 있으면 번역 모드로 껐다 켜야 해요. 음성 채널에 들어가 있다면 연결이 끊겨요.")
            }

            Section("알아둘 점") {
                Group {
                    Text(RiskNotice.debugPort)
                    Text(RiskNotice.terms)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("버전") {
                LabeledContent("현재 버전", value: model.appVersion)
                if let update = model.update {
                    LabeledContent("새 버전 \(update.version)") {
                        Button("내려받기") { model.openUpdatePage() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: height)
        .packDownloadTask(model, host: .settings)
    }

    // 상단 막대 메뉴 대신 여기서 지금 상태를 보고, 디스코드를 켜거나 앱을 끝낸다.
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status == .translating ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.status.text)
            Spacer()
            if let action = model.discordAction {
                Button(action.title) { model.onDiscordAction?() }
            }
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("디스코드 번역을 끝내요. 디스코드는 켜진 채로 남아요.")
        }
    }

    @ViewBuilder private func packStatus(_ pack: LanguageChoice) -> some View {
        if model.installedPacks.contains(pack.id) {
            Text("받음").foregroundStyle(.secondary)
        } else if model.downloadingPack == pack.id {
            ProgressView().controlSize(.small)
        } else {
            Button("받기") { model.requestDownload(pack.id, select: false) }
                .disabled(model.downloadRequest != nil)
        }
    }

    @ViewBuilder private var missingLanguage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.targetName) 번역에 필요한 언어가 이 맥에 없어요.")
            Text("받으면 앱을 다시 켜지 않아도 바로 번역을 시작해요.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("언어 받기") { model.requestDownload(model.target) }
                Button("시스템 설정 열기") { model.openLanguageSettings() }
            }
        }
    }
}

extension View {
    // 언어팩 받기 창을 띄운다. 창이 있는 화면에서만 뜰 수 있다.
    func packDownloadTask(_ model: AppModel, host: DownloadHost) -> some View {
        translationTask(model.downloadHost == host ? model.downloadRequest : nil) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                logLine("언어 받기를 마치지 못함: \(error)")
            }
            await model.downloadFinished()
        }
    }
}

enum DiscordAction {
    case launch, restart

    var title: String {
        switch self {
        case .launch: "번역 모드로 켜기"
        case .restart: "다시 시작"
        }
    }
}

// MARK: - 상단 막대와 메뉴

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    var supervisor: Supervisor?
    private var statusItem: NSStatusItem?
    private var lastStatusLog = ""

    init(model: AppModel) {
        self.model = model
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 온보딩을 끝내지 않고 닫으면 아직 아무것도 시작하지 않았으니 앱을 끝낸다.
    func windowWillClose(_ notification: Notification) {
        model.windowClosed(notification.object as? NSWindow)
    }

    // 메뉴 막대가 꽉 차면 아이콘이 가려질 수 있다. 앱을 다시 실행하면 설정을 열어 길을 남겨 둔다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let supervisor {
            Task { await supervisor.handleReopen() }
        } else {
            model.showWindow()
        }
        return false
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "디스코드 번역")
        image?.isTemplate = true // 막대 색에 맞춰 밝고 어둡게 바뀐다.
        item.button?.image = image
        item.button?.toolTip = "디스코드 번역"
        // 메뉴 없이 누르면 바로 설정 창을 연다. 상태와 종료는 설정 창 맨 위에 있다.
        item.button?.target = self
        item.button?.action = #selector(showSettings)
        statusItem = item
        model.onUpdateChange = { [weak self] in self?.refreshStatusItem() }
        refreshStatusItem()
    }

    // 새 버전이 있으면 아이콘 옆에 빨간 점을 찍는다.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        button.imagePosition = model.update == nil ? .imageOnly : .imageLeading // 글자 자리를 비워 두지 않는다.
        button.attributedTitle = model.update == nil
            ? NSAttributedString(string: "")
            : NSAttributedString(string: "●", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 7)])
    }

    // 시험용: 설정 창 상태 줄(상태 글자와 버튼)이 바뀔 때마다 로그에 남긴다.
    func logStatusRowIfChanged() {
        let entries = [model.status.text] + [model.discordAction?.title].compactMap { $0 } + ["종료"]
        let text = entries.joined(separator: " | ")
        guard text != lastStatusLog else { return }
        lastStatusLog = text
        logLine("상태 줄(시험): \(text)")
    }

    @objc func showSettings() {
        model.showWindow()
    }
}

@MainActor
func installMainMenu(delegate: AppDelegate) {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "디스코드 번역에 관하여", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "설정…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",").target = delegate
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "디스코드 번역 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(withTitle: "디스코드 번역 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "윈도우")
    windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)

    NSApplication.shared.mainMenu = main
}
