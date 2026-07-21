package com.cvrlab.dating_app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 화면 캡처 보호 (Phase 3-5).
 *
 * Android에서는 감지가 아니라 **차단**이 기본 정책이다. FLAG_SECURE를 켜면
 * 스크린샷, 화면 녹화 결과, 비보안 외부 디스플레이 출력, 최근 앱 미리보기에서
 * 앱 내용이 가려진다.
 *
 * 스크린샷 감지 권한(DETECT_SCREEN_CAPTURE)이나 미디어 저장소 감시 같은
 * 추가 권한은 사용하지 않는다.
 */
class MainActivity : FlutterActivity() {

    /**
     * 앱 시작 시 fail-closed. 로그인 상태가 확정되기 전에 첫 프레임이
     * 캡처되지 않도록 보호를 켠 상태로 시작하고, 로그아웃 시 Flutter가 끈다.
     */
    private var protectionEnabled = true

    private var methodChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyScreenProtection()
    }

    override fun onResume() {
        super.onResume()
        // Activity가 복원된 뒤에도 현재 정책이 유지되도록 다시 적용한다.
        applyScreenProtection()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_PROTECTION_CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                METHOD_SET_ENABLED -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled == null) {
                        result.error(
                            "invalid_argument",
                            "enabled must be a boolean",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    protectionEnabled = enabled
                    // 윈도우 플래그는 UI 스레드에서만 변경한다.
                    runOnUiThread {
                        applyScreenProtection()
                        result.success(mapOf("enabled" to protectionEnabled))
                    }
                }

                METHOD_GET_CAPTURE_STATE -> {
                    // Android는 FLAG_SECURE로 캡처 자체를 막으므로 별도 녹화
                    // 감지 기능을 두지 않는다. 여기서의 false는 "녹화 중이
                    // 아니다"가 아니라 "감지 기능 미제공"이라는 뜻이며,
                    // 차단 계약과 혼동하지 않도록 iOS 전용 경로로만 쓴다.
                    result.success(false)
                }

                else -> result.notImplemented()
            }
        }
        methodChannel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun applyScreenProtection() {
        if (protectionEnabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    companion object {
        private const val SCREEN_PROTECTION_CHANNEL =
            "com.cvrlab.dating_app/screen_protection"
        private const val METHOD_SET_ENABLED = "setEnabled"
        private const val METHOD_GET_CAPTURE_STATE = "getCaptureState"
    }
}
