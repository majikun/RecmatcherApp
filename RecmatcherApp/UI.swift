import SwiftUI
import AVKit
import AppKit

// AVPlayerView wrapper (AppKit) for SwiftUI
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var mirrorX: Bool = false // kept for API compatibility; mirroring is applied at SwiftUI level

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        // Do NOT disable translatesAutoresizingMaskIntoConstraints. SwiftUI will size it.
        v.controlsStyle = .none
        v.showsFrameSteppingButtons = false
        v.showsTimecodes = false
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player {
            v.player = player
        }
        // No CALayer transforms here (negative scale on the view layer can blank video on macOS).
    }
}

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedCandIdx: Int = 0
    @State private var maxLoops: Int = 3 // kept for parity; AVFoundation loops continuously
    @State private var audioSource: String = "clip" // "clip" or "movie"
    @State private var selectedCand: Candidate? = nil

    // Pick a local file and pass its URL back
    private func pickLocalFile(_ title: String = "选择文件…", _ onPick: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedFileTypes = ["mp4", "mov", "m4v"]
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }

    // Pick a local directory and pass its URL back (for project root)
    private func pickLocalDirectory(_ title: String = "选择目录…", _ onPick: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                // Left: segments
                VStack(alignment: .leading) {
                    Text("段落列表").font(.headline).padding(.bottom, 6)
                    // Annotate segments with continuity info for left list
                    let annotated = annotateSegments(store.allSegments)
                    List {
                        ForEach(annotated, id: \.row.seg_id) { item in
                            let s = item.row
                            SegmentRowView(
                                row: s,
                                isSelected: store.selectedSeg?.seg_id == s.seg_id,
                                hasOverride: s.is_override == true,
                                fromPrev: item.fromPrev,
                                toNext: item.toNext,
                                islandColor: item.spike ? .pink : islandColorFor(item.islandId),
                                isSpike: item.spike
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await store.select(seg: s) } }
                        }
                    }
                    .listStyle(.plain)
                    .listRowSeparator(.hidden)
                    .scrollContentBackground(.hidden)
                }
                .frame(minWidth: 280, maxWidth: 350)

                // Right pane: controls + side-by-side players + timeline + 4-column candidates
                VStack(alignment: .leading, spacing: 8) {
                    // Controls row
                    HStack {
                        Button(action: togglePlayPause) {
                            Text(isPlaying ? "⏸️ 暂停" : "▶️ 播放")
                        }
                        Toggle("同步循环", isOn: $store.loopPair).onChange(of: store.loopPair) { _, _ in
                            if let seg = store.selectedSeg { Task { await store.select(seg: seg) } }
                        }
                        Toggle("镜像 Clip", isOn: $store.mirrorClip)
                        Picker("音频", selection: $audioSource) {
                            Text("Clip").tag("clip")
                            Text("Movie").tag("movie")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        .onChange(of: audioSource) { _, _ in applyAudioSelection() }
                        Spacer()
                        Stepper(value: $maxLoops, in: 1...8) {
                            Text("循环次数: \(maxLoops)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 160)
                    }

                    // Side-by-side players
                    HStack(alignment: .top, spacing: 8) {
                        VStack(spacing: 6) {
                            Text("Clip").font(.caption).foregroundColor(.secondary)
                            ZStack {
                                PlayerView(player: store.pair.clip)
                                    .scaleEffect(x: store.mirrorClip ? -1 : 1, y: 1)
                                if store.pair.clip.currentItem == nil {
                                    Text("未加载 / 无视频").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .frame(minHeight: 240)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.9))
                            .clipped()
                        }
                        VStack(spacing: 6) {
                            Text("Movie").font(.caption).foregroundColor(.secondary)
                            ZStack {
                                PlayerView(player: store.pair.movie)
                                if store.pair.movie.currentItem == nil {
                                    Text("未加载 / 无视频").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .frame(minHeight: 240)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.9))
                            .clipped()
                        }
                    }

                    // Timeline placeholder (layout only for now)
                    ZStack {
                        Rectangle().fill(Color.blue.opacity(0.6)).frame(height: 14).cornerRadius(4)
                        HStack {
                            Text("Cur seg").padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.yellow).cornerRadius(3)
                            Spacer()
                            Text("movie timeline").font(.caption).foregroundColor(.white.opacity(0.9))
                        }.padding(.horizontal, 6)
                    }

                    // Header: status & apply
                    HStack {
                        Text("候选（当前段）").font(.headline)
                        Spacer()
                        if let st = store.selectedSeg?.review_status, !st.isEmpty {
                            Text("状态：\(st)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("状态：-").font(.caption).foregroundStyle(.secondary)
                        }
                        Menu("校对状态") {
                            Button("OK") { Task { await store.updateReviewStatus("ok") } }
                            Button("Need Trim") { Task { await store.updateReviewStatus("needTrim") } }
                            Button("Unsure") { Task { await store.updateReviewStatus("unsure") } }
                            Button("Mismatch") { Task { await store.updateReviewStatus("mismatch") } }
                        }
                        Button("应用所选") { applySelected() }.keyboardShortcut(.return, modifiers: [])
                    }

                    // 4 horizontal strips: top / scene / corridor / all
                    HStack(alignment: .top, spacing: 8) {
                        candColumn(title: "Top", items: bucket("top"))
                        candColumn(title: "场景内", items: bucket("scene"))
                        candColumn(title: "走廊", items: bucket("corridor"))
                        candColumn(title: "全部", items: bucket("all"))
                    }
                }
                .frame(minWidth: 720, maxWidth: .infinity)
            }
        }
        .onAppear {
            // If you want to start without openProject, set DEFAULT_* constants in Core.swift
            if let first = store.allSegments.first {
                Task { await store.select(seg: first) }
            }
            // Ensure the initial audio routing matches the Picker
            applyAudioSelection()
        }
        .onChange(of: store.selectedSeg?.seg_id ?? -1) { _, _ in
            selectedCand = nil
        }
        .onChange(of: store.selectedSeg?.matched_orig_seg?.seg_id ?? -1) { _, _ in
            // 应用覆盖后，清理蓝色选中；橙色绑定会根据新的 matched 重新计算
            selectedCand = nil
        }
        .padding(8)
    }

    private var isPlaying: Bool {
        (store.pair.clip.rate != 0) || (store.pair.movie.rate != 0)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("project root", text: $store.projectRoot)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                Button("选择项目…") {
                    pickLocalDirectory("选择项目根目录…") { url in
                        store.projectRoot = url.path
                        Task {
                            await store.openProject()            // 仅传 project.root，由后端返回 clip/movie
                            await store.loadEverythingAfterOpen() // 回填文本框并加载视频
                        }
                    }
                }
            }
            TextField("movie.mp4 (local path, optional)", text: $store.moviePath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            TextField("clip.mp4 (local path, optional)", text: $store.clipPath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Button("授权Movie…") {
                store.authorizeMovieFile()
                Task { await store.openProject() }
            }
            Button("授权Clip…") {
                store.authorizeClipFile()
                Task { await store.openProject() }
            }
            Button("打开") {
                Task {
                    await store.openProject()            // 仅使用 project.root；由后端返回 clip/movie
                    await store.loadEverythingAfterOpen() // 回填并加载
                }
            }
            Button("刷新场景") { Task { await store.loadEverythingAfterOpen() } }
            Button("导出") { Task { await store.exportMerged() } }
            // Keyboard shortcuts: ← / → to switch segments
            Button("") { selectPrevSegment() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0.001)
            Button("") { selectNextSegment() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0.001)
            
            Spacer()
            if !store.moviePath.isEmpty {
                Text(URL(fileURLWithPath: store.moviePath).lastPathComponent)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !store.clipPath.isEmpty {
                Text(URL(fileURLWithPath: store.clipPath).lastPathComponent)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func togglePlayPause() {
        if isPlaying {
            store.pair.clip.pause()
            store.pair.movie.pause()
        } else {
            store.pair.clip.play()
            store.pair.movie.play()
        }
    }

    // MARK: - Continuity / Island helpers
    private func isContiguous(_ a: SegmentRow?, _ b: SegmentRow?) -> Bool {
        guard let am = a?.matched_orig_seg, let bm = b?.matched_orig_seg else { return false }

        // 1) 优先：orig 的 seg_id 连号
        if let asid = am.seg_id, let bsid = bm.seg_id, bsid == asid + 1 { return true }

        // 2) 兼容：同 scene 且 idx 连号
        if let ascn = am.scene_id, let bscn = bm.scene_id,
           let aidx = am.scene_seg_idx, let bidx = bm.scene_seg_idx,
           ascn == bscn, bidx == aidx + 1 { return true }

        // 3) 跨场景边界但时间相接（prev.end ≈ next.start）
        let eps = 0.001 // 1ms 容忍
        if abs(am.end - bm.start) <= eps { return true }

        return false
    }

    private func annotateSegments(_ rows: [SegmentRow])
    -> [(row: SegmentRow, fromPrev: Bool, toNext: Bool, islandId: Int, spike: Bool)] {
        var out: [(SegmentRow, Bool, Bool, Int, Bool)] = []
        var island = 0
        for i in rows.indices {
            let cur = rows[i]
            let prev = (i > 0) ? rows[i-1] : nil
            let next = (i + 1 < rows.count) ? rows[i+1] : nil

            let fromPrev = isContiguous(prev, cur)
            if !fromPrev { island += 1 }
            let toNext = isContiguous(cur, next)

            // --- spike 计算（单位：秒；阈值转自你给的毫秒规则） ---
            let spike: Bool = {
                guard
                    let pm = prev?.matched_orig_seg,
                    let cm = cur.matched_orig_seg,
                    let nm = next?.matched_orig_seg
                else { return false }
                // 使用边界判断：prev.end 与 next.start 作为“交界”，当前用中点
                let prevEnd = pm.end
                let nextStart = nm.start
                let cMid = 0.5 * (cm.start + cm.end)

                let dt1 = abs(cMid - prevEnd)
                let dt2 = abs(nextStart - cMid)
                let dtCross = abs(nextStart - prevEnd)

                // 附加：若 seg_id 连续，也视为交界相邻
                let idAdjacent: Bool = {
                    if let ps = pm.seg_id, let ns = nm.seg_id { return ns == ps + 1 }
                    return false
                }()

                // 放宽“交界接近”的判定：
                // 1) 绝对阈值：dtCross <= 6s 认为 prev/next 仍然属于同一时间邻域；
                // 2) 或者相对阈值：当前与两侧都远离，且相对 dtCross 的比值很大（>=20），也视作尖刺场景；
                let crossLimit = 6.0
                let ratioGate = 20.0
                let ratio = min(dt1, dt2) / max(dtCross, 0.001)
                let adjacentLike = (dtCross <= crossLimit) || (ratio >= ratioGate) || idAdjacent

                let isSpike = adjacentLike && (dt1 > 1.000) && (dt2 > 1.000) && (min(dt1, dt2) > 5.0 * dtCross)

                if isSpike {
                    let f3: (Double) -> String = { String(format: "%.3f", $0) }
                    print("[Spike] seg #\(cur.seg_id)  prevEnd=\(fmt(prevEnd))  nextStart=\(fmt(nextStart))  cMid=\(fmt(cMid))  dt1=\(f3(dt1))  dt2=\(f3(dt2))  cross=\(f3(dtCross))  ratio=\(f3(ratio))  idAdj=\(idAdjacent)  crossLimit=\(f3(crossLimit))")
                }
                return isSpike
            }()

            out.append((cur, fromPrev, toNext, island, spike))
        }
        return out
    }
    
    private func islandColorFor(_ id: Int) -> Color {
        // Deterministic palette by island id (1-based); repeats every 8 islands
        let hues: [Double] = [0.03, 0.12, 0.20, 0.33, 0.58, 0.70, 0.80, 0.92]
        let h = hues[max(0, (id - 1) % hues.count)]
        return Color(hue: h, saturation: 0.65, brightness: 0.85)
    }

    private func bucket(_ key: String) -> [Candidate] {
        guard let segId = store.selectedSeg?.seg_id else { return [] }
        let arr = store.candBucketsBySeg[segId]?[key] ?? []
        if key == "corridor" { return dedupCorridor(arr) }
        return arr
    }

    @ViewBuilder
    private func candColumn(title: String, items: [Candidate]) -> some View {
        let hasSel = items.contains { sameCandidate(selectedCand, $0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline).bold()
                    .foregroundColor(hasSel ? .blue : .primary)
                if hasSel { Circle().fill(Color.blue).frame(width: 6, height: 6) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { (_, c) in
                        CandidateRowView(c: c,
                                         isSelected: sameCandidate(selectedCand, c),
                                         isBound: isBoundCandidate(c),
                                         onClick: {
                                             selectedCand = c
                                             previewCandidate(c)
                                         },
                                         onDoubleClick: {
                                             applyCandidate(c)
                                         })
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func applyAudioSelection() {
        switch audioSource {
        case "movie":
            store.pair.clip.isMuted = true
            store.pair.movie.isMuted = false
        default: // "clip"
            store.pair.clip.isMuted = false
            store.pair.movie.isMuted = true
        }
    }

    private func previewCandidate(_ c: Candidate) {
        guard let seg = store.selectedSeg else { return }
        let clipStart = seg.clip.start
        let clipEnd   = seg.clip.end
        let movieStart = c.start
        let movieEnd   = c.end
        store.pair.playPair(
            clipStart: clipStart,
            clipEnd: clipEnd,
            movieStart: movieStart,
            movieEnd: movieEnd,
            togetherLoop: store.loopPair,
            mirrorClip: store.mirrorClip,
            clipURL: store.clipURL(),
            movieURL: store.movieURL(),
            loopCount: maxLoops
        )
    }

    private func applySelected() {
        if let cand = selectedCand {
            Task { await store.applyCurrentCandidate(cand) }
            return
        }
        guard selectedCandIdx < store.candidates.count else { return }
        let cand = store.candidates[selectedCandIdx]
        Task { await store.applyCurrentCandidate(cand) }
    }
    
    private func applyCandidate(_ cand: Candidate) {
        selectedCand = cand
        Task { await store.applyCurrentCandidate(cand) }
    }

    private func selectPrevSegment() {
        guard let current = store.selectedSeg?.seg_id,
              let idx = store.allSegments.firstIndex(where: { $0.seg_id == current }),
              idx > 0 else { return }
        let prev = store.allSegments[idx - 1]
        Task { await store.select(seg: prev) }
    }

    private func selectNextSegment() {
        guard let current = store.selectedSeg?.seg_id,
              let idx = store.allSegments.firstIndex(where: { $0.seg_id == current }),
              idx + 1 < store.allSegments.count else { return }
        let next = store.allSegments[idx + 1]
        Task { await store.select(seg: next) }
    }
    
    private func sameCandidate(_ a: Candidate?, _ b: Candidate) -> Bool {
        guard let a = a else { return false }
        if let asid = a.seg_id, let bsid = b.seg_id { return asid == bsid }
        // 兜底：用时间段比较（防止 seg_id 缺失）
        let eps = 0.001
        return abs(a.start - b.start) < eps && abs(a.end - b.end) < eps
    }

    // Helper to deduplicate corridor candidates
    private func dedupCorridor(_ xs: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        for c in xs {
            let key = "\(c.seg_id ?? -1)#\(Int(c.start * 1000))#\(Int(c.end * 1000))"
            if seen.insert(key).inserted {
                out.append(c)
            }
        }
        return out
    }
    
    // Bound (orange) = candidate that matches the selected left segment's current mapping
    private func isBoundCandidate(_ c: Candidate) -> Bool {
        guard let seg = store.selectedSeg, let m = seg.matched_orig_seg else { return false }
        // 优先：seg_id 相同
        if let ms = m.seg_id, let cs = c.seg_id, ms == cs { return true }
        // 兜底：时间段一致（小容差）
        let eps = 0.010 // 10ms 容忍
        return abs(m.start - c.start) <= eps && abs(m.end - c.end) <= eps
    }
}

struct SegmentRowView: View {
    let row: SegmentRow
    let isSelected: Bool
    let hasOverride: Bool
    // continuity
    let fromPrev: Bool
    let toNext: Bool
    let islandColor: Color
    // spike
    let isSpike: Bool

    private var statusColor: Color {
        switch row.review_status {
        case "ok": return .green
        case "needTrim": return .yellow
        case "unsure": return .orange
        case "mismatch": return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ContinuityPip(color: islandColor, fromPrev: fromPrev, toNext: toNext)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("#\(row.seg_id)  S\(row.clip.scene_id ?? -1)/idx \(row.clip.scene_seg_idx ?? -1)")
                        .fontWeight(isSelected ? .bold : .regular)
                    if hasOverride { Text("✓").foregroundColor(.blue) }
                    if isSpike {
                        Text("⚡︎")
                            .foregroundColor(.pink)
                            .padding(.horizontal, 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.pink.opacity(0.6), lineWidth: 1)
                            )
                    }
                    let st = (row.review_status?.isEmpty == false) ? row.review_status! : "-"
                    Group {
                        if row.review_status?.isEmpty == false {
                            Circle().fill(statusColor).frame(width: 8, height: 8)
                        } else {
                            Circle().stroke(.secondary, lineWidth: 1).frame(width: 8, height: 8)
                        }
                        Text(st).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let mo = row.matched_orig_seg {
                        Text("seg \(mo.seg_id ?? -1) S\(mo.scene_id ?? -1)/idx \(mo.scene_seg_idx ?? -1)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("-").foregroundStyle(.secondary)
                    }
                }
                Text("clip: \(fmt(row.clip.start)) – \(fmt(row.clip.end))").font(.caption).foregroundStyle(.secondary)
                if let mo = row.matched_orig_seg {
                    Text("movie: \(fmt(mo.start)) – \(fmt(mo.end))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.blue.opacity(0.28) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSpike ? Color.red : Color.clear, lineWidth: isSpike ? 2 : 0)
        )
    }
}

struct ContinuityPip: View {
    let color: Color
    let fromPrev: Bool
    let toNext: Bool
    var body: some View {
        GeometryReader { g in
            let lineW: CGFloat = 3
            let dotR: CGFloat = 4
            let midY = g.size.height / 2
            let x = (g.size.width - lineW) / 2

            Path { p in
                // 上半段：顶 -> 圆点上缘
                if fromPrev {
                    p.addRect(CGRect(x: x,
                                     y: 0,
                                     width: lineW,
                                     height: max(0, midY - dotR)))
                }
                // 圆点
                p.addEllipse(in: CGRect(x: (g.size.width - dotR*2)/2,
                                        y: midY - dotR,
                                        width: dotR*2,
                                        height: dotR*2))
                // 下半段：圆点下缘 -> 底
                if toNext {
                    p.addRect(CGRect(x: x,
                                     y: midY + dotR,
                                     width: lineW,
                                     height: max(0, g.size.height - (midY + dotR))))
                }
            }
            .fill(color)
        }
        .frame(width: 12) // 左侧占位宽
    }
}

struct CandidateRowView: View {
    let c: Candidate
    let isSelected: Bool
    let isBound: Bool
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("seg \(c.seg_id ?? -1) S\(c.scene_id ?? -1)/idx \(c.scene_seg_idx ?? -1)")
                    .fontWeight(isSelected ? .bold : .regular)
                Spacer()
                Text((c.score ?? 0).formatted(.number.precision(.fractionLength(3))))
            }
            Text("\(fmt(c.start)) – \(fmt(c.end))  src: \(c.source ?? "-")").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.10) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? Color.blue : (isBound ? Color.orange : Color.clear),
                    lineWidth: (isSelected || isBound) ? 2 : 0
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleClick() }   // 双击 = 应用所选
        .onTapGesture { onClick() }                  // 单击 = 选中 + 预览
    }
}

fileprivate func fmt(_ t: Double) -> String {
    let m = Int(t) / 60
    let s = Int(t) % 60
    let ms = Int((t - floor(t)) * 1000)
    return String(format: "%02d:%02d.%03d", m, s, ms)
}
