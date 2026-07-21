import Flutter
import UIKit

/// 화면 캡처 보호 (Phase 3-5).
///
/// iOS는 단일 스크린샷 촬영 자체를 공개 API로 막을 수 없다. 따라서:
/// - 화면 녹화·미러링(`UIScreen.main.isCaptured`) 중에는 privacy overlay로 가린다.
/// - 앱 전환(App Switcher) 화면에도 overlay를 덮는다.
/// - 스크린샷은 **촬영된 뒤** 알림을 받아 Flutter에 안내만 전달한다.
///
/// 비공개 API나 secure text field 이식 같은 우회 기법은 쓰지 않는다.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private static let screenProtectionChannel = "com.cvrlab.dating_app/screen_protection"
  private static let methodSetEnabled = "setEnabled"
  private static let methodGetCaptureState = "getCaptureState"
  private static let callbackScreenshotTaken = "onScreenshotTaken"
  private static let callbackCaptureChanged = "onCaptureChanged"

  /// 앱 시작 시 fail-closed. 로그인 상태가 확정되면 Flutter가 조정한다.
  private var screenProtectionEnabled = true
  private var privacyOverlay: UIView?
  private var methodChannel: FlutterMethodChannel?
  private var observersRegistered = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    registerScreenProtectionObservers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 앱 수준 binary messenger는 applicationRegistrar를 통해 얻는다.
    setUpScreenProtectionChannel(with: engineBridge.applicationRegistrar.messenger())
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - MethodChannel

  private func setUpScreenProtectionChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: AppDelegate.screenProtectionChannel,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: nil, details: nil))
        return
      }
      switch call.method {
      case AppDelegate.methodSetEnabled:
        guard
          let args = call.arguments as? [String: Any],
          let enabled = args["enabled"] as? Bool
        else {
          result(
            FlutterError(
              code: "invalid_argument",
              message: "enabled must be a boolean",
              details: nil
            )
          )
          return
        }
        // UI 변경은 반드시 메인 스레드에서 수행한다.
        DispatchQueue.main.async {
          self.screenProtectionEnabled = enabled
          if enabled {
            // 이미 녹화/미러링 중이면 즉시 가린다.
            if UIScreen.main.isCaptured { self.showPrivacyOverlay() }
          } else {
            self.hidePrivacyOverlay()
          }
          result(["enabled": enabled])
        }

      case AppDelegate.methodGetCaptureState:
        result(UIScreen.main.isCaptured)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    methodChannel = channel
  }

  // MARK: - Observers

  private func registerScreenProtectionObservers() {
    // 엔진 재생성 등으로 중복 등록되지 않게 한 번만 붙인다.
    guard !observersRegistered else { return }
    observersRegistered = true

    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(handleCapturedDidChange),
      name: UIScreen.capturedDidChangeNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleScreenshotTaken),
      name: UIApplication.userDidTakeScreenshotNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func handleCapturedDidChange() {
    let captured = UIScreen.main.isCaptured
    if captured {
      if screenProtectionEnabled { showPrivacyOverlay() }
    } else if UIApplication.shared.applicationState == .active {
      hidePrivacyOverlay()
    }
    methodChannel?.invokeMethod(AppDelegate.callbackCaptureChanged, arguments: captured)
  }

  /// 스크린샷은 촬영이 끝난 뒤 통지된다. 차단이 아니라 사후 안내 용도다.
  /// 이미지·화면·route를 저장하거나 전송하지 않는다.
  @objc private func handleScreenshotTaken() {
    guard screenProtectionEnabled else { return }
    methodChannel?.invokeMethod(AppDelegate.callbackScreenshotTaken, arguments: nil)
  }

  /// 앱 전환 화면(App Switcher) 스냅샷에 내용이 남지 않도록 미리 가린다.
  @objc private func handleWillResignActive() {
    guard screenProtectionEnabled else { return }
    showPrivacyOverlay()
  }

  /// 포그라운드 복귀. 카메라·갤러리·권한 dialog에서 돌아온 경우에도
  /// 녹화 중이 아니라면 overlay를 반드시 제거한다.
  @objc private func handleDidBecomeActive() {
    if screenProtectionEnabled && UIScreen.main.isCaptured {
      showPrivacyOverlay()
      return
    }
    hidePrivacyOverlay()
  }

  // MARK: - Privacy overlay

  /// Flutter view를 제거하거나 재생성하지 않고 window 위에 덮기만 한다.
  private func showPrivacyOverlay() {
    guard privacyOverlay == nil, let window = window else { return }

    let overlay = UIView(frame: window.bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // 검정 단색 대신 앱 배경과 가까운 중립 색을 쓴다.
    overlay.backgroundColor = UIColor(
      red: 0.980, green: 0.969, blue: 0.949, alpha: 1.0
    )
    // 녹화·미러링 중 터치가 앱으로 전달되지 않게 한다.
    overlay.isUserInteractionEnabled = true
    overlay.isAccessibilityElement = true
    overlay.accessibilityLabel = "개인정보 보호를 위해 화면을 가렸어요"

    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let icon = UIImageView(image: UIImage(systemName: "lock.shield"))
    icon.tintColor = UIColor(red: 0.055, green: 0.624, blue: 0.420, alpha: 1.0)
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

    let label = UILabel()
    label.text = "개인정보 보호를 위해 화면을 가렸어요"
    label.textColor = UIColor(red: 0.110, green: 0.106, blue: 0.098, alpha: 1.0)
    label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    label.numberOfLines = 0
    label.textAlignment = .center

    stack.addArrangedSubview(icon)
    stack.addArrangedSubview(label)
    overlay.addSubview(stack)

    // safe area 기준으로 배치해 회전·노치에서도 잘리지 않게 한다.
    let guide = overlay.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),
    ])

    window.addSubview(overlay)
    privacyOverlay = overlay
  }

  private func hidePrivacyOverlay() {
    privacyOverlay?.removeFromSuperview()
    privacyOverlay = nil
  }
}
