/// 채팅 안전 가이드 — 전송 전 클라이언트 사전 안내용 위험 신호 탐지.
///
/// 이 모듈은 **서버 보안 기능이 아니다.** 사용자가 민감한 내용을 무심코 보내기
/// 전에 한 번 더 확인시키는 보조 장치이며, 탐지됐다고 해서 전송을 영구
/// 차단하지 않는다. 실제 신고/차단은 기존 SafetyService 흐름을 그대로 쓴다.
///
/// 개인정보 원칙:
/// - 입력 원문을 [ChatSafetyDetection]에 저장하지 않는다.
/// - 탐지 결과를 로그로 남기거나 Firestore/서버로 보내지 않는다.
library;

/// 전송 전 확인이 필요한 위험 신호 종류.
enum ChatSafetyRisk {
  /// 휴대전화 번호로 보이는 숫자 조합.
  phoneNumber,

  /// 계좌·송금·선입금 등 금전 요청으로 보이는 표현.
  financialRequest,

  /// 인증번호·비밀번호 등 절대 공유하면 안 되는 정보.
  verificationCode,

  /// 카카오톡·인스타 등 외부 메신저로 옮기려는 표현.
  externalContact,
}

/// 탐지 결과. **원문 텍스트는 담지 않는다.**
class ChatSafetyDetection {
  final Set<ChatSafetyRisk> risks;

  const ChatSafetyDetection(this.risks);

  static const ChatSafetyDetection none = ChatSafetyDetection(
    <ChatSafetyRisk>{},
  );

  bool get hasRisk => risks.isNotEmpty;
}

// ── 탐지 패턴 ──────────────────────────────────────────────────────────────
//
// 오탐(false positive)을 줄이는 쪽으로 보수적으로 잡는다. 날짜/시간/가격 같은
// 일상 대화가 경고로 이어지면 사용자가 경고 자체를 무시하게 되기 때문이다.

/// 한국 휴대전화 번호. 앞뒤가 다른 숫자로 이어지면(더 긴 숫자열의 일부이면)
/// 매칭하지 않아 날짜·주문번호 등의 오탐을 막는다.
final RegExp _phonePattern = RegExp(
  r'(?<![0-9])01[016789][-. ]?[0-9]{3,4}[-. ]?[0-9]{4}(?![0-9])',
);

/// 금전 요청으로 읽히는 명확한 표현만 넣는다. '돈'처럼 단독으로는 일상어인
/// 단어는 제외한다('돈까스' 등).
final RegExp _financialKeywordPattern = RegExp(
  r'계좌|입금|송금|이체|대리\s*결제|더치페이\s*송금',
);

/// "돈 보내줘 / 돈 좀 부쳐줘"처럼 동사가 함께 있을 때만 금전 요청으로 본다.
final RegExp _moneyTransferPattern = RegExp(
  r'돈\s*(을|좀|만)?\s*(보내|부쳐|이체|송금|빌려)',
);

/// 은행명이 등장하고 8자리 이상 숫자가 함께 있으면 계좌 공유로 본다.
final RegExp _bankNamePattern = RegExp(
  r'은행|카카오뱅크|케이뱅크|토스뱅크|농협|신한|국민|하나|우리|기업|새마을|우체국',
);
final RegExp _longDigitsPattern = RegExp(r'[0-9][0-9-]{7,}');

/// 인증/비밀 정보. 숫자가 함께 없어도 경고 대상이다.
/// OTP는 영문 단어 안에 우연히 포함되지 않도록 앞뒤 영문자를 배제한다.
final RegExp _verificationPattern = RegExp(
  r'인증\s*번호|인증\s*코드|승인\s*번호|보안\s*코드|비밀\s*번호|패스워드|(?<![A-Za-z])OTP(?![A-Za-z])',
  caseSensitive: false,
);

/// 외부 메신저/SNS로 옮기려는 표현. '연락해' 같은 일반 표현은 넣지 않는다.
/// '라인'은 '온라인·가이드라인·라인업'과 겹치므로 앞 글자와 뒤 글자를 확인한다.
final RegExp _externalContactPattern = RegExp(
  r'카카오톡|카톡|오픈\s*채팅|오픈\s*카톡|인스타|텔레그램|telegram|왓츠앱|whatsapp|디스코드|discord|스냅챗|snapchat|(?<![가-힣A-Za-z])라인(?!업)|(?<![A-Za-z])LINE(?![A-Za-z])',
  caseSensitive: false,
);

/// 메시지 텍스트에서 전송 전 확인이 필요한 위험 신호를 찾는다(순수 함수).
///
/// 원문은 어디에도 저장·기록하지 않고, 결과 [Set]만 반환한다. 같은 종류가 여러
/// 번 나와도 [Set]이므로 하나로 정리된다.
ChatSafetyDetection detectChatSafetyRisks(String text) {
  if (text.trim().isEmpty) return ChatSafetyDetection.none;

  final risks = <ChatSafetyRisk>{};

  if (_phonePattern.hasMatch(text)) {
    risks.add(ChatSafetyRisk.phoneNumber);
  }
  if (_financialKeywordPattern.hasMatch(text) ||
      _moneyTransferPattern.hasMatch(text) ||
      (_bankNamePattern.hasMatch(text) && _longDigitsPattern.hasMatch(text))) {
    risks.add(ChatSafetyRisk.financialRequest);
  }
  if (_verificationPattern.hasMatch(text)) {
    risks.add(ChatSafetyRisk.verificationCode);
  }
  if (_externalContactPattern.hasMatch(text)) {
    risks.add(ChatSafetyRisk.externalContact);
  }

  return ChatSafetyDetection(Set.unmodifiable(risks));
}

/// 경고 시트에 보여줄 사용자 친화적 라벨. 사용자를 비난하거나 사기라고
/// 단정하지 않는 중립적인 표현만 쓴다.
String chatSafetyRiskLabel(ChatSafetyRisk risk) {
  switch (risk) {
    case ChatSafetyRisk.phoneNumber:
      return '전화번호 또는 연락처';
    case ChatSafetyRisk.financialRequest:
      return '계좌·송금 관련 내용';
    case ChatSafetyRisk.verificationCode:
      return '인증번호 또는 비밀번호';
    case ChatSafetyRisk.externalContact:
      return '외부 메신저 정보';
  }
}
