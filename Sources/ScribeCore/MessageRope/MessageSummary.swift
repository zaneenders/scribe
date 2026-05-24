import _RopeModule

// MARK: - MessageSummary

/// Count-based summary for chat messages.  Each message contributes 1.
public struct MessageSummary: RopeSummary {
  public var count: Int

  public static let maxNodeSize: Int = 32
  public static let zero: Self = MessageSummary(count: 0)

  public var isZero: Bool { count == 0 }

  public init(count: Int) { self.count = count }

  public mutating func add(_ other: Self) { count += other.count }
  public mutating func subtract(_ other: Self) { count -= other.count }
}
