import AppKit

@MainActor
struct EditorTypography: Equatable {
    let family: String?
    let size: Int
    let lineHeight: Int

    static let sizeRange = 8...48
    static let lineHeightRange = 100...220
    static let defaults = Self(family: nil, size: 14, lineHeight: 120)
    static let didChange = Notification.Name("LocalTeXEditorTypographyChanged")
    private static let preferenceKey = "EditorTypography"

    static var current: Self {
        let values = UserDefaults.standard.dictionary(forKey: preferenceKey)
        return Self(
            family: values?["family"] as? String,
            size: Self.clamp(values?["size"] as? Int ?? defaults.size, to: sizeRange),
            lineHeight: Self.clamp(values?["lineHeight"] as? Int ?? defaults.lineHeight, to: lineHeightRange)
        )
    }

    var font: NSFont {
        if let family,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: CGFloat(size)) {
            return font
        }
        return .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    func save() {
        let validatedSize = Self.clamp(size, to: Self.sizeRange)
        let validatedHeight = Self.clamp(lineHeight, to: Self.lineHeightRange)
        let preference = Self(family: family, size: validatedSize, lineHeight: validatedHeight)
        guard preference != Self.current else { return }
        var values: [String: Any] = ["size": validatedSize, "lineHeight": validatedHeight]
        values["family"] = family
        UserDefaults.standard.set(values, forKey: Self.preferenceKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

@MainActor
struct EditorAutosaveSettings: Equatable {
    let enabled: Bool
    let delayMilliseconds: Int

    static let minimumDelay = 1000
    static let defaults = Self(enabled: true, delayMilliseconds: minimumDelay)
    static let didChange = Notification.Name("LocalTeXEditorAutosaveChanged")
    private static let preferenceKey = "EditorAutosave"

    static var current: Self {
        let values = UserDefaults.standard.dictionary(forKey: preferenceKey)
        return Self(
            enabled: values?["enabled"] as? Bool ?? defaults.enabled,
            delayMilliseconds: max(minimumDelay, values?["delayMilliseconds"] as? Int ?? defaults.delayMilliseconds)
        )
    }

    func save() {
        let delay = max(Self.minimumDelay, delayMilliseconds)
        guard Self(enabled: enabled, delayMilliseconds: delay) != Self.current else { return }
        UserDefaults.standard.set(["enabled": enabled, "delayMilliseconds": delay], forKey: Self.preferenceKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

@MainActor
final class EditorSettingsController: NSWindowController, NSTextFieldDelegate {
    private let fontPicker = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let heightField = NSTextField()
    private let heightStepper = NSStepper()
    private let autosaveToggle = NSButton(checkboxWithTitle: "Save named files after typing stops", target: nil, action: nil)
    private let autosaveDelay = NSTextField()

    init() {
        let size = NSSize(width: 414, height: 254)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Editor Settings"
        window.backgroundColor = AppPalette.window
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        installControls(in: window)
        window.setContentSize(size)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        updateControls()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func installControls(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        fontPicker.addItem(withTitle: "System Monospace")
        fontPicker.menu?.addItem(.separator())
        let families = NSFontManager.shared.availableFontFamilies
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for family in families {
            fontPicker.addItem(withTitle: family)
            fontPicker.lastItem?.representedObject = family
        }
        fontPicker.target = self
        fontPicker.action = #selector(updateTypography(_:))
        fontPicker.setAccessibilityLabel("Font")

        autosaveToggle.target = self
        autosaveToggle.action = #selector(updateAutosave(_:))
        autosaveToggle.setAccessibilityLabel("Autosave")
        autosaveDelay.alignment = .right
        autosaveDelay.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        autosaveDelay.target = self
        autosaveDelay.action = #selector(updateAutosave(_:))
        autosaveDelay.delegate = self
        autosaveDelay.setAccessibilityLabel("Autosave delay")
        autosaveDelay.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let milliseconds = NSTextField(labelWithString: "ms (minimum 1000)")
        milliseconds.textColor = AppPalette.secondaryText
        let delayRow = NSStackView(views: [autosaveDelay, milliseconds])
        delayRow.alignment = .centerY
        delayRow.spacing = 7

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Font"), fontPicker],
            [NSTextField(labelWithString: "Font Size"), numberRow(sizeField, stepper: sizeStepper,
                                                      label: "Font Size", unit: "pt", range: EditorTypography.sizeRange, increment: 1)],
            [NSTextField(labelWithString: "Line Height"), numberRow(heightField, stepper: heightStepper,
                                                      label: "Line Height", unit: "%", range: EditorTypography.lineHeightRange, increment: 5)],
            [NSTextField(labelWithString: "Autosave"), autosaveToggle],
            [NSTextField(labelWithString: "Save Delay"), delayRow]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        fontPicker.widthAnchor.constraint(equalToConstant: 278).isActive = true

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetSettings(_:)))
        for subview in [grid, reset] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            reset.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            reset.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 12),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func numberRow(_ field: NSTextField, stepper: NSStepper, label: String, unit: String,
                           range: ClosedRange<Int>, increment: Double) -> NSView {
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.target = self
        field.action = #selector(updateTypography(_:))
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true

        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = increment
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(updateTypography(_:))
        stepper.setAccessibilityLabel(label)

        let suffix = NSTextField(labelWithString: unit)
        suffix.textColor = AppPalette.secondaryText
        let row = NSStackView(views: [field, stepper, suffix])
        row.alignment = .centerY
        row.spacing = 7
        return row
    }

    private func updateControls() {
        let typography = EditorTypography.current
        let item = fontPicker.itemArray.first { ($0.representedObject as? String) == typography.family }
        fontPicker.select(item ?? fontPicker.item(at: 0))
        sizeField.integerValue = typography.size
        sizeStepper.integerValue = typography.size
        heightField.integerValue = typography.lineHeight
        heightStepper.integerValue = typography.lineHeight
        updateAutosaveControls()
    }

    private func updateAutosaveControls() {
        let autosave = EditorAutosaveSettings.current
        autosaveToggle.state = autosave.enabled ? .on : .off
        autosaveDelay.stringValue = String(autosave.delayMilliseconds)
        autosaveDelay.isEnabled = autosave.enabled
    }

    @objc private func updateTypography(_ sender: NSControl) {
        let current = EditorTypography.current
        let size = sender === sizeStepper ? sizeStepper.integerValue
            : Int(sizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? current.size
        let height = sender === heightStepper ? heightStepper.integerValue
            : Int(heightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? current.lineHeight
        EditorTypography(family: fontPicker.selectedItem?.representedObject as? String,
                         size: size, lineHeight: height).save()
        updateControls()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField {
            if field === autosaveDelay { updateAutosave(field) }
            else { updateTypography(field) }
        }
    }

    @objc private func updateAutosave(_ sender: NSControl) {
        let delay = Int(autosaveDelay.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? EditorAutosaveSettings.current.delayMilliseconds
        EditorAutosaveSettings(enabled: autosaveToggle.state == .on, delayMilliseconds: delay).save()
        updateAutosaveControls()
    }

    @objc private func resetSettings(_ sender: Any?) {
        EditorTypography.defaults.save()
        EditorAutosaveSettings.defaults.save()
        updateControls()
    }
}
