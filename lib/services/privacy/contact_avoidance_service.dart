import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../../core/constants/app_constants.dart';
import '../../models/contact_avoidance_settings.dart';
import 'contact_phone_normalizer.dart';

/// 지인 피하기 실패. 사용자에게는 [message]만 노출하고 raw 오류·연락처 정보는
/// 감춘다.
class ContactAvoidanceError implements Exception {
  final String message;
  const ContactAvoidanceError(this.message);

  @override
  String toString() => 'ContactAvoidanceError: $message';
}

/// 연락처 권한 거부. 화면이 별도 안내를 보여줄 수 있게 타입을 나눈다.
class ContactPermissionDeniedError extends ContactAvoidanceError {
  const ContactPermissionDeniedError()
    : super('연락처 권한이 필요해요. 기기 설정에서 연락처 접근을 허용한 뒤 다시 시도해주세요.');
}

/// 지인 피하기(Phase 3-4) 클라이언트 서비스.
///
/// 기기에서 **전화번호만** 읽어 정규화 → SHA-256 digest로 바꾼 뒤 서버에 보낸다.
/// 연락처 이름·사진·이메일은 요청하지도, 전송하지도 않는다. 원문 번호와 Contact
/// 객체는 메서드 밖으로 나가지 않으며 상태로 보관하지 않는다.
class ContactAvoidanceService {
  ContactAvoidanceService({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _functions =
           functions ??
           FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// 한 번에 동기화할 수 있는 고유 전화번호 수(서버 검증과 동일 값).
  static const int maxContactDigests = 2000;

  static const String settingsSubcollection = 'contactAvoidanceSettings';
  static const String settingsDocId = 'current';
  static const String pairsCollection = 'contactAvoidancePairs';
  static const String callableName = 'syncAvoidContacts';

  DocumentReference<Map<String, dynamic>> _settingsRef(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .collection(settingsSubcollection)
        .doc(settingsDocId);
  }

  /// 본인 설정 요약을 실시간 구독한다(서버 전용 write, 본인만 read).
  Stream<ContactAvoidanceSettings?> watchSettings(String uid) {
    return _settingsRef(uid).snapshots().map((snap) {
      if (!snap.exists) return null;
      return ContactAvoidanceSettings.fromMap(snap.data());
    });
  }

  Future<ContactAvoidanceSettings?> getSettings(String uid) async {
    final snap = await _settingsRef(uid).get();
    if (!snap.exists) return null;
    return ContactAvoidanceSettings.fromMap(snap.data());
  }

  /// 나와 지인 피하기 pair로 묶인 상대 uid 집합을 구독한다.
  ///
  /// rules가 participants에 본인이 포함된 문서만 읽도록 보장한다.
  Stream<Set<String>> watchAvoidedUids(String uid) {
    if (uid.isEmpty) return Stream.value(const <String>{});
    return _db
        .collection(pairsCollection)
        .where('participants', arrayContains: uid)
        .snapshots()
        .map((snap) => avoidedUidsFromDocs(uid, snap.docs.map((d) => d.data())));
  }

  /// pair 문서 목록에서 상대 uid만 뽑는다(순수 함수).
  /// malformed 문서(participants 누락·타입 오류)는 조용히 건너뛴다.
  static Set<String> avoidedUidsFromDocs(
    String currentUid,
    Iterable<Map<String, dynamic>> docs,
  ) {
    final result = <String>{};
    for (final data in docs) {
      final participants = data['participants'];
      if (participants is! List) continue;
      for (final participant in participants) {
        if (participant is! String) continue;
        if (participant.isEmpty || participant == currentUid) continue;
        result.add(participant);
      }
    }
    return result;
  }

  /// 연락처 읽기 권한을 요청한다. 거부되면 false.
  Future<bool> requestContactsPermission() async {
    try {
      final status = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      return status == PermissionStatus.granted ||
          status == PermissionStatus.limited;
    } catch (_) {
      // 권한 요청 실패(동시 요청 등)는 거부와 동일하게 다룬다. crash 금지.
      return false;
    }
  }

  /// 기기 연락처에서 **전화번호만** 읽어 digest 집합을 만든다.
  ///
  /// 이름·사진·이메일 속성은 요청하지 않는다. 반환값에는 원문이 없다.
  Future<Set<String>> loadContactDigests() async {
    final contacts = await FlutterContacts.getAll(
      properties: {ContactProperty.phone},
    );
    // 번호만 추출해 즉시 digest로 바꾸고 원문 리스트는 이 스코프를 벗어나지 않는다.
    return contactPhoneDigests(
      contacts.expand((contact) => contact.phones.map((phone) => phone.number)),
    );
  }

  /// 연락처를 동기화해 지인 피하기를 켠다(재동기화도 같은 경로).
  Future<ContactAvoidanceSyncResult> syncContacts({required String uid}) async {
    if (uid.isEmpty) {
      throw const ContactAvoidanceError('동기화하지 못했어요. 잠시 후 다시 시도해주세요.');
    }

    final granted = await requestContactsPermission();
    if (!granted) throw const ContactPermissionDeniedError();

    final Set<String> digests;
    try {
      digests = await loadContactDigests();
    } catch (_) {
      throw const ContactAvoidanceError('연락처를 읽지 못했어요. 잠시 후 다시 시도해주세요.');
    }

    if (digests.length > maxContactDigests) {
      // 임의로 잘라내면 사용자가 기대한 것과 다른 결과가 되므로 중단한다.
      throw const ContactAvoidanceError(
        '연락처가 너무 많아 동기화할 수 없어요. (최대 2,000개)',
      );
    }

    return _callSync(enabled: true, digests: digests.toList());
  }

  /// 지인 피하기를 끈다. 연락처를 다시 읽거나 전송하지 않는다.
  Future<ContactAvoidanceSyncResult> disable({required String uid}) {
    if (uid.isEmpty) {
      throw const ContactAvoidanceError('설정을 변경하지 못했어요. 잠시 후 다시 시도해주세요.');
    }
    return _callSync(enabled: false, digests: const []);
  }

  Future<ContactAvoidanceSyncResult> _callSync({
    required bool enabled,
    required List<String> digests,
  }) async {
    try {
      final callable = _functions.httpsCallable(callableName);
      final response = await callable.call<Map<Object?, Object?>>({
        'enabled': enabled,
        'contactDigests': digests,
      });
      return ContactAvoidanceSyncResult.fromMap(response.data);
    } on FirebaseFunctionsException catch (e) {
      throw ContactAvoidanceError(_messageForCode(e.code));
    } catch (_) {
      throw const ContactAvoidanceError('동기화하지 못했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  /// 서버 오류 코드를 사용자 안전 문구로 바꾼다(raw 오류·내부 메시지 미노출).
  static String _messageForCode(String code) {
    switch (code) {
      case 'resource-exhausted':
        return '잠시 후 다시 동기화해주세요.';
      case 'failed-precondition':
        return '지인 피하기를 사용하려면 먼저 전화 인증이 필요해요.';
      case 'invalid-argument':
        return '연락처 정보를 처리하지 못했어요. 잠시 후 다시 시도해주세요.';
      case 'unauthenticated':
        return '다시 로그인한 뒤 시도해주세요.';
      default:
        return '동기화하지 못했어요. 잠시 후 다시 시도해주세요.';
    }
  }
}
