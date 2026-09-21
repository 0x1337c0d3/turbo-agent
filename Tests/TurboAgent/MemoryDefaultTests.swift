import ContinuityCore
import XCTest

@testable import TurboAgentCore

/// The continuity memory engine is the point of this project, so it is on by
/// default: a session gets a bootstrap, a tool surface, a conversation
/// journal, and a per-project workspace on disk unless the operator opts out.
final class MemoryDefaultTests: XCTestCase {
  func testMemoryIsEnabledByDefault() {
    let config = MemoryConfiguration.fromEnvironment(["HOME": "/tmp"])
    XCTAssertTrue(config.isEnabled)
    XCTAssertNil(config.disabledReason)
    XCTAssertEqual(config.toolSurface, .minimal)
    XCTAssertTrue(config.journalEnabled)
  }

  func testExplicitOptOutDisablesMemory() {
    for value in ["0", "off", "false", "no"] {
      let config = MemoryConfiguration.fromEnvironment([
        "HOME": "/tmp", "TINYTITAN_MEMORY": value,
      ])
      XCTAssertFalse(config.isEnabled, "TINYTITAN_MEMORY=\(value) must disable memory")
    }
    for value in ["1", "on", "true", ""] {
      let config = MemoryConfiguration.fromEnvironment([
        "HOME": "/tmp", "TINYTITAN_MEMORY": value,
      ])
      XCTAssertTrue(config.isEnabled, "TINYTITAN_MEMORY=\(value) must enable memory")
    }
  }

  func testWorkspaceDirectoryResolvesToAValidScope() {
    let config = MemoryConfiguration.fromEnvironment([
      "HOME": "/tmp",
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone/code/turbo-agent",
    ])
    XCTAssertTrue(config.isEnabled)
    let scope = config.scope(workspaceOverride: "/Users/someone/code/turbo-agent")
    XCTAssertNotNil(
      scope, "a directory override must resolve to a workspace id, never fail validation")
    XCTAssertEqual(scope?.workspace, config.workspace)
    XCTAssertFalse(scope!.workspace.contains("/"), "a scope component never carries a separator")
  }

  func testDirectoryOverrideMatchesLaunchDirectoryWorkspace() {
    let fromLaunch = MemoryConfiguration.fromEnvironment([
      "HOME": "/tmp",
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone/code/turbo-agent",
    ])
    let fromRequest = MemoryConfiguration()
    let launchScope = fromLaunch.scope(workspaceOverride: "/Users/someone/code/turbo-agent")
    let requestScope = fromRequest.scope(workspaceOverride: "/Users/someone/code/turbo-agent")
    XCTAssertEqual(launchScope?.workspace, requestScope?.workspace,
                   "the same directory must name the same memory from either entry point")
    XCTAssertEqual(
      fromLaunch.workspace,
      MemoryConfiguration.workspaceIdentifier(forPath: "/Users/someone/code/turbo-agent"))
  }

  func testWorkspaceIdentifierIsStableAcrossCalls() {
    let first = MemoryConfiguration.workspaceIdentifier(forPath: "/a/b/project")
    let second = MemoryConfiguration.workspaceIdentifier(forPath: "/a/b/project")
    XCTAssertEqual(first, second)
    XCTAssertNotEqual(
      first, MemoryConfiguration.workspaceIdentifier(forPath: "/a/b/other-project"),
      "two checkouts must never share memory")
  }

  func testJunkDrawerRefusalAppliesToHomeDirectory() {
    let config = MemoryConfiguration.fromEnvironment([
      "HOME": "/Users/someone",
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone",
    ])
    XCTAssertFalse(config.isEnabled)
    XCTAssertNotNil(config.disabledReason)
    XCTAssertTrue(config.disabledReason!.contains("not a project"))
  }

  func testJunkDrawerRefusalDoesNotFireForAProjectDirectory() {
    let config = MemoryConfiguration.fromEnvironment([
      "HOME": "/Users/someone",
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone/code/project",
    ])
    XCTAssertTrue(config.isEnabled)
    XCTAssertNil(config.disabledReason)
  }

  func testExplicitWorkspaceNameBeatsTheDirectoryOverride() {
    let config = MemoryConfiguration.fromEnvironment([
      "HOME": "/tmp",
      "TINYTITAN_MEMORY_WORKSPACE": "novel",
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone/code/project",
    ])
    XCTAssertEqual(config.workspace, "novel")
  }

  func testStorageLivesBesideTheProjectNotTheHomeDirectory() {
    let config = MemoryConfiguration.fromEnvironment([
      "HOME": "/Users/someone",
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone/code/turbo-agent",
    ])
    XCTAssertEqual(
      config.storage.directory.standardizedFileURL.path,
      "/Users/someone/code/turbo-agent/.turbo/memory",
      "memory belongs beside the project, not in a dot directory at home")
    XCTAssertTrue(config.storage.directory.path.hasSuffix(".turbo/memory"))
    XCTAssertFalse(config.storage.directory.path.contains("/Users/someone/.tinytitan"))
  }

  func testJunkDrawerLaunchFallsBackToTheHomeMemoryDirectory() {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let homeParent = URL(fileURLWithPath: home).deletingLastPathComponent().path
    for launch in [home, homeParent, "/"] {
      let config = MemoryConfiguration.fromEnvironment([
        "HOME": home,
        "TINYTITAN_WORKSPACE_DIR": launch,
      ])
      XCTAssertEqual(
        config.storage.directory.standardizedFileURL.path,
        home + "/.turbo/memory",
        "no project to sit beside for \(launch): the fallback is under home")
      // The refusal, not silent misdirected writes: a session opened from a
      // non-project directory must not serve memory at all.
      XCTAssertNil(config.scope(workspaceOverride: launch))
    }
  }

  func testExplicitMemoryDirectoryOverridesTheDerivedLocation() {
    let config = MemoryConfiguration.fromEnvironment([
      "HOME": "/Users/someone",
      "TINYTITAN_MEMORY_DIR": "/var/turbo-memory",
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone/code/project",
    ])
    XCTAssertEqual(config.storage.directory.standardizedFileURL.path, "/var/turbo-memory")
  }

  func testResolvedDirectoryUsesTheProcessWorkingDirectoryWhenNoOverrideIsSet() {
    let directory = ContinuityStorageConfiguration.resolvedDirectory(
      environment: ["HOME": "/Users/someone"],
      currentDirectory: "/Users/someone/code/other")
    XCTAssertEqual(directory.standardizedFileURL.path, "/Users/someone/code/other/.turbo/memory")
  }

  func testToolSurfaceEnvironmentStillControlsTheSurface() async {
    let full = MemoryConfiguration.fromEnvironment([
      "HOME": "/tmp", "TINYTITAN_MEMORY_TOOLS": "full",
    ])
    XCTAssertEqual(full.toolSurface, .full)
    let off = MemoryConfiguration.fromEnvironment([
      "HOME": "/tmp", "TINYTITAN_MEMORY_TOOLS": "off",
    ])
    XCTAssertEqual(off.toolSurface, .off)
    let offService = MemoryService(configuration: off)
    let offDefs = await offService.toolDefinitions()
    XCTAssertTrue(offDefs.isEmpty)
    let defaultService = MemoryService(configuration: MemoryConfiguration())
    let defaultDefs = await defaultService.toolDefinitions()
    XCTAssertEqual(
      Set(defaultDefs.map { $0.name }),
      Set(MemoryToolSurface.minimal.toolNames))
  }

  func testBeginSessionProducesABoundedBootstrapAndJournalTurns() async {
    let store = InMemoryStore()
    let journal = InMemoryJournal()
    let service = MemoryService(
      configuration: MemoryConfiguration(),
      durableStore: store, journal: journal)
    let first = await service.beginSession(
      id: "conversation-1", workspaceOverride: "/tmp/proj", focus: "the sync design")
    XCTAssertNotNil(first, "memory on by default must produce a session")
    let scope = first!.scope
    try! await store.set(
      MemoryRecord(key: try! MemoryKey(validating: "decisions/sync"), value: "use the journal",
                   importance: 0.9),
      in: scope)
    // A fresh bootstrap picks up the fact already in the store.
    let second = await service.beginSession(id: "conversation-2", workspaceOverride: "/tmp/proj")
    XCTAssertNotNil(second)
    XCTAssertTrue(
      second!.bootstrap.records.contains { $0.key.rawValue == "decisions/sync" })
    XCTAssertTrue(second!.isDurable)

    await service.recordTurn(
      session: first!, prompt: "how does sync work?", reply: "It uses the journal.")
    await service.recordTurn(
      session: first!, prompt: "and the budget?", reply: "Bytes, not items.")

    let turns = await journal.turns(session: first!.session.id, limit: 10, in: scope)
    XCTAssertEqual(turns.count, 2, "both turns of one conversation share one session")
    XCTAssertEqual(turns.first?.prompt, "and the budget?", "newest first, indexed in order")
    XCTAssertEqual(turns.first?.index, 1)

    // A later turn inside the same conversation keeps the session and the
    // journal continuous rather than splitting the transcript.
    let again = await service.beginSession(id: "anything", workspaceOverride: "/tmp/proj")
    XCTAssertEqual(again?.session.id, second?.session.id)
    await service.recordTurn(session: again!, prompt: "third", reply: "still one conversation")
    let all = await journal.allTurns(in: scope)
    XCTAssertEqual(all.count, 3)
    XCTAssertEqual(Set(all.map { $0.session }), [second!.session.id],
                   "every turn of the conversation lands under one journal session")
  }

  func testRecordedFactsSurviveIntoANewServiceOnTheSameStore() async {
    let store = InMemoryStore()
    let service = MemoryService(configuration: MemoryConfiguration(), durableStore: store)
    let first = await service.beginSession(id: "one", workspaceOverride: "/tmp/proj")
    await service.recordTurn(session: first!, prompt: "remember the town is Ashgrove",
                             reply: "Noted.")
    let scope = first!.scope
    let remembered = await service.recordedFacts(in: scope, limit: 10)
    XCTAssertTrue(remembered.isEmpty,
                  "journaling records a turn; only memory_set writes a fact")

    let tool = await service.execute(
      name: "memory_set",
      arguments: ["key": .string("setting/town"), "value": .string("Ashgrove")],
      in: first!)
    XCTAssertFalse(tool.isFailure)
    let after = await service.recordedFacts(in: scope, limit: 10)
    XCTAssertTrue(after.contains { $0.key.rawValue == "setting/town" && $0.value == "Ashgrove" })
  }

  func testDisabledConfigurationProducesNoSessionAndNoTools() async {
    let service = MemoryService(
      configuration: MemoryConfiguration(isEnabled: false))
    let session = await service.beginSession(id: "x", workspaceOverride: "/tmp/proj")
    XCTAssertNil(session)
    let defs = await service.toolDefinitions()
    XCTAssertTrue(defs.isEmpty)
    let enabled = await service.isEnabled
    XCTAssertFalse(enabled)
  }

  func testSummaryStatesEnabledState() {
    let on = MemoryConfiguration.fromEnvironment(["HOME": "/tmp"])
    XCTAssertTrue(on.summary.contains("memory enabled=true"))
    let off = MemoryConfiguration.fromEnvironment(["HOME": "/tmp", "TINYTITAN_MEMORY": "0"])
    XCTAssertTrue(off.summary.contains("memory enabled=false"))
  }

  /// The reason a memory file was never seen on disk was the opt-in flag
  /// plus directory overrides failing scope validation. A default launch
  /// from a project directory must end with a journal file on disk.
  func testDefaultSessionWritesAProjectFileOnDisk() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("turbo-agent-memory-\(UUID().uuidString)", isDirectory: true)
    let configuration = MemoryConfiguration.fromEnvironment([
      "HOME": "/tmp",
      "TINYTITAN_MEMORY_DIR": directory.path,
      "TINYTITAN_WORKSPACE_DIR": "/Users/someone/code/novel",
    ])
    XCTAssertTrue(configuration.isEnabled)
    let service = MemoryService(configuration: configuration)
    defer { Task { await service.shutDown() } }

    let session = await service.beginSession(
      id: "conversation-on-disk", workspaceOverride: "/Users/someone/code/novel")
    XCTAssertNotNil(session)
    await service.recordTurn(session: session!, prompt: "the town is Ashgrove",
                             reply: "Recorded.")

    let url = configuration.storage.journalURL(for: session!.scope)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                  "a default session must leave a project file on disk")
    let records = try FileJournal.read(contentsOf: url)
    XCTAssertTrue(records.contains {
      if case .event(let event) = $0, case .userPrompt = event.kind { return true }
      return false
    }, "the turn's prompt is in the journal")

    await service.shutDown()
    try? FileManager.default.removeItem(at: directory)
  }
}
