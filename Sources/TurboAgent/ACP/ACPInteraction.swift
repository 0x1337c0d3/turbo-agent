import Foundation

enum ACPInteraction {
  static func make(
    session: String, directory: URL, capabilities: JSONValue,
    channel: ACPChannel, cancellation: AgentCancellation
  ) -> AgentInteraction {
    var interaction = AgentInteraction(
      cancellation: cancellation,
      text: { text in
        channel.update(
          session: session,
          [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
          ])
      },
      tool: { call, status, output in
        var update = toolCall(call, directory: directory)
        update["sessionUpdate"] = .string(status == "pending" ? "tool_call" : "tool_call_update")
        update["status"] = .string(status)
        if let output {
          update["content"] = .array([
            .object([
              "type": .string("content"),
              "content": .object([
                "type": .string("text"), "text": .string(String(output.prefix(32_768))),
              ]),
            ])
          ])
        }
        channel.update(session: session, update)
      },
      approve: { call, diff in
        do {
          let result = try await channel.request(
            "session/request_permission",
            params: [
              "sessionId": .string(session),
              "toolCall": .object(toolCall(call, directory: directory, diff: diff)),
              "options": .array([
                .object([
                  "optionId": .string("allow-once"), "name": .string("Allow once"),
                  "kind": .string("allow_once"),
                ]),
                .object([
                  "optionId": .string("reject-once"), "name": .string("Reject"),
                  "kind": .string("reject_once"),
                ]),
              ]),
            ], session: session, cancellation: cancellation)
          return !cancellation.isCancelled && result["outcome"]?["outcome"]?.string == "selected"
            && result["outcome"]?["optionId"]?.string == "allow-once"
        } catch { return false }
      })
    if capabilities["fs"]?["readTextFile"]?.boolean == true {
      interaction.readFile = { path in
        let result = try await channel.request(
          "fs/read_text_file",
          params: [
            "sessionId": .string(session), "path": .string(path),
          ], session: session, cancellation: cancellation)
        guard let content = result["content"]?.string else {
          throw ACPError.invalid("Missing client file content")
        }
        return content
      }
    }
    if capabilities["fs"]?["writeTextFile"]?.boolean == true {
      interaction.writeFile = { path, content in
        _ = try await channel.request(
          "fs/write_text_file",
          params: [
            "sessionId": .string(session), "path": .string(path), "content": .string(content),
          ], session: session, cancellation: cancellation)
      }
    }
    return interaction
  }

  private static func toolCall(_ call: ParsedToolCall, directory: URL, diff: String? = nil)
    -> ACPObject
  {
    let kind: String
    switch call.name {
    case "read_file": kind = "read"
    case "write_file", "edit_file", "apply_patch": kind = "edit"
    case "execute_bash": kind = "execute"
    case "read_url": kind = "fetch"
    default: kind = "other"
    }
    var result: ACPObject = [
      "toolCallId": .string(call.id), "title": .string(call.name + " " + call.argumentSummary),
      "kind": .string(kind), "rawInput": call.arguments,
    ]
    if let diff {
      result["content"] = .array([
        .object([
          "type": .string("content"),
          "content": .object([
            "type": .string("text"), "text": .string(diff),
          ]),
        ])
      ])
    }
    if let path = call.stringArgument("path"),
      ["read_file", "write_file", "edit_file", "apply_patch"].contains(call.name)
    {
      let path = URL(
        fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory
      ).standardizedFileURL.path
      result["locations"] = .array([.object(["path": .string(path)])])
    }
    return result
  }
}
