// 디스코드 번역: 디스코드 데스크톱 앱을 디버그 포트와 함께 실행하고,
// 화면의 영어 메시지 아래에 맥 내장 번역 결과를 표시한다.
// 앱 파일은 고치지 않고, 메시지 원문은 이 맥 밖으로 보내지 않으며 로그에도 남기지 않는다.

import AppKit
import CryptoKit
import Foundation
import NaturalLanguage
import Translation

let discordBundleID = optionValue("--discord-bundle") ?? "com.hnc.Discord"
// 자동 모델이 언어팩 없이 글 하나를 이만큼 오래 번역하면 언어팩을 권한다(초).
let packHintLimit = optionValue("--pack-hint-after-ms").flatMap(Double.init).map { $0 / 1000 } ?? 3
// 디스코드가 이만큼 꺼져 있어야 앱도 끝낸다(초). 업데이트로 잠깐 꺼질 때 먼저 끝나면 번역 없이 다시 켜진다.
let discordGoneLimit = optionValue("--discord-gone-seconds").flatMap(Int.init) ?? 60
// 번역 한 줄을 이만큼 기다려도 답이 없으면 실패로 본다(초). 가장 느린 모델로 긴 줄을 옮기는 시간보다 넉넉하게 둔다.
let translationTimeout = optionValue("--translation-timeout-seconds").flatMap(Double.init) ?? 60
let bindingName = "__krtTranslate"
// 기본 세션은 응답을 디스크에 캐시한다. 창 제목이 든 목록을 매초 받으므로 디스크에 남기지 않는다.
let localHTTP = URLSession(configuration: .ephemeral)

// 시험은 실제 로그에 섞이지 않게 임시 폴더에 남긴다.
let logFile = optionValue("--data-dir").map { URL(fileURLWithPath: $0).appendingPathComponent("app.log") }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiscordTranslator.log")

let logLimit = optionValue("--log-limit-bytes").flatMap(Int.init) ?? 1_000_000

// 메시지 내용은 남기지 않는다. 오래 켜 두어도 한없이 늘지 않게 이전 파일 하나만 남기고 넘긴다.
func logLine(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let manager = FileManager.default
    let owner: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
    let attributes = try? manager.attributesOfItem(atPath: logFile.path)
    if let size = attributes?[.size] as? Int, size + line.utf8.count > logLimit {
        let old = logFile.appendingPathExtension("1")
        try? manager.removeItem(at: old)
        try? manager.moveItem(at: logFile, to: old)
        try? manager.setAttributes(owner, ofItemAtPath: old.path)
    }
    if !manager.fileExists(atPath: logFile.path) {
        manager.createFile(atPath: logFile.path, contents: nil, attributes: owner)
    } else if (attributes?[.posixPermissions] as? NSNumber)?.intValue != 0o600 {
        try? manager.setAttributes(owner, ofItemAtPath: logFile.path)
    }
    if let handle = try? FileHandle(forWritingTo: logFile) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

// MARK: - 언어 판별

enum LanguageDetector {
    // 글의 언어를 알아낸다. 확신이 없으면 nil을 돌려주고 번역하지 않는다.
    // 짧은 라틴 문자 글은 판별이 크게 흔들린다. 「ok」는 폴란드어, 「gg」는 베트남어, 「Sora」는 루마니아어로 나온다(11-05 측정).
    static func detect(_ text: String) -> Locale.Language? {
        var letters = 0, hangul = 0, kana = 0, han = 0, latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: hangul += 1
            case 0x3040...0x30FF: kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
            case 0...0x24F: latin += 1
            default: break
            }
        }
        guard letters >= 2 else { return nil }
        let share = { (count: Int) in Double(count) / Double(letters) }

        // 글자만 봐도 아는 언어는 먼저 정한다. 「render 왜 안 돼요」가 헝가리어로 나오는 것을 막는다.
        if share(hangul) >= 0.3 { return Locale.Language(identifier: "ko") }
        if kana > 0, share(kana + han) >= 0.3 { return Locale.Language(identifier: "ja") }

        let recognizer = NLLanguageRecognizer()
        if share(han) >= 0.3 { recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .japanese] }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let confidence = hypotheses[dominant] ?? 0

        if share(latin) >= 0.7 {
            let english = hypotheses[.english] ?? 0
            let words = text.split(whereSeparator: \.isWhitespace).count
            // 짧은 글은 판별이 흔들려서 영어 기준을 낮춘다. 영어 사전에 없는 말은 번역해도 그대로라 표시되지 않는다.
            if words <= 2 ? english >= 0.1 : (dominant == .english || english >= 0.4) {
                return Locale.Language(identifier: "en")
            }
            // 다른 라틴 문자 언어는 틀리면 엉뚱한 번역이 붙으니 확실할 때만 옮긴다.
            return confidence >= (words <= 2 ? 0.9 : 0.7) ? Locale.Language(identifier: dominant.rawValue) : nil
        }
        return confidence >= 0.5 ? Locale.Language(identifier: dominant.rawValue) : nil
    }
}

func makeTranslationSession(source: Locale.Language, target: Locale.Language, packs: Bool) -> TranslationSession {
    if packs, #available(macOS 26.4, *) {
        return TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
    }
    return TranslationSession(installedSource: source, target: target)
}

func translationAvailability(packs: Bool) -> LanguageAvailability {
    if packs, #available(macOS 26.4, *) {
        return LanguageAvailability(preferredStrategy: .lowLatency)
    }
    return LanguageAvailability()
}

struct ForcedTranslationFailure: Error {}
struct TranslationTimedOut: Error {}

// 번역과 시간 제한 중 먼저 끝난 쪽의 결과만 돌려준다.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
        return waiting != nil
    }
}

enum ModelMode: Equatable {
    case automatic, appleIntelligence, packs
}

// MARK: - 파일 위치

struct Paths {
    let cacheDirectory: URL
    let glossary: URL
    let settings: URL

    static func resolve() -> Paths {
        // 시험에서는 실제 번역 기록과 용어집을 건드리지 않도록 임시 폴더를 쓴다.
        if let directory = optionValue("--data-dir") {
            let url = URL(fileURLWithPath: directory)
            return Paths(cacheDirectory: url, glossary: url.appendingPathComponent("glossary.txt"), settings: url.appendingPathComponent("settings.json"))
        }
        let manager = FileManager.default
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(
            cacheDirectory: caches.appendingPathComponent("kr.yeoreum.discord-translator"),
            glossary: support.appendingPathComponent("DiscordTranslator/glossary.txt"),
            settings: support.appendingPathComponent("DiscordTranslator/settings.json")
        )
    }
}

// MARK: - 번역 기록

// 번역한 줄을 디스크에 남겨 앱을 다시 켜도 다시 번역하지 않는다.
// 원문은 해시로만 저장하고, 파일은 사용자 본인만 읽을 수 있다.
struct LineStore {
    static let limit = optionValue("--line-store-limit").flatMap(Int.init) ?? 20_000

    private var table: [String: String] = [:]
    private var handle: FileHandle?
    private var rowCount = 0
    private let url: URL

    init(directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        url = directory.appendingPathComponent("lines-v2.jsonl")
        // 언어 구분이 없던 이전 기록은 어느 언어인지 알 수 없어 지운다. 다시 번역하면 되는 기록이다.
        try? manager.removeItem(at: directory.appendingPathComponent("lines-v1.jsonl"))
        load()
    }

    // 파일을 읽어 들인다. 제한을 넘었으면 오래된 줄을 지우고 다시 쓴다.
    private mutating func load() {
        let manager = FileManager.default
        try? handle?.close()
        table.removeAll()
        var rows = (try? Data(contentsOf: url))?.split(separator: 0x0A) ?? []
        if rows.count > Self.limit {
            rows = Array(rows.suffix(Self.limit))
            let temporary = url.deletingLastPathComponent().appendingPathComponent("lines-v2.tmp")
            var trimmed = Data()
            rows.forEach { trimmed.append($0); trimmed.append(0x0A) }
            if manager.createFile(atPath: temporary.path, contents: trimmed, attributes: [.posixPermissions: 0o600]) {
                _ = rename(temporary.path, url.path)
            }
        }
        for row in rows {
            // 앱이 쓰는 도중 꺼지면 마지막 줄이 잘릴 수 있어 읽히지 않는 줄은 건너뛴다.
            if let pair = (try? JSONSerialization.jsonObject(with: Data(row))) as? [String], pair.count == 2 {
                table[pair[0]] = pair[1]
            }
        }

        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        rowCount = rows.count
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    subscript(line: String, tag: String) -> String? { table[key(line, tag)] }

    mutating func save(_ line: String, tag: String, _ translated: String) {
        let hash = key(line, tag)
        table[hash] = translated
        guard let data = try? JSONSerialization.data(withJSONObject: [hash, translated]) else { return }
        try? handle?.write(contentsOf: data + [0x0A])
        rowCount += 1
        // 로그인 시작을 쓰면 앱을 며칠씩 켜 두니, 켜 둔 채로도 제한을 지킨다. 매번 다시 쓰지 않게 여유를 둔다.
        if rowCount > Self.limit + Self.limit / 4 { load() }
    }

    // 같은 원문도 번역될 언어와 모델마다 번역이 달라서 열쇠에 넣는다.
    private func key(_ line: String, _ tag: String) -> String {
        SHA256.hash(data: Data("\(tag)\n\(line)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 용어집

struct Glossary {
    private var before: [(pattern: NSRegularExpression, template: String)] = []
    private var after: [(from: String, to: String)] = []

    init(text: String) {
        var rules: [(String, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let left = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let right = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { rules.append((left, right)) }
        }
        // 긴 표현이 먼저 적용돼야 「we're so cooked」가 짧은 규칙에 먼저 먹히지 않는다.
        for (left, right) in rules.sorted(by: { $0.0.count > $1.0.count }) {
            // 왼쪽에 영어 알파벳 밖의 글자가 있으면 번역문을 고치는 규칙이다. 굽은 아포스트로피는 글자가 아니라 영어로 본다.
            if left.unicodeScalars.contains(where: { $0.properties.isAlphabetic && !$0.isASCII }) {
                after.append((left, right))
            } else {
                let escaped = NSRegularExpression.escapedPattern(for: left).replacingOccurrences(of: "'", with: "['’]")
                if let pattern = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: .caseInsensitive) {
                    before.append((pattern, NSRegularExpression.escapedTemplate(for: right)))
                }
            }
        }
    }

    func beforeTranslation(_ line: String) -> String {
        before.reduce(line) { text, rule in
            rule.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.template)
        }
    }

    func afterTranslation(_ text: String) -> String {
        after.reduce(text) { $0.replacingOccurrences(of: $1.from, with: $1.to) }
    }
}

// MARK: - 멘션 보호

// 내장 번역은 @everyone을 「@모두」로 옮긴다. 멘션을 @u0, #c0 같은 표시로 바꿔 번역한 뒤 되돌린다.
// 「{0}」 같은 표시보다 문장이 자연스럽게 번역되는 것을 시험으로 확인했다.
struct PreparedLine {
    private static let bare = try! NSRegularExpression(pattern: "(?<![\\w@#\\x{2}])@(?:everyone|here)\\b")
    private static let span = try! NSRegularExpression(pattern: "\\x{2}([^\\x{3}]*)\\x{3}")
    private static let token = try! NSRegularExpression(pattern: "(?:@u|#c)(\\d+)")

    let plain: String // 멘션을 글자 그대로 둔 원문
    let masked: String // 번역기에 넘길 글
    let unmasked: String // 표시가 망가졌을 때 대신 넘길 글
    let hasWords: Bool
    private let mentions: [String]

    init(_ line: String, glossary: Glossary) {
        let marked = Self.bare.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "\u{2}$0\u{3}")
        let source = marked as NSString
        var found: [String] = []
        var maskedText = ""
        var plainText = ""
        var outside = ""
        var cursor = 0
        for match in Self.span.matches(in: marked, range: NSRange(location: 0, length: source.length)) {
            let between = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let value = source.substring(with: match.range(at: 1))
            maskedText += between + (value.hasPrefix("#") ? "#c\(found.count)" : "@u\(found.count)")
            plainText += between + value
            outside += between
            found.append(value)
            cursor = match.range.location + match.range.length
        }
        let tail = source.substring(from: cursor)
        // 글자 수 제한으로 잘린 표시 문자는 화면에 나오지 않게 지운다.
        let strip = { (text: String) in text.replacingOccurrences(of: "\u{2}", with: "").replacingOccurrences(of: "\u{3}", with: "") }
        mentions = found
        plain = strip(plainText + tail)
        masked = glossary.beforeTranslation(strip(maskedText + tail))
        unmasked = glossary.beforeTranslation(plain)
        hasWords = strip(outside + tail).unicodeScalars.filter { $0.properties.isAlphabetic }.count >= 2
    }

    // 표시가 모두 정확히 한 번씩 남아 있을 때만 되돌린다.
    func restore(_ translated: String) -> String? {
        if mentions.isEmpty { return translated }
        let source = translated as NSString
        let matches = Self.token.matches(in: translated, range: NSRange(location: 0, length: source.length))
        let indexes = matches.compactMap { Int(source.substring(with: $0.range(at: 1))) }
        guard indexes.sorted() == Array(mentions.indices) else { return nil }
        var result = translated as NSString
        for (match, index) in zip(matches, indexes).reversed() {
            result = result.replacingCharacters(in: match.range, with: mentions[index]) as NSString
        }
        return result as String
    }

    // 언어 판별에는 멘션을 뺀다. 한국어 글에 영어 닉네임을 불렀다고 영어로 보면 안 된다.
    static func wordsOnly(_ text: String) -> String {
        span.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

// MARK: - 번역 대기열

actor TranslationQueue {
    private struct Job {
        let text: String
        let target: CDPTarget
    }

    // 원문 언어마다 어떤 모델로 옮길지. 태그는 번역 기록의 열쇠다.
    private struct Route {
        let session: TranslationSession
        let tag: String
        let source: Locale.Language
        let usesPack: Bool
    }

    private struct PlannedLine {
        let line: PreparedLine
        let route: Route? // 없으면 옮기지 않고 그대로 둔다.
    }

    private enum Outcome {
        case stopped // 새 글이 와서 멈췄다. 끝낸 줄은 기록에 남아 다시 번역하지 않는다.
        case finished(String?) // nil이면 표시할 번역이 없다.
        case failed(partial: String?) // 번역하지 못한 줄이 있다. 나중에 다시 시도한다.
    }

    private var jobs: [Job] = []
    private var cache: [String: String?] = [:]
    private var lines: LineStore
    private var glossary = Glossary(text: "")
    private var glossaryDate: Date?
    private let glossaryURL: URL
    private var draining = false
    private var targetID: String?
    private var mode = ModelMode.automatic
    private var sessions: [String: TranslationSession] = [:]
    private var routes: [String: (route: Route?, expires: Date)] = [:]
    private var slowSource: Locale.Language? // 지금 글을 언어팩 없이 옮기는 원문 언어
    // 시험용: 이 글자가 든 줄을 한 번 실패시키거나 멈춘다. 다른 글의 번역과 겹쳐도 결과가 흔들리지 않는다.
    private var forcedFailure = optionValue("--fail-once-containing")
    private var forcedHang = optionValue("--hang-once-containing")
    private let onSlow: @Sendable (Locale.Language) -> Void
    private var generation = 0 // 번역 언어가 바뀔 때마다 늘어, 바뀌기 전에 시작한 번역 결과를 가려낸다.

    init(paths: Paths, onSlow: @escaping @Sendable (Locale.Language) -> Void) {
        self.onSlow = onSlow
        lines = LineStore(directory: paths.cacheDirectory)
        glossaryURL = paths.glossary
        let manager = FileManager.default
        if !manager.fileExists(atPath: paths.glossary.path),
           let bundled = Bundle.main.url(forResource: "glossary", withExtension: "txt") {
            try? manager.createDirectory(at: paths.glossary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.copyItem(at: bundled, to: paths.glossary)
        }
        glossaryDate = (try? manager.attributesOfItem(atPath: paths.glossary.path))?[.modificationDate] as? Date
        glossary = Glossary(text: (try? String(contentsOf: paths.glossary, encoding: .utf8)) ?? "")
    }

    func setLanguage(_ id: String?, mode: ModelMode) {
        generation += 1
        jobs.removeAll()
        cache.removeAll()
        routes.removeAll()
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll()
        targetID = id
        self.mode = mode
    }

    // 원문 언어와 번역될 언어가 모두 준비된 모델을 고른다. 자동이면 빠른 언어팩부터 본다.
    // 언어팩을 받거나 지울 수 있으니 결과는 잠깐만 기억한다.
    private func route(from source: Locale.Language) async -> Route? {
        guard let targetID else { return nil }
        let target = Locale.Language(identifier: targetID)
        guard source.languageCode != target.languageCode else { return nil }
        let id = source.minimalIdentifier
        if let known = routes[id], Date() < known.expires { return known.route }

        let started = generation
        var found: Route?
        for packs in mode == .automatic ? [true, false] : [mode == .packs] {
            let status = await translationAvailability(packs: packs).status(from: source, to: target)
            guard started == generation else { return nil }
            guard status == .installed else { continue }
            let name = "\(id)|\(packs)"
            let session = sessions[name] ?? makeTranslationSession(source: source, target: target, packs: packs)
            sessions[name] = session
            found = Route(session: session, tag: packs ? "\(targetID)#pack" : targetID, source: source, usesPack: packs)
            break
        }
        routes[id] = (found, Date().addingTimeInterval(10))
        return found
    }

    // 용어집 파일이 바뀌었으면 다시 읽고 true를 돌려준다. 번역 기록은 그대로 쓸 수 있다.
    func reloadGlossaryIfChanged() -> Bool {
        let date = (try? FileManager.default.attributesOfItem(atPath: glossaryURL.path))?[.modificationDate] as? Date
        guard date != glossaryDate else { return false }
        glossaryDate = date
        glossary = Glossary(text: (try? String(contentsOf: glossaryURL, encoding: .utf8)) ?? "")
        cache.removeAll()
        logLine("용어집을 다시 읽었습니다")
        return true
    }

    func enqueue(_ texts: [String], target: CDPTarget) async {
        // 원문을 메모리에 쥐고 있으니 한없이 늘리지 않는다. 지워도 번역 기록에서 바로 다시 찾는다.
        if cache.count > 5000 { cache.removeAll() }
        let started = generation
        var ready: [(String, String?)] = []
        for text in texts {
            if let hit = cache[text] {
                ready.append((text, hit))
                continue
            }
            let routed = await plan(text).contains { $0.route != nil }
            // 판별하는 사이 언어가 바뀌었으면 이 결과를 새 언어의 기억에 넣지 않는다.
            guard started == generation else { return }
            if routed {
                jobs.append(Job(text: text, target: target))
            } else {
                cache[text] = .some(nil)
                ready.append((text, nil))
            }
        }
        if !ready.isEmpty { target.deliver(ready) }
        if !draining, !jobs.isEmpty {
            draining = true
            Task { await drain() }
        }
    }

    // 여러 언어가 섞인 글이 있어 줄마다 언어를 본다. 줄만 봐서 모르겠으면 글 전체의 언어를 따른다.
    private func plan(_ text: String) async -> [PlannedLine] {
        let whole = LanguageDetector.detect(PreparedLine.wordsOnly(text))
        var planned: [PlannedLine] = []
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let line = PreparedLine(trimmed, glossary: glossary)
            var chosen: Route?
            if line.hasWords, let source = LanguageDetector.detect(PreparedLine.wordsOnly(trimmed)) ?? whole {
                chosen = await route(from: source)
            }
            planned.append(PlannedLine(line: line, route: chosen))
        }
        return planned
    }

    // 내장 번역은 동시에 돌려도 빨라지지 않는다(150자 줄: Apple Intelligence 약 1초, 언어팩 약 0.06초).
    // 무엇을 먼저 번역할지는 화면을 아는 표시 스크립트가 한 개씩 골라 보낸다.
    private func drain() async {
        while let job = jobs.popLast() {
            // 표시 스크립트는 마지막에 보낸 글만 기다린다. 그 앞의 글은 채널을 옮기며 버린 것이다.
            jobs.removeAll { $0.target === job.target }
            if let hit = cache[job.text] {
                job.target.deliver([(job.text, hit)])
                continue
            }
            let started = generation
            let began = Date()
            let outcome = await translate(job)
            guard started == generation else { continue }
            switch outcome {
            case .stopped:
                continue
            case .finished(let translated):
                if mode == .automatic, let slowSource, Date().timeIntervalSince(began) >= packHintLimit { onSlow(slowSource) }
                cache[job.text] = .some(translated)
                job.target.deliver([(job.text, translated)])
            case .failed(let partial):
                job.target.fail(job.text, partial: partial)
            }
        }
        draining = false
    }

    // 통째로 넘기면 번호 목록이 한 줄로 합쳐지므로 줄 단위로 번역해 원래 줄 구조를 지킨다.
    private func translate(_ job: Job) async -> Outcome {
        let planned = await plan(job.text)
        slowSource = planned.compactMap(\.route).first { !$0.usesPack }?.source
        let first = planned.compactMap { item in item.route.map { (item.line.masked, $0) } }
        guard await fill(first, job: job, planned: planned) else { return .stopped }
        // 번역기가 멘션 표시를 망가뜨린 줄은 표시 없이 다시 번역한다.
        let broken = planned.compactMap { item -> (String, Route)? in
            guard let route = item.route, let done = lines[item.line.masked, route.tag], item.line.restore(done) == nil else { return nil }
            return (item.line.unmasked, route)
        }
        guard await fill(broken, job: job, planned: planned) else { return .stopped }

        let output = planned.map { finished($0) ?? $0.line.plain }
        let source = planned.map(\.line.plain).joined(separator: "\n")
        let text = clean(glossary.afterTranslation(output.joined(separator: "\n")), source: source)
        let unfinished = planned.contains { $0.route != nil && finished($0) == nil }
        return unfinished ? .failed(partial: text) : .finished(text)
    }

    private func finished(_ item: PlannedLine) -> String? {
        guard let route = item.route else { return nil }
        if let done = lines[item.line.masked, route.tag], let restored = item.line.restore(done) { return restored }
        return lines[item.line.unmasked, route.tag]
    }

    // 일괄로 넘기면 도중에 멈출 수 없어서 다음 요청이 남은 줄을 다 기다린다(그만두거나 취소해도 약 5초, 11-05 측정).
    // 한 줄씩 보내면 더 느리지 않으면서 줄 사이에서 멈출 수 있고, 끝난 줄을 바로 보여 줄 수 있다.
    private func fill(_ inputs: [(String, Route)], job: Job, planned: [PlannedLine]) async -> Bool {
        let started = generation
        var seen = Set<String>()
        var failed = false
        for (line, route) in inputs where seen.insert(line).inserted {
            if lines[line, route.tag] != nil { continue }
            if jobs.contains(where: { $0.target === job.target }) { return false }
            do {
                if let marker = forcedFailure, line.contains(marker) {
                    forcedFailure = nil
                    throw ForcedTranslationFailure()
                }
                let translated = try await translateWithLimit(line, session: route.session)
                // 번역하는 사이 언어가 바뀌었으면 이 결과를 새 언어의 기록에 넣지 않는다.
                guard started == generation else { return false }
                lines.save(line, tag: route.tag, translated)
                report(job, planned)
            } catch {
                guard started == generation else { return false }
                if !failed {
                    logLine("번역 실패: \(error)")
                    failed = true
                }
                // 세션이 망가졌을 수 있으니 다음 글부터 새로 만들고, 언어팩 상태도 다시 확인한다.
                sessions.removeAll()
                routes.removeAll()
            }
        }
        return true
    }

    // 번역 호출이 돌아오지 않으면 대기열 전체가 멈추므로 시간을 제한한다.
    private func translateWithLimit(_ line: String, session: TranslationSession) async throws -> String {
        let hangs = forcedHang.map(line.contains) ?? false
        if hangs { forcedHang = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let first = FirstResult(continuation)
            let timer = Task {
                try await Task.sleep(nanoseconds: UInt64(translationTimeout * 1_000_000_000))
                if first.finish(.failure(TranslationTimedOut())) { session.cancel() }
            }
            Task {
                defer { timer.cancel() }
                do {
                    if hangs { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
                    first.finish(.success(try await session.translate(line).targetText))
                } catch {
                    first.finish(.failure(error))
                }
            }
        }
    }

    // 아직 남은 줄이 있으면 끝난 줄까지를 먼저 화면에 보낸다.
    private func report(_ job: Job, _ planned: [PlannedLine]) {
        var shown: [String] = []
        var translatedAny = false
        for item in planned {
            guard item.route != nil else {
                shown.append(item.line.plain)
                continue
            }
            guard let done = finished(item) else {
                if translatedAny {
                    let partial = glossary.afterTranslation(shown.joined(separator: "\n"))
                    job.target.progress(job.text, partial.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return
            }
            shown.append(done)
            translatedAny = true
        }
    }

    private func clean(_ translated: String, source: String) -> String? {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == source.lowercased() { return nil }
        return trimmed
    }
}

// MARK: - 디버그 프로토콜 연결

final class CDPTarget: @unchecked Sendable {
    let id: String
    var onClose: (@Sendable () -> Void)?
    var onTranslated: (@Sendable () -> Void)?

    private let task: URLSessionWebSocketTask
    private let script: String
    private let queue: TranslationQueue
    private let lock = NSLock()
    private var sequence = 0

    init(id: String, socketURL: URL, script: String, queue: TranslationQueue) {
        self.id = id
        self.script = script
        self.queue = queue
        task = localHTTP.webSocketTask(with: socketURL)
        task.maximumMessageSize = 64 * 1024 * 1024
    }

    func start() {
        task.resume()
        send("Runtime.enable")
        send("Page.enable")
        send("Runtime.addBinding", ["name": bindingName])
        send("Page.addScriptToEvaluateOnNewDocument", ["source": script])
        send("Runtime.evaluate", ["expression": script])
        send("Runtime.evaluate", ["expression": "window.__krt&&window.__krt.attached&&window.__krt.attached()"])
        receive()
    }

    func deliver(_ results: [(String, String?)]) {
        if results.contains(where: { $0.1 != nil }) { onTranslated?() }
        let rows: [[Any]] = results.map { [$0.0, $0.1 ?? NSNull()] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return }
        send("Runtime.evaluate", ["expression": "window.__krt&&window.__krt.done(\(json))"])
    }

    func ping() {
        send("Runtime.evaluate", ["expression": "window.__krt&&window.__krt.alive&&window.__krt.alive()"])
    }

    func fail(_ text: String, partial: String?) {
        let row: [Any] = [text, partial ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              let json = String(data: data, encoding: .utf8) else { return }
        send("Runtime.evaluate", ["expression": "window.__krt&&window.__krt.failed&&window.__krt.failed(...\(json))"])
    }

    func progress(_ text: String, _ partial: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [text, partial]),
              let json = String(data: data, encoding: .utf8) else { return }
        send("Runtime.evaluate", ["expression": "window.__krt&&window.__krt.progress&&window.__krt.progress(...\(json))"])
    }

    func refresh() {
        send("Runtime.evaluate", ["expression": "window.__krt&&window.__krt.reset()"])
    }

    private func send(_ method: String, _ params: [String: Any] = [:]) {
        lock.lock()
        sequence += 1
        let id = sequence
        lock.unlock()
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { logLine("전송 실패: \(error.localizedDescription)") }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handle(Data(text.utf8))
                case .data(let data): self.handle(data)
                @unknown default: break
                }
                self.receive()
            case .failure:
                self.onClose?()
            }
        }
    }

    private func handle(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["method"] as? String == "Runtime.bindingCalled",
              let params = event["params"] as? [String: Any],
              params["name"] as? String == bindingName,
              let payload = (params["payload"] as? String)?.data(using: .utf8),
              let texts = try? JSONSerialization.jsonObject(with: payload) as? [String] else { return }
        Task { await queue.enqueue(texts, target: self) }
    }
}

// MARK: - 대상 창 감시

@MainActor
final class Supervisor {
    private var port: Int
    private let script: String
    private let matches: (URL) -> Bool
    private let followsDiscord: Bool
    private let model: AppModel
    private let queue: TranslationQueue
    private var attached: [String: CDPTarget] = [:]
    private var language: String?
    private var usesPacks = false
    private var modelMode = ModelMode.automatic
    private var knownPacks: Set<String> = []
    private var unreachable = 0
    private var discordGone = 0
    private var approvedAt = Date()
    private var recoveries = 0
    private var declined: Set<pid_t> = [] // 재시작을 거절한 디스코드. 새로 켜질 때까지 다시 묻지 않는다.

    init(port: Int, script: String, followsDiscord: Bool, model: AppModel, restartDeclined: Bool = false, matches: @escaping (URL) -> Bool) {
        self.port = port
        self.script = script
        self.followsDiscord = followsDiscord
        self.model = model
        self.matches = matches
        queue = TranslationQueue(paths: model.paths) { [weak model] source in
            Task { @MainActor in model?.slowTranslationSeen(source: source) }
        }
        if restartDeclined {
            declined = Set(discordApps().map(\.processIdentifier))
            approvedAt = .distantPast
        }
    }

    private func discordApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: discordBundleID)
    }

    func run() async {
        var tick = 0
        while true {
            if model.reloadSettingsIfChanged() || tick % 2 == 0 { await model.refreshTarget() }
            if tick % 5 == 0, model.isWindowVisible || model.waitsForPackModel { await model.refreshLanguages() }
            tick += 1
            await applyLanguage()

            if let targets = await fetchTargets() {
                unreachable = 0
                recoveries = 0
                attachNew(targets)
                attached.values.forEach { $0.ping() }
                model.status = .translating
            } else {
                unreachable += 1
                if followsDiscord, unreachable >= 3 { await recoverIfFlagLost() }
            }
            if await queue.reloadGlossaryIfChanged() {
                attached.values.forEach { $0.refresh() }
            }
            if followsDiscord { watchDiscord() }
            if model.readyLanguage == nil { model.status = .waitingForLanguage }
            if unreachable >= 60 {
                logLine("디버그 포트에 60초 동안 연결하지 못해 끝냅니다")
                showMessage("디스코드에 연결하지 못했어요", "번역 앱을 끝낼게요. 디스코드를 다시 켠 뒤 번역 앱을 실행해 주세요.")
                exit(1)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // 언어를 바꾸거나 언어팩을 받으면 앱을 다시 켜지 않아도 화면의 번역을 새로 받는다.
    private func applyLanguage() async {
        let ready = model.readyLanguage
        let packs = model.usesLanguagePacks
        let mode = model.modelMode
        let installed = model.installedPacks
        let changed = ready != language || packs != usesPacks
        // 언어팩을 받으면 그동안 건너뛰던 언어도 옮길 수 있으니 화면을 다시 본다.
        guard changed || mode != modelMode || installed != knownPacks else { return }
        language = ready
        usesPacks = packs
        modelMode = mode
        knownPacks = installed
        await queue.setLanguage(ready, mode: mode)
        attached.values.forEach { $0.refresh() }
        guard changed else { return }
        logLine("번역 언어: \(ready ?? "없음")\(packs ? " (언어팩)" : "")")
        if ready == nil { model.showWindow(activates: false) } // 디스코드에 입력하던 글자를 뺏지 않는다.
    }

    private func watchDiscord() {
        let apps = discordApps()
        declined.formIntersection(apps.map(\.processIdentifier))
        discordGone = apps.isEmpty ? discordGone + 1 : 0
        guard discordGone >= 5 else { return }
        if !model.staysAfterDiscord, discordGone >= discordGoneLimit {
            logLine("디스코드가 종료되어 함께 끝냅니다")
            exit(0)
        }
        if discordGone == 5 { logLine("디스코드가 꺼져 있어 기다립니다") }
        unreachable = 0
        model.status = .discordOff
    }

    // 디스코드는 업데이트를 적용하며 스스로 다시 켜지는데, 이때 실행 옵션이 사라진다.
    // 평소처럼 Dock에서 켠 경우도 옵션이 없어 같은 길로 온다.
    private func recoverIfFlagLost() async {
        let apps = discordApps()
        guard !apps.isEmpty else { return }
        if let current = apps.compactMap({ debugPort(ofProcess: $0.processIdentifier) }).first {
            port = current
            return
        }
        if apps.contains(where: { declined.contains($0.processIdentifier) }) {
            unreachable = 0
            model.status = .discordWithoutTranslation
            return
        }
        // 옵션을 받아 주지 않는 경우 디스코드를 끝없이 재시작하지 않도록 횟수를 제한한다.
        guard recoveries < 2 else {
            logLine("번역 모드로 켜지 못해 끝냅니다")
            showMessage("번역 모드로 켜지 못했어요", "디스코드는 평소처럼 쓸 수 있어요. 번역 앱을 다시 실행해 주세요.")
            exit(1)
        }
        // 방금 승인받은 재시작의 연장이면 다시 묻지 않는다.
        if Date().timeIntervalSince(approvedAt) > 120 {
            let confirmed = model.confirmRestart(
                title: "디스코드가 번역 없이 켜졌어요",
                detail: "번역 모드로 다시 켤까요? 음성 채널에 들어가 있다면 연결이 끊겨요."
            )
            guard confirmed else {
                guard model.staysAfterDiscord else {
                    logLine("사용자가 재시작을 취소해 끝냅니다")
                    exit(0)
                }
                declined.formUnion(apps.map(\.processIdentifier))
                approvedAt = .distantPast
                unreachable = 0
                model.status = .discordWithoutTranslation
                return
            }
            recoveries = 0
        }
        recoveries += 1
        guard quitDiscord(apps), let next = freePort(), await launchDiscord(port: next) else {
            logLine("번역 모드 복구 실패")
            showMessage("번역 모드로 다시 켜지 못했어요", "디스코드가 꺼져 있다면 직접 켜 주세요. 번역 앱을 다시 실행하면 번역 모드로 켤 수 있어요.")
            exit(1)
        }
        logLine("옵션 없이 켜진 디스코드를 번역 모드로 다시 시작")
        port = next
        approvedAt = Date()
        unreachable = 0
    }

    // Dock 아이콘: 디스코드가 꺼져 있으면 번역 모드로 켜고, 번역 없이 켜져 있으면 다시 물으며, 그 밖에는 설정을 연다.
    func handleDockClick() async {
        let apps = discordApps()
        guard followsDiscord, model.readyLanguage != nil else {
            model.showWindow()
            return
        }
        if apps.isEmpty {
            guard let next = freePort(), await launchDiscord(port: next) else {
                showMessage("디스코드를 켜지 못했어요", "응용 프로그램 폴더에 Discord가 있는지 확인해 주세요.")
                return
            }
            port = next
            approvedAt = Date()
            unreachable = 0
            discordGone = 0
        } else if apps.contains(where: { declined.contains($0.processIdentifier) }) {
            declined.removeAll()
            approvedAt = .distantPast
            unreachable = 3
        } else {
            model.showWindow()
        }
    }

    private func fetchTargets() async -> [[String: Any]]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
              let (data, _) = try? await localHTTP.data(from: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    private func attachNew(_ targets: [[String: Any]]) {
        for info in targets {
            guard info["type"] as? String == "page",
                  let id = info["id"] as? String, attached[id] == nil,
                  let page = (info["url"] as? String).flatMap(URL.init(string:)), matches(page),
                  let socket = (info["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { continue }
            let target = CDPTarget(id: id, socketURL: socket, script: script, queue: queue)
            target.onClose = { [weak self] in
                Task { @MainActor in self?.attached[id] = nil }
            }
            let model = model
            target.onTranslated = { [weak model] in
                Task { @MainActor in model?.translationDelivered() }
            }
            attached[id] = target
            target.start()
            logLine("번역 표시 연결: \(page.host ?? page.lastPathComponent)")
        }
    }
}

// MARK: - 실행 준비

func showMessage(_ title: String, _ detail: String) {
    if isHeadless {
        logLine("알림(시험): \(title)")
        return
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "확인")
    alert.runModal()
}

func debugPort(ofProcess pid: pid_t) -> Int? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "args=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let args = String(decoding: data, as: UTF8.self)
    guard let range = args.range(of: #"--remote-debugging-port=(\d+)"#, options: .regularExpression) else { return nil }
    return Int(args[range].split(separator: "=")[1])
}

func freePort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
            bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
        }
    }
    return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
}

// LaunchServices로 띄워야 마이크·카메라 권한이 지금처럼 디스코드 앱에 그대로 묶인다.
func launchDiscord(port: Int) async -> Bool {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: discordBundleID) else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ["--remote-debugging-port=\(port)"]
    do {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    } catch {
        logLine("디스코드 실행 실패: \(error.localizedDescription)")
        return false
    }
}

// 막 켜진 앱은 꺼져도 isTerminated가 바뀌지 않는 경우가 있어(로그인 직후 디스코드가 함께 켜질 때) 프로세스를 직접 확인한다.
func quitDiscord(_ apps: [NSRunningApplication]) -> Bool {
    apps.forEach { $0.terminate() }
    let pids = apps.map(\.processIdentifier)
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if pids.allSatisfy({ kill($0, 0) != 0 && errno == ESRCH }) { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return false
}

@MainActor
func prepareDiscordPort(model: AppModel) async -> Int? {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: discordBundleID)
    if let existing = running.compactMap({ debugPort(ofProcess: $0.processIdentifier) }).first {
        return existing
    }
    if !running.isEmpty {
        let confirmed = model.confirmRestart(
            title: "디스코드를 번역 모드로 다시 시작할까요?",
            detail: "지금 켜진 디스코드를 껐다가 다시 켭니다. 음성 채널에 들어가 있다면 연결이 끊겨요."
        )
        guard confirmed else { return nil }
        guard quitDiscord(running) else {
            showMessage("디스코드를 끄지 못했어요", "디스코드를 직접 종료한 뒤 다시 실행해 주세요.")
            return nil
        }
    }
    guard let port = freePort(), await launchDiscord(port: port) else {
        showMessage("디스코드를 켜지 못했어요", "응용 프로그램 폴더에 Discord가 있는지 확인해 주세요.")
        return nil
    }
    return port
}

func optionValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

// MARK: - 시작

if CommandLine.arguments.contains("--self-test") {
    while let line = readLine() {
        print(LanguageDetector.detect(line)?.minimalIdentifier ?? "건너뜀", "|", line)
    }
    exit(0)
}

@MainActor
func start() async {
    let model = AppModel(paths: Paths.resolve())
    let delegate = AppDelegate(model: model)
    appDelegate = delegate
    NSApplication.shared.delegate = delegate
    if !isHeadless { installMainMenu(delegate: delegate) }
    await model.refreshLanguages()
    precondition(Thread.isMainThread, "확인 창은 메인 스레드에서만 띄울 수 있다")
    if CommandLine.arguments.contains("--choose-pack-model") { model.setUsesLanguagePacks(true) } // 시험용: 설정 창에서 고른 것과 같다.

    if let output = optionValue("--render-onboarding") {
        await model.renderOnboarding(to: output)
        exit(0)
    }
    if let output = optionValue("--render-guide"), let stage = optionValue("--guide-stage").flatMap(GuideStage.init(rawValue:)) {
        await model.renderGuide(stage, to: output)
        exit(0)
    }
    if let output = optionValue("--render-settings") {
        await model.checkForUpdate()
        await model.renderSettings(to: output)
        exit(0)
    }
    Task { await model.runUpdateChecks() }

    if model.isFirstRun {
        if isHeadless, optionValue("--onboarding-answer") == nil {
            model.rememberFirstRunChoice()
        } else {
            await model.runOnboarding()
        }
    }
    // 언어가 준비되면 앱을 다시 켜지 않아도 그대로 이어서 시작한다.
    if !model.targetInstalled {
        logLine("번역 언어가 없어 기다립니다: \(model.target)")
        model.status = .waitingForLanguage
        model.showWindow(activates: false) // 로그인 직후에 뜰 수 있으니 포커스를 뺏지 않는다.
        while !model.targetInstalled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            model.reloadSettingsIfChanged()
            await model.refreshLanguages()
        }
    }

    let scriptPath = optionValue("--script") ?? Bundle.main.url(forResource: "inject", withExtension: "js")?.path
    guard let scriptPath, let injectScript = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
        logLine("표시 스크립트를 찾지 못했습니다")
        showMessage("앱 파일이 손상됐어요", "디스코드 번역을 다시 내려받아 주세요.")
        exit(1)
    }

    let needle = optionValue("--match")
    let supervisor: Supervisor
    if let attachPort = optionValue("--attach").flatMap(Int.init) {
        // 시험용: 이미 떠 있는 브라우저에 붙는다. 주소에 --match 값이 들어간 페이지만 대상이다.
        supervisor = Supervisor(port: attachPort, script: injectScript, followsDiscord: false, model: model) {
            $0.absoluteString.contains(needle ?? "")
        }
    } else {
        let prepared = await prepareDiscordPort(model: model)
        // 거절했을 때 로그인 시작을 켜 두었다면 남아 있다가, 디스코드가 새로 켜지거나 Dock 아이콘을 누를 때 다시 묻는다.
        guard prepared != nil || model.staysAfterDiscord else { exit(0) }
        logLine("디스코드 번역 시작")
        supervisor = Supervisor(port: prepared ?? 0, script: injectScript, followsDiscord: true, model: model, restartDeclined: prepared == nil) { url in
            if let needle { return url.absoluteString.contains(needle) }
            guard let host = url.host, host == "discord.com" || host.hasSuffix(".discord.com") else { return false }
            return !url.path.hasPrefix("/popout")
        }
    }
    delegate.supervisor = supervisor
    await supervisor.run()
}

// dispatchMain()은 메인 큐를 메인 스레드 밖에서 돌릴 수 있어 확인 창을 띄울 때 앱이 죽는다.
// NSApplication 이벤트 루프를 써야 메인 액터가 진짜 메인 스레드에서 돈다.
NSApplication.shared.setActivationPolicy(isHeadless ? .accessory : .regular)
Task { @MainActor in await start() }
NSApplication.shared.run()
