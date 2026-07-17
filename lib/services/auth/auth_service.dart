import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/constants/app_constants.dart';
import '../../models/user_profile.dart';

typedef AuthBadgeSyncCaller = Future<dynamic> Function();

/// 인증 관련 결과를 화면에 전달하기 위한 의미 있는 예외.
///
/// 왜 만드나:
/// - FirebaseAuthException의 코드("user-disabled" 등)는 사용자에게 그대로 보여줄 수 없다.
/// - 서비스 계층에서 한국어 메시지로 변환해 던지면, 화면은 message만 보여주면 된다.
class AuthFailure implements Exception {
  final String message;
  const AuthFailure(this.message);

  @override
  String toString() => message;
}

/// FirebaseAuth를 감싸는 추상화 레이어.
///
/// 왜 직접 FirebaseAuth.instance를 화면에서 쓰지 않고 감싸나:
/// - 화면(UI)이 Firebase에 직접 의존하면, 나중에 인증 백엔드를 바꾸거나
///   테스트용 가짜(Mock)로 교체하기가 어렵다.
/// - 모든 인증 로직을 이 클래스 한 곳에 모아두면 교체/테스트/에러처리가 쉬워진다.
class AuthService {
  AuthService({
    FirebaseAuth? firebaseAuth,
    FirebaseFunctions? functions,
    AuthBadgeSyncCaller? authBadgeSyncCaller,
  }) : _auth =
           firebaseAuth ??
           (authBadgeSyncCaller == null ? FirebaseAuth.instance : null),
       _functions =
           functions ??
           (authBadgeSyncCaller == null
               ? FirebaseFunctions.instanceFor(
                   region: AppConstants.functionsRegion,
                 )
               : null),
       _authBadgeSyncCaller = authBadgeSyncCaller;

  final FirebaseAuth? _auth;
  final FirebaseFunctions? _functions;
  final AuthBadgeSyncCaller? _authBadgeSyncCaller;

  FirebaseAuth get _firebaseAuth {
    final auth = _auth;
    if (auth == null) {
      throw StateError('FirebaseAuth is not configured.');
    }
    return auth;
  }

  /// google_sign_in 7.x 부터는 인스턴스를 직접 생성하지 않고
  /// 싱글턴 [GoogleSignIn.instance] 를 사용하고, 쓰기 전에 initialize() 해야 한다.
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  /// initialize()를 중복 호출하지 않도록 한 번만 수행하기 위한 플래그.
  bool _googleInitialized = false;

  /// 현재 로그인된 사용자(없으면 null). 동기적으로 즉시 확인할 때 사용.
  User? get currentUser => _auth?.currentUser;

  /// 로그인 상태 변화 스트림.
  ///
  /// 로그인/로그아웃이 일어날 때마다 새 값을 흘려보낸다.
  /// AuthState(ChangeNotifier)가 이 스트림을 구독해 앱 전체 화면 전환을 처리한다.
  Stream<User?> authStateChanges() => _firebaseAuth.authStateChanges();

  // ===========================================================================
  // 구글 로그인
  // ===========================================================================

  /// 구글 계정으로 로그인한다.
  ///
  /// 흐름:
  /// 1) GoogleSignIn 초기화(최초 1회)
  /// 2) authenticate()로 구글 계정 선택 → idToken 획득
  /// 3) idToken으로 Firebase 자격증명(credential) 생성
  /// 4) Firebase에 로그인 → UserCredential 반환
  ///
  /// 반환값이 null이면 "사용자가 중간에 취소"한 경우다(에러가 아님).
  Future<UserCredential?> signInWithGoogle() async {
    try {
      await _ensureGoogleInitialized();

      // 웹은 authenticate() 대신 별도 버튼 위젯을 써야 하므로, 지원 여부를 먼저 확인.
      // (이번 마일스톤은 모바일 기준이지만 안전장치로 남겨둔다.)
      if (!_googleSignIn.supportsAuthenticate()) {
        throw const AuthFailure('이 플랫폼에서는 구글 로그인을 지원하지 않습니다.');
      }

      // 구글 계정 선택 UI 표시 → 선택된 계정 반환.
      final GoogleSignInAccount account = await _googleSignIn.authenticate();

      // 7.x에서 authentication은 idToken만 제공한다.
      // Firebase 로그인에는 idToken만 있으면 충분하다.
      final GoogleSignInAuthentication googleAuth = account.authentication;
      final String? idToken = googleAuth.idToken;

      if (idToken == null) {
        throw const AuthFailure('구글 인증 토큰을 가져오지 못했습니다.');
      }

      final credential = GoogleAuthProvider.credential(idToken: idToken);
      return await _firebaseAuth.signInWithCredential(credential);
    } on GoogleSignInException catch (e) {
      // 사용자가 로그인 창을 닫은 경우는 에러가 아니라 "취소"로 처리한다.
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      throw AuthFailure('구글 로그인에 실패했습니다. (${e.code.name})');
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_firebaseAuthMessage(e));
    } catch (_) {
      throw const AuthFailure('구글 로그인 중 알 수 없는 오류가 발생했습니다.');
    }
  }

  /// GoogleSignIn 싱글턴을 최초 1회 초기화한다.
  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;

    // TODO(연결): Android는 보통 google-services.json 만으로 동작하지만,
    //  iOS / 서버측 검증이 필요하면 serverClientId(웹 클라이언트 ID)를 넣어야 한다.
    //  flutterfire configure 이후 Firebase 콘솔에서 OAuth 클라이언트 ID를 확인해
    //  아래 serverClientId에 채워라. (절대 코드에 시크릿이 아닌 "클라이언트 ID"만)
    await _googleSignIn.initialize(
      // serverClientId: 'YOUR_WEB_CLIENT_ID.apps.googleusercontent.com',
    );
    _googleInitialized = true;
  }

  // ===========================================================================
  // 이메일/비밀번호 인증
  // ===========================================================================

  /// 이메일/비밀번호로 신규 계정을 만든다.
  ///
  /// 성공하면 Firebase에 즉시 로그인된 상태가 된다.
  /// 이메일 인증 메일은 이 메서드 직후 [sendEmailVerification]을 호출해 발송한다.
  Future<UserCredential> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      return await _firebaseAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_firebaseAuthMessage(e));
    } catch (_) {
      throw const AuthFailure('회원가입 중 알 수 없는 오류가 발생했습니다.');
    }
  }

  /// 이메일/비밀번호로 로그인한다.
  Future<UserCredential> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      return await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_firebaseAuthMessage(e));
    } catch (_) {
      throw const AuthFailure('로그인 중 알 수 없는 오류가 발생했습니다.');
    }
  }

  /// 현재 로그인된 사용자에게 이메일 인증 메일을 보낸다.
  ///
  /// 이미 인증된 계정이면 아무 일도 하지 않는다.
  /// too-many-requests 에러가 날 수 있으니 화면에서 버튼 쿨다운을 걸어야 한다.
  Future<void> sendEmailVerification() async {
    try {
      final user = _auth?.currentUser;
      if (user != null && !user.emailVerified) {
        await user.sendEmailVerification();
      }
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_firebaseAuthMessage(e));
    }
  }

  /// Firebase 서버에서 사용자 정보를 새로 불러온다.
  ///
  /// [emailVerified]는 로그인 시 캐시된 값이므로, 사용자가 인증 링크를 클릭한
  /// 뒤에도 앱은 이 메서드를 호출해야 변경을 반영할 수 있다.
  Future<void> reloadUser() async {
    await _auth?.currentUser?.reload();
  }

  /// 현재 로그인된 사용자의 이메일 인증 여부.
  ///
  /// 최신 상태를 얻으려면 [reloadUser] 후에 읽어야 한다.
  bool get isEmailVerified => _auth?.currentUser?.emailVerified ?? false;

  bool get hasPhoneNumber =>
      (_auth?.currentUser?.phoneNumber ?? '').trim().isNotEmpty;

  bool get hasAnyAuthVerificationSignal => isEmailVerified || hasPhoneNumber;

  /// 비밀번호 재설정 메일을 보낸다.
  ///
  /// Firebase는 보안상 이메일 존재 여부를 노출하지 않으므로,
  /// 가입되지 않은 주소로 보내도 에러 없이 동일한 응답이 온다.
  Future<void> sendPasswordResetEmail({required String email}) async {
    try {
      await _firebaseAuth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_firebaseAuthMessage(e));
    } catch (_) {
      throw const AuthFailure('재설정 메일 발송 중 오류가 발생했습니다.');
    }
  }

  // ===========================================================================
  // 전화번호 로그인
  // ===========================================================================

  /// 전화번호로 SMS 인증코드를 요청한다(1단계).
  ///
  /// [phoneNumber]는 반드시 E.164 형식(국가코드 포함, 예: '+821012345678')이어야
  /// 한다. 화면(PhoneLoginScreen)이 Validators.phone으로 걸러진 국내 번호를
  /// E.164로 변환해 넘긴다.
  ///
  /// 전화 인증은 2단계다:
  ///   (1) verifyPhoneNumber로 SMS 인증코드 발송 — 이 메서드
  ///   (2) 사용자가 입력한 코드로 credential을 만들어 로그인 — [confirmSmsCode]
  ///
  /// 콜백 기반인 이유: verifyPhoneNumber는 Future가 완료되는 시점과
  /// 실제 발송 성공/실패/자동인증 시점이 서로 다르다(콜백이 나중에 온다).
  /// 그래서 결과 처리는 이 메서드가 반환된 뒤가 아니라 아래 콜백 안에서 한다.
  ///
  /// [onCodeSent] : SMS 발송 성공 → verificationId를 돌려준다.
  ///   → 화면은 이 id를 보관했다가 사용자가 입력한 6자리 코드와 합쳐
  ///     [confirmSmsCode]를 호출한다.
  /// [onVerified] : (주로 안드로이드) SMS를 자동 감지해 별도 코드 입력 없이
  ///   바로 로그인까지 끝난 경우. authStateChanges 스트림이 반응하므로
  ///   화면은 별도 네비게이션 없이 로딩만 해제하면 된다.
  /// [onFailed]   : 발송/자동 인증 실패(잘못된 번호, 쿼터 초과 등).
  Future<void> signInWithPhone({
    required String phoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(UserCredential credential) onVerified,
    required void Function(String message) onFailed,
    bool linkToCurrentUser = false,
  }) async {
    try {
      await _firebaseAuth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          // 안드로이드 자동 인증: 코드 입력 화면 없이 바로 인증까지 끝난다.
          try {
            final userCredential = linkToCurrentUser
                ? await _linkCredentialToCurrentUser(credential)
                : await _firebaseAuth.signInWithCredential(credential);
            onVerified(userCredential);
          } on FirebaseAuthException catch (e) {
            onFailed(_firebaseAuthMessage(e, phone: true));
          } on AuthFailure catch (e) {
            onFailed(e.message);
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          onFailed(_firebaseAuthMessage(e, phone: true));
        },
        codeSent: (String verificationId, int? resendToken) {
          onCodeSent(verificationId);
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          // 자동 감지 제한시간 종료 — verificationId는 이미 codeSent에서
          // 전달됐으므로, 사용자가 직접 코드를 입력하면 confirmSmsCode()로
          // 처리된다. 여기서 추가로 할 일은 없다.
        },
      );
    } on FirebaseAuthException catch (e) {
      onFailed(_firebaseAuthMessage(e, phone: true));
    } catch (_) {
      onFailed('인증코드 발송 중 알 수 없는 오류가 발생했습니다.');
    }
  }

  /// 전화 인증 2단계: 사용자가 입력한 SMS 코드로 최종 로그인.
  ///
  /// [verificationId]는 onCodeSent에서 받은 값, [smsCode]는 사용자가 입력한 코드.
  Future<UserCredential> confirmSmsCode({
    required String verificationId,
    required String smsCode,
    bool linkToCurrentUser = false,
  }) async {
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );
      return linkToCurrentUser
          ? await _linkCredentialToCurrentUser(credential)
          : await _firebaseAuth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_firebaseAuthMessage(e, phone: true));
    }
  }

  /// Firebase Auth의 canonical 상태를 서버에서 확인해 Firestore 배지를 동기화한다.
  ///
  /// 클라이언트는 uid나 verified 값을 보내지 않는다. 최종 판정은 Cloud Functions가
  /// Admin SDK로 현재 로그인 사용자만 조회해 결정한다.
  Future<VerificationStatus> syncAuthVerificationBadges() async {
    try {
      final data = _authBadgeSyncCaller != null
          ? await _authBadgeSyncCaller()
          : (await _functions!
                    .httpsCallable('syncAuthVerificationBadges')
                    .call())
                .data;
      return _verificationStatusFromSyncResponse(data);
    } on AuthFailure {
      rethrow;
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[AuthService] syncAuthVerificationBadges failed code=${e.code}',
        );
      }
      throw const AuthFailure('인증 상태를 확인하지 못했어요. 잠시 후 다시 시도해주세요.');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthService] syncAuthVerificationBadges malformed: $e');
      }
      throw const AuthFailure('인증 상태를 확인하지 못했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  VerificationStatus _verificationStatusFromSyncResponse(dynamic data) {
    if (data is! Map) {
      throw const AuthFailure('인증 상태 응답이 올바르지 않습니다.');
    }
    final verifications = data['verifications'];
    if (verifications is! Map) {
      throw const AuthFailure('인증 상태 응답이 올바르지 않습니다.');
    }
    final email = verifications['email'];
    final phone = verifications['phone'];
    final photo = verifications['photo'];
    if (email is! bool || phone is! bool || photo is! bool) {
      throw const AuthFailure('인증 상태 응답이 올바르지 않습니다.');
    }
    return VerificationStatus(email: email, phone: phone, photo: photo);
  }

  /// 프로필 인증용: 현재 로그인 계정에 전화번호 credential을 연결한다.
  ///
  /// 일반 전화 로그인은 새 Firebase 사용자로 전환될 수 있으므로, 내 프로필의
  /// "전화 인증하기"에서는 반드시 linkWithCredential을 사용해야 한다.
  Future<UserCredential> _linkCredentialToCurrentUser(
    PhoneAuthCredential credential,
  ) async {
    final user = _auth?.currentUser;
    if (user == null) {
      throw const AuthFailure('로그인이 필요합니다.');
    }
    final result = await user.linkWithCredential(credential);
    await result.user?.reload();
    return result;
  }

  // ===========================================================================
  // 로그아웃
  // ===========================================================================

  /// 로그아웃. 구글 세션과 Firebase 세션을 모두 정리한다.
  ///
  /// 왜 구글도 signOut 하나:
  /// - Firebase만 로그아웃하면 다음 로그인 때 구글 계정 선택창이 뜨지 않고
  ///   직전 계정으로 바로 들어가버린다. 계정 선택을 다시 띄우려면 구글도 정리해야 한다.
  Future<void> signOut() async {
    try {
      // 구글이 초기화된 적이 있을 때만 signOut 시도(미초기화 상태에서 호출 방지).
      if (_googleInitialized) {
        await _googleSignIn.signOut();
      }
      await _firebaseAuth.signOut();
    } catch (_) {
      throw const AuthFailure('로그아웃 중 오류가 발생했습니다.');
    }
  }

  // ===========================================================================
  // 내부 유틸
  // ===========================================================================

  /// FirebaseAuthException 코드를 사용자용 한국어 메시지로 변환.
  ///
  /// [phone]이 true면 전화/SMS 인증 문맥의 메시지를 우선 사용한다. 같은
  /// 코드(예: operation-not-allowed)라도 이메일 로그인과 전화 인증에서
  /// 원인이 다르므로, 화면에 맞는 안내가 나가도록 문맥을 구분한다.
  String _firebaseAuthMessage(FirebaseAuthException e, {bool phone = false}) {
    // 진단용 로그 — 안정적인 code와 문맥만 남긴다.
    // 주의: e.message에는 전화번호/이메일/내부 요청 정보가 섞일 수 있으므로
    // debug 빌드에서도 출력하지 않는다. UID/OTP/verificationId/token 등도 금지.
    if (kDebugMode) {
      debugPrint(
        '[AuthService] FirebaseAuthException '
        'context=${phone ? 'phone' : 'default'} code=${e.code}',
      );
    }
    return authFailureMessageForCode(e.code, phone: phone);
  }
}

/// FirebaseAuthException 코드 → 사용자용 한국어 메시지 순수 변환 함수.
///
/// 왜 top-level 순수 함수로 분리했나:
/// - 문맥(이메일 vs 전화) 분기 로직을 FirebaseAuthException 인스턴스 없이
///   코드 문자열만으로 테스트할 수 있도록 하기 위함이다.
/// - 원문 Firebase message 문자열에 의존해 원인을 확정 파싱하지 않는다.
///   오직 안정적인 `code` 값만으로 분기한다(예: SMS region policy를 영어
///   message로 추측해 단정하지 않는다).
@visibleForTesting
String authFailureMessageForCode(String code, {bool phone = false}) {
  // 전화 인증 문맥에서만 의미가 다른 코드는 먼저 전용 매핑을 시도한다.
  // null이면 공용 매핑으로 폴백한다(전화에서도 동일한 안내면 중복을 피함).
  if (phone) {
    final phoneMessage = _phoneAuthMessageForCode(code);
    if (phoneMessage != null) return phoneMessage;
  }
  switch (code) {
    // ── 이메일/비밀번호 ──────────────────────────────────────────────────
    case 'weak-password':
      return '비밀번호는 6자 이상이어야 합니다.';
    case 'email-already-in-use':
      return '이미 사용 중인 이메일이에요.\n구글로 가입한 이메일이라면 구글로 로그인해주세요.';
    case 'invalid-email':
      return '올바른 이메일 형식이 아닙니다.';
    case 'user-not-found':
      return '등록되지 않은 이메일입니다.';
    case 'wrong-password':
      return '비밀번호가 올바르지 않습니다.';
    case 'invalid-credential':
      return '이메일 또는 비밀번호가 올바르지 않습니다.';
    case 'too-many-requests':
      return '로그인 시도가 너무 많습니다. 잠시 후 다시 시도해주세요.';
    // ── 제공업체 설정 ────────────────────────────────────────────────────
    // Firebase Console에서 해당 로그인 방식이 비활성화된 경우.
    // (전화 인증 문맥은 위 _phoneAuthMessageForCode에서 먼저 처리된다.)
    case 'operation-not-allowed':
      return '이메일/비밀번호 로그인이 활성화되지 않았습니다.\n'
          'Firebase 콘솔 → Authentication → Sign-in method에서 활성화해주세요.';
    // ── 소셜/공통 ────────────────────────────────────────────────────────
    case 'account-exists-with-different-credential':
      return '이미 다른 방식으로 가입된 이메일입니다. 구글로 로그인해주세요.';
    case 'user-disabled':
      return '비활성화된 계정입니다. 고객센터에 문의해주세요.';
    case 'invalid-verification-code':
      return '인증번호가 올바르지 않습니다.';
    case 'session-expired':
      return '인증 시간이 만료되었습니다. 다시 시도해주세요.';
    case 'network-request-failed':
      return '네트워크 연결을 확인해주세요.';
    // ── 전화번호 인증 ────────────────────────────────────────────────────
    case 'invalid-phone-number':
      return '올바른 전화번호 형식이 아닙니다.';
    case 'missing-phone-number':
      return '전화번호를 입력해주세요.';
    case 'quota-exceeded':
      return 'SMS 발송 한도를 초과했습니다. 잠시 후 다시 시도해주세요.';
    case 'captcha-check-failed':
      return '보안 확인에 실패했습니다. 다시 시도해주세요.';
    case 'invalid-verification-id':
      return '인증 세션이 유효하지 않습니다. 인증코드를 다시 받아주세요.';
    case 'credential-already-in-use':
      return '이미 다른 계정에 연결된 전화번호입니다.';
    case 'provider-already-linked':
      return '이미 전화번호 인증이 완료된 계정입니다.';
    default:
      return '인증에 실패했습니다. 잠시 후 다시 시도해주세요.';
  }
}

/// 전화/SMS 인증 문맥 전용 메시지.
///
/// 공용 매핑과 안내가 달라야 하는 코드만 여기서 처리하고, 동일하면 null을
/// 반환해 공용 매핑으로 폴백한다. 원인을 영어 message로 추측하지 않고 코드만
/// 사용한다(특히 operation-not-allowed는 SMS 허용 지역/제공업체 설정 문제가
/// 흔하므로 그 방향으로 안내한다).
String? _phoneAuthMessageForCode(String code) {
  switch (code) {
    case 'operation-not-allowed':
      // 출시용 사용자 문구: 콘솔 설정을 사용자에게 요구하지 않는다.
      // 실제 원인(제공업체/SMS 허용 지역 등)은 safe debug log의
      // context=phone code=operation-not-allowed로만 진단한다.
      return '현재 전화 인증을 사용할 수 없습니다.\n'
          '잠시 후 다시 시도해 주세요.';
    case 'invalid-credential':
      return '인증 정보가 유효하지 않습니다.\n'
          '인증코드를 다시 받아 시도해주세요.';
    case 'too-many-requests':
      return '인증 요청이 너무 많습니다. 잠시 후 다시 시도해주세요.';
    case 'session-expired':
      return '인증 시간이 만료되었습니다. 인증코드를 다시 받아주세요.';
    case 'invalid-app-credential':
      return '앱 인증에 실패했습니다. 앱을 다시 실행한 뒤 시도해주세요.';
    case 'app-not-authorized':
      return '이 앱은 전화 인증을 사용할 권한이 없습니다.\n앱 설정을 확인해 주세요.';
    default:
      // invalid-phone-number / invalid-verification-code / quota-exceeded /
      // network-request-failed 등은 공용 매핑 문구를 그대로 사용한다.
      return null;
  }
}
