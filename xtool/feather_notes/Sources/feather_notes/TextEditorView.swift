import SwiftUI

struct TextEditorView: View {
    let noteId: Int
    @State private var textContent: String = ""
    @State private var previewMode: Bool = false
    @State private var debounceTimer: Timer?
    @FocusState private var isFocused: Bool
    
    @Environment(\.colorScheme) var colorScheme
    
    init(noteId: Int, initialPreviewMode: Bool = false) {
        self.noteId = noteId
        _previewMode = State(initialValue: initialPreviewMode)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Main content area
                VStack(spacing: 0) {
                    if previewMode {
                        // Preview mode - show rendered Markdown
                        ScrollView {
                            Text(markdownToAttributedString(textContent))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    } else {
                        // Edit mode - show text editor
                        TextEditor(text: $textContent)
                            .font(.body)
                            .padding(.horizontal, 8)
                            .focused($isFocused)
                            .onChange(of: textContent) { _, newValue in
                                debounceSave(newValue)
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Toggle button
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            previewMode.toggle()
                        }) {
                            Image(systemName: previewMode ? "pencil" : "eye")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .padding()
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Circle())
                        }
                        .padding()
                    }
                    Spacer()
                }
            }
        }
        .navigationTitle(noteTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadTextContent()
            if !previewMode {
                isFocused = true
            }
        }
    }
    
    private var noteTitle: String {
        DatabaseHelper.shared.getNote(id: noteId)?.title ?? "Note"
    }
    
    private func loadTextContent() {
        if let content = DatabaseHelper.shared.getTextContent(noteId: noteId) {
            textContent = content
            // If note has content, default to preview mode
            if !content.isEmpty {
                previewMode = true
            }
        }
    }
    
    private func debounceSave(_ text: String) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            DatabaseHelper.shared.saveTextContent(noteId: noteId, textContent: text)
        }
    }
}

// Helper function to convert Markdown to AttributedString
private func markdownToAttributedString(_ markdown: String) -> AttributedString {
    do {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return try AttributedString(markdown: markdown, options: options)
    } catch {
        // Fallback to plain text if parsing fails
        return AttributedString(markdown)
    }
}

