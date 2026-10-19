import UIKit
import Display
import SwiftSignalKit
import SSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AnimationCache
import MultiAnimationRenderer
import LottieSettings
import LegacyComponents

/// The AccountContext that Telegram's components take. tau has no Telegram account: this one carries the presentation
/// data and app bindings the copied components (attachment menu, media picker) read, and nothing account-bound.
final class TauSharedAccountContext: SharedAccountContext {
    let currentPresentationData: Atomic<PresentationData>
    private let presentationDataPromise: Promise<PresentationData>
    let energyUsageSettings = EnergyUsageSettings.default
    weak var mainWindow: Window1?
    let applicationBindings = TelegramApplicationBindings(openSettings: {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    })

    init(presentationData: PresentationData) {
        self.currentPresentationData = Atomic(value: presentationData)
        self.presentationDataPromise = Promise(presentationData)
    }

    var presentationData: Signal<PresentationData, NoError> {
        return self.presentationDataPromise.get()
    }

    func update(presentationData: PresentationData) {
        let _ = self.currentPresentationData.swap(presentationData)
        self.presentationDataPromise.set(.single(presentationData))
    }
}

private final class NoAnimationCache: AnimationCache {
}

private final class NoAnimationRenderer: MultiAnimationRenderer {
}

final class TauAccountContext: AccountContext {
    let sharedContext: SharedAccountContext
    let account = Account()
    let currentLimitsConfiguration = Atomic(value: LimitsConfiguration.defaultValue)
    let currentAppConfiguration = Atomic(value: AppConfiguration.defaultValue)
    let animationCache: AnimationCache = NoAnimationCache()
    let animationRenderer: MultiAnimationRenderer = NoAnimationRenderer()
    let lottieRenderingSettings = LottieRenderingSettings.noAccountFallback

    init(shared: TauSharedAccountContext) {
        self.sharedContext = shared
    }
}

// MARK: - LegacyComponents

/// As Telegram's LegacyUI/Sources/TelegramInitializeLegacyComponents.swift: what LegacyComponents (the camera tile,
/// asset selection and editing contexts) asks the app for, with the account-bound parts (audio sessions, document
/// stores) left out.
private var legacyLocalization = TGLocalization(version: 0, code: "en", dict: [:], isActive: true)
private weak var legacyContext: TauAccountContext?

func initializeLegacyComponents(context: TauAccountContext, strings: PresentationStrings) {
    legacyContext = context
    legacyLocalization = TGLocalization(version: 0, code: strings.primaryComponent.languageCode, dict: strings.primaryComponent.dict, isActive: true)
    freedomInit()
    LegacyComponentsGlobals.setProvider(LegacyComponentsGlobalsProviderImpl())
}

private final class LegacyComponentsAccessCheckerImpl: NSObject, LegacyComponentsAccessChecker {
    func checkPhotoAuthorizationStatus(for intent: TGPhotoAccessIntent, alertDismissCompletion: (() -> Void)!) -> Bool {
        return true
    }

    func checkMicrophoneAuthorizationStatus(for intent: TGMicrophoneAccessIntent, alertDismissCompletion: (() -> Void)!) -> Bool {
        return true
    }

    func checkCameraAuthorizationStatus(for intent: TGCameraAccessIntent, completion: ((Bool) -> Void)!, alertDismissCompletion: (() -> Void)!) -> Bool {
        completion?(true)
        return true
    }
}

private final class LegacyComponentsGlobalsProviderImpl: NSObject, LegacyComponentsGlobalsProvider {
    private var theme: PresentationTheme {
        return legacyContext?.sharedContext.currentPresentationData.with { $0 }.theme ?? defaultPresentationTheme
    }

    private var windows: [UIWindow] {
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    func log(_ string: String!) {
    }

    func effectiveLocalization() -> TGLocalization! {
        return legacyLocalization
    }

    func applicationWindows() -> [UIWindow]! {
        return self.windows
    }

    func applicationStatusBarWindow() -> UIWindow! {
        return nil
    }

    func applicationKeyboardWindow() -> UIWindow! {
        return self.windows.first { window in
            let name = NSStringFromClass(type(of: window))
            return name.hasPrefix("UI") && name.hasSuffix("RemoteKeyboardWindow")
        }
    }

    func applicationInstance() -> UIApplication! {
        return UIApplication.shared
    }

    func applicationStatusBarOrientation() -> UIInterfaceOrientation {
        return self.windows.first?.windowScene?.interfaceOrientation ?? .portrait
    }

    func statusBarFrame() -> CGRect {
        return self.windows.first?.windowScene?.statusBarManager?.statusBarFrame ?? CGRect(x: 0.0, y: 0.0, width: 320.0, height: 20.0)
    }

    func isStatusBarHidden() -> Bool {
        return false
    }

    func setStatusBarHidden(_ hidden: Bool, with animation: UIStatusBarAnimation) {
    }

    func statusBarStyle() -> UIStatusBarStyle {
        return .default
    }

    func setStatusBarStyle(_ statusBarStyle: UIStatusBarStyle, animated: Bool) {
    }

    func forceStatusBarAppearanceUpdate() {
    }

    func canOpen(_ url: URL!) -> Bool {
        return UIApplication.shared.canOpenURL(url)
    }

    func open(_ url: URL!) {
        UIApplication.shared.open(url)
    }

    func openURLNative(_ url: URL!) {
        UIApplication.shared.open(url)
    }

    func makeViewDisableInteractiveKeyboardGestureRecognizer(_ view: UIView!) {
        view.disablesInteractiveKeyboardGestureRecognizer = true
    }

    func disableUserInteraction(for timeInterval: TimeInterval) {
    }

    func setIdleTimerDisabled(_ value: Bool) {
        UIApplication.shared.isIdleTimerDisabled = value
    }

    func pauseMusicPlayback() {
    }

    func dataStoragePath() -> String! {
        return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }

    func dataCachePath() -> String! {
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    }

    func accessChecker() -> LegacyComponentsAccessChecker! {
        return LegacyComponentsAccessCheckerImpl()
    }

    func request(_ type: TGAudioSessionType, activated: (() -> Void)!, interrupted: (() -> Void)!) -> SDisposable! {
        activated?()
        return SBlockDisposable(block: {})
    }

    func sharedMediaImageProcessingThreadPool() -> SThreadPool! {
        return nil
    }

    func sharedMediaMemoryImageCache() -> TGMemoryImageCache! {
        return nil
    }

    func squarePhotoThumbnail(_ imageAttachment: TGImageMediaAttachment!, of size: CGSize, threadPool: SThreadPool!, memoryCache: TGMemoryImageCache!, pixelProcessingBlock: ((UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Void)!, downloadLargeImage: Bool, placeholder: SSignal!) -> SSignal! {
        return SSignal.never()
    }

    func localDocumentDirectory(forLocalDocumentId localDocumentId: Int64, version: Int32) -> String! {
        return ""
    }

    func localDocumentDirectory(forDocumentId documentId: Int64, version: Int32) -> String! {
        return ""
    }

    func pausePictureInPicturePlayback() {
    }

    func resumePictureInPicturePlayback() {
    }

    func maybeReleaseVolumeOverlay() {
    }

    func navigationBarPallete() -> TGNavigationBarPallete! {
        let bar = self.theme.rootController.navigationBar
        return TGNavigationBarPallete(backgroundColor: bar.opaqueBackgroundColor, separatorColor: bar.separatorColor, titleColor: bar.primaryTextColor, tintColor: bar.accentTextColor)
    }

    func menuSheetPallete() -> TGMenuSheetPallete! {
        let theme = self.theme
        let sheet = theme.actionSheet
        return TGMenuSheetPallete(dark: theme.overallDarkAppearance, backgroundColor: sheet.opaqueItemBackgroundColor, selectionColor: sheet.opaqueItemHighlightedBackgroundColor, separatorColor: sheet.opaqueItemSeparatorColor, accentColor: sheet.controlAccentColor, destructiveColor: sheet.destructiveActionTextColor, textColor: sheet.primaryTextColor, secondaryTextColor: sheet.secondaryTextColor, spinnerColor: sheet.secondaryTextColor, badgeTextColor: sheet.controlAccentColor, badgeImage: nil, cornersImage: generateStretchableFilledCircleImage(diameter: 11.0, color: nil, strokeColor: nil, strokeWidth: nil, backgroundColor: sheet.opaqueItemBackgroundColor))
    }

    func darkMenuSheetPallete() -> TGMenuSheetPallete! {
        return self.menuSheetPallete()
    }

    func mediaAssetsPallete() -> TGMediaAssetsPallete! {
        let presentationTheme = self.theme
        let list = presentationTheme.list
        let bar = presentationTheme.rootController.navigationBar
        let tabBar = presentationTheme.rootController.tabBar
        return TGMediaAssetsPallete(dark: presentationTheme.overallDarkAppearance, backgroundColor: list.plainBackgroundColor, selectionColor: list.itemHighlightedBackgroundColor, separatorColor: list.itemPlainSeparatorColor, textColor: list.itemPrimaryTextColor, secondaryTextColor: list.controlSecondaryColor, accentColor: list.itemAccentColor, destructiveColor: list.itemDestructiveColor, barBackgroundColor: bar.opaqueBackgroundColor, barSeparatorColor: tabBar.separatorColor, navigationTitleColor: bar.primaryTextColor, badge: generateStretchableFilledCircleImage(diameter: 22.0, color: bar.accentTextColor), badgeTextColor: bar.opaqueBackgroundColor, sendIconImage: PresentationResourcesChat.chatInputPanelSendButtonImage(presentationTheme), doneIconImage: PresentationResourcesChat.chatInputPanelApplyButtonImage(presentationTheme), scheduleIconImage: PresentationResourcesChat.chatInputPanelScheduleButtonImage(presentationTheme), maybeAccentColor: bar.accentTextColor)
    }

    func checkButtonPallete() -> TGCheckButtonPallete! {
        let colors = self.theme.chat.message.selectionControlColors
        return TGCheckButtonPallete(defaultBackgroundColor: colors.fillColor, accentBackgroundColor: colors.fillColor, defaultBorderColor: colors.strokeColor, mediaBorderColor: colors.strokeColor, chatBorderColor: colors.strokeColor, check: colors.foregroundColor, blueColor: colors.fillColor, barBackgroundColor: colors.fillColor)
    }
}
