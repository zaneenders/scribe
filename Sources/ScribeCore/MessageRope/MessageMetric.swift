import ScribeLLM
import _RopeModule

public struct MessageMetric: RopeMetric {
  public typealias Element = Message

  public func size(of summary: MessageSummary) -> Int {
    summary.count
  }

  public func index(at offset: Int, in element: Message) -> Int {
    offset
  }
}
