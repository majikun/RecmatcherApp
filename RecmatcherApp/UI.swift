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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                // Left: segments
                VStack(alignment: .leading) {
                    Text("段落列表").font(.headline).padding(.bottom, 6)
                    List(selection: Binding(get: {
                        store.selectedSeg?.seg_id
                    }, set: { _ in })) {
                        ForEach(store.allSegments) { s in
                            SegmentRowView(row: s, isSelected: store.selectedSeg?.seg_id == s.seg_id, hasOverride: s.is_override == true)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task { await store.select(seg: s) }
                                }
                        }
                    }
                }
                .frame(minWidth: 340)

                // Middle: dual players
                VStack(spacing: 8) {
                    HStack {
                        Button(action: togglePlayPause) {
                            Text(isPlaying ? "⏸️ 暂停" : "▶️ 播放")
                        }
                        Toggle("同步循环", isOn: $store.loopPair).onChange(of: store.loopPair) { _, newVal in
                            if let seg = store.selectedSeg {
                                Task { await store.select(seg: seg) }
                            }
                        }
                        Toggle("镜像 Clip", isOn: $store.mirrorClip).onChange(of: store.mirrorClip) { _, _ in
                            // layer transform updates via PlayerView.updateNSView
                        }
                        Spacer()
                        Text("循环次数: ∞ / \(maxLoops)").font(.footnote).foregroundColor(.secondary)
                    }
                    .padding(.bottom, 4)

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
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 480, maxWidth: .infinity)

                // Right: candidates
                VStack(alignment: .leading) {
                    HStack {
                        Text("候选（当前段）").font(.headline)
                        Picker("", selection: $store.candMode) {
                            Text("Top").tag("top")
                            Text("场景内").tag("scene")
                            Text("走廊").tag("corridor")
                            Text("全部").tag("all")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: store.candMode) { _, _ in
                            if let seg = store.selectedSeg {
                                Task { await store.loadCandidates(for: seg) }
                            }
                        }
                        Spacer()
                        // 当前校对状态展示
                        Group {
                            if let st = store.selectedSeg?.review_status, !st.isEmpty {
                                Text("状态：\(st)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("状态：-").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        // 校对状态菜单 {"anchor", "matched", "deferred", "rejected"}
                        Menu("校对状态") {
                            Button("OK") { Task { await store.updateReviewStatus("ok") } }
                            Button("Need Trim") { Task { await store.updateReviewStatus("needTrim") } }
                            Button("Unsure") { Task { await store.updateReviewStatus("unsure") } }
                            Button("Mismatch") { Task { await store.updateReviewStatus("mismatch") } }
                        }
                        Button("应用所选") { applySelected() }.keyboardShortcut(.return, modifiers: [])
                    }
                    .padding(.bottom, 6)

                    List(selection: $selectedCandIdx) {
                        ForEach(Array(store.candidates.enumerated()), id: \.offset) { (i, c) in
                            CandidateRowView(c: c, isSelected: i == selectedCandIdx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedCandIdx = i
                                    previewCandidate(c)
                                }
                        }
                    }
                }
                .frame(minWidth: 360)
            }
        }
        .onAppear {
            // If you want to start without openProject, set DEFAULT_* constants in Core.swift
            if let first = store.allSegments.first {
                Task { await store.select(seg: first) }
            }
        }
        .padding(8)
    }

    private var isPlaying: Bool {
        (store.pair.clip.rate != 0) || (store.pair.movie.rate != 0)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("project root", text: $store.projectRoot).textFieldStyle(.roundedBorder).frame(width: 340)
            TextField("movie.mp4 (local path, optional)", text: $store.moviePath).textFieldStyle(.roundedBorder).frame(width: 320)
            TextField("clip.mp4 (local path, optional)", text: $store.clipPath).textFieldStyle(.roundedBorder).frame(width: 320)
            Button("授权Movie…") {
                store.authorizeMovieFile()
                Task { await store.openProject() }
            }
            Button("授权Clip…") {
                store.authorizeClipFile()
                Task { await store.openProject() }
            }
            Button("打开") { Task { await store.openProject() } }
            Button("刷新场景") { Task { await store.loadEverythingAfterOpen() } }
            Button("刷新状态") { Task { await store.refreshReviewStates() } }
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

    private func previewCandidate(_ c: Candidate) {
        guard let seg = store.selectedSeg else { return }
        let clipStart = seg.clip.start
        let clipEnd   = seg.clip.end
        let movieStart = c.start
        let movieEnd   = c.end
        store.pair.playPair(clipStart: clipStart, clipEnd: clipEnd, movieStart: movieStart, movieEnd: movieEnd, togetherLoop: store.loopPair, mirrorClip: store.mirrorClip, clipURL: store.clipURL(), movieURL: store.movieURL())
    }

    private func applySelected() {
        guard selectedCandIdx < store.candidates.count else { return }
        let cand = store.candidates[selectedCandIdx]
        Task { await store.applyCurrentCandidate(cand) }
    }
}

struct SegmentRowView: View {
    let row: SegmentRow
    let isSelected: Bool
    let hasOverride: Bool

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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(row.seg_id)  S\(row.clip.scene_id ?? -1)/idx \(row.clip.scene_seg_idx ?? -1)")
                    .fontWeight(isSelected ? .bold : .regular)
                if hasOverride { Text("✓").foregroundColor(.blue) }
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
                    Text("seg \(mo.seg_id) S\(mo.scene_id)/idx \(mo.scene_seg_idx ?? -1)").foregroundStyle(.secondary)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            Text("clip: \(fmt(row.clip.start)) – \(fmt(row.clip.end))").font(.caption).foregroundStyle(.secondary)
            if let mo = row.matched_orig_seg {
                Text("movie: \(fmt(mo.start)) – \(fmt(mo.end))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }
}

struct CandidateRowView: View {
    let c: Candidate
    let isSelected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("seg \(c.seg_id) S\(c.scene_id)/idx \(c.scene_seg_idx ?? -1)")
                    .fontWeight(isSelected ? .bold : .regular)
                Spacer()
                Text((c.score ?? 0).formatted(.number.precision(.fractionLength(3))))
            }
            Text("\(fmt(c.start)) – \(fmt(c.end))  src: \(c.source ?? "-")").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }
}

fileprivate func fmt(_ t: Double) -> String {
    let m = Int(t) / 60
    let s = Int(t) % 60
    let ms = Int((t - floor(t)) * 1000)
    return String(format: "%02d:%02d.%03d", m, s, ms)
}
