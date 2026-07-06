import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/charm/charm_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/safety/safety_service.dart';
import '../../services/storage/storage_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/primary_button.dart';
import '../auth/phone_login_screen.dart';
import '../charm/charm_report_screen.dart';
import '../jelly/jelly_shop_screen.dart';
import '../profile/profile_edit_screen.dart';
import '../profile/widgets/verification_badge.dart';
import '../safety/blocked_users_screen.dart';

/// 홈 화면 — 내 프로필을 카드 형태로 표시한다 (M2.5).
///
/// M2.5에서 표시되는 정보:
/// - 사진 갤러리 (PageView, 여러 장이면 좌우 스와이프)
/// - 이름·나이·성별·한줄 소개
/// - 상세 정보 (키·MBTI·종교·흡연·음주·학력)
/// - 관심사·성향·이상형 태그 칩
/// - 찾는 관계
/// - 프로필 편집 / 로그아웃 버튼
class HomeScreen extends StatefulWidget {
  final AuthService authService;
  final FirestoreService firestoreService;
  final StorageService storageService;
  final CharmService charmService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final SafetyService safetyService;

  const HomeScreen({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.storageService,
    required this.charmService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.safetyService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  UserProfile? _profile;
  bool _loading = true;
  bool _verificationLoading = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    final profile = await widget.firestoreService.getUserProfile(uid);
    final synced = profile == null
        ? null
        : await _syncEmailVerification(profile);
    if (mounted) {
      setState(() {
        _profile = synced;
        _loading = false;
      });
    }
  }

  Future<UserProfile> _syncEmailVerification(UserProfile profile) async {
    await widget.authService.reloadUser();
    final syncedVerifications = profile.verifications.copyWith(
      email: widget.authService.isEmailVerified,
    );
    if (syncedVerifications.email != profile.verifications.email) {
      await widget.firestoreService.updateUserVerifications(
        profile.uid,
        syncedVerifications,
      );
    }
    return profile.copyWith(verifications: syncedVerifications);
  }

  Future<void> _sendEmailVerification() async {
    setState(() => _verificationLoading = true);
    try {
      await widget.authService.sendEmailVerification();
      if (!mounted) return;
      _showSnack('인증 메일을 보냈어요. 메일함의 링크를 눌러주세요.');
    } on AuthFailure catch (e) {
      if (mounted) _showSnack(e.message);
    } finally {
      if (mounted) setState(() => _verificationLoading = false);
    }
  }

  Future<void> _refreshEmailVerification() async {
    final profile = _profile;
    if (profile == null) return;
    setState(() => _verificationLoading = true);
    try {
      final synced = await _syncEmailVerification(profile);
      if (!mounted) return;
      setState(() => _profile = synced);
      _showSnack(
        synced.verifications.email ? '이메일 인증이 확인됐어요.' : '아직 이메일 인증 전이에요.',
      );
    } finally {
      if (mounted) setState(() => _verificationLoading = false);
    }
  }

  Future<void> _openPhoneVerification() async {
    final profile = _profile;
    if (profile == null || profile.verifications.phone) return;

    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PhoneLoginScreen(
          authService: widget.authService,
          linkToCurrentUser: true,
          onVerificationCompleted: _markPhoneVerified,
        ),
      ),
    );
    if (!mounted) return;
    if (completed == true) {
      _showSnack('전화 인증이 완료됐어요.');
    }
  }

  Future<void> _markPhoneVerified() async {
    final profile = _profile;
    if (profile == null) return;
    final synced = profile.verifications.copyWith(phone: true);
    await widget.firestoreService.updateUserVerifications(profile.uid, synced);
    if (!mounted) return;
    setState(() => _profile = profile.copyWith(verifications: synced));
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleSignOut() async {
    try {
      await widget.authService.signOut();
    } on AuthFailure catch (e) {
      if (mounted) {
        _showSnack(e.message);
      }
    }
  }

  /// 프로필 편집 화면으로 이동하고, 돌아올 때 최신 프로필을 반영한다.
  Future<void> _openEditScreen() async {
    final profile = _profile;
    if (profile == null) return;

    final updated = await Navigator.push<UserProfile>(
      context,
      MaterialPageRoute(
        builder: (ctx) => ProfileEditScreen(
          profile: profile,
          firestoreService: widget.firestoreService,
          storageService: widget.storageService,
        ),
      ),
    );
    // 저장된 경우 재조회 없이 반영
    if (updated != null && mounted) {
      setState(() => _profile = updated);
    }
  }

  Future<void> _openBlockedUsers() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BlockedUsersScreen(
          currentUid: uid,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  Future<void> _openCharmReport() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CharmReportScreen(
          currentUid: uid,
          charmService: widget.charmService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: LoadingIndicator());
    }

    final profile = _profile;
    if (profile == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('프로필을 불러올 수 없습니다.'),
              const SizedBox(height: 16),
              TextButton(onPressed: _loadProfile, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('내 프로필'),
        actions: [
          JellyBalanceButton(
            currentUid: profile.uid,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '프로필 편집',
            onPressed: _openEditScreen,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 사진 갤러리 ─────────────────────────────────────────────
            _PhotoGallery(photoUrls: profile.photoUrls),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── 이름·나이·성별 ──────────────────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          '${profile.displayName}, ${profile.age}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _Badge(label: _genderLabel(profile.gender)),
                      if (profile.mbti != null) ...[
                        const SizedBox(width: 6),
                        _Badge(
                          label: profile.mbti!,
                          color: AppColors.secondary.withValues(alpha: 0.12),
                          textColor: AppColors.secondary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),

                  // ── 한줄 소개 ────────────────────────────────────────
                  if (profile.bio.isNotEmpty)
                    Text(
                      profile.bio,
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  const SizedBox(height: 20),

                  _VerificationSection(
                    verifications: profile.verifications,
                    loading: _verificationLoading,
                    onSendEmail: _sendEmailVerification,
                    onRefreshEmail: _refreshEmailVerification,
                    onVerifyPhone: _openPhoneVerification,
                  ),
                  const SizedBox(height: 24),

                  // ── 상세 정보 칩 ─────────────────────────────────────
                  if (_hasDetailInfo(profile)) ...[
                    _DetailInfoRow(profile: profile),
                    const SizedBox(height: 24),
                  ],

                  // ── 찾는 관계 ────────────────────────────────────────
                  if (profile.relationshipGoal != null) ...[
                    _SectionTitle(title: '찾는 관계'),
                    const SizedBox(height: 8),
                    _Badge(
                      label:
                          ProfileOptions.keyToLabel(
                            ProfileOptions.relationshipGoals,
                            profile.relationshipGoal!,
                          ) ??
                          '',
                      color: AppColors.primary.withValues(alpha: 0.1),
                      textColor: AppColors.primary,
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── 관심사 태그 ──────────────────────────────────────
                  if (profile.interests.isNotEmpty) ...[
                    _SectionTitle(title: '관심사'),
                    const SizedBox(height: 8),
                    _TagWrap(
                      keys: profile.interests,
                      options: ProfileOptions.interests,
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── 성향 태그 ────────────────────────────────────────
                  if (profile.personalityTags.isNotEmpty) ...[
                    _SectionTitle(title: '나를 표현하는 키워드'),
                    const SizedBox(height: 8),
                    _TagWrap(
                      keys: profile.personalityTags,
                      options: ProfileOptions.personalities,
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── 이상형 태그 ──────────────────────────────────────
                  if (profile.idealTags.isNotEmpty) ...[
                    _SectionTitle(title: '이런 친구를 원해요'),
                    const SizedBox(height: 8),
                    _TagWrap(
                      keys: profile.idealTags,
                      options: ProfileOptions.ideals,
                    ),
                    const SizedBox(height: 24),
                  ],

                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: '내 매력 리포트',
                    icon: const Icon(Icons.auto_awesome_rounded, size: 20),
                    onPressed: _openCharmReport,
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(label: '프로필 편집', onPressed: _openEditScreen),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: '차단 목록 관리',
                    outlined: true,
                    onPressed: _openBlockedUsers,
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: '로그아웃',
                    outlined: true,
                    onPressed: _handleSignOut,
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _hasDetailInfo(UserProfile p) =>
      p.height != null ||
      p.religion != null ||
      p.smoking != null ||
      p.drinking != null ||
      p.education != null ||
      p.jobCategory != null ||
      (p.jobTitle != null && p.jobTitle!.isNotEmpty);

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
}

// ── 내부 위젯 ──────────────────────────────────────────────────────────────────

/// 사진 PageView — 여러 장이면 좌우 스와이프, 1장이면 정적 표시.
class _PhotoGallery extends StatefulWidget {
  final List<String> photoUrls;
  const _PhotoGallery({required this.photoUrls});

  @override
  State<_PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<_PhotoGallery> {
  int _currentPage = 0;

  @override
  Widget build(BuildContext context) {
    final urls = widget.photoUrls;
    final height = MediaQuery.of(context).size.width; // 정사각형 갤러리

    if (urls.isEmpty) {
      return Container(
        height: height,
        color: AppColors.surface,
        child: const Icon(
          Icons.person,
          size: 80,
          color: AppColors.textSecondary,
        ),
      );
    }

    return Stack(
      children: [
        SizedBox(
          height: height,
          child: PageView.builder(
            itemCount: urls.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (ctx, i) => Image.network(
              urls[i],
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: AppColors.surface,
                child: const Icon(
                  Icons.broken_image,
                  size: 60,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        // 도트 인디케이터 — 사진이 2장 이상일 때만 표시
        if (urls.length > 1)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(urls.length, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active ? Colors.white : Colors.white54,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}

class _VerificationSection extends StatelessWidget {
  final VerificationStatus verifications;
  final bool loading;
  final VoidCallback onSendEmail;
  final VoidCallback onRefreshEmail;
  final VoidCallback onVerifyPhone;

  const _VerificationSection({
    required this.verifications,
    required this.loading,
    required this.onSendEmail,
    required this.onRefreshEmail,
    required this.onVerifyPhone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '인증 현황',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          VerificationBadges(
            verifications: verifications,
            showUnverified: true,
          ),
          const SizedBox(height: 12),
          if (!verifications.email) ...[
            const Text(
              '이메일 인증을 완료하면 프로필에 신뢰 배지가 표시돼요.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: loading ? null : onSendEmail,
                  icon: const Icon(Icons.mark_email_unread_outlined, size: 17),
                  label: const Text('이메일 인증하기'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: loading ? null : onRefreshEmail,
                  icon: loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('인증 확인'),
                ),
              ],
            ),
          ],
          if (!verifications.phone) ...[
            if (!verifications.email) const SizedBox(height: 14),
            const Text(
              '전화번호 인증을 완료하면 상대에게 더 신뢰감 있게 보여요.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onVerifyPhone,
              icon: const Icon(Icons.phone_iphone_rounded, size: 17),
              label: const Text('전화 인증하기'),
            ),
          ],
          if (verifications.email && verifications.phone)
            const Text(
              '사진 인증은 다음 단계에서 연결할 수 있게 자리만 준비해뒀어요.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
        ],
      ),
    );
  }
}

/// 상세 정보를 아이콘+값 칩으로 표시하는 행.
class _DetailInfoRow extends StatelessWidget {
  final UserProfile profile;
  const _DetailInfoRow({required this.profile});

  @override
  Widget build(BuildContext context) {
    final items = <_DetailItem>[];

    if (profile.height != null) {
      items.add(_DetailItem(icon: '📏', label: '${profile.height}cm'));
    }
    if (profile.religion != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.religions,
        profile.religion!,
      );
      if (label != null) items.add(_DetailItem(icon: '🙏', label: label));
    }
    if (profile.smoking != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.smokingOptions,
        profile.smoking!,
      );
      if (label != null) items.add(_DetailItem(icon: '🚬', label: label));
    }
    if (profile.drinking != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.drinkingOptions,
        profile.drinking!,
      );
      if (label != null) items.add(_DetailItem(icon: '🍺', label: label));
    }
    if (profile.education != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.educationOptions,
        profile.education!,
      );
      if (label != null) items.add(_DetailItem(icon: '🎓', label: label));
    }
    // 직업: "카테고리 · 세부직업명" 형태로 표시 (카테고리만 있어도 표시)
    final catLabel = profile.jobCategory != null
        ? ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions,
            profile.jobCategory!,
          )
        : null;
    final catName = catLabel != null
        ? (catLabel.contains(' ')
              ? catLabel.substring(catLabel.indexOf(' ') + 1)
              : catLabel)
        : null;
    final jobParts = [
      ?catName,
      if (profile.jobTitle != null && profile.jobTitle!.isNotEmpty)
        profile.jobTitle!,
    ];
    if (jobParts.isNotEmpty) {
      items.add(_DetailItem(icon: '💼', label: jobParts.join(' · ')));
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items
          .map((item) => _DetailChip(icon: item.icon, label: item.label))
          .toList(),
    );
  }
}

class _DetailItem {
  final String icon;
  final String label;
  const _DetailItem({required this.icon, required this.label});
}

class _DetailChip extends StatelessWidget {
  final String icon;
  final String label;
  const _DetailChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// 태그 key 목록 → label → Wrap 칩 표시.
class _TagWrap extends StatelessWidget {
  final List<String> keys;
  final List<TagOption> options;

  const _TagWrap({required this.keys, required this.options});

  @override
  Widget build(BuildContext context) {
    final labels = ProfileOptions.keysToLabels(options, keys);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: labels
          .map(
            (label) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color? color;
  final Color? textColor;

  const _Badge({required this.label, this.color, this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: textColor ?? AppColors.textSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
