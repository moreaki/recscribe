import Foundation

/// Validates the checked-in v1 schema, then the cross-field invariants used by the Python reference.
/// This is deliberately a validator for our schema's vocabulary, not a general JSON Schema engine.
public struct CanonicalTranscript: Sendable {
    public let value: JSONValue
    public init(_ value: JSONValue) throws {
        let name = value["schema_version"] == "1.1" ? "transcript-v1.1.schema" : "transcript.schema"
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw CoreFailure("The app is missing its transcript schema resource; reinstall this build")
        }
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        try Self.validate(value, schema: schema, root: schema, path: "$", depth: 0)
        try Self.validateMeaning(value)
        self.value = value
    }
    public static var schemaURL: URL { Bundle.module.url(forResource: "transcript.schema", withExtension: "json")! }

    private static func validate(_ value: JSONValue, schema: JSONValue, root: JSONValue, path: String, depth: Int) throws {
        guard depth < 64, let rules = schema.object else { throw CoreFailure("Unsupported transcript schema") }
        let supported: Set<String> = ["$schema", "$id", "$defs", "$ref", "title", "description", "type", "const", "enum", "required", "properties", "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "minimum", "maximum", "minLength", "pattern"]
        guard Set(rules.keys).isSubset(of: supported) else { throw CoreFailure("Transcript schema needs a newer validator") }
        if let reference = schema["$ref"].string {
            guard reference.hasPrefix("#/$defs/"), let name = reference.split(separator: "/").last,
                  root["$defs"][String(name)].object != nil else { throw CoreFailure("Unsupported transcript schema reference") }
            return try validate(value, schema: root["$defs"][String(name)], root: root, path: path, depth: depth + 1)
        }
        func require(_ condition: Bool) throws { if !condition { throw CoreFailure("Invalid canonical transcript at \(path)") } }
        if let constant = rules["const"] { try require(value == constant) }
        if let choices = schema["enum"].array { try require(choices.contains(value)) }
        let types = schema["type"].array?.compactMap(\.string) ?? schema["type"].string.map { [$0] } ?? []
        if !types.isEmpty {
            try require(types.contains { type in
                switch type {
                case "object": value.object != nil
                case "array": value.array != nil
                case "string": value.string != nil
                case "integer": value.integer != nil
                case "number": value.double != nil
                case "boolean": value.bool != nil
                case "null": value == .null
                default: false
                }
            })
        }
        if let object = value.object {
            let required = schema["required"].array?.compactMap(\.string) ?? []
            try require(required.allSatisfy { object[$0] != nil })
            let properties = schema["properties"].object ?? [:]
            if schema["additionalProperties"] == false { try require(Set(object.keys).isSubset(of: Set(properties.keys))) }
            for (key, child) in object {
                if let definition = properties[key] { try validate(child, schema: definition, root: root, path: path + "." + key, depth: depth + 1) }
            }
        }
        if let array = value.array {
            if let minimum = schema["minItems"].integer { try require(array.count >= minimum) }
            if let maximum = schema["maxItems"].integer { try require(array.count <= maximum) }
            if schema["uniqueItems"] == true {
                let encoded = try array.map { try $0.encoded() }
                try require(Set(encoded).count == array.count)
            }
            if let item = rules["items"] {
                for (index, child) in array.enumerated() { try validate(child, schema: item, root: root, path: "\(path)[\(index)]", depth: depth + 1) }
            }
        }
        if let number = value.double {
            if let minimum = schema["minimum"].double { try require(number >= minimum) }
            if let maximum = schema["maximum"].double { try require(number <= maximum) }
        }
        if let string = value.string {
            if let minimum = schema["minLength"].integer { try require(string.unicodeScalars.count >= minimum) }
            if let pattern = schema["pattern"].string { try require(string.range(of: pattern, options: .regularExpression) != nil) }
        }
    }

    private static func validateMeaning(_ document: JSONValue) throws {
        let source = document["source"], processing = document["processing"], language = document["language_processing"]
        let segments = document["segments"].array ?? [], derivations = language["derivations"].array ?? []
        let cloud = !(processing["openai_model"].string ?? "").isEmpty
        let cloudAudio = processing["allow_cloud_audio"] == true
        guard (cloud || cloudAudio) == (processing["local_only"] == false), !cloud || processing["allow_cloud_text"] == true,
              language["mode"] == processing["mode"] else { throw CoreFailure("Transcript mode or cloud consent is inconsistent") }
        let passes = processing["engine_passes"].array ?? []
        guard cloudAudio == (document["schema_version"] == "1.1"),
              cloudAudio == passes.contains(where: { $0["local_only"] == false }) else {
            throw CoreFailure("Cloud audio provenance requires transcript v1.1 and explicit consent")
        }
        for pass in passes {
            if pass["local_only"] == true {
                guard pass["model_sha256"].string?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                    throw CoreFailure("Local models require a SHA-256 digest")
                }
            } else {
                guard pass["model_sha256"] == .null,
                      pass["model"] == processing["cloud_audio_consent"]["model"] else {
                    throw CoreFailure("Cloud model weights must not claim a local hash")
                }
            }
        }
        let needsReview = !(document["review_reasons"].array ?? []).isEmpty || segments.contains { $0["needs_review"] == true }
        guard (document["status"] == "completed_with_review") == needsReview else { throw CoreFailure("Transcript status does not match review requirements") }
        let ids = Set(segments.compactMap { $0["id"].string })
        guard ids.count == segments.count else { throw CoreFailure("Transcript segment IDs are not unique") }
        for note in document["summary"]["notes"].array ?? [] {
            guard Set(note["segment_ids"].array?.compactMap(\.string) ?? []).isSubset(of: ids) else { throw CoreFailure("Summary references unknown segments") }
        }
        let duration = source["duration_ms"].integer ?? 0
        var boundaries: Set<Int64> = [duration]
        for part in source["parts"].array ?? [] {
            if let offset = part["offset_ms"].integer, let length = part["report"]["duration_ms"].integer {
                let (end, overflow) = offset.addingReportingOverflow(length)
                guard !overflow else { throw CoreFailure("Invalid part boundary") }
                boundaries.insert(end)
            }
        }
        var previous: Int64 = -1
        for segment in segments {
            guard let start = segment["start_ms"].integer, let end = segment["end_ms"].integer,
                  start >= previous, start < end, end <= duration,
                  (segment["channel"].integer ?? .max) < (source["channels"].integer ?? 0),
                  segment["needs_review"].bool == !(segment["review_reasons"].array ?? []).isEmpty else {
                throw CoreFailure("Invalid transcript timing, channel or review flags")
            }
            previous = start
            if segment["timing_adjustment"] != .null {
                guard (segment["timing_adjustment"]["original_end_ms"].integer ?? 0) > end, boundaries.contains(end),
                      segment["review_reasons"].array?.contains("engine_end_exceeds_source; trimmed_with_provenance") == true else {
                    throw CoreFailure("Invalid source-boundary timing adjustment")
                }
            }
            for field in ["normalized_text", "translated_text"] where segment[field] != .null {
                guard derivations.contains(where: { $0["segment_id"] == segment["id"] && $0["field"] == .string(field) }) else {
                    throw CoreFailure("Derived text requires source-linked provenance")
                }
            }
        }
    }
}
