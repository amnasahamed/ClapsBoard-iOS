//
//  DocumentsView.swift
//  ClapsBoard
//
//  Document viewer for PDFs and other documents with native iOS import features
//

import SwiftUI
import PDFKit
import QuickLook
import UniformTypeIdentifiers
import PhotosUI
import AVFoundation

// MARK: - Thumbnail Cache Manager

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: UIImage] = [:]
    
    func thumbnail(for url: URL, generator: @escaping () -> UIImage?) -> UIImage? {
        if let cached = cache[url] {
            return cached
        }
        
        if let generated = generator() {
            cache[url] = generated
            return generated
        }
        
        return nil
    }
    
    func removeThumbnail(for url: URL) {
        cache[url] = nil
    }

    func clearCache() {
        cache.removeAll()
    }
}

/// Document viewer for PDFs and other documents (HIG: Empty States, Accessibility)
struct DocumentsView: View {
    @EnvironmentObject var appState: AppState

    @State private var documents: [DocumentItem] = []
    @State private var selectedDocument: DocumentItem?
    @State private var showDocumentPicker = false
    @State private var previewItem: PreviewItem?
    @State private var showImportOptions = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    // Check if camera is available on this device
    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AppModeMenu(selectedTab: $appState.selectedTab)

                Spacer()

                Button(action: { showImportOptions = true }) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.accentSoft)
                            .frame(width: 38, height: 38)

                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .accessibilityLabel("Import document")
                .accessibilityHint("Opens options to import documents")
            }
            .shadow(color: .black.opacity(0.04), radius: 16, y: 6)
            .padding(.horizontal, 28)
            .padding(.top, 8)

            // Content
            ZStack {
                ScrollView {
                    if documents.isEmpty {
                        VStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(.regularMaterial)
                                    .frame(width: 68, height: 68)

                                Image(systemName: "doc.text")
                                    .font(.system(size: 26, weight: .regular))
                                    .foregroundStyle(AppTheme.accent.opacity(0.78))
                            }

                            VStack(spacing: 5) {
                                Text("No documents yet")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)

                                Text("Tap + to import a file")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.top, 76)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity)
                    } else {
                        // Document Grid
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 16),
                            GridItem(.flexible(), spacing: 16)
                        ], spacing: 16) {
                            ForEach(documents) { document in
                                DocumentCard(document: document) {
                                    openDocument(document)
                                } onDelete: {
                                    deleteDocument(document)
                                } onShare: {
                                    shareDocument(document)
                                }
                            }
                        }
                        .padding(20)
                    }
                }
                .padding(.bottom, 28)
                
                // Processing Overlay
                if isProcessing {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        
                        Text("Importing...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .padding(32)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .confirmationDialog("Import Document", isPresented: $showImportOptions, titleVisibility: .visible) {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            
            // Only show camera option if camera is available
            if isCameraAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            
            Button {
                showDocumentPicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose where to import from")
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { urls in
                importDocuments(urls)
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 20,
            matching: .any(of: [.images, .livePhotos]),
            photoLibrary: .shared()
        )
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker { image in
                importCameraImage(image)
            }
        }
        .fullScreenCover(item: $previewItem) { item in
            QuickLookPreview(url: item.url) {
                previewItem = nil
            }
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhotoItems) { newItems in
            if !newItems.isEmpty {
                importPhotos(newItems)
                selectedPhotoItems = []
            }
        }
        .onAppear {
            loadDocuments()
        }
        .alert("Import Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        // Drop support for drag and drop
        .onDrop(of: [.image, .pdf, .data], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    // MARK: - Document Opening

    /// Opens a document in the QuickLook preview, guarding against stale/missing files
    /// (previously an unguarded preview of a missing file could crash the app).
    private func openDocument(_ document: DocumentItem) {
        guard FileManager.default.fileExists(atPath: document.url.path),
              FileManager.default.isReadableFile(atPath: document.url.path) else {
            errorMessage = "\"\(document.name)\" could not be opened. The file may have been moved or deleted."
            showError = true
            loadDocuments() // Refresh the grid to drop stale entries
            return
        }

        previewItem = PreviewItem(url: document.url)
    }

    // MARK: - Document Loading

    private func loadDocuments() {
        let fileManager = FileManager.default
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        // Create ClapsBoard Documents subfolder if needed
        let clapsboardDocsPath = documentsPath.appendingPathComponent("ClapsBoard Documents", isDirectory: true)
        if !fileManager.fileExists(atPath: clapsboardDocsPath.path) {
            try? fileManager.createDirectory(at: clapsboardDocsPath, withIntermediateDirectories: true)
        }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: clapsboardDocsPath, includingPropertiesForKeys: [.nameKey, .creationDateKey, .contentModificationDateKey])
            documents = files.compactMap { url in
                let ext = url.pathExtension.lowercased()
                guard ["pdf", "docx", "pptx", "xlsx", "txt", "jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) else { return nil }
                return DocumentItem(
                    id: UUID(),
                    name: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    type: DocumentType(from: url.pathExtension),
                    dateAdded: (try? fileManager.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
                )
            }.sorted { $0.dateAdded > $1.dateAdded }
        } catch {
            print("Error loading documents: \(error)")
        }
    }
    
    // MARK: - Document Import
    
    private func importDocuments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        
        isProcessing = true
        print("📄 Starting import of \(urls.count) document(s)")
        
        Task {
            let fileManager = FileManager.default
            guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                print("❌ Could not access documents directory")
                await MainActor.run { isProcessing = false }
                return
            }
            
            let clapsboardDocsPath = documentsPath.appendingPathComponent("ClapsBoard Documents", isDirectory: true)
            
            // Ensure directory exists
            if !fileManager.fileExists(atPath: clapsboardDocsPath.path) {
                try? fileManager.createDirectory(at: clapsboardDocsPath, withIntermediateDirectories: true)
            }
            
            var successCount = 0
            
            for url in urls {
                // With asCopy: true, files are already copied to a temporary location
                // Security-scoped access may still be needed for some sources
                let needsSecurityAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if needsSecurityAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                // Generate unique filename if file already exists
                var destinationURL = clapsboardDocsPath.appendingPathComponent(url.lastPathComponent)
                var counter = 1
                let baseName = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                
                while fileManager.fileExists(atPath: destinationURL.path) {
                    let newName = "\(baseName)_\(counter).\(ext)"
                    destinationURL = clapsboardDocsPath.appendingPathComponent(newName)
                    counter += 1
                }
                
                do {
                    try fileManager.copyItem(at: url, to: destinationURL)
                    print("✅ Imported: \(url.lastPathComponent)")
                    
                    let document = DocumentItem(
                        id: UUID(),
                        name: destinationURL.deletingPathExtension().lastPathComponent,
                        url: destinationURL,
                        type: DocumentType(from: url.pathExtension),
                        dateAdded: Date()
                    )
                    
                    await MainActor.run {
                        documents.insert(document, at: 0)
                    }
                    successCount += 1
                } catch {
                    print("❌ Error importing \(url.lastPathComponent): \(error.localizedDescription)")
                    await MainActor.run {
                        errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                        showError = true
                    }
                }
            }
            
            print("📄 Import complete: \(successCount)/\(urls.count) successful")
            
            await MainActor.run {
                isProcessing = false
            }
        }
    }
    
    // MARK: - Photo Import
    
    private func importPhotos(_ items: [PhotosPickerItem]) {
        isProcessing = true

        Task {
            let clapsboardDocsPath = documentsDirectory

            for item in items {
                do {
                    // Try to load as Data first to preserve original format
                    if let data = try await item.loadTransferable(type: Data.self) {
                        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                        
                        // Determine file extension from content type
                        var fileExtension = "jpg"
                        if let contentType = item.supportedContentTypes.first {
                            if contentType.conforms(to: .png) {
                                fileExtension = "png"
                            } else if contentType.conforms(to: .heic) {
                                fileExtension = "heic"
                            } else if contentType.conforms(to: .gif) {
                                fileExtension = "gif"
                            } else if contentType.conforms(to: .webP) {
                                fileExtension = "webp"
                            }
                        }
                        
                        let fileName = "Photo_\(timestamp).\(fileExtension)"
                        let destinationURL = clapsboardDocsPath.appendingPathComponent(fileName)
                        
                        try data.write(to: destinationURL)
                        
                        let document = DocumentItem(
                            id: UUID(),
                            name: "Photo_\(timestamp)",
                            url: destinationURL,
                            type: .image,
                            dateAdded: Date()
                        )
                        
                        await MainActor.run {
                            documents.insert(document, at: 0)
                        }
                    }
                } catch {
                    print("Error importing photo: \(error)")
                    await MainActor.run {
                        errorMessage = "Failed to import photo: \(error.localizedDescription)"
                        showError = true
                    }
                }
            }
            
            await MainActor.run {
                isProcessing = false
            }
        }
    }
    
    // MARK: - Camera Import
    
    private func importCameraImage(_ image: UIImage) {
        isProcessing = true

        Task {
            let clapsboardDocsPath = documentsDirectory

            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let fileName = "Camera_\(timestamp).jpg"
            let destinationURL = clapsboardDocsPath.appendingPathComponent(fileName)
            
            do {
                if let imageData = image.jpegData(compressionQuality: 0.9) {
                    try imageData.write(to: destinationURL)
                    
                    let document = DocumentItem(
                        id: UUID(),
                        name: "Camera_\(timestamp)",
                        url: destinationURL,
                        type: .image,
                        dateAdded: Date()
                    )
                    
                    await MainActor.run {
                        documents.insert(document, at: 0)
                    }
                }
            } catch {
                print("Error saving camera image: \(error)")
                await MainActor.run {
                    errorMessage = "Failed to save photo: \(error.localizedDescription)"
                    showError = true
                }
            }
            
            await MainActor.run {
                isProcessing = false
            }
        }
    }
    
    // MARK: - Drag and Drop

    private func handleDrop(providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isProcessing = true

        Task {
            var newDocuments: [DocumentItem] = []

            for provider in providers {
                // Handle images
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let document = await loadImageDocument(provider: provider) {
                        newDocuments.append(document)
                    }
                }
                // Handle PDFs
                else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    if let document = await loadPDFDocument(provider: provider) {
                        newDocuments.append(document)
                    }
                }
            }

            // Update UI on main thread
            await MainActor.run {
                documents.insert(contentsOf: newDocuments, at: 0)
                isProcessing = false
            }
        }
    }

    private func loadImageDocument(provider: NSItemProvider) async -> DocumentItem? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                guard let data = data, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let fileName = "Dropped_\(timestamp).jpg"
                let destinationURL = self.documentsDirectory.appendingPathComponent(fileName)

                do {
                    try data.write(to: destinationURL)
                    let document = DocumentItem(
                        id: UUID(),
                        name: "Dropped_\(timestamp)",
                        url: destinationURL,
                        type: .image,
                        dateAdded: Date()
                    )
                    continuation.resume(returning: document)
                } catch {
                    print("Error saving dropped image: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadPDFDocument(provider: NSItemProvider) async -> DocumentItem? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
                guard let data = data, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let fileName = "Dropped_\(timestamp).pdf"
                let destinationURL = self.documentsDirectory.appendingPathComponent(fileName)

                do {
                    try data.write(to: destinationURL)
                    let document = DocumentItem(
                        id: UUID(),
                        name: "Dropped_\(timestamp)",
                        url: destinationURL,
                        type: .pdf,
                        dateAdded: Date()
                    )
                    continuation.resume(returning: document)
                } catch {
                    print("Error saving dropped PDF: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Returns the app's documents folder, creating it if needed so writes never
    /// fail because the folder is missing (e.g. photo import before first load).
    private var documentsDirectory: URL {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = documentsPath.appendingPathComponent("ClapsBoard Documents", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
    
    // MARK: - Document Actions
    
    private func deleteDocument(_ document: DocumentItem) {
        do {
            try FileManager.default.removeItem(at: document.url)
            documents.removeAll { $0.id == document.id }
            // Drop the cached thumbnail so a future file at the same path
            // doesn't show a stale preview
            Task { await ThumbnailCache.shared.removeThumbnail(for: document.url) }
        } catch {
            print("Error deleting document: \(error)")
            errorMessage = "Failed to delete document: \(error.localizedDescription)"
            showError = true
        }
    }
    
    private func shareDocument(_ document: DocumentItem) {
        guard FileManager.default.fileExists(atPath: document.url.path) else {
            errorMessage = "\"\(document.name)\" could not be shared. The file may have been moved or deleted."
            showError = true
            loadDocuments()
            return
        }

        let activityVC = UIActivityViewController(activityItems: [document.url], applicationActivities: nil)

        // Find the active foreground scene's key window (the previous lookup used
        // the *first* connected scene, which may not be the visible one).
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
              let rootVC = window.rootViewController else { return }

        // Walk to the top-most presented controller so presenting never fails
        // with "already presenting" (a crash/no-op source when a dialog is up).
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        // For iPad popover anchoring
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(activityVC, animated: true)
    }
}

// MARK: - Preview Item

struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - QuickLook Preview
/// Stable QLPreviewController wrapper.
/// Replaces the `.quickLookPreview` modifier, which is crash-prone on iOS 16
/// (the app's deployment target) when presented from lazy/hidden view hierarchies.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismissPreview)
        )

        let navigation = UINavigationController(rootViewController: preview)
        navigation.modalPresentationStyle = .fullScreen
        return navigation
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var parent: QuickLookPreview

        init(parent: QuickLookPreview) {
            self.parent = parent
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            parent.url as NSURL
        }

        // Disable markup/editing: editing writes back to the file and was a
        // source of instability; viewing is all teachers need here.
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .disabled
        }

        @objc func dismissPreview() {
            parent.onDismiss()
        }
    }
}

// MARK: - Document Item

struct DocumentItem: Identifiable {
    let id: UUID
    let name: String
    let url: URL
    let type: DocumentType
    let dateAdded: Date
}

enum DocumentType {
    case pdf, word, powerpoint, excel, text, image, other
    
    init(from extension: String) {
        switch `extension`.lowercased() {
        case "pdf": self = .pdf
        case "doc", "docx": self = .word
        case "ppt", "pptx": self = .powerpoint
        case "xls", "xlsx": self = .excel
        case "txt", "rtf": self = .text
        case "jpg", "jpeg", "png", "heic", "gif", "webp": self = .image
        default: self = .other
        }
    }
    
    var iconName: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .powerpoint: return "rectangle.stack"
        case .excel: return "tablecells"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        case .other: return "doc"
        }
    }
    
    var color: Color {
        switch self {
        case .pdf: return .red
        case .word: return .blue
        case .powerpoint: return .orange
        case .excel: return .green
        case .text: return .gray
        case .image: return .purple
        case .other: return .secondary
        }
    }
}

// MARK: - Document Card with Thumbnail

struct DocumentCard: View {
    let document: DocumentItem
    let onTap: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void
    
    @State private var showDeleteConfirm = false
    @State private var thumbnail: UIImage?
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                // Thumbnail or Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                        .frame(height: 100)
                    
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: document.type.iconName)
                            .font(.system(size: 40))
                            .foregroundStyle(document.type.color)
                    }
                    
                    // Type Badge
                    VStack {
                        HStack {
                            Spacer()
                            Text(document.url.pathExtension.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(document.type.color.opacity(0.9))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        }
                        Spacer()
                    }
                }
                
                // Name
                Text(document.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                
                // Date
                Text(document.dateAdded, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
            )
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Open", systemImage: "eye")
            }
            
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Divider()
            
            Button(role: .destructive, action: { showDeleteConfirm = true }) {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete Document?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("This action cannot be undone.")
        }
        .task {
            // Load thumbnail asynchronously
            if thumbnail == nil && (document.type == .pdf || document.type == .image) {
                await loadThumbnail()
            }
        }
    }
    
    private func loadThumbnail() async {
        let documentURL = document.url
        let documentType = document.type
        
        let thumb = await ThumbnailCache.shared.thumbnail(for: documentURL) {
            switch documentType {
            case .pdf:
                return generatePDFThumbnail(for: documentURL)
            case .image:
                return generateImageThumbnail(for: documentURL)
            default:
                return nil
            }
        }
        
        await MainActor.run {
            thumbnail = thumb
        }
    }
    
    private func generatePDFThumbnail(for url: URL) -> UIImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 150 / max(pageRect.width, pageRect.height)
        let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        return page.thumbnail(of: scaledSize, for: .mediaBox)
    }
    
    private func generateImageThumbnail(for url: URL) -> UIImage? {
        guard let imageData = try? Data(contentsOf: url),
              let image = UIImage(data: imageData) else { return nil }
        
        let maxSize: CGFloat = 150
        let scale = min(maxSize / image.size.width, maxSize / image.size.height)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .pdf,
            .presentation,
            .spreadsheet,
            .plainText,
            .rtf,
            .image,
            .jpeg,
            .png,
            .heic,
            .gif,
            .webP
        ]
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        
        // Reduce modal presentation animation issues
        picker.modalPresentationStyle = .formSheet
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        
        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Filter out any invalid URLs
            let validURLs = urls.filter { url in
                // Check if file exists and is readable
                return FileManager.default.isReadableFile(atPath: url.path)
            }
            
            if !validURLs.isEmpty {
                onPick(validURLs)
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // User cancelled - no action needed
            print("📄 Document picker cancelled by user")
        }
    }
}

// MARK: - Camera Image Picker

struct CameraImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    let onCapture: (UIImage) -> Void
    
    func makeUIViewController(context: Context) -> UIViewController {
        // Check if camera is available
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // Return empty controller if camera not available (will be dismissed)
            let controller = UIViewController()
            DispatchQueue.main.async {
                self.dismiss()
            }
            return controller
        }
        
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        picker.cameraDevice = .rear
        picker.cameraCaptureMode = .photo
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraImagePicker
        
        init(parent: CameraImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    DocumentsView()
        .environmentObject(AppState())
}
