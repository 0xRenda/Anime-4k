#if os(iOS)
import UIKit

enum RoxyAppearance {
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.40, green: 0.92, blue: 0.84, alpha: 1) :
            UIColor(red: 0.02, green: 0.43, blue: 0.43, alpha: 1)
    }

    @discardableResult
    static func glass(behind view: UIView, radius: CGFloat = 24) -> RoxyGlassView {
        let glass = RoxyGlassView(radius: radius)
        glass.frame = view.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.isUserInteractionEnabled = false
        view.insertSubview(glass, at: 0)
        view.backgroundColor = .clear
        return glass
    }

    static func presentSettings(from controller: UIViewController) {
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
        let material: UIVisualEffect
        if UIAccessibility.isReduceTransparencyEnabled {
            material = UIBlurEffect(style: .systemThickMaterial)
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
    private let comparison = UISegmentedControl(items: ["Original", "Anime4K"])
    private let enabled = UISwitch()
    private let showStatus = UISwitch()
    private let qualityDetail = UILabel()
    private let metrics = UILabel()
    private let shader = UIButton(type: .system)
    private var timer: Timer?
    private let values = ["automatic", "low", "medium", "high"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Anime4K"
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = RoxyAppearance.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        let scroll = UIScrollView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        stack.addArrangedSubview(label("Sharper lines.\nOriginal colors.", size: 30, weight: .bold))
        stack.addArrangedSubview(label("Real-time anime upscaling on your device.", size: 15, secondary: true))

        enabled.isOn = defaults.bool(forKey: "RoxyAnime4KEnabled")
        enabled.accessibilityIdentifier = "roxy.anime4k.enabled"
        enabled.addTarget(self, action: #selector(changeEnabled), for: .valueChanged)
        stack.addArrangedSubview(card([row("Anime4K", control: enabled)]))

        quality.selectedSegmentIndex = values.firstIndex(of: defaults.string(forKey: "RoxyAnime4KQuality") ?? "automatic") ?? 0
        quality.accessibilityIdentifier = "roxy.anime4k.quality"
        quality.addTarget(self, action: #selector(changeQuality), for: .valueChanged)
        quality.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        qualityDetail.font = .preferredFont(forTextStyle: .subheadline)
        qualityDetail.numberOfLines = 0
        qualityDetail.textColor = .secondaryLabel
        stack.addArrangedSubview(card([label("QUALITY", size: 11, weight: .semibold, secondary: true), quality, qualityDetail]))

        comparison.selectedSegmentIndex = defaults.bool(forKey: "RoxyAnime4KPreviewOriginal") ? 0 : 1
        comparison.accessibilityIdentifier = "roxy.anime4k.comparison"
        comparison.addTarget(self, action: #selector(changeComparison), for: .valueChanged)
        comparison.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        metrics.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        metrics.numberOfLines = 0
        metrics.accessibilityIdentifier = "roxy.anime4k.metrics"
        stack.addArrangedSubview(card([label("LIVE PREVIEW", size: 11, weight: .semibold, secondary: true), comparison, metrics]))

        showStatus.isOn = defaults.bool(forKey: "RoxyAnime4KShowStatus")
        showStatus.addTarget(self, action: #selector(changeStatus), for: .valueChanged)
        shader.contentHorizontalAlignment = .leading
        shader.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        shader.titleLabel?.numberOfLines = 2
        shader.showsMenuAsPrimaryAction = true
        shader.accessibilityIdentifier = "roxy.anime4k.shader"
        updateShaderMenu()
        stack.addArrangedSubview(card([row("Performance overlay", control: showStatus), shader,
            label("Quality changes apply during playback. Auto adapts to rendering time, Low Power Mode and temperature. Picture in Picture uses the original player with Anime4K off.", size: 13, secondary: true)]))
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
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
    @objc private func changeStatus() { defaults.set(showStatus.isOn, forKey: "RoxyAnime4KShowStatus") }

    private func refresh() {
        quality.isEnabled = enabled.isOn
        comparison.isEnabled = enabled.isOn
        qualityDetail.text = ["Automatic • balances sharpness and smooth playback.",
            "Low • fast small CNN, lowest memory and power use.",
            "Medium • more detailed restoration and upscaling.",
            "High • large CNN for powerful iPads and iPhones. Uses more power."][quality.selectedSegmentIndex]
        let value = PlaybackService.sharedInstance().anime4KRenderMetrics
        guard let width = value["inputWidth"] as? Int, let height = value["inputHeight"] as? Int else {
            metrics.text = enabled.isOn ? "Ready for video\nOpen a video to see processing details." : "Original video • Anime4K is off"
            return
        }
        let output = "\(value["outputWidth"] ?? width) × \(value["outputHeight"] ?? height)"
        let time = (value["gpuMilliseconds"] as? Double).map { String(format: "%.1f ms GPU", $0) } ?? ""
        metrics.text = "\(value["status"] ?? "")\n\(width) × \(height) → \(output)\n\(value["passes"] ?? 0) passes · \(time)"
    }

    private func updateShaderMenu() {
        let selected = defaults.string(forKey: "RoxyAnime4KShader") ?? "preset"
        shader.setTitle("Advanced shader  ›  " + (selected == "preset" ? "Quality preset" : selected.replacingOccurrences(of: "Anime4K_", with: "")), for: .normal)
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "RoxyAnime4K"),
              let data = try? Data(contentsOf: url), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shaders = manifest["shaders"] as? [[String: Any]] else { return }
        let names = ["preset"] + shaders.compactMap { $0["name"] as? String }.sorted()
        shader.menu = UIMenu(title: "Advanced shader", children: names.map { name in
            UIAction(title: name == "preset" ? "Use quality preset" : name.replacingOccurrences(of: "Anime4K_", with: ""),
                     state: name == selected ? .on : .off) { [weak self] _ in
                self?.defaults.set(name, forKey: "RoxyAnime4KShader"); self?.updateShaderMenu()
            }
        })
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
        let glass = RoxyGlassView()
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -20)
        ])
        return glass
    }
}
#endif
