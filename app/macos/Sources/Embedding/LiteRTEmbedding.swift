import CLiteRTLM
import Foundation

// All C handles stay on the helper's serial request path. Each native owner is
// released on errors as well as success; no handle crosses the Runtime pipe.
final class LiteRTEmbedding {
    private var handle: OpaquePointer?
    private let dimensions: Int
    private struct NativeFailure: Error {}
    private static func check(_ status: LiteRtLmStatusCode) throws {
        guard status == kLiteRtLmStatusOk else {
            let message = "LiteRT embedding status: \(status.rawValue)\n"
            FileHandle.standardError.write(Data(message.utf8))
            litert_lm_clear_last_error()
            throw NativeFailure()
        }
    }
    init(path: String, cache: String, dimensions: Int, maxInputTokens: Int) throws {
        self.dimensions = dimensions
        var settings: OpaquePointer?
        try Self.check(litert_lm_embedding_engine_settings_create(path, "cpu", nil, nil, &settings))
        guard let settings else { throw NativeFailure() }
        defer { litert_lm_embedding_engine_settings_delete(settings) }
        try Self.check(litert_lm_embedding_engine_settings_set_num_threads(settings, 2))
        try Self.check(litert_lm_embedding_engine_settings_set_cache_dir(settings, cache))
        try Self.check(litert_lm_embedding_engine_settings_set_max_input_length(settings, Int32(maxInputTokens)))
        try Self.check(litert_lm_embedding_engine_create(settings, &handle))
        guard handle != nil else { throw NativeFailure() }
    }
    deinit { close() }
    func close() {
        if let handle { litert_lm_embedding_engine_delete(handle); self.handle = nil }
    }
    func compute(_ text: String) throws -> [Float] {
        guard let handle else { throw NativeFailure() }
        var input: OpaquePointer?
        try Self.check(text.withCString {
            litert_lm_input_data_create(kLiteRtLmInputDataTypeText, $0, text.utf8.count, &input)
        })
        defer { if let input { litert_lm_input_data_delete(input) } }
        var options: OpaquePointer?
        try Self.check(litert_lm_embedding_options_create(&options))
        defer { if let options { litert_lm_embedding_options_delete(options) } }
        try Self.check(litert_lm_embedding_options_set_normalize(options, true))
        try Self.check(litert_lm_embedding_options_set_output_size(options, Int32(dimensions)))
        try Self.check(litert_lm_embedding_options_set_input_overflow_strategy(options, kLiteRtLmInputOverflowStrategyError))
        var response: OpaquePointer?
        try Self.check(litert_lm_embedding_engine_compute_embedding(handle, &input, 1, options, &response))
        defer { if let response { litert_lm_embedding_response_delete(response) } }
        var size = 0
        var values: UnsafePointer<Float>?
        try Self.check(litert_lm_embedding_response_get_size(response, &size))
        try Self.check(litert_lm_embedding_response_get_values(response, &values))
        guard size == dimensions, let values else { throw NativeFailure() }
        return Array(UnsafeBufferPointer(start: values, count: size))
    }
}
