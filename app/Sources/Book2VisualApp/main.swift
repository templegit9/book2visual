import SwiftUI
import Book2VisualCore

/// Thin @main entry point. Hosts the SwiftUI scene defined in the library.
/// Set BOOK2VISUAL_MOCK=1 to run fully offline against the mock services.
@main
struct Book2VisualAppMain: App {
    var body: some Scene {
        Book2VisualScene()
    }
}
