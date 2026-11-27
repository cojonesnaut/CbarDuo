import Darwin
import Foundation

/// Hands memory the app has already freed back to the system.
///
/// Freeing a large SwiftUI view tree (the popover, Settings) returns its
/// objects to malloc, but malloc keeps the now-empty pages mapped and they
/// still count against the app's footprint. Asking every zone for pressure
/// relief releases those pages. It only touches free memory, so it is safe
/// to call at any time; it is not free, so it runs off the main thread and
/// only after a window's contents have actually been torn down.
enum MemoryRelief {
    /// Delay before relief, so SwiftUI and Core Animation finish their own
    /// deferred releases from the teardown first.
    static let settleDelay: TimeInterval = 2

    static func releaseFreedPages() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + settleDelay) {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }
}
