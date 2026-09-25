import Chroma
import Foundation

struct SessionSidebar: Block {
  let store: ScribeMacStore
  let theme: MacTheme

  @MainActor var body: some Block {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Button(
          "Folder", fontScale: theme.smallScale,
          style: theme.buttonStyle(tint: theme.peach),
          padding: EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        ) { store.toggleDirectoryPicker() }
        Button(
          "Resume", fontScale: theme.smallScale,
          style: theme.buttonStyle(tint: theme.green),
          padding: EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        ) { store.resumeLatest() }
        Spacer()
      }
      .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
      .sizing(y: .fixed(44))
      .sizing(x: .grow)
      .border(theme.chromeBorder ?? theme.border)

      HStack(spacing: 6) {
        Text("SESSIONS")
          .fontScale(theme.smallScale)
          .foregroundColor(theme.sidebarHeading ?? theme.textSecondary)
        Spacer()
        Interactive(action: { store.refreshSavedSessions() }) { phase in
          Text("↻")
            .fontScale(theme.smallScale)
            .foregroundColor(phase == .idle ? (theme.refreshColor ?? theme.textSecondary) : theme.textPrimary)
            .padding(EdgeInsets(top: 5, leading: 6.5, bottom: 5, trailing: 6.5))
            .sizing(x: .fixed(24), y: .fixed(24))
            .background(phase == .idle ? .clear : theme.sidebarHover)
        }
        Interactive(action: { store.closeSessionSidebar() }) { phase in
          Text("×")
            .fontScale(theme.textScale)
            .foregroundColor(phase == .idle ? (theme.closeColor ?? theme.textSecondary) : theme.textPrimary)
            .padding(EdgeInsets(top: 5, leading: 6.5, bottom: 5, trailing: 6.5))
            .sizing(x: .fixed(24), y: .fixed(24))
            .background(phase == .idle ? .clear : theme.sidebarHover)
        }
      }
      .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6))
      .sizing(y: .fixed(36))
      .sizing(x: .grow)
      .border(theme.chromeBorder ?? theme.border)

      ScrollView(
        showsIndicator: true,
        controller: store.sidebarScroll
      ) {
        VStack(spacing: 1) {
          ForEach(store.sessionGroups) { group in
            SessionGroupHeader(
              store: store,
              group: group,
              theme: theme,
              isCollapsed: store.isGroupCollapsed(group.cwd))
            if !store.isGroupCollapsed(group.cwd) {
              ForEach(group.entries, id: \.id) { entry in
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
    .padding(theme.sidebarPadding)
    .sizing(x: .fixed(theme.sidebarWidth))
    .sizing(y: .grow)
    .background(theme.sidebarBackground)
    .border(theme.chromeBorder ?? theme.border)
  }
}

struct SessionGroupHeader: Block {
  let store: ScribeMacStore
  let group: ScribeMacStore.SessionGroup
  let theme: MacTheme
  let isCollapsed: Bool

  @MainActor var body: some Block {
    ScribeSessionGroup(
      id: "group-name:\(group.cwd)", title: sanitizeASCII(group.title),
      count: group.open.count + group.totalSavedCount, isCollapsed: isCollapsed,
      style: theme.sessionGroupStyle ?? ScribeSessionGroupStyle(
        foreground: group.open.contains(where: \.isRunning)
          ? theme.purple : theme.textPrimary,
        hoveredForeground: theme.accent,
        count: theme.textSecondary,
        newSession: theme.textSecondary,
        hoverBackground: theme.sidebarHover, fontScale: theme.smallScale),
      onToggle: { store.toggleGroup(group.cwd) },
      onNewSession: { store.newSession(in: group.cwd) })
  }
}

struct SessionRow: Block {
  let store: ScribeMacStore
  let session: SessionController
  let theme: MacTheme
  let isActive: Bool

  @MainActor var body: some Block {
    HStack(spacing: 5) {
      ScribeSessionRow(
        id: "session-name:\(session.sessionId)", title: sanitizeASCII(session.displayName),
        subtitle: sanitizeASCII(session.modelName), isSelected: isActive,
        isRunning: session.isRunning, isUnread: session.hasUnreadActivity,
        style: sessionRowStyle(theme), onSelect: { store.switchTo(session.sessionId) })
      sessionActions(store: store, id: session.sessionId, pinned: session.isPinned, theme: theme)
    }.sizing(x: .grow)
  }
}

private func sessionRowStyle(_ theme: MacTheme) -> ScribeSessionRowStyle {
  theme.sessionRowStyle ?? ScribeSessionRowStyle(
    foreground: theme.textSecondary,
    secondaryForeground: theme.textSecondary,
    selectedForeground: theme.textPrimary, activity: theme.purple,
    selection: theme.sidebarSelection, hover: theme.sidebarHover, border: theme.accent,
    fontScale: theme.smallScale)
}

struct SavedSessionRow: Block {
  let store: ScribeMacStore
  let saved: ScribeMacStore.SavedSession
  let theme: MacTheme

  @MainActor var body: some Block {
    let isSelected = store.selectedSavedSession?.id == saved.id
    return HStack(spacing: 5) {
      ScribeSessionRow(
        id: "saved-session-name:\(saved.id)", title: sanitizeASCII(saved.metadata.displayName),
        subtitle: sanitizeASCII(saved.metadata.model), isSelected: isSelected,
        style: sessionRowStyle(theme), onSelect: { store.openSavedSession(saved) })
      sessionActions(store: store, id: saved.id, pinned: saved.metadata.isPinned, theme: theme)
    }.sizing(x: .grow)
  }
}

@MainActor
private final class MarqueeAnimationState {
  static let shared = MarqueeAnimationState()
  private var startTimes: [String: TimeInterval] = [:]

  func elapsed(for id: String, scrolling: Bool, now: TimeInterval) -> TimeInterval {
    guard scrolling else {
      startTimes[id] = nil
      return 0
    }
    let start = startTimes[id] ?? now
    startTimes[id] = start
    return now - start
  }
}

struct MarqueeText: PrimitiveBlock {
  let text: String
  let id: String
  let color: Color
  let scale: Float
  let isScrolling: Bool

  private let pointsPerSecond: Float = 28
  private let endPause: TimeInterval = 0.8

  init(_ text: String, id: String, color: Color, scale: Float, isScrolling: Bool) {
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
      action: { store.toggleSessionPin(id) }
    ) { phase in
      Text(pinned ? "◆" : "◇")
        .fontScale(theme.smallScale)
        .foregroundColor(pinned ? theme.yellow : theme.orange)
        .sizing(x: .fixed(24), y: .fixed(24))
        .background(phase == .idle ? .clear : theme.sidebarHover)
    }
    Interactive(
      action: { store.renameSession(id) }
    ) { phase in
      Text("✎")
        .fontScale(theme.smallScale)
        .foregroundColor(phase == .idle ? (theme.renameColor ?? theme.green) : theme.textPrimary)
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
      action: { store.showMoreSavedSessions(for: group.cwd) },
      content: { phase in
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
    )
  }
}
