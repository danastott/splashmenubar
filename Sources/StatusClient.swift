import Foundation

/// Subset of the `GET /status` JSON (schema_version 6) used by the UI.
struct StatusDoc: Decodable {
    let ready: Bool?
    let thermal_state: String?
    let maximum_context_tokens: Int?
    let requests: Requests?
    let metrics: Metrics?
    let cache: Cache?
    let scheduler: Scheduler?
    let instance: Instance?
    let transport: Transport?
    let memory_current_bytes: Int?
    let weights: Weights?
    let active_requests: [ActiveRequest]?

    struct ActiveRequest: Decodable {
        let id: Int?
        let phase: String?
        let prompt_tokens: Int?
        let prompt_processed: Int?
        let generated_tokens: Int?
        let max_new_tokens: Int?
        let age_ms: Double?
    }

    struct Requests: Decodable {
        let submitted: Int?
        let completed: Int?
        let cancelled: Int?
        let failed: Int?
    }

    struct Metrics: Decodable {
        let ttft_ms: Percentiles?
        let prefill_tokens_per_second: Double?
        let decode_tokens_per_second: Double?
        let decode_output_tokens: Int?
        let current_decode_batch: Batch?
        let current_prefill_batch: Batch?

        struct Percentiles: Decodable {
            let p50: Double?
            let p95: Double?
        }

        struct Batch: Decodable {
            let valid: Bool?
            let tokens_per_second: Double?
            let input_tokens: Int?
            let output_tokens: Int?
        }
    }

    struct Cache: Decodable {
        let hit_rate: Double?
        let reused_tokens: Int?
        let deduplicated_kv_tokens: Int?
    }

    struct Scheduler: Decodable {
        let prefilling: Int?
        let decoding: Int?
        let queued: Int?
    }

    struct Instance: Decodable {
        let started_at: Double?
        let model: String?
        let port: Int?
    }

    struct Transport: Decodable {
        let ready: Bool?
        let stopped: Bool?
    }

    struct Weights: Decodable {
        let released: Bool?
        let restoring: Bool?
    }
}

enum StatusClient {
    /// Fetch and decode `/status` from the local server.
    static func fetch(port: Int) async -> StatusDoc? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/status") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try? JSONDecoder().decode(StatusDoc.self, from: data)
        } catch {
            return nil
        }
    }
}
