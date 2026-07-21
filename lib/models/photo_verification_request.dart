import 'package:cloud_firestore/cloud_firestore.dart';

/// 사진 인증 요청 상태.
enum PhotoVerificationStatus { pending, approved, rejected }

String photoVerificationStatusToString(PhotoVerificationStatus status) =>
    status.name;

/// 알 수 없는 값은 null로 본다(임의 상태로 추측하지 않는다).
PhotoVerificationStatus? photoVerificationStatusFromString(Object? value) {
  switch (value) {
    case 'pending':
      return PhotoVerificationStatus.pending;
    case 'approved':
      return PhotoVerificationStatus.approved;
    case 'rejected':
      return PhotoVerificationStatus.rejected;
    default:
      return null;
  }
}

/// 서버가 저장할 수 있는 반려 사유 key와 사용자 표시 문구.
///
/// 관리자는 key만 저장한다. 관리자 자유 입력 원문을 사용자 화면에 그대로
/// 노출하지 않기 위한 계약이다.
const Map<String, String> photoRejectionReasonLabels = {
  'face_not_clear': '얼굴이 충분히 보이지 않아요.',
  'photo_mismatch': '프로필 사진과 확인하기 어려워요.',
  'face_covered': '마스크나 물건으로 얼굴이 가려져 있어요.',
  'image_quality': '사진이 흐리거나 너무 어두워요.',
  'other': '사진을 다시 촬영해주세요.',
};

/// 허용되지 않은/알 수 없는 key는 안전한 기본 문구로 대체한다.
String photoRejectionReasonLabel(String? key) {
  return photoRejectionReasonLabels[key] ??
      photoRejectionReasonLabels['other']!;
}

/// photoVerificationRequests/{uid} 문서 모델.
///
/// [storagePath]는 운영 검토용 비공개 경로다 — 화면에 표시하지 않는다.
/// 공개 download URL은 어디에도 저장하지 않는다.
class PhotoVerificationRequest {
  final String uid;
  final PhotoVerificationStatus status;
  final String storagePath;
  final DateTime? submittedAt;
  final DateTime? updatedAt;
  final DateTime? reviewedAt;
  final String? rejectionReason;

  const PhotoVerificationRequest({
    required this.uid,
    required this.status,
    required this.storagePath,
    required this.submittedAt,
    required this.updatedAt,
    required this.reviewedAt,
    required this.rejectionReason,
  });

  bool get isPending => status == PhotoVerificationStatus.pending;
  bool get isApproved => status == PhotoVerificationStatus.approved;
  bool get isRejected => status == PhotoVerificationStatus.rejected;

  /// 사용자에게 보여줄 반려 문구. 반려 상태가 아니면 null.
  String? get rejectionLabel =>
      isRejected ? photoRejectionReasonLabel(rejectionReason) : null;

  /// malformed 문서는 crash 없이 처리한다. status를 알 수 없으면 null을 반환해
  /// 화면이 "요청 없음"으로 안전하게 폴백하도록 한다. unknown field는 무시.
  static PhotoVerificationRequest? fromMap(
    String uid,
    Map<String, dynamic>? data,
  ) {
    if (uid.isEmpty) return null;
    if (data == null) return null;

    final status = photoVerificationStatusFromString(data['status']);
    if (status == null) return null;

    final submittedAt = data['submittedAt'];
    final updatedAt = data['updatedAt'];
    final reviewedAt = data['reviewedAt'];
    final rejectionReason = data['rejectionReason'];

    return PhotoVerificationRequest(
      uid: uid,
      status: status,
      storagePath: data['storagePath'] is String
          ? data['storagePath'] as String
          : '',
      submittedAt: submittedAt is Timestamp ? submittedAt.toDate() : null,
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
      reviewedAt: reviewedAt is Timestamp ? reviewedAt.toDate() : null,
      rejectionReason: rejectionReason is String ? rejectionReason : null,
    );
  }

  static PhotoVerificationRequest? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return fromMap(doc.id, doc.data());
  }
}
