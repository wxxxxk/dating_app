'use strict';

// ============================================================================
// Push token helper — 자기 메시지 알림 방지 (Phase 2-1)
//
// 같은 물리 기기에서 계정 A→B로 전환하면, A의 FCM token이 B(수신자)의
// fcmTokens 배열에도 남아 있을 수 있다. 이때 수신자에게 push를 그대로 보내면
// A의 현재 기기로 "자기 메시지" 알림이 되돌아온다.
//
// tokensForRecipient는 수신자 token에서 발신자 token과 겹치는 것을 제외해,
// 발신자의 현재 기기로 알림이 가지 않도록 한다. 수신자의 다른 기기 token은
// 그대로 유지된다. raw token은 로그하지 않는다(호출부 책임 포함).
// ============================================================================

/**
 * 수신자에게 실제로 push를 보낼 token 목록을 계산한다.
 * - 빈/비문자 token 제거
 * - 중복 제거
 * - 발신자와 겹치는 token 제외
 *
 * @param {{recipientTokens: string[], senderTokens: string[]}} params
 * @returns {string[]}
 */
function tokensForRecipient({ recipientTokens, senderTokens }) {
  const excluded = new Set(
    (Array.isArray(senderTokens) ? senderTokens : []).filter(
      (token) => typeof token === 'string' && token,
    ),
  );
  const seen = new Set();
  const result = [];
  for (const token of Array.isArray(recipientTokens) ? recipientTokens : []) {
    if (typeof token !== 'string' || !token) continue;
    if (excluded.has(token) || seen.has(token)) continue;
    seen.add(token);
    result.push(token);
  }
  return result;
}

module.exports = { tokensForRecipient };
