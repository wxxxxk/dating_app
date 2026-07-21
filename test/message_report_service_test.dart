import 'package:dating_app/services/safety/safety_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2-4 — 메시지 신고 payload/검증 테스트.
///
/// 실제 Firestore write 경로는 Emulator rules 테스트가 검증하고, 여기서는
/// 신고 문서에 무엇이 담기고 무엇이 담기지 않는지(원문 미저장)와 클라이언트
/// 1차 검증을 순수 함수로 확인한다.
Map<String, dynamic> build({
  String reporterUid = 'userA',
  String reportedUid = 'userB',
  String matchId = 'match1',
  String messageId = 'msg1',
  String reason = 'abusive_language',
  String? detail,
  Object createdAt = 'ts',
}) {
  return SafetyService.buildMessageReportDoc(
    reporterUid: reporterUid,
    reportedUid: reportedUid,
    matchId: matchId,
    messageId: messageId,
    reason: reason,
    detail: detail,
    createdAt: createdAt,
  );
}

void main() {
  test('1. 올바른 참조 필드로 신고 문서를 만든다', () {
    final doc = build(detail: '반복해서 욕설을 보냈어요');

    expect(doc, {
      'reportType': 'message',
      'reporterUid': 'userA',
      'reportedUid': 'userB',
      'matchId': 'match1',
      'messageId': 'msg1',
      'reason': 'abusive_language',
      'detail': '반복해서 욕설을 보냈어요',
      'createdAt': 'ts',
    });
  });

  test('2. 메시지 원문·프로필 정보를 저장하지 않는다', () {
    final doc = build(detail: '설명');

    // rules allowlist와 정확히 같은 키만 담긴다.
    expect(doc.keys.toSet(), {
      'reportType',
      'reporterUid',
      'reportedUid',
      'matchId',
      'messageId',
      'reason',
      'detail',
      'createdAt',
    });
    for (final forbidden in [
      'text',
      'messageText',
      'senderId',
      'photoUrls',
      'displayName',
      'fcmTokens',
      'location',
    ]) {
      expect(doc.containsKey(forbidden), isFalse, reason: '$forbidden 미저장');
    }
    // 값 어디에도 원문이 섞이지 않는다.
    expect(doc.values.join(' '), isNot(contains('욕설 원문')));
  });

  test('detail이 없으면 필드 자체를 생략한다', () {
    expect(build().containsKey('detail'), isFalse);
    expect(build(detail: '').containsKey('detail'), isFalse);
    expect(build(detail: '   ').containsKey('detail'), isFalse);
  });

  test('3. 빈 reporterUid/reportedUid를 거부한다', () {
    expect(() => build(reporterUid: ''), throwsArgumentError);
    expect(() => build(reportedUid: ''), throwsArgumentError);
  });

  test('4. 자기 자신을 대상으로 한 신고를 거부한다', () {
    expect(
      () => build(reporterUid: 'userA', reportedUid: 'userA'),
      throwsArgumentError,
    );
  });

  test('5. 빈 matchId/messageId를 거부한다', () {
    expect(() => build(matchId: ''), throwsArgumentError);
    expect(() => build(messageId: ''), throwsArgumentError);
  });

  test('6. 허용되지 않은 reason을 거부한다', () {
    expect(() => build(reason: 'nope'), throwsArgumentError);
    // 사용자 신고 전용 사유는 메시지 신고에서 쓸 수 없다.
    expect(() => build(reason: 'inappropriate_photo'), throwsArgumentError);
    expect(() => build(reason: 'impersonation'), throwsArgumentError);

    for (final reason in messageReportReasonLabels.keys) {
      expect(build(reason: reason)['reason'], reason);
    }
  });

  test('7. detail은 trim해서 저장한다', () {
    expect(build(detail: '  욕설이 심해요  ')['detail'], '욕설이 심해요');
  });

  test('8. detail 500자 초과를 거부한다', () {
    expect(build(detail: 'ㄱ' * 500)['detail'], hasLength(500));
    expect(() => build(detail: 'ㄱ' * 501), throwsArgumentError);
    // 앞뒤 공백은 trim 후 길이로 판단한다.
    expect(build(detail: '  ${'ㄱ' * 500}  ')['detail'], hasLength(500));
  });

  test('9. 기존 사용자 신고 사유 계약은 그대로 유지된다', () {
    expect(reportReasonLabels.keys.toSet(), {
      'inappropriate_photo',
      'abusive_language',
      'spam_scam',
      'impersonation',
      'other',
    });
    expect(messageReportReasonLabels.keys.toSet(), {
      'abusive_language',
      'sexual_harassment',
      'hate_threat',
      'spam_scam',
      'personal_info',
      'other',
    });
    // 두 신고 경로는 서로 다른 사유 집합을 쓴다.
    expect(reportReasonLabels.containsKey('sexual_harassment'), isFalse);
    expect(
      messageReportReasonLabels.containsKey('inappropriate_photo'),
      isFalse,
    );
    expect(reportDetailMaxLength, 500);
  });
}
