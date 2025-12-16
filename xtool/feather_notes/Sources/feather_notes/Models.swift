import Foundation
import SwiftUI
import CoreGraphics

// MARK: - Point
struct DrawingPoint: Codable, Equatable {
    let x: Double
    let y: Double
    let pressure: Double
    
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
    
    init(x: Double, y: Double, pressure: Double = 0.5) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }
    
    init(_ point: CGPoint, pressure: Double = 0.5) {
        self.x = Double(point.x)
        self.y = Double(point.y)
        self.pressure = pressure
    }
}

// MARK: - Stroke
struct Stroke: Codable, Equatable {
    let points: [DrawingPoint]
    let color: StrokeColor
    let penSize: Double
    
    init(points: [DrawingPoint], color: StrokeColor = .black, penSize: Double = 1.0) {
        self.points = points
        self.color = color
        self.penSize = penSize
    }
    
    func hitTest(_ pos: CGPoint) -> Bool {
        for point in points {
            let distance = sqrt(pow(Double(point.x - pos.x), 2) + pow(Double(point.y - pos.y), 2))
            if distance < 12 {
                return true
            }
        }
        return false
    }
}

// MARK: - StrokeColor
struct StrokeColor: Codable, Equatable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    
    var uiColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
    
    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    
    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    
    init(_ color: Color) {
        // Convert SwiftUI Color to RGB
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }
    
    static let black = StrokeColor(red: 0, green: 0, blue: 0, alpha: 1.0)
    static let white = StrokeColor(red: 1, green: 1, blue: 1, alpha: 1.0)
}

// MARK: - TextElement
struct TextElement: Codable, Equatable, Identifiable {
    let id: UUID
    let position: DrawingPoint
    let text: String
    let fontSize: Double
    
    init(position: DrawingPoint, text: String, fontSize: Double = 16.0) {
        self.id = UUID()
        self.position = position
        self.text = text
        self.fontSize = fontSize
    }
    
    var cgPoint: CGPoint {
        position.cgPoint
    }
}

// MARK: - NoteCanvasData
struct NoteCanvasData: Codable, Equatable {
    var strokes: [Stroke]
    var textElements: [TextElement]
    var matrix: Matrix4
    var scale: Double
    
    init(strokes: [Stroke] = [], textElements: [TextElement] = [], matrix: Matrix4 = Matrix4.identity, scale: Double = 1.0) {
        self.strokes = strokes
        self.textElements = textElements
        self.matrix = matrix
        self.scale = scale
    }
    
    func copy() -> NoteCanvasData {
        NoteCanvasData(
            strokes: strokes,
            textElements: textElements,
            matrix: matrix,
            scale: scale
        )
    }
}

// MARK: - Matrix4
struct Matrix4: Codable, Equatable {
    var m11: Double, m12: Double, m13: Double, m14: Double
    var m21: Double, m22: Double, m23: Double, m24: Double
    var m31: Double, m32: Double, m33: Double, m34: Double
    var m41: Double, m42: Double, m43: Double, m44: Double
    
    static let identity = Matrix4(
        m11: 1, m12: 0, m13: 0, m14: 0,
        m21: 0, m22: 1, m23: 0, m24: 0,
        m31: 0, m32: 0, m33: 1, m34: 0,
        m41: 0, m42: 0, m43: 0, m44: 1
    )
    
    var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(m11), b: CGFloat(m12),
            c: CGFloat(m21), d: CGFloat(m22),
            tx: CGFloat(m41), ty: CGFloat(m42)
        )
    }
    
    init(m11: Double, m12: Double, m13: Double, m14: Double,
         m21: Double, m22: Double, m23: Double, m24: Double,
         m31: Double, m32: Double, m33: Double, m34: Double,
         m41: Double, m42: Double, m43: Double, m44: Double) {
        self.m11 = m11; self.m12 = m12; self.m13 = m13; self.m14 = m14
        self.m21 = m21; self.m22 = m22; self.m23 = m23; self.m24 = m24
        self.m31 = m31; self.m32 = m32; self.m33 = m33; self.m34 = m34
        self.m41 = m41; self.m42 = m42; self.m43 = m43; self.m44 = m44
    }
    
    init(from values: [Double]) {
        guard values.count == 16 else {
            self = .identity
            return
        }
        self.m11 = values[0]; self.m12 = values[1]; self.m13 = values[2]; self.m14 = values[3]
        self.m21 = values[4]; self.m22 = values[5]; self.m23 = values[6]; self.m24 = values[7]
        self.m31 = values[8]; self.m32 = values[9]; self.m33 = values[10]; self.m34 = values[11]
        self.m41 = values[12]; self.m42 = values[13]; self.m43 = values[14]; self.m44 = values[15]
    }
    
    var storage: [Double] {
        [m11, m12, m13, m14,
         m21, m22, m23, m24,
         m31, m32, m33, m34,
         m41, m42, m43, m44]
    }
    
    enum CodingKeys: String, CodingKey {
        case storage
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([Double].self, forKey: .storage)
        self.init(from: values)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storage, forKey: .storage)
    }
}

// MARK: - Note
struct Note: Identifiable, Codable {
    let id: Int
    var title: String
    let createdAt: Int64
    var modifiedAt: Int64
    var folderId: Int?
    var tags: [String]
    var isTextOnly: Bool
    
    init(id: Int, title: String, createdAt: Int64, modifiedAt: Int64, folderId: Int? = nil, tags: [String] = [], isTextOnly: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.folderId = folderId
        self.tags = tags
        self.isTextOnly = isTextOnly
    }
}

// MARK: - Folder
struct Folder: Identifiable, Codable {
    let id: Int
    var name: String
    let createdAt: Int64
    let sortOrder: Int
    
    init(id: Int, name: String, createdAt: Int64, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }
}

