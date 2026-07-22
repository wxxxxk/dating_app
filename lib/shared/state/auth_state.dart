import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../features/auth/auth_gate_controller.dart';
import '../../services/auth/auth_service.dart';

/// 앱 전역의 "로그인 상태"를 들고 있는 ChangeNotifier.
///
/// 왜 ChangeNotifier인가:
/// - 이 프로젝트는 외부 상태관리 패키지 없이 Flutter 기본 도구만 쓴다.
/// - ChangeNotifier는 "값이 바뀌면 notifyListeners()로 알림" 하는 가장 단순한 도구.
/// - app.dart의 AnimatedBuilder/ListenableBuilder가 이걸 구독해
///   로그인/로그아웃에 따라 화면을 자동으로 바꾼다.
///
/// 흐름:
///   AuthService.authStateChanges() 스트림을 구독
///     → User 객체가 들어오면 보관하고 notifyListeners()
///     → 화면이 다시 그려지며 로그인/비로그인 화면이 전환됨
class AuthState extends ChangeNotifier implements AuthGateAuth {
  AuthState(this._authService) {
    // 생성과 동시에 인증 상태 스트림을 구독한다.
    _subscription = _authService.authStateChanges().listen(_onAuthChanged);
  }

  final AuthService _authService;
  StreamSubscription<User?>? _subscription;

  User? _user;

  /// 스트림에서 첫 값이 오기 전(앱 시작 직후)인지 여부.
  /// true인 동안에는 스플래시/로딩을 보여주면 깜빡임을 막을 수 있다.
  bool _initializing = true;
  @override
  bool get initializing => _initializing;

  /// 현재 로그인된 사용자(없으면 null).
  User? get currentUser => _user;

  /// 현재 로그인된 사용자의 uid(없으면 null).
  /// AuthGate는 User 객체 전체가 아니라 이 값만 본다.
  @override
  String? get currentUid => _user?.uid;

  /// 로그인 여부.
  bool get isLoggedIn => _user != null;

  /// 인증 스트림 콜백.
  void _onAuthChanged(User? user) {
    _user = user;
    _initializing = false;
    // 상태가 바뀌었으니 구독 중인 위젯들에게 다시 그리라고 알린다.
    notifyListeners();
  }

  @override
  void dispose() {
    // 메모리 누수 방지를 위해 구독 해제.
    _subscription?.cancel();
    super.dispose();
  }
}
