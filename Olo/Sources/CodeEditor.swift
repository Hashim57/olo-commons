import AppKit
import SwiftUI
import OloKit

/// Colours and the font of Build with Olo's editor. System colours, so dark mode just works.
enum EditorTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    static func color(_ kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPink
        case .string: return .systemRed
        case .comment: return .systemGray
        case .number: return .systemBlue
        }
    }

    static func severity(_ severity: String) -> NSColor {
        switch severity {
        case "error": return .systemRed
        case "warning": return .systemOrange
        default: return .systemBlue
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }
}

/// Shows one document's editor. Each open file keeps its own text view (and with it its own
/// undo history); switching tabs swaps which one this view hosts.
struct CodeEditor: NSViewRepresentable {
    let controller: CodeTextController

    func makeNSView(context: Context) -> EditorHostView {
        let host = EditorHostView()
        host.show(controller)
        return host
    }

    func updateNSView(_ host: EditorHostView, context: Context) {
        host.show(controller)
    }
}

final class EditorHostView: NSView {
    private weak var shown: CodeTextController?

    func show(_ controller: CodeTextController) {
        guard shown !== controller || controller.scrollView.superview !== self else { return }
        for v in subviews { v.removeFromSuperview() }
        let scroll = controller.scrollView
        scroll.removeFromSuperview()
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        shown = controller
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shown === controller else { return }
            self.window?.makeFirstResponder(controller.textView)
        }
    }
}

/// The AppKit side of one open file: an NSTextView with a line number gutter, syntax colours,
/// issue markers, auto-indent and ghost text for Olo's suggestions. Temporary attributes carry
/// the colours and underlines, so the text itself stays plain and the undo history only ever
/// holds the developer's (and accepted) edits.
@MainActor
final class CodeTextController: NSObject, NSTextViewDelegate {
    static let highlightLimit = 200_000

    let scrollView: NSScrollView
    let textView: CodeTextView
    let ruler: LineNumberRuler
    let undo = UndoManager()
    let path: String
    let language: String
    let indentUnit: String

    /// Every change to the text, typed or applied.
    var onTextChange: ((String) -> Void)?
    /// The cursor's line and column (1-based).
    var onCaretChange: ((Int, Int) -> Void)?

    /// UTF-16 offsets where each line starts; lineStarts[0] is 0.
    private(set) var lineStarts: [Int] = [0]
    /// The most severe issue on each line (1-based).
    private(set) var issuesByLine: [Int: CodeIssue] = [:]
    private var highlightTask: Task<Void, Never>?
    private var highlightGeneration = 0

    init(path: String, text: String) {
        self.path = path
        self.language = CodeLanguage.detect(path)
        self.indentUnit = CodeIndent.unit(for: path)
        let scroll = CodeTextView.scrollableTextView()
        let tv: CodeTextView
        if let made = scroll.documentView as? CodeTextView {
            tv = made
        } else {
            tv = CodeTextController.makeTextView(in: scroll)
        }
        self.scrollView = scroll
        self.textView = tv
        self.ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        super.init()
        configure(text)
    }

    /// Used only if scrollableTextView() hands back a plain NSTextView.
    private static func makeTextView(in scroll: NSScrollView) -> CodeTextView {
        let size = scroll.contentSize
        let tv = CodeTextView(frame: NSRect(origin: .zero, size: size))
        tv.minSize = NSSize(width: 0, height: size.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        return tv
    }

    private func configure(_ text: String) {
        let tv = textView
        // TextKit 1: the gutter, the temporary attributes and the ghost text use the layout manager.
        _ = tv.layoutManager
        tv.controller = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = EditorTheme.font
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.typingAttributes = EditorTheme.baseAttributes
        tv.string = text
        tv.textStorage?.setAttributes(EditorTheme.baseAttributes, range: NSRange(location: 0, length: (text as NSString).length))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.delegate = self

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        ruler.controller = self
        ruler.clientView = tv
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        tv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: NSView.frameDidChangeNotification, object: tv)

        recomputeLineStarts()
        scheduleHighlight()
    }

    @objc private func viewMoved(_ note: Notification) {
        ruler.needsDisplay = true
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
        recomputeLineStarts()
        onTextChange?(textView.string)
        applyIssueUnderlines()
        scheduleHighlight()
        ruler.needsDisplay = true
        // The selection notice can come before this one, while the line starts were out of date.
        reportCaret()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.needsDisplay = true
        let sel = textView.selectedRange()
        if textView.ghost != nil && (sel.length > 0 || sel.location != textView.ghostLocation) {
            textView.clearGhost()
        }
        reportCaret()
    }

    private func reportCaret() {
        let location = min(textView.selectedRange().location, (textView.string as NSString).length)
        let line = lineNumber(at: location)
        onCaretChange?(line, max(1, location - lineStarts[line - 1] + 1))
    }

    // MARK: Lines

    private func recomputeLineStarts() {
        let ns = textView.string as NSString
        let length = ns.length
        var starts = [0]
        if length > 0 {
            var buffer = [unichar](repeating: 0, count: length)
            ns.getCharacters(&buffer, range: NSRange(location: 0, length: length))
            for i in 0..<length where buffer[i] == 10 { starts.append(i + 1) }
        }
        lineStarts = starts
        let digits = CGFloat(max(3, String(starts.count).count))
        let width = digits * 7 + 22
        if abs(ruler.ruleThickness - width) > 0.5 { ruler.ruleThickness = width }
    }

    /// The 1-based line holding the UTF-16 offset.
    func lineNumber(at location: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// Line `line` (1-based) without its line ending.
    func lineRange(_ line: Int) -> NSRange {
        guard line >= 1, line <= lineStarts.count else { return NSRange(location: NSNotFound, length: 0) }
        let ns = textView.string as NSString
        let start = lineStarts[line - 1]
        var end = line < lineStarts.count ? lineStarts[line] : ns.length
        while end > start {
            let c = ns.character(at: end - 1)
            if c == 10 || c == 13 { end -= 1 } else { break }
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Issues

    func setIssues(_ issues: [CodeIssue]) {
        var byLine: [Int: CodeIssue] = [:]
        for issue in issues {
            let low = max(1, issue.line)
            let high = min(max(low, issue.endLine), lineStarts.count)
            guard low <= high else { continue }
            for n in low...high {
                if let existing = byLine[n], existing.severityRank <= issue.severityRank { continue }
                byLine[n] = issue
            }
        }
        issuesByLine = byLine
        applyIssueUnderlines()
        ruler.needsDisplay = true
    }

    private func applyIssueUnderlines() {
        guard let lm = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
        for (line, issue) in issuesByLine {
            var r = lineRange(line)
            guard r.location != NSNotFound else { continue }
            // Underline the code, not the indentation.
            let ns = textView.string as NSString
            while r.length > 0 {
                let c = ns.character(at: r.location)
                guard c == 32 || c == 9 else { break }
                r.location += 1
                r.length -= 1
            }
            guard r.length > 0 else { continue }
            lm.addTemporaryAttributes([.underlineStyle: style, .underlineColor: EditorTheme.severity(issue.severity)], forCharacterRange: r)
        }
    }

    /// The tooltip for a point in the text view: the issue on that line, if any.
    func issueMessage(at point: NSPoint) -> String? {
        guard !issuesByLine.isEmpty else { return nil }
        let index = textView.characterIndexForInsertion(at: point)
        guard let issue = issuesByLine[lineNumber(at: index)] else { return nil }
        return "\(issue.severity.capitalized), \(issue.category): \(issue.message)"
    }

    // MARK: Syntax colours

    private func scheduleHighlight() {
        highlightTask?.cancel()
        highlightGeneration += 1
        let generation = highlightGeneration
        let text = textView.string
        guard text.utf8.count < CodeTextController.highlightLimit, SyntaxFamily.of(language: language) != .plain else {
            clearColours()
            return
        }
        let language = self.language
        highlightTask = Task { [weak self] in
            let tokens = await Task.detached(priority: .userInitiated) {
                SyntaxScanner.tokens(in: text, language: language)
            }.value
            guard let self, !Task.isCancelled, generation == self.highlightGeneration else { return }
            self.applyColours(tokens)
        }
    }

    private func clearColours() {
        guard let lm = textView.layoutManager else { return }
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
    }

    private func applyColours(_ tokens: [SyntaxToken]) {
        guard let lm = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for t in tokens where NSMaxRange(t.range) <= length {
            lm.addTemporaryAttribute(.foregroundColor, value: EditorTheme.color(t.kind), forCharacterRange: t.range)
        }
    }

    // MARK: Changing the text

    /// Replaces the whole text with `new` as one undoable step (Cmd+Z puts it back). Only the
    /// part that differs is replaced, so the cursor and scroll position stay where they were.
    func replaceText(_ new: String, actionName: String) {
        let old = textView.string as NSString
        let next = new as NSString
        let oldLength = old.length, newLength = next.length
        var prefix = 0
        while prefix < oldLength && prefix < newLength && old.character(at: prefix) == next.character(at: prefix) { prefix += 1 }
        // Never split a surrogate pair.
        if prefix > 0 && UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < oldLength - prefix && suffix < newLength - prefix
                && old.character(at: oldLength - 1 - suffix) == next.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        if suffix > 0 && UTF16.isTrailSurrogate(old.character(at: oldLength - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let replacement = next.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        if range.length == 0 && replacement.isEmpty { return }
        textView.clearGhost()
        textView.breakUndoCoalescing()
        textView.replace(range, with: replacement, actionName: actionName)
        textView.breakUndoCoalescing()
    }

    /// Replaces the text without an undo step: used when a file is first shown.
    func loadText(_ text: String) {
        textView.clearGhost()
        textView.string = text
        textView.textStorage?.setAttributes(EditorTheme.baseAttributes, range: NSRange(location: 0, length: (text as NSString).length))
        undo.removeAllActions()
        recomputeLineStarts()
        applyIssueUnderlines()
        scheduleHighlight()
    }

    // MARK: Questions the editor model asks

    /// Where a suggestion could go: the cursor, with no selection, at the end of its line or on an
    /// empty line. Nil otherwise.
    func completionContext() -> (location: Int, prefix: String, suffix: String)? {
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location != NSNotFound else { return nil }
        let ns = textView.string as NSString
        let line = lineRange(lineNumber(at: sel.location))
        guard line.location != NSNotFound, sel.location <= NSMaxRange(line) else { return nil }
        let rest = ns.substring(with: NSRange(location: sel.location, length: NSMaxRange(line) - sel.location))
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let before = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
        // Nothing to go on: an empty line after an empty line at the very start of the file.
        if before.trimmingCharacters(in: .whitespaces).isEmpty && sel.location < 2 { return nil }
        let prefixStart = max(0, sel.location - CodeCompleteInput.maxPrefix)
        let suffixLength = min(ns.length - sel.location, CodeCompleteInput.maxSuffix)
        let prefix = ns.substring(with: NSRange(location: prefixStart, length: sel.location - prefixStart))
        let suffix = ns.substring(with: NSRange(location: sel.location, length: suffixLength))
        return (sel.location, prefix, suffix)
    }

    /// The selected lines, when something is selected.
    func selectedLines() -> CodeEditSelection? {
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return nil }
        let first = lineNumber(at: sel.location)
        let last = lineNumber(at: max(sel.location, NSMaxRange(sel) - 1))
        return CodeEditSelection(startLine: first, endLine: last)
    }

    func selectedText() -> String {
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return "" }
        return (textView.string as NSString).substring(with: sel)
    }

    func showGhost(_ text: String, at location: Int) {
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location == location else { return }
        textView.ghostLocation = location
        textView.ghost = text
        textView.needsDisplay = true
    }

    func clearGhost() { textView.clearGhost() }

    /// Moves the cursor to the start of a line and scrolls it into view.
    func reveal(line: Int) {
        let r = lineRange(min(max(line, 1), lineStarts.count))
        guard r.location != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: r.location, length: 0))
        textView.scrollRangeToVisible(r)
        textView.showFindIndicator(for: r.length > 0 ? r : NSRange(location: r.location, length: 0))
        textView.window?.makeFirstResponder(textView)
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }
}

/// NSTextView with the editor's key handling (Tab, Return, ghost text) and drawing (the current
/// line and the ghost text).
final class CodeTextView: NSTextView {
    weak var controller: CodeTextController?
    /// Olo's suggestion, drawn in grey after the cursor until Tab accepts it or any other key dismisses it.
    var ghost: String?
    var ghostLocation = 0
    private var hoverArea: NSTrackingArea?

    func clearGhost() {
        guard ghost != nil else { return }
        ghost = nil
        needsDisplay = true
    }

    /// One undoable replacement, in plain text with the editor's font.
    @discardableResult
    func replace(_ range: NSRange, with text: String, actionName: String? = nil) -> Bool {
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: EditorTheme.baseAttributes))
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
        return true
    }

    private func acceptGhost() {
        guard let text = ghost else { return }
        let location = ghostLocation
        clearGhost()
        guard location <= (string as NSString).length else { return }
        breakUndoCoalescing()
        insertText(text, replacementRange: NSRange(location: location, length: 0))
        undoManager?.setActionName("Olo Suggestion")
        breakUndoCoalescing()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if ghost != nil {
            let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if event.keyCode == 48 && mods.isEmpty {
                acceptGhost()
                return
            }
            if event.keyCode == 53 {
                clearGhost()
                return
            }
            clearGhost()
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        clearGhost()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command && event.charactersIgnoringModifiers == "f" {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var unit: String { controller?.indentUnit ?? "    " }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0 && ns.substring(with: sel).contains("\n") {
            shiftLines(right: true)
            return
        }
        insertText(unit, replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLines(right: false)
    }

    /// Indents (or outdents) every line the selection touches, as one undoable step.
    private func shiftLines(right: Bool) {
        let ns = string as NSString
        let block = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: block)
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        let shifted = lines.map { line -> String in
            if right { return line.isEmpty ? line : unit + line }
            return CodeIndent.outdented(line, unit: unit)
        }
        let replacement = shifted.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard replacement != text else { return }
        breakUndoCoalescing()
        if replace(block, with: replacement, actionName: right ? "Indent" : "Outdent") {
            setSelectedRange(NSRange(location: block.location, length: (replacement as NSString).length))
        }
    }

    override func insertNewline(_ sender: Any?) {
        clearGhost()
        let ns = string as NSString
        let sel = selectedRange()
        let startLine = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: startLine.location, length: sel.location - startLine.location))
        let selEnd = NSMaxRange(sel)
        let endLine = ns.lineRange(for: NSRange(location: selEnd, length: 0))
        var contentEnd = NSMaxRange(endLine)
        while contentEnd > selEnd {
            let c = ns.character(at: contentEnd - 1)
            if c == 10 || c == 13 { contentEnd -= 1 } else { break }
        }
        let after = ns.substring(with: NSRange(location: selEnd, length: contentEnd - selEnd))
        let result = CodeIndent.newline(before: before, after: after, unit: unit)
        insertText(result.text, replacementRange: sel)
        setSelectedRange(NSRange(location: sel.location + result.caret, length: 0))
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let message = controller?.issueMessage(at: convert(event.locationInWindow, from: nil))
        if toolTip != message { toolTip = message }
    }

    // MARK: Drawing

    /// The rectangle of the line fragment holding `location`, in view coordinates.
    private func caretRect(at location: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let ns = string as NSString
        var rect: NSRect
        if location >= ns.length {
            if ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
                rect = lm.extraLineFragmentRect
                rect.size.width = 1
            } else {
                let g = lm.glyphIndexForCharacter(at: ns.length - 1)
                let b = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                rect = NSRect(x: b.maxX, y: b.minY, width: 1, height: b.height)
            }
        } else {
            let g = lm.glyphIndexForCharacter(at: location)
            let fragment = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let p = lm.location(forGlyphAt: g)
            rect = NSRect(x: fragment.minX + p.x, y: fragment.minY, width: 1, height: fragment.height)
        }
        guard rect.height > 0 else { return nil }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let sel = selectedRange()
        guard sel.length == 0, var line = caretRect(at: sel.location) else { return }
        line.origin.x = 0
        line.size.width = bounds.width
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        line.fill(using: .sourceOver)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let text = ghost, !text.isEmpty, let caret = caretRect(at: ghostLocation) else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? EditorTheme.font, .foregroundColor: NSColor.tertiaryLabelColor]
        let lines = text.components(separatedBy: "\n")
        (lines[0] as NSString).draw(at: NSPoint(x: caret.minX, y: caret.minY), withAttributes: attrs)
        guard lines.count > 1 else { return }
        // The other lines go in a box below the cursor's line, over the code that follows.
        let rest = Array(lines.dropFirst())
        let lineHeight = caret.height
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let widest = rest.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 0
        let box = NSRect(x: x - 3, y: caret.maxY, width: max(widest + 10, 60), height: lineHeight * CGFloat(rest.count) + 4)
        NSColor.textBackgroundColor.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: box).stroke()
        for (i, l) in rest.enumerated() {
            (l as NSString).draw(at: NSPoint(x: x, y: caret.maxY + 2 + CGFloat(i) * lineHeight), withAttributes: attrs)
        }
    }
}

/// The gutter: line numbers, and a coloured dot on each line with an issue (hover for the message).
final class LineNumberRuler: NSRulerView {
    weak var controller: CodeTextController?
    private var hoverArea: NSTrackingArea?

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 43
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    override var requiredThickness: CGFloat { ruleThickness }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let c = controller, let lm = c.textView.layoutManager, let tc = c.textView.textContainer else { return }
        let tv = c.textView
        let ns = tv.string as NSString
        let offsetY = convert(NSPoint.zero, from: tv).y + tv.textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let starts = c.lineStarts
        let attrs: [NSAttributedString.Key: Any] = [.font: EditorTheme.gutterFont, .foregroundColor: NSColor.secondaryLabelColor]
        var index = c.lineNumber(at: chars.location) - 1
        while index < starts.count {
            let start = starts[index]
            if start > NSMaxRange(chars) { break }
            let fragment: NSRect
            if start >= ns.length {
                fragment = lm.extraLineFragmentRect
            } else {
                fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            if fragment.height > 0 {
                let y = fragment.minY + offsetY
                let label = String(index + 1) as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - 8 - size.width, y: y + (fragment.height - size.height) / 2), withAttributes: attrs)
                if let issue = c.issuesByLine[index + 1] {
                    let d: CGFloat = 7
                    let dot = NSRect(x: 4, y: y + (fragment.height - d) / 2, width: d, height: d)
                    EditorTheme.severity(issue.severity).setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
            index += 1
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let c = controller else { return }
        let p = c.textView.convert(event.locationInWindow, from: nil)
        let message = c.issueMessage(at: NSPoint(x: c.textView.textContainerOrigin.x + 1, y: p.y))
        if toolTip != message { toolTip = message }
    }
}
