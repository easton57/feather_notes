import SwiftUI

@main
struct feather_notesApp: App {
    @AppStorage("themeMode") private var themeMode: String = "system"
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
        }
    }
    
    private var colorScheme: ColorScheme? {
        switch themeMode {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }
}
