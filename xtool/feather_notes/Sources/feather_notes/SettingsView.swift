import SwiftUI

struct SettingsView: View {
    @AppStorage("themeMode") private var themeMode: String = "system"
    @Environment(\.dismiss) var dismiss
    @State private var showingWipeConfirmation = false
    
    var body: some View {
        NavigationView {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: $themeMode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                
                Section("Data") {
                    Button(role: .destructive, action: {
                        showingWipeConfirmation = true
                    }) {
                        HStack {
                            Text("Wipe All Data")
                            Spacer()
                            Image(systemName: "trash")
                        }
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Wipe All Data", isPresented: $showingWipeConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    DatabaseHelper.shared.wipeDatabase()
                }
            } message: {
                Text("This will permanently delete all notes, drawings, and data. This action cannot be undone.")
            }
        }
    }
}

