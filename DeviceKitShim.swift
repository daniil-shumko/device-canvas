import Foundation
import SwiftUI

// Compile-time API shim. The executable links these symbols from Xcode's
// private DeviceKit framework; this implementation is never linked.
public struct DeviceView: View {
    public init(deviceIdentifier: UUID) {
        fatalError("DeviceKitShim must not be linked")
    }

    public var body: some View {
        EmptyView()
    }
}
