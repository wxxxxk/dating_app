// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/constants/app_constants.dart';

const deleteMyAccountConfirmation = 'DELETE_MY_ACCOUNT';

enum AccountDeletionReauthProvider {
  password('password', '이메일'),
  google('google.com', 'Google'),
  phone('phone', '전화번호');

  final String providerId;
  final String label;

  const AccountDeletionReauthProvider(this.providerId, this.label);
}

class AccountDeletionFailure implements Exception {
  final String message;

  const AccountDeletionFailure(this.message);

  @override
  String toString() => message;
}

class AccountDeletionUserSnapshot {
  final String uid;
  final String? email;
  final String? phoneNumber;
  final Set<String> providerIds;

  const AccountDeletionUserSnapshot({
    required this.uid,
    required this.providerIds,
    this.email,
    this.phoneNumber,
  });

  bool supports(AccountDeletionReauthProvider provider) =>
      providerIds.contains(provider.providerId);

  List<AccountDeletionReauthProvider> get supportedProviders =>
      AccountDeletionReauthProvider.values.where(supports).toList();
}

typedef AccountDeletionSnapshotReader = AccountDeletionUserSnapshot? Function();
typedef AccountDeletionPasswordReauthenticator =
    Future<void> Function(String password);
typedef AccountDeletionGoogleReauthenticator = Future<void> Function();
typedef AccountDeletionPhoneCodeSender = Future<String> Function();
typedef AccountDeletionPhoneCodeConfirmer =
    Future<void> Function(String verificationId, String smsCode);
typedef AccountDeletionTokenRefresher =
    Future<void> Function(String expectedUid);
typedef AccountDeletionCallable =
    Future<dynamic> Function(Map<String, Object?> payload);
typedef AccountDeletionSignOutRunner = Future<void> Function();

class AccountDeletionService {
  AccountDeletionService({
    FirebaseAuth? firebaseAuth,
    FirebaseFunctions? functions,
    GoogleSignIn? googleSignIn,
    AccountDeletionSnapshotReader? snapshotReader,
    AccountDeletionPasswordReauthenticator? passwordReauthenticator,
    AccountDeletionGoogleReauthenticator? googleReauthenticator,
    AccountDeletionPhoneCodeSender? phoneCodeSender,
    AccountDeletionPhoneCodeConfirmer? phoneCodeConfirmer,
    AccountDeletionTokenRefresher? tokenRefresher,
    AccountDeletionCallable? deleteCallable,
    AccountDeletionSignOutRunner? signOutRunner,
  }) : _auth = firebaseAuth,
       _functions = functions,
       _googleSignIn = googleSignIn,
       _snapshotReader = snapshotReader,
       _passwordReauthenticator = passwordReauthenticator,
       _googleReauthenticator = googleReauthenticator,
       _phoneCodeSender = phoneCodeSender,
       _phoneCodeConfirmer = phoneCodeConfirmer,
       _tokenRefresher = tokenRefresher,
       _deleteCallable = deleteCallable,
       _signOutRunner = signOutRunner;

  final FirebaseAuth? _auth;
  final FirebaseFunctions? _functions;
  final GoogleSignIn? _googleSignIn;
  final AccountDeletionSnapshotReader? _snapshotReader;
  final AccountDeletionPasswordReauthenticator? _passwordReauthenticator;
  final AccountDeletionGoogleReauthenticator? _googleReauthenticator;
  final AccountDeletionPhoneCodeSender? _phoneCodeSender;
  final AccountDeletionPhoneCodeConfirmer? _phoneCodeConfirmer;
  final AccountDeletionTokenRefresher? _tokenRefresher;
  final AccountDeletionCallable? _deleteCallable;
  final AccountDeletionSignOutRunner? _signOutRunner;

  bool _googleInitialized = false;

  FirebaseAuth get _firebaseAuth => _auth ?? FirebaseAuth.instance;

  FirebaseFunctions get _firebaseFunctions =>
      _functions ??
      FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  GoogleSignIn get _google => _googleSignIn ?? GoogleSignIn.instance;

  AccountDeletionUserSnapshot? currentSnapshot() {
    final reader = _snapshotReader;
    if (reader != null) return reader();

    final user = _firebaseAuth.currentUser;
    if (user == null) return null;
    return AccountDeletionUserSnapshot(
      uid: user.uid,
      email: user.email,
      phoneNumber: user.phoneNumber,
      providerIds: user.providerData.map((p) => p.providerId).toSet(),
    );
  }

  List<AccountDeletionReauthProvider> supportedProviders() =>
      currentSnapshot()?.supportedProviders ?? const [];

  Future<void> reauthenticateWithPassword(String password) async {
    final delegate = _passwordReauthenticator;
    if (delegate != null) {
      await delegate(password);
      return;
    }

    final snapshot = _requireSnapshot();
    final email = snapshot.email?.trim();
    if (email == null ||
        email.isEmpty ||
        !snapshot.supports(AccountDeletionReauthProvider.password)) {
      throw const AccountDeletionFailure('이 계정은 비밀번호 재인증을 지원하지 않습니다.');
    }
    if (password.isEmpty) {
      throw const AccountDeletionFailure('비밀번호를 입력해주세요.');
    }

    try {
      final credential = EmailAuthProvider.credential(
        email: email,
        password: password,
      );
      await _requireCurrentUser().reauthenticateWithCredential(credential);
    } on FirebaseAuthException {
      throw const AccountDeletionFailure('재인증에 실패했습니다.');
    }
  }

  Future<void> reauthenticateWithGoogle() async {
    final delegate = _googleReauthenticator;
    if (delegate != null) {
      await delegate();
      return;
    }

    final beforeUid = _requireSnapshot().uid;
    if (!_requireSnapshot().supports(AccountDeletionReauthProvider.google)) {
      throw const AccountDeletionFailure('이 계정은 Google 재인증을 지원하지 않습니다.');
    }

    try {
      await _ensureGoogleInitialized();
      if (!_google.supportsAuthenticate()) {
        throw const AccountDeletionFailure('이 플랫폼에서는 Google 재인증을 지원하지 않습니다.');
      }
      final account = await _google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AccountDeletionFailure('Google 재인증에 실패했습니다.');
      }
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final result = await _requireCurrentUser().reauthenticateWithCredential(
        credential,
      );
      await result.user?.reload();
      final afterUid = result.user?.uid ?? _firebaseAuth.currentUser?.uid;
      if (afterUid != beforeUid) {
        throw const AccountDeletionFailure('현재 계정으로 다시 인증해주세요.');
      }
    } on AccountDeletionFailure {
      rethrow;
    } on FirebaseAuthException {
      throw const AccountDeletionFailure('재인증에 실패했습니다.');
    } catch (_) {
      throw const AccountDeletionFailure('Google 재인증에 실패했습니다.');
    }
  }

  Future<String> sendPhoneReauthenticationCode() async {
    final delegate = _phoneCodeSender;
    if (delegate != null) return delegate();

    final snapshot = _requireSnapshot();
    final phoneNumber = snapshot.phoneNumber?.trim();
    if (phoneNumber == null ||
        phoneNumber.isEmpty ||
        !snapshot.supports(AccountDeletionReauthProvider.phone)) {
      throw const AccountDeletionFailure('이 계정은 전화번호 재인증을 지원하지 않습니다.');
    }

    final completer = Completer<String>();
    await _firebaseAuth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (credential) async {
        try {
          await _requireCurrentUser().reauthenticateWithCredential(credential);
        } catch (_) {
          // 자동 인증 실패는 사용자가 직접 OTP를 입력하는 흐름에서 처리한다.
        }
      },
      verificationFailed: (_) {
        if (!completer.isCompleted) {
          completer.completeError(
            const AccountDeletionFailure('인증코드 발송에 실패했습니다.'),
          );
        }
      },
      codeSent: (verificationId, _) {
        if (!completer.isCompleted) completer.complete(verificationId);
      },
      codeAutoRetrievalTimeout: (_) {},
    );
    return completer.future;
  }

  Future<void> confirmPhoneReauthenticationCode({
    required String verificationId,
    required String smsCode,
  }) async {
    final delegate = _phoneCodeConfirmer;
    if (delegate != null) {
      await delegate(verificationId, smsCode);
      return;
    }
    if (verificationId.isEmpty || smsCode.trim().isEmpty) {
      throw const AccountDeletionFailure('인증번호를 입력해주세요.');
    }
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );
      await _requireCurrentUser().reauthenticateWithCredential(credential);
    } on FirebaseAuthException {
      throw const AccountDeletionFailure('재인증에 실패했습니다.');
    }
  }

  Future<void> refreshIdTokenAfterReauthentication(String expectedUid) async {
    final delegate = _tokenRefresher;
    if (delegate != null) {
      await delegate(expectedUid);
      return;
    }

    final user = _firebaseAuth.currentUser;
    if (user == null) {
      throw const AccountDeletionFailure('재인증 상태를 확인하지 못했습니다.');
    }
    if (user.uid != expectedUid) {
      throw const AccountDeletionFailure('현재 계정으로 다시 인증해주세요.');
    }
    try {
      await user.getIdToken(true);
    } on FirebaseAuthException {
      throw const AccountDeletionFailure('재인증 상태를 확인하지 못했습니다.');
    } catch (_) {
      throw const AccountDeletionFailure('재인증 상태를 확인하지 못했습니다.');
    }
  }

  Future<dynamic> deleteMyAccount() async {
    final payload = <String, Object?>{
      'confirmation': deleteMyAccountConfirmation,
    };
    final delegate = _deleteCallable;
    if (delegate != null) return delegate(payload);

    try {
      return (await _firebaseFunctions
              .httpsCallable('deleteMyAccount')
              .call(payload))
          .data;
    } on FirebaseFunctionsException {
      throw const AccountDeletionFailure('계정 삭제를 완료하지 못했습니다. 잠시 후 다시 시도해주세요.');
    } catch (_) {
      throw const AccountDeletionFailure('계정 삭제를 완료하지 못했습니다. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> signOutAfterDeletion() async {
    final delegate = _signOutRunner;
    if (delegate != null) {
      await delegate();
      return;
    }
    try {
      if (_googleInitialized) await _google.signOut();
      await _firebaseAuth.signOut();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' ||
          e.code == 'user-token-expired' ||
          e.code == 'invalid-user-token') {
        return;
      }
      throw const AccountDeletionFailure('로컬 로그인 상태 정리에 실패했습니다.');
    }
  }

  AccountDeletionUserSnapshot _requireSnapshot() {
    final snapshot = currentSnapshot();
    if (snapshot == null) {
      throw const AccountDeletionFailure('로그인이 필요합니다.');
    }
    return snapshot;
  }

  User _requireCurrentUser() {
    final user = _firebaseAuth.currentUser;
    if (user == null) {
      throw const AccountDeletionFailure('로그인이 필요합니다.');
    }
    return user;
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    await _google.initialize();
    _googleInitialized = true;
  }
}
