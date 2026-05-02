import Foundation
import ScribeCore
import ScribeLLM
import SlateCore

/// Usage panel rendered as CSI strings from Slate ``CSI`` and ``ScribePalette`` RGB.
enum UsageBanner {
  static func line(
    usage: Components.Schemas.CompletionUsage,
    outputTokensPerSecond: Double? = nil
  ) -> String? {
    guard let triple = usage.scribeReportedPromptCompletionTotal else {
      return nil
    }
    let inStr = ScribeUsageFormatting.groupingInt(triple.prompt)
    let outStr = ScribeUsageFormatting.groupingInt(triple.completion)
    let sumStr = ScribeUsageFormatting.groupingInt(triple.total)
    let rateStr = outputTokensPerSecond.map { String(format: "%.1f", $0) + " out/s" }

    var detailParts: [String] = []
    if let r = usage.completionTokensDetails?.reasoningTokens, r > 0 {
      detailParts.append("reasoning \(ScribeUsageFormatting.groupingInt(r))")
    }
    if let cached = usage.promptTokensDetails?.cachedTokens, cached > 0 {
      detailParts.append("cache \(ScribeUsageFormatting.groupingInt(cached))")
    }
    let detailSuffix = detailParts.isEmpty ? "" : "  ·  " + detailParts.joined(separator: "  ·  ")

    let innerVisible =
      "◆ \(inStr) in  ·  \(outStr) out"
      + (rateStr.map { "  ·  \($0)" } ?? "")
      + detailSuffix
      + "  ·  \(sumStr) Σ ◆"
    let targetWidth = max(innerVisible.count + 10, 54)
    let sidePad = max(0, targetWidth - innerVisible.count)
    let padL = sidePad / 2
    let padR = sidePad - padL

    let uBg = ScribePalette.usageBg
    let railBg = ScribePalette.usageRail
    let m = ScribePalette.usageMuted
    let ni = ScribePalette.usagePrompt
    let no = ScribePalette.usageCompletion
    let ns = ScribePalette.usageTurnSum
    let x = CSI.sgr0

    func pair(_ bg: TerminalRGB, _ fg: TerminalRGB) -> String {
      CSI.sgrTruecolor(background: bg, foreground: fg)
    }

    let railRow =
      "  \(pair(railBg, m))" + String(repeating: "·", count: targetWidth) + "\(x)"
    let midInner =
      "\(pair(uBg, m))◆ \(pair(uBg, ni))\(inStr)\(pair(uBg, m)) in  ·  \(pair(uBg, no))\(outStr)\(pair(uBg, m)) out"
      + (rateStr.map { "  ·  \(pair(uBg, no))\($0)\(pair(uBg, m))" } ?? "")
      + (detailSuffix.isEmpty ? "" : "\(pair(uBg, m))\(detailSuffix)")
      + "  ·  \(CSI.sgrBold)\(pair(uBg, ns))\(sumStr)"
      + "\(CSI.sgrNormalIntensity)\(pair(uBg, m)) Σ ◆"

    let padTint = pair(uBg, uBg)
    let midRow =
      "  \(padTint)" + String(repeating: " ", count: padL)
      + midInner
      + String(repeating: " ", count: padR)
      + "\(x)"

    return "\n\(railRow)\n\(midRow)\n\(railRow)"
  }
}
