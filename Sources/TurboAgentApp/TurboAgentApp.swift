import AppKit
import SwiftUI
import TurboAgentCore

/// Makes a bare SwiftPM executable behave like a foreground Mac application.
/// Without this, Terminal can remain active and keep keyboard input after launch.
private final class AgentAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
struct TurboAgentApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AgentAppDelegate
  @StateObject private var model = AgentAppModel()

  var body: some Scene {
    WindowGroup("Turbo Agent") {
      AgentRootView(model: model)
        .frame(minWidth: 860, minHeight: 600)
    }
    .defaultSize(width: 1120, height: 760)
  }
}

private struct ChatMessage: Identifiable {
  enum Role { case user, assistant, tool, error }
  let id = UUID()
  let role: Role
  var text: String
}

private struct PendingApproval: Identifiable {
  let id = UUID()
  let request: AgentToolRequest
  let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
private final class AgentAppModel: ObservableObject {
  @Published var messages: [ChatMessage] = []
  @Published var draft = ""
  @Published var backend: AgentClientBackend = .appleAutomatic
  @Published var isWorking = false
  @Published var pendingApproval: PendingApproval?
  @Published var status = "Ready"

  private var client: AgentClient?
  private var clientBackend: AgentClientBackend?
  private var task: Task<Void, Never>?
  private var activeGenerationID: UUID?

  func newConversation() {
    let previousClient = client
    task?.cancel()
    if let previousClient { Task { await previousClient.cancel() } }
    task = nil
    activeGenerationID = nil
    client = nil
    clientBackend = nil
    messages.removeAll()
    draft = ""
    isWorking = false
    status = "Ready"
    resolveApproval(false)
  }

  func send() {
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !isWorking else { return }
    draft = ""
    messages.append(ChatMessage(role: .user, text: prompt))
    messages.append(ChatMessage(role: .assistant, text: ""))
    let responseID = messages.last!.id
    isWorking = true
    status = "Thinking"
    let selectedBackend = backend
    let generationID = UUID()
    activeGenerationID = generationID

    task = Task { [self] in
      do {
        let activeClient: AgentClient
        if let client, clientBackend == selectedBackend {
          activeClient = client
        } else {
          activeClient = try await AgentClient.make(backend: selectedBackend)
          client = activeClient
          clientBackend = selectedBackend
        }
        _ = try await activeClient.send(
          prompt,
          onText: { [weak self] text in
            Task { @MainActor in
              guard self?.activeGenerationID == generationID else { return }
              self?.append(text, to: responseID)
            }
          },
          onTool: { [weak self] update in
            Task { @MainActor in
              guard self?.activeGenerationID == generationID else { return }
              self?.messages.append(
                ChatMessage(
                  role: .tool,
                  text: "\(update.name) · \(update.status)\n\(update.output ?? update.summary)"))
            }
          },
          approve: { [weak self] request in
            guard let self else { return false }
            guard await self.activeGenerationID == generationID else { return false }
            return await self.requestApproval(request)
          })
        if activeGenerationID == generationID { status = "Ready" }
      } catch is CancellationError {
        if activeGenerationID == generationID { status = "Stopped" }
      } catch {
        if activeGenerationID == generationID {
          messages.append(ChatMessage(role: .error, text: String(describing: error)))
          status = "Error"
        }
      }
      if activeGenerationID == generationID {
        activeGenerationID = nil
        isWorking = false
        task = nil
      }
    }
  }

  func stop() {
    resolveApproval(false)
    task?.cancel()
    if let client { Task { await client.cancel() } }
  }

  func resolveApproval(_ allowed: Bool) {
    guard let pendingApproval else { return }
    self.pendingApproval = nil
    pendingApproval.continuation.resume(returning: allowed)
  }

  private func append(_ text: String, to id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += text
  }

  private func requestApproval(_ request: AgentToolRequest) async -> Bool {
    await withCheckedContinuation { continuation in
      pendingApproval = PendingApproval(request: request, continuation: continuation)
    }
  }
}

private struct AgentRootView: View {
  @ObservedObject var model: AgentAppModel
  @FocusState private var composerFocused: Bool

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 16) {
        Button(action: model.newConversation) {
          Label("New Chat", systemImage: "square.and.pencil")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Text("Backend").font(.caption).foregroundStyle(.secondary)
        Picker("Backend", selection: $model.backend) {
          ForEach(AgentClientBackend.allCases) { backend in
            Text(backend.label).tag(backend)
          }
        }
        .labelsHidden()

        Divider()
        Label(model.status, systemImage: model.isWorking ? "sparkles" : "circle.fill")
          .foregroundStyle(model.isWorking ? Color.accentColor : Color.secondary)
        Spacer()
        Text("AFM 3 + OpenAI-compatible APIs")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
      .navigationSplitViewColumnWidth(min: 210, ideal: 230)
    } detail: {
      VStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
              if model.messages.isEmpty {
                ContentUnavailableView(
                  "Start a conversation", systemImage: "bubble.left.and.bubble.right",
                  description: Text("Choose AFM 3 or an OpenAI-compatible backend.")
                )
                .padding(.top, 100)
              }
              ForEach(model.messages) { message in
                MessageView(message: message).id(message.id)
              }
            }
            .padding(24)
          }
          .onChange(of: model.messages.count) {
            if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
        Divider()
        HStack(alignment: .bottom, spacing: 12) {
          TextEditor(text: $model.draft)
            .font(.body)
            .focused($composerFocused)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 44, maxHeight: 130)
            .padding(8)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
          if model.isWorking {
            Button(action: model.stop) { Image(systemName: "stop.fill") }
              .buttonStyle(.borderedProminent).tint(.red)
          } else {
            Button(action: model.send) { Image(systemName: "arrow.up") }
              .buttonStyle(.borderedProminent)
              .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .padding(16)
      }
      .navigationTitle("Turbo Agent")
    }
    .alert(
      "Allow tool call?",
      isPresented: Binding(
        get: { model.pendingApproval != nil },
        set: { if !$0 { model.resolveApproval(false) } }
      )
    ) {
      Button("Deny", role: .cancel) { model.resolveApproval(false) }
      Button("Allow Once") { model.resolveApproval(true) }
    } message: {
      if let approval = model.pendingApproval {
        Text("\(approval.request.name)\n\(approval.request.summary)")
      }
    }
    .onChange(of: model.backend) { model.newConversation() }
    .onChange(of: model.isWorking) {
      if !model.isWorking { composerFocused = true }
    }
    .onAppear {
      DispatchQueue.main.async { composerFocused = true }
    }
  }
}

private struct MessageView: View {
  let message: ChatMessage

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .frame(width: 28, height: 28)
        .background(color.opacity(0.14), in: Circle())
        .foregroundStyle(color)
      VStack(alignment: .leading, spacing: 5) {
        Text(label).font(.caption.bold()).foregroundStyle(.secondary)
        Text(message.text.isEmpty ? "…" : message.text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var label: String {
    switch message.role {
    case .user: "You"
    case .assistant: "Agent"
    case .tool: "Tool"
    case .error: "Error"
    }
  }
  private var icon: String {
    switch message.role {
    case .user: "person.fill"
    case .assistant: "sparkles"
    case .tool: "wrench.and.screwdriver"
    case .error: "exclamationmark.triangle.fill"
    }
  }
  private var color: Color {
    switch message.role {
    case .user: .blue
    case .assistant: .purple
    case .tool: .orange
    case .error: .red
    }
  }
}
