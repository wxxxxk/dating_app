import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/match_model.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/ideal_type/ideal_type_service.dart';
import '../../services/matches/matches_service.dart';
import 'fortune_route_names.dart';
import 'fortune_history_screen.dart';
import '../ideal_type/ideal_type_screen.dart';
import 'my_fortune_screen.dart';

/// 사주 탭 허브 화면 (하단 내비 3번째 탭).
///
/// 사주 관련 기능을 한 곳에 모은다:
/// - 오늘의 운세(애정 중심, 매일 갱신)
/// - 내 사주 요약 → 탭하면 [MyFortuneScreen] 상세로
/// - 매칭된 상대와 궁합 보기 → 서버 공개 API 재설계 전까지 안내만 표시
///
/// 사주는 매칭 로직을 지배하지 않는 독립 코너다 — 여기서 매칭 순서를 바꾸거나
/// 스와이프 카드에 궁합 힌트를 얹지 않는다(의도적 제외).
class FortuneHubScreen extends StatefulWidget {
  final AuthService authService;
  final FirestoreService firestoreService;
  final MatchesService matchesService;
  final FortuneService fortuneService;

  /// "새로운 인연을 만나보세요" CTA 탭 시 둘러보기 탭으로 전환한다.
  final VoidCallback onExploreTap;

  const FortuneHubScreen({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.matchesService,
    required this.fortuneService,
    required this.onExploreTap,
  });

  @override
  State<FortuneHubScreen> createState() => _FortuneHubScreenState();
}

class _FortuneHubScreenState extends State<FortuneHubScreen> {
  bool _loading = true;
  String? _error;

  UserProfile? _profile;
  ZodiacInfo? _zodiac;
  SajuInfo? _saju;
  DailyFortune? _daily;
  final _idealTypeService = IdealTypeService();

  Stream<List<MatchWithProfile>>? _matchesStream;

  Future<T?> _pushFortuneDetail<T>({
    required String routeName,
    required WidgetBuilder builder,
  }) {
    // 사주 상세 라우트가 중간에 남으면 pop 전환 중 내 사주 화면이 비칠 수 있다.
    // 항상 루트(MainShell) 바로 위에 현재 상세 화면만 쌓아 깜빡임을 막는다.
    return Navigator.of(context).pushAndRemoveUntil<T>(
      MaterialPageRoute<T>(
        settings: RouteSettings(name: routeName),
        builder: builder,
      ),
      (route) => route.isFirst,
    );
  }

  @override
  void initState() {
    super.initState();
    final uid = widget.authService.currentUser?.uid;
    if (uid != null) {
      _matchesStream = widget.matchesService.watchMatches(currentUid: uid);
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uid = widget.authService.currentUser?.uid;
      if (uid == null) throw StateError('로그인이 필요합니다.');

      final profile = await widget.firestoreService.getUserProfile(uid);
      if (profile == null) throw StateError('프로필을 찾을 수 없습니다.');

      final zodiac = FortuneCalculator.getZodiacSign(profile.birthDate);
      final saju = FortuneCalculator.getSaju(profile.birthDate);
      final daily = await widget.fortuneService.getDailyFortune(
        uid: uid,
        zodiac: zodiac,
        saju: saju,
      );

      if (mounted) {
        setState(() {
          _profile = profile;
          _zodiac = zodiac;
          _saju = saju;
          _daily = daily;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openMyFortune() {
    final profile = _profile;
    if (profile == null) return;
    _pushFortuneDetail<void>(
      routeName: FortuneRouteNames.my,
      builder: (_) => MyFortuneScreen(
        profile: profile,
        fortuneService: widget.fortuneService,
      ),
    );
  }

  void _openFortuneHistory() {
    final profile = _profile;
    if (profile == null) return;
    _pushFortuneDetail<void>(
      routeName: FortuneRouteNames.history,
      builder: (_) => FortuneHistoryScreen(
        profile: profile,
        fortuneService: widget.fortuneService,
      ),
    );
  }

  void _openIdealType() {
    final profile = _profile;
    if (profile == null) return;
    _pushFortuneDetail<void>(
      routeName: FortuneRouteNames.idealType,
      builder: (_) => IdealTypeScreen(
        profile: profile,
        idealTypeService: _idealTypeService,
      ),
    );
  }

  void _openMatchFortune(MatchWithProfile _) {
    // TODO(Phase 0-B follow-up): move compatibility calculation behind an authenticated server API that accepts targetUid without exposing target birth data.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('궁합 기능은 서버 공개 API 연결 후 다시 제공할게요.')),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('사주', style: TextStyle(fontWeight: FontWeight.bold)),
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
                '사주 정보를 불러오지 못했어요\n$_error',
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

    final daily = _daily;
    final zodiac = _zodiac;
    final saju = _saju;
    if (daily == null || zodiac == null || saju == null) {
      return const SizedBox.shrink();
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        40 + MediaQuery.of(context).padding.bottom,
      ),
      children: [
        _DailyFortuneCard(daily: daily),
        const SizedBox(height: 12),
        _HistoryEntryCard(onTap: _openFortuneHistory),
        const SizedBox(height: 12),
        _IdealTypeEntryCard(onTap: _openIdealType),
        const SizedBox(height: 20),
        _MyFortuneSummaryCard(
          zodiac: zodiac,
          saju: saju,
          onTap: _openMyFortune,
        ),
        const SizedBox(height: 24),
        const _SectionTitle(title: '궁합 준비 중'),
        const SizedBox(height: 10),
        _MatchFortuneSection(
          matchesStream: _matchesStream,
          onTapMatch: _openMatchFortune,
        ),
        const SizedBox(height: 28),
        // 둘러보기(Discovery)로 보내는 매칭 CTA라 fortuneAccent가 아니라
        // matchPrimary(mintDeep)로 스타일한다. 앱 공통 secondary CTA(white/cream
        // + mintDeep border + text)와 같은 높이/radius로 맞춘다.
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton(
            onPressed: widget.onExploreTap,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.matchPrimary,
              side: const BorderSide(color: AppColors.matchPrimary),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
              ),
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            child: const Text('새로운 인연을 만나보세요'),
          ),
        ),
      ],
    );
  }
}

/// 오늘의 운세 카드 (애정 중심).
class _DailyFortuneCard extends StatelessWidget {
  final DailyFortune daily;
  const _DailyFortuneCard({required this.daily});

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateLabel =
        '${now.month}월 ${now.day}일 (${_weekdays[now.weekday - 1]})';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.seal.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$dateLabel의 애정운',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                children: List.generate(5, (i) {
                  final filled = i < daily.loveScore;
                  return Icon(
                    filled
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 15,
                    color: filled ? AppColors.seal : AppColors.border,
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            daily.mood,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            daily.message,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textPrimary,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.seal.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.tips_and_updates_rounded,
                  size: 16,
                  color: AppColors.seal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    daily.advice,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryEntryCard extends StatelessWidget {
  final VoidCallback onTap;

  const _HistoryEntryCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: AppColors.fortuneAccent.withValues(alpha: 0.12),
          ),
        ),
        child: const Row(
          children: [
            Icon(
              Icons.timeline_rounded,
              color: AppColors.fortuneAccent,
              size: 26,
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '운세 기록 보기',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '최근 7일 애정운 흐름을 확인해요',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _IdealTypeEntryCard extends StatelessWidget {
  final VoidCallback onTap;

  const _IdealTypeEntryCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    // 사주/궁합 카드는 절제된 회색 accent를 쓰지만, AI 이상형은 이 허브의
    // 대표 프리미엄 기능이라 premium accent로 눈에 띄게 구분한다.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.premiumSoft,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.premiumBorder),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.premium,
              size: 26,
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI 이상형 만들기',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '가상의 이상형 이미지를 생성해요',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.premium),
          ],
        ),
      ),
    );
  }
}

/// "내 사주" 요약 카드 — 탭하면 [MyFortuneScreen] 상세로 이동.
class _MyFortuneSummaryCard extends StatelessWidget {
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  final VoidCallback onTap;

  const _MyFortuneSummaryCard({
    required this.zodiac,
    required this.saju,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: AppColors.fortuneAccent.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          children: [
            // 사주/궁합 카드 계열은 fortuneAccent로 통일해, 초록색
            // AI 이상형 카드와 시각적으로 구분되는 "사주 가족"을 만든다.
            const Icon(
              Icons.auto_awesome_rounded,
              size: 28,
              color: AppColors.fortuneAccent,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '내 사주',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${zodiac.sign} · 오행 ${saju.element}(일간 ${saju.dayMaster})',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
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

/// 매칭된 상대 목록. 궁합 상세는 서버 공개 API 재설계 전까지 임시 중단한다.
class _MatchFortuneSection extends StatelessWidget {
  final Stream<List<MatchWithProfile>>? matchesStream;
  final ValueChanged<MatchWithProfile> onTapMatch;

  const _MatchFortuneSection({
    required this.matchesStream,
    required this.onTapMatch,
  });

  @override
  Widget build(BuildContext context) {
    final stream = matchesStream;
    if (stream == null) return const SizedBox.shrink();

    return StreamBuilder<List<MatchWithProfile>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final matches = snap.data ?? [];
        if (matches.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: const Text(
              '서버 공개 API 연결 후 매칭된 상대와 궁합을 볼 수 있어요',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          );
        }

        return Column(
          children: matches
              .map(
                (mwp) =>
                    _MatchFortuneTile(mwp: mwp, onTap: () => onTapMatch(mwp)),
              )
              .toList(),
        );
      },
    );
  }
}

class _MatchFortuneTile extends StatelessWidget {
  final MatchWithProfile mwp;
  final VoidCallback onTap;
  const _MatchFortuneTile({required this.mwp, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final profile = mwp.otherProfile;
    final photoUrl = profile.photoUrls.isNotEmpty ? profile.photoUrls[0] : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      elevation: 0,
      color: AppColors.surface,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: CircleAvatar(
          radius: 24,
          backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
          backgroundColor: AppColors.border,
          child: photoUrl == null
              ? const Icon(Icons.person_rounded, color: AppColors.textSecondary)
              : null,
        ),
        title: Text(
          '${profile.displayName}, ${profile.age}',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        subtitle: const Text(
          '서버 공개 API 연결 후 제공 예정',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        trailing: const Icon(
          Icons.auto_awesome_rounded,
          color: AppColors.fortuneAccent,
        ),
        onTap: onTap,
      ),
    );
  }
}
