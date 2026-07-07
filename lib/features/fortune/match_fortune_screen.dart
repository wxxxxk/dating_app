import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/share/share_image_service.dart';
import 'widgets/share_card.dart';

/// 궁합 화면 — 매칭 목록의 "궁합 보기" 진입점.
///
/// 내 프로필은 [currentUid]로 직접 조회한다(호출부가 이미 들고 있지 않은 경우가
/// 많아, 화면 안에서 한 번 더 불러오는 편이 재사용하기 쉽다).
class MatchFortuneScreen extends StatefulWidget {
  final String matchId;
  final String currentUid;
  final UserProfile otherProfile;
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
  FortuneNarrative? _narrative;
  bool _sharing = false;

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

      final myZodiac = FortuneCalculator.getZodiacSign(myProfile.birthDate);
      final mySaju = FortuneCalculator.getSaju(myProfile.birthDate);
      final otherZodiac = FortuneCalculator.getZodiacSign(
        widget.otherProfile.birthDate,
      );
      final otherSaju = FortuneCalculator.getSaju(
        widget.otherProfile.birthDate,
      );

      final narrative = await widget.fortuneService.getMatchFortune(
        matchId: widget.matchId,
        myZodiac: myZodiac,
        mySaju: mySaju,
        otherZodiac: otherZodiac,
        otherSaju: otherSaju,
      );

      if (mounted) {
        setState(() {
          _myProfile = myProfile;
          _myZodiac = myZodiac;
          _mySaju = mySaju;
          _narrative = narrative;
        });
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[MatchFortune] 궁합 로드 실패: $e');
        debugPrint('$stackTrace');
      }
      if (mounted) setState(() => _error = '궁합 정보를 불러오지 못했어요.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _shareMatchResult() async {
    final narrative = _narrative;
    final myProfile = _myProfile;
    final myZodiac = _myZodiac;
    final mySaju = _mySaju;
    if (narrative == null ||
        myProfile == null ||
        myZodiac == null ||
        mySaju == null ||
        _sharing) {
      return;
    }
    final otherZodiac = FortuneCalculator.getZodiacSign(
      widget.otherProfile.birthDate,
    );
    final otherSaju = FortuneCalculator.getSaju(widget.otherProfile.birthDate);

    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _sharing = true);
    try {
      await ShareImageService.sharePng(
        context: context,
        child: MatchShareCard(
          myProfile: myProfile,
          otherProfile: widget.otherProfile,
          narrative: narrative,
          myZodiac: myZodiac,
          mySaju: mySaju,
          otherZodiac: otherZodiac,
          otherSaju: otherSaju,
        ),
        fileName: 'match_${widget.matchId}.png',
        title: '우리의 사주 궁합',
        text: '우리의 사주 궁합 결과를 확인해보세요.',
        sharePositionOrigin: origin,
      );
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[MatchFortune] 궁합 이미지 생성 실패: $e');
        debugPrint('$stackTrace');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('궁합 이미지를 만드는 데 실패했어요.')));
    } finally {
      if (mounted) setState(() => _sharing = false);
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
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
                _error ?? '궁합 정보를 불러오지 못했어요.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    final narrative = _narrative;
    final myProfile = _myProfile;
    final myZodiac = _myZodiac;
    final mySaju = _mySaju;
    if (narrative == null ||
        myProfile == null ||
        myZodiac == null ||
        mySaju == null) {
      return const SizedBox.shrink();
    }

    final otherZodiac = FortuneCalculator.getZodiacSign(
      widget.otherProfile.birthDate,
    );
    final otherSaju = FortuneCalculator.getSaju(widget.otherProfile.birthDate);

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
            _CharacterCard(narrative: narrative),
            const SizedBox(height: 20),
            _ShareButton(
              label: '궁합 공유하기',
              onPressed: _sharing ? null : _shareMatchResult,
            ),
            const SizedBox(height: 20),
            _AiRecommendationReasons(narrative: narrative),
            if (narrative.relationshipStory != null &&
                narrative.relationshipStory!.isNotEmpty) ...[
              const SizedBox(height: 20),
              _RelationshipStoryCard(story: narrative.relationshipStory!),
            ],
          ],
        ),
        if (_sharing) const _ShareLoadingOverlay(),
      ],
    );
  }
}

class _ShareButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _ShareButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.ios_share_rounded),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.surface,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
    );
  }
}

class _ShareLoadingOverlay extends StatelessWidget {
  const _ShareLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.ink.withValues(alpha: 0.26),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('공유 이미지 생성 중'),
              ],
            ),
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
  final UserProfile otherProfile;
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
            profile: myProfile,
            zodiac: myZodiac,
            saju: mySaju,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(
            Icons.favorite_rounded,
            color: AppColors.primary,
            size: 28,
          ),
        ),
        Expanded(
          child: _PersonCard(
            profile: otherProfile,
            zodiac: otherZodiac,
            saju: otherSaju,
          ),
        ),
      ],
    );
  }
}

class _PersonCard extends StatelessWidget {
  final UserProfile profile;
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  const _PersonCard({
    required this.profile,
    required this.zodiac,
    required this.saju,
  });

  @override
  Widget build(BuildContext context) {
    final photoUrl = profile.photoUrls.isNotEmpty ? profile.photoUrls[0] : null;
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
            profile.displayName,
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
        color: AppColors.seal,
        borderRadius: BorderRadius.circular(AppRadius.card),
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
              color: AppColors.surface,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            narrative.summary,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 15,
              color: AppColors.surface,
              height: 1.6,
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
              color: AppColors.primary.withValues(alpha: 0.12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.primary,
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
          color: AppColors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome_rounded,
              size: 15,
              color: AppColors.primary,
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
