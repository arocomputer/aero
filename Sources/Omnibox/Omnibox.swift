import AppKit

/// The address field with its suggestions, centered over the content area. It is the whole page of a
/// blank tab, and a dismissible overlay on a loaded one (⌘L). Suggestions follow what is typed, so the
/// page's own address opens as the field alone. Typing completes inline from history; ↑/↓ pick a row,
/// Tab accepts the completion, Return navigates, Esc or a click outside dismisses.
///
/// The field appears and leaves at once; animating its arrival once flashed a gray card at launch.
/// It holds still at the window's center while it is open, and the list below it follows typing with
/// brief, interruptible motion: it unrolls from under the field and rolls back up, grows and
/// shrinks, suggestions that survive a keystroke keep their row and slide to their new place, new ones
/// rise into theirs, and dropped ones clear out first, so two lines of text never share a slot for
/// long. The typed text itself never moves. Reduce Motion turns it all off.
final class Omnibox: NSView, NSTextFieldDelegate {
    var onNavigate: ((URL) -> Void)?
    var onDismiss: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    var onBackgroundChange: (() -> Void)?
    /// Everything the field shows for one tab, taken as the person switches away, so switching back
    /// finds the text, its highlight or caret, any inline completion and the chosen row as they were.
    struct Snapshot {
        let text: String
        let typed: String
        let selection: NSRange
        let row: Int?
    }

    /// The field as it stands, or nil when it is not showing.
    var snapshot: Snapshot? {
        guard !isHidden, let editor = field.currentEditor() as? NSTextView else { return nil }
        return Snapshot(text: editor.string, typed: typed, selection: editor.selectedRange(), row: selected)
    }

    var allowsRemoteSuggestions = false { didSet { if !allowsRemoteSuggestions { suggestionTask?.cancel() } } }
    private var suggestionTask: Task<Void, Never>?

    private let fieldBox = CardView()
    private let field = NSTextField()
    private let searchHint = SearchHint()
    private let listBox = CardView()
    /// Clips rows to the list's rounded shape; the card itself can't clip without losing its shadow. Flipped, so the first row is the top one and ↓ moves down the list.
    private let rowsClip = RowsClip()
    private var rows: [SuggestionRow] = []
    private var isOverPage = false
    /// What the user typed, without the inline completion or a row's address filled in over it.
    private var typed = ""
    private var entries: [HistoryEntry] = []
    /// Index into the history rows.
    private var selected: Int? { didSet { rows.enumerated().forEach { $1.isSelected = $0 == selected } } }
    private var skipCompletion = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = "Enter a web address"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        searchHint.font = .systemFont(ofSize: 13)
        searchHint.textColor = .tertiaryLabelColor
        searchHint.isHidden = true
        [field, searchHint].forEach(fieldBox.addSubview)
        listBox.alphaValue = 0
        rowsClip.wantsLayer = true
        rowsClip.layer?.cornerRadius = 12
        rowsClip.layer?.cornerCurve = .continuous
        rowsClip.layer?.masksToBounds = true
        listBox.addSubview(rowsClip)
        addSubview(fieldBox)
        addSubview(listBox)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// The native blank page's background, resolved in its own appearance for the strip to share.
    var pageBackground: NSColor {
        var color = NSColor.textBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: NSColor.textBackgroundColor.cgColor) ?? color
        }
        return color
    }

    override func updateLayer() {
        layer?.backgroundColor = isOverPage ? nil : pageBackground.cgColor
        if !isOverPage { onBackgroundChange?() }
    }

    /// Shows the field with `text` and takes keyboard focus. `overPage` makes the backdrop transparent
    /// and dismissible; otherwise it is the opaque blank-tab page. `selectingText` highlights the
    /// existing address so typing replaces it at once; without it the caret sits after the address.
    /// `suggesting` lists history matching `text`; the page's own address passes false, since matches
    /// for where the person already is only cover the page. The first keystroke brings them back.
    /// `restoring` puts back a `snapshot` taken from this tab, overriding `text` and `selectingText`.
    func present(
        text: String, overPage: Bool, selectingText: Bool = true, suggesting: Bool = true, restoring saved: Snapshot? = nil
    ) {
        suggestionTask?.cancel()
        isOverPage = overPage
        needsDisplay = true
        field.stringValue = saved?.text ?? text
        searchHint.isHidden = true
        typed = saved?.typed ?? text
        entries = typed.isEmpty || !suggesting ? [] : History.shared.suggestions(for: typed)
        onTextChange?(typed)
        isHidden = false
        rebuildRows(select: saved?.row.flatMap { $0 < entries.count ? $0 : nil }, animated: false)

        window?.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { return }
        // The inline completion is a selection; neutral gray keeps it from reading as an error or a link.
        editor.selectedTextAttributes = [.backgroundColor: NSColor.labelColor.withAlphaComponent(0.12)]
        let length = (field.stringValue as NSString).length
        if let range = saved?.selection {
            let start = min(range.location, length)
            editor.setSelectedRange(NSRange(location: start, length: min(range.length, length - start)))
        } else if !selectingText {
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        placeSearchHint()
    }

    func dismiss() {
        suggestionTask?.cancel()
        isHidden = true
    }

    override func layout() {
        super.layout()
        arrange()
    }

    /// Places the field at the window's center with the list below it; suggestions never move the field.
    /// Animated, a list that is appearing unrolls from a sliver under the field, uncovering its rows from
    /// the top while it fades in over the first half; one that is emptying rolls back up as it fades.
    /// A plain fade was too faint to notice at the moment the eye is on the first letter typed.
    private func arrange(animated: Bool = false) {
        let width = min(478, bounds.width - 40)
        let x = ((bounds.width - width) / 2).rounded()
        // Centered on the window rather than the content area, which starts below the tab strip.
        let windowCenter = superview.map { convert(NSPoint(x: 0, y: $0.bounds.midY), from: $0).y } ?? bounds.midY
        let y = (windowCenter - 21).rounded()
        fieldBox.frame = NSRect(x: x, y: y, width: width, height: 42)
        var listFrame = NSRect(x: x, y: y + 50, width: width, height: CGFloat(rows.count) * 29 + 9)
        field.frame = NSRect(x: 16, y: 12, width: width - 32, height: 18)
        placeSearchHint()
        let rowFrames = rows.indices.map { NSRect(x: 5.5, y: 4.5 + CGFloat($0) * 29, width: width - 11, height: 29) }

        guard animated else {
            listBox.frame = listFrame
            listBox.alphaValue = rows.isEmpty ? 0 : 1
            rowsClip.frame = NSRect(origin: .zero, size: listFrame.size)
            zip(rows, rowFrames).forEach { $0.frame = $1 }
            return
        }
        let listWasShowing = listBox.alphaValue > 0
        let sliver = NSRect(origin: listFrame.origin, size: NSSize(width: width, height: 9))
        if rows.isEmpty {
            listFrame = sliver
        } else if !listWasShowing {
            listBox.frame = sliver
            rowsClip.frame = NSRect(origin: .zero, size: sliver.size)
        }
        for (row, frame) in zip(rows, rowFrames) where row.frame.isEmpty || !listWasShowing {
            // A row joining a list that is already up rises the last few points into its place.
            row.frame = listWasShowing ? frame.offsetBy(dx: 0, dy: 6) : frame
        }
        Self.animate(rows.isEmpty ? 0.2 : 0.14) { listBox.animator().alphaValue = rows.isEmpty ? 0 : 1 }
        Self.animate(0.28) {
            listBox.animator().frame = listFrame
            rowsClip.animator().frame = NSRect(origin: .zero, size: listFrame.size)
            for (row, frame) in zip(rows, rowFrames) where row.frame != frame { row.animator().frame = frame }
        }
    }

    /// Runs `changes` with the address field's motion: brief and instant under Reduce Motion. The curve
    /// is the plain ease-out: steeper ones measured as most of the travel landing in the first 60 ms,
    /// which read as no motion at all.
    fileprivate static func animate(_ duration: TimeInterval, _ changes: () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                changes()
            }, completionHandler: completion)
    }

    override func mouseDown(with event: NSEvent) {
        if isOverPage { onDismiss?() }
    }

    // MARK: Typing

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        typed = editor.string
        onTextChange?(typed)
        entries = History.shared.suggestions(for: typed)

        let caretAtEnd = editor.selectedRange().location == (typed as NSString).length
        if !skipCompletion, caretAtEnd, !editor.hasMarkedText(), !typed.isEmpty,
            let top = entries.first, top.display.lowercased().hasPrefix(typed.lowercased())
        {
            editor.string = typed + top.display.dropFirst(typed.count)
            let start = (typed as NSString).length
            editor.setSelectedRange(NSRange(location: start, length: (editor.string as NSString).length - start))
            rebuildRows(select: 0)
        } else {
            rebuildRows()
        }
        skipCompletion = false
        updateSearchHint()
        suggestionTask?.cancel()
        if allowsRemoteSuggestions, UserDefaults.standard.bool(forKey: "RemoteSuggestions") {
            let query = typed
            suggestionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let suggestions = await SearchSuggestions.fetch(query)
                guard let self, !Task.isCancelled, allowsRemoteSuggestions, UserDefaults.standard.bool(forKey: "RemoteSuggestions"),
                    !isHidden, typed == query, selected == nil
                else { return }
                let seen = Set(entries.map(\.url))
                entries = Array((entries + suggestions.filter { !seen.contains($0.url) }).prefix(5))
                rebuildRows()
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            commit()
        case #selector(cancelOperation(_:)):
            if isOverPage { onDismiss?() } else { present(text: "", overPage: false) }
        case #selector(moveDown(_:)):
            moveSelection(by: 1)
        case #selector(moveUp(_:)):
            moveSelection(by: -1)
        case #selector(insertTab(_:)):
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        default:
            // Deleting removes the completion instead of re-offering it.
            if NSStringFromSelector(selector).hasPrefix("delete") { skipCompletion = true }
            return false
        }
        return true
    }

    private func moveSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        let index = min(max((selected ?? (step > 0 ? -1 : rows.count)) + step, 0), rows.count - 1)
        selected = index
        let text = entries[index].display
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        updateSearchHint()
    }

    private func commit() {
        if let selected { return activate(row: selected) }
        if let url = AddressInput.url(for: field.stringValue) { onNavigate?(url) }
    }

    private func activate(row index: Int) { onNavigate?(entries[index].url) }

    /// Brings the rows in line with history. The field itself owns typed text and its inline completion,
    /// so rows only show distinct destinations. A destination that is still offered keeps its row view.
    /// Animated, which is the default once the field is up, new rows fade in as they rise into place and
    /// dropped ones fade out quickly, drifting up, so they are gone before a surviving row slides into
    /// their slot.
    private func rebuildRows(select: Int? = nil, animated: Bool = true) {
        // With favicons on, every row has an icon so the titles line up: the site's, or a plain globe.
        let showsIcons = Settings.showsFavicons
        let items = entries.map {
            let title = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                key: $0.url.absoluteString, primary: title.isEmpty ? $0.display : title, secondary: title.isEmpty ? "" : $0.display,
                icon: showsIcons ? Favicons.shared.icon(for: $0.url) ?? SuggestionRow.globe : nil
            )
        }

        let existing = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = items.map { item -> SuggestionRow in
            if let row = existing[item.key] {
                row.update(primary: item.primary, secondary: item.secondary, icon: item.icon)
                return row
            }
            let row = SuggestionRow(key: item.key, primary: item.primary, secondary: item.secondary, icon: item.icon)
            rowsClip.addSubview(row)
            return row
        }
        let entering = updated.filter { $0.frame.isEmpty }
        let leaving = rows.filter { row in !updated.contains { $0 === row } }
        rows = updated
        for (index, row) in rows.enumerated() {
            row.onClick = { [weak self] in self?.activate(row: index) }
        }
        selected = select
        updateSearchHint()

        guard animated, !isHidden, window?.isVisible == true else {
            leaving.forEach { $0.removeFromSuperview() }
            arrange()
            return
        }
        // Rows arriving with the list itself ride its fade rather than fading twice.
        if listBox.alphaValue > 0 { entering.forEach { $0.alphaValue = 0 } }
        arrange(animated: true)
        leaving.forEach { $0.onClick = nil }
        Self.animate(0.12) {
            for row in leaving {
                row.animator().alphaValue = 0
                row.animator().frame = row.frame.offsetBy(dx: 0, dy: -4)
            }
        } completion: {
            leaving.forEach { $0.removeFromSuperview() }
        }
        Self.animate(0.22) { entering.forEach { $0.animator().alphaValue = 1 } }
    }

    /// Shows the search provider after a query without adding a duplicate suggestion row.
    private func updateSearchHint() {
        let isSearch = AddressInput.url(for: typed).map(AddressInput.isSearchURL) == true
        searchHint.stringValue = CustomSearch.name(for: typed)
        searchHint.isHidden = !isSearch || selected != nil
        placeSearchHint()
    }

    private func placeSearchHint() {
        guard !searchHint.isHidden else { return }
        let shown = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let width = (shown as NSString).size(withAttributes: [.font: field.font!]).width
        // NSTextFieldCell keeps drawing insets outside its intrinsic text measurement. Leave enough
        // room for both insets so the final "e" is never clipped at Retina pixel boundaries.
        let hintWidth = ceil(searchHint.intrinsicContentSize.width) + 12
        guard width + 8 + hintWidth < field.frame.width else {
            searchHint.isHidden = true
            return
        }
        let x = min(field.frame.minX + width + 8, field.frame.maxX - hintWidth)
        searchHint.frame = NSRect(x: x, y: field.frame.minY + 1, width: hintWidth, height: 17)
    }
}

/// A dim provider label that lets clicks continue through to the editable address field.
private final class SearchHint: NSTextField {
    init() {
        super.init(frame: .zero)
        stringValue = CustomSearch.name
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Holds the suggestion rows, laid out from the top like everything else in the address field.
private final class RowsClip: NSView {
    override var isFlipped: Bool { true }
}

/// One history suggestion, led by its site's icon when it is given one. `key` identifies it across
/// keystrokes so its row can be kept.
private final class SuggestionRow: NSView {
    /// Stands in for a site whose icon isn't known yet.
    static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

    let key: String
    var onClick: (() -> Void)?
    /// Shown by contrast alone: the selected or hovered row's text is full strength, the rest recede.
    var isSelected = false { didSet { if isSelected != oldValue { updateEmphasis(fading: false) } } }
    private var isHovered = false { didSet { if isHovered != oldValue { updateEmphasis(fading: true) } } }

    private let primary: NSTextField
    private let secondary: NSTextField
    private let iconView = NSImageView()

    init(key: String, primary: String, secondary: String, icon: NSImage?) {
        self.key = key
        self.primary = NSTextField(labelWithString: primary)
        self.secondary = NSTextField(labelWithString: secondary)
        super.init(frame: .zero)
        setIcon(icon)
        addSubview(iconView)
        self.primary.wantsLayer = true
        self.primary.font = .systemFont(ofSize: 13)
        self.primary.textColor = .secondaryLabelColor
        self.secondary.font = .systemFont(ofSize: 13)
        self.secondary.textColor = .tertiaryLabelColor
        for label in [self.primary, self.secondary] { label.lineBreakMode = .byTruncatingTail }
        [self.primary, self.secondary].forEach(addSubview)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    func update(primary: String, secondary: String, icon: NSImage?) {
        guard primary != self.primary.stringValue || secondary != self.secondary.stringValue || icon !== iconView.image
        else { return }
        self.primary.stringValue = primary
        self.secondary.stringValue = secondary
        setIcon(icon)
        needsLayout = true
    }

    /// A single-tone site icon is drawn like the row's text; the globe recedes further.
    private func setIcon(_ icon: NSImage?) {
        iconView.image = icon
        iconView.contentTintColor = icon === Self.globe ? .tertiaryLabelColor : .secondaryLabelColor
    }

    /// The pointer's emphasis fades in and out; the keyboard's is immediate, so arrowing through the
    /// list keeps pace with the address it fills into the field.
    private func updateEmphasis(fading: Bool) {
        if fading, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            primary.layer?.add(fade, forKey: "emphasis")
        }
        primary.textColor = isSelected || isHovered ? .labelColor : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let x: CGFloat = iconView.image == nil ? 10 : 33
        iconView.frame = NSRect(x: 9, y: 6.5, width: 16, height: 16)
        let available = bounds.width - x - 10
        let primaryWidth = min(primary.intrinsicContentSize.width, available)
        primary.frame = NSRect(x: x, y: 7, width: primaryWidth, height: 16)
        secondary.frame = NSRect(x: x + primaryWidth + 8, y: 7, width: max(0, available - primaryWidth - 8), height: 16)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A rounded, softly shadowed surface: the address field and the suggestion list sit on these.
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
}
