import AppKit

enum LaTeXCompletion {
    struct Candidate {
        let insertion: String
        let label: String
        let detail: String
    }

    struct Match {
        let range: NSRange
        let candidates: [Candidate]
    }

    private static let commandNames = """
        documentclass usepackage begin end section subsection subsubsection chapter paragraph subparagraph \
        title author date maketitle tableofcontents label ref pageref eqref autoref cref cite citep citet \
        textcite parencite bibliography bibliographystyle addbibresource printbibliography \
        textbf textit texttt textsc textsf textsl textrm textup textnormal emph underline footnote footnotemark \
        item caption captionof centering includegraphics graphicspath input include includeonly \
        frac dfrac tfrac sqrt overline underline widehat widetilde operatorname mathbf mathrm mathcal mathbb \
        mathsf mathit text mbox ensuremath boldsymbol left right middle limits nolimits substack \
        appendix part index newcommand renewcommand providecommand DeclareMathOperator newenvironment \
        renewenvironment newtheorem newcounter setcounter addtocounter setlength addtolength \
        hspace vspace hfill vfill quad qquad smallskip medskip bigskip newpage clearpage pagebreak noindent \
        newline linebreak raggedright raggedleft setlength geometry href url verb LaTeX TeX
        """.split(whereSeparator: \.isWhitespace).map(String.init)

    private static let symbolNames: [(String, String)] = [
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("epsilon", "ϵ"),
        ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"), ("theta", "θ"), ("vartheta", "ϑ"),
        ("iota", "ι"), ("kappa", "κ"), ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"),
        ("pi", "π"), ("varpi", "ϖ"), ("rho", "ρ"), ("varrho", "ϱ"), ("sigma", "σ"), ("varsigma", "ς"),
        ("tau", "τ"), ("upsilon", "υ"), ("phi", "ϕ"), ("varphi", "φ"), ("chi", "χ"), ("psi", "ψ"),
        ("omega", "ω"), ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"), ("Xi", "Ξ"),
        ("Pi", "Π"), ("Sigma", "Σ"), ("Upsilon", "Υ"), ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
        ("sum", "∑"), ("prod", "∏"), ("int", "∫"), ("iint", "∬"), ("iiint", "∭"), ("oint", "∮"),
        ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("ell", "ℓ"), ("hbar", "ℏ"),
        ("forall", "∀"), ("exists", "∃"), ("nexists", "∄"), ("neg", "¬"), ("emptyset", "∅"),
        ("varnothing", "∅"), ("in", "∈"), ("notin", "∉"), ("ni", "∋"), ("subset", "⊂"),
        ("subseteq", "⊆"), ("supset", "⊃"), ("supseteq", "⊇"), ("cup", "∪"), ("cap", "∩"),
        ("bigcup", "⋃"), ("bigcap", "⋂"), ("setminus", "∖"), ("land", "∧"), ("lor", "∨"),
        ("times", "×"), ("div", "÷"), ("cdot", "·"), ("ast", "∗"), ("star", "⋆"), ("circ", "∘"),
        ("bullet", "•"), ("oplus", "⊕"), ("otimes", "⊗"), ("pm", "±"), ("mp", "∓"),
        ("le", "≤"), ("leq", "≤"), ("ge", "≥"), ("geq", "≥"), ("ne", "≠"), ("neq", "≠"),
        ("equiv", "≡"), ("approx", "≈"), ("sim", "∼"), ("simeq", "≃"), ("cong", "≅"), ("propto", "∝"),
        ("to", "→"), ("rightarrow", "→"), ("leftarrow", "←"), ("leftrightarrow", "↔"), ("mapsto", "↦"),
        ("Rightarrow", "⇒"), ("Leftarrow", "⇐"), ("Leftrightarrow", "⇔"), ("longrightarrow", "⟶"),
        ("longleftarrow", "⟵"), ("uparrow", "↑"), ("downarrow", "↓"), ("hookrightarrow", "↪"),
        ("dots", "…"), ("ldots", "…"), ("cdots", "⋯"), ("vdots", "⋮"), ("ddots", "⋱"),
        ("langle", "⟨"), ("rangle", "⟩"), ("lceil", "⌈"), ("rceil", "⌉"), ("lfloor", "⌊"),
        ("rfloor", "⌋"), ("mid", "∣"), ("parallel", "∥"), ("perp", "⟂"), ("angle", "∠"),
        ("aleph", "ℵ"), ("prime", "′"), ("dagger", "†"), ("ddagger", "‡"),
        ("%", "%"), ("$", "$"), ("_", "_"), ("&", "&"), ("#", "#"), ("{", "{"), ("}", "}")
    ]

    private static let commands: [Candidate] = {
        var names = Set<String>()
        let keywords = commandNames.compactMap { name in
            names.insert(name).inserted ? Candidate(insertion: name, label: "\\" + name, detail: "") : nil
        }
        return keywords + symbolNames.map { name, glyph in
            Candidate(insertion: name, label: "\\" + name, detail: glyph)
        }
    }()

    private static let environments = """
        document abstract figure figure* table table* tabular tabular* tabularx longtable \
        itemize enumerate description quote quotation verse center flushleft flushright \
        minipage multicols equation equation* align align* aligned gather gather* multline multline* \
        split cases array matrix pmatrix bmatrix Bmatrix vmatrix Vmatrix \
        theorem lemma proof definition proposition corollary example \
        frame columns column block alertblock tikzpicture listing lstlisting verbatim
        """.split(whereSeparator: \.isWhitespace).map { name in
            Candidate(insertion: String(name), label: String(name), detail: "")
        }

    static func match(in source: NSString, at caret: Int, manual: Bool) -> Match? {
        guard caret > 0, caret <= source.length else { return nil }
        var start = caret
        while start > 0, isNameCharacter(source.character(at: start - 1)) {
            start -= 1
            if caret - start > 64 { return nil }
        }

        var catalog = commands
        var anchor = start - 1
        guard anchor >= 0 else { return nil }
        if source.character(at: anchor) == 0x7b {
            guard let commandStart = environmentCommandStart(in: source, before: anchor) else { return nil }
            anchor = commandStart
            catalog = environments
        } else if source.character(at: anchor) != 0x5c {
            return nil
        }
        guard isCode(in: source, before: anchor) else { return nil }

        let range = NSRange(location: start, length: caret - start)
        let prefix = source.substring(with: range)
        var matches: [Candidate] = []
        for candidate in catalog where candidate.insertion.hasPrefix(prefix) {
            if manual || candidate.insertion != prefix { matches.append(candidate) }
            if matches.count == 100 { break }
        }
        guard !matches.isEmpty else { return nil }
        return Match(range: range, candidates: matches)
    }

    static func isCode(in source: NSString, before offset: Int) -> Bool {
        var lineStart = 0
        source.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: offset, length: 0))
        var escaped = false
        for position in lineStart..<offset {
            let character = source.character(at: position)
            if character == 0x25 && !escaped { return false }
            escaped = character == 0x5c && !escaped
        }
        return !escaped
    }

    private static func environmentCommandStart(in source: NSString, before brace: Int) -> Int? {
        for command in ["\\begin", "\\end"] {
            let length = command.utf16.count
            let start = brace - length
            if start >= 0, source.substring(with: NSRange(location: start, length: length)) == command {
                return start
            }
        }
        return nil
    }

    private static func isNameCharacter(_ character: unichar) -> Bool {
        (0x41...0x5a).contains(character) || (0x61...0x7a).contains(character)
            || (0x30...0x39).contains(character) || character == 0x2a || character == 0x2d || character == 0x40
    }
}

@MainActor
final class LaTeXCompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = LaTeXCompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
    private let table = NSTableView()
    private var candidates: [LaTeXCompletion.Candidate] = []

    var onAccept: ((LaTeXCompletion.Candidate) -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LaTeXCompletion"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseRow(_:))
        table.setAccessibilityLabel("LaTeX Completions")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.drawsBackground = false
        scroll.documentView = table
        let surface = LaTeXCompletionSurface()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 7
        surface.layer?.masksToBounds = true
        panel.contentView = surface
        scroll.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -4)
        ])
    }

    func show(_ candidates: [LaTeXCompletion.Candidate], below caret: NSRect, in parent: NSWindow) {
        guard let screen = parent.screen ?? NSScreen.main else { return }
        self.candidates = candidates
        table.reloadData()
        select(row: 0)
        let visible = screen.visibleFrame
        let width: CGFloat = 218
        let height = CGFloat(min(candidates.count, 8)) * table.rowHeight + 8
        let x = min(max(caret.minX, visible.minX + 2), visible.maxX - width - 2)
        let below = caret.minY - height - 3
        let y = below >= visible.minY ? below : min(visible.maxY - height, caret.maxY + 3)
        panel.appearance = parent.appearance
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func dismiss() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(by offset: Int) {
        select(row: min(max(0, table.selectedRow + offset), candidates.count - 1))
    }

    func accept() {
        let row = table.selectedRow
        if candidates.indices.contains(row) { onAccept?(candidates[row]) }
    }

    private func select(row: Int) {
        guard candidates.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func chooseRow(_ sender: NSTableView) {
        if candidates.indices.contains(sender.clickedRow) { onAccept?(candidates[sender.clickedRow]) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("LaTeXCompletionRow")
        if let row = tableView.makeView(withIdentifier: identifier, owner: self) as? LaTeXCompletionRow {
            return row
        }
        let row = LaTeXCompletionRow()
        row.identifier = identifier
        return row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let option = candidates[row]
        let label = NSTextField(labelWithString: option.label)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = AppPalette.text
        let detail = NSTextField(labelWithString: option.detail)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = AppPalette.text
        let cell = NSView()
        for view in [label, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 5),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -9),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

private final class LaTeXCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LaTeXCompletionSurface: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        AppPalette.control.setFill()
        bounds.fill()
        AppPalette.rule.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5).stroke()
    }
}

private final class LaTeXCompletionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        AppPalette.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}
