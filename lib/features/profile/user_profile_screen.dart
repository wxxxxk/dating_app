import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/profile_insight_model.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/location/location_service.dart';
import '../../services/profile/profile_insight_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/premium_components.dart';
import '../safety/report_sheet.dart';
import 'widgets/verification_badge.dart';

/// 상대 프로필 상세 화면.
///
/// 정확한 위치 좌표는 노출하지 않고 거리/프로필 정보만 보여준다.
class UserProfileScreen extends StatefulWidget {
  final String currentUid;
  final UserProfile initialProfile;
  final UserLocation? currentLocation;
  final FirestoreService firestoreService;
  final SafetyService safetyService;
  final ProfileInsightService profileInsightService;

  const UserProfileScreen({
    super.key,
    required this.currentUid,
    required this.initialProfile,
    required this.currentLocation,
    required this.firestoreService,
    required this.safetyService,
    required this.profileInsightService,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  late UserProfile _profile = widget.initialProfile;
  bool _loading = false;
  bool _blocked = false;
  Future<ProfileInsight>? _profileInsightFuture;
  String? _profileInsightKey;

  @override
  void initState() {
    super.initState();
    _loadProfileInsight(_profile);
    _refreshProfile();
  }

  Future<void> _refreshProfile() async {
    setState(() => _loading = true);
    try {
      final latest = await widget.firestoreService.getUserProfile(
        widget.initialProfile.uid,
      );
      if (latest != null && mounted) {
        setState(() => _profile = latest);
        _loadProfileInsight(latest);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _loadProfileInsight(UserProfile profile, {bool refresh = false}) {
    final inputHash = widget.profileInsightService.inputHashForProfile(profile);
    final key = refresh
        ? '${profile.uid}:$inputHash:${DateTime.now().microsecondsSinceEpoch}'
        : '${profile.uid}:$inputHash';
    if (!refresh && _profileInsightKey == key) return;
    setState(() {
      _profileInsightKey = key;
      _profileInsightFuture = widget.profileInsightService.getProfileInsight(
        profile: profile,
        refresh: refresh,
      );
    });
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
      _debugLog('[Safety] 프로필 신고 실패 uid=${_profile.uid} error=$e');
      if (mounted) _showSnack('신고에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> _blockUser() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('차단하기'),
        content: const Text('차단하면 서로 디스커버리, 매칭, 채팅에서 볼 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.surface,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('차단'),
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
      _debugLog('[Safety] 프로필 차단 실패 uid=${_profile.uid} error=$e');
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
    final distance = LocationService.distanceBetween(
      widget.currentLocation,
      _profile.location,
    );
    final distanceLabel = distance == null
        ? null
        : LocationService.formatDistance(distance);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          _profile.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: AppColors.background,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'report') _reportUser();
              if (value == 'block') _blockUser();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'report', child: Text('신고하기')),
              PopupMenuItem(value: 'block', child: Text('차단하기')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshProfile,
        child: ListView(
          children: [
            _PhotoGallery(
              profile: _profile,
              distanceLabel: distanceLabel,
              blocked: _blocked,
              loading: _loading,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  const SizedBox(height: 22),
                  _DetailGrid(profile: _profile),
                  _TagSection(
                    title: '관심사',
                    labels: ProfileOptions.keysToLabels(
                      ProfileOptions.interests,
                      _profile.interests,
                    ),
                  ),
                  _TagSection(
                    title: '성향',
                    labels: ProfileOptions.keysToLabels(
                      ProfileOptions.personalities,
                      _profile.personalityTags,
                    ),
                  ),
                  _TagSection(
                    title: '이상형',
                    labels: ProfileOptions.keysToLabels(
                      ProfileOptions.ideals,
                      _profile.idealTags,
                    ),
                  ),
                  if (_profile.relationshipGoal != null)
                    _InfoSection(
                      title: '찾는 관계',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.favorite_rounded,
                            size: 15,
                            color: AppColors.matchPrimary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              ProfileOptions.keyToLabel(
                                    ProfileOptions.relationshipGoals,
                                    _profile.relationshipGoal!,
                                  ) ??
                                  _profile.relationshipGoal!,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  _ProfileInsightSection(
                    future: _profileInsightFuture,
                    onRetry: () => _loadProfileInsight(_profile, refresh: true),
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

class _ProfileInsightSection extends StatelessWidget {
  final Future<ProfileInsight>? future;
  final VoidCallback onRetry;

  const _ProfileInsightSection({required this.future, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final currentFuture = future;
    if (currentFuture == null) return const SizedBox.shrink();

    return FutureBuilder<ProfileInsight>(
      future: currentFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _ProfileInsightShell(child: _ProfileInsightLoading());
        }
        final insight = snap.data;
        if (snap.hasError || insight == null || !insight.isComplete) {
          return _ProfileInsightShell(
            child: _ProfileInsightError(onRetry: onRetry),
          );
        }
        return _ProfileInsightShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InsightItem(
                icon: Icons.auto_awesome_rounded,
                label: '첫인상',
                text: insight.firstImpression,
              ),
              const SizedBox(height: 14),
              _InsightItem(
                icon: Icons.chat_bubble_rounded,
                label: '대화 스타일',
                text: insight.conversationStyle,
              ),
              const SizedBox(height: 14),
              _InsightItem(
                icon: Icons.spa_rounded,
                label: '분위기',
                text: insight.atmosphere,
              ),
              const SizedBox(height: 14),
              _InsightItem(
                icon: Icons.favorite_rounded,
                label: '잘 맞는 사람',
                text: insight.goodMatchType,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ProfileInsightShell extends StatelessWidget {
  final Widget child;

  const _ProfileInsightShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ProfileInsightHeader(),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _ProfileInsightHeader extends StatelessWidget {
  const _ProfileInsightHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.premiumSoft,
            borderRadius: BorderRadius.circular(AppRadius.chip),
            border: Border.all(color: AppColors.premiumBorder),
          ),
          child: const Text(
            'AI PROFILE INSIGHT',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: AppColors.matchPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileInsightLoading extends StatelessWidget {
  const _ProfileInsightLoading();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            '프로필 분위기를 분석하고 있어요',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _ProfileInsightError extends StatelessWidget {
  final VoidCallback onRetry;

  const _ProfileInsightError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '지금은 분석을 불러올 수 없어요',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
      ],
    );
  }
}

class _InsightItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String text;

  const _InsightItem({
    required this.icon,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: Icon(icon, size: 17, color: AppColors.matchPrimary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoGallery extends StatefulWidget {
  final UserProfile profile;
  final String? distanceLabel;
  final bool blocked;
  final bool loading;

  const _PhotoGallery({
    required this.profile,
    required this.distanceLabel,
    required this.blocked,
    required this.loading,
  });

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
        child: SizedBox(
          height: 420,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (photoUrls.isEmpty)
                const ColoredBox(
                  color: AppColors.surfaceElevated,
                  child: Icon(
                    Icons.person_rounded,
                    size: 90,
                    color: AppColors.textMutedOnDark,
                  ),
                )
              else
                PageView.builder(
                  controller: _controller,
                  itemCount: photoUrls.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (_, index) => Image.network(
                    photoUrls[index],
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: AppColors.surfaceElevated,
                      child: Icon(
                        Icons.person_rounded,
                        color: AppColors.textMutedOnDark,
                      ),
                    ),
                  ),
                ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.42, 0.72, 1],
                      colors: [
                        Colors.transparent,
                        Color(0x33000000),
                        Color(0xE6000000),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.profile.displayName}, ${widget.profile.age}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textOnDark,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        PremiumStatusPill(
                          label: _genderLabel(widget.profile.gender),
                          compact: true,
                        ),
                        if (widget.profile.mbti != null)
                          PremiumStatusPill(
                            label: widget.profile.mbti!,
                            compact: true,
                          ),
                        if (widget.distanceLabel != null)
                          PremiumStatusPill(
                            label: widget.distanceLabel!,
                            icon: Icons.near_me_rounded,
                            compact: true,
                          ),
                        if (widget.blocked)
                          const PremiumStatusPill(
                            label: '차단됨',
                            icon: Icons.block_rounded,
                            color: AppColors.danger,
                            compact: true,
                          ),
                      ],
                    ),
                    if (widget.profile.verifications.hasAny) ...[
                      const SizedBox(height: 10),
                      VerificationBadges(
                        verifications: widget.profile.verifications,
                        brightness: Brightness.dark,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.loading)
                const Positioned(
                  top: 18,
                  right: 18,
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.mint,
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
              height: 3,
              margin: EdgeInsets.only(right: index == count - 1 ? 0 : 4),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(
                  alpha: active ? 0.95 : 0.34,
                ),
                borderRadius: BorderRadius.circular(AppRadius.chip),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: AppColors.ink.withValues(alpha: 0.2),
                          blurRadius: 3,
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
  final UserProfile profile;

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

    return _InfoSection(
      title: '상세 정보',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: items
            .map((item) => _InfoPill(label: item.label, value: item.value))
            .toList(),
      ),
    );
  }

  static String _jobText(UserProfile profile) {
    final category = profile.jobCategory == null
        ? null
        : ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions,
            profile.jobCategory!,
          );
    return [?category, ?profile.jobTitle].join(' · ');
  }
}

class _TagSection extends StatelessWidget {
  final String title;
  final List<String> labels;

  const _TagSection({required this.title, required this.labels});

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    return _InfoSection(
      title: title,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: labels.map((label) => _TagChip(label: label)).toList(),
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _InfoSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
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

class _InfoPill extends StatelessWidget {
  final String label;
  final String value;

  const _InfoPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        '$label · $value',
        style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;

  const _TagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
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
