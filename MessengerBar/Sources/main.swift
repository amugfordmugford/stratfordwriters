// MessengerBar — a tiny macOS menu bar app for Facebook Messenger.
//
// Left-click the menu bar icon to open Messenger in a popover; right-click for
// options. It hosts the real messenger.com web client in a WKWebView, so every
// operation Messenger supports (send, read, edit, unsend/delete, reactions,
// attachments) works exactly as it does in a browser, and your login is kept in
// the app's persistent web data store.

import AppKit
import ServiceManagement
import UserNotifications
import WebKit

// MARK: - Preferences

enum Source: String, CaseIterable {
    case messenger = "https://www.messenger.com/"
    case facebook = "https://www.facebook.com/messages/"

    var title: String {
        switch self {
        case .messenger: return "messenger.com"
        case .facebook: return "facebook.com/messages"
        }
    }
}

enum PopoverSize: String, CaseIterable {
    case compact, regular, large

    var size: NSSize {
        switch self {
        case .compact: return NSSize(width: 380, height: 560)
        case .regular: return NSSize(width: 460, height: 680)
        case .large: return NSSize(width: 620, height: 820)
        }
    }

    var title: String { rawValue.capitalized }
}

enum Prefs {
    private static var defaults: UserDefaults { .standard }

    static var source: Source {
        get { Source(rawValue: defaults.string(forKey: "source") ?? "") ?? .messenger }
        set { defaults.set(newValue.rawValue, forKey: "source") }
    }

    static var popoverSize: PopoverSize {
        get { PopoverSize(rawValue: defaults.string(forKey: "popoverSize") ?? "") ?? .regular }
        set { defaults.set(newValue.rawValue, forKey: "popoverSize") }
    }
}

// MARK: - URL helpers

enum Links {
    /// Hosts that belong in the in-app web view. Anything else opens in the default browser.
    static let internalSuffixes = [
        "messenger.com", "facebook.com", "fb.com", "fbcdn.net", "fbsbx.com",
        "facebook.net", "meta.com", "accountscenter.meta.com",
    ]

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true } // about:blank, data:, etc.
        if isRedirector(url) { return false }
        return internalSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Messenger wraps outbound links as l.messenger.com/l.php?u=<target>.
    static func isRedirector(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return (host.hasPrefix("l.") || host.hasPrefix("lm.")) && url.path.hasSuffix("l.php")
    }

    static func unwrap(_ url: URL) -> URL {
        guard isRedirector(url),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              let real = URL(string: target)
        else { return url }
        return real
    }

    static func openExternally(_ url: URL) {
        NSWorkspace.shared.open(unwrap(url))
    }
}

// MARK: - Web view controller

@MainActor
final class WebViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    var onNotification: ((_ title: String, _ body: String, _ tag: String) -> Void)?

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Bridges the web Notification API to native notifications (WKWebView has none of its own).
    private static let notificationShim = """
    (function () {
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.notify) return;
      const post = (title, opts) => {
        try {
          window.webkit.messageHandlers.notify.postMessage({
            title: String(title || ''),
            body: String((opts && opts.body) || ''),
            tag: String((opts && opts.tag) || '')
          });
        } catch (e) {}
      };
      class BarNotification extends EventTarget {
        constructor(title, opts) {
          super();
          this.title = title;
          Object.assign(this, opts || {});
          this.onclick = this.onclose = this.onshow = this.onerror = null;
          post(title, opts);
        }
        close() {}
        static get permission() { return 'granted'; }
        static requestPermission(cb) { if (cb) cb('granted'); return Promise.resolve('granted'); }
      }
      Object.defineProperty(window, 'Notification', { value: BarNotification, writable: true, configurable: true });
    })();
    """

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: keeps you signed in
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init(nibName: nil, bundle: nil)

        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: Self.notificationShim,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(ScriptBridge(owner: self), name: "notify")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() { view = webView }

    func loadHome() {
        webView.load(URLRequest(url: URL(string: Prefs.source.rawValue)!))
    }

    func focus() {
        view.window?.makeFirstResponder(webView)
    }

    fileprivate func handleScriptMessage(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        onNotification?(dict["title"] as? String ?? "Messenger",
                        dict["body"] as? String ?? "",
                        dict["tag"] as? String ?? "")
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url else { return decisionHandler(.allow) }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if isMainFrame, action.navigationType == .linkActivated, !Links.isInternal(url) {
            Links.openExternally(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: Downloads (saving photos / files from a chat)

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString)
        var candidate = downloads.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = name.deletingPathExtension
            let ext = name.pathExtension
            candidate = downloads.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        completionHandler(candidate)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("MessengerBar download failed: \(error.localizedDescription)")
    }

    // MARK: UI delegate

    /// target="_blank" links and window.open().
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme?.hasPrefix("http") == true {
            if Links.isInternal(url) {
                webView.load(action.request)
            } else {
                Links.openExternally(url)
            }
        }
        return nil
    }

    /// Attaching photos and files to a message.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        NSApp.activate()
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

/// Weak trampoline so the user content controller doesn't retain the view controller.
final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewController?
    init(owner: WebViewController) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.handleScriptMessage(body) }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let web = WebViewController()
    private var titleObservation: NSKeyValueObservation?
    private var askedForNotifications = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        popover.contentViewController = web
        popover.contentSize = Prefs.popoverSize.size
        popover.behavior = .semitransient // stays open for in-app panels (file picker), closes when you click away
        popover.animates = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill",
                                accessibilityDescription: "Messenger")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Messenger — click to open, right-click for options"
        }

        titleObservation = web.webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.updateBadge(from: webView.title) }
        }
        web.onNotification = { [weak self] title, body, tag in
            self?.postNotification(title: title, body: body, tag: tag)
        }
        UNUserNotificationCenter.current().delegate = self

        enableLaunchAtLoginOnFirstRun()
        web.loadHome()
    }

    /// Turns on "Launch at Login" the first time the installed app runs. After that the
    /// right-click menu toggle is the source of truth, so turning it off sticks.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetUpLaunchAtLogin"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        // Don't register a throwaway copy (e.g. build/MessengerBar.app) as the login item.
        guard Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else { return }

        let service = SMAppService.mainApp
        do {
            if service.status != .enabled { try service.register() }
            defaults.set(true, forKey: key)
            NSLog("MessengerBar: launch at login status = \(service.status.rawValue)")
        } catch {
            NSLog("MessengerBar: could not enable launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showOptionsMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        web.focus()
    }

    /// Unread count from the page title, e.g. "(3) Messenger".
    private func updateBadge(from title: String?) {
        guard let button = statusItem?.button else { return }
        let count = title.flatMap { t -> String? in
            guard let match = t.firstMatch(of: /\((\d+\+?)\)/) else { return nil }
            return String(match.1)
        }
        button.title = count.map { " \($0)" } ?? ""
    }

    // MARK: Options menu (right-click)

    private func showOptionsMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(item(popover.isShown ? "Hide Messenger" : "Show Messenger", #selector(togglePopoverAction)))
        menu.addItem(item("Go to Inbox", #selector(goHome)))
        menu.addItem(item("Reload", #selector(reload)))
        menu.addItem(item("Open in Browser", #selector(openInBrowser)))
        menu.addItem(.separator())

        let sourceMenu = NSMenu()
        for source in Source.allCases {
            let mi = item(source.title, #selector(chooseSource(_:)))
            mi.representedObject = source.rawValue
            mi.state = Prefs.source == source ? .on : .off
            sourceMenu.addItem(mi)
        }
        let sourceItem = NSMenuItem(title: "Load From", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        let sizeMenu = NSMenu()
        for size in PopoverSize.allCases {
            let mi = item(size.title, #selector(chooseSize(_:)))
            mi.representedObject = size.rawValue
            mi.state = Prefs.popoverSize == size ? .on : .off
            sizeMenu.addItem(mi)
        }
        let sizeItem = NSMenuItem(title: "Window Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit MessengerBar", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil // restore left-click → popover
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = target ?? self
        return mi
    }

    @objc private func togglePopoverAction() { togglePopover() }
    @objc private func goHome() { web.loadHome(); showPopover() }
    @objc private func reload() { web.webView.reload() }
    @objc private func goBack() { web.webView.goBack() }
    @objc private func goForward() { web.webView.goForward() }
    @objc private func closePopover() { popover.performClose(nil) }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(web.webView.url ?? URL(string: Prefs.source.rawValue)!)
    }

    @objc private func chooseSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = Source(rawValue: raw) else { return }
        Prefs.source = source
        goHome()
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = PopoverSize(rawValue: raw) else { return }
        Prefs.popoverSize = size
        popover.contentSize = size.size
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Move MessengerBar.app to /Applications and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    // MARK: Main menu (invisible, but gives the web view ⌘C/⌘V/⌘Z/⌘R etc.)

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("Quit MessengerBar", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pasteMatch = NSMenuItem(title: "Paste and Match Style",
                                    action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(pasteMatch)
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(item("Reload", #selector(reload), key: "r"))
        view.addItem(item("Back", #selector(goBack), key: "["))
        view.addItem(item("Forward", #selector(goForward), key: "]"))
        view.addItem(item("Close", #selector(closePopover), key: "w"))
        viewItem.submenu = view
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    // MARK: Notifications

    private func postNotification(title: String, body: String, tag: String) {
        let send: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let id = tag.isEmpty ? UUID().uuidString : tag
            UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        let center = UNUserNotificationCenter.current()
        if askedForNotifications {
            send()
        } else {
            askedForNotifications = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { send() }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let visible = await MainActor.run { popover.isShown }
        return visible ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { showPopover() }
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
