'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { tokensForRecipient } = require('../lib/push_tokens');

test('sender와 겹치는 token은 제외하고 receiver 전용 token만 남긴다', () => {
  const result = tokensForRecipient({
    recipientTokens: ['shared', 'receiverOnly'],
    senderTokens: ['shared', 'senderOnly'],
  });
  assert.deepEqual(result, ['receiverOnly']);
});

test('중복 token을 제거한다', () => {
  const result = tokensForRecipient({
    recipientTokens: ['a', 'a', 'b', 'b', 'c'],
    senderTokens: [],
  });
  assert.deepEqual(result, ['a', 'b', 'c']);
});

test('빈/비문자 token을 제거한다', () => {
  const result = tokensForRecipient({
    recipientTokens: ['a', '', null, undefined, 0, 'b'],
    senderTokens: [''],
  });
  assert.deepEqual(result, ['a', 'b']);
});

test('sender token 전부가 겹치면 receiver 전송 대상이 비어 자기 알림이 없다', () => {
  const result = tokensForRecipient({
    recipientTokens: ['dev1', 'dev1'],
    senderTokens: ['dev1'],
  });
  assert.deepEqual(result, []);
});

test('receiver의 다른 기기 token은 유지된다', () => {
  const result = tokensForRecipient({
    recipientTokens: ['phoneA', 'tabletB', 'sharedDevice'],
    senderTokens: ['sharedDevice'],
  });
  assert.deepEqual(result, ['phoneA', 'tabletB']);
});

test('입력이 배열이 아니어도 안전하게 빈 배열을 반환한다', () => {
  assert.deepEqual(
    tokensForRecipient({ recipientTokens: null, senderTokens: null }),
    [],
  );
  assert.deepEqual(
    tokensForRecipient({ recipientTokens: undefined, senderTokens: ['x'] }),
    [],
  );
});

test('onMessageCreated가 sender token을 excludeTokens로 넘기고 raw token을 로그하지 않는다', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(
    path.join(__dirname, '..', 'index.js'),
    'utf8',
  );
  const start = src.indexOf('exports.onMessageCreated = onDocumentCreated(');
  const end = src.indexOf('\nexports.', start + 1);
  const fnSrc = src.slice(start, end === -1 ? src.length : end);
  assert.ok(fnSrc.includes('const senderTokens = await userTokens(senderId);'));
  assert.ok(fnSrc.includes('excludeTokens: senderTokens,'));
  // raw token 값을 console에 남기지 않는다.
  assert.ok(!/console\.\w+\([^)]*[tT]oken/.test(fnSrc));
});
