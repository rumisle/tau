import UIKit
import SafariServices
import AsyncDisplayKit
import Display
import SwiftSignalKit
import UndoUI

/// A login the server runs (docs/accounts.md): it shows what the provider's flow says, a code to enter on a page with
/// the page a tap away, a field for what to paste back or type, a choice; it answers the flow's questions, and closes
/// when the account is added. Leaving it cancels the login.
final class LoginController: SettingsListController {
    private let slot: Int
    private let provider: String
    private let providerName: String
    private let type: String
    private var loginId: String?
    private var startError: String?
    private var state: AccountsState?
    private let stateDisposable = MetaDisposable()
    /// What is typed for the prompt on screen, by the prompt's ID.
    private var answer = ""
    private var answeredPrompt: String?
    private var finished = false
    private weak var safari: SFSafariViewController?

    init(context: AppContext, slot: Int, provider: String, providerName: String, type: String) {
        self.slot = slot
        self.provider = provider
        self.providerName = providerName
        self.type = type
        super.init(context: context, title: type == "oauth" ? ProviderAccount.serviceName(provider: provider, providerName: providerName, subscription: true) : providerName)
        if let server = context.store.server(slot) {
            self.stateDisposable.set((server.accountsSignal |> deliverOnMainQueue).start(next: { [weak self] state in
                self?.state = state
                self?.stateChanged()
            }))
        }
        self.start()
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stateDisposable.dispose()
    }

    private var server: TauServer? {
        return self.context.store.server(self.slot)
    }

    private var session: LoginSession? {
        return self.loginId.flatMap { self.state?.login($0) }
    }

    private func start() {
        self.loginId = nil
        self.startError = nil
        self.answer = ""
        self.answeredPrompt = nil
        self.reload()
        self.server?.startLogin(provider: self.provider, type: self.type) { [weak self] result in
            Queue.mainQueue().async {
                guard let self else {
                    return
                }
                switch result {
                case let .success(id):
                    self.loginId = id
                case let .failure(error):
                    self.startError = error.message
                }
                self.stateChanged()
            }
        }
    }

    private func stateChanged() {
        if let session = self.session, case let .account(accountId) = session.done, !self.finished {
            self.finished = true
            self.safari?.dismiss(animated: true)
            let title = self.state?.account(accountId)?.title ?? "the account"
            let navigationController = self.navigationController as? NavigationController
            let toast = UndoOverlayController(presentationData: self.theme.presentationData, content: .succeed(text: "Signed in as **\(title)**", timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false })
            // Back to the accounts, where it shows in use, and the toast there, above the tab bar.
            if let navigationController, let accounts = navigationController.viewControllers.last(where: { $0 is AccountsController || $0 is AccountController }) as? ViewController {
                navigationController.popToViewController(accounts, animated: true)
                accounts.present(toast, in: .current)
            } else if let navigationController, let root = navigationController.viewControllers.first as? RootTabController {
                navigationController.popToRoot(animated: true)
                (root.controllers.first { $0 is AccountsController } ?? root).present(toast, in: .current)
            }
            return
        }
        if let session = self.session, session.done == .cancelled, !self.finished {
            self.finished = true
            return
        }
        // A new question: what was typed for the last one goes.
        if let prompt = self.session?.prompt, prompt.id != self.answeredPrompt, self.answeredPrompt != nil {
            self.answeredPrompt = nil
            self.answer = ""
        }
        self.reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Gone back from: the login ends with it.
        if let loginId = self.loginId, !self.finished, self.navigationController == nil || !(self.navigationController?.viewControllers.contains(self) ?? false) {
            self.finished = true
            self.server?.cancelLogin(loginId)
        }
    }

    override func items(theme: TauTheme) -> [ListViewItem] {
        let single = SettingsRowPosition(isFirst: true, isLast: true)
        var items: [ListViewItem] = []
        if let error = self.startError {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(self.tryAgainRow(theme: theme))
            items.append(SettingsTextItem(theme: theme, text: error, kind: .footer))
            return items
        }
        guard let session = self.session else {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(ActivityRowItem(theme: theme, text: "Starting…", position: single))
            return items
        }
        if case let .failed(error) = session.done {
            items.append(SettingsTextItem(theme: theme, text: "Couldn't Sign In", kind: .header))
            items.append(self.tryAgainRow(theme: theme))
            items.append(SettingsTextItem(theme: theme, text: error, kind: .footer))
            return items
        }
        if session.done != nil {
            return items
        }

        // A code to enter on a page: the code, the page, then the wait.
        if let device = session.deviceCode {
            let host = device.url.host ?? device.url.absoluteString
            items.append(SettingsTextItem(theme: theme, text: "Enter this code at \(host)", kind: .header))
            items.append(LoginCodeItem(theme: theme, code: device.code, action: { [weak self] in
                self?.copy(device.code)
            }))
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Copy Code and Open \(host)", titleColor: theme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: false), action: { [weak self] in
                UIPasteboard.general.string = device.code
                self?.open(device.url)
            }))
            // To open it on another device.
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Copy Link", titleColor: theme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: false), action: { [weak self] in
                self?.copyLink(device.url)
            }))
            items.append(ActivityRowItem(theme: theme, text: session.progress ?? "Waiting for you to sign in", position: SettingsRowPosition(isFirst: false, isLast: true)))
            items.append(SettingsTextItem(theme: theme, text: "This closes on its own once you have signed in.", kind: .footer))
        } else if let page = session.authURL {
            let host = page.url.host ?? "the page"
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Open \(host)", titleColor: theme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: false), action: { [weak self] in
                self?.open(page.url)
            }))
            items.append(SettingsRowItem(theme: theme, icon: nil, title: "Copy Link", titleColor: theme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: true), action: { [weak self] in
                self?.copyLink(page.url)
            }))
            items.append(SettingsTextItem(theme: theme, text: self.pageInstructions(session, host: host), kind: .footer))
        }

        if let prompt = session.prompt {
            items.append(contentsOf: self.promptItems(prompt, session: session, theme: theme))
        } else if session.deviceCode == nil {
            items.append(SettingsTextItem(theme: theme, text: "", kind: .header))
            items.append(ActivityRowItem(theme: theme, text: session.progress ?? "Signing in", position: single))
        }
        for event in session.events {
            if case let .info(message, _) = event {
                items.append(SettingsTextItem(theme: theme, text: message, kind: .footer))
            }
        }
        return items
    }

    /// What to do on the page, in tau's words: pi's instructions speak of a terminal.
    private func pageInstructions(_ session: LoginSession, host: String) -> String {
        guard let prompt = session.prompt, prompt.kind == .manualCode else {
            return "Sign in on \(host). This continues once you have."
        }
        if session.provider == "anthropic" {
            return "Sign in on \(host), then copy the code it shows and paste it below."
        }
        return "Sign in on \(host). When the page fails to load at the end, copy its address and paste it below."
    }

    private func promptItems(_ prompt: LoginSession.Prompt, session: LoginSession, theme: TauTheme) -> [ListViewItem] {
        var items: [ListViewItem] = []
        let sending = self.answeredPrompt == prompt.id
        switch prompt.kind {
        case let .select(options):
            items.append(SettingsTextItem(theme: theme, text: prompt.message, kind: .header))
            for (index, option) in options.enumerated() {
                items.append(SettingsRowItem(theme: theme, icon: nil, title: option.label, subtitle: option.detail, accessory: .disclosure(label: ""), position: SettingsRowPosition(isFirst: index == 0, isLast: index == options.count - 1), action: { [weak self] in
                    self?.send(option.id, to: prompt)
                }))
            }
        case .text, .secret, .manualCode:
            let header: String
            switch prompt.kind {
            case .manualCode:
                header = session.provider == "anthropic" ? "Code" : "Address or Code"
            default:
                header = prompt.message
            }
            items.append(SettingsTextItem(theme: theme, text: header, kind: .header))
            let placeholder: String
            switch prompt.kind {
            case .secret:
                placeholder = "Key"
            case .manualCode:
                placeholder = "Paste here"
            default:
                placeholder = prompt.placeholder ?? ""
            }
            let field = SettingsInputItem(theme: theme, text: self.answer, placeholder: placeholder, position: SettingsRowPosition(isFirst: true, isLast: false), maxLength: 4096, changed: { [weak self] text in
                guard let self else {
                    return
                }
                let wasEmpty = self.answer.isEmpty
                self.answer = text
                if wasEmpty != text.isEmpty {
                    self.reload()
                }
            })
            field.secure = prompt.kind == .secret
            field.verbatim = true
            field.focused = prompt.kind != .manualCode
            field.submit = { [weak self] in
                guard let self, !self.answer.isEmpty else {
                    return
                }
                self.send(self.answer, to: prompt)
            }
            items.append(field)
            if sending {
                items.append(ActivityRowItem(theme: theme, text: "Checking", position: SettingsRowPosition(isFirst: false, isLast: true)))
            } else {
                let ready = !self.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                items.append(SettingsRowItem(theme: theme, icon: nil, title: "Continue", titleColor: ready ? theme.list.itemAccentColor : theme.presentationTheme.list.itemDisabledTextColor, accessory: .none, position: SettingsRowPosition(isFirst: false, isLast: true), action: ready ? { [weak self] in
                    guard let self else {
                        return
                    }
                    self.send(self.answer, to: prompt)
                } : nil))
            }
            if prompt.kind == .text, prompt.placeholder != nil {
                items.append(SettingsTextItem(theme: theme, text: "For example \(prompt.placeholder ?? "")", kind: .footer))
            }
        }
        return items
    }

    private func send(_ value: String, to prompt: LoginSession.Prompt) {
        guard let loginId = self.loginId else {
            return
        }
        self.answeredPrompt = prompt.id
        self.view.endEditing(true)
        self.reload()
        self.server?.answerLogin(loginId, prompt: prompt.id, value: value.trimmingCharacters(in: .whitespacesAndNewlines)) { [weak self] error in
            Queue.mainQueue().async {
                guard let self, let error else {
                    return
                }
                self.answeredPrompt = nil
                self.reload()
                self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .info(title: nil, text: error.message, timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
            }
        }
    }

    private func tryAgainRow(theme: TauTheme) -> ListViewItem {
        return SettingsRowItem(theme: theme, icon: nil, title: "Try Again", titleColor: theme.list.itemAccentColor, accessory: .none, position: SettingsRowPosition(isFirst: true, isLast: true), action: { [weak self] in
            self?.finished = false
            self?.start()
        })
    }

    private func copyLink(_ url: URL) {
        UIPasteboard.general.url = url
        self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .linkCopied(title: nil, text: self.theme.presentationStrings.Conversation_LinkCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        self.present(UndoOverlayController(presentationData: self.theme.presentationData, content: .copy(text: "Code copied"), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .current)
    }

    /// The page in Safari over the app: it closes by itself once the server has the account.
    private func open(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .done
        self.safari = safari
        self.view.window?.rootViewController?.present(safari, animated: true)
    }
}
