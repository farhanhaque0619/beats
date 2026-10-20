// Prints the CGWindowID of the frontmost normal window owned by the app named in argv[1],
// for `screencapture -l <id>`. Owner names don't need Screen Recording permission.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Ink"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
let match = windows.first { info in
    (info[kCGWindowOwnerName as String] as? String) == owner
        && (info[kCGWindowLayer as String] as? Int) == 0
        && ((info[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) > 200
}
if let id = match?[kCGWindowNumber as String] as? Int {
    print(id)
} else {
    exit(1)
}
