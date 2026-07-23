import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/share/share_image_service.dart';
import '../../shared/widgets/app_components.dart';
import 'widgets/saju_precision_notice.dart';
import 'widgets/share_card.dart';

/// 궁합 화면 — 매칭 목록의 "궁합 보기" 진입점.
///
/// 내 프로필은 [currentUid]로 직접 조회한다(호출부가 이미 들고 있지 않은 경우가
/// 많아, 화면 안에서 한 번 더 불러오는 편이 재사용하기 쉽다).
class MatchFortuneScreen extends StatefulWidget {
  final String matchId;
  final String currentUid;
  final PublicProfile otherProfile;
  final FirestoreService firestoreService;
  final FortuneService fortuneService;

  const MatchFortuneScreen({
    super.key,
    required this.matchId,
    required this.currentUid,
    required this.otherProfile,
    required this.firestoreService,
    required this.fortuneService,
  });

  @override
  State<MatchFortuneScreen> createState() => _MatchFortuneScreenState();
}

class _MatchFortuneScreenState extends State<MatchFortuneScreen> {
  bool _loading = true;
  bool _sharing = false;
  String? _error;
  UserProfile? _myProfile;
  ZodiacInfo? _myZodiac;
  SajuInfo? _mySaju;
  ZodiacInfo? _otherZodiac;
  SajuInfo? _otherSaju;
  FortuneNarrative? _narrative;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final myProfile =
          _myProfile ??
          await widget.firestoreService.getUserProfile(widget.currentUid);
      if (myProfile == null) {
        throw StateError('내 프로필을 찾을 수 없습니다.');
      }

      final result = await widget.fortuneService.getMatchFortune(
        matchId: widget.matchId,
        currentUid: widget.currentUid,
        otherUid: widget.otherProfile.uid,
      );

      if (mounted) {
        setState(() {
          _myProfile = myProfile;
          _myZodiac = result.myZodiac;
          _mySaju = result.mySaju;
          _otherZodiac = result.otherZodiac;
          _otherSaju = result.otherSaju;
          _narrative = result.narrative;
        });
      }
    } on FortuneFailure catch (e) {
      if (kDebugMode) {
        debugPrint('[MatchFortune] load_failed code=${e.code}');
      }
      if (mounted) setState(() => _error = 'load_failed');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[MatchFortune] load_failed category=${e.runtimeType}');
      }
      if (mounted) setState(() => _error = 'load_failed');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 궁합 결과 공유.
  ///
  /// 이미 화면에 로드된 값만 쓴다 — `_load()`나 `getMatchFortune`을 다시
  /// 부르지 않고, 상대의 비공개 프로필(UserProfile/birthDate/BirthProfile)을
  /// 조회하지도 않는다. 상대 쪽 별자리·일간은 서버 응답으로 이미 받아둔
  /// `_otherZodiac`/`_otherSaju`를 그대로 넘긴다.
  Future<void> _shareMatchFortuneResult() async {
    final narrative = _narrative;
    final myProfile = _myProfile;
    final myZodiac = _myZodiac;
    final mySaju = _mySaju;
    final otherZodiac = _otherZodiac;
    final otherSaju = _otherSaju;
    if (_sharing ||
        narrative == null ||
        myProfile == null ||
        myZodiac == null ||
        mySaju == null ||
        otherZodiac == null ||
        otherSaju == null) {
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _sharing = true);
    try {
      await ShareImageService.sharePng(
        context: context,
        child: MatchFortuneShareCard(
          myDisplayName: myProfile.displayName,
          otherDisplayName: widget.otherProfile.displayName,
          narrative: narrative,
          myZodiac: myZodiac,
          mySaju: mySaju,
          otherZodiac: otherZodiac,
          otherSaju: otherSaju,
        ),
        // matchId나 uid를 파일명에 넣지 않는다 — 공유 시트/저장 파일명으로
        // 내부 식별자가 새어나가지 않게 한다.
        fileName: 'match_fortune.png',
        title: '우리의 사주 궁합',
        text: '우리의 사주 궁합 결과를 확인해보세요.',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      // 원인 분류만 남기고 uid/matchId/경로는 로그에도 남기지 않는다.
      if (kDebugMode) {
        debugPrint('[MatchFortune] share_failed category=${e.runtimeType}');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('공유 이미지를 만드는 데 실패했어요.')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  double get _horizontalPadding => MediaQuery.sizeOf(context).width < 360
      ? AppSpacing.screenHCompact
      : AppSpacing.screenH;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        title: const Text('궁합', style: AppTextStyles.cardTitle),
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return _MatchFortuneLoadingState(horizontal: _horizontalPadding);
    }
    if (_error != null) {
      return _MatchFortuneErrorState(
        horizontal: _horizontalPadding,
        message: '궁합 정보를 불러오지 못했어요.\n잠시 후 다시 시도해주세요.',
        onRetry: _load,
      );
    }

    final narrative = _narrative;
    final myProfile = _myProfile;
    final myZodiac = _myZodiac;
    final mySaju = _mySaju;
    final otherZodiac = _otherZodiac;
    final otherSaju = _otherSaju;
    if (narrative == null ||
        myProfile == null ||
        myZodiac == null ||
        mySaju == null ||
        otherZodiac == null ||
        otherSaju == null) {
      return const SizedBox.shrink();
    }

    final horizontal = _horizontalPadding;
    final story = narrative.relationshipStory;

    return ListView(
      padding: EdgeInsets.fromLTRB(horizontal, AppSpacing.xs, horizontal, 40),
      children: [
        // ── A. Pair identity hero ───────────────────────────────────────────
        AppFadeSlideIn(
          child: _PairIdentityHero(
            myProfile: myProfile,
            myZodiac: myZodiac,
            mySaju: mySaju,
            otherProfile: widget.otherProfile,
            otherZodiac: otherZodiac,
            otherSaju: otherSaju,
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),

        // ── B. 핵심 궁합 인사이트 ────────────────────────────────────────────
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(1),
          child: _CompatibilityInsight(narrative: narrative),
        ),
        const SizedBox(height: AppSpacing.xxl),

        // ── C. 잘 맞는 이유 ──────────────────────────────────────────────────
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(2),
          child: _CompatibilityReasons(narrative: narrative),
        ),

        // ── D. 관계 이야기 (값이 있을 때만) ───────────────────────────────────
        if (story != null && story.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xxl),
          AppFadeSlideIn(
            delay: AppMotion.staggerDelay(3),
            child: _RelationshipStory(story: story),
          ),
        ],

        // ── E. 해석 근거 (결과보다 뒤, 조용히) ────────────────────────────────
        // MatchPrecisionNotice는 확정된 경우 스스로 숨는다. 여백만 조건부로 준다.
        if (narrative.missingBirthTime || narrative.boundaryUncertain) ...[
          const SizedBox(height: AppSpacing.xxl),
          MatchPrecisionNotice(
            missingBirthTime: narrative.missingBirthTime,
            boundaryUncertain: narrative.boundaryUncertain,
          ),
        ],

        // ── F. 공유 ──────────────────────────────────────────────────────────
        // 결과를 다 읽은 뒤 화면 마지막에서 공유하게 둔다.
        const SizedBox(height: AppSpacing.xxl),
        AppBrandButton(
          key: const Key('match-fortune-share'),
          label: _sharing ? '공유 이미지를 만들고 있어요' : '궁합 결과 공유하기',
          icon: _sharing ? null : Icons.ios_share_rounded,
          loading: _sharing,
          onPressed: _sharing ? null : _shareMatchFortuneResult,
        ),
      ],
    );
  }
}

// ═══ A. Pair identity hero ═══════════════════════════════════════════════════

/// 두 사람의 실제 사진이 화면의 첫 시각 중심이 되는 히어로.
///
/// 기존 [내 카드][빨간 하트][상대 카드] 구조를 폐기하고, 두 사진 사이를
/// [ConnectionMotif] 곡선이 잇는다 — 이 화면이 모티프의 원래 의미
/// ("두 사람이 이어진다")에 가장 정확히 맞는 자리다.
class _PairIdentityHero extends StatelessWidget {
  final UserProfile myProfile;
  final ZodiacInfo myZodiac;
  final SajuInfo mySaju;
  final PublicProfile otherProfile;
  final ZodiacInfo otherZodiac;
  final SajuInfo otherSaju;

  const _PairIdentityHero({
    required this.myProfile,
    required this.myZodiac,
    required this.mySaju,
    required this.otherProfile,
    required this.otherZodiac,
    required this.otherSaju,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.heroPadding),
      decoration: BoxDecoration(
        // 승인된 민트·코랄 tonal gradient. 세 색 모두 흰색에 가까워 위에 얹는
        // 차콜 텍스트 대비를 해치지 않는다.
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfacePrimary,
            AppColors.expressiveAccentSoft,
            AppColors.surfaceMintSoft,
          ],
          stops: [0.1, 0.62, 1],
        ),
        borderRadius: BorderRadius.circular(AppRadius.heroSoft),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '두 사람의 궁합 인사이트',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.brandPrimaryStrong,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: AppSpacing.lg20),
          LayoutBuilder(
            builder: (context, constraints) {
              // 사진은 남는 폭에서 계산하되 상·하한을 둬서, 좁은 기기에서도
              // 얼굴이 알아볼 수 없을 만큼 작아지지 않게 한다.
              const motifWidth = 58.0;
              final available = constraints.maxWidth - motifWidth;
              final photoSize = (available / 2 - AppSpacing.sm).clamp(
                62.0,
                92.0,
              );

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _PersonIdentity(
                      roleLabel: '나',
                      displayName: myProfile.displayName,
                      photoUrls: myProfile.photoUrls,
                      zodiac: myZodiac,
                      saju: mySaju,
                      photoSize: photoSize,
                      accent: AppColors.brandPrimary,
                    ),
                  ),
                  SizedBox(
                    width: motifWidth,
                    // 사진 세로 중앙 근처에 곡선이 걸리도록 높이를 맞춘다.
                    height: photoSize,
                    child: ExcludeSemantics(
                      child: IgnorePointer(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: AppMotion.entrance * 2,
                          curve: AppMotion.emphasized,
                          builder: (context, t, _) =>
                              ConnectionMotif(progress: t, strokeWidth: 1.8),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _PersonIdentity(
                      roleLabel: '상대',
                      displayName: otherProfile.displayName,
                      photoUrls: otherProfile.photoUrls,
                      zodiac: otherZodiac,
                      saju: otherSaju,
                      photoSize: photoSize,
                      accent: AppColors.expressiveAccent,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 한 사람의 사진 + 역할 라벨 + 이름 + metadata.
///
/// 역할(나/상대)을 색만이 아니라 텍스트 라벨로도 구분한다. 사진은 크기가
/// 고정돼 있어 로딩 전후로 레이아웃이 흔들리지 않는다.
class _PersonIdentity extends StatelessWidget {
  final String roleLabel;
  final String displayName;
  final List<String> photoUrls;
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  final double photoSize;

  /// 역할 점 색. 사진을 감싸는 두꺼운 테두리로는 쓰지 않는다.
  final Color accent;

  const _PersonIdentity({
    required this.roleLabel,
    required this.displayName,
    required this.photoUrls,
    required this.zodiac,
    required this.saju,
    required this.photoSize,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final photoUrl = photoUrls.isNotEmpty && photoUrls.first.trim().isNotEmpty
        ? photoUrls.first
        : null;

    return Column(
      children: [
        Semantics(
          image: true,
          label: '$roleLabel $displayName의 프로필 사진',
          child: ExcludeSemantics(
            child: Container(
              width: photoSize,
              height: photoSize,
              decoration: BoxDecoration(
                color: AppColors.surfaceSecondary,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.surfacePrimary, width: 2),
              ),
              clipBehavior: Clip.antiAlias,
              child: photoUrl == null
                  ? const _PhotoPlaceholder()
                  : Image.network(
                      photoUrl,
                      fit: BoxFit.cover,
                      // 실패해도 깨진 이미지 아이콘 대신 앱 토큰 placeholder로
                      // 떨어진다. 크기가 고정이라 레이아웃도 흔들리지 않는다.
                      errorBuilder: (_, _, _) => const _PhotoPlaceholder(),
                    ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              roleLabel,
              style: AppTextStyles.caption.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppTextStyles.cardTitle.copyWith(fontSize: 15),
        ),
        const SizedBox(height: 2),
        Text(
          // PublicProfile에는 생년월일·출생시간이 없다. 화면이 이미 다루던
          // 별자리·오행만 그대로 쓴다.
          '${zodiac.sign} · ${saju.dayMaster}(${saju.element})',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppTextStyles.caption,
        ),
      ],
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceSecondary,
      child: Center(
        child: Icon(Icons.person_rounded, color: AppColors.textMuted, size: 28),
      ),
    );
  }
}

// ═══ B. 핵심 궁합 인사이트 ════════════════════════════════════════════════════

class _CompatibilityInsight extends StatelessWidget {
  final FortuneNarrative narrative;

  const _CompatibilityInsight({required this.narrative});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('우리 관계의 분위기'),
        const SizedBox(height: AppSpacing.md),
        // 이 화면에서 명조(insight)를 쓰는 유일한 자리. 사주 레드로 칠하던
        // 것을 짙은 차콜로 되돌려 결과 문장 자체가 읽히게 한다.
        Text(narrative.characterType, style: AppTextStyles.insight),
        const SizedBox(height: AppSpacing.lg),
        Text(narrative.summary, style: AppTextStyles.body),
      ],
    );
  }
}

/// 민트 짧은 바 + caps 라벨. 사주 영역 화면들이 공유하는 섹션 헤딩 문법이다.
///
/// 내 사주 화면에도 같은 모양이 있지만, 이번 Phase에서 그 파일을 수정하지
/// 않기로 했으므로 공통 컴포넌트 승격은 다음 정리 Phase로 미룬다.
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 2,
          decoration: BoxDecoration(
            color: AppColors.brandPrimary,
            borderRadius: BorderRadius.circular(AppRadius.chip),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            text,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.brandPrimaryStrong,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══ C. 잘 맞는 이유 ══════════════════════════════════════════════════════════

/// 추천 이유 목록.
///
/// 큰 pill chip을 5개 늘어놓던 구성을 번호가 붙은 읽기용 목록으로 바꾼다.
/// **[_extractReasons]/[_splitIntoReasons]의 추출·분리·길이 제한 규칙은 기존
/// 그대로다** — 디자인을 이유로 텍스트 가공 규칙을 다시 쓰지 않는다.
class _CompatibilityReasons extends StatelessWidget {
  final FortuneNarrative narrative;

  const _CompatibilityReasons({required this.narrative});

  @override
  Widget build(BuildContext context) {
    final reasons = _extractReasons(narrative);
    final hasReasons = reasons.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('두 사람이 잘 맞는 이유'),
        const SizedBox(height: AppSpacing.lg),
        if (hasReasons)
          for (var i = 0; i < reasons.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1, color: AppColors.borderSubtle),
              const SizedBox(height: AppSpacing.md),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ReasonIndex(index: i + 1),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    reasons[i].text,
                    style: AppTextStyles.bodySecondary.copyWith(
                      color: AppColors.textStrong,
                    ),
                  ),
                ),
              ],
            ),
          ]
        else
          const Text(
            '아직 충분한 추천 이유를 만들 수 없어요. 프로필 정보를 더 채우면 추천 정확도가 높아져요.',
            style: AppTextStyles.bodySecondary,
          ),
      ],
    );
  }

  List<FortuneReason> _extractReasons(FortuneNarrative narrative) {
    final generated = narrative.reasons
        .where((reason) => reason.text.trim().isNotEmpty)
        .take(5)
        .toList();
    if (generated.isNotEmpty) return generated;

    final source = [
      narrative.relationshipStory,
      narrative.summary,
    ].whereType<String>().join(' ');
    return _splitIntoReasons(
      source,
    ).map((text) => FortuneReason(icon: '', text: text)).take(5).toList();
  }

  List<String> _splitIntoReasons(String source) {
    final normalized = source.replaceAll('\n', ' ').trim();
    if (normalized.isEmpty) return const [];
    return normalized
        .split(RegExp(r'[.!?。！？]|(?<=요)\s+|(?<=다)\s+'))
        .map((part) => part.trim())
        .where((part) => part.length >= 8)
        .map((part) => part.length > 44 ? '${part.substring(0, 44)}...' : part)
        .take(5)
        .toList();
  }
}

/// 순서를 알려주는 작은 번호. 아이콘 반복 대신 읽는 순서를 만든다.
class _ReasonIndex extends StatelessWidget {
  final int index;

  const _ReasonIndex({required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.brandPrimarySoft,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$index',
        style: AppTextStyles.caption.copyWith(
          fontSize: 11,
          height: 1,
          color: AppColors.brandPrimaryStrong,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// ═══ D. 관계 이야기 ═══════════════════════════════════════════════════════════

/// [FortuneNarrative.relationshipStory]가 실제로 있을 때만 호출된다.
/// 값이 없을 때의 placeholder나 "아직 없어요" 문구는 만들지 않는다.
class _RelationshipStory extends StatelessWidget {
  final String story;

  const _RelationshipStory({required this.story});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('두 사람의 관계 이야기'),
        const SizedBox(height: AppSpacing.lg),
        // 카드가 아니라 왼쪽 민트 룰이 붙은 에디토리얼 인용 형태.
        // 따옴표 아이콘이나 보조색 카드는 쓰지 않는다.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 2,
                decoration: BoxDecoration(
                  color: AppColors.brandPrimary.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Text(
                  story,
                  style: AppTextStyles.body.copyWith(height: 1.75),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ═══ 상태 화면 ═══════════════════════════════════════════════════════════════

/// FortuneHub / History / 내 사주와 같은 skeleton 문법.
/// 새 데이터 호출은 없다 — 기존 `_loading` 플래그의 표현만 바뀐다.
class _MatchFortuneLoadingState extends StatelessWidget {
  final double horizontal;

  const _MatchFortuneLoadingState({required this.horizontal});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        AppSpacing.xs,
        horizontal,
        AppSpacing.xxl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.heroSoft),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SkeletonBar(width: 118, height: 12),
                  const Spacer(),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brandPrimary.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg20),
              const Row(
                children: [
                  Expanded(child: _PersonSkeleton()),
                  SizedBox(width: 58),
                  Expanded(child: _PersonSkeleton()),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        const _SkeletonBar(width: 104, height: 12),
        const SizedBox(height: AppSpacing.md),
        const _SkeletonBar(width: 212, height: 26),
        const SizedBox(height: AppSpacing.lg),
        const _SkeletonBar(height: 14),
        const SizedBox(height: AppSpacing.sm),
        const _SkeletonBar(height: 14),
        const SizedBox(height: AppSpacing.sm),
        const _SkeletonBar(width: 176, height: 14),
        const SizedBox(height: AppSpacing.xxl),
        const _SkeletonBar(width: 128, height: 12),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.lg),
          const Row(
            children: [
              _SkeletonBar(width: 22, height: 22),
              SizedBox(width: AppSpacing.md),
              Expanded(child: _SkeletonBar(height: 14)),
            ],
          ),
        ],
      ],
    );
  }
}

class _PersonSkeleton extends StatelessWidget {
  const _PersonSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        _SkeletonBar(width: 82, height: 82, radius: 999),
        SizedBox(height: AppSpacing.md),
        _SkeletonBar(width: 34, height: 11),
        SizedBox(height: 6),
        _SkeletonBar(width: 62, height: 15),
        SizedBox(height: 6),
        _SkeletonBar(width: 86, height: 11),
      ],
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const _SkeletonBar({
    this.width,
    required this.height,
    this.radius = AppRadius.chip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.canvasSubtle,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _MatchFortuneErrorState extends StatelessWidget {
  final double horizontal;
  final String message;
  final VoidCallback onRetry;

  const _MatchFortuneErrorState({
    required this.horizontal,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        AppSpacing.xl,
        horizontal,
        AppSpacing.xxl,
      ),
      children: [
        AppSurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.statusDangerSoft,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 24,
                    color: AppColors.statusDanger,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary,
              ),
              const SizedBox(height: AppSpacing.lg20),
              AppBrandButton(
                label: '다시 시도',
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
