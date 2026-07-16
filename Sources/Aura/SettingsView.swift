import SwiftUI

struct SettingsView: View {
    @AppStorage("editorFontSize") private var fontSize = 16.0

    var body: some View {
        Form {
            HStack {
                Text("Editor text size")
                Slider(value: $fontSize, in: 12...28, step: 1)
                Text("\(Int(fontSize)) pt")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
