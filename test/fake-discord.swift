// 실행 흐름 시험에 쓰는 가짜 디스코드. 디버그 포트 옵션을 받으면 헤드리스 크롬을 그 포트로 띄운다.
// 옵션이 없으면 포트를 열지 않아서, 평소처럼 Dock에서 켠 디스코드와 같은 상태가 된다.
import AppKit

let mockURL = (try? String(contentsOf: Bundle.main.url(forResource: "mock-url", withExtension: "txt")!, encoding: .utf8)) ?? ""
let profile = FileManager.default.temporaryDirectory.appendingPathComponent("krt-fake-\(ProcessInfo.processInfo.processIdentifier)")
var browser: Process?

func stopBrowser() {
    browser?.terminate()
    browser?.waitUntilExit()
    try? FileManager.default.removeItem(at: profile)
}

if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--remote-debugging-port=") }) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    process.arguments = ["--headless=new", flag, "--user-data-dir=\(profile.path)", "--no-first-run", mockURL]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    browser = process
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { stopBrowser() }
}

let delegate = Delegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { NSApplication.shared.terminate(nil) }
term.resume()
NSApplication.shared.run()
