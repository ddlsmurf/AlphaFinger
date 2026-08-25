/// "1 recording", "2 recordings".
///
/// Naive -- it appends an "s" -- but every noun this app counts is regular, and
/// "recording(s)" reads like a placeholder nobody went back and finished. In a
/// menu it looks unfinished; in a notification it looks broken.
public func counted(_ count: Int, _ noun: String) -> String {
  "\(count) \(noun)\(count == 1 ? "" : "s")"
}
