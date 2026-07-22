'use strict';

/**
 * 서사 생성 OpenAI 호출 — Phase 5-4.
 *
 * v2까지는 `json_object` 모드로 받아 sanitize로 보정했다. v3는 strict
 * Structured Outputs를 쓴다: 형식이 맞지 않는 응답은 애초에 오지 않고,
 * 대신 refusal·truncation 같은 **명시적 실패 신호**를 처리해야 한다.
 *
 * 이 모듈은 평가 harness와 production callable이 공유한다. 여기서 조용히
 * 다른 모델로 fallback하지 않는다 — 실패는 분류해서 그대로 올려보낸다.
 *
 * 새 dependency를 추가하지 않는다. 기존 `openai` SDK의 Chat Completions만 쓴다.
 */

/** 모델 계열별 파라미터 차이. rolling alias(gpt-5.6)는 쓰지 않는다. */
const MODEL_FAMILIES = Object.freeze({
  GPT_4O: 'gpt-4o',
  GPT_5: 'gpt-5',
});

/** 실패 분류. 로그·평가 리포트가 같은 값을 본다. */
const FAILURE_KINDS = Object.freeze({
  REFUSAL: 'refusal',
  TRUNCATED: 'truncated',
  EMPTY: 'empty',
  INVALID_JSON: 'invalidJson',
  ACCESS_DENIED: 'accessDenied',
  RATE_LIMIT: 'rateLimit',
  TIMEOUT: 'timeout',
  UNSUPPORTED_PARAMETER: 'unsupportedParameter',
  UNKNOWN: 'unknown',
});

class NarrativeGenerationError extends Error {
  constructor(kind, message, { finishReason, cause } = {}) {
    super(message);
    this.name = 'NarrativeGenerationError';
    this.kind = kind;
    this.finishReason = finishReason || null;
    // 원인 오류는 분류·디버깅용으로만 들고 있는다. 로그나 사용자 응답에 그대로 내보내지 않는다.
    if (cause) this.cause = cause;
  }
}

/** 모델 ID → 계열. 알 수 없는 ID는 호출 전에 막는다. */
function modelFamilyOf(modelId) {
  if (typeof modelId !== 'string' || !modelId.trim()) {
    throw new NarrativeGenerationError(
      FAILURE_KINDS.UNKNOWN,
      'model id가 비어 있습니다.',
    );
  }
  if (modelId.startsWith('gpt-4o')) return MODEL_FAMILIES.GPT_4O;
  if (modelId.startsWith('gpt-5')) return MODEL_FAMILIES.GPT_5;
  throw new NarrativeGenerationError(
    FAILURE_KINDS.UNKNOWN,
    `지원하지 않는 model 계열입니다: ${modelId}`,
  );
}

/**
 * 계열별로 **지원되는 파라미터만** 만든다.
 *
 * - gpt-4o 계열: temperature + max_tokens
 * - gpt-5 계열: reasoning_effort(low) + max_completion_tokens, temperature 없음
 *   (과도한 추론을 쓰지 않는다. 길이는 schema와 프롬프트로 통제한다.)
 */
function samplingParamsFor(modelId, { maxOutputTokens, reasoningEffort = 'low', temperature = 0.8 }) {
  const family = modelFamilyOf(modelId);
  if (family === MODEL_FAMILIES.GPT_4O) {
    return { temperature, max_tokens: maxOutputTokens };
  }
  return { reasoning_effort: reasoningEffort, max_completion_tokens: maxOutputTokens };
}

/** OpenAI SDK 예외를 실패 분류로 옮긴다. 원문 메시지는 그대로 남기지 않는다. */
function classifyError(error) {
  const status = error?.status;
  const code = error?.code || error?.error?.code || '';
  const message = String(error?.message || '');
  if (status === 401 || status === 403 || code === 'model_not_found' || status === 404) {
    return FAILURE_KINDS.ACCESS_DENIED;
  }
  if (status === 429) return FAILURE_KINDS.RATE_LIMIT;
  if (code === 'unsupported_parameter' || code === 'unsupported_value' || /Unsupported parameter|Unrecognized request argument/i.test(message)) {
    return FAILURE_KINDS.UNSUPPORTED_PARAMETER;
  }
  if (error?.name === 'APIConnectionTimeoutError' || /timeout/i.test(message)) {
    return FAILURE_KINDS.TIMEOUT;
  }
  return FAILURE_KINDS.UNKNOWN;
}

/**
 * strict Structured Outputs로 서사 JSON을 받아온다.
 *
 * @returns {{ parsed: object, modelId: string, usage: object|null, systemFingerprint: string|null }}
 * @throws {NarrativeGenerationError}
 */
async function generateStructuredNarrative({
  client,
  modelId,
  jsonSchema,
  systemPrompt,
  userPayload,
  maxOutputTokens = 2000,
  reasoningEffort = 'low',
  temperature = 0.8,
}) {
  let completion;
  try {
    completion = await client.chat.completions.create({
      model: modelId,
      response_format: { type: 'json_schema', json_schema: jsonSchema },
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: JSON.stringify(userPayload) },
      ],
      ...samplingParamsFor(modelId, { maxOutputTokens, reasoningEffort, temperature }),
    });
  } catch (error) {
    if (error instanceof NarrativeGenerationError) throw error;
    throw new NarrativeGenerationError(classifyError(error), '모델 호출에 실패했습니다.', {
      cause: error,
    });
  }

  const choice = completion.choices?.[0];
  const finishReason = choice?.finish_reason || null;

  if (choice?.message?.refusal) {
    throw new NarrativeGenerationError(FAILURE_KINDS.REFUSAL, '모델이 생성을 거부했습니다.', {
      finishReason,
    });
  }
  if (finishReason === 'length') {
    throw new NarrativeGenerationError(FAILURE_KINDS.TRUNCATED, '응답이 잘렸습니다.', {
      finishReason,
    });
  }
  const raw = choice?.message?.content;
  if (!raw || !raw.trim()) {
    throw new NarrativeGenerationError(FAILURE_KINDS.EMPTY, '응답이 비어 있습니다.', {
      finishReason,
    });
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // strict schema에서는 사실상 오지 않는 경로다. 오면 계약 위반으로 본다.
    throw new NarrativeGenerationError(FAILURE_KINDS.INVALID_JSON, '응답을 해석하지 못했습니다.', {
      finishReason,
    });
  }

  return {
    parsed,
    modelId: completion.model || modelId,
    usage: completion.usage || null,
    systemFingerprint: completion.system_fingerprint || null,
  };
}

module.exports = {
  MODEL_FAMILIES,
  FAILURE_KINDS,
  NarrativeGenerationError,
  modelFamilyOf,
  samplingParamsFor,
  classifyError,
  generateStructuredNarrative,
};
