/// Keyboard focus inside a Windows 95 dialog. Tab walks every control, arrows walk the push
/// buttons, and a focused push button is the one Return presses (it takes the thick default
/// border); with focus elsewhere Return presses the dialog's default button.
public struct DialogFocus: Equatable, Sendable {
    public enum Control: Hashable, Sendable {
        case button(String)
        case field(String)
        case checkbox(String)
        case radio(String)
    }

    public let controls: [Control]
    public let defaultButton: String?
    public let cancelButton: String?
    public private(set) var index: Int

    public init(controls: [Control], defaultButton: String?, cancelButton: String?, initial: Control? = nil) {
        self.controls = controls
        self.defaultButton = defaultButton
        self.cancelButton = cancelButton
        let wanted = initial ?? defaultButton.map(Control.button)
        index = wanted.flatMap { controls.firstIndex(of: $0) } ?? 0
    }

    public var focused: Control? { controls.indices.contains(index) ? controls[index] : nil }

    /// The button drawn with the extra black border and pressed by Return.
    public var effectiveDefault: String? {
        if case let .button(id) = focused { return id }
        return defaultButton
    }

    public mutating func tab(backward: Bool = false) {
        guard !controls.isEmpty else { return }
        index = (index + (backward ? controls.count - 1 : 1)) % controls.count
    }

    /// Arrow keys move between push buttons only while one has focus. Returns false when the
    /// arrow belongs to the focused control (a text field moves its caret).
    @discardableResult
    public mutating func arrow(forward: Bool) -> Bool {
        guard case .button = focused else { return false }
        let buttons = controls.indices.filter { if case .button = controls[$0] { true } else { false } }
        guard let at = buttons.firstIndex(of: index) else { return false }
        index = buttons[(at + (forward ? 1 : buttons.count - 1)) % buttons.count]
        return true
    }

    public mutating func focus(_ control: Control) {
        if let i = controls.firstIndex(of: control) { index = i }
    }
}
