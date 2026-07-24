import Foundation

struct SlackWorkspace: Equatable, Sendable {
  let id: String
  let name: String
  let domain: String?
}

struct SlackWorkspaceSelection: Sendable {
  let workspaces: [SlackWorkspace]
  let selectedWorkspaceID: String?
}

enum SlackWorkspaceDiscovery {
  static func load() -> SlackWorkspaceSelection {
    let stateURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Slack/storage/root-state.json")
    guard
      let data = try? Data(contentsOf: stateURL),
      let state = try? JSONDecoder().decode(SlackDesktopState.self, from: data)
    else {
      return SlackWorkspaceSelection(workspaces: [], selectedWorkspaceID: nil)
    }

    let workspaces = state.workspaces.values
      .map {
        SlackWorkspace(id: $0.id, name: $0.name, domain: $0.domain)
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    return SlackWorkspaceSelection(
      workspaces: workspaces,
      selectedWorkspaceID: state.workspacesMeta?.selectedWorkspaceID
    )
  }
}

private struct SlackDesktopState: Decodable {
  struct Workspace: Decodable {
    let id: String
    let name: String
    let domain: String?
  }

  struct WorkspacesMeta: Decodable {
    let selectedWorkspaceID: String?

    enum CodingKeys: String, CodingKey {
      case selectedWorkspaceID = "selectedWorkspaceId"
    }
  }

  let workspaces: [String: Workspace]
  let workspacesMeta: WorkspacesMeta?
}
