import Chroma
import Foundation

/// Groups open and saved sessions by project. Selecting a saved session loads
/// it from ~/.scribe/sessions; open sessions continue running in memory.
struct SessionSidebar: Block {
  let store: ScribeMacStore
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0, alignment: .leading) {
      HStack(spacing: 6) {
        Text("PROJECTS")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
        Spacer()
        Interactive(id: WidgetID("sidebar-refresh"), action: { store.refreshSavedSessions() }) { phase in
          Text("R")
            .fontScale(theme.smallScale)
            .foregroundColor(phase == .idle ? theme.textSecondary : theme.textPrimary)
            .sizing(x: .fixed(24), y: .fixed(24))
            .background(phase == .idle ? .clear : theme.sidebarHover)
        }
        Interactive(id: WidgetID("sidebar-new"), action: { store.newSession() }) { phase in
          Text("+")
            .fontScale(theme.textScale)
            .foregroundColor(phase == .idle ? theme.textSecondary : theme.textPrimary)
            .sizing(x: .fixed(24), y: .fixed(24))
            .background(phase == .idle ? .clear : theme.sidebarHover)
        }
      }
      .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 6))
      .sizing(y: .fixed(40))
      .sizing(x: .grow)
      .border(theme.border)

      ScrollView(
        id: WidgetID("sidebar-project-scroll"),
        showsIndicator: true,
        controller: store.sidebarScroll
      ) {
        VStack(spacing: 1, alignment: .leading) {
          for project in store.projectSessions {
            ProjectHeader(
              store: store,
              project: project,
              theme: theme,
              isCollapsed: store.isProjectCollapsed(project.cwd))
            if !store.isProjectCollapsed(project.cwd) {
              for session in project.open {
                SessionRow(
                  store: store,
                  session: session,
                  theme: theme,
                  isActive: session.sessionId == store.activeSessionID)
              }
              for saved in project.saved {
                SavedSessionRow(store: store, saved: saved, theme: theme)
              }
              if project.canShowMore {
                ShowMoreSessionsRow(store: store, project: project, theme: theme)
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

          if store.projectSessions.isEmpty && store.pendingSessionCount == 0
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
    .sizing(x: .fixed(210))
    .sizing(y: .grow)
    .background(theme.sidebarBackground)
    .border(theme.border)
  }
}

struct ProjectHeader: Block {
  let store: ScribeMacStore
  let project: ScribeMacStore.ProjectSessions
  let theme: MacTheme
  let isCollapsed: Bool

  @MainActor var body: some Block {
    Interactive(
      id: WidgetID("project-toggle:\(project.cwd)"),
      action: { store.toggleProject(project.cwd) }
    ) { phase in
      HStack(spacing: 5) {
        Text(isCollapsed ? ">" : "v")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
        Text(sanitizeASCII(project.title))
          .fontScale(theme.smallScale)
          .foregroundColor(phase == .hovered ? theme.accent : theme.textPrimary)
        Spacer()
        Text("\(project.open.count + project.totalSavedCount)")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
      }
      .padding(EdgeInsets(top: 7, leading: 8, bottom: 5, trailing: 8))
      .sizing(x: .grow)
      .background(phase == .hovered ? theme.sidebarHover : .clear)
    }
  }
}

struct SessionRow: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme
  let isActive: Bool

  @MainActor var body: some Block {
    ZStack(alignment: .trailing) {
      Interactive(
        id: WidgetID("session-row:\(session.sessionId.uuidString)"),
        action: { store.switchTo(session.sessionId) }
      ) { phase in
        HStack(spacing: 5) {
          Text(session.isRunning ? "●" : "○")
            .fontScale(theme.smallScale)
            .foregroundColor(session.isRunning ? theme.yellow : theme.textSecondary)
          Text(session.sessionIdText)
            .fontScale(theme.smallScale)
            .foregroundColor(isActive || phase == .hovered ? theme.textPrimary : theme.textSecondary)
          Spacer()
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
    Interactive(
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
      .background(phase == .hovered ? theme.sidebarHover : .clear)
    }
  }
}

struct ShowMoreSessionsRow: Block {
  let store: ScribeMacStore
  let project: ScribeMacStore.ProjectSessions
  let theme: MacTheme

  @MainActor var body: some Block {
    Interactive(
      id: WidgetID("show-more-sessions:\(project.cwd)"),
      action: { store.showMoreSavedSessions(for: project.cwd) }
    ) { phase in
      HStack(spacing: 5) {
        Text("+")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.textSecondary)
        Text("Show 5 more")
          .fontScale(theme.smallScale)
          .foregroundColor(phase == .hovered ? theme.textPrimary : theme.textSecondary)
        Spacer()
        Text("\(project.hiddenSavedCount) older")
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
