
import Foundation
import AVFoundation
import AppKit

// === Config ===
let BACKEND_BASE = URL(string: "http://127.0.0.1:8787")!

// Optional: You can set default local file paths here to test without opening a project first.
let DEFAULT_MOVIE_PATH: String? = nil
let DEFAULT_CLIP_PATH: String?  = nil

// === Models (align with your FastAPI JSON) ===
struct Scene: Codable, Identifiable {
    let clip_scene_id: Int
    var id: Int { clip_scene_id }
}

struct ClipInfo: Codable {
    let start: Double
    let end: Double
    let scene_id: Int?
    let scene_seg_idx: Int?
}

struct Candidate: Codable, Identifiable {
    let seg_id: Int?
    let scene_seg_idx: Int?
    let start: Double
    let end: Double
    let scene_id: Int
    let score: Double?
    let faiss_id: Int?
    let movie_id: String?
    let shot_id: Int?
    let source: String?
    var id: Int {
        if let sid = seg_id { return sid }
        // Fallback id if seg_id is missing (use scene info + ms timestamp)
        let ms = Int((start * 1000).rounded())
        let a = (scene_id & 0xFFFF) << 8
        let b = (scene_seg_idx ?? 0) & 0xFF
        return (a | b) ^ ms
    }
}
struct ScenesResponse: Codable {
    let ok: Bool?
    let scenes: [Scene]
}

struct SegmentRow: Codable, Identifiable {
    let seg_id: Int
    let clip: ClipInfo
    let top_matches: [Candidate]?
    var matched_orig_seg: Candidate?
    let matched_source: String?
    var is_override: Bool?
    /// 校对评价（ok / needTrim / unsure / mismatch）
    var review_status: String?
    /// 当“生效匹配关系”变化导致现有评价失效时，置为 true（由后端 /segments 返回）
    var review_stale: Bool?
    var id: Int { seg_id }
}

// === Security-Scoped Bookmark Helpers ===
enum BookmarkKey: String {
    case movie = "bookmark.movie"
    case clip  = "bookmark.clip"
}

enum PrefKey: String {
    case projectRoot = "pref.projectRoot"
    case moviePath   = "pref.moviePath"   // for display only; auth uses bookmark
    case clipPath    = "pref.clipPath"    // for display only; auth uses bookmark
}

struct BookmarkStore {
    static func save(url: URL, key: BookmarkKey) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key.rawValue)
        } catch {
            print("[bookmark] save error:", error)
        }
    }
    static func resolve(key: BookmarkKey) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                // refresh the bookmark if needed
                save(url: url, key: key)
            }
            return url
        } catch {
            print("[bookmark] resolve error:", error)
            return nil
        }
    }
    static func clear(key: BookmarkKey) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }
}

final class SecurityScope {
    private var active: [String: URL] = [:]
    func start(key: BookmarkKey, url: URL) {
        if url.startAccessingSecurityScopedResource() {
            active[key.rawValue] = url
            print("[scope] started for", key.rawValue, url.path)
        } else {
            print("[scope] failed to start for", key.rawValue, url.path)
        }
    }
    func stop(key: BookmarkKey) {
        if let u = active.removeValue(forKey: key.rawValue) {
            u.stopAccessingSecurityScopedResource()
            print("[scope] stopped for", key.rawValue)
        }
    }
    func stopAll() {
        for (k, u) in active {
            u.stopAccessingSecurityScopedResource()
            print("[scope] stopped for", k)
        }
        active.removeAll()
    }
}

struct OverridesResponse: Codable {
    let path: String?
    let count: Int?
    let data: [String: Candidate]?
}


struct CandidatesResponse: Codable {
    let ok: Bool
    let seg_id: Int
    let mode: String?
    let total: Int?
    let items: [Candidate]
}

// === Additional endpoints for scene/corridor candidate sets ===
extension APIClient {
    struct SceneNeighborhoodResp: Decodable {
        let ok: Bool
        let seg_id: Int
        let anchor_scene_id: Int?
        let scene_ids: [Int]
        let items: [Candidate]
    }
    func sceneNeighborhood(segId: Int, span: Int = 2) async throws -> SceneNeighborhoodResp {
        try await get("/candidates/scene_neighborhood", query: ["seg_id": "\(segId)", "span": "\(span)"])
    }

    struct CorridorResp: Decodable {
        struct Anchors: Decodable { let prev: Int?; let next: Int? }
        let ok: Bool
        let seg_id: Int
        let anchors: Anchors?
        let span: Int
        let prev: [Candidate]
        let next: [Candidate]
    }
    func corridor(segId: Int, span: Int = 2) async throws -> CorridorResp {
        try await get("/candidates/corridor", query: ["seg_id": "\(segId)", "span": "\(span)"])
    }
}

// === API Client ===
actor APIClient {
    // API: review state
    struct UpdateReviewBody: Encodable { let seg_id: Int; let status: String }
    func updateReviewStatus(segId: Int, status: String) async throws {
        struct R: Decodable { let ok: Bool? }
        let body = UpdateReviewBody(seg_id: segId, status: status)
        let _: R = try await post("/review/update", body: body)
    }

    // Fetch review states from backend: { ok?, segs: { "id": { status, fp? } } } or { ok?, data: { segs: ... } }
    func reviewState() async throws -> [Int:String] {
        struct Entry: Decodable { let status: String? }
        struct DataWrap: Decodable { let segs: [String: Entry]? }
        struct Resp: Decodable { let ok: Bool?; let segs: [String: Entry]?; let data: DataWrap? }
        let resp: Resp = try await get("/review/state")
        let segs = resp.segs ?? resp.data?.segs ?? [:]
        return segs.reduce(into: [:]) { res, kv in
            if let id = Int(kv.key), let s = kv.value.status { res[id] = s }
        }
    }
    
    func getRaw(_ path: String, query: [String:String] = [:]) async throws -> Data {
        var comps = URLComponents(url: BACKEND_BASE.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        print("[api] GET(raw)", comps.url!.absoluteString, "status", (resp as? HTTPURLResponse)?.statusCode ?? -1, "bytes", data.count)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
    func get<T: Decodable>(_ path: String, query: [String:String] = [:]) async throws -> T {
        var comps = URLComponents(url: BACKEND_BASE.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        print("[api] GET", comps.url!.absoluteString, "status", (resp as? HTTPURLResponse)?.statusCode ?? -1, "bytes", data.count)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: Encodable) async throws -> T {
        var req = URLRequest(url: BACKEND_BASE.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(AnyEncodable(body))
        let (data, resp) = try await URLSession.shared.data(for: req)
        print("[api] POST", req.url!.absoluteString, "status", (resp as? HTTPURLResponse)?.statusCode ?? -1, "bytes", data.count)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // API: open project
    struct OpenProjectBody: Encodable { let root: String; let movie: String?; let clip: String? }
    func openProject(root: String, movie: String?, clip: String?) async throws {
        struct R: Decodable { let ok: Bool }
        let _: R = try await post("/project/open", body: OpenProjectBody(root: root, movie: movie, clip: clip))
    }

    // API: scenes
    func listScenes() async throws -> [Scene] {
        let resp: ScenesResponse = try await get("/scenes")
        return resp.scenes
    }

    // API: scene segments
    func listSegments(sceneId: Int) async throws -> [SegmentRow] {
        try await get("/segments", query: ["clip_scene_id": String(sceneId)])
    }

    // API: candidates
    func candidates(segId: Int, mode: String, k: Int = 120, offset: Int = 0) async throws -> CandidatesResponse {
        try await get("/candidates", query: ["seg_id": "\(segId)","mode": mode,"k":"\(k)","offset":"\(offset)"])
    }

    // API: apply
    struct ApplyBody: Encodable {
        struct Change: Encodable { let seg_id: Int; let chosen: Candidate }
        let changes: [Change]
    }
    func apply(segId: Int, chosen: Candidate) async throws {
        struct R: Decodable { let ok: Bool }
        let body = ApplyBody(changes: [.init(seg_id: segId, chosen: chosen)])
        let _: R = try await post("/apply", body: body)
    }

    // API: overrides
    func overrides() async throws -> OverridesResponse {
        try await get("/overrides")
    }
}

// === Store ===
@MainActor
final class AppStore: ObservableObject {
    let api = APIClient()

    // Persisted user inputs
    @Published var projectRoot: String = UserDefaults.standard.string(forKey: PrefKey.projectRoot.rawValue) ?? "" {
        didSet { UserDefaults.standard.set(projectRoot, forKey: PrefKey.projectRoot.rawValue) }
    }
    @Published var moviePath: String = UserDefaults.standard.string(forKey: PrefKey.moviePath.rawValue) ?? (DEFAULT_MOVIE_PATH ?? "") {
        didSet { UserDefaults.standard.set(moviePath, forKey: PrefKey.moviePath.rawValue) }
    }
    @Published var clipPath: String  = UserDefaults.standard.string(forKey: PrefKey.clipPath.rawValue) ?? (DEFAULT_CLIP_PATH ?? "") {
        didSet { UserDefaults.standard.set(clipPath, forKey: PrefKey.clipPath.rawValue) }
    }

    // Security-scope handler for bookmarks
    private let scope = SecurityScope()

    init() {
        // Restore movie bookmark if available
        if let mu = BookmarkStore.resolve(key: .movie) {
            scope.start(key: .movie, url: mu)
            self.moviePath = mu.path
        }
        // Restore clip bookmark if available
        if let cu = BookmarkStore.resolve(key: .clip) {
            scope.start(key: .clip, url: cu)
            self.clipPath = cu.path
        }
    }

    @Published var scenes: [Scene] = []
    @Published var allSegments: [SegmentRow] = []
    @Published var selectedSeg: SegmentRow? = nil

    @Published var candMode: String = "top" { // top/scene/corridor/all
        didSet { Task { await self.onCandModeChanged() } }
    }
    @Published var candidates: [Candidate] = []
    @Published var sceneOrigSegments: [Candidate] = []   // 场景内（锚点±2）
    @Published var corridorPrev: [Candidate] = []        // 走廊-前序
    @Published var corridorNext: [Candidate] = []        // 走廊-后续
    @Published var overridesMap: [Int: Candidate] = [:]

    // Playback flags
    @Published var followMovie: Bool = true
    @Published var loopPair: Bool = true
    @Published var mirrorClip: Bool = false

    // Players
    let pair = PairPlayer()

    func loadEverythingAfterOpen() async {
        do {
            self.scenes = try await api.listScenes()
            // Flatten segments from all scenes (limit first N if necessary)
            var flat: [SegmentRow] = []
            for sc in scenes {
                let segs = try await api.listSegments(sceneId: sc.clip_scene_id)
                flat.append(contentsOf: segs)
            }
            self.allSegments = flat
            if let first = flat.first {
                await select(seg: first)
            }
            try await refreshOverrides()
            await refreshReviewStates()
        } catch {
            print("[store] loadEverything error:", error)
        }
    }

    func openProject() async {
        do {
            try await api.openProject(root: projectRoot, movie: moviePath.isEmpty ? nil : moviePath, clip: clipPath.isEmpty ? nil : clipPath)
            await loadEverythingAfterOpen()
        } catch {
            print("[store] openProject error:", error)
        }
    }

    func refreshOverrides() async throws {
        let r = try await api.overrides()
        var m: [Int: Candidate] = [:]
        r.data?.forEach { (k, v) in
            if let id = Int(k) { m[id] = v }
        }
        self.overridesMap = m
        // apply local marks
        self.allSegments = self.allSegments.map { row in
            if let ov = m[row.seg_id] {
                var r = row
                r.matched_orig_seg = ov
                r.is_override = true
                return r
            }
            return row
        }
    }
    
    func select(seg: SegmentRow) async {
        self.selectedSeg = seg
        // movie choice
        let mo = overridesMap[seg.seg_id] ?? seg.matched_orig_seg ?? seg.top_matches?.first
        // prepare ranges
        let clipStart = seg.clip.start
        let clipEnd   = seg.clip.end
        let movieStart = mo?.start ?? 0
        let movieEnd   = mo?.end ?? (movieStart + (clipEnd-clipStart))
        pair.playPair(clipStart: clipStart, clipEnd: clipEnd, movieStart: movieStart, movieEnd: movieEnd, togetherLoop: loopPair, mirrorClip: mirrorClip, clipURL: clipURL(), movieURL: movieURL())
        // load candidates
        await onCandModeChanged()
    }

    func clipURL() -> URL? {
        if !clipPath.isEmpty { return URL(fileURLWithPath: clipPath) }
        return nil
    }
    func movieURL() -> URL? {
        if !moviePath.isEmpty { return URL(fileURLWithPath: moviePath) }
        return nil
    }


    func loadCandidates(for seg: SegmentRow) async {
        do {
            let r = try await api.candidates(segId: seg.seg_id, mode: candMode, k: 120, offset: 0)
            self.candidates = r.items
        } catch {
            print("[store] candidates error:", error)
            self.candidates = []
        }
    }

    func onCandModeChanged() async {
        guard let seg = selectedSeg else { return }
        do {
            switch candMode {
            case "scene":
                let r = try await api.sceneNeighborhood(segId: seg.seg_id, span: 2)
                self.sceneOrigSegments = r.items
                self.candidates = []
                self.corridorPrev = []
                self.corridorNext = []
            case "corridor":
                let r = try await api.corridor(segId: seg.seg_id, span: 2)
                self.corridorPrev = r.prev
                self.corridorNext = r.next
                self.sceneOrigSegments = []
                self.candidates = []
            default:
                let r = try await api.candidates(segId: seg.seg_id, mode: candMode, k: 120, offset: 0)
                self.candidates = r.items
                self.sceneOrigSegments = []
                self.corridorPrev = []
                self.corridorNext = []
            }
        } catch {
            print("[store] onCandModeChanged error:", error)
            self.candidates = []
            self.sceneOrigSegments = []
            self.corridorPrev = []
            self.corridorNext = []
        }
    }

    func applyCurrentCandidate(_ cand: Candidate) async {
        guard let seg = selectedSeg else { return }
        do {
            try await api.apply(segId: seg.seg_id, chosen: cand)
            // optimistic update
            if let idx = allSegments.firstIndex(where: { $0.seg_id == seg.seg_id }) {
                var row = allSegments[idx]
                row.matched_orig_seg = cand
                row.is_override = true
                allSegments[idx] = row
                selectedSeg = row
            }
            try await refreshOverrides()
            // preview again with applied range
            _ = await select(seg: selectedSeg!)
        } catch {
            print("[store] apply error:", error)
        }
    }
    
    /// 让用户选择“原片”并保存授权（安全书签）
    func authorizeMovieFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["mp4", "mov", "m4v", "mkv"]
        panel.message = "请选择电影原片文件以授权沙箱访问（将保存安全书签）"
        if panel.runModal() == .OK, let url = panel.url {
            scope.stop(key: .movie)
            BookmarkStore.save(url: url, key: .movie)
            scope.start(key: .movie, url: url)
            self.moviePath = url.path
        }
    }

    /// 让用户选择“短片/clip”并保存授权（安全书签）
    func authorizeClipFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["mp4", "mov", "m4v", "mkv"]
        panel.message = "请选择短片文件以授权沙箱访问（将保存安全书签）"
        if panel.runModal() == .OK, let url = panel.url {
            scope.stop(key: .clip)
            BookmarkStore.save(url: url, key: .clip)
            scope.start(key: .clip, url: url)
            self.clipPath = url.path
        }
    }

    func refreshReviewStates() async {
        do {
            let map = try await api.reviewState()
            // merge into allSegments
            self.allSegments = self.allSegments.map { row in
                var r = row
                if let st = map[row.seg_id] { r.review_status = st }
                return r
            }
            // also update selectedSeg if visible
            if let cur = selectedSeg, let st = map[cur.seg_id] {
                var c = cur; c.review_status = st; selectedSeg = c
            }
        } catch {
            print("[store] refreshReviewStates error:", error)
        }
    }

    /// 更新当前选中分段的校对状态（会同步到后端）
    func updateReviewStatus(_ status: String) async {
        guard let seg = selectedSeg else { return }
        do {
            try await api.updateReviewStatus(segId: seg.seg_id, status: status)
            if let idx = allSegments.firstIndex(where: { $0.seg_id == seg.seg_id }) {
                var row = allSegments[idx]
                row.review_status = status
                row.review_stale = false
                allSegments[idx] = row
                selectedSeg = row
            }
        } catch {
            print("[store] updateReviewStatus error:", error)
        }
    }
}

// === AnyEncodable helper ===
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ wrapped: T) { _encode = wrapped.encode }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

// === PairPlayer: two AVPlayers synced & looping together ===
final class PairPlayer {
    let clip = AVPlayer()
    let movie = AVPlayer()

    private var clipBoundary: Any?
    private var movieBoundary: Any?

    private var clipRange: (Double, Double) = (0, 0)
    private var movieRange: (Double, Double) = (0, 0)
    private var togetherLoop: Bool = true
    private var mirrorClip: Bool = false

    private var clipFinished = false
    private var movieFinished = false

    init() {
        clip.allowsExternalPlayback = false
        movie.allowsExternalPlayback = false
    }

    func playPair(clipStart: Double, clipEnd: Double,
                  movieStart: Double, movieEnd: Double,
                  togetherLoop: Bool,
                  mirrorClip: Bool,
                  clipURL: URL?, movieURL: URL?) {

        self.togetherLoop = togetherLoop
        self.mirrorClip = mirrorClip
        self.clipRange = (clipStart, clipEnd)
        self.movieRange = (movieStart, movieEnd)
        self.clipFinished = false
        self.movieFinished = false

        if let cu = clipURL {
            let item = AVPlayerItem(url: cu)
            clip.replaceCurrentItem(with: item)
        }
        if let mu = movieURL {
            let item = AVPlayerItem(url: mu)
            movie.replaceCurrentItem(with: item)
        }

        // Seek with zero tolerance
        let cs = CMTime(seconds: clipStart, preferredTimescale: 600)
        let ms = CMTime(seconds: movieStart, preferredTimescale: 600)
        clip.seek(to: cs, toleranceBefore: .zero, toleranceAfter: .zero)
        movie.seek(to: ms, toleranceBefore: .zero, toleranceAfter: .zero)

        // Remove old boundary observers
        if let b = clipBoundary { clip.removeTimeObserver(b); clipBoundary = nil }
        if let b = movieBoundary { movie.removeTimeObserver(b); movieBoundary = nil }

        // Boundary observers at absolute end seconds (relative to asset)
        let cEnd = CMTime(seconds: clipEnd, preferredTimescale: 600)
        let mEnd = CMTime(seconds: movieEnd, preferredTimescale: 600)
        clipBoundary = clip.addBoundaryTimeObserver(forTimes: [NSValue(time: cEnd)], queue: .main) { [weak self] in
            guard let self = self else { return }
            self.clip.pause()
            self.clipFinished = true
            self.maybeRestartTogether()
        }
        movieBoundary = movie.addBoundaryTimeObserver(forTimes: [NSValue(time: mEnd)], queue: .main) { [weak self] in
            guard let self = self else { return }
            self.movie.pause()
            self.movieFinished = true
            self.maybeRestartTogether()
        }

        clip.play()
        movie.play()
    }

    private func maybeRestartTogether() {
        guard togetherLoop else {
            // Independent loop
            if clipFinished {
                clip.seek(to: CMTime(seconds: clipRange.0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                clip.play()
                clipFinished = false
            }
            if movieFinished {
                movie.seek(to: CMTime(seconds: movieRange.0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                movie.play()
                movieFinished = false
            }
            return
        }
        if clipFinished && movieFinished {
            clip.seek(to: CMTime(seconds: clipRange.0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            movie.seek(to: CMTime(seconds: movieRange.0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            clipFinished = false
            movieFinished = false
            clip.play()
            movie.play()
        }
    }
}
