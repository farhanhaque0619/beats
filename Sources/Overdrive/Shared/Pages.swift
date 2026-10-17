import Foundation

/// Sidebar destinations that aren't a sound device.
enum Page {
    static let overview = "overview"
    static let display = "display"
    static let performance = "performance"
    static let tools = "tools"

    static let all: Set<String> = [overview, display, performance, tools, SoundModel.groupSelectionID, SoundModel.appsSelectionID]
}
