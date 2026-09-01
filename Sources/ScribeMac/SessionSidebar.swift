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
    HStack(spacing: 4) {
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
    Interactive(
      id: WidgetID("session-row:\(session.sessionId.uuidString)"),
      action: { store.switchTo(session.sessionId) }
    ) { phase in
      HStack(spacing: 5) {
        if session.isRunning {
          ActivitySpinner(color: theme.purple)
        }
        MarqueeText(
          sanitizeASCII(session.displayName),
          id: WidgetID("session-name:\(session.sessionId.uuidString)"),
          color: session.isRunning
            ? theme.purple
            : isActive || phase == .hovered ? theme.textPrimary : theme.textSecondary,
          scale: theme.smallScale,
          isScrolling: phase == .hovered
        )
        if phase != .hovered {
          if session.hasUnreadActivity && !isActive {
            Text("●").fontScale(theme.smallScale).foregroundColor(theme.accent)
          }
          Text(sanitizeASCII(session.modelName))
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
        }
        // Keep actions in place while previewing the name so moving the pointer
        // toward one cannot make its hit target disappear.
        sessionActions(store: store, id: session.sessionId, pinned: session.isPinned, theme: theme)
      }
      .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 6))
      .sizing(y: .fixed(30))
      .sizing(x: .grow)
      .background(isActive ? theme.sidebarSelection : phase == .hovered ? theme.sidebarHover : .clear)
      .border(isActive ? theme.accent : .clear, width: isActive ? 1 : 0)
    }
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
        MarqueeText(
          sanitizeASCII(saved.metadata.displayName),
          id: WidgetID("saved-session-name:\(saved.id.uuidString)"),
          color: phase == .hovered ? theme.textPrimary : theme.textSecondary,
          scale: theme.smallScale,
          isScrolling: phase == .hovered
        )
        if phase != .hovered {
          Text(sanitizeASCII(saved.metadata.model))
            .fontScale(theme.smallScale)
            .foregroundColor(theme.textSecondary)
        }
        sessionActions(
          store: store, id: saved.id, pinned: saved.metadata.isPinned, theme: theme)
      }
      .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 8))
      .sizing(y: .fixed(30))
      .sizing(x: .grow)
      .background(isSelected ? theme.sidebarSelection : phase == .hovered ? theme.sidebarHover : .clear)
      .border(isSelected ? theme.accent : .clear, width: isSelected ? 1 : 0)
    }
  }
}

/// A single-line label that scrolls only when hovered and wider than its slot.
/// The pause at each end keeps short names still and makes long names readable.
@MainActor
private final class MarqueeAnimationState {
  static let shared = MarqueeAnimationState()
  private var startTimes: [WidgetID: TimeInterval] = [:]

  func elapsed(for id: WidgetID, scrolling: Bool, now: TimeInterval) -> TimeInterval {
    guard scrolling else {
      startTimes[id] = nil
      return 0
    }
    let start = startTimes[id] ?? now
    startTimes[id] = start
    return now - start
  }
}

private struct MarqueeText: PrimitiveBlock {
  let text: String
  let id: WidgetID
  let color: Color
  let scale: Float
  let isScrolling: Bool

  private let pointsPerSecond: Float = 28
  private let endPause: TimeInterval = 0.8

  init(_ text: String, id: WidgetID, color: Color, scale: Float, isScrolling: Bool) {
    self.text = text
    self.id = id
    self.color = color
    self.scale = scale
    self.isScrolling = isScrolling
  }

  @MainActor var expandsHorizontally: Bool { true }

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    let measured = context.fontMetrics.measure(text, scale: scale * context.textScale)
    return Size(width: proposal.width, height: measured.height)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let effectiveScale = scale * context.textScale
    let textWidth = context.fontMetrics.measure(text, scale: effectiveScale).width
    let shouldScroll = isScrolling && textWidth > rect.size.width
    let animationElapsed = MarqueeAnimationState.shared.elapsed(
      for: id, scrolling: shouldScroll, now: Date().timeIntervalSinceReferenceDate)
    var offset: Float = 0

    if shouldScroll {
      let distance = textWidth - rect.size.width
      let travelDuration = TimeInterval(distance / pointsPerSecond)
      let cycleDuration = endPause * 2 + travelDuration * 2
      let elapsed = animationElapsed.truncatingRemainder(dividingBy: cycleDuration)

      switch elapsed {
      case ..<endPause:
        offset = 0
      case ..<(endPause + travelDuration):
        offset = Float(elapsed - endPause) * pointsPerSecond
      case ..<(endPause * 2 + travelDuration):
        offset = distance
      default:
        offset = distance - Float(elapsed - endPause * 2 - travelDuration) * pointsPerSecond
      }
      context.requestRedraw()
    }

    drawList.pushClip(rect)
    drawList.text(
      text, at: Point(x: rect.minX - offset, y: rect.minY), color: color, scale: effectiveScale)
    drawList.popClip()
  }
}

@MainActor
private func sessionActions(
  store: ScribeMacStore, id: UUID, pinned: Bool, theme: MacTheme
) -> some Block {
  HStack(spacing: 2) {
    Interactive(
      id: WidgetID("session-pin:\(id.uuidString)"),
      action: { store.toggleSessionPin(id) }
    ) { phase in
      Text(pinned ? "◆" : "◇")
        .fontScale(theme.smallScale)
        .foregroundColor(pinned ? theme.yellow : theme.orange)
        .sizing(x: .fixed(24), y: .fixed(24))
        .background(phase == .idle ? .clear : theme.sidebarHover)
    }
    Interactive(
      id: WidgetID("session-rename:\(id.uuidString)"),
      action: { store.renameSession(id) }
    ) { phase in
      Text("✎")
        .fontScale(theme.smallScale)
        .foregroundColor(phase == .idle ? theme.green : theme.textPrimary)
        .sizing(x: .fixed(24), y: .fixed(24))
        .background(phase == .idle ? .clear : theme.sidebarHover)
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
