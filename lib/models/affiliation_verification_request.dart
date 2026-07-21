import 'package:cloud_firestore/cloud_firestore.dart';

/// 소속 인증 종류. 직장과 학교는 서로 독립적으로 인증할 수 있다.
enum AffiliationVerificationType { work, school }

String affiliationVerificationTypeToString(AffiliationVerificationType type) =>
    type.name;

AffiliationVerificationType? affiliationVerificationTypeFromString(
  Object? value,
) {
  switch (value) {
    case 'work':
      return AffiliationVerificationType.work;
    case 'school':
      return AffiliationVerificationType.school;
    default:
      return null;
  }
}

String affiliationVerificationTypeLabel(AffiliationVerificationType type) {
  switch (type) {
    case AffiliationVerificationType.work:
      return '직장 인증';
    case AffiliationVerificationType.school:
      return '학교 인증';
  }
}

/// 증빙 유형 key와 사용자 표시 문구.
const Map<String, String> affiliationProofTypeLabels = {
  'employee_id': '사원증',
  'employment_certificate': '재직 증명 자료',
  'student_id': '학생증',
  'enrollment_certificate': '재학 증명 자료',
};

/// 인증 종류별 허용 증빙 유형. 잘못된 조합(work + student_id 등)은
/// 클라이언트와 firestore.rules 양쪽에서 거부한다.
const Map<AffiliationVerificationType, List<String>> affiliationProofTypesByType =
    {
      AffiliationVerificationType.work: [
        'employee_id',
        'employment_certificate',
      ],
      AffiliationVerificationType.school: [
        'student_id',
        'enrollment_certificate',
      ],
    };

bool isAffiliationProofTypeAllowed(
  AffiliationVerificationType type,
  String proofType,
) {
  return affiliationProofTypesByType[type]!.contains(proofType);
}

String affiliationProofTypeLabel(String? key) =>
    affiliationProofTypeLabels[key] ?? '증빙 자료';

/// 소속 인증 요청 상태.
enum AffiliationVerificationStatus { pending, approved, rejected }

String affiliationVerificationStatusToString(
  AffiliationVerificationStatus status,
) => status.name;

AffiliationVerificationStatus? affiliationVerificationStatusFromString(
  Object? value,
) {
  switch (value) {
    case 'pending':
      return AffiliationVerificationStatus.pending;
    case 'approved':
      return AffiliationVerificationStatus.approved;
    case 'rejected':
      return AffiliationVerificationStatus.rejected;
    default:
      return null;
  }
}

/// 서버가 저장할 수 있는 반려 사유 key와 사용자 표시 문구.
/// 관리자 자유 입력 문구는 저장하지 않는다.
const Map<String, String> affiliationRejectionReasonLabels = {
  'document_not_clear': '자료가 흐리거나 내용을 확인하기 어려워요.',
  'institution_not_visible': '기관명이 충분히 보이지 않아요.',
  'affiliation_not_confirmed': '현재 소속 상태를 확인하기 어려워요.',
  'sensitive_info_visible': '민감한 번호나 QR 코드를 가린 뒤 다시 제출해주세요.',
  'expired_document': '현재 상태를 확인할 수 있는 최근 자료가 필요해요.',
  'other': '인증 자료를 다시 준비해주세요.',
};

/// 알 수 없는 key는 other 문구로 처리한다.
String affiliationRejectionReasonLabel(String? key) =>
    affiliationRejectionReasonLabels[key] ??
    affiliationRejectionReasonLabels['other']!;

/// users/{uid}/affiliationVerificationRequests/{type} 문서 모델.
///
/// 기관명·상세 소속은 이 요청 문서에만 저장되고 공개 프로필에는 올라가지 않는다.
/// [storagePath]는 운영 검토용 비공개 경로이므로 화면에 표시하지 않는다.
class AffiliationVerificationRequest {
  static const int institutionNameMinLength = 2;
  static const int institutionNameMaxLength = 80;
  static const int affiliationDetailMaxLength = 80;

  final String uid;
  final AffiliationVerificationType type;
  final String institutionName;
  final String affiliationDetail;
  final String proofType;
  final AffiliationVerificationStatus status;
  final String storagePath;
  final DateTime? submittedAt;
  final DateTime? updatedAt;
  final DateTime? reviewedAt;
  final String? rejectionReason;

  const AffiliationVerificationRequest({
    required this.uid,
    required this.type,
    required this.institutionName,
    required this.affiliationDetail,
    required this.proofType,
    required this.status,
    required this.storagePath,
    required this.submittedAt,
    required this.updatedAt,
    required this.reviewedAt,
    required this.rejectionReason,
  });

  bool get isPending => status == AffiliationVerificationStatus.pending;
  bool get isApproved => status == AffiliationVerificationStatus.approved;
  bool get isRejected => status == AffiliationVerificationStatus.rejected;

  /// 사용자에게 보여줄 반려 문구. 반려 상태가 아니면 null.
  String? get rejectionLabel =>
      isRejected ? affiliationRejectionReasonLabel(rejectionReason) : null;

  /// malformed 문서는 crash 없이 처리한다. type/status를 알 수 없으면 null을
  /// 반환해 화면이 "요청 없음"으로 안전하게 폴백한다. unknown field는 무시.
  static AffiliationVerificationRequest? fromMap(
    String docId,
    Map<String, dynamic>? data,
  ) {
    if (data == null) return null;

    // 문서 id가 곧 type이다. body와 어긋나면 신뢰하지 않는다.
    final type = affiliationVerificationTypeFromString(docId);
    if (type == null) return null;
    final bodyType = affiliationVerificationTypeFromString(data['type']);
    if (bodyType != type) return null;

    final status = affiliationVerificationStatusFromString(data['status']);
    if (status == null) return null;

    final uid = data['uid'];
    if (uid is! String || uid.isEmpty) return null;

    final submittedAt = data['submittedAt'];
    final updatedAt = data['updatedAt'];
    final reviewedAt = data['reviewedAt'];
    final rejectionReason = data['rejectionReason'];

    return AffiliationVerificationRequest(
      uid: uid,
      type: type,
      institutionName: data['institutionName'] is String
          ? data['institutionName'] as String
          : '',
      affiliationDetail: data['affiliationDetail'] is String
          ? data['affiliationDetail'] as String
          : '',
      proofType: data['proofType'] is String ? data['proofType'] as String : '',
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

  static AffiliationVerificationRequest? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return fromMap(doc.id, doc.data());
  }
}
