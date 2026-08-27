import Chroma
import Foundation

/// An eight-dot activity indicator drawn with Chroma primitives so it does not
/// depend on the Metal backend's ASCII-only bitmap font.
struct ActivitySpinner: PrimitiveBlock {
  let color: Color

  private let diameter: Float = 11
  private let dotDiameter: Float = 2.2
  private let dotCount = 8

  @MainActor func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size {
    Size(width: diameter, height: diameter)
  }

  @MainActor func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    let center = Point(x: rect.minX + diameter / 2, y: rect.minY + rect.size.height / 2)
    let orbitRadius = (diameter - dotDiameter) / 2
    let head = Int(Date().timeIntervalSinceReferenceDate * 11) % dotCount

    for index in 0..<dotCount {
      let angle = Float(index) * 2 * .pi / Float(dotCount) - .pi / 2
      let age = (head - index + dotCount) % dotCount
      let opacity = max(0.18, 1 - Float(age) * 0.12)
      let dotColor = Color(r: color.r, g: color.g, b: color.b, a: color.a * opacity)
      let x = center.x + cos(angle) * orbitRadius - dotDiameter / 2
      let y = center.y + sin(angle) * orbitRadius - dotDiameter / 2
      drawList.fillRoundedRect(
        Rect(x: x, y: y, width: dotDiameter, height: dotDiameter),
        radius: dotDiameter / 2,
        color: dotColor)
    }
  }
}
