import SwiftUI

/// Rows used to float as separate glass capsules; they now sit inside a
/// section card (see PopoverChrome), so the row-level background is a no-op.
/// The modifier is kept so existing call sites compile unchanged.
struct PopoverRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func popoverCardBackground(cornerRadius: CGFloat, fillOpacity: Double) -> some View {
        modifier(PopoverRowBackground())
    }
}
