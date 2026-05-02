import Foundation
import SlateCore

/// Usage panel rendered as CSI strings from Slate ``CSI`` and ``ScribePalette`` RGB.
enum UsageBanner {
  static func line(
    promptTokens: Int?,
    completionTokens: Int?,
    totalTokens: Int?,
    outputTokensPerSecond: Double? = nil
  ) -> String? {
    guard promptTokens != nil || completionTokens != nil || totalTokens != nil else {
      return nil
    }
    let inStr = promptTokens.map(String.init) ?? "—"
    let outStr = completionTokens.map(String.init) ?? "—"
    let sumStr = totalTokens.map(String.init) ?? "—"
    let rateStr = outputTokensPerSecond.map { String(format: "%.1f", $0) + " out/s" }

    let innerVisible =
      "◆ \(inStr) in  ·  \(outStr) out"
      + (rateStr.map { "  ·  \($0)" } ?? "")
      + "  ·  \(sumStr) Σ ◆"
    let targetWidth = max(innerVisible.count + 10, 54)
    let sidePad = max(0, targetWidth - innerVisible.count)
    let padL = sidePad / 2
    let padR = sidePad - padL

    let uBg = ScribePalette.usageBg
    let railBg = ScribePalette.usageRail
    let m = ScribePalette.usageMuted
    let ni = ScribePalette.usageInOut
    let no = ScribePalette.usageInOut
    let ns = ScribePalette.usageSum
    let x = CSI.sgr0

    func pair(_ bg: TerminalRGB, _ fg: TerminalRGB) -> String {
      CSI.sgrTruecolor(background: bg, foreground: fg)
    }

    let railRow =
      "  \(pair(railBg, m))" + String(repeating: "·", count: targetWidth) + "\(x)"
    let midInner =
      "\(pair(uBg, m))◆ \(pair(uBg, ni))\(inStr)\(pair(uBg, m)) in  ·  \(pair(uBg, no))\(outStr)\(pair(uBg, m)) out"
      + (rateStr.map { "  ·  \(pair(uBg, no))\($0)\(pair(uBg, m))" } ?? "")
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
