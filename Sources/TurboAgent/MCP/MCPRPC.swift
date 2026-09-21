import Foundation

enum MCPRPC {
    static func call(id: Int, name: String, argumentsJSON: String) throws -> Data {
        let arguments = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                     "params": ["name": name, "arguments": arguments]]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    static func matches(_ line: String, id: Int) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let responseID = object["id"] as? NSNumber,
              CFGetTypeID(responseID) != CFBooleanGetTypeID() else { return false }
        return responseID == NSNumber(value: id)
    }
}
