#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// The Index01 ring, drawn as a path.
///
/// One silhouette for every state: a stroked band with the button seated at
/// twelve o'clock. Only the band's dash pattern and the mark inside it change, so
/// the icon stays recognisably the same object as it moves between states.
///
/// The button's seating is the one measurement that matters. Its base sits at
/// `y = 7.4`, where the band is 3.46 wide against the button's 3.4 half-width;
/// any higher and the bottom corners overhang into empty space, which is what
/// made the first draft look like a tab floating above a circle rather than a
/// part of the ring.
public enum RingGlyph {
  /// Everything below is expressed in this square, then scaled to whatever size
  /// is being drawn.
  public static let viewBox: CGFloat = 24

  public static let bandCentre = CGPoint(x: 12, y: 13.6)
  public static let bandRadius: CGFloat = 7.1
  public static let bandWidth: CGFloat = 1.7
  public static let button = CGRect(x: 8.6, y: 3.2, width: 6.8, height: 4.2)
  public static let buttonCornerRadius: CGFloat = 1.2

  /// How the band is drawn, which is what carries the state.
  public enum Band: Sendable {
    case solid
    case dashed
    case dotted

    var dashes: [CGFloat]? {
      switch self {
      case .solid: return nil
      case .dashed: return [2.6, 2.4]
      case .dotted: return [0.1, 2.9]
      }
    }

    var roundCaps: Bool { self == .dotted }
  }

  /// What sits inside the band.
  public enum Mark: Sendable {
    case none
    case dot
    case filled
    case downArrow
    case slash
    case exclamation
  }

  /// Draws the glyph filling `size`, in the current fill colour.
  ///
  /// Expects a context whose origin is top-left with y increasing downwards, so
  /// the numbers above read the same as the drawing they came from.
  public static func draw(band: Band, mark: Mark, in context: CGContext,
                          size: CGSize) {
    let scale = min(size.width, size.height) / viewBox
    context.saveGState()
    context.translateBy(x: (size.width - viewBox * scale) / 2,
                        y: (size.height - viewBox * scale) / 2)
    context.scaleBy(x: scale, y: scale)

    context.setLineWidth(bandWidth)
    context.setLineCap(band.roundCaps ? .round : .butt)
    if let dashes = band.dashes {
      context.setLineDash(phase: 0, lengths: dashes)
    }
    context.addArc(center: bandCentre, radius: bandRadius,
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])

    let buttonPath = CGPath(roundedRect: button,
                            cornerWidth: buttonCornerRadius,
                            cornerHeight: buttonCornerRadius, transform: nil)
    context.addPath(buttonPath)
    context.fillPath()

    drawMark(mark, in: context)
    context.restoreGState()
  }

  private static func drawMark(_ mark: Mark, in context: CGContext) {
    let centre = bandCentre
    context.setLineWidth(bandWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    switch mark {
    case .none:
      break
    case .dot:
      context.addEllipse(in: CGRect(x: centre.x - 2, y: centre.y - 2,
                                    width: 4, height: 4))
      context.fillPath()
    case .filled:
      context.addEllipse(in: CGRect(x: centre.x - 3.5, y: centre.y - 3.5,
                                    width: 7, height: 7))
      context.fillPath()
    case .downArrow:
      context.move(to: CGPoint(x: 12, y: 10.1))
      context.addLine(to: CGPoint(x: 12, y: 16.4))
      context.strokePath()
      context.move(to: CGPoint(x: 9.4, y: 13.9))
      context.addLine(to: CGPoint(x: 12, y: 16.6))
      context.addLine(to: CGPoint(x: 14.6, y: 13.9))
      context.strokePath()
    case .slash:
      context.move(to: CGPoint(x: 7.4, y: 18.6))
      context.addLine(to: CGPoint(x: 16.6, y: 8.6))
      context.strokePath()
    case .exclamation:
      context.move(to: CGPoint(x: 12, y: 10.2))
      context.addLine(to: CGPoint(x: 12, y: 14.4))
      context.strokePath()
      context.addEllipse(in: CGRect(x: 12 - 1.05, y: 17 - 1.05,
                                    width: 2.1, height: 2.1))
      context.fillPath()
    }
  }
}
#endif
