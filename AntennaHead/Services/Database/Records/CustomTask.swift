import Foundation
import GRDB

struct CustomTask: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var taskName: String
    var taskJson: String
    var sampleRate: Int
    var channels: Int
    var inputBufferSize: Int
    var audioconverterBufferSize: Int
    var audioqueueBufferSize: Int

    static let databaseTableName = "custom_task"

    enum CodingKeys: String, CodingKey {
        case id
        case taskName = "task_name"
        case taskJson = "task_json"
        case sampleRate = "sample_rate"
        case channels
        case inputBufferSize = "input_buffer_size"
        case audioconverterBufferSize = "audioconverter_buffer_size"
        case audioqueueBufferSize = "audioqueue_buffer_size"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func prototype(name: String = "") -> CustomTask {
        CustomTask(
            id: nil,
            taskName: name,
            taskJson: "",
            sampleRate: 48_000,
            channels: 1,
            inputBufferSize: 256,
            audioconverterBufferSize: 256,
            audioqueueBufferSize: 256
        )
    }
}
