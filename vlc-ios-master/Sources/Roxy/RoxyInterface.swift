#if os(iOS)
import UIKit
import Metal

enum RoxyAppearance {
    // Playback controls always sit on a dark surface, independently of the library theme.
    static let playbackAccent = UIColor(red: 0.40, green: 0.92, blue: 0.84, alpha: 1)
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.40, green: 0.92, blue: 0.84, alpha: 1) :
            UIColor(red: 0.02, green: 0.43, blue: 0.43, alpha: 1)
    }

    @discardableResult
    static func glass(behind view: UIView, radius: CGFloat = 24) -> RoxyGlassView {
        if let existing = view.subviews.first(where: { $0 is RoxyGlassView }) as? RoxyGlassView {
            return existing
        }
        let glass = RoxyGlassView(radius: radius)
        glass.frame = view.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.isUserInteractionEnabled = false
        view.insertSubview(glass, at: 0)
        view.backgroundColor = .clear
        return glass
    }

    static func presentSettings(from controller: UIViewController) {
        guard controller.presentedViewController == nil else { return }
        let settings = RoxyAnime4KSettingsController()
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .pageSheet
        navigation.navigationBar.prefersLargeTitles = false
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 32
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        controller.present(navigation, animated: true)
    }
}

// Real system glass on current iOS; accessible material on older devices.
final class RoxyGlassView: UIVisualEffectView {
    init(radius: CGFloat = 24) {
        let material: UIVisualEffect?
        if UIAccessibility.isReduceTransparencyEnabled {
            material = nil
        } else if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = false
            material = glass
        } else {
            material = UIBlurEffect(style: .systemMaterial)
        }
        super.init(effect: material)
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        if UIAccessibility.isReduceTransparencyEnabled { backgroundColor = .secondarySystemBackground }
    }
    required init?(coder: NSCoder) { return nil }
}

// Catalog I/O stays off the main thread; opening or changing quality never rebuilds all shader actions.
private enum RoxyShaderCatalog {
    private static var cached: [String]?
    private static var waiting: [([String]) -> Void] = []

    static func load(_ completion: @escaping ([String]) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { load(completion) }
            return
        }
        if let cached = cached { completion(cached); return }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var names: [String] = []
            if let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "RoxyAnime4K"),
               let data = try? Data(contentsOf: url),
               let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let shaders = manifest["shaders"] as? [[String: Any]] {
                names = shaders.compactMap { $0["name"] as? String }.sorted()
            }
            DispatchQueue.main.async { [names] in
                cached = names
                let completions = waiting
                waiting.removeAll()
                completions.forEach { $0(names) }
            }
        }
    }
}

@objc(RoxyLibraryStyle)
final class RoxyLibraryStyle: NSObject {
    @objc(decorateEmptyView:content:)
    static func decorate(_ view: UIView, content: UIView) {
        let glass = RoxyGlassView(radius: 32)
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(glass, belowSubview: content)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: -16),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 16),
            glass.topAnchor.constraint(equalTo: content.topAnchor, constant: -24),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 24)
        ])
    }
}

@objc(RoxyAnime4KSettingsController)
final class RoxyAnime4KSettingsController: UIViewController {
    private let defaults = UserDefaults.standard
    private let quality = UISegmentedControl(items: ["Auto", "Low", "Medium", "High"])
    private let mode = UISegmentedControl(items: ["Standard", "Soft", "Strong"])
    private let comparison = UISegmentedControl(items: ["Original", "Anime4K"])
    private let enabled = UISwitch()
    private let showStatus = UISwitch()
    private let qualityDetail = UILabel()
    private let modeDetail = UILabel()
    private let metrics = UILabel()
    private let shader = UIButton(type: .system)
    private var timer: Timer?
    private let values = ["automatic", "low", "medium", "high"]
    private let modes = ["standard", "soft", "strong"]
    private let deviceName = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Anime4K"
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = RoxyAppearance.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        let scroll = UIScrollView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 640)
        ])
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        stack.addArrangedSubview(label("Sharper anime", size: 26, weight: .bold))
        stack.addArrangedSubview(label("Restoration and upscaling powered by the Apple GPU.", size: 15, secondary: true))

        enabled.isOn = defaults.bool(forKey: "RoxyAnime4KEnabled")
        enabled.accessibilityIdentifier = "roxy.anime4k.enabled"
        enabled.addTarget(self, action: #selector(changeEnabled), for: .valueChanged)
        stack.addArrangedSubview(card([row("Anime4K", control: enabled)]))

        quality.selectedSegmentIndex = values.firstIndex(of: defaults.string(forKey: "RoxyAnime4KQuality") ?? "automatic") ?? 0
        quality.accessibilityIdentifier = "roxy.anime4k.quality"
        quality.addTarget(self, action: #selector(changeQuality), for: .valueChanged)
        quality.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        qualityDetail.font = .preferredFont(forTextStyle: .subheadline)
        qualityDetail.adjustsFontForContentSizeCategory = true
        qualityDetail.numberOfLines = 0
        qualityDetail.textColor = .secondaryLabel
        mode.selectedSegmentIndex = modes.firstIndex(of: defaults.string(forKey: "RoxyAnime4KMode") ?? "standard") ?? 0
        mode.accessibilityIdentifier = "roxy.anime4k.mode"
        mode.addTarget(self, action: #selector(changeMode), for: .valueChanged)
        mode.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        modeDetail.font = .preferredFont(forTextStyle: .subheadline)
        modeDetail.adjustsFontForContentSizeCategory = true
        modeDetail.numberOfLines = 0
        modeDetail.textColor = .secondaryLabel
        stack.addArrangedSubview(card([label("QUALITY", size: 11, weight: .semibold, secondary: true), quality, qualityDetail,
            label("RESTORATION", size: 11, weight: .semibold, secondary: true), mode, modeDetail]))

        comparison.selectedSegmentIndex = defaults.bool(forKey: "RoxyAnime4KPreviewOriginal") ? 0 : 1
        comparison.accessibilityIdentifier = "roxy.anime4k.comparison"
        comparison.addTarget(self, action: #selector(changeComparison), for: .valueChanged)
        comparison.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        metrics.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .medium))
        metrics.adjustsFontForContentSizeCategory = true
        metrics.numberOfLines = 0
        metrics.accessibilityIdentifier = "roxy.anime4k.metrics"
        stack.addArrangedSubview(card([label("LIVE PREVIEW", size: 11, weight: .semibold, secondary: true), comparison, metrics]))

        showStatus.isOn = defaults.bool(forKey: "RoxyAnime4KShowStatus")
        showStatus.accessibilityIdentifier = "roxy.anime4k.overlay"
        showStatus.addTarget(self, action: #selector(changeStatus), for: .valueChanged)
        shader.contentHorizontalAlignment = .leading
        shader.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        shader.titleLabel?.numberOfLines = 2
        shader.showsMenuAsPrimaryAction = true
        shader.accessibilityIdentifier = "roxy.anime4k.shader"
        shader.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        shader.menu = UIMenu(title: "Advanced shader", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            RoxyShaderCatalog.load { names in
                completion(self?.shaderActions(names) ?? [])
            }
        }])
        RoxyShaderCatalog.load { _ in }
        updateShaderMenu()
        stack.addArrangedSubview(card([row("Performance overlay", control: showStatus), shader,
            label("Changes apply during playback. Restoration also works at native size; extra pixels help when the video is smaller than the display. Low Power Mode, temperature and memory can limit quality. Picture in Picture uses the original player.", size: 13, secondary: true)]))
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
    @objc private func close() { dismiss(animated: true) }

    @objc private func changeEnabled() {
        defaults.set(enabled.isOn, forKey: "RoxyAnime4KEnabled")
        if enabled.isOn { comparison.selectedSegmentIndex = 1; defaults.set(false, forKey: "RoxyAnime4KPreviewOriginal") }
        PlaybackService.sharedInstance().applyAnime4KSettings()
        refresh()
    }
    @objc private func changeQuality() {
        defaults.set(values[quality.selectedSegmentIndex], forKey: "RoxyAnime4KQuality")
        defaults.set("preset", forKey: "RoxyAnime4KShader")
        updateShaderMenu()
        refresh()
    }
    @objc private func changeComparison() { defaults.set(comparison.selectedSegmentIndex == 0, forKey: "RoxyAnime4KPreviewOriginal"); refresh() }
    @objc private func changeMode() {
        defaults.set(modes[mode.selectedSegmentIndex], forKey: "RoxyAnime4KMode")
        defaults.set("preset", forKey: "RoxyAnime4KShader")
        updateShaderMenu()
        refresh()
    }
    @objc private func changeStatus() { defaults.set(showStatus.isOn, forKey: "RoxyAnime4KShowStatus") }

    private func refresh() {
        quality.isEnabled = enabled.isOn
        mode.isEnabled = enabled.isOn
        comparison.isEnabled = enabled.isOn
        let detail = ["Auto selects a quality for this GPU, then adapts to keep playback smooth.",
            "Low • fast small CNN, lowest memory and power use.",
            "Medium • more detailed restoration and upscaling.",
            "High keeps the largest preset active for maximum detail. Uses more GPU power and memory."][quality.selectedSegmentIndex]
        if qualityDetail.text != detail { qualityDetail.text = detail }
        let restoration = ["Standard • restores lines and reconstructs a larger image.",
            "Soft • gentler restoration for aliased lines and softer sources.",
            "Strong • adds restoration with Medium or High when enlarging at least 2× in each direction. Otherwise uses Standard."][mode.selectedSegmentIndex]
        if modeDetail.text != restoration { modeDetail.text = restoration }
        let value = PlaybackService.sharedInstance().anime4KRenderMetrics
        guard let width = value["inputWidth"] as? Int, let height = value["inputHeight"] as? Int else {
            let status = (value["status"] as? String).flatMap {
                !$0.isEmpty && $0 != "Waiting for video" ? $0 : nil
            } ?? "Ready for video. Open a video to see processing details."
            setMetrics(enabled.isOn ? "\(deviceName)\n\(status)" : "Original video • Anime4K is off")
            return
        }
        let output = "\(value["outputWidth"] ?? width) × \(value["outputHeight"] ?? height)"
        let time = (value["gpuMilliseconds"] as? Double).map { String(format: "%.1f ms GPU", $0) } ?? ""
        var text = "\(deviceName)\n\(value["status"] ?? "")\n\(width) × \(height) → \(output)\n\(value["passes"] ?? 0) passes · \(time)"
        if let fps = value["sourceFPS"] as? Double, fps > 0 {
            text += String(format: "\n%.1f fps source", fps)
        }
        if let skipped = value["skippedFrames"] as? Int, skipped > 0 {
            text += " · \(skipped) frames skipped"
        }
        setMetrics(text)
    }

    private func setMetrics(_ text: String) {
        if metrics.text != text { metrics.text = text }
    }

    private func updateShaderMenu() {
        let selected = defaults.string(forKey: "RoxyAnime4KShader") ?? "preset"
        shader.setTitle("Advanced shader  ›  " + (selected == "preset" ? "Quality preset" : selected.replacingOccurrences(of: "Anime4K_", with: "")), for: .normal)
    }

    private func shaderActions(_ names: [String]) -> [UIMenuElement] {
        let selected = defaults.string(forKey: "RoxyAnime4KShader") ?? "preset"
        let action: (String) -> UIAction = { name in
            UIAction(title: name == "preset" ? "Use quality preset" : name.replacingOccurrences(of: "Anime4K_", with: ""),
                     state: name == selected ? .on : .off) { [weak self] _ in
                self?.defaults.set(name, forKey: "RoxyAnime4KShader")
                self?.updateShaderMenu()
            }
        }
        let groups: [(String, (String) -> Bool)] = [
            ("Restore", { $0.hasPrefix("Anime4K_Restore_") }),
            ("Upscale", { $0.hasPrefix("Anime4K_Upscale_") }),
            ("Other filters", { !$0.hasPrefix("Anime4K_Restore_") && !$0.hasPrefix("Anime4K_Upscale_") })
        ]
        var result: [UIMenuElement] = [action("preset")]
        result.append(contentsOf: groups.compactMap { title, includes in
            let children = names.filter(includes).map(action)
            return children.isEmpty ? nil : UIMenu(title: title, children: children)
        })
        return result
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, secondary: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = secondary ? .secondaryLabel : .label
        label.numberOfLines = 0
        return label
    }
    private func row(_ title: String, control: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [label(title, size: 17, weight: .semibold), control])
        row.alignment = .center
        row.spacing = 12
        control.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }
    private func card(_ views: [UIView]) -> UIView {
        // The sheet already supplies system glass. Static cards avoid several full-screen blur passes
        // composited over a running video whenever the settings menu scrolls or animates.
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])
        return card
    }
}
#endif
