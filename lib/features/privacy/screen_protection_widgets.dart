import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/privacy/screen_protection_service.dart';

/// 로그인 상태에 맞춰 화면 캡처 보호를 켜고 끄는 coordinator(Phase 3-5).
///
/// route마다 켜고 끄지 않고 로그인 여부 한 곳에서만 관리한다. 네이티브 호출
/// 실패는 삼켜서 화면 표시(AuthGate)를 절대 막지 않는다.
///
/// iOS 스크린샷 감지 이벤트는 **로그인 상태에서만** 안내 SnackBar로 보여준다.
class ScreenProtectionCoordinator extends StatefulWidget {
  final ScreenProtectionService service;

  /// 현재 로그인 여부. 이 값이 바뀔 때만 네이티브를 호출한다.
  final bool loggedIn;

  final Widget child;

  const ScreenProtectionCoordinator({
    super.key,
    required this.service,
    required this.loggedIn,
    required this.child,
  });

  @override
  State<ScreenProtectionCoordinator> createState() =>
      _ScreenProtectionCoordinatorState();
}

class _ScreenProtectionCoordinatorState
    extends State<ScreenProtectionCoordinator> {
  /// 짧은 시간에 연속으로 오는 스크린샷 이벤트의 중복 안내를 막는다.
  static const Duration screenshotNoticeCooldown = Duration(seconds: 2);

  static const String screenshotNotice =
      '스크린샷이 감지됐어요. 상대방의 개인정보를 공유하지 말아주세요.';

  StreamSubscription<ScreenProtectionEvent>? _eventSub;
  DateTime? _lastScreenshotNoticeAt;

  /// 보조 상태. 화면을 다시 그리거나 서버에 쓰지 않는다(최종 방어는 네이티브).
  bool _captureActive = false;

  /// 녹화/미러링 진행 여부. 화면 로직에는 쓰지 않고 테스트 확인용으로만 연다.
  @visibleForTesting
  bool get captureActive => _captureActive;

  @override
  void initState() {
    super.initState();
    _eventSub = widget.service.events.listen(
      _onEvent,
      onError: (Object e) {
        if (kDebugMode) {
          debugPrint('[ScreenProtection] 이벤트 구독 실패 code=${e.runtimeType}');
        }
      },
    );
    _applyProtection();
  }

  @override
  void didUpdateWidget(ScreenProtectionCoordinator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 같은 로그인 상태가 반복 전달되면 네이티브를 다시 호출하지 않는다
    // (서비스 쪽에도 동일 값 중복 호출 가드가 있다).
    if (oldWidget.loggedIn != widget.loggedIn) _applyProtection();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  void _applyProtection() {
    // 실패해도 화면 표시를 막지 않도록 await하지 않고 오류를 삼킨다.
    unawaited(
      widget.service.setEnabled(widget.loggedIn).catchError((Object e) {
        if (kDebugMode) {
          debugPrint('[ScreenProtection] 보호 설정 실패 code=${e.runtimeType}');
        }
      }),
    );
  }

  void _onEvent(ScreenProtectionEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case ScreenProtectionEventType.captureStarted:
        _captureActive = true;
      case ScreenProtectionEventType.captureStopped:
        _captureActive = false;
      case ScreenProtectionEventType.screenshotTaken:
        _showScreenshotNotice();
    }
  }

  void _showScreenshotNotice() {
    // 로그인 화면에서는 안내하지 않는다.
    if (!widget.loggedIn) return;
    final now = DateTime.now();
    final last = _lastScreenshotNoticeAt;
    if (last != null && now.difference(last) < screenshotNoticeCooldown) {
      return;
    }
    _lastScreenshotNoticeAt = now;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(screenshotNotice)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 홈 개인정보 영역의 "화면 캡처 보호" 안내 행. 토글은 제공하지 않는다
/// (로그인 사용자에게 기본 적용).
class ScreenProtectionInfoRow extends StatelessWidget {
  final VoidCallback onTap;

  const ScreenProtectionInfoRow({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('screen-protection-info-row'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.button),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.screenshot_monitor_rounded,
              size: 18,
              color: AppColors.mintDeep,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '화면 캡처 보호',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.mintSoft,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: const Text(
                          '사용 중',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.mintDeep,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    '민감한 프로필과 대화 화면을 보호해요',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 플랫폼별 보호 범위 상세 안내 시트.
///
/// iOS에서 단일 스크린샷을 "완전히 막는다"고 표현하지 않는다.
Future<void> showScreenProtectionInfoSheet(
  BuildContext context, {
  TargetPlatform? platformOverride,
}) {
  final platform = platformOverride ?? defaultTargetPlatform;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => _ScreenProtectionInfoSheet(platform: platform),
  );
}

class _ScreenProtectionInfoSheet extends StatelessWidget {
  final TargetPlatform platform;

  const _ScreenProtectionInfoSheet({required this.platform});

  static const String androidBody =
      'Android에서는 로그인 후 스크린샷과 화면 녹화를 차단해요.\n'
      '기기나 운영체제 환경에 따라 보호 방식이 다를 수 있어요.';

  static const String iosBody =
      'iPhone에서는 화면 녹화·미러링 중 앱 내용을 가리고, 스크린샷이 감지되면 개인정보 보호 안내를 표시해요.\n\n'
      'iOS에서는 단일 스크린샷 촬영 자체를 완전히 막을 수 없어요.';

  static const String otherBody = '현재 기기에서는 운영체제가 지원하는 범위 안에서 화면을 보호해요.';

  String get _platformBody {
    if (kIsWeb) return otherBody;
    switch (platform) {
      case TargetPlatform.android:
        return androidBody;
      case TargetPlatform.iOS:
        return iosBody;
      default:
        return otherBody;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
          child: Column(
            key: const ValueKey('screen-protection-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Icon(
                    Icons.screenshot_monitor_rounded,
                    size: 20,
                    color: AppColors.mintDeep,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '화면 캡처 보호',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '프로필 사진과 대화 내용에는 다른 사람의 개인정보가 포함될 수 있어요.\n앱 밖으로 저장하거나 공유하지 말아주세요.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  _platformBody,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('screen-protection-info-confirm'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인했어요'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
