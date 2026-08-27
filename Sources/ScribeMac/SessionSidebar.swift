import Chroma
import Foundation

/// Groups open and saved sessions by working directory. Selecting a saved
/// session loads it from ~/.scribe/sessions; open sessions keep running.
struct SessionSidebar: Block {
  let store: ScribeMacStore
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Button(
          "Folder", id: WidgetID("directory-toggle"), fontScale: theme.smallScale,
          padding: EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        ) { store.toggleDirectoryPicker() }
        Button(
          "Resume", id: WidgetID("resume-latest"), fontScale: theme.smallScale,
          padding: EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        ) { store.resumeLatest() }
        Spacer()
      }
      .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
      .sizing(y: .fixed(44))
      .sizing(x: .grow)
      .border(theme.border)

      HStack(spacing: 6) {
        Text("SESSIONS")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
        Spacer()
        Interactive(id: WidgetID("sidebar-refresh"), action: { store.refreshSavedSessions() }) { phase in
          Text("↻")
            .fontScale(theme.smallScale)
            .foregroundColor(phase == .idle ? theme.textSecondary : theme.textPrimary)
            .padding(EdgeInsets(top: 5, leading: 6.5, bottom: 5, trailing: 6.5))
            .sizing(x: .fixed(24), y: .fixed(24))
            .background(phase == .idle ? .clear : theme.sidebarHover)
        }
        Interactive(id: WidgetID("sidebar-close"), action: { store.closeSessionSidebar() }) { phase in
          Text("×")
            .fontScale(theme.textScale)
            .foregroundColor(phase == .idle ? theme.textSecondary : theme.textPrimary)
            .padding(EdgeInsets(top: 5, leading: 6.5, bottom: 5, trailing: 6.5))
            .sizing(x: .fixed(24), y: .fixed(24))
            .background(phase == .idle ? .clear : theme.sidebarHover)
        }
      }
      .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6))
      .sizing(y: .fixed(36))
      .sizing(x: .grow)
      .border(theme.border)

      ScrollView(
        id: WidgetID("sidebar-session-scroll"),
        showsIndicator: true,
        controller: store.sidebarScroll
      ) {
        VStack(spacing: 1) {
          for group in store.sessionGroups {
            SessionGroupHeader(
              store: store,
              group: group,
              theme: theme,
              isCollapsed: store.isGroupCollapsed(group.cwd))
            if !store.isGroupCollapsed(group.cwd) {
              for (_, entry) in group.entries.enumerated() {
                switch entry {
                case .open(let session):
                  SessionRow(
                    store: store,
                    session: session,
                    theme: theme,
                    isActive: session.sessionId == store.activeSessionID)
                case .saved(let saved):
                  SavedSessionRow(store: store, saved: saved, theme: theme)
                }
              }
              if group.canShowMore {
                ShowMoreSessionsRow(store: store, group: group, theme: theme)
              }
            }
          }

          if store.pendingSessionCount > 0 || store.isLoadingSavedSessions {
            HStack(spacing: 6) {
              Text("●").fontScale(theme.smallScale).foregroundColor(theme.yellow)
              Text(store.pendingSessionCount > 0 ? "Opening session..." : "Loading history...")
                .fontScale(theme.smallScale)
                .foregroundColor(theme.textSecondary)
            }
            .padding(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
          }

          if store.sessionGroups.isEmpty && store.pendingSessionCount == 0
            && !store.isLoadingSavedSessions
          {
            Text("No sessions found")
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textSecondary)
              .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
          }
        }
        .sizing(x: .grow)
      }
    }
    .sizing(x: .fixed(theme.sidebarWidth))
    .sizing(y: .grow)
    .background(theme.sidebarBackground)
    .border(theme.border)
  }
}

struct SessionGroupHeader: Block {
  let store: ScribeMacStore
  let group: ScribeMacStore.SessionGroup
  let theme: MacTheme
  let isCollapsed: Bool

  @MainActor var body: some Block {
    HStack(spacing: 0) {
      Interactive(
        id: WidgetID("group-toggle:\(group.cwd)"),
        action: { store.toggleGroup(group.cwd) }
      ) { phase in
        HStack(spacing: 5) {
          Text(isCollapsed ? ">" : "v")
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
          Text(sanitizeASCII(group.title))
            .fontScale(theme.smallScale)
            .foregroundColor(
              group.open.contains(where: \.isRunning)
                ? theme.purple : phase == .hovered ? theme.accent : theme.textPrimary)
          Spacer()
          Text("\(group.open.count + group.totalSavedCount)")
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
        }
        .padding(EdgeInsets(top: 7, leading: 8, bottom: 5, trailing: 4))
        .sizing(x: .grow)
        .background(phase == .hovered ? theme.sidebarHover : .clear)
      }
      Interactive(
        id: WidgetID("group-new-session:\(group.cwd)"),
        action: { store.newSession(in: group.cwd) }
      ) { phase in
        VStack(spacing: 0) {
          Spacer()
          HStack(spacing: 0) {
            Spacer()
            Text("+")
              .fontScale(theme.textScale)
              .foregroundColor(phase == .idle ? theme.textSecondary : theme.textPrimary)
            Spacer()
          }
          .sizing(x: .grow)
          Spacer()
        }
        .sizing(x: .fixed(28), y: .fixed(28))
        .background(phase == .idle ? .clear : theme.sidebarHover)
      }
      .padding(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 4))
    }
    .sizing(x: .grow)
  }
}

struct SessionRow: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme
  let isActive: Bool

  @MainActor var body: some Block {
    ZStack {
      Interactive(
        id: WidgetID("session-row:\(session.sessionId.uuidString)"),
        action: { store.switchTo(session.sessionId) }
      ) { phase in
        HStack(spacing: 5) {
          if session.isRunning {
            ActivitySpinner(color: theme.purple)
          } else {
            Text("○")
              .fontScale(theme.smallScale)
              .foregroundColor(theme.textSecondary)
          }
          Text(session.sessionIdText)
            .fontScale(theme.smallScale)
            .foregroundColor(
              session.isRunning
                ? theme.purple : isActive || phase == .hovered ? theme.textPrimary : theme.textSecondary)
          Spacer()
          Text(sanitizeASCII(session.modelName))
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
          if session.hasUnreadActivity && !isActive {
            Text("●").fontScale(theme.smallScale).foregroundColor(theme.accent)
          }
        }
        .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 28))
        .sizing(y: .fixed(30))
        .sizing(x: .grow)
        .background(isActive ? theme.sidebarSelection : phase == .hovered ? theme.sidebarHover : .clear)
        .border(isActive ? theme.accent : .clear, width: isActive ? 1 : 0)
      }
      Interactive(
        id: WidgetID("session-close:\(session.sessionId.uuidString)"),
        action: { store.closeSession(session.sessionId) }
      ) { phase in
        Text("×")
          .fontScale(theme.smallScale)
          .foregroundColor(phase == .idle ? theme.textSecondary : theme.textPrimary)
          .sizing(x: .fixed(24), y: .fixed(28))
          .background(phase == .idle ? .clear : theme.sidebarHover)
      }
      .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4))
    }
    .sizing(x: .grow)
  }
}

struct SavedSessionRow: Block {
  let store: ScribeMacStore
  let saved: ScribeMacStore.SavedSession
  let theme: MacTheme

  @MainActor var body: some Block {
    let isSelected = store.selectedSavedSession?.id == saved.id
    return Interactive(
      id: WidgetID("saved-session:\(saved.id.uuidString)"),
      action: { store.openSavedSession(saved) }
    ) { phase in
      HStack(spacing: 5) {
        Text("-")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
        Text(String(saved.id.uuidString.prefix(8)).uppercased())
          .fontScale(theme.smallScale)
          .foregroundColor(phase == .hovered ? theme.textPrimary : theme.textSecondary)
        Spacer()
        Text(sanitizeASCII(saved.metadata.model))
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
      }
      .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 8))
      .sizing(y: .fixed(30))
      .sizing(x: .grow)
      .background(isSelected ? theme.sidebarSelection : phase == .hovered ? theme.sidebarHover : .clear)
      .border(isSelected ? theme.accent : .clear, width: isSelected ? 1 : 0)
    }
  }
}

struct ShowMoreSessionsRow: Block {
  let store: ScribeMacStore
  let group: ScribeMacStore.SessionGroup
  let theme: MacTheme

  @MainActor var body: some Block {
    Interactive(
      id: WidgetID("show-more-sessions:\(group.cwd)"),
      action: { store.showMoreSavedSessions(for: group.cwd) }
    ) { phase in
      HStack(spacing: 5) {
        Text("+")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
        Text("Show 5 more")
          .fontScale(theme.smallScale)
          .foregroundColor(phase == .hovered ? theme.textPrimary : theme.textSecondary)
        Spacer()
        Text("\(group.hiddenSavedCount) older")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
      }
      .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 8))
      .sizing(y: .fixed(30))
      .sizing(x: .grow)
      .background(phase == .hovered ? theme.sidebarHover : .clear)
    }
  }
}
