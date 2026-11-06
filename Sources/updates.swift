// 새 버전: Sparkle(https://sparkle-project.org)이 하루에 한 번 확인하고, 받은 파일은 공개 키로 서명을 확인한 뒤에만 설치한다.
// 자동 설치가 켜져 있으면 조용히 받아 두었다가 번역 중일 때 바로 설치하고 앱을 다시 켠다. 디스코드는 그대로 둔다.
// 자동 설치를 끄면 상단 막대 아이콘에 빨간 점만 찍고, 설정 창의 「설치」를 누를 때 Sparkle 창을 띄운다.
import AppKit
import Sparkle

@MainActor
final class Updates: NSObject {
    private unowned let model: AppModel
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    // 시험용: 업데이트 목록 주소를 바꾸고, 켜자마자 한 번 확인한다. 받는 파일은 이때도 앱의 공개 키로 확인한다.
    private let testFeedURL = optionValue("--feed-url")

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        // 시험은 주소를 직접 줄 때만 확인해서 GitHub에 요청을 보내지 않는다.
        guard !isHeadless || testFeedURL != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        do {
            try controller.updater.start()
        } catch {
            logLine("새 버전 확인을 시작하지 못했습니다: \(error.localizedDescription)")
            return
        }
        // 창 없는 시험은 정기 확인처럼, 창을 띄우는 시험은 설정 창에서 누른 것처럼 확인한다.
        if testFeedURL != nil {
            if isHeadless { controller.updater.checkForUpdatesInBackground() } else { checkNow() }
        }
    }

    // 설정 창에서 누를 때. 찾아 둔 새 버전이 있으면 그 창을 앞으로 가져온다.
    func checkNow() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var automaticallyInstalls: Bool {
        get {
            controller?.updater.automaticallyDownloadsUpdates
                ?? (Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool ?? false)
        }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    // 번역 중일 때만 바로 설치한다. 다시 켜진 앱은 열려 있는 디버그 포트에 그대로 붙는다.
    // 디스코드가 꺼져 있거나 번역 없이 켜져 있으면 다시 켜진 앱이 디스코드를 켜거나 다시 시작할지 물으니, 그때는 앱을 끌 때 설치된다.
    func installIfIdle() {
        guard let install = pendingInstall, model.status == .translating, !model.isOnboarding, model.guideStage == nil else { return }
        pendingInstall = nil
        logLine("새 버전 설치")
        install()
    }
}

extension Updates: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        testFeedURL
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        logLine("새 버전 있음: \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        if code == Int(SUError.noUpdateError.rawValue) || code == Int(SUError.installationCanceledError.rawValue) { return }
        logLine("새 버전 확인 실패: \(error.localizedDescription)")
    }

    // 받은 새 버전은 앱을 끌 때 Sparkle이 설치한다. 그 전에 번역 중이면 바로 설치한다.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        logLine("새 버전 받음: \(item.displayVersionString)")
        pendingInstall = immediateInstallHandler
        DispatchQueue.main.async { self.installIfIdle() }
        return true
    }
}

extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    // 상단 막대 앱이라 창을 갑자기 띄우지 않고 빨간 점만 찍는다.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate()
        } else {
            logLine("새 버전 알림: \(update.displayVersionString)")
            model.setUpdate(AvailableUpdate(version: update.displayVersionString))
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        model.setUpdate(nil)
    }
}
