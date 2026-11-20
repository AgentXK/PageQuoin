import AppKit

@MainActor
final class FrostedSidebarController: NSViewController {
    private let content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        view = material

        let tint = NSBox()
        tint.boxType = .custom
        tint.borderWidth = 0
        tint.fillColor = AppPalette.sidebarTint

        addChild(content)
        let panel = content.view
        for layer in [tint, panel] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(layer)
            NSLayoutConstraint.activate([
                layer.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                layer.topAnchor.constraint(equalTo: material.topAnchor),
                layer.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
        }
    }
}
