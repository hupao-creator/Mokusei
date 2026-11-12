import MokuseiPluginAPI

/// Static native composition mirrors the shipped renderer module registry.
/// The host receives only public module contracts, never concrete app DTOs.
@MainActor public enum NativeApplicationModules {
    public static func make() throws -> [ApplicationPluginModule] {
        try [NativeReportApplication.make(), NativeTagApplication.make()]
    }
}
