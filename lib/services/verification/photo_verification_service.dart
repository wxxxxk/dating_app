import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/photo_verification_request.dart';

/// 사진 인증 제출 실패. 사용자에게는 [message]만 노출하고 raw 경로·uid·내부
/// 오류는 감춘다.
class PhotoVerificationError implements Exception {
  final String message;
  const PhotoVerificationError(this.message);

  @override
  String toString() => 'PhotoVerificationError: $message';
}

/// 사진 인증 요청 서비스(Phase 3-2).
///
/// **자동 얼굴 인식·생체 판정을 하지 않는다.** 사용자가 촬영한 셀피를 비공개
/// Storage에 올리고, 운영자가 수동으로 검토할 수 있는 요청 문서를 만든다.
/// 승인/반려와 인증 배지 갱신은 서버(admin 전용 callable)만 수행한다.
class PhotoVerificationService {
  PhotoVerificationService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    ImagePicker? imagePicker,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _storage = storage ?? FirebaseStorage.instance,
       _imagePicker = imagePicker ?? ImagePicker();

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;
  final ImagePicker _imagePicker;

  /// 인증 사진 최대 크기(5MB).
  static const int maxPhotoBytes = 5 * 1024 * 1024;

  static const Set<String> allowedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'heic',
    'heif',
  };

  static const Map<String, String> _contentTypeByExtension = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'heic': 'image/heic',
    'heif': 'image/heif',
  };

  static const String collectionPath = 'photoVerificationRequests';
  static const String storageRoot = 'photoVerification';
  static const int schemaVersion = 1;

  DocumentReference<Map<String, dynamic>> _requestRef(String uid) =>
      _db.collection(collectionPath).doc(uid);

  /// 본인 요청 상태를 실시간 구독한다. 문서가 없거나 malformed면 null.
  Stream<PhotoVerificationRequest?> watchRequest(String uid) {
    return _requestRef(uid).snapshots().map((snap) {
      if (!snap.exists) return null;
      return PhotoVerificationRequest.fromMap(snap.id, snap.data());
    });
  }

  Future<PhotoVerificationRequest?> getRequest(String uid) async {
    final snap = await _requestRef(uid).get();
    if (!snap.exists) return null;
    return PhotoVerificationRequest.fromMap(snap.id, snap.data());
  }

  /// 인증용 셀피를 **카메라로만** 촬영한다. 갤러리 선택은 제공하지 않는다.
  /// 사용자가 취소하면 null을 반환한다.
  Future<XFile?> captureVerificationPhoto() {
    return _imagePicker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      imageQuality: 80,
      maxWidth: 1440,
    );
  }

  /// 파일명 확장자(소문자). 알 수 없으면 'jpg'로 본다.
  static String extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'jpg';
    return path.substring(dot + 1).toLowerCase();
  }

  /// Storage 경로(순수 함수). storage.rules의 경로와 1:1 대응한다.
  static String buildStoragePath({
    required String uid,
    required String uploadId,
    required String extension,
  }) {
    return '$storageRoot/$uid/$uploadId.$extension';
  }

  /// 충돌 가능성이 낮은 uploadId를 만든다(새 dependency 없이 timestamp + 난수).
  static String generateUploadId({DateTime? now, Random? random}) {
    final millis = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rnd = random ?? Random.secure();
    final suffix = List.generate(
      12,
      (_) => _idAlphabet[rnd.nextInt(_idAlphabet.length)],
    ).join();
    return '${millis}_$suffix';
  }

  static const String _idAlphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  /// 요청 문서 payload(순수 함수). **공개 download URL을 담지 않는다** —
  /// 운영 검토는 storagePath로만 원본을 찾는다.
  static Map<String, dynamic> buildRequestDoc({
    required String uid,
    required String storagePath,
    required Object timestamp,
  }) {
    return {
      'uid': uid,
      'status': photoVerificationStatusToString(
        PhotoVerificationStatus.pending,
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
  /// 요청이 없거나 반려된 경우에만 제출할 수 있다.
  static bool canSubmit(PhotoVerificationRequest? current) {
    if (current == null) return true;
    return current.isRejected;
  }

  /// 인증 사진을 업로드하고 요청 문서를 만든다(반려 상태면 재제출).
  ///
  /// 실패 시 [PhotoVerificationError]의 고정 문구만 노출한다. uid·storagePath·
  /// 원본 오류는 사용자 화면과 로그 어디에도 넣지 않는다.
  Future<void> submitVerificationPhoto({
    required String uid,
    required XFile photo,
  }) async {
    if (uid.isEmpty) {
      throw const PhotoVerificationError('사진 인증을 제출하지 못했어요. 잠시 후 다시 시도해주세요.');
    }

    final extension = extensionOf(photo.name.isEmpty ? photo.path : photo.name);
    if (!allowedExtensions.contains(extension)) {
      throw const PhotoVerificationError('jpg, png, heic 형식의 사진만 제출할 수 있어요.');
    }

    // 1. 현재 상태 확인 — pending/approved면 중복 제출을 막는다.
    final current = await getRequest(uid);
    if (!canSubmit(current)) {
      throw PhotoVerificationError(
        current!.isPending
            ? '이미 검토 중인 요청이 있어요.'
            : '이미 사진 인증이 완료됐어요.',
      );
    }

    // 2~3. bytes 읽기 + 크기 검증
    final Uint8List bytes;
    try {
      bytes = await photo.readAsBytes();
    } catch (_) {
      throw const PhotoVerificationError('사진을 읽지 못했어요. 다시 촬영해주세요.');
    }
    if (bytes.isEmpty) {
      throw const PhotoVerificationError('사진을 읽지 못했어요. 다시 촬영해주세요.');
    }
    if (bytes.length > maxPhotoBytes) {
      throw const PhotoVerificationError('사진 용량이 너무 커요. 다시 촬영해주세요.');
    }

    // 4~5. 고유 경로 생성 후 업로드
    final storagePath = buildStoragePath(
      uid: uid,
      uploadId: generateUploadId(),
      extension: extension,
    );
    try {
      await _storage.ref(storagePath).putData(
        bytes,
        SettableMetadata(contentType: _contentTypeByExtension[extension]),
      );
    } catch (_) {
      throw const PhotoVerificationError('사진을 업로드하지 못했어요. 잠시 후 다시 시도해주세요.');
    }

    // 6. 요청 문서 생성/재제출. 실패해도 업로드 파일을 클라이언트가 임의로
    //    지우지 않는다(권한도 없다) — orphan 정리는 서버 운영 백로그로 둔다.
    try {
      final doc = buildRequestDoc(
        uid: uid,
        storagePath: storagePath,
        timestamp: FieldValue.serverTimestamp(),
      );
      if (current == null) {
        await _requestRef(uid).set(doc);
      } else {
        // rejected → pending 재제출. rules가 허용하는 전체 필드로 덮어쓴다.
        await _requestRef(uid).update(doc);
      }
    } catch (_) {
      throw const PhotoVerificationError('사진 인증을 제출하지 못했어요. 잠시 후 다시 시도해주세요.');
    }
  }
}
