//
//  DocumentsView.swift
//  ClapsBoard
//
//  Document viewer for PDFs and other documents
//

import SwiftUI
import PDFKit
import QuickLook
import UniformTypeIdentifiers

/// Document viewer for PDFs and other documents (HIG: Empty States, Accessibility)
struct DocumentsView: View {
    @State private var documents: [DocumentItem] = []
    @State private var selectedDocument: DocumentItem?
    @State private var showDocumentPicker = false
    @State private var showingPreview = false
    @State private var previewURL: URL?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                HStack {
                    Text("Documents")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    
                    Spacer()
                    
                    // Import Button
                    Button(action: { showDocumentPicker = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Circle()
                            )
                            .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)
                    }
                    .accessibilityLabel("Import document")
                    .accessibilityHint("Opens file picker to import documents")
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
            }
            .background(Color(.systemBackground))
            
            // Content
            ScrollView {
                if documents.isEmpty {
                    // Empty State
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                        
                        Text("No Documents")
                            .font(.title2.weight(.semibold))
                        
                        Text("Import PDFs and documents to view while teaching")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: { showDocumentPicker = true }) {
                            Label("Import Document", systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(.blue, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 8)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity)
                } else {
                    // Document Grid
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ], spacing: 16) {
                        ForEach(documents) { document in
                            DocumentCard(document: document) {
                                previewURL = document.url
                                showingPreview = true
                            } onDelete: {
                                deleteDocument(document)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .padding(.bottom, 100)
        }
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { urls in
                importDocuments(urls)
            }
        }
        .quickLookPreview($previewURL)
        .onAppear {
            loadDocuments()
        }
    }
    
    private func loadDocuments() {
        // Load saved document references
        let fileManager = FileManager.default
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.nameKey, .creationDateKey])
            documents = files.compactMap { url in
                let ext = url.pathExtension.lowercased()
                guard ["pdf", "docx", "pptx", "xlsx", "txt", "jpg", "jpeg", "png", "heic"].contains(ext) else { return nil }
                return DocumentItem(
                    id: UUID(),
                    name: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    type: DocumentType(from: url.pathExtension)
                )
            }
        } catch {
            print("Error loading documents: \(error)")
        }
    }
    
    private func importDocuments(_ urls: [URL]) {
        let fileManager = FileManager.default
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            
            let destinationURL = documentsPath.appendingPathComponent(url.lastPathComponent)
            
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: url, to: destinationURL)
                
                let document = DocumentItem(
                    id: UUID(),
                    name: url.deletingPathExtension().lastPathComponent,
                    url: destinationURL,
                    type: DocumentType(from: url.pathExtension)
                )
                documents.append(document)
            } catch {
                print("Error importing document: \(error)")
            }
        }
    }
    
    private func deleteDocument(_ document: DocumentItem) {
        do {
            try FileManager.default.removeItem(at: document.url)
            documents.removeAll { $0.id == document.id }
        } catch {
            print("Error deleting document: \(error)")
        }
    }
}

// MARK: - Document Item
struct DocumentItem: Identifiable {
    let id: UUID
    let name: String
    let url: URL
    let type: DocumentType
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
        case "jpg", "jpeg", "png", "heic": self = .image
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

// MARK: - Document Card
struct DocumentCard: View {
    let document: DocumentItem
    let onTap: () -> Void
    let onDelete: () -> Void
    
    @State private var showDeleteConfirm = false
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                // Icon
                Image(systemName: document.type.iconName)
                    .font(.system(size: 40))
                    .foregroundStyle(document.type.color)
                    .frame(height: 60)
                
                // Name
                Text(document.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Open", systemImage: "eye")
            }
            
            Button(role: .destructive, action: { showDeleteConfirm = true }) {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete Document?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Document Picker
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [.pdf, .presentation, .spreadsheet, .plainText, .rtf, .image]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
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
            onPick(urls)
        }
    }
}

// MARK: - Preview
#Preview {
    DocumentsView()
}
