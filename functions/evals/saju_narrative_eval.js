'use strict';

/**
 * 사주·궁합 서사 품질 평가 harness — Phase 5-4 Stage A.
 *
 * 이 스크립트는 `npm test`에서 실행되지 않는다. 외부 API를 호출하므로
 * 반드시 명시적으로 실행한다:
 *
 *   npm run eval:saju-narrative -- --estimate          # 호출 없이 비용만 추정
 *   npm run eval:saju-narrative -- --probe             # 모델 접근 가능 여부만 확인
 *   npm run eval:saju-narrative -- --models=a,b        # 실제 평가 실행
 *
 * 원칙:
 * - production 사용자 데이터를 쓰지 않는다(입력은 합성 fixture)
 * - 생성 결과·prompt·응답 원문을 저장소에 쓰지 않는다(기본 출력은 /tmp)
 * - API key를 출력하거나 파일에 남기지 않는다
 * - 접근 불가한 후보를 다른 모델로 조용히 대체하지 않는다
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const OpenAI = require('openai');

const {
  PERSONAL_NARRATIVE_JSON_SCHEMA,
  COMPATIBILITY_NARRATIVE_JSON_SCHEMA,
  toPublicPersonalNarrative,
  toPublicCompatibilityNarrative,
  isValidPublicNarrative,
  collectPublicText,
} = require('../lib/saju/narrative_schema_v3');
const {
  personalNarrativePromptV3,
  compatibilityNarrativePromptV3,
  personalNarrativeUserPayload,
  compatibilityNarrativeUserPayload,
} = require('../lib/saju/narrative_prompts_v3');
const {
  validatePersonalGrounding,
  validateCompatibilityGrounding,
  catalogIds,
} = require('../lib/saju/narrative_grounding');
const {
  runHardChecks,
  runQualitySignals,
  textSimilarity,
  crossCaseRepetition,
} = require('../lib/saju/narrative_quality_checks');
const {
  generateStructuredNarrative,
  NarrativeGenerationError,
  FAILURE_KINDS,
  classifyError,
} = require('../lib/saju/narrative_client');
const {
  buildPersonalCases,
  buildCompatibilityCases,
} = require('./saju_narrative_cases');
const {
  RUBRIC_KEYS,
  RUBRIC_JSON_SCHEMA,
  PAIRWISE_JSON_SCHEMA,
  QUALITY_GATE,
  rubricJudgeSystemPrompt,
  pairwiseJudgeSystemPrompt,
  aggregateScores,
  evaluateQualityGate,
} = require('./saju_narrative_rubric');

/** 평가 후보. rolling alias(gpt-5.6)는 쓰지 않고 명시적 ID만 쓴다. */
const CANDIDATES = Object.freeze([
  { key: 'baseline', modelId: 'gpt-4o-mini', role: 'baseline' },
  { key: 'terra', modelId: 'gpt-5.6-terra', role: 'balanced' },
  { key: 'sol', modelId: 'gpt-5.6-sol', role: 'quality' },
]);

/**
 * 1M 토큰당 단가(USD). **문서 기준값이며 변동될 수 있다.**
 * 값이 null인 모델은 단가를 확인하지 못한 것이다 — 비용을 지어내지 않는다.
 */
const PRICING_USD_PER_MTOK = Object.freeze({
  'gpt-4o-mini': { input: 0.15, output: 0.6 },
  'gpt-5.6-terra': { input: 2.5, output: 15 },
  'gpt-5.6-sol': { input: 5, output: 30 },
});

const MAX_OUTPUT_TOKENS = 2000;
const APPROVAL_THRESHOLD_USD = 10;

/** judge 실패 중 재시도해도 되는 것. schema·contract 오류는 재시도하지 않는다. */
const RETRYABLE_JUDGE_KINDS = Object.freeze(
  new Set([FAILURE_KINDS.RATE_LIMIT, FAILURE_KINDS.TIMEOUT, FAILURE_KINDS.EMPTY]),
);
const MAX_JUDGE_ATTEMPTS = 3; // 최초 1회 + bounded retry 2회
/** judge 실패율이 이 값을 넘으면 비교 결과를 신뢰 가능하다고 보지 않는다. */
const MAX_JUDGE_FAILURE_RATE = 0.05;

/** judge 호출의 usage·비용·latency·실패 분류를 한 곳에 모은다. */
function createJudgeLedger(judgeModel) {
  return {
    judgeModel,
    calls: 0,
    attempts: 0,
    failures: {},
    inputTokens: 0,
    outputTokens: 0,
    latencyMs: [],
    record(usage, latency) {
      this.calls += 1;
      this.inputTokens += usage?.prompt_tokens || 0;
      this.outputTokens += usage?.completion_tokens || 0;
      this.latencyMs.push(latency);
    },
    recordFailure(kind) {
      this.failures[kind] = (this.failures[kind] || 0) + 1;
    },
    summary() {
      const pricing = PRICING_USD_PER_MTOK[this.judgeModel];
      const sorted = this.latencyMs.slice().sort((a, b) => a - b);
      const failed = Object.values(this.failures).reduce((s, v) => s + v, 0);
      const requested = this.calls + failed;
      return {
        judgeModel: this.judgeModel,
        succeeded: this.calls,
        failed,
        attempts: this.attempts,
        failureRate: requested === 0 ? 0 : failed / requested,
        failuresByKind: { ...this.failures },
        inputTokens: this.inputTokens,
        outputTokens: this.outputTokens,
        costUsd: pricing
          ? (this.inputTokens / 1e6) * pricing.input + (this.outputTokens / 1e6) * pricing.output
          : null,
        latencyMs: sorted.length
          ? { min: sorted[0], median: sorted[Math.floor(sorted.length / 2)], max: sorted[sorted.length - 1] }
          : null,
      };
    },
  };
}

/** 일시적 실패만 최대 2회 재시도한다. */
async function withBoundedRetry(ledger, fn) {
  let lastKind = FAILURE_KINDS.UNKNOWN;
  for (let attempt = 1; attempt <= MAX_JUDGE_ATTEMPTS; attempt += 1) {
    ledger.attempts += 1;
    const startedAt = Date.now();
    try {
      const result = await fn();
      ledger.record(result.usage, Date.now() - startedAt);
      return result.parsed;
    } catch (error) {
      lastKind = error instanceof NarrativeGenerationError ? error.kind : FAILURE_KINDS.UNKNOWN;
      if (!RETRYABLE_JUDGE_KINDS.has(lastKind)) break;
      if (attempt < MAX_JUDGE_ATTEMPTS) {
        await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
      }
    }
  }
  ledger.recordFailure(lastKind);
  return null;
}

function parseArgs(argv) {
  const args = { models: null, judge: null, estimate: false, probe: false, out: null, limit: null, pilot: false, baselineReport: null };
  for (const raw of argv.slice(2)) {
    if (raw === '--estimate') args.estimate = true;
    else if (raw === '--probe') args.probe = true;
    else if (raw === '--pilot') args.pilot = true;
    else if (raw.startsWith('--models=')) args.models = raw.slice(9).split(',').map((s) => s.trim()).filter(Boolean);
    else if (raw.startsWith('--judge=')) args.judge = raw.slice(8).trim();
    else if (raw.startsWith('--out=')) args.out = raw.slice(6).trim();
    // 이전 실행의 baseline aggregate를 재사용한다. baseline을 다시 생성하지
    // 않고도 "baseline 대비 개선폭" gate를 판정하기 위한 것이다.
    else if (raw.startsWith('--baseline-report=')) args.baselineReport = raw.slice(18).trim();
    else if (raw.startsWith('--limit=')) args.limit = Number.parseInt(raw.slice(8), 10);
    else throw new Error(`알 수 없는 인자: ${raw}`);
  }
  return args;
}

function selectedCandidates(args) {
  if (!args.models) return CANDIDATES.slice();
  return args.models.map((key) => {
    const found = CANDIDATES.find((c) => c.key === key || c.modelId === key);
    if (!found) throw new Error(`알 수 없는 후보: ${key}`);
    return found;
  });
}

/** 한국어+JSON 혼합 입력의 보수적 토큰 추정(문자 수 / 1.8). */
function estimateTokens(text) {
  return Math.ceil(text.length / 1.8);
}

function promptFor(testCase) {
  if (testCase.kind === 'personal') {
    return {
      systemPrompt: personalNarrativePromptV3(),
      userPayload: personalNarrativeUserPayload({
        evidence: testCase.evidence,
        catalog: testCase.catalog,
      }),
      jsonSchema: PERSONAL_NARRATIVE_JSON_SCHEMA,
    };
  }
  return {
    systemPrompt: compatibilityNarrativePromptV3(),
    userPayload: compatibilityNarrativeUserPayload({
      compatibilityEvidence: testCase.compatibilityEvidence,
      firstEvidence: testCase.firstEvidence,
      secondEvidence: testCase.secondEvidence,
      catalog: testCase.catalog,
    }),
    jsonSchema: COMPATIBILITY_NARRATIVE_JSON_SCHEMA,
  };
}

function estimateRun(cases, candidates) {
  let inputTokens = 0;
  for (const testCase of cases) {
    const { systemPrompt, userPayload } = promptFor(testCase);
    inputTokens += estimateTokens(systemPrompt) + estimateTokens(JSON.stringify(userPayload));
  }
  const callsPerModel = cases.length;
  const rows = candidates.map((candidate) => {
    const pricing = PRICING_USD_PER_MTOK[candidate.modelId];
    const outputTokens = callsPerModel * MAX_OUTPUT_TOKENS;
    const cost = pricing
      ? (inputTokens / 1e6) * pricing.input + (outputTokens / 1e6) * pricing.output
      : null;
    return {
      key: candidate.key,
      modelId: candidate.modelId,
      calls: callsPerModel,
      maxInputTokens: inputTokens,
      maxOutputTokens: outputTokens,
      maxCostUsd: cost,
    };
  });
  return { rows, callsTotal: callsPerModel * candidates.length };
}

/**
 * probe용 최소 strict schema. 본 평가 schema와 같은 계약(strict: true,
 * additionalProperties: false, 전 필드 required)을 쓰되 토큰만 아주 작게 잡는다.
 */
const PROBE_JSON_SCHEMA = Object.freeze({
  name: 'saju_narrative_probe',
  strict: true,
  schema: {
    type: 'object',
    properties: {
      ok: { type: 'boolean' },
      label: { type: 'string', enum: ['red', 'green'] },
      count: { type: 'integer' },
    },
    required: ['ok', 'label', 'count'],
    additionalProperties: false,
  },
});

/** strict Structured Outputs 왕복이 실제로 계약대로 도는지 확인한다. */
async function probeStructuredOutputs(client, modelId) {
  try {
    const result = await generateStructuredNarrative({
      client,
      modelId,
      jsonSchema: PROBE_JSON_SCHEMA,
      systemPrompt: 'Return the requested JSON object. No prose.',
      userPayload: { ok: true, label: 'green', count: 1 },
      maxOutputTokens: 800,
      temperature: 0,
    });
    const parsed = result.parsed;
    const conforms =
      parsed !== null &&
      typeof parsed === 'object' &&
      typeof parsed.ok === 'boolean' &&
      ['red', 'green'].includes(parsed.label) &&
      Number.isInteger(parsed.count) &&
      Object.keys(parsed).length === 3;
    return {
      structuredOutputs: conforms,
      structuredFailureKind: conforms ? null : 'schemaMismatch',
      usage: result.usage,
    };
  } catch (error) {
    const kind = error instanceof NarrativeGenerationError
      ? error.kind
      : classifyError(error);
    return { structuredOutputs: false, structuredFailureKind: kind, usage: null };
  }
}

async function probeModel(client, modelId) {
  try {
    await client.chat.completions.create({
      model: modelId,
      messages: [{ role: 'user', content: 'ping' }],
      ...(modelId.startsWith('gpt-5')
        ? { max_completion_tokens: 16, reasoning_effort: 'low' }
        : { max_tokens: 16 }),
    });
  } catch (error) {
    const kind = error instanceof NarrativeGenerationError
      ? error.kind
      : classifyError(error);
    return {
      modelId,
      available: false,
      failureKind: kind,
      structuredOutputs: null,
      structuredFailureKind: null,
    };
  }
  const structured = await probeStructuredOutputs(client, modelId);
  return { modelId, available: true, failureKind: null, ...structured };
}

async function generateForCase({ client, modelId, testCase }) {
  const { systemPrompt, userPayload, jsonSchema } = promptFor(testCase);
  const startedAt = Date.now();
  const result = await generateStructuredNarrative({
    client,
    modelId,
    jsonSchema,
    systemPrompt,
    userPayload,
    maxOutputTokens: MAX_OUTPUT_TOKENS,
  });
  const latencyMs = Date.now() - startedAt;

  const grounding = testCase.kind === 'personal'
    ? validatePersonalGrounding(result.parsed, testCase.catalog)
    : validateCompatibilityGrounding(result.parsed, testCase.catalog);

  const publicNarrative = testCase.kind === 'personal'
    ? toPublicPersonalNarrative(result.parsed)
    : toPublicCompatibilityNarrative(result.parsed);

  const schemaValid = isValidPublicNarrative(publicNarrative, { kind: testCase.kind });
  const hard = runHardChecks(publicNarrative, {
    kind: testCase.kind,
    hourPillarKnown: testCase.hourPillarKnown,
    catalogIds: catalogIds(testCase.catalog),
  });
  const quality = runQualitySignals(publicNarrative, { kind: testCase.kind });

  return {
    caseId: testCase.id,
    kind: testCase.kind,
    axes: testCase.axes,
    latencyMs,
    usage: result.usage,
    resolvedModel: result.modelId,
    schemaValid,
    grounding,
    hard,
    quality,
    narrative: publicNarrative,
  };
}

async function judgeRubric({ client, judgeModel, testCase, narrative, ledger }) {
  return withBoundedRetry(ledger, () =>
    generateStructuredNarrative({
      client,
      modelId: judgeModel,
      jsonSchema: RUBRIC_JSON_SCHEMA,
      systemPrompt: rubricJudgeSystemPrompt(),
      userPayload: { 근거목록: testCase.catalog, 결과물: narrative },
      // gpt-5 계열은 reasoning 토큰이 max_completion_tokens에 함께 잡힌다.
      // 400은 truncation을 유발할 수 있어 여유를 둔다.
      maxOutputTokens: 2000,
      temperature: 0,
    }),
  );
}

async function judgePairwise({ client, judgeModel, testCase, first, second, ledger }) {
  return withBoundedRetry(ledger, () =>
    generateStructuredNarrative({
      client,
      modelId: judgeModel,
      jsonSchema: PAIRWISE_JSON_SCHEMA,
      systemPrompt: pairwiseJudgeSystemPrompt(),
      userPayload: { 근거목록: testCase.catalog, A: first, B: second },
      maxOutputTokens: 2000,
      temperature: 0,
    }),
  );
}

/** 같은 kind 안에서 결과가 서로 얼마나 비슷한지 → generic 중복 비율. */
function genericDuplicateRatio(results) {
  const texts = results.map((r) => collectPublicText(r.narrative).join(' '));
  if (texts.length < 2) return 0;
  const duplicated = new Set();
  for (let i = 0; i < texts.length; i += 1) {
    for (let j = i + 1; j < texts.length; j += 1) {
      if (textSimilarity(texts[i], texts[j]) >= QUALITY_GATE.duplicateSimilarityThreshold) {
        duplicated.add(i);
        duplicated.add(j);
      }
    }
  }
  return duplicated.size / texts.length;
}

function summarizeCandidate(results) {
  const hardViolations = results.reduce((sum, r) => sum + (r.hard?.violations.length || 0), 0);
  const privacyViolations = results.reduce(
    (sum, r) =>
      sum +
      (r.hard?.violations || []).filter((v) =>
        ['rawBirthDate', 'rawBirthTime', 'identifierLike', 'fingerprintLike'].includes(v.code),
      ).length,
    0,
  );
  const fatalismViolations = results.reduce(
    (sum, r) =>
      sum +
      (r.hard?.violations || []).filter((v) =>
        ['fatalism', 'absoluteVerdict', 'harmonyClashVerdict'].includes(v.code),
      ).length,
    0,
  );
  const groundingViolations = results.reduce(
    (sum, r) => sum + (r.grounding?.violations.length || 0),
    0,
  );
  const schemaFailures = results.filter((r) => !r.schemaValid).length;
  const latencies = results.map((r) => r.latencyMs).sort((a, b) => a - b);
  return {
    generated: results.length,
    hardViolations,
    privacyViolations,
    fatalismViolations,
    groundingViolations,
    schemaFailures,
    latencyMs: latencies.length
      ? { min: latencies[0], median: latencies[Math.floor(latencies.length / 2)], max: latencies[latencies.length - 1] }
      : null,
    tokens: results.reduce(
      (acc, r) => ({
        input: acc.input + (r.usage?.prompt_tokens || 0),
        output: acc.output + (r.usage?.completion_tokens || 0),
      }),
      { input: 0, output: 0 },
    ),
  };
}

function outputDir(args) {
  if (args.out) return args.out;
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(os.tmpdir(), `cvr-saju-narrative-eval-${stamp}`);
}

function writeJson(dir, name, data) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, name), JSON.stringify(data, null, 2), 'utf8');
}

/** 사람이 읽을 blind sample. 후보 이름을 파일 안에 노출하지 않는다. */
function writeBlindSamples(dir, byCandidate, cases) {
  const personal = cases.filter((c) => c.kind === 'personal').slice(0, 5);
  const compat = cases.filter((c) => c.kind === 'compatibility').slice(0, 5);
  const picked = [...personal, ...compat];
  const labelMap = {};
  const lines = ['# Blind sample (모델 이름 비공개)', ''];

  picked.forEach((testCase, caseIndex) => {
    const entries = Object.entries(byCandidate)
      .map(([key, results]) => ({ key, result: results.find((r) => r.caseId === testCase.id) }))
      .filter((e) => e.result);
    // 매 case마다 순서를 섞는다.
    for (let i = entries.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [entries[i], entries[j]] = [entries[j], entries[i]];
    }
    lines.push(`## Case ${caseIndex + 1} — ${testCase.id} (${testCase.axes.join(', ')})`, '');
    entries.forEach((entry, index) => {
      const label = `후보 ${String.fromCharCode(65 + index)}`;
      labelMap[`${testCase.id}/${label}`] = entry.key;
      lines.push(`### ${label}`, '');
      for (const part of collectPublicText(entry.result.narrative)) lines.push(`- ${part}`);
      lines.push('');
    });
  });

  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'blind_samples.md'), lines.join('\n'), 'utf8');
  writeJson(dir, 'blind_label_map.json', labelMap);
}

async function main() {
  const args = parseArgs(process.argv);
  const personalCases = buildPersonalCases();
  const compatCases = buildCompatibilityCases();
  const cases = [...personalCases, ...compatCases];
  // pilot은 개인·궁합을 균형 있게 뽑는다. --limit은 앞에서 자르므로 개인만 뽑힌다.
  const pilotCases = [...personalCases.slice(0, 6), ...compatCases.slice(0, 6)];
  const limited = args.pilot ? pilotCases : args.limit ? cases.slice(0, args.limit) : cases;
  const candidates = selectedCandidates(args);

  const estimate = estimateRun(limited, candidates);
  console.log('=== 평가 계획 ===');
  console.log(`case 수: ${limited.length} (개인 ${limited.filter((c) => c.kind === 'personal').length} / 궁합 ${limited.filter((c) => c.kind === 'compatibility').length})`);
  for (const row of estimate.rows) {
    const cost = row.maxCostUsd === null
      ? '단가 미확인 — 실제 요금은 OpenAI 대시보드에서 확인 필요'
      : `최대 약 $${row.maxCostUsd.toFixed(2)}`;
    console.log(
      `- ${row.key} (${row.modelId}): 호출 ${row.calls}회, 입력 최대 ~${row.maxInputTokens} tok, 출력 최대 ${row.maxOutputTokens} tok, ${cost}`,
    );
  }
  const knownCost = estimate.rows.reduce((sum, r) => sum + (r.maxCostUsd || 0), 0);
  const hasUnknownPricing = estimate.rows.some((r) => r.maxCostUsd === null);
  console.log(
    `합계 호출 ${estimate.callsTotal}회 / 단가 확인된 부분 최대 약 $${knownCost.toFixed(2)}` +
      (hasUnknownPricing ? ' + 단가 미확인 모델 있음' : ''),
  );
  if (knownCost > APPROVAL_THRESHOLD_USD || hasUnknownPricing) {
    console.log(
      `※ 예상 비용이 $${APPROVAL_THRESHOLD_USD}를 넘거나 단가를 확인하지 못했습니다. 실행 전 승인이 필요합니다.`,
    );
  }

  if (args.estimate) return;

  if (!process.env.OPENAI_API_KEY) {
    throw new Error('OPENAI_API_KEY 환경변수가 필요합니다. (키를 파일에 저장하지 마세요)');
  }
  const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

  console.log('\n=== 모델 접근 확인 ===');
  const probes = [];
  for (const candidate of candidates) {
    const probe = await probeModel(client, candidate.modelId);
    probes.push({ ...probe, key: candidate.key });
    if (!probe.available) {
      console.log(`- ${candidate.key} (${candidate.modelId}): 접근 불가 (${probe.failureKind})`);
    } else {
      console.log(
        `- ${candidate.key} (${candidate.modelId}): 접근 가능 / strict Structured Outputs ` +
          (probe.structuredOutputs ? '정상' : `실패 (${probe.structuredFailureKind})`),
      );
    }
  }
  // strict Structured Outputs가 안 도는 후보는 평가 계약을 만족하지 못하므로 제외한다.
  const usable = candidates.filter((c) => {
    const probe = probes.find((p) => p.key === c.key);
    return probe?.available && probe?.structuredOutputs;
  });
  if (usable.length === 0) throw new Error('사용 가능한 후보 모델이 없습니다.');

  if (args.probe) return;

  const dir = outputDir(args);
  const byCandidate = {};
  const failures = {};

  for (const candidate of usable) {
    console.log(`\n=== 생성: ${candidate.key} (${candidate.modelId}) ===`);
    const results = [];
    const candidateFailures = [];
    for (const testCase of limited) {
      try {
        const result = await generateForCase({ client, modelId: candidate.modelId, testCase });
        results.push(result);
        process.stdout.write('.');
      } catch (error) {
        const kind = error instanceof NarrativeGenerationError ? error.kind : FAILURE_KINDS.UNKNOWN;
        candidateFailures.push({ caseId: testCase.id, kind });
        process.stdout.write('x');
      }
    }
    process.stdout.write('\n');
    byCandidate[candidate.key] = results;
    failures[candidate.key] = candidateFailures;
  }

  const judgeModel = args.judge;
  const ledger = createJudgeLedger(judgeModel);
  const report = { generatedAt: new Date().toISOString(), judgeModel: judgeModel || null, candidates: {} };

  for (const candidate of usable) {
    const results = byCandidate[candidate.key];
    const summary = summarizeCandidate(results);
    let aggregate = null;
    const perCaseScores = [];
    if (judgeModel) {
      console.log(`\n=== 채점(model judge): ${candidate.key} ===`);
      const scores = [];
      for (const result of results) {
        const testCase = limited.find((c) => c.id === result.caseId);
        const parsed = await judgeRubric({
          client, judgeModel, testCase, narrative: result.narrative, ledger,
        });
        if (parsed) {
          scores.push(parsed);
          perCaseScores.push({ caseId: result.caseId, kind: result.kind, scores: parsed });
          process.stdout.write('.');
        } else {
          process.stdout.write('x');
        }
      }
      process.stdout.write('\n');
      aggregate = aggregateScores(scores);
    }
    report.candidates[candidate.key] = {
      modelId: candidate.modelId,
      role: candidate.role,
      summary,
      failures: failures[candidate.key],
      genericDuplicateRatio: genericDuplicateRatio(results),
      crossCaseRepetition: crossCaseRepetition(
        results.map((r) => ({ caseId: r.caseId, narrative: r.narrative })),
      ).repeatedSentenceRatio,
      // case별 점수를 남긴다. 집계만 남기면 어느 case가 왜 낮은지 사후 분석이 안 된다.
      perCaseScores,
      aggregate,
    };
  }

  // baseline은 이번 실행에 없을 수 있다(재평가 대상에서 제외). 그럴 때는
  // 지정된 이전 리포트의 baseline aggregate를 비교 기준으로 쓴다.
  let baseline = report.candidates.baseline || null;
  if (!baseline && args.baselineReport) {
    const previous = JSON.parse(fs.readFileSync(args.baselineReport, 'utf8'));
    baseline = previous?.candidates?.baseline || null;
    report.baselineSource = {
      path: args.baselineReport,
      generatedAt: previous?.generatedAt || null,
      modelId: baseline?.modelId || null,
    };
    if (!baseline) throw new Error('지정한 리포트에 baseline aggregate가 없습니다.');
  }
  for (const candidate of usable) {
    const entry = report.candidates[candidate.key];
    if (!entry.aggregate) continue;
    entry.gate = evaluateQualityGate({
      hardViolations: entry.summary.hardViolations + entry.summary.groundingViolations,
      privacyViolations: entry.summary.privacyViolations,
      schemaFailures: entry.summary.schemaFailures,
      fatalismViolations: entry.summary.fatalismViolations,
      aggregate: entry.aggregate,
      baselineAggregate: candidate.role === 'baseline' ? null : baseline?.aggregate || null,
      genericDuplicateRatio: entry.genericDuplicateRatio,
    });
  }

  if (judgeModel && usable.length >= 2) {
    console.log('\n=== blind pairwise (순서 뒤집어 2회) ===');
    const pairwise = [];
    const [a, b] = usable.filter((c) => c.role !== 'baseline').slice(0, 2);
    if (a && b) {
      for (const testCase of limited) {
        const first = byCandidate[a.key].find((r) => r.caseId === testCase.id);
        const second = byCandidate[b.key].find((r) => r.caseId === testCase.id);
        if (!first || !second) continue;
        const forward = await judgePairwise({ client, judgeModel, testCase, first: first.narrative, second: second.narrative, ledger });
        const reverse = await judgePairwise({ client, judgeModel, testCase, first: second.narrative, second: first.narrative, ledger });
        // 양방향이 모두 성공한 case만 집계한다. 한쪽만 있으면 순서 편향을 못 뺀다.
        if (forward && reverse) {
          pairwise.push({ caseId: testCase.id, forward, reverse });
          process.stdout.write('.');
        } else {
          process.stdout.write('x');
        }
      }
      process.stdout.write('\n');
      report.pairwise = {
        candidates: [a.key, b.key],
        note: 'model judge 결과이며 사람 평가가 아니다.',
        attemptedCases: limited.length,
        usableCases: pairwise.length,
        results: pairwise,
      };
    }
  }

  const judgeSummary = judgeModel ? ledger.summary() : null;
  report.judge = judgeSummary;
  if (judgeSummary) {
    report.judgeTrustworthy = judgeSummary.failureRate <= MAX_JUDGE_FAILURE_RATE;
  }

  writeJson(dir, 'report.json', report);
  writeJson(dir, 'raw_results.json', byCandidate);
  writeBlindSamples(dir, byCandidate, limited);

  console.log('\n=== 요약 ===');
  for (const [key, entry] of Object.entries(report.candidates)) {
    console.log(`- ${key} (${entry.modelId})`);
    console.log(`  schema 실패 ${entry.summary.schemaFailures} / hard 위반 ${entry.summary.hardViolations} / grounding 위반 ${entry.summary.groundingViolations} / privacy 위반 ${entry.summary.privacyViolations}`);
    console.log(`  generic 중복 비율 ${(entry.genericDuplicateRatio * 100).toFixed(1)}%`);
    if (entry.aggregate) {
      console.log(`  rubric 평균 ${entry.aggregate.overall?.toFixed(2)} (model judge 참고치)`);
      console.log(`  항목별: ${RUBRIC_KEYS.map((k) => `${k}=${entry.aggregate.perCriterion[k]?.toFixed(2)}`).join(', ')}`);
    }
    console.log(`  case 간 문장 반복 비율 ${(entry.crossCaseRepetition * 100).toFixed(1)}%`);
    if (entry.gate) {
      console.log(`  품질 gate: ${entry.gate.passed ? 'PASS' : 'FAIL'}${entry.gate.passed ? '' : ` (${entry.gate.failures.map((f) => f.code).join(', ')})`}`);
    }
  }
  if (report.judge) {
    const j = report.judge;
    console.log(`\n=== judge (${j.judgeModel}) ===`);
    console.log(`  성공 ${j.succeeded} / 실패 ${j.failed} (실패율 ${(j.failureRate * 100).toFixed(1)}%), 시도 ${j.attempts}`);
    console.log(`  실패 분류: ${Object.keys(j.failuresByKind).length ? JSON.stringify(j.failuresByKind) : '없음'}`);
    console.log(`  토큰 in/out ${j.inputTokens}/${j.outputTokens}, 비용 ${j.costUsd === null ? '단가 미확인' : '$' + j.costUsd.toFixed(4)}`);
    console.log(`  latency ${JSON.stringify(j.latencyMs)}`);
    console.log(`  신뢰 판정: ${report.judgeTrustworthy ? '가능' : `불가 (실패율 > ${MAX_JUDGE_FAILURE_RATE * 100}%)`}`);
  }
  console.log(`\n결과 저장 위치: ${dir}`);
  console.log('※ 이 디렉터리는 저장소 밖이며 커밋 대상이 아니다.');
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`[eval 실패] ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  CANDIDATES,
  RETRYABLE_JUDGE_KINDS,
  MAX_JUDGE_ATTEMPTS,
  MAX_JUDGE_FAILURE_RATE,
  createJudgeLedger,
  withBoundedRetry,
  PRICING_USD_PER_MTOK,
  MAX_OUTPUT_TOKENS,
  APPROVAL_THRESHOLD_USD,
  parseArgs,
  selectedCandidates,
  estimateTokens,
  promptFor,
  estimateRun,
  genericDuplicateRatio,
  summarizeCandidate,
};
