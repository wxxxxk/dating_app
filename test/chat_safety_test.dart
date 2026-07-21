import 'package:dating_app/features/chat/chat_safety.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2-3 — 채팅 안전 가이드 detector 테스트.
///
/// detector는 순수 함수이며 원문을 저장하거나 로그로 남기지 않는다. 오탐(날짜·
/// 시간·가격 같은 일상 대화)이 경고로 이어지지 않는지도 함께 확인한다.
Set<ChatSafetyRisk> risks(String text) => detectChatSafetyRisks(text).risks;

void main() {
  group('1. 일반 문장은 risk 없음', () {
    for (final text in [
      '안녕하세요! 오늘 날씨 좋네요',
      '주말에 시간 괜찮으세요?',
      '오늘 돈까스 먹자',
      '가격이 12000원이야',
      '온라인으로 먼저 얘기해요',
      '나중에 연락해요',
      '',
      '   ',
    ]) {
      test('"$text"', () {
        expect(detectChatSafetyRisks(text).hasRisk, isFalse);
      });
    }
  });

  group('2~3. 전화번호 탐지', () {
    for (final text in [
      '제 번호는 010-1234-5678이에요',
      '010 1234 5678 로 연락주세요',
      '01012345678',
      '011-123-4567',
    ]) {
      test('"$text"', () {
        expect(risks(text), contains(ChatSafetyRisk.phoneNumber));
      });
    }
  });

  group('4~5. 날짜·시간은 전화번호로 오탐하지 않는다', () {
    for (final text in [
      '2026년 7월 23일에 만나요',
      '2026-07-23 어때요?',
      '오후 7시 30분에 봐요',
      '7월 24일 19시에 만나요',
      '1234',
      '345개 정도 남았어요',
      '주문번호가 20260723001이에요',
    ]) {
      test('"$text"', () {
        expect(risks(text), isNot(contains(ChatSafetyRisk.phoneNumber)));
      });
    }
  });

  group('6. 인증정보 탐지', () {
    for (final text in [
      '인증번호 좀 알려주세요',
      '인증 코드 왔어요?',
      '보안코드 알려줘',
      'OTP 번호 보내줘',
      '비밀번호가 뭐예요',
      '패스워드 알려줄게',
    ]) {
      test('"$text"', () {
        expect(risks(text), contains(ChatSafetyRisk.verificationCode));
      });
    }

    test('영문 단어 안의 otp는 오탐하지 않는다', () {
      expect(
        risks('I have a laptop here'),
        isNot(contains(ChatSafetyRisk.verificationCode)),
      );
    });
  });

  group('7. 금융·송금 탐지', () {
    for (final text in [
      '계좌번호 알려주세요',
      '입금해줘',
      '송금해줘',
      '선입금 부탁해요',
      '돈 보내줘',
      '돈 좀 빌려줄 수 있어?',
      '국민은행 12345678901로 보내주세요',
    ]) {
      test('"$text"', () {
        expect(risks(text), contains(ChatSafetyRisk.financialRequest));
      });
    }

    for (final text in ['오늘 돈까스 먹자', '가격이 12000원이야', '국민 체조 배웠어']) {
      test('오탐 없음: "$text"', () {
        expect(risks(text), isNot(contains(ChatSafetyRisk.financialRequest)));
      });
    }
  });

  group('8. 외부 연락처 탐지', () {
    for (final text in [
      '카톡 아이디 알려줘',
      '카카오톡으로 얘기해요',
      '오픈채팅방 링크 보낼게요',
      '인스타 아이디 뭐예요',
      '인스타그램 팔로우할게요',
      '텔레그램으로 옮길까요',
      'Telegram 계정 있어요?',
      '라인으로 연락줘',
      'LINE 쓰세요?',
    ]) {
      test('"$text"', () {
        expect(risks(text), contains(ChatSafetyRisk.externalContact));
      });
    }

    for (final text in [
      '온라인으로 만나요',
      '가이드라인 확인했어요',
      '라인업이 좋네요',
      '나중에 연락해요',
    ]) {
      test('오탐 없음: "$text"', () {
        expect(risks(text), isNot(contains(ChatSafetyRisk.externalContact)));
      });
    }
  });

  test('9. 같은 category가 여러 번 나와도 Set 하나로 정리된다', () {
    final result = detectChatSafetyRisks(
      '010-1234-5678 이고 01098765432 이에요. 카톡이랑 인스타도 있어요.',
    );
    expect(result.risks.length, 2);
    expect(result.risks, {
      ChatSafetyRisk.phoneNumber,
      ChatSafetyRisk.externalContact,
    });
  });

  test('여러 category가 동시에 잡힌다', () {
    final result = detectChatSafetyRisks(
      '계좌번호랑 인증번호 보내주시고 카톡으로 연락주세요. 010-1234-5678',
    );
    expect(result.risks, {
      ChatSafetyRisk.phoneNumber,
      ChatSafetyRisk.financialRequest,
      ChatSafetyRisk.verificationCode,
      ChatSafetyRisk.externalContact,
    });
  });

  test('10. 결과 객체는 원문을 담지 않는다', () {
    const secret = '제 계좌는 국민은행 12345678901이에요';
    final result = detectChatSafetyRisks(secret);

    // 공개 API는 risks/hasRisk뿐이며, 문자열 표현 어디에도 원문이 남지 않는다.
    expect(result.hasRisk, isTrue);
    expect(result.toString(), isNot(contains('12345678901')));
    expect(result.toString(), isNot(contains(secret)));
    // 결과는 불변이라 호출자가 뒤늦게 원문 기반 정보를 끼워 넣을 수 없다.
    expect(
      () => result.risks.add(ChatSafetyRisk.phoneNumber),
      throwsUnsupportedError,
    );
  });

  test('risk label은 중립적인 사용자 문구를 돌려준다', () {
    expect(chatSafetyRiskLabel(ChatSafetyRisk.phoneNumber), '전화번호 또는 연락처');
    expect(
      chatSafetyRiskLabel(ChatSafetyRisk.financialRequest),
      '계좌·송금 관련 내용',
    );
    expect(
      chatSafetyRiskLabel(ChatSafetyRisk.verificationCode),
      '인증번호 또는 비밀번호',
    );
    expect(chatSafetyRiskLabel(ChatSafetyRisk.externalContact), '외부 메신저 정보');
  });
}
