import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/location/location_service.dart';
import '../../services/safety/safety_service.dart';
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
  late UserProfile _profile = widget.initialProfile;
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
      final latest = await widget.firestoreService.getUserProfile(
        widget.initialProfile.uid,
      );
      if (latest != null && mounted) setState(() => _profile = latest);
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
      if (mounted) _showSnack('신고에 실패했어요: $e');
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
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
      if (mounted) _showSnack('차단에 실패했어요: $e');
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
        title: Text(_profile.displayName),
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
            _PhotoGallery(photoUrls: _profile.photoUrls),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '${_profile.displayName}, ${_profile.age}',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (_loading)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Badge(label: _genderLabel(_profile.gender)),
                      if (_profile.mbti != null) _Badge(label: _profile.mbti!),
                      if (distanceLabel != null) _Badge(label: distanceLabel),
                      if (_blocked) _Badge(label: '차단됨', danger: true),
                    ],
                  ),
                  if (_profile.verifications.hasAny) ...[
                    const SizedBox(height: 12),
                    VerificationBadges(verifications: _profile.verifications),
                  ],
                  if (_profile.bio.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      _profile.bio,
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
                      child: Text(
                        ProfileOptions.keyToLabel(
                              ProfileOptions.relationshipGoals,
                              _profile.relationshipGoal!,
                            ) ??
                            _profile.relationshipGoal!,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.textPrimary,
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

class _PhotoGallery extends StatelessWidget {
  final List<String> photoUrls;

  const _PhotoGallery({required this.photoUrls});

  @override
  Widget build(BuildContext context) {
    if (photoUrls.isEmpty) {
      return Container(
        height: 420,
        color: AppColors.surface,
        child: const Icon(
          Icons.person,
          size: 90,
          color: AppColors.textSecondary,
        ),
      );
    }
    return SizedBox(
      height: 420,
      child: PageView(
        children: photoUrls
            .map(
              (url) => Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.surface,
                  child: Icon(Icons.person, color: AppColors.textSecondary),
                ),
              ),
            )
            .toList(),
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
        borderRadius: BorderRadius.circular(8),
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
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final bool danger;

  const _Badge({required this.label, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
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
