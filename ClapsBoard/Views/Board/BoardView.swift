//
//  BoardView.swift
//  ClapsBoard
//
//  Main whiteboard view with drawing canvas and tools
//

import SwiftUI
import PencilKit
import UIKit
import PDFKit
import PhotosUI
import ImageIO

struct BoardView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var lessonStore: LessonStore
    @EnvironmentObject var appState: AppState

    @State private var showClearConfirm = false
    @State private var showExportSheet = false
    @State private var showMenu = false
    @State private var exportedImage: UIImage?
    @State private var exportedPDFURL: URL?
    @State private var isExporting = false
    @State private var showLessonLibrary = false
    @State private var isTeachMode = false
    @State private var teachStartedAt: Date?
    @State private var teachElapsed: TimeInterval = 0
    @State private var teachHistoryId: UUID?
    @State private var showMathToolkit = false
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photoInsertFailed = false
    @State private var showLayerControls = false
    @State private var showPageSwitcher = false
    @State private var showDocumentBesideBoard = false
    @State private var boardSplitRatio: CGFloat = 0.56
    @State private var splitDragStartRatio: CGFloat?
    @State private var documentResizeVersion = 0
    @GestureState private var magnificationState: CGFloat = 1.0
    @GestureState private var isMagnificationGestureActive = false
    @State private var lastPanValue: DragGesture.Value?
    @State private var isSuppressingDrawingForCanvasTransform = false

    // Haptic feedback for shake gesture
    private let notificationFeedback = UINotificationFeedbackGenerator()

    @State private var showDeletePageConfirm = false
    @State private var exportMessage: String?
    /// Lesson whose page is on the board, to tell a page flip from a lesson switch.
    @State private var loadedLessonId: UUID?
    /// Teach Mode only turns the camera back off if it was the one to turn it on.
    @State private var teachTurnedCameraOn = false

    // One fixed size. Element coordinates are absolute and the view is centred
    // on canvasSize / 2, so the size must never change. It used to switch to
    // 15000 for a regular width class, which Plus/Max iPhones report in
    // landscape: rotating moved the centre by 2500 pt and the board looked empty.
    private let canvasSize: CGFloat = 10000

    // Larger values cause Core Animation to request textures beyond the GPU's
    // supported dimensions on high-density iPhones (for example 11k × 23k).
    private let maximumSafeZoom: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let usesSideSplit = showDocumentBesideBoard && geometry.size.width > geometry.size.height
            let boardWidth = usesSideSplit ? geometry.size.width * boardSplitRatio : geometry.size.width
            let boardHeight = showDocumentBesideBoard && !usesSideSplit ? geometry.size.height * boardSplitRatio : geometry.size.height
            // Live pinch value, held to the same limits as the committed zoom.
            let liveZoom = max(0.1, min(maximumSafeZoom, viewModel.zoom * magnificationState))
            // The canvas scales about its own centre and is then offset by
            // pan, so scaling pan by the same factor keeps whatever is at the
            // centre of the board area in place while zooming.
            let liveZoomRatio = liveZoom / max(viewModel.zoom, 0.0001)
            ZStack {
                ZStack {
                    CanvasBackground(gridStyle: viewModel.gridStyle)
                        .frame(width: canvasSize, height: canvasSize)

                    // Drawing Canvas
                    DrawingCanvas(
                        viewModel: viewModel,
                        isCanvasTransformGestureActive: isMagnificationGestureActive || isSuppressingDrawingForCanvasTransform
                    )
                        .frame(width: canvasSize, height: canvasSize)
                }
                .scaleEffect(liveZoom)
                .offset(x: viewModel.pan.x * liveZoomRatio, y: viewModel.pan.y * liveZoomRatio)
                .gesture(
                    MagnificationGesture()
                        .updating($magnificationState) { value, state, _ in
                            state = value
                        }
                        .updating($isMagnificationGestureActive) { _, state, _ in
                            state = true
                        }
                        .onEnded { value in
                            isSuppressingDrawingForCanvasTransform = true
                            let newZoom = viewModel.zoom * value
                            let clampedZoom = max(0.1, min(maximumSafeZoom, newZoom))

                            // Haptic feedback at zoom limits
                            if newZoom != clampedZoom {
                                let generator = UIImpactFeedbackGenerator(style: .rigid)
                                generator.impactOccurred()
                            }

                            // Same anchoring as the live preview above, so
                            // nothing jumps when the fingers lift.
                            let ratio = clampedZoom / max(viewModel.zoom, 0.0001)
                            viewModel.pan = CGPoint(x: viewModel.pan.x * ratio, y: viewModel.pan.y * ratio)
                            viewModel.zoom = clampedZoom
                            releaseDrawingSuppressionAfterCanvasTransform()
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // With Select, a drag on empty canvas pans, but a drag that is
                            // moving or resizing an element must not pan as well.
                            let isPanning = viewModel.tool == .pan
                                || (viewModel.tool == .select && !viewModel.isManipulatingSelection)
                            if isPanning {
                                if let last = lastPanValue {
                                    let deltaX = value.translation.width - last.translation.width
                                    let deltaY = value.translation.height - last.translation.height
                                    viewModel.pan.x += deltaX
                                    viewModel.pan.y += deltaY
                                }
                                lastPanValue = value
                            }
                        }
                        .onEnded { _ in
                            lastPanValue = nil
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            // Only with the navigation tools. With a pen, two
                            // quick dots (":" or "=") must not reset the view.
                            guard viewModel.tool == .pan || viewModel.tool == .select else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.zoom = 1.0
                                viewModel.pan = .zero
                            }
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                        }
                )
                .frame(width: boardWidth, height: boardHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .ignoresSafeArea()

                // Empty canvas state
                if viewModel.elements.isEmpty && !viewModel.isDrawing {
                    Text("Tap anywhere to begin")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.46))
                        .frame(width: boardWidth, height: boardHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Tap anywhere to begin")
                }

                // Teach Mode swaps the header for its own bar but keeps the
                // drawing toolbar (tools, undo/redo, eraser) on screen.
                controlsLayer(in: geometry, availableSize: CGSize(width: boardWidth, height: boardHeight), showsHeader: !isTeachMode)
                    .frame(width: boardWidth, height: boardHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if isTeachMode {
                    teachModeControls(in: geometry)
                        .frame(width: boardWidth, height: boardHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if showPageSwitcher {
                    pageNavigation(in: geometry)
                        .frame(width: boardWidth, height: boardHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if viewModel.activeLayer != .base || hasPreparedAnswer {
                    answerRevealQuickControl(in: geometry)
                        .frame(width: boardWidth, height: boardHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .zIndex(15)
                }

                // Export loading overlay
                if isExporting {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Exporting...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .padding(30)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                // Zoom level indicator
                if viewModel.zoom != 1.0 {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(Int(viewModel.zoom * 100))%")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                        Spacer()
                    }
                    .accessibilityLabel("Canvas zoom level \(Int(viewModel.zoom * 100)) percent")
                    .accessibilityHint("Double tap to reset zoom to 100 percent")
                    .transition(.opacity.combined(with: .scale))
                }

                if showDocumentBesideBoard {
                    Group {
                        if usesSideSplit {
                            HStack(spacing: 0) {
                                Spacer().frame(width: boardWidth)
                                Rectangle()
                                    .fill(AppTheme.accent.opacity(0.65))
                                    .frame(width: 6)
                                    .contentShape(Rectangle().inset(by: -12))
                                    .gesture(splitResizeGesture(totalLength: geometry.size.width, usesHorizontalMovement: true))
                                BoardDocumentPanel(resizeVersion: documentResizeVersion, onClose: { showDocumentBesideBoard = false })
                            }
                        } else {
                            VStack(spacing: 0) {
                                Spacer().frame(height: boardHeight)
                                Rectangle()
                                    .fill(AppTheme.accent.opacity(0.65))
                                    .frame(height: 6)
                                    .contentShape(Rectangle().inset(by: -12))
                                    .gesture(splitResizeGesture(totalLength: geometry.size.height, usesHorizontalMovement: false))
                                BoardDocumentPanel(resizeVersion: documentResizeVersion, onClose: { showDocumentBesideBoard = false })
                            }
                        }
                    }
                    .transition(.move(edge: .bottom))
                    .zIndex(20)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.2), value: viewModel.zoom)
        // Cmd+Z / Shift+Cmd+Z for a hardware keyboard. These live in an
        // always-present, invisible background: in the `.keyboard` toolbar
        // they only existed while the software keyboard was up.
        .background {
            Group {
                Button("Undo") { if viewModel.canUndo { viewModel.undo() } }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { if viewModel.canRedo { viewModel.redo() } }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // Clear Confirmation
        .alert("Clear Whiteboard?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                viewModel.clearBoard()
            }
        } message: {
            Text("This will remove all drawings and notes permanently.")
        }
        .alert("Delete Page?", isPresented: $showDeletePageConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive, action: deletePage)
        } message: {
            Text("\u{201C}\(lessonStore.activePage.title)\u{201D} and everything on it will be removed. This can't be undone.")
        }
        .alert(
            "Export",
            isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportMessage ?? "")
        }
        // Export Sheet
        .sheet(isPresented: $showExportSheet, onDismiss: {
            // Clean up exported image to free memory and reset state
            exportedImage = nil
            if let url = exportedPDFURL { try? FileManager.default.removeItem(at: url) }
            exportedPDFURL = nil
        }) {
            if let url = exportedPDFURL {
                ShareSheet(items: [url])
            } else if let image = exportedImage {
                ShareSheet(items: [image])
            }
        }
        .sheet(isPresented: $showLessonLibrary) {
            LessonLibraryView(
                store: lessonStore,
                onOpen: loadActiveLesson,
                onTeach: startTeachMode,
                onActiveLessonDeleted: reloadActiveLessonPage,
                onLessonDeleted: purgeUnreferencedMedia
            )
        }
        .sheet(isPresented: $showMathToolkit) {
            MathToolkitView { image, diagram in insertMathDiagram(image, diagram) }
        }
        // The system picker runs out of process, so no photo permission is needed.
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil // so the same photo can be picked again
            insertPhoto(item)
        }
        .alert("Couldn't Add Image", isPresented: $photoInsertFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("That photo could not be loaded. Try another one.")
        }
        .sheet(isPresented: $showLayerControls) {
            AnswerLayerControls(
                viewModel: viewModel,
                onPrepare: beginAnswerPreparation,
                onRevealNext: revealNextAnswerStep,
                onHideAll: hidePreparedAnswers
            )
                .presentationDetents([.medium])
        }
        .onAppear {
            viewModel.zoom = min(maximumSafeZoom, max(0.1, viewModel.zoom))
            loadActiveLesson()
        }
        .onChange(of: viewModel.elements) { _, elements in
            lessonStore.updateActivePage(elements: elements, gridStyle: viewModel.gridStyle)
        }
        .onChange(of: viewModel.gridStyle) { _, style in
            lessonStore.updateActivePage(elements: viewModel.elements, gridStyle: style)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if let started = teachStartedAt { teachElapsed = Date().timeIntervalSince(started) }
        }
    }

    private func splitResizeGesture(totalLength: CGFloat, usesHorizontalMovement: Bool) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if splitDragStartRatio == nil { splitDragStartRatio = boardSplitRatio }
                let translation = usesHorizontalMovement ? value.translation.width : value.translation.height
                let nextRatio = min(0.76, max(0.34, (splitDragStartRatio ?? boardSplitRatio) + translation / max(totalLength, 1)))
                if abs(nextRatio - boardSplitRatio) > 0.002 { boardSplitRatio = nextRatio }
            }
            .onEnded { _ in
                splitDragStartRatio = nil
                documentResizeVersion += 1
            }
    }

    private func releaseDrawingSuppressionAfterCanvasTransform() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isSuppressingDrawingForCanvasTransform = false
        }
    }

    private func handleExport() {
        // Prevent multiple simultaneous export operations
        // Fixes: "Trying to perform UISocialActivity but there is already an activity performing"
        guard !isExporting && !showExportSheet else {
            print("⚠️ Export already in progress, ignoring duplicate request")
            return
        }

        // Show loading state
        isExporting = true

        // Use async export to prevent UI blocking
        viewModel.exportImageAsync { image in
            // Update state on main thread
            isExporting = false
            if let image = image {
                exportedImage = image
                showExportSheet = true
            } else {
                exportMessage = viewModel.calculateContentBounds() == nil
                    ? "There is nothing on this page to export yet."
                    : "The image could not be created. Please try again."
            }
        }
    }

    private func loadActiveLesson() {
        reloadActiveLessonPage()
        showLessonLibrary = false
    }

    /// Puts the store's active page on the board without closing the library.
    private func reloadActiveLessonPage() {
        // Zoom and pan survive a page change; a different lesson starts centred.
        let isNewLesson = loadedLessonId != lessonStore.activeLessonId
        loadedLessonId = lessonStore.activeLessonId
        viewModel.loadLessonPage(lessonStore.activePage, resetView: isNewLesson)
        hidePreparedAnswers()
    }

    private func openPage(_ id: UUID) {
        lessonStore.openPage(id)
        reloadActiveLessonPage()
    }

    /// Removes image files that no page of any lesson (and no undo step of the
    /// open page) uses any more. Called after a page or lesson is deleted.
    private func purgeUnreferencedMedia() {
        StorageService.shared.purgeMedia(keeping: lessonStore.referencedMediaIds.union(viewModel.referencedMediaIds))
    }

    private func addPage() {
        _ = lessonStore.addPage()
        loadActiveLesson()
    }

    private func deletePage() {
        lessonStore.deleteActivePage()
        loadActiveLesson()
        purgeUnreferencedMedia()
    }

    private func startTeachMode() {
        loadActiveLesson()
        isTeachMode = true
        teachStartedAt = Date()
        teachElapsed = 0
        let historyId = UUID()
        teachHistoryId = historyId
        if var student = lessonStore.students.first(where: { $0.id == lessonStore.activeLesson.studentId }) {
            var history = student.lessonHistory ?? []
            history.insert(LessonHistoryItem(id: historyId, lessonId: lessonStore.activeLesson.id, lessonTitle: lessonStore.activeLesson.title, startedAt: Date(), finishedAt: nil, durationSeconds: nil), at: 0)
            student.lessonHistory = history
            lessonStore.updateStudent(student)
        }
        viewModel.showProperties = false
        teachTurnedCameraOn = !cameraManager.isActive
        if teachTurnedCameraOn { cameraManager.toggleCamera() }
    }

    private func stopTeachMode() {
        if let historyId = teachHistoryId,
           var student = lessonStore.students.first(where: { $0.id == lessonStore.activeLesson.studentId }),
           let index = student.lessonHistory?.firstIndex(where: { $0.id == historyId }) {
            student.lessonHistory?[index].finishedAt = Date()
            student.lessonHistory?[index].durationSeconds = Int(teachElapsed)
            lessonStore.updateStudent(student)
        }
        isTeachMode = false
        teachStartedAt = nil
        teachHistoryId = nil
        // Leave the camera as it was found: off again if Teach Mode started it.
        if teachTurnedCameraOn, cameraManager.isActive { cameraManager.toggleCamera() }
        teachTurnedCameraOn = false
    }

    private func exportLessonPDF() {
        guard !isExporting && !showExportSheet else { return }
        let lesson = lessonStore.activeLesson
        let layers = viewModel.visibleLayers
        guard lesson.pages.contains(where: { page in
            page.elements.contains { !$0.isDeleted && layers.contains($0.layer ?? .base) }
        }) else {
            exportMessage = "There is nothing in this lesson to export yet."
            return
        }
        isExporting = true
        Task { @MainActor in
            // The pages render on the main thread. Give SwiftUI a moment to
            // put the spinner on screen first, or it never appears.
            try? await Task.sleep(nanoseconds: 80_000_000)
            defer { isExporting = false }

            let pageBounds = CGRect(x: 0, y: 0, width: 842, height: 595)
            let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
            // A fixed dark colour: UIColor.label turns white in Dark Mode and
            // the PDF page is always white.
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 18),
                .foregroundColor: UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1)
            ]
            let data = renderer.pdfData { context in
                for page in lesson.pages {
                    context.beginPage()
                    let title = "\(lesson.title) — \(page.title)"
                    title.draw(at: CGPoint(x: 32, y: 22), withAttributes: titleAttributes)
                    if let image = viewModel.exportImage(elements: page.elements, gridStyle: page.gridStyle) {
                        let available = CGRect(x: 32, y: 58, width: pageBounds.width - 64, height: pageBounds.height - 90)
                        let scale = min(available.width / image.size.width, available.height / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        image.draw(in: CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height))
                    }
                }
            }
            let safeName = lesson.title.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)-lesson.pdf")
            do {
                try data.write(to: url, options: .atomic)
                exportedPDFURL = url
                showExportSheet = true
            } catch {
                exportMessage = "The lesson PDF could not be saved: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func teachModeControls(in geometry: GeometryProxy) -> some View {
        VStack {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TEACH MODE").font(.caption2.bold()).foregroundStyle(AppTheme.accent)
                        Text("\(lessonStore.activeLesson.title) · \(elapsedText)").font(.caption.bold()).foregroundStyle(.white).lineLimit(1)
                    }
                }
                .padding(.horizontal, 14).frame(height: 48)
                .background(.black.opacity(0.84), in: Capsule())

                Spacer()

                // Header is hidden in Teach Mode, so page controls open from here.
                Button { withAnimation { showPageSwitcher.toggle() } } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(showPageSwitcher ? AppTheme.accent : Color.black.opacity(0.84), in: Circle())
                }
                .accessibilityLabel("Page switcher")
                .accessibilityValue(showPageSwitcher ? "Visible" : "Hidden")

                Button(action: stopTeachMode) {
                    Label("Finish", systemImage: "stop.fill").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 48).background(.red, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            // In landscape the toolbar is a rail down the right edge; keep
            // Finish clear of it.
            .padding(.trailing, geometry.size.width > geometry.size.height ? resolvedSafeAreaInsets(for: geometry).trailing + 64 : 0)
            .padding(.top, resolvedSafeAreaInsets(for: geometry).top + 8)
            Spacer()
        }
    }

    @ViewBuilder
    private func pageNavigation(in geometry: GeometryProxy) -> some View {
        let lesson = lessonStore.activeLesson
        let index = lesson.pages.firstIndex(where: { $0.id == lesson.activePageId }) ?? 0
        VStack {
            Spacer()
            HStack(spacing: 3) {
                Button { withAnimation { showPageSwitcher = false } } label: {
                    Image(systemName: "xmark").frame(width: 40, height: 40)
                }

                Button { if index > 0 { openPage(lesson.pages[index - 1].id) } } label: {
                    Image(systemName: "chevron.left").frame(width: 40, height: 40)
                }.disabled(index == 0)

                Button { showLessonLibrary = true } label: {
                    VStack(spacing: 0) {
                        Text(lesson.pages[index].title).font(.caption.bold()).lineLimit(1)
                        Text("\(index + 1) of \(lesson.pages.count)").font(.caption2).foregroundStyle(.secondary)
                    }.frame(minWidth: 70, maxWidth: 120)
                }

                Button { if index + 1 < lesson.pages.count { openPage(lesson.pages[index + 1].id) } } label: {
                    Image(systemName: "chevron.right").frame(width: 40, height: 40)
                }.disabled(index + 1 == lesson.pages.count)

                Button(action: addPage) { Image(systemName: "plus").frame(width: 40, height: 40).background(AppTheme.accent, in: Circle()).foregroundStyle(.white) }

                if lesson.pages.count > 1 {
                    Button(role: .destructive) { showDeletePageConfirm = true } label: { Image(systemName: "trash").frame(width: 40, height: 40) }
                        .accessibilityLabel("Delete page")
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 12, y: 5)
            .padding(.bottom, geometry.size.width > geometry.size.height ? 8 : resolvedSafeAreaInsets(for: geometry).bottom + 72)
        }
    }

    private var elapsedText: String {
        let seconds = Int(teachElapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var hintItemCount: Int {
        viewModel.elements.filter { !$0.isDeleted && ($0.layer ?? .base) == .hint }.count
    }

    private var answerItemCount: Int {
        viewModel.elements.filter { !$0.isDeleted && ($0.layer ?? .base) == .solution }.count
    }

    private var hasPreparedAnswer: Bool { hintItemCount > 0 || answerItemCount > 0 }

    private var nextRevealTitle: String {
        if viewModel.visibleLayers.contains(.solution) { return "Hide prepared content" }
        if viewModel.visibleLayers.contains(.hint) { return answerItemCount > 0 ? "Reveal answer" : "Hide hint" }
        if hintItemCount > 0 { return "Reveal hint" }
        return "Reveal answer"
    }

    private func hidePreparedAnswers() {
        viewModel.activeLayer = .base
        viewModel.visibleLayers = [.base]
    }

    private func beginAnswerPreparation(_ layer: AnswerLayer) {
        guard layer != .base else { return }
        viewModel.activeLayer = layer
        viewModel.visibleLayers = [.base, layer]
        showLayerControls = false
    }

    private func revealNextAnswerStep() {
        viewModel.activeLayer = .base
        if hintItemCount > 0, !viewModel.visibleLayers.contains(.hint) {
            viewModel.visibleLayers = [.base, .hint]
        } else if answerItemCount > 0, !viewModel.visibleLayers.contains(.solution) {
            viewModel.visibleLayers = hintItemCount > 0 ? [.base, .hint, .solution] : [.base, .solution]
        } else {
            viewModel.visibleLayers = [.base]
        }
    }

    @ViewBuilder
    private func answerRevealQuickControl(in geometry: GeometryProxy) -> some View {
        VStack {
            if viewModel.activeLayer != .base {
                HStack(spacing: 10) {
                    Text("Preparing \(viewModel.activeLayer == .hint ? "HINT" : "ANSWER") · visible now")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Button("Done & Hide", action: hidePreparedAnswers)
                        .font(.caption.bold())
                        .foregroundStyle(.brown)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(.white, in: Capsule())
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .frame(height: 40)
                .background(.brown.opacity(0.94), in: Capsule())
                .shadow(radius: 8, y: 3)
            } else {
                Button(action: revealNextAnswerStep) {
                    Label(nextRevealTitle, systemImage: viewModel.visibleLayers.contains(.solution) ? "eye.slash" : "eye")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(viewModel.visibleLayers.contains(.solution) ? Color.secondary : AppTheme.accent, in: Capsule())
                        .shadow(radius: 7, y: 3)
                }
            }
            Spacer()
        }
        .padding(.top, resolvedSafeAreaInsets(for: geometry).top + 68)
    }

    @ViewBuilder
    private func controlsLayer(in geometry: GeometryProxy, availableSize: CGSize, showsHeader: Bool = true) -> some View {
        if geometry.size.width > geometry.size.height {
            landscapeControlRails(in: geometry, availableSize: availableSize, showsHeader: showsHeader)
        } else {
            portraitControlStack(in: geometry, showsHeader: showsHeader)
        }
    }

    @ViewBuilder
    private func portraitControlStack(in geometry: GeometryProxy, showsHeader: Bool) -> some View {
        let safeAreaInsets = resolvedSafeAreaInsets(for: geometry)
        let headerY = safeAreaInsets.top + 43
        let bottomControlPadding = safeAreaInsets.bottom + 8
        let propertiesPanelMaxWidth = min(geometry.size.width - 32, 420)

        Group {
            if showsHeader {
                headerControls(orientation: .horizontal)
                    .position(x: geometry.size.width / 2, y: headerY)
            }

            VStack(spacing: 16) {
                if viewModel.showProperties && viewModel.tool.supportsProperties {
                    PropertiesPanel(viewModel: viewModel)
                        .frame(maxWidth: propertiesPanelMaxWidth)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showProperties)
                }

                ToolbarView(viewModel: viewModel, onInsertImage: { showPhotoPicker = true })
                    .zIndex(1)
            }
            // 8pt keeps the full tool bar (with Marker) on 393pt-wide phones.
            .padding(.horizontal, 8)
            .padding(.bottom, bottomControlPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func landscapeControlRails(in geometry: GeometryProxy, availableSize: CGSize, showsHeader: Bool) -> some View {
        let metrics = BoardFloatingRailMetrics(
            containerSize: availableSize,
            safeAreaInsets: resolvedSafeAreaInsets(for: geometry),
            interfaceOrientation: activeInterfaceOrientation
        )

        return BoardFloatingSideRails(metrics: metrics) {
            if showsHeader {
                headerControls(orientation: .vertical)
            }
        } trailing: {
            HStack(spacing: metrics.controlClusterSpacing) {
                if viewModel.showProperties && viewModel.tool.supportsProperties {
                    PropertiesPanel(viewModel: viewModel)
                        .frame(width: metrics.propertiesPanelWidth)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showProperties)
                }

                ToolbarView(viewModel: viewModel, orientation: .vertical, onInsertImage: { showPhotoPicker = true })
            }
        }
    }

    private func resolvedSafeAreaInsets(for geometry: GeometryProxy) -> EdgeInsets {
        let windowInsets = activeWindowSafeAreaInsets

        return EdgeInsets(
            top: max(geometry.safeAreaInsets.top, windowInsets.top),
            leading: max(geometry.safeAreaInsets.leading, windowInsets.left),
            bottom: max(geometry.safeAreaInsets.bottom, windowInsets.bottom),
            trailing: max(geometry.safeAreaInsets.trailing, windowInsets.right)
        )
    }

    private var activeWindowSafeAreaInsets: UIEdgeInsets {
        guard let windowScene = activeWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return .zero
        }

        return window.safeAreaInsets
    }

    private var activeInterfaceOrientation: UIInterfaceOrientation {
        activeWindowScene?.interfaceOrientation ?? .unknown
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private func headerControls(orientation: BoardControlOrientation) -> some View {
        HeaderControls(
            viewModel: viewModel,
            cameraManager: cameraManager,
            showMenu: $showMenu,
            showClearConfirm: $showClearConfirm,
            onExport: handleExport,
            onExportLesson: exportLessonPDF,
            onLessons: { showLessonLibrary = true },
            onMathToolkit: { showMathToolkit = true },
            onLayers: { showLayerControls = true },
            onPageToggle: { withAnimation { showPageSwitcher.toggle() } },
            isPageSwitcherVisible: showPageSwitcher,
            onDocumentToggle: { withAnimation { showDocumentBesideBoard.toggle() } },
            isDocumentBesideBoard: showDocumentBesideBoard,
            orientation: orientation
        )
        .opacity(viewModel.isDrawing ? 0.28 : 1)
        .blur(radius: viewModel.isDrawing ? 0.7 : 0)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isDrawing)
    }

    private func insertMathDiagram(_ image: UIImage, _ diagram: MathDiagram) {
        guard let data = image.pngData(),
              let mediaId = StorageService.shared.saveMedia(data) else { return }
        insertImageElement(mediaId: mediaId, size: diagram.size, maxWidth: 560)
        showMathToolkit = false
    }

    /// Loads the picked photo, shrinks it and puts it on the board.
    private func insertPhoto(_ item: PhotosPickerItem) {
        Task {
            // Decoding and re-encoding a photo is too slow for the main thread.
            let prepared: (data: Data, size: CGSize)? = await Task.detached(priority: .userInitiated) {
                guard let raw = try? await item.loadTransferable(type: Data.self) else { return nil }
                return Self.downscaledImageData(from: raw, maxPixelSize: 1600)
            }.value
            await MainActor.run {
                guard let prepared, let mediaId = StorageService.shared.saveMedia(prepared.data) else {
                    photoInsertFailed = true
                    return
                }
                let element = insertImageElement(mediaId: mediaId, size: prepared.size, maxWidth: prepared.size.width)
                viewModel.selectedElement = element
            }
        }
    }

    /// Re-encodes an image so its longest side is at most `maxPixelSize`
    /// pixels (never enlarged), upright. ImageIO does this without first
    /// decoding the full-size photo. PNG is kept only for images with
    /// transparency; photos become JPEG, which is far smaller.
    nonisolated private static func downscaledImageData(from data: Data, maxPixelSize: CGFloat) -> (data: Data, size: CGSize)? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        let hasAlpha: Bool
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        guard let encoded = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.85) else { return nil }
        return (encoded, CGSize(width: cgImage.width, height: cgImage.height))
    }

    /// Adds an image element centred in the visible board area, keeping the
    /// aspect ratio of `size` (one undo step) and switches to Select.
    @discardableResult
    private func insertImageElement(mediaId: String, size: CGSize, maxWidth: CGFloat) -> DrawingElement {
        // Size it to at most ~70% of the visible board at the current zoom,
        // so it lands where the tutor is looking and fits on screen.
        let zoom = max(viewModel.zoom, 0.1)
        let windowSize = activeWindowScene?.windows.first(where: { $0.isKeyWindow })?.bounds.size ?? CGSize(width: 390, height: 844)
        let scale = min(0.7 * windowSize.width / zoom / max(size.width, 1),
                        0.6 * windowSize.height / zoom / max(size.height, 1),
                        maxWidth / max(size.width, 1))
        let width = size.width * scale
        let height = size.height * scale
        let visibleCenterX = canvasSize / 2 - viewModel.pan.x / max(viewModel.zoom, 0.1)
        let visibleCenterY = canvasSize / 2 - viewModel.pan.y / max(viewModel.zoom, 0.1)
        let element = DrawingElement(
            type: .image,
            x: visibleCenterX - width / 2,
            y: visibleCenterY - height / 2,
            width: width,
            height: height,
            mediaId: mediaId,
            layer: viewModel.activeLayer
        )
        viewModel.addElement(element)
        viewModel.tool = .select
        return element
    }
}

// MARK: - Floating Board Rails
private struct BoardFloatingRailMetrics {
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let interfaceOrientation: UIInterfaceOrientation

    private enum Value {
        static let borderClearance: CGFloat = 8
        static let safeAreaTieTolerance: CGFloat = 4
        static let verticalClearance: CGFloat = 10
        static let controlClusterSpacing: CGFloat = 12
        static let propertiesWidthRatio: CGFloat = 0.34
        static let minimumPropertiesWidth: CGFloat = 260
        static let maximumPropertiesWidth: CGFloat = 340
    }

    var verticalInset: CGFloat {
        max(safeAreaInsets.top, safeAreaInsets.bottom) + Value.verticalClearance
    }

    var controlClusterSpacing: CGFloat {
        Value.controlClusterSpacing
    }

    var propertiesPanelWidth: CGFloat {
        min(
            max(containerSize.width * Value.propertiesWidthRatio, Value.minimumPropertiesWidth),
            Value.maximumPropertiesWidth
        )
    }

    func edgeInset(for side: BoardFloatingRailSide) -> CGFloat {
        guard side == dynamicIslandSide else {
            return Value.borderClearance
        }

        return side.safeAreaInset(from: safeAreaInsets) + Value.borderClearance
    }

    private var dynamicIslandSide: BoardFloatingRailSide? {
        switch interfaceOrientation {
        case .landscapeLeft:
            return .trailing
        case .landscapeRight:
            return .leading
        default:
            return sideWithLargerSafeArea
        }
    }

    private var sideWithLargerSafeArea: BoardFloatingRailSide? {
        let leading = safeAreaInsets.leading
        let trailing = safeAreaInsets.trailing

        guard abs(leading - trailing) > Value.safeAreaTieTolerance else {
            return nil
        }

        return leading > trailing ? .leading : .trailing
    }
}

private enum BoardFloatingRailSide {
    case leading
    case trailing

    var paddingEdge: Edge.Set {
        switch self {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    func safeAreaInset(from insets: EdgeInsets) -> CGFloat {
        switch self {
        case .leading:
            return insets.leading
        case .trailing:
            return insets.trailing
        }
    }
}

private struct BoardFloatingSideRails<LeadingRail: View, TrailingRail: View>: View {
    let metrics: BoardFloatingRailMetrics
    private let leadingRail: LeadingRail
    private let trailingRail: TrailingRail

    init(
        metrics: BoardFloatingRailMetrics,
        @ViewBuilder leading: () -> LeadingRail,
        @ViewBuilder trailing: () -> TrailingRail
    ) {
        self.metrics = metrics
        self.leadingRail = leading()
        self.trailingRail = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: metrics.controlClusterSpacing) {
            BoardFloatingRail(side: .leading, metrics: metrics) {
                leadingRail
            }

            Spacer(minLength: 0)
                .allowsHitTesting(false)

            BoardFloatingRail(side: .trailing, metrics: metrics) {
                trailingRail
            }
        }
        .padding(.vertical, metrics.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BoardFloatingRail<Content: View>: View {
    let side: BoardFloatingRailSide
    let metrics: BoardFloatingRailMetrics
    private let content: Content

    init(
        side: BoardFloatingRailSide,
        metrics: BoardFloatingRailMetrics,
        @ViewBuilder content: () -> Content
    ) {
        self.side = side
        self.metrics = metrics
        self.content = content()
    }

    var body: some View {
        content
            .padding(side.paddingEdge, metrics.edgeInset(for: side))
    }
}

// MARK: - Canvas Background
/// Adaptive background that supports Light and Dark Mode (HIG: Color Usage)
struct CanvasBackground: View {
    let gridStyle: GridStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AppTheme.canvasBase

            RadialGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.04 : 0.68),
                    AppTheme.canvasWarmth.opacity(colorScheme == .dark ? 0.04 : 0.28),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: 620
            )
            .blendMode(.softLight)

            CanvasTextureView(colorScheme: colorScheme)
                .opacity(colorScheme == .dark ? 0.16 : 0.11)

            if gridStyle.isVisible {
                GridPatternView(style: gridStyle, colorScheme: colorScheme)
                    .id(gridStyle)
            }

            RadialGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.08 : 0.035)
                ],
                center: .center,
                startRadius: 280,
                endRadius: 980
            )
            .blendMode(.multiply)
        }
    }
}

struct CanvasTextureView: View {
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let lineColor = colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y + 6))
                context.stroke(path, with: .color(lineColor), lineWidth: 0.35)
                y += 56
            }
        }
    }
}

/// Grid pattern rendered as a separate view for proper redraw
struct GridPatternView: View {
    let style: GridStyle
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            let dotRadius: CGFloat = 1.05
            let gridColor = colorScheme == .dark ?
                Color.white.opacity(0.13) : Color.gray.opacity(0.13)
            let majorGridColor = colorScheme == .dark ?
                Color.white.opacity(0.19) : Color.gray.opacity(0.2)

            switch style {
            case .none:
                break

            case .dots:
                var x: CGFloat = spacing / 2
                while x < size.width {
                    var y: CGFloat = spacing / 2
                    while y < size.height {
                        let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(gridColor))
                        y += spacing
                    }
                    x += spacing
                }

            case .lines:
                drawLineGrid(in: &context, size: size, spacing: spacing, color: gridColor)

            case .graph:
                drawLineGrid(in: &context, size: size, spacing: spacing, color: gridColor)
                drawLineGrid(in: &context, size: size, spacing: spacing * 5, color: majorGridColor, lineWidth: 0.8)

            case .isometric:
                drawIsometricGrid(in: &context, size: size, spacing: spacing, color: gridColor)
            }
        }
    }

    private func drawLineGrid(
        in context: inout GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        color: Color,
        lineWidth: CGFloat = 0.45
    ) {
        var x: CGFloat = 0
        while x <= size.width {
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
            x += spacing
        }

        var y: CGFloat = 0
        while y <= size.height {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
            y += spacing
        }
    }

    private func drawIsometricGrid(
        in context: inout GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        color: Color
    ) {
        let slope: CGFloat = 0.58
        var offset: CGFloat = -size.height
        while offset < size.width {
            var path = Path()
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset + size.height / slope, y: size.height))
            context.stroke(path, with: .color(color), lineWidth: 0.45)
            offset += spacing
        }

        offset = -size.height / slope
        while offset < size.width {
            var path = Path()
            path.move(to: CGPoint(x: offset, y: size.height))
            path.addLine(to: CGPoint(x: offset + size.height / slope, y: 0))
            context.stroke(path, with: .color(color), lineWidth: 0.45)
            offset += spacing
        }

        var y: CGFloat = 0
        while y <= size.height {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(color.opacity(0.72)), lineWidth: 0.35)
            y += spacing
        }
    }
}

// MARK: - Header Controls
/// Top header controls with accessibility support (HIG: Accessibility)
struct HeaderControls: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var cameraManager: CameraManager
    @EnvironmentObject var appState: AppState
    
    @Binding var showMenu: Bool
    @Binding var showClearConfirm: Bool
    let onExport: () -> Void
    let onExportLesson: () -> Void
    let onLessons: () -> Void
    let onMathToolkit: () -> Void
    let onLayers: () -> Void
    let onPageToggle: () -> Void
    let isPageSwitcherVisible: Bool
    let onDocumentToggle: () -> Void
    let isDocumentBesideBoard: Bool
    var orientation: BoardControlOrientation = .horizontal
    
    var body: some View {
        Group {
            if orientation == .vertical {
                VStack(spacing: 4) {
                    headerItems
                }
            } else {
                HStack(spacing: 4) {
                    headerItems
                }
            }
        }
        .padding(.vertical, orientation == .vertical ? 6 : 2)
        .padding(.horizontal, 5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .opacity(0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.04), radius: 16, y: 6)
    }

    @ViewBuilder
    private var headerItems: some View {
        AppModeMenu(
            selectedTab: $appState.selectedTab,
            presentation: orientation == .vertical ? .vertical : .horizontal
        )

        GridStyleMenu(gridStyle: $viewModel.gridStyle)

        PiPCameraButton(cameraManager: cameraManager)

        HeaderChromeButton(
            icon: "rectangle.stack",
            accessibilityLabel: "Page switcher",
            accessibilityValue: isPageSwitcherVisible ? "Visible" : "Hidden",
            accessibilityHint: "Shows or hides lesson page controls",
            isActive: isPageSwitcherVisible,
            action: onPageToggle
        )

        HeaderChromeButton(
            icon: "rectangle.split.1x2",
            accessibilityLabel: "Document below board",
            accessibilityValue: isDocumentBesideBoard ? "On" : "Off",
            accessibilityHint: "Shows or hides a local document below the board",
            isActive: isDocumentBesideBoard,
            action: onDocumentToggle
        )

        if cameraManager.isActive {
            HeaderChromeButton(
                icon: "video.fill",
                accessibilityLabel: "Camera",
                accessibilityValue: "On",
                accessibilityHint: "Tap to turn off camera",
                isActive: true,
                action: { cameraManager.toggleCamera() }
            )
        }

        Menu {
            Button(action: onLessons) {
                Label("Lessons & Students", systemImage: "books.vertical")
            }

            Button(action: onMathToolkit) {
                Label("Math Toolkit", systemImage: "function")
            }

            Button(action: onLayers) {
                Label("Answer Layers", systemImage: "square.3.layers.3d")
            }

            Button(action: onPageToggle) {
                Label(isPageSwitcherVisible ? "Hide Page Switcher" : "Show Page Switcher", systemImage: "rectangle.stack")
            }

            Button(action: onDocumentToggle) {
                Label(isDocumentBesideBoard ? "Hide Bottom Document" : "Document Below Board", systemImage: "rectangle.split.1x2")
            }

            Button {
                appState.showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                appState.showOnboarding = true
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }

            Divider()

            Button {
                cameraManager.toggleCamera()
            } label: {
                Label(cameraManager.isActive ? "Turn Camera Off" : "Turn Camera On", systemImage: cameraManager.isActive ? "video.slash" : "video")
            }

            Button(action: onExport) {
                Label("Export Image", systemImage: "square.and.arrow.down")
            }

            Button(action: onExportLesson) {
                Label("Export Lesson PDF", systemImage: "doc.richtext")
            }

            Divider()

            Button(role: .destructive, action: { showClearConfirm = true }) {
                Label("Clear Board", systemImage: "trash")
            }
        } label: {
            HeaderChromeGlyph(icon: "ellipsis", isActive: false)
        }
        .accessibilityLabel("More options")
        .accessibilityHint("Opens menu with settings, camera, export, and clear options")
    }
}

private struct PiPCameraButton: View {
    @ObservedObject var cameraManager: CameraManager

    var body: some View {
        HeaderChromeButton(
            icon: cameraManager.isPiPActive ? "pip.fill" : "pip",
            accessibilityLabel: "Picture in Picture camera",
            accessibilityValue: cameraManager.isPiPActive ? "On" : "Off",
            accessibilityHint: cameraManager.isPiPActive ? "Stops the floating camera window" : "Starts the camera in Picture in Picture",
            isActive: cameraManager.isPiPActive,
            action: { cameraManager.togglePiP() }
        )
    }
}

private struct GridStyleMenu: View {
    @Binding var gridStyle: GridStyle

    var body: some View {
        Menu {
            ForEach(GridStyle.allCases, id: \.self) { style in
                Button {
                    gridStyle = style
                } label: {
                    Label(style.title, systemImage: gridStyle == style ? "checkmark" : style.iconName)
                }
            }
        } label: {
            HeaderChromeGlyph(icon: gridStyle.isVisible ? gridStyle.iconName : "grid", isActive: gridStyle.isVisible)
        }
        .accessibilityLabel("Grid style")
        .accessibilityValue(gridStyle.title)
        .accessibilityHint("Opens grid style options")
    }
}

private struct HeaderChromeButton: View {
    let icon: String
    let accessibilityLabel: String
    let accessibilityValue: String?
    let accessibilityHint: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeaderChromeGlyph(icon: icon, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint(accessibilityHint)
    }
}

private struct HeaderChromeGlyph: View {
    let icon: String
    var isActive = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AppTheme.accentSoft : Color.primary.opacity(0.045))
                .frame(width: 38, height: 38)

            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? AppTheme.accent : .secondary)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
}

// MARK: - Offline Lesson Library
struct LessonLibraryView: View {
    @ObservedObject var store: LessonStore
    let onOpen: () -> Void
    let onTeach: () -> Void
    let onActiveLessonDeleted: () -> Void
    /// Runs after any lesson is deleted (once the board has moved on).
    var onLessonDeleted: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @State private var lessonPendingDelete: TutorLesson?
    @State private var selectedStudentId: UUID
    @State private var studentName = ""
    @State private var lessonTitle = ""
    @State private var homeworkTitle = ""
    @State private var localDocumentNames: [String] = []

    init(store: LessonStore, onOpen: @escaping () -> Void, onTeach: @escaping () -> Void, onActiveLessonDeleted: @escaping () -> Void, onLessonDeleted: @escaping () -> Void = { }) {
        self.onLessonDeleted = onLessonDeleted
        self.store = store
        self.onOpen = onOpen
        self.onTeach = onTeach
        self.onActiveLessonDeleted = onActiveLessonDeleted
        _selectedStudentId = State(initialValue: store.students.first?.id ?? UUID())
    }

    private var visibleLessons: [TutorLesson] {
        store.lessons.filter { $0.studentId == selectedStudentId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.students) { student in
                                Button(student.name) { selectedStudentId = student.id }
                                    .buttonStyle(.borderedProminent)
                                    .tint(selectedStudentId == student.id ? AppTheme.accent : Color.secondary.opacity(0.22))
                            }
                        }
                    }

                    HStack {
                        TextField("New student folder", text: $studentName).textFieldStyle(.roundedBorder)
                        Button {
                            guard !studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            let student = store.addStudent(name: studentName)
                            selectedStudentId = student.id
                            studentName = ""
                        } label: { Label("Student", systemImage: "person.badge.plus") }
                            .buttonStyle(.borderedProminent)
                    }

                    if let student = selectedStudent {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Student notes", systemImage: "note.text").font(.headline)
                            TextEditor(text: Binding(
                                get: { selectedStudent?.notes ?? "" },
                                set: { value in updateSelectedStudent { $0.notes = value } }
                            ))
                            .frame(minHeight: 82)
                            .padding(8)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                            Label("Homework", systemImage: "checklist").font(.headline)
                            HStack {
                                TextField("Add homework", text: $homeworkTitle).textFieldStyle(.roundedBorder)
                                Button("Add") {
                                    let title = homeworkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !title.isEmpty else { return }
                                    updateSelectedStudent { value in
                                        var items = value.homework ?? []
                                        items.append(HomeworkItem(id: UUID(), title: title, isComplete: false, createdAt: Date()))
                                        value.homework = items
                                    }
                                    homeworkTitle = ""
                                }.buttonStyle(.bordered)
                            }
                            ForEach(student.homework ?? []) { item in
                                Button {
                                    updateSelectedStudent { value in
                                        guard let index = value.homework?.firstIndex(where: { $0.id == item.id }) else { return }
                                        value.homework?[index].isComplete.toggle()
                                    }
                                } label: {
                                    Label(item.title, systemImage: item.isComplete ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.isComplete ? .secondary : .primary)
                                }.buttonStyle(.plain)
                            }

                            Label("Assigned documents", systemImage: "folder").font(.headline)
                            if localDocumentNames.isEmpty {
                                Text("Import PDFs or worksheets from the Docs tab, then assign them here.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(localDocumentNames, id: \.self) { name in
                                    Toggle(name, isOn: Binding(
                                        get: { selectedStudent?.documentNames?.contains(name) == true },
                                        set: { assigned in
                                            updateSelectedStudent { value in
                                                var names = value.documentNames ?? []
                                                if assigned && !names.contains(name) { names.append(name) }
                                                if !assigned { names.removeAll { $0 == name } }
                                                value.documentNames = names
                                            }
                                        }
                                    ))
                                }
                            }

                            Label("Lesson history", systemImage: "clock.arrow.circlepath").font(.headline)
                            if (student.lessonHistory ?? []).isEmpty {
                                Text("Finished Teach Mode sessions will appear here.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach((student.lessonHistory ?? []).prefix(8)) { item in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.lessonTitle).font(.subheadline.bold())
                                            Text(item.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let seconds = item.durationSeconds { Text("\(seconds / 60)m").font(.caption.monospacedDigit()) }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    }

                    HStack {
                        TextField("Lesson title", text: $lessonTitle).textFieldStyle(.roundedBorder)
                        Button {
                            guard !lessonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            _ = store.addLesson(studentId: selectedStudentId, title: lessonTitle)
                            lessonTitle = ""
                            onOpen(); dismiss()
                        } label: { Label("Lesson", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16))

                    if visibleLessons.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No Lessons").font(.headline)
                            Text("Create the first lesson for this student.").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleLessons) { lesson in
                                HStack(spacing: 12) {
                                    Button {
                                        store.openLesson(lesson.id); onOpen(); dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(lesson.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                                            Text("\(lesson.pages.count) \(lesson.pages.count == 1 ? "page" : "pages") · \(lesson.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)

                                    Button {
                                        store.openLesson(lesson.id); onTeach(); dismiss()
                                    } label: { Label("Teach", systemImage: "play.fill") }
                                        .buttonStyle(.borderedProminent)

                                    if store.lessons.count > 1 {
                                        Button(role: .destructive) { lessonPendingDelete = lesson } label: { Image(systemName: "trash") }
                                            .frame(width: 44, height: 44)
                                    }
                                }
                                .padding(14)
                                .background(lesson.id == store.activeLessonId ? AppTheme.accentSoft : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                }.padding()
            }
            .navigationTitle("Lessons")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .alert(
                "Delete Lesson?",
                isPresented: Binding(get: { lessonPendingDelete != nil }, set: { if !$0 { lessonPendingDelete = nil } }),
                presenting: lessonPendingDelete
            ) { lesson in
                Button("Delete", role: .destructive) { deleteLesson(lesson) }
                Button("Cancel", role: .cancel) { }
            } message: { lesson in
                Text("\u{201C}\(lesson.title)\u{201D} and its pages will be removed from this device. This can't be undone.")
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: loadLocalDocuments)
    }

    private func deleteLesson(_ lesson: TutorLesson) {
        let wasActive = lesson.id == store.activeLessonId
        store.deleteLesson(lesson.id)
        // The store has moved on to another lesson. The board must follow,
        // or the next stroke writes the deleted lesson's drawing into it.
        if wasActive { onActiveLessonDeleted() }
        onLessonDeleted()
    }

    private var selectedStudent: StudentFolder? {
        store.students.first(where: { $0.id == selectedStudentId })
    }

    private func updateSelectedStudent(_ update: (inout StudentFolder) -> Void) {
        guard var student = selectedStudent else { return }
        update(&student)
        store.updateStudent(student)
    }

    private func loadLocalDocuments() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ClapsBoard Documents", isDirectory: true)
        localDocumentNames = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - Answer Reveal Layers
private struct AnswerLayerControls: View {
    @ObservedObject var viewModel: CanvasViewModel
    let onPrepare: (AnswerLayer) -> Void
    let onRevealNext: () -> Void
    let onHideAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var screenDescription: String {
        if viewModel.visibleLayers.contains(.solution) { return "Question + hint + answer" }
        if viewModel.visibleLayers.contains(.hint) { return "Question + hint" }
        return "Question only"
    }

    private var hintCount: Int {
        viewModel.elements.filter { !$0.isDeleted && ($0.layer ?? .base) == .hint }.count
    }

    private var answerCount: Int {
        viewModel.elements.filter { !$0.isDeleted && ($0.layer ?? .base) == .solution }.count
    }

    private var nextTitle: String {
        if viewModel.visibleLayers.contains(.solution) { return "Hide prepared content" }
        if viewModel.visibleLayers.contains(.hint) { return answerCount > 0 ? "Reveal answer" : "Hide hint" }
        if hintCount > 0 { return "Reveal hint" }
        return "Reveal answer"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Currently on screen") {
                    Label(screenDescription, systemImage: "eye")
                        .font(.headline)

                    if hintCount > 0 || answerCount > 0 {
                        Button {
                            onRevealNext()
                            dismiss()
                        } label: {
                            Label(nextTitle, systemImage: viewModel.visibleLayers.contains(.solution) ? "eye.slash" : "eye")
                                .font(.headline)
                        }
                    }

                    if viewModel.visibleLayers.contains(.hint) && !viewModel.visibleLayers.contains(.solution) {
                        Button {
                            onHideAll()
                            dismiss()
                        } label: {
                            Label("Hide prepared content", systemImage: "eye.slash")
                        }
                    }
                }

                Section {
                    Text("Prepare before sharing your screen. The selected content is visible while you edit; tap Done & Hide on the board when finished.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    preparationButton(.hint, title: hintCount > 0 ? "Edit hint" : "Prepare hint", count: hintCount)
                    preparationButton(.solution, title: answerCount > 0 ? "Edit answer" : "Prepare answer", count: answerCount)
                } header: {
                    Text("Prepare this page")
                }
            }
            .navigationTitle("Prepared Answer")
        }
    }

    private func preparationButton(_ layer: AnswerLayer, title: String, count: Int) -> some View {
        Button {
            onPrepare(layer)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: layer.iconName)
                    .foregroundStyle(layer == .hint ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text("\(count) items on this page").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Document Beside Board
private struct BoardDocumentPanel: View {
    let resizeVersion: Int
    let onClose: () -> Void
    @State private var files: [URL] = []
    @State private var selectedURL: URL?
    @State private var pdfPage = 1
    @State private var pdfPageCount = 0
    @State private var fitRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        if files.isEmpty { Text("Import documents from the Docs tab") }
                        ForEach(files, id: \.self) { file in Button(file.lastPathComponent) { selectedURL = file } }
                    } label: {
                        Label(selectedURL?.lastPathComponent ?? "Choose document", systemImage: "doc")
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)

                if selectedURL != nil {
                    HStack(spacing: 6) {
                        if selectedURL?.pathExtension.lowercased() == "pdf" {
                            Button { pdfPage = max(1, pdfPage - 1) } label: {
                                Image(systemName: "chevron.left").frame(width: 36, height: 36)
                            }
                            .disabled(pdfPage <= 1)

                            Text("\(pdfPage) / \(max(pdfPageCount, 1))")
                                .font(.caption.bold().monospacedDigit())
                                .frame(minWidth: 56)

                            Button { pdfPage = min(max(pdfPageCount, 1), pdfPage + 1) } label: {
                                Image(systemName: "chevron.right").frame(width: 36, height: 36)
                            }
                            .disabled(pdfPage >= pdfPageCount)
                        }

                        Spacer()
                        Text("Pinch to zoom")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button { fitRequest += 1 } label: {
                            Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(AppTheme.accent, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 42)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .background(.ultraThinMaterial)

            Group {
                if let url = selectedURL, url.pathExtension.lowercased() == "pdf" {
                    EmbeddedPDFView(url: url, page: $pdfPage, pageCount: $pdfPageCount, fitRequest: fitRequest)
                } else if let url = selectedURL, let image = UIImage(contentsOfFile: url.path) {
                    ZoomableDocumentImage(image: image, fitRequest: fitRequest)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No document selected").font(.headline)
                        Text("Choose a local PDF or image above.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .onAppear(perform: loadFiles)
        .onChange(of: selectedURL) {
            pdfPage = 1
            pdfPageCount = 0
            fitRequest += 1
        }
        .onChange(of: resizeVersion) { fitRequest += 1 }
    }

    private func loadFiles() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ClapsBoard Documents", isDirectory: true)
        files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["pdf", "png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if selectedURL == nil { selectedURL = files.first }
    }
}

private struct EmbeddedPDFView: UIViewRepresentable {
    let url: URL
    @Binding var page: Int
    @Binding var pageCount: Int
    let fitRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = .secondarySystemBackground
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = false
        view.document = PDFDocument(url: url)
        view.maxScaleFactor = 6
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        context.coordinator.pdfView = view
        updatePageCount(view.document)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            page = 1
            updatePageCount(view.document)
            view.autoScales = false
            let fitScale = max(view.scaleFactorForSizeToFit, 0.1)
            view.scaleFactor = fitScale
        }
        if let document = view.document,
           let current = view.currentPage,
           document.index(for: current) + 1 != page,
           let destination = document.page(at: max(0, min(page - 1, document.pageCount - 1))) {
            view.go(to: destination)
        }
        if context.coordinator.lastFitRequest != fitRequest {
            context.coordinator.lastFitRequest = fitRequest
            view.autoScales = false
            view.scaleFactor = max(view.scaleFactorForSizeToFit, 0.1)
        }
        let fitScale = max(view.scaleFactorForSizeToFit, 0.1)
        view.minScaleFactor = fitScale * 0.5
        view.maxScaleFactor = max(6, fitScale * 6)
    }

    private func updatePageCount(_ document: PDFDocument?) {
        let count = document?.pageCount ?? 0
        DispatchQueue.main.async { pageCount = count }
    }

    final class Coordinator: NSObject {
        var parent: EmbeddedPDFView
        weak var pdfView: PDFView?
        var lastFitRequest = -1

        init(_ parent: EmbeddedPDFView) { self.parent = parent }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let document = view.document,
                  let current = view.currentPage else { return }
            let nextPage = document.index(for: current) + 1
            DispatchQueue.main.async { self.parent.page = nextPage }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private struct ZoomableDocumentImage: UIViewRepresentable {
    let image: UIImage
    let fitRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .secondarySystemBackground

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        if context.coordinator.lastFitRequest != fitRequest {
            context.coordinator.lastFitRequest = fitRequest
            scrollView.setZoomScale(1, animated: true)
            scrollView.setContentOffset(.zero, animated: true)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var lastFitRequest = -1
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // Exclude activity types that can cause issues in simulator
        controller.excludedActivityTypes = [
            .addToReadingList,
            .openInIBooks
        ]

        // Handle completion to dismiss the sheet
        controller.completionWithItemsHandler = { _, completed, _, error in
            if let error = error {
                print("⚠️ Share activity error: \(error.localizedDescription)")
            }
            // Dismiss the sheet after activity completes or is cancelled
            DispatchQueue.main.async {
                context.coordinator.dismiss()
            }
        }

        return controller
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed - sheet is modal
    }

    class Coordinator: NSObject {
        @MainActor func dismiss() {
            // Find and dismiss the presenting view controller
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else { return }
            rootVC.dismiss(animated: true)
        }
    }
}

// MARK: - Preview
#Preview {
    BoardView(viewModel: CanvasViewModel(), cameraManager: CameraManager(), lessonStore: LessonStore())
        .environmentObject(AppState())
}
