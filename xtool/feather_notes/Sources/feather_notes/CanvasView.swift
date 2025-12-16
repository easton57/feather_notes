import SwiftUI

struct CanvasView: View {
    let noteId: Int
    @State private var canvasData: NoteCanvasData
    @State private var currentStroke: [DrawingPoint] = []
    @State private var isDrawing = false
    @State private var selectedColor: StrokeColor = .black
    @State private var penSize: Double = 2.0
    @State private var isTextMode = false
    @State private var showingColorPicker = false
    @State private var showingTagEditor = false
    @State private var fontSize: Double = 16.0
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var undoStack: [NoteCanvasData] = []
    @State private var redoStack: [NoteCanvasData] = []
    @State private var showingTextInput = false
    @State private var textInputPosition: CGPoint = .zero
    @State private var textInputText: String = ""
    
    @Environment(\.colorScheme) var colorScheme
    
    init(noteId: Int) {
        self.noteId = noteId
        // Check if note is text-only - if so, use empty canvas data
        let note = DatabaseHelper.shared.getNote(id: noteId)
        if note?.isTextOnly == true {
            _canvasData = State(initialValue: NoteCanvasData())
            _scale = State(initialValue: 1.0)
            _offset = State(initialValue: .zero)
            _lastOffset = State(initialValue: .zero)
        } else {
            let loadedData = DatabaseHelper.shared.loadCanvasData(noteId: noteId)
            _canvasData = State(initialValue: loadedData)
            _scale = State(initialValue: CGFloat(loadedData.scale))
            let transform = loadedData.matrix.cgAffineTransform
            _offset = State(initialValue: CGSize(width: transform.tx, height: transform.ty))
            _lastOffset = State(initialValue: CGSize(width: transform.tx, height: transform.ty))
        }
        _selectedColor = State(initialValue: .black) // Will be updated in onAppear based on colorScheme
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Canvas background
                Color(colorScheme == .dark ? UIColor.systemBackground : UIColor.white)
                    .ignoresSafeArea()
                
                // Canvas content
                Canvas { context, size in
                    // Apply transformations
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: offset.width / scale, y: offset.height / scale)
                    
                    // Draw strokes
                    for stroke in canvasData.strokes {
                        if stroke.points.count > 1 {
                            var path = Path()
                            path.move(to: stroke.points[0].cgPoint)
                            
                            for i in 1..<stroke.points.count {
                                path.addLine(to: stroke.points[i].cgPoint)
                            }
                            
                            context.stroke(
                                path,
                                with: .color(stroke.color.uiColor),
                                lineWidth: stroke.penSize
                            )
                        }
                    }
                    
                    // Draw text elements
                    for textElement in canvasData.textElements {
                        context.draw(
                            Text(textElement.text)
                                .font(.system(size: textElement.fontSize))
                                .foregroundColor(.primary),
                            at: textElement.cgPoint
                        )
                    }
                    
                    // Draw current stroke
                    if !currentStroke.isEmpty && currentStroke.count > 1 {
                        var path = Path()
                        path.move(to: currentStroke[0].cgPoint)
                        for i in 1..<currentStroke.count {
                            path.addLine(to: currentStroke[i].cgPoint)
                        }
                        context.stroke(
                            path,
                            with: .color(selectedColor.uiColor),
                            lineWidth: penSize
                        )
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if isTextMode {
                                // In text mode, show text input at tap location
                                if !showingTextInput {
                                    textInputPosition = CGPoint(
                                        x: (value.location.x - offset.width) / scale,
                                        y: (value.location.y - offset.height) / scale
                                    )
                                    showingTextInput = true
                                    textInputText = ""
                                }
                            } else {
                                // Drawing mode
                                let point = DrawingPoint(
                                    x: (value.location.x - offset.width) / scale,
                                    y: (value.location.y - offset.height) / scale,
                                    pressure: 0.5
                                )
                                
                                if !isDrawing {
                                    isDrawing = true
                                    saveState()
                                    currentStroke = [point]
                                } else {
                                    currentStroke.append(point)
                                }
                            }
                        }
                        .onEnded { _ in
                            if !isTextMode && !currentStroke.isEmpty {
                                let stroke = Stroke(points: currentStroke, color: selectedColor, penSize: penSize)
                                canvasData.strokes.append(stroke)
                                currentStroke = []
                                isDrawing = false
                                saveCanvasData()
                            }
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(0.1, min(5.0, value))
                        }
                        .onEnded { _ in
                            canvasData.scale = Double(scale)
                            saveCanvasData()
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDrawing && !isTextMode {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { _ in
                            lastOffset = offset
                            updateMatrix()
                            saveCanvasData()
                        }
                )
                
                // Text input overlay
                if showingTextInput {
                    VStack {
                        HStack {
                            TextField("Enter text", text: $textInputText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: fontSize))
                            Button("Done") {
                                if !textInputText.isEmpty {
                                    let textElement = TextElement(
                                        position: DrawingPoint(textInputPosition),
                                        text: textInputText,
                                        fontSize: fontSize
                                    )
                                    saveState()
                                    canvasData.textElements.append(textElement)
                                    saveCanvasData()
                                }
                                showingTextInput = false
                                textInputText = ""
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                        .padding()
                        Spacer()
                    }
                }
                
                // Toolbar
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            // Undo
                            Button(action: undo) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.title2)
                                    .foregroundColor(.primary)
                                    .padding()
                                    .background(Color.secondary.opacity(0.2))
                                    .clipShape(Circle())
                            }
                            .disabled(undoStack.isEmpty)
                            
                            // Redo
                            Button(action: redo) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.title2)
                                    .foregroundColor(.primary)
                                    .padding()
                                    .background(Color.secondary.opacity(0.2))
                                    .clipShape(Circle())
                            }
                            .disabled(redoStack.isEmpty)
                            
                            // Text mode toggle
                            Button(action: {
                                isTextMode.toggle()
                                showingTextInput = false
                            }) {
                                Image(systemName: isTextMode ? "text.cursor" : "pencil")
                                    .font(.title2)
                                    .foregroundColor(isTextMode ? .blue : .primary)
                                    .padding()
                                    .background(Color.secondary.opacity(0.2))
                                    .clipShape(Circle())
                            }
                            
                            // Font size adjuster (only show in text mode)
                            if isTextMode {
                                VStack(spacing: 4) {
                                    Button(action: {
                                        fontSize = min(48, fontSize + 2)
                                    }) {
                                        Image(systemName: "plus")
                                            .font(.caption)
                                    }
                                    Text("\(Int(fontSize))")
                                        .font(.caption2)
                                    Button(action: {
                                        fontSize = max(8, fontSize - 2)
                                    }) {
                                        Image(systemName: "minus")
                                            .font(.caption)
                                    }
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(8)
                            }
                            
                            // Color picker
                            Button(action: {
                                showingColorPicker.toggle()
                            }) {
                                Circle()
                                    .fill(selectedColor.uiColor)
                                    .frame(width: 40, height: 40)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary, lineWidth: 2)
                                    )
                            }
                            
                            // Tag editor
                            Button(action: {
                                showingTagEditor = true
                            }) {
                                Image(systemName: "tag")
                                    .font(.title2)
                                    .foregroundColor(.primary)
                                    .padding()
                                    .background(Color.secondary.opacity(0.2))
                                    .clipShape(Circle())
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .navigationTitle(noteTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingColorPicker) {
            ColorPickerView(selectedColor: $selectedColor)
        }
        .sheet(isPresented: $showingTagEditor) {
            TagEditorView(noteId: noteId)
        }
        .onAppear {
            loadCanvasData()
            // Set default color based on theme
            if colorScheme == .dark {
                selectedColor = .white
            } else {
                selectedColor = .black
            }
        }
        .onChange(of: colorScheme) { oldScheme, newScheme in
            // Update color when theme changes
            if newScheme == .dark && selectedColor == .black {
                selectedColor = .white
            } else if newScheme == .light && selectedColor == .white {
                selectedColor = .black
            }
        }
    }
    
    private var noteTitle: String {
        DatabaseHelper.shared.getNote(id: noteId)?.title ?? "Note"
    }
    
    private func loadCanvasData() {
        canvasData = DatabaseHelper.shared.loadCanvasData(noteId: noteId)
        scale = CGFloat(canvasData.scale)
        // Initialize offset from matrix
        let transform = canvasData.matrix.cgAffineTransform
        offset = CGSize(width: transform.tx, height: transform.ty)
        lastOffset = offset
    }
    
    private func saveCanvasData() {
        DatabaseHelper.shared.saveCanvasData(noteId: noteId, data: canvasData)
    }
    
    private func saveState() {
        undoStack.append(canvasData.copy())
        redoStack.removeAll()
    }
    
    private func undo() {
        guard !undoStack.isEmpty else { return }
        redoStack.append(canvasData.copy())
        canvasData = undoStack.removeLast()
        saveCanvasData()
    }
    
    private func redo() {
        guard !redoStack.isEmpty else { return }
        undoStack.append(canvasData.copy())
        canvasData = redoStack.removeLast()
        saveCanvasData()
    }
    
    private func updateMatrix() {
        // Update matrix based on offset and scale
        canvasData.matrix = Matrix4(
            m11: Double(scale), m12: 0, m13: 0, m14: 0,
            m21: 0, m22: Double(scale), m23: 0, m24: 0,
            m31: 0, m32: 0, m33: 1, m34: 0,
            m41: Double(offset.width), m42: Double(offset.height), m43: 0, m44: 1
        )
    }
}

struct ColorPickerView: View {
    @Binding var selectedColor: StrokeColor
    @Environment(\.dismiss) var dismiss
    
    let colors: [StrokeColor] = [
        .black, .white,
        StrokeColor(red: 1, green: 0, blue: 0), // Red
        StrokeColor(red: 0, green: 1, blue: 0), // Green
        StrokeColor(red: 0, green: 0, blue: 1), // Blue
        StrokeColor(red: 1, green: 1, blue: 0), // Yellow
        StrokeColor(red: 1, green: 0, blue: 1), // Magenta
        StrokeColor(red: 0, green: 1, blue: 1), // Cyan
    ]
    
    var body: some View {
        NavigationView {
            VStack {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 20) {
                    ForEach(colors, id: \.self) { color in
                        Button(action: {
                            selectedColor = color
                            dismiss()
                        }) {
                            Circle()
                                .fill(color.uiColor)
                                .frame(width: 50, height: 50)
                                .overlay(
                                    Circle()
                                        .stroke(selectedColor == color ? Color.blue : Color.clear, lineWidth: 3)
                                )
                        }
                    }
                }
                .padding()
                Spacer()
            }
            .navigationTitle("Select Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TagEditorView: View {
    let noteId: Int
    @State private var tags: [String] = []
    @State private var tagText: String = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                TextField("Enter tags (comma separated)", text: $tagText)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                    .onSubmit {
                        addTags()
                    }
                
                List {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                    }
                    .onDelete { indexSet in
                        tags.remove(atOffsets: indexSet)
                    }
                }
                
                Button("Save") {
                    DatabaseHelper.shared.setNoteTags(noteId: noteId, tags: tags)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle("Edit Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                tags = DatabaseHelper.shared.getNoteTags(noteId: noteId)
            }
        }
    }
    
    private func addTags() {
        let newTags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        tags.append(contentsOf: newTags)
        tagText = ""
    }
}

