import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/affiliation_verification_request.dart';
import 'photo_verification_service.dart';

/// 소속 인증 제출 실패. 사용자에게는 [message]만 노출하고 raw 경로·기관명·
/// 내부 오류는 감춘다.
class AffiliationVerificationError implements Exception {
  final String message;
  const AffiliationVerificationError(this.message);

  @override
  String toString() => 'AffiliationVerificationError: $message';
}

/// 직장·학교 소속 인증 요청 서비스(Phase 3-3).
///
/// **OCR·문서 내용 자동 분석·위변조 판정을 하지 않는다.** 사용자가 올린 증빙을
/// 비공개 Storage에 저장하고 운영자가 수동으로 검토할 요청 문서를 만든다.
/// 인증 배지(verifications.work/school)는 admin 전용 callable만 켤 수 있다.
class AffiliationVerificationService {
  AffiliationVerificationService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    ImagePicker? imagePicker,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _storage = storage ?? FirebaseStorage.instance,
       _imagePicker = imagePicker ?? ImagePicker();

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;
  final ImagePicker _imagePicker;

  /// 증빙 이미지 최대 크기(5MB). 사진 인증과 동일한 제한을 쓴다.
  static const int maxProofBytes = PhotoVerificationService.maxPhotoBytes;

  static const Set<String> allowedExtensions =
      PhotoVerificationService.allowedExtensions;

  static const Map<String, String> _contentTypeByExtension = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'heic': 'image/heic',
    'heif': 'image/heif',
  };

  static const String subcollectionPath = 'affiliationVerificationRequests';
  static const String storageRoot = 'affiliationVerification';
  static const int schemaVersion = 1;

  DocumentReference<Map<String, dynamic>> _requestRef({
    required String uid,
    required AffiliationVerificationType type,
  }) {
    return _db
        .collection('users')
        .doc(uid)
        .collection(subcollectionPath)
        .doc(affiliationVerificationTypeToString(type));
  }

  /// 본인 요청 상태를 실시간 구독한다. 문서가 없거나 malformed면 null.
  Stream<AffiliationVerificationRequest?> watchRequest({
    required String uid,
    required AffiliationVerificationType type,
  }) {
    return _requestRef(uid: uid, type: type).snapshots().map((snap) {
      if (!snap.exists) return null;
      return AffiliationVerificationRequest.fromMap(snap.id, snap.data());
    });
  }

  Future<AffiliationVerificationRequest?> getRequest({
    required String uid,
    required AffiliationVerificationType type,
  }) async {
    final snap = await _requestRef(uid: uid, type: type).get();
    if (!snap.exists) return null;
    return AffiliationVerificationRequest.fromMap(snap.id, snap.data());
  }

  /// 증빙은 카메라 촬영과 갤러리 선택 모두 허용한다(사진 인증과 달리 전면
  /// 카메라를 강제하지 않는다). 취소하면 null.
  Future<XFile?> pickProofFromCamera() {
    return _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
      maxWidth: 1600,
    );
  }

  Future<XFile?> pickProofFromGallery() {
    return _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 1600,
    );
  }

  /// Storage 경로(순수 함수). storage.rules의 경로와 1:1 대응한다.
  /// 파일명에는 기관명·사용자 이름 등 개인정보를 넣지 않는다.
  static String buildStoragePath({
    required String uid,
    required AffiliationVerificationType type,
    required String uploadId,
    required String extension,
  }) {
    final typeName = affiliationVerificationTypeToString(type);
    return '$storageRoot/$uid/$typeName/$uploadId.$extension';
  }

  /// 요청 문서 payload(순수 함수). **공개 download URL을 담지 않는다.**
  static Map<String, dynamic> buildRequestDoc({
    required String uid,
    required AffiliationVerificationType type,
    required String institutionName,
    required String affiliationDetail,
    required String proofType,
    required String storagePath,
    required Object timestamp,
  }) {
    return {
      'uid': uid,
      'type': affiliationVerificationTypeToString(type),
      'institutionName': institutionName,
      'affiliationDetail': affiliationDetail,
      'proofType': proofType,
      'status': affiliationVerificationStatusToString(
        AffiliationVerificationStatus.pending,
      ),
      'storagePath': storagePath,
      'submittedAt': timestamp,
      'updatedAt': timestamp,
      'reviewedAt': null,
      'rejectionReason': null,
      'schemaVersion': schemaVersion,
    };
  }

  /// 현재 상태에서 새 제출이 가능한지(순수 함수).
  static bool canSubmit(AffiliationVerificationRequest? current) {
    if (current == null) return true;
    return current.isRejected;
  }

  /// 입력값 trim/검증(순수 함수). 실패 시 [AffiliationVerificationError].
  static ({String institutionName, String affiliationDetail})
  normalizeInput({
    required AffiliationVerificationType type,
    required String institutionName,
    required String affiliationDetail,
    required String proofType,
  }) {
    final name = institutionName.trim();
    if (name.length < AffiliationVerificationRequest.institutionNameMinLength ||
        name.length > AffiliationVerificationRequest.institutionNameMaxLength) {
      throw const AffiliationVerificationError('기관명을 2~80자로 입력해주세요.');
    }
    final detail = affiliationDetail.trim();
    if (detail.length >
        AffiliationVerificationRequest.affiliationDetailMaxLength) {
      throw const AffiliationVerificationError('상세 소속은 80자까지 입력할 수 있어요.');
    }
    if (!isAffiliationProofTypeAllowed(type, proofType)) {
      throw const AffiliationVerificationError('선택한 인증 종류에 맞는 증빙을 골라주세요.');
    }
    return (institutionName: name, affiliationDetail: detail);
  }

  /// 증빙 이미지를 업로드하고 요청 문서를 만든다(반려 상태면 재제출).
  ///
  /// 실패 시 고정 문구만 노출한다. uid·storagePath·기관명은 사용자 오류 메시지와
  /// 로그 어디에도 넣지 않는다.
  Future<void> submitVerification({
    required String uid,
    required AffiliationVerificationType type,
    required String institutionName,
    required String affiliationDetail,
    required String proofType,
    required XFile proof,
  }) async {
    if (uid.isEmpty) {
      throw const AffiliationVerificationError(
        '인증 요청을 제출하지 못했어요. 잠시 후 다시 시도해주세요.',
      );
    }

    // 2. 입력 normalize/검증 (제출 불가 상태보다 먼저 사용자 입력 오류를 알린다)
    final normalized = normalizeInput(
      type: type,
      institutionName: institutionName,
      affiliationDetail: affiliationDetail,
      proofType: proofType,
    );

    final extension = PhotoVerificationService.extensionOf(
      proof.name.isEmpty ? proof.path : proof.name,
    );
    if (!allowedExtensions.contains(extension)) {
      throw const AffiliationVerificationError(
        'jpg, png, heic 형식의 이미지만 제출할 수 있어요.',
      );
    }

    // 1. 현재 상태 확인 — pending/approved면 중복 제출을 막는다.
    final current = await getRequest(uid: uid, type: type);
    if (!canSubmit(current)) {
      throw AffiliationVerificationError(
        current!.isPending ? '이미 검토 중인 요청이 있어요.' : '이미 인증이 완료됐어요.',
      );
    }

    // 3~4. bytes 읽기 + 크기 검증
    final Uint8List bytes;
    try {
      bytes = await proof.readAsBytes();
    } catch (_) {
      throw const AffiliationVerificationError('이미지를 읽지 못했어요. 다시 선택해주세요.');
    }
    if (bytes.isEmpty) {
      throw const AffiliationVerificationError('이미지를 읽지 못했어요. 다시 선택해주세요.');
    }
    if (bytes.length > maxProofBytes) {
      throw const AffiliationVerificationError('이미지 용량이 너무 커요. 다시 선택해주세요.');
    }

    // 5~6. 고유 경로 생성 후 업로드. 재제출은 반드시 새 경로를 쓴다(rules도 요구).
    final storagePath = buildStoragePath(
      uid: uid,
      type: type,
      uploadId: PhotoVerificationService.generateUploadId(),
      extension: extension,
    );
    try {
      await _storage.ref(storagePath).putData(
        bytes,
        SettableMetadata(contentType: _contentTypeByExtension[extension]),
      );
    } catch (_) {
      throw const AffiliationVerificationError(
        '이미지를 업로드하지 못했어요. 잠시 후 다시 시도해주세요.',
      );
    }

    // 7. 요청 문서 생성/재제출. 실패해도 업로드 파일을 클라이언트가 임의로
    //    지우지 않는다(권한도 없다) — orphan 정리는 서버 운영 백로그로 둔다.
    try {
      final doc = buildRequestDoc(
        uid: uid,
        type: type,
        institutionName: normalized.institutionName,
        affiliationDetail: normalized.affiliationDetail,
        proofType: proofType,
        storagePath: storagePath,
        timestamp: FieldValue.serverTimestamp(),
      );
      final ref = _requestRef(uid: uid, type: type);
      if (current == null) {
        await ref.set(doc);
      } else {
        // rejected → pending 재제출. rules가 허용하는 전체 필드로 덮어쓴다.
        await ref.update(doc);
      }
    } catch (_) {
      throw const AffiliationVerificationError(
        '인증 요청을 제출하지 못했어요. 잠시 후 다시 시도해주세요.',
      );
    }
  }
}
