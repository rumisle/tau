import UIKit
import UniformTypeIdentifiers

private let tauPink = UIColor(red: 0xF2 / 255.0, green: 0x56 / 255.0, blue: 0x9A / 255.0, alpha: 1.0)
private let accent = UIColor(red: 0x2A / 255.0, green: 0x9E / 255.0, blue: 0xF1 / 255.0, alpha: 1.0)

/// Telegram's avatar gradients (top, bottom), in the order the app's Avatar picks them by chat ID.
private let avatarGradients: [(UInt32, UInt32)] = [(0xFF885E, 0xFF516A), (0xFFCD6A, 0xFFA85C), (0x82B1FF, 0x665FFF), (0xA0DE7E, 0x54CB68), (0x00FCFD, 0x4ACCCD), (0x72D5FD, 0x2A9EF1), (0xE0A2F3, 0xD669ED)]

private func color(_ rgb: UInt32) -> UIColor {
    return UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
}

private func avatarImage(title: String, index: Int, diameter: CGFloat) -> UIImage {
    let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).prefix(2)
    let letters = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    let (top, bottom) = avatarGradients[abs(index) % avatarGradients.count]
    return UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { context in
        let rect = CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter)
        context.cgContext.addEllipse(in: rect)
        context.cgContext.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(top).cgColor, color(bottom).cgColor] as CFArray, locations: [0.0, 1.0])!
        context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0.0, y: diameter), options: [])
        let text = NSAttributedString(string: letters, attributes: [.font: UIFont.systemFont(ofSize: floor(diameter * 26.0 / 60.0), weight: .bold).rounded, .foregroundColor: UIColor.white])
        let size = text.size()
        text.draw(at: CGPoint(x: (diameter - size.width) / 2.0, y: (diameter - size.height) / 2.0))
    }
}

/// The τ in pink, for New Chat.
private func newChatImage(diameter: CGFloat) -> UIImage {
    return UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { context in
        let cg = context.cgContext
        cg.addEllipse(in: CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter))
        cg.setFillColor(tauPink.cgColor)
        cg.fillPath()
        let scale = diameter / 24.0 * 0.62
        let origin = CGPoint(x: diameter / 2.0 - 11.9 * scale, y: diameter / 2.0 - 13.0 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            return CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        cg.move(to: p(3.2, 10.0))
        cg.addQuadCurve(to: p(7.0, 6.6), control: p(3.9, 6.7))
        cg.addLine(to: p(20.6, 6.6))
        cg.move(to: p(12.6, 6.6))
        cg.addLine(to: p(11.9, 15.2))
        cg.addQuadCurve(to: p(16.6, 19.4), control: p(11.5, 19.7))
        cg.setStrokeColor(UIColor.white.cgColor)
        cg.setLineWidth(2.6 * scale)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
    }
}

/// tau's share sheet, after Telegram's (ShareController): the chats as a grid of avatars to pick from, the list's
/// order with pinned chats first, New Chat leading; a search over them; what is shared and a comment at the bottom; Send
/// with how many it goes to. A new chat starts in a project picked from the recent ones. It sends itself, as a
/// follow-up where an agent is working; what it cannot send, tau sends when it opens.
final class ShareViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UITextViewDelegate, UISearchBarDelegate {
    private var snapshot = ShareSnapshot(servers: [], chats: [], projects: [])
    private var filtered: [ShareSnapshot.Chat] = []
    private var selected: [Int] = []
    private var newChatSelected = false
    private var project: ShareSnapshot.Project?

    private var sharedText = ""
    private var sharedImages: [UIImage] = []
    /// Files (a PDF, an archive, a video), copied here: the provider's URL lasts only while it is read.
    private var sharedFiles: [URL] = []

    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let searchBar = UISearchBar()
    private var collectionView: UICollectionView!
    private let bottomBar = UIView()
    private let previewLabel = UILabel()
    private let previewImage = UIImageView()
    private let commentView = UITextView()
    private let commentPlaceholder = UILabel()
    private let projectButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .custom)
    private let countBadge = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var bottomConstraint: NSLayoutConstraint!
    private var projectRow: UIView?
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemGroupedBackground
        self.loadSnapshot()
        self.buildViews()
        self.loadContent()
    }

    private func loadSnapshot() {
        if let snapshot = ShareGroup.snapshot {
            self.snapshot = snapshot
        }
        self.filtered = self.snapshot.chats
        self.project = self.snapshot.projects.first
    }

    private func buildViews() {
        self.titleLabel.text = "Send to"
        self.titleLabel.font = .systemFont(ofSize: 17.0, weight: .semibold)
        self.cancelButton.setTitle("Cancel", for: .normal)
        self.cancelButton.titleLabel?.font = .systemFont(ofSize: 17.0)
        self.cancelButton.addTarget(self, action: #selector(self.cancel), for: .touchUpInside)
        self.searchBar.searchBarStyle = .minimal
        self.searchBar.placeholder = "Search"
        self.searchBar.delegate = self

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 12.0
        layout.minimumInteritemSpacing = 0.0
        layout.sectionInset = UIEdgeInsets(top: 8.0, left: 12.0, bottom: 16.0, right: 12.0)
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        self.collectionView.backgroundColor = .clear
        self.collectionView.alwaysBounceVertical = true
        self.collectionView.keyboardDismissMode = .interactive
        self.collectionView.register(ShareChatCell.self, forCellWithReuseIdentifier: "chat")
        self.collectionView.dataSource = self
        self.collectionView.delegate = self

        self.emptyLabel.text = "Open tau once to list your chats here."
        self.emptyLabel.textColor = .secondaryLabel
        self.emptyLabel.font = .systemFont(ofSize: 15.0)
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.numberOfLines = 0
        self.emptyLabel.isHidden = !self.snapshot.servers.isEmpty

        self.bottomBar.backgroundColor = .secondarySystemGroupedBackground
        self.previewLabel.font = .systemFont(ofSize: 13.0)
        self.previewLabel.textColor = .secondaryLabel
        self.previewLabel.numberOfLines = 2
        self.previewImage.contentMode = .scaleAspectFill
        self.previewImage.clipsToBounds = true
        self.previewImage.layer.cornerRadius = 6.0
        self.commentView.font = .systemFont(ofSize: 17.0)
        self.commentView.backgroundColor = .tertiarySystemFill
        self.commentView.layer.cornerRadius = 18.0
        self.commentView.textContainerInset = UIEdgeInsets(top: 8.0, left: 10.0, bottom: 8.0, right: 10.0)
        self.commentView.isScrollEnabled = false
        self.commentView.delegate = self
        self.commentPlaceholder.text = "Add a comment…"
        self.commentPlaceholder.textColor = .placeholderText
        self.commentPlaceholder.font = .systemFont(ofSize: 17.0)
        self.projectButton.titleLabel?.font = .systemFont(ofSize: 15.0)
        self.projectButton.showsMenuAsPrimaryAction = true
        self.sendButton.backgroundColor = accent
        self.sendButton.layer.cornerRadius = 18.0
        self.sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16.0, weight: .bold)), for: .normal)
        self.sendButton.tintColor = .white
        self.sendButton.addTarget(self, action: #selector(self.send), for: .touchUpInside)
        self.sendButton.accessibilityLabel = "Send"
        self.countBadge.font = .systemFont(ofSize: 12.0, weight: .semibold)
        self.countBadge.textColor = accent
        self.countBadge.backgroundColor = .white
        self.countBadge.textAlignment = .center
        self.countBadge.layer.cornerRadius = 9.0
        self.countBadge.clipsToBounds = true
        self.spinner.color = .white

        for view in [self.titleLabel, self.cancelButton, self.searchBar, self.collectionView!, self.emptyLabel, self.bottomBar] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        // Rows that come and go (the photo, the new chat's project) in a stack, so a hidden one takes no room.
        let previewRow = UIStackView(arrangedSubviews: [self.previewImage, self.previewLabel])
        previewRow.axis = .horizontal
        previewRow.spacing = 10.0
        previewRow.alignment = .center
        let projectRow = UIStackView(arrangedSubviews: [self.projectButton, UIView()])
        projectRow.axis = .horizontal
        let inputRow = UIView()
        for view in [self.commentView, self.commentPlaceholder, self.sendButton, self.countBadge] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            inputRow.addSubview(view)
        }
        let stack = UIStackView(arrangedSubviews: [previewRow, projectRow, inputRow])
        stack.axis = .vertical
        stack.spacing = 8.0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.bottomBar.addSubview(stack)
        self.projectRow = projectRow
        self.spinner.translatesAutoresizingMaskIntoConstraints = false
        self.sendButton.addSubview(self.spinner)
        let guide = self.view.safeAreaLayoutGuide
        // Over the keyboard when it is up, at the bottom when it is not.
        self.view.keyboardLayoutGuide.usesBottomSafeArea = false
        self.bottomConstraint = self.bottomBar.bottomAnchor.constraint(equalTo: self.view.keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            self.titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14.0),
            self.titleLabel.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            self.cancelButton.centerYAnchor.constraint(equalTo: self.titleLabel.centerYAnchor),
            self.cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16.0),
            self.searchBar.topAnchor.constraint(equalTo: self.titleLabel.bottomAnchor, constant: 8.0),
            self.searchBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8.0),
            self.searchBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8.0),
            self.collectionView.topAnchor.constraint(equalTo: self.searchBar.bottomAnchor),
            self.collectionView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            self.collectionView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            self.collectionView.bottomAnchor.constraint(equalTo: self.bottomBar.topAnchor),
            self.emptyLabel.centerYAnchor.constraint(equalTo: self.collectionView.centerYAnchor),
            self.emptyLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32.0),
            self.emptyLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32.0),
            self.bottomBar.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.bottomBar.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.bottomConstraint,
            stack.topAnchor.constraint(equalTo: self.bottomBar.topAnchor, constant: 10.0),
            stack.leadingAnchor.constraint(equalTo: self.bottomBar.leadingAnchor, constant: 16.0),
            stack.trailingAnchor.constraint(equalTo: self.bottomBar.trailingAnchor, constant: -12.0),
            stack.bottomAnchor.constraint(equalTo: self.bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -8.0),
            self.previewImage.widthAnchor.constraint(equalToConstant: 36.0),
            self.previewImage.heightAnchor.constraint(equalToConstant: 36.0),
            self.commentView.topAnchor.constraint(equalTo: inputRow.topAnchor),
            self.commentView.bottomAnchor.constraint(equalTo: inputRow.bottomAnchor),
            self.commentView.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: -4.0),
            self.commentView.trailingAnchor.constraint(equalTo: self.sendButton.leadingAnchor, constant: -8.0),
            self.commentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 36.0),
            self.commentView.heightAnchor.constraint(lessThanOrEqualToConstant: 110.0),
            self.commentPlaceholder.leadingAnchor.constraint(equalTo: self.commentView.leadingAnchor, constant: 15.0),
            self.commentPlaceholder.centerYAnchor.constraint(equalTo: self.commentView.topAnchor, constant: 18.0),
            self.sendButton.trailingAnchor.constraint(equalTo: inputRow.trailingAnchor),
            self.sendButton.bottomAnchor.constraint(equalTo: self.commentView.bottomAnchor),
            self.sendButton.widthAnchor.constraint(equalToConstant: 36.0),
            self.sendButton.heightAnchor.constraint(equalToConstant: 36.0),
            self.countBadge.centerXAnchor.constraint(equalTo: self.sendButton.trailingAnchor, constant: -4.0),
            self.countBadge.centerYAnchor.constraint(equalTo: self.sendButton.topAnchor, constant: 4.0),
            self.countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0),
            self.countBadge.heightAnchor.constraint(equalToConstant: 18.0),
            self.spinner.centerXAnchor.constraint(equalTo: self.sendButton.centerXAnchor),
            self.spinner.centerYAnchor.constraint(equalTo: self.sendButton.centerYAnchor),
        ])
        self.updateProjectButton()
        self.updateSendState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Four avatars a row, as Telegram's share grid.
        if let layout = self.collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let width = floor((self.collectionView.bounds.width - 24.0) / 4.0)
            if layout.itemSize.width != width {
                layout.itemSize = CGSize(width: width, height: 96.0)
            }
        }
    }

    // MARK: - What is shared

    private func loadContent() {
        let providers = (self.extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        var texts: [String] = []
        var urls: [String] = []
        var images: [UIImage] = []
        var files: [URL] = []
        let lock = NSLock()
        for provider in providers {
            // A file that is no image, link or text (one from Files, a PDF from Safari): as it is, to upload.
            let isFile = provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            if isFile || (provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)) {
                group.enter()
                let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    if let url {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let copy = directory.appendingPathComponent(provider.suggestedName.map { name in (url.pathExtension.isEmpty || name.hasSuffix(".\(url.pathExtension)")) ? name : "\(name).\(url.pathExtension)" } ?? url.lastPathComponent)
                        if (try? FileManager.default.copyItem(at: url, to: copy)) != nil {
                            lock.lock()
                            files.append(copy)
                            lock.unlock()
                        }
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                    var image: UIImage?
                    if let url = item as? URL, let data = try? Data(contentsOf: url) {
                        image = UIImage(data: data)
                    } else if let data = item as? Data {
                        image = UIImage(data: data)
                    } else if let value = item as? UIImage {
                        image = value
                    }
                    if let image {
                        lock.lock()
                        images.append(image)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    if let url = item as? URL, !url.isFileURL {
                        lock.lock()
                        urls.append(url.absoluteString)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    if let text = item as? String {
                        lock.lock()
                        texts.append(text)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            // A link shared with its page's title comes as both; the title, then the link.
            self.sharedText = (texts + urls.filter { url in !texts.contains(where: { $0.contains(url) }) }).joined(separator: "\n")
            self.sharedImages = images
            self.sharedFiles = files
            self.previewImage.image = images.first ?? (files.isEmpty ? nil : UIImage(systemName: "doc.fill"))
            self.previewImage.isHidden = images.isEmpty && files.isEmpty
            var preview = self.sharedText.replacingOccurrences(of: "\n", with: " ")
            var parts: [String] = []
            if !images.isEmpty {
                parts.append(images.count == 1 ? "Photo" : "\(images.count) Photos")
            }
            if !files.isEmpty {
                parts.append(files.count == 1 ? files[0].lastPathComponent : "\(files.count) Files")
            }
            if preview.isEmpty {
                preview = parts.joined(separator: " · ")
            } else if !parts.isEmpty {
                preview = parts.joined(separator: " · ") + " · " + preview
            }
            self.previewLabel.text = preview
            self.updateSendState()
        }
    }

    // MARK: - Choosing

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.snapshot.projects.isEmpty ? self.filtered.count : self.filtered.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "chat", for: indexPath) as! ShareChatCell
        let offset = self.snapshot.projects.isEmpty ? 0 : 1
        if indexPath.item < offset {
            cell.update(image: newChatImage(diameter: 60.0), title: "New Chat", subtitle: nil, selected: self.newChatSelected)
        } else {
            let chat = self.filtered[indexPath.item - offset]
            let multi = self.snapshot.servers.count > 1
            cell.update(image: avatarImage(title: chat.title, index: chat.id, diameter: 60.0), title: chat.title, subtitle: chat.busy ? "working" : (multi ? chat.project : nil), selected: self.selected.contains(chat.id))
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let offset = self.snapshot.projects.isEmpty ? 0 : 1
        if indexPath.item < offset {
            self.newChatSelected.toggle()
        } else {
            let id = self.filtered[indexPath.item - offset].id
            if let index = self.selected.firstIndex(of: id) {
                self.selected.remove(at: index)
            } else {
                self.selected.append(id)
            }
        }
        UISelectionFeedbackGenerator().selectionChanged()
        collectionView.reloadItems(at: [indexPath])
        self.updateProjectButton()
        self.updateSendState()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let words = searchText.lowercased().split(separator: " ").map(String.init)
        self.filtered = words.isEmpty ? self.snapshot.chats : self.snapshot.chats.filter { chat in
            let haystack = "\(chat.title) \(chat.project)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        self.collectionView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        self.commentPlaceholder.isHidden = !textView.text.isEmpty
        self.updateSendState()
    }

    private func updateProjectButton() {
        self.projectRow?.isHidden = !self.newChatSelected
        let title = "New chat in \(self.project?.title ?? "–") ▾"
        self.projectButton.setTitle(title, for: .normal)
        self.projectButton.menu = UIMenu(children: self.snapshot.projects.map { project in
            UIAction(title: project.title, subtitle: project.path, state: project.path == self.project?.path && project.slot == self.project?.slot ? .on : .off) { [weak self] _ in
                self?.project = project
                self?.updateProjectButton()
            }
        })
    }

    private func updateSendState() {
        let count = self.selected.count + (self.newChatSelected ? 1 : 0)
        let hasContent = !self.sharedText.isEmpty || !self.sharedImages.isEmpty || !self.sharedFiles.isEmpty || !self.commentView.text.isEmpty
        self.sendButton.isEnabled = count > 0 && hasContent
        self.sendButton.alpha = self.sendButton.isEnabled ? 1.0 : 0.4
        self.countBadge.text = "\(count)"
        self.countBadge.isHidden = count < 2
    }

    // MARK: - Sending

    @objc private func cancel() {
        self.extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func send() {
        let comment = self.commentView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = [comment, self.sharedText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        // As the app sends photos.
        let images = self.sharedImages.compactMap { ImageEncoding.jpeg($0) }
        let chats = self.snapshot.chats.filter { self.selected.contains($0.id) }
        let newChat = self.newChatSelected ? self.project : nil
        self.sendButton.isEnabled = false
        self.sendButton.setImage(nil, for: .normal)
        self.spinner.startAnimating()
        let servers = self.snapshot.servers
        let files = self.sharedFiles
        Task {
            let failed = await ShareSender.send(text: text, images: images, files: files, chats: chats, newChat: newChat, servers: servers)
            await MainActor.run {
                if failed.chats.isEmpty && failed.newChat == nil {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else if let reason = failed.reason {
                    // The server answered no: nothing to leave for later.
                    let alert = UIAlertController(title: "Not Sent", message: reason, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                        // Back as it was, to pick otherwise or cancel.
                        self?.sendButton.isEnabled = true
                        self?.sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16.0, weight: .bold)), for: .normal)
                        self?.spinner.stopAnimating()
                    })
                    self.present(alert, animated: true)
                } else if !files.isEmpty {
                    // Files are too large to leave in the keychain for the app: shared again once the server is back.
                    let alert = UIAlertController(title: "Not Sent", message: "The server could not be reached, and files are not kept for later: share them again once it is.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    })
                    self.present(alert, animated: true)
                } else {
                    ShareSender.leaveForApp(text: text, images: images, chats: failed.chats, newChat: failed.newChat)
                    let alert = UIAlertController(title: "Not Sent Yet", message: "The server could not be reached. tau sends it when it opens.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    })
                    self.present(alert, animated: true)
                }
            }
        }
    }
}

/// An avatar with its title under it, as ShareControllerPeerGridItem; picked, a ring and a check.
final class ShareChatCell: UICollectionViewCell {
    private let avatar = UIImageView()
    private let ring = UIView()
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private let title = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.ring.layer.borderColor = accent.cgColor
        self.ring.layer.borderWidth = 2.0
        self.ring.layer.cornerRadius = 33.0
        self.check.tintColor = accent
        self.check.backgroundColor = .systemBackground
        self.check.layer.cornerRadius = 11.0
        self.title.font = .systemFont(ofSize: 12.0)
        self.title.textAlignment = .center
        self.title.numberOfLines = 2
        for view in [self.ring, self.avatar, self.check, self.title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            self.avatar.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 4.0),
            self.avatar.centerXAnchor.constraint(equalTo: self.contentView.centerXAnchor),
            self.avatar.widthAnchor.constraint(equalToConstant: 60.0),
            self.avatar.heightAnchor.constraint(equalToConstant: 60.0),
            self.ring.centerXAnchor.constraint(equalTo: self.avatar.centerXAnchor),
            self.ring.centerYAnchor.constraint(equalTo: self.avatar.centerYAnchor),
            self.ring.widthAnchor.constraint(equalToConstant: 66.0),
            self.ring.heightAnchor.constraint(equalToConstant: 66.0),
            self.check.trailingAnchor.constraint(equalTo: self.avatar.trailingAnchor, constant: 2.0),
            self.check.bottomAnchor.constraint(equalTo: self.avatar.bottomAnchor, constant: 2.0),
            self.check.widthAnchor.constraint(equalToConstant: 22.0),
            self.check.heightAnchor.constraint(equalToConstant: 22.0),
            self.title.topAnchor.constraint(equalTo: self.avatar.bottomAnchor, constant: 6.0),
            self.title.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 2.0),
            self.title.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -2.0),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(image: UIImage, title: String, subtitle: String?, selected: Bool) {
        self.avatar.image = image
        let text = NSMutableAttributedString(string: title, attributes: [.font: UIFont.systemFont(ofSize: 12.0), .foregroundColor: selected ? accent : UIColor.label])
        if let subtitle {
            text.append(NSAttributedString(string: "\n\(subtitle)", attributes: [.font: UIFont.systemFont(ofSize: 11.0), .foregroundColor: subtitle == "working" ? accent : UIColor.secondaryLabel]))
        }
        self.title.attributedText = text
        self.title.numberOfLines = subtitle == nil ? 2 : 2
        self.ring.isHidden = !selected
        self.check.isHidden = !selected
        self.avatar.transform = selected ? CGAffineTransform(scaleX: 0.86, y: 0.86) : .identity
        self.accessibilityLabel = title
        self.isAccessibilityElement = true
        self.accessibilityTraits = selected ? [.button, .selected] : .button
    }
}

private extension UIFont {
    /// SF Rounded, as Telegram's avatar letters.
    var rounded: UIFont {
        return self.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: self.pointSize) } ?? self
    }
}
