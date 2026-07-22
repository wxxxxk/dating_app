import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import 'widgets/saju_precision_notice.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('궁합', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.background,
        elevation: 0,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _MatchFortuneErrorState(
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

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          children: [
            _CoupleRow(
              myProfile: myProfile,
              myZodiac: myZodiac,
              mySaju: mySaju,
              otherProfile: widget.otherProfile,
              otherZodiac: otherZodiac,
              otherSaju: otherSaju,
            ),
            const SizedBox(height: 24),
            MatchPrecisionNotice(missingBirthTime: narrative.missingBirthTime),
            if (narrative.missingBirthTime) const SizedBox(height: 16),
            _CharacterCard(narrative: narrative),
            const SizedBox(height: 20),
            _AiRecommendationReasons(narrative: narrative),
            if (narrative.relationshipStory != null &&
                narrative.relationshipStory!.isNotEmpty) ...[
              const SizedBox(height: 20),
              _RelationshipStoryCard(story: narrative.relationshipStory!),
            ],
          ],
        ),
      ],
    );
  }
}

class _MatchFortuneErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _MatchFortuneErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final minHeight =
        MediaQuery.sizeOf(context).height -
        kToolbarHeight -
        MediaQuery.paddingOf(context).vertical;
    final safeMinHeight = minHeight < 0 ? 0.0 : minHeight;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: safeMinHeight),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoupleRow extends StatelessWidget {
  final UserProfile myProfile;
  final ZodiacInfo myZodiac;
  final SajuInfo mySaju;
  final PublicProfile otherProfile;
  final ZodiacInfo otherZodiac;
  final SajuInfo otherSaju;

  const _CoupleRow({
    required this.myProfile,
    required this.myZodiac,
    required this.mySaju,
    required this.otherProfile,
    required this.otherZodiac,
    required this.otherSaju,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _PersonCard(
            displayName: myProfile.displayName,
            photoUrls: myProfile.photoUrls,
            zodiac: myZodiac,
            saju: mySaju,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(
            Icons.favorite_rounded,
            color: AppColors.fortuneAccent,
            size: 28,
          ),
        ),
        Expanded(
          child: _PersonCard(
            displayName: otherProfile.displayName,
            photoUrls: otherProfile.photoUrls,
            zodiac: otherZodiac,
            saju: otherSaju,
          ),
        ),
      ],
    );
  }
}

class _PersonCard extends StatelessWidget {
  final String displayName;
  final List<String> photoUrls;
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  const _PersonCard({
    required this.displayName,
    required this.photoUrls,
    required this.zodiac,
    required this.saju,
  });

  @override
  Widget build(BuildContext context) {
    final photoUrl = photoUrls.isNotEmpty ? photoUrls[0] : null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
            backgroundColor: AppColors.border,
            child: photoUrl == null
                ? const Icon(
                    Icons.person_rounded,
                    color: AppColors.textSecondary,
                  )
                : null,
          ),
          const SizedBox(height: 8),
          Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            '${zodiac.sign} · ${saju.element}',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacterCard extends StatelessWidget {
  final FortuneNarrative narrative;
  const _CharacterCard({required this.narrative});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.seal.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            narrative.characterType,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.seal,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            narrative.summary,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.textPrimary,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}

class _AiRecommendationReasons extends StatelessWidget {
  final FortuneNarrative narrative;

  const _AiRecommendationReasons({required this.narrative});

  @override
  Widget build(BuildContext context) {
    final reasons = _extractReasons(narrative);
    final hasReasons = reasons.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: AppColors.fortuneAccent.withValues(alpha: 0.12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.fortuneAccent,
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'AI 추천 이유',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (hasReasons)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: reasons
                      .map((reason) => _RecommendationChip(reason: reason))
                      .toList(),
                )
              else
                const Text(
                  '아직 충분한 추천 이유를 만들 수 없어요. 프로필 정보를 더 채우면 추천 정확도가 높아져요.',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                    height: 1.5,
                  ),
                ),
            ],
          ),
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

class _RecommendationChip extends StatelessWidget {
  final FortuneReason reason;

  const _RecommendationChip({required this.reason});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        constraints: const BoxConstraints(minHeight: 42),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.fortuneAccent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: AppColors.fortuneAccent.withValues(alpha: 0.16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome_rounded,
              size: 15,
              color: AppColors.fortuneAccent,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                reason.text,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RelationshipStoryCard extends StatelessWidget {
  final String story;
  const _RelationshipStoryCard({required this.story});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            ' 관계 이야기',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppColors.secondary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            story,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textPrimary,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
