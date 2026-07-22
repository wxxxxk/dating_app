import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../models/user_profile.dart';

/// 앱 시작 화면을 결정하는 단일 상태.
///
/// bool 두 개(`_profileChecked`/`_hasProfile`)로는 "조회 실패"를 표현할 수 없어
/// 실패가 곧 "프로필 없음"으로 접혀버렸다. 그 조합 자체를 없앤다.
enum AuthGateStatus {
  loading,
  unauthenticated,
  onboarding,
  authenticated,
  recoverableError,
}

/// 사용자에게 보여줄 수 있는 수준으로 뭉뚱그린 실패 분류.
/// raw Firebase 코드·메시지는 이 밖으로 나가지 않는다.
enum ProfileErrorCategory { network, permissionDenied, unavailable, unknown }

/// 컨트롤러가 필요로 하는 인증 상태의 최소 계약.
///
/// `AuthState`가 이걸 구현한다. 테스트는 FirebaseAuth 없이 가짜를 넣는다.
abstract class AuthGateAuth implements Listenable {
  bool get initializing;
  String? get currentUid;
}

typedef ProfileLoader = Future<UserProfile?> Function(String uid);

/// 라우팅에 영향을 주면 안 되는 부가 작업(reloadUser·배지 동기화·알림 등록).
typedef ProfileSideEffects =
    Future<void> Function(String uid, UserProfile profile);

/// 로그인 상태 + 프로필 존재 여부로 초기 화면을 정하는 상태 머신.
///
/// 핵심 규칙 세 가지:
/// - 프로필 **조회 실패**는 `recoverableError`다. 절대 `onboarding`이 아니다.
/// - 부가 작업 실패는 라우팅에 영향을 주지 않는다.
/// - 늦게 도착한 이전 요청은 현재 상태를 덮어쓰지 못한다.
class AuthGateController extends ChangeNotifier {
  AuthGateController({
    required AuthGateAuth auth,
    required ProfileLoader loadProfile,
    required ProfileSideEffects runSideEffects,
  }) : _auth = auth,
       _loadProfile = loadProfile,
       _runSideEffects = runSideEffects;

  // ignore_for_file: prefer_initializing_formals
  // private 필드마다 역할을 문서 주석으로 남기려고 초기화 목록을 쓴다.

  final AuthGateAuth _auth;

  /// `users/{uid}` 조회. 이 호출의 성공·실패만이 라우팅을 결정한다.
  final ProfileLoader _loadProfile;

  /// 라우팅 확정 뒤 실행되는 부가 작업.
  final ProfileSideEffects _runSideEffects;

  AuthGateStatus _status = AuthGateStatus.loading;
  ProfileErrorCategory? _errorCategory;

  /// 요청 세대. 늦게 끝난 이전 요청을 버리는 기준이다.
  int _generation = 0;

  /// 현재 진행 중인 요청이 대상으로 삼은 uid. 계정 전환 감지에 쓴다.
  String? _inFlightUid;

  bool _disposed = false;
  bool _started = false;

  AuthGateStatus get status => _status;
  ProfileErrorCategory? get errorCategory => _errorCategory;

  /// 테스트·진단용. 진행 중인 조회가 있는지.
  bool get isFetching => _inFlightUid != null;

  void start() {
    if (_started) return;
    _started = true;
    _auth.addListener(_onAuthChanged);
    _evaluate();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() => _evaluate();

  void _evaluate() {
    if (_disposed) return;

    if (_auth.initializing) {
      _setStatus(AuthGateStatus.loading);
      return;
    }

    final uid = _auth.currentUid;
    if (uid == null) {
      // 로그아웃·계정 소멸: 진행 중이던 요청을 무효화하고 상태를 비운다.
      _generation += 1;
      _inFlightUid = null;
      _errorCategory = null;
      _setStatus(AuthGateStatus.unauthenticated);
      return;
    }

    // 이미 이 uid로 조회 중이면 중복 실행하지 않는다.
    if (_inFlightUid == uid) return;

    // 이미 이 uid로 확정된 상태라면 다시 조회하지 않는다.
    if (_resolvedUid == uid &&
        (_status == AuthGateStatus.authenticated ||
            _status == AuthGateStatus.onboarding)) {
      return;
    }

    unawaited(_fetchProfile(uid));
  }

  /// 마지막으로 확정(authenticated/onboarding)된 uid.
  String? _resolvedUid;

  /// 온보딩이 방금 프로필을 만들었을 때. 재조회 없이 authenticated로 올린다.
  void markProfileCreated(String uid) {
    if (_disposed) return;
    if (_auth.currentUid != uid) return;
    _generation += 1; // 진행 중이던 조회가 이 결과를 덮어쓰지 못하게 한다.
    _inFlightUid = null;
    _errorCategory = null;
    _resolvedUid = uid;
    _setStatus(AuthGateStatus.authenticated);
  }

  /// 사용자가 오류 화면에서 "다시 시도"를 눌렀을 때.
  Future<void> retry() async {
    if (_disposed) return;
    final uid = _auth.currentUid;
    if (uid == null) {
      _evaluate();
      return;
    }
    if (_inFlightUid == uid) return; // 중복 요청 금지
    await _fetchProfile(uid);
  }

  Future<void> _fetchProfile(String uid) async {
    final requestId = ++_generation;
    _inFlightUid = uid;
    _errorCategory = null;
    _setStatus(AuthGateStatus.loading);
    _log('profile_fetch_started auth_present=true');

    UserProfile? profile;
    try {
      profile = await _loadProfile(uid);
    } catch (error) {
      if (!_isCurrent(requestId, uid)) {
        _log('stale_request_ignored');
        return;
      }
      _inFlightUid = null;
      final category = categorizeProfileError(error);
      _errorCategory = category;
      _log('profile_fetch_failed error_category=${category.name} retryable=true');
      _setStatus(AuthGateStatus.recoverableError);
      return;
    }

    if (!_isCurrent(requestId, uid)) {
      // 로그아웃했거나 계정이 바뀐 뒤 도착한 응답. 버린다.
      _log('stale_request_ignored');
      return;
    }

    _inFlightUid = null;
    _resolvedUid = uid;
    final found = profile != null;
    _log('profile_fetch_succeeded profile_found=$found');

    if (!found) {
      _setStatus(AuthGateStatus.onboarding);
      return;
    }

    // 라우팅은 여기서 확정된다. 아래 부가 작업 결과는 이 판정을 바꾸지 못한다.
    _setStatus(AuthGateStatus.authenticated);
    unawaited(_runSideEffectsSafely(uid, profile));
  }

  /// reloadUser·배지 동기화·알림 등록. 실패해도 라우팅을 건드리지 않는다.
  Future<void> _runSideEffectsSafely(String uid, UserProfile profile) async {
    try {
      await _runSideEffects(uid, profile);
    } catch (_) {
      // 의도적으로 삼킨다. 이 실패는 화면 전환 사유가 아니다.
      _log('profile_side_effects_failed');
    }
  }

  /// 이 요청이 아직 유효한지: 최신 세대 + 같은 uid + 여전히 로그인 상태.
  bool _isCurrent(int requestId, String uid) {
    if (_disposed) return false;
    if (requestId != _generation) return false;
    if (_auth.currentUid != uid) return false;
    return true;
  }

  void _setStatus(AuthGateStatus next) {
    if (_status == next && next != AuthGateStatus.loading) {
      notifyListeners();
      return;
    }
    _status = next;
    notifyListeners();
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[AuthGate] $message');
  }
}

/// 실패 원인을 사용자에게 보여줄 수 있는 분류로 축약한다.
/// 여기서 raw 메시지를 밖으로 내보내지 않는다.
ProfileErrorCategory categorizeProfileError(Object error) {
  if (error is SocketException || error is TimeoutException) {
    return ProfileErrorCategory.network;
  }
  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return ProfileErrorCategory.permissionDenied;
      case 'unavailable':
        return ProfileErrorCategory.unavailable;
      case 'network-request-failed':
      case 'deadline-exceeded':
        return ProfileErrorCategory.network;
      default:
        return ProfileErrorCategory.unknown;
    }
  }
  return ProfileErrorCategory.unknown;
}
