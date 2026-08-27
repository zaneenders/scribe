import Foundation
import ScribeCore

extension ScribeUsage {

  public var scribeReportedPromptCompletionTotal: (prompt: Int, completion: Int, total: Int)? {
    let p = promptTokens ?? 0
    let c = completionTokens ?? 0
    let statedTotal = totalTokens ?? 0
    let t = statedTotal > 0 ? statedTotal : (p + c > 0 ? p + c : 0)
    guard p > 0 || c > 0 || t > 0 else { return nil }
    return (p, c, t)
  }
}
