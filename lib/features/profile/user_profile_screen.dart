import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/constants/profile_story_prompts.dart';
import '../../core/constants/value_questions.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/ai_keyword_summary.dart';
import '../../models/profile_story.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/location/location_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/premium_components.dart';
import '../../shared/widgets/profile_photo_view.dart';
import '../safety/report_sheet.dart';
import 'widgets/verification_badge.dart';

/// 상대 프로필 상세 화면.
///
/// 정확한 위치 좌표는 노출하지 않고 거리/프로필 정보만 보여준다.
class UserProfileScreen extends StatefulWidget {
  final String currentUid;
  final PublicProfile initialProfile;
  final UserLocation? currentLocation;
  final FirestoreService firestoreService;
  final SafetyService safetyService;

  const UserProfileScreen({
    super.key,
    required this.currentUid,
    required this.initialProfile,
    required this.currentLocation,
    required this.firestoreService,
    required this.safetyService,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  late PublicProfile _profile = widget.initialProfile;
  bool _loading = false;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    _refreshProfile();
  }

  Future<void> _refreshProfile() async {
    setState(() => _loading = true);
    try {
      final latest = await widget.firestoreService.getPublicProfile(
        widget.initialProfile.uid,
      );
      if (latest != null && mounted) {
        setState(() => _profile = latest);
      } else if (mounted) {
        _showSnack('프로필을 불러올 수 없어요.');
      }
    } catch (e) {
      _debugLog('[Profile] 공개 프로필 새로고침 실패: $e');
      if (mounted) _showSnack('프로필을 불러올 수 없어요.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reportUser() async {
    final submission = await showReportSheet(context);
    if (submission == null) return;
    try {
      await widget.safetyService.reportUser(
        reporterUid: widget.currentUid,
        reportedUid: _profile.uid,
        reason: submission.reason,
        detail: submission.detail,
      );
      if (submission.blockUser) {
        await widget.safetyService.blockUser(
          currentUid: widget.currentUid,
          blockedUid: _profile.uid,
        );
      }
      if (!mounted) return;
      setState(() => _blocked = submission.blockUser || _blocked);
      _showSnack(submission.blockUser ? '신고가 접수되고 차단했어요.' : '신고가 접수되었어요.');
    } catch (e) {
      _debugLog('[Safety] 프로필 신고 실패: $e');
      if (mounted) _showSnack('신고에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> _blockUser() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfacePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        icon: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: AppColors.statusDangerSoft,
            shape: BoxShape.circle,
          ),
          child: const ExcludeSemantics(
            child: Icon(
              Icons.block_rounded,
              size: 22,
              color: AppColors.statusDanger,
            ),
          ),
        ),
        title: const Text(
          '차단하기',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
          ),
        ),
        content: const Text(
          '차단하면 서로 디스커버리, 매칭, 채팅에서 볼 수 없어요.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: AppColors.textBody,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textBody,
                    side: const BorderSide(color: AppColors.borderStrong),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                  ),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.statusDanger,
                    foregroundColor: AppColors.surface,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text(
                    '차단',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.safetyService.blockUser(
        currentUid: widget.currentUid,
        blockedUid: _profile.uid,
      );
      if (!mounted) return;
      setState(() => _blocked = true);
      _showSnack('차단했어요.');
    } catch (e) {
      _debugLog('[Safety] 프로필 차단 실패: $e');
      if (mounted) _showSnack('차단에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final coarseDistance = LocationService.distanceToCoarse(
      widget.currentLocation,
      _profile.coarseLocation,
    );
    final distanceLabel = coarseDistance == null
        ? null
        : LocationService.formatDistance(coarseDistance);
    final visibleStories = _visibleProfileStories(_profile.profileStories);
    final keywordSummary = _profile.aiKeywordSummary;
    final visibleKeywordSummary =
        keywordSummary != null && keywordSummary.keywords.length >= 2
        ? keywordSummary
        : null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          _profile.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
          ),
        ),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            tooltip: '안전 메뉴',
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppColors.textBody,
            ),
            color: AppColors.surfacePrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.borderSubtle),
            ),
            onSelected: (value) {
              if (value == 'report') _reportUser();
              if (value == 'block') _blockUser();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'report',
                child: Row(
                  children: [
                    Icon(
                      Icons.flag_outlined,
                      size: 19,
                      color: AppColors.textBody,
                    ),
                    SizedBox(width: 12),
                    Text('신고하기'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'block',
                child: Row(
                  children: [
                    Icon(
                      Icons.block_rounded,
                      size: 19,
                      color: AppColors.statusDanger,
                    ),
                    SizedBox(width: 12),
                    Text(
                      '차단하기',
                      style: TextStyle(color: AppColors.statusDanger),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshProfile,
        child: ListView(
          children: [
            _PhotoGallery(profile: _profile, loading: _loading),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IntroHeader(
                    profile: _profile,
                    distanceLabel: distanceLabel,
                    blocked: _blocked,
                  ),
                  const SizedBox(height: 20),
                  if (_profile.bio.isNotEmpty) ...[
                    Text(
                      stripEmoji(_profile.bio),
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.55,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                  if (visibleKeywordSummary != null) ...[
                    if (_profile.bio.isNotEmpty) const SizedBox(height: 22),
                    _ProfileKeywordSummarySection(
                      summary: visibleKeywordSummary,
                    ),
                  ],
                  if (visibleStories.isNotEmpty) ...[
                    if (_profile.bio.isNotEmpty &&
                        visibleKeywordSummary == null)
                      const SizedBox(height: 22),
                    _ProfileStoriesSection(entries: visibleStories),
                  ] else if (visibleKeywordSummary == null)
                    const SizedBox(height: 22),
                  _DetailGrid(profile: _profile),
                  _TagSection(
                    title: '관심사',
                    tone: _TagTone.interest,
                    labels: ProfileOptions.keysToLabels(
                      ProfileOptions.interests,
                      _profile.interests,
                    ),
                  ),
                  _TagSection(
                    title: '성향',
                    tone: _TagTone.personality,
                    labels: ProfileOptions.keysToLabels(
                      ProfileOptions.personalities,
                      _profile.personalityTags,
                    ),
                  ),
                  _TagSection(
                    title: '이상형',
                    tone: _TagTone.ideal,
                    labels: ProfileOptions.keysToLabels(
                      ProfileOptions.ideals,
                      _profile.idealTags,
                    ),
                  ),
                  _ValueAnswersSection(answers: _profile.valueAnswers),
                  if (_profile.relationshipGoal != null)
                    _InfoSection(
                      title: '찾는 관계',
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceMintSoft,
                          borderRadius: BorderRadius.circular(
                            AppRadius.surface,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.favorite_rounded,
                              size: 19,
                              color: AppColors.matchPrimary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                ProfileOptions.keyToLabel(
                                      ProfileOptions.relationshipGoals,
                                      _profile.relationshipGoal!,
                                    ) ??
                                    _profile.relationshipGoal!,
                                style: const TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textStrong,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileStoryDisplayEntry {
  final String promptKey;
  final String promptLabel;
  final String answer;

  const _ProfileStoryDisplayEntry({
    required this.promptKey,
    required this.promptLabel,
    required this.answer,
  });
}

List<_ProfileStoryDisplayEntry> _visibleProfileStories(
  List<ProfileStory> stories,
) {
  final entries = <_ProfileStoryDisplayEntry>[];
  for (final story in stories) {
    final label = ProfileStoryPrompts.labelFor(story.promptKey);
    if (label == null || label.isEmpty) continue;

    final answer = _profileStoryDisplayAnswer(story.answer);
    if (answer.isEmpty) continue;

    entries.add(
      _ProfileStoryDisplayEntry(
        promptKey: story.promptKey,
        promptLabel: label,
        answer: answer,
      ),
    );
  }
  return entries;
}

String _profileStoryDisplayAnswer(String answer) {
  final withoutControls = answer.replaceAll(
    RegExp(r'[\u0000-\u0009\u000B-\u001F\u007F]'),
    '',
  );
  return stripEmoji(withoutControls);
}

/// 사진 아래 밝은 first-impression 영역 — 이름·나이 + 인증 + 기본 정보 chip.
/// 소개글은 이 다음에 본문 흐름으로 이어진다(별도 카드에 넣지 않는다).
class _IntroHeader extends StatelessWidget {
  final PublicProfile profile;
  final String? distanceLabel;
  final bool blocked;

  const _IntroHeader({
    required this.profile,
    required this.distanceLabel,
    required this.blocked,
  });

  @override
  Widget build(BuildContext context) {
    // 기본 정보 chip: 거리 > MBTI > 성별 > 차단 상태 순. 기존에 보이던 값은
    // 모두 유지하되 한 줄에 억지로 넣지 않고 Wrap한다.
    final chips = <Widget>[
      if (distanceLabel != null)
        _IntroChip(
          icon: Icons.place_rounded,
          label: distanceLabel!,
          iconColor: AppColors.mintDeep,
        ),
      if (profile.mbti != null) _IntroChip(label: profile.mbti!),
      _IntroChip(label: _genderLabel(profile.gender)),
      if (blocked)
        const _IntroChip(icon: Icons.block_rounded, label: '차단됨', danger: true),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                '${profile.displayName}, ${profile.age}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                  height: 1.1,
                  color: AppColors.textStrong,
                ),
              ),
            ),
            if (profile.verifications.hasAny) ...[
              const SizedBox(width: 10),
              VerificationBadges(
                verifications: profile.verifications,
                brightness: Brightness.light,
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: chips),
      ],
    );
  }
}

/// introduction shelf의 기본 정보 chip(밝은 톤). 차단 상태만 pale danger.
class _IntroChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color? iconColor;
  final bool danger;

  const _IntroChip({
    this.icon,
    required this.label,
    this.iconColor,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = danger ? AppColors.statusDangerSoft : AppColors.surfaceSecondary;
    final fg = danger ? AppColors.statusDanger : AppColors.textBody;
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            ExcludeSemantics(
              child: Icon(
                icon,
                size: 14,
                color: danger ? fg : (iconColor ?? fg),
              ),
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                height: 1,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoGallery extends StatefulWidget {
  final PublicProfile profile;
  final bool loading;

  const _PhotoGallery({required this.profile, required this.loading});

  @override
  State<_PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<_PhotoGallery> {
  late final PageController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void didUpdateWidget(covariant _PhotoGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.photoUrls != widget.profile.photoUrls) {
      _index = 0;
      if (_controller.hasClients) {
        _controller.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showPrevious() {
    if (widget.profile.photoUrls.length <= 1 || _index == 0) return;
    _controller.previousPage(
      duration: AppDurations.base,
      curve: AppCurves.standard,
    );
  }

  void _showNext() {
    if (widget.profile.photoUrls.length <= 1 ||
        _index >= widget.profile.photoUrls.length - 1) {
      return;
    }
    _controller.nextPage(
      duration: AppDurations.base,
      curve: AppCurves.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final photoUrls = widget.profile.photoUrls;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: PremiumProfileImageCard(
        // 사진 자체가 중심인 밝은 stage — 정보 오버레이/강한 검정 gradient 없이
        // 대표 사진의 실제 비율을 그대로 따른다(잘리지 않음). softFrame으로 mint
        // glow 대신 얇은 중립 보더 + 부드러운 단일 섀도우만 쓴다.
        softFrame: true,
        child: Stack(
          children: [
            ProfilePhotoDetailView(
              photoUrls: photoUrls,
              controller: _controller,
              onPageChanged: (value) => setState(() => _index = value),
            ),
            // 사진↔shelf 경계를 위한 아주 옅은 하단 fade(36px, 최대 10% ink).
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 36,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0x1A000000)],
                  ),
                ),
              ),
            ),
            if (widget.loading)
              Positioned(
                top: 14,
                right: 14,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: AppColors.surfacePrimary.withValues(alpha: 0.92),
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.mintDeep,
                    ),
                  ),
                ),
              ),
            if (photoUrls.length > 1) ...[
              _PhotoTapZones(onPrevious: _showPrevious, onNext: _showNext),
              _PhotoSegmentIndicator(
                count: photoUrls.length,
                activeIndex: _index,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PhotoTapZones extends StatelessWidget {
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _PhotoTapZones({required this.onPrevious, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onPrevious,
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onNext,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoSegmentIndicator extends StatelessWidget {
  final int count;
  final int activeIndex;

  const _PhotoSegmentIndicator({
    required this.count,
    required this.activeIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Row(
        children: List.generate(count, (index) {
          final active = index == activeIndex;
          return Expanded(
            child: Container(
              height: 2.5,
              margin: EdgeInsets.only(right: index == count - 1 ? 0 : 4),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: active ? 0.95 : 0.3),
                borderRadius: BorderRadius.circular(AppRadius.chip),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: AppColors.ink.withValues(alpha: 0.16),
                          blurRadius: 2,
                        ),
                      ]
                    : null,
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _DetailGrid extends StatelessWidget {
  final PublicProfile profile;

  const _DetailGrid({required this.profile});

  @override
  Widget build(BuildContext context) {
    final items = <({String label, String value})>[
      if (profile.height != null) (label: '키', value: '${profile.height}cm'),
      if (profile.jobCategory != null || profile.jobTitle != null)
        (label: '직업', value: _jobText(profile)),
      if (profile.education != null)
        (
          label: '학력',
          value:
              ProfileOptions.keyToLabel(
                ProfileOptions.educationOptions,
                profile.education!,
              ) ??
              profile.education!,
        ),
      if (profile.religion != null)
        (
          label: '종교',
          value:
              ProfileOptions.keyToLabel(
                ProfileOptions.religions,
                profile.religion!,
              ) ??
              profile.religion!,
        ),
      if (profile.smoking != null)
        (
          label: '흡연',
          value:
              ProfileOptions.keyToLabel(
                ProfileOptions.smokingOptions,
                profile.smoking!,
              ) ??
              profile.smoking!,
        ),
      if (profile.drinking != null)
        (
          label: '음주',
          value:
              ProfileOptions.keyToLabel(
                ProfileOptions.drinkingOptions,
                profile.drinking!,
              ) ??
              profile.drinking!,
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    // pill 반복 대신 하나의 밝은 Facts Surface에 label/value row를 divider로
    // 이어 붙인다. 실제 값이 있는 항목만, 기존 순서 그대로 표시한다.
    return _InfoSection(
      title: '상세 정보',
      bottomSpacing: 26,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfacePrimary,
          borderRadius: BorderRadius.circular(AppRadius.surface),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                const Divider(height: 1, color: AppColors.borderSubtle),
              _FactRow(label: items[i].label, value: items[i].value),
            ],
          ],
        ),
      ),
    );
  }

  static String _jobText(PublicProfile profile) {
    final category = profile.jobCategory == null
        ? null
        : ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions,
            profile.jobCategory!,
          );
    return [?category, ?profile.jobTitle].join(' · ');
  }
}

/// 취향 chip section의 톤. 관심사(친근한 mint) / 성향(중립 outline) /
/// 이상형(옅은 coral)을 서로 다른 성격으로 구분한다. 데이터·순서·표시 조건은
/// 톤과 무관하게 동일하다(색상 presentation만 다르다).
enum _TagTone { interest, personality, ideal }

class _TagSection extends StatelessWidget {
  final String title;
  final List<String> labels;
  final _TagTone tone;

  const _TagSection({
    required this.title,
    required this.labels,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    return _InfoSection(
      title: title,
      bottomSpacing: 26,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: labels
            .map((label) => _TagChip(label: label, tone: tone))
            .toList(),
      ),
    );
  }
}

class _ProfileKeywordSummarySection extends StatelessWidget {
  final AiKeywordSummary summary;

  const _ProfileKeywordSummarySection({required this.summary});

  @override
  Widget build(BuildContext context) {
    final isAiGenerated = summary.generator == 'ai';
    final title = isAiGenerated ? 'AI가 요약한 키워드' : '프로필 키워드';

    return Padding(
      key: const ValueKey('profile-keyword-summary-section'),
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isAiGenerated) ...[
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 16,
                  color: AppColors.matchPrimary,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < summary.keywords.length; i++)
                _ProfileKeywordChip(keyword: summary.keywords[i], index: i),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileKeywordChip extends StatelessWidget {
  final String keyword;
  final int index;

  const _ProfileKeywordChip({required this.keyword, required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('profile-keyword-summary-chip-$index'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.mintSoft,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.premiumBorder),
      ),
      child: Text(
        '#$keyword',
        key: ValueKey('profile-keyword-summary-label-$index'),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: AppColors.mintDeep,
        ),
      ),
    );
  }
}

class _ProfileStoriesSection extends StatelessWidget {
  final List<_ProfileStoryDisplayEntry> entries;

  const _ProfileStoriesSection({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();

    // 어두운 독립 카드 반복 대신, 하나의 밝은 interview surface에 story를
    // divider로 이어 붙인다(본인이 직접 들려주는 문장이 주인공이 되도록).
    return _InfoSection(
      key: const ValueKey('profile-stories-section'),
      title: '이 사람의 이야기',
      bottomSpacing: 28,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfacePrimary,
          borderRadius: BorderRadius.circular(AppRadius.surface),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0)
                const Divider(height: 1, color: AppColors.borderSubtle),
              _ProfileStoryDisplayCard(entry: entries[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileStoryDisplayCard extends StatelessWidget {
  final _ProfileStoryDisplayEntry entry;

  const _ProfileStoryDisplayCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    // 밝은 interview surface 내부의 한 항목 — 별도 그림자 카드가 아니다.
    return Container(
      key: ValueKey('profile-story-display-${entry.promptKey}'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(color: AppColors.surfacePrimary),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ExcludeSemantics(
                child: Icon(
                  Icons.format_quote_rounded,
                  size: 15,
                  color: AppColors.expressiveAccent,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.promptLabel,
                  key: ValueKey(
                    'profile-story-prompt-label-${entry.promptKey}',
                  ),
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                    color: AppColors.expressiveAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            entry.answer,
            key: ValueKey('profile-story-answer-label-${entry.promptKey}'),
            style: const TextStyle(
              fontSize: 16.5,
              height: 1.55,
              fontWeight: FontWeight.w700,
              color: AppColors.textStrong,
            ),
          ),
        ],
      ),
    );
  }
}

/// 상대 프로필의 가치관 답변을 기본 라벨 형태로 표시하는 섹션.
///
/// 표시 규칙:
/// - [PublicProfile.valueAnswers]만 사용한다(비공개 users 문서를 조회하지 않는다).
/// - 항상 [ValueQuestions.all] 순서로 순회한다.
/// - 카탈로그에 없는 question key, 유효하지 않은 answer key는 화면에서만 숨긴다
///   (모델 데이터는 변경하지 않는다).
/// - 표시할 유효 항목이 하나도 없으면 섹션 자체를 렌더링하지 않는다(빈 상태 문구 없음).
class _ValueAnswersSection extends StatelessWidget {
  final Map<String, String> answers;

  const _ValueAnswersSection({required this.answers});

  @override
  Widget build(BuildContext context) {
    final entries =
        <({String questionKey, String questionLabel, String answerLabel})>[];
    for (final question in ValueQuestions.all) {
      final answerKey = answers[question.key];
      if (answerKey == null || answerKey.isEmpty) continue;
      final answerLabel = ValueQuestions.answerLabel(question.key, answerKey);
      if (answerLabel == null || answerLabel.isEmpty) continue;
      entries.add((
        questionKey: question.key,
        questionLabel: question.profileLabel,
        answerLabel: answerLabel,
      ));
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    // 질문/답변을 하나의 차분한 surface에 divider로 정리한다(Values Portrait).
    return _InfoSection(
      key: const ValueKey('profile-value-answers-section'),
      title: '가치관',
      bottomSpacing: 24,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceSecondary,
          borderRadius: BorderRadius.circular(AppRadius.surface),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0)
                const Divider(height: 1, color: AppColors.borderSubtle),
              _ValueAnswerItem(
                questionKey: entries[i].questionKey,
                questionLabel: entries[i].questionLabel,
                answerLabel: entries[i].answerLabel,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ValueAnswerItem extends StatelessWidget {
  final String questionKey;
  final String questionLabel;
  final String answerLabel;

  const _ValueAnswerItem({
    required this.questionKey,
    required this.questionLabel,
    required this.answerLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('profile-value-answer-$questionKey'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            questionLabel,
            key: ValueKey('profile-value-question-$questionKey'),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            answerLabel,
            key: ValueKey('profile-value-label-$questionKey'),
            style: const TextStyle(
              fontSize: 15.5,
              height: 1.45,
              fontWeight: FontWeight.w700,
              color: AppColors.textStrong,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  final String title;
  final Widget child;

  /// 서사 영역(이야기/가치관)에서만 section 간 여백을 명시 조정한다.
  /// 기본값 22는 기존 상세 정보·태그·찾는 관계 렌더를 그대로 유지한다.
  final double bottomSpacing;

  const _InfoSection({
    super.key,
    required this.title,
    required this.child,
    this.bottomSpacing = 22,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Facts Surface의 label/value row 한 줄.
class _FactRow extends StatelessWidget {
  final String label;
  final String value;

  const _FactRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                  color: AppColors.textStrong,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  final _TagTone tone;

  const _TagChip({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    Border? border;
    switch (tone) {
      case _TagTone.interest:
        bg = AppColors.surfaceMintSoft;
        fg = AppColors.mintDeep;
      case _TagTone.personality:
        bg = AppColors.surfaceSecondary;
        fg = AppColors.textStrong;
        border = Border.all(color: AppColors.borderSubtle);
      case _TagTone.ideal:
        bg = AppColors.expressiveAccentSoft;
        fg = AppColors.textStrong;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: border,
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

String _genderLabel(String gender) {
  switch (gender) {
    case 'male':
      return '남성';
    case 'female':
      return '여성';
    default:
      return '기타';
  }
}
