import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_party.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/party_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../../../shared/widgets/app_components.dart';
import '../community_audience_filter.dart';
import 'party_compose_screen.dart';
import 'party_detail_screen.dart';
import 'party_widgets.dart';

/// Party·Square 화면(Phase 4-4).
///
/// - **스퀘어**: 로그인 사용자가 공개 파티를 탐색한다.
/// - **내 파티**: 내가 만든 파티 / 참여 중 / 승인 대기를 관리한다.
///
/// 두 탭은 같은 파티 모델을 쓴다. Square 목록에서는 차단·지인 피하기 관계인
/// 호스트의 파티를 표시만 건너뛰고(본인 파티는 유지), 실제 참여 차단은 서버가
/// 다시 판정한다.
class PartySquareScreen extends StatefulWidget {
  final AuthService authService;
  final PartyService partyService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const PartySquareScreen({
    super.key,
    required this.authService,
    required this.partyService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<PartySquareScreen> createState() => _PartySquareScreenState();
}

class _PartySquareScreenState extends State<PartySquareScreen> {
  /// stream error 재시도를 위해 다시 구독할 수 있어야 하므로 final이 아니다.
  late Stream<List<CommunityParty>> _squareStream = widget.partyService
      .watchSquareParties();
  late final Stream<List<CommunityPartyMembership>> _myPartiesStream = widget
      .partyService
      .watchMyMemberships(uid: _currentUid ?? '');

  late final CommunityAudienceFilter _audience = CommunityAudienceFilter(
    safetyService: widget.safetyService,
    contactAvoidanceService: widget.contactAvoidanceService,
  );

  @override
  void initState() {
    super.initState();
    _audience.start(
      uid: _currentUid,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _audience.dispose();
    super.dispose();
  }

  String? get _currentUid => widget.authService.currentUser?.uid;

  void _retrySquare() {
    setState(() {
      _squareStream = widget.partyService.watchSquareParties();
    });
  }

  void _openDetail(String partyId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartyDetailScreen(
          partyId: partyId,
          authService: widget.authService,
          partyService: widget.partyService,
          safetyService: widget.safetyService,
          contactAvoidanceService: widget.contactAvoidanceService,
        ),
      ),
    );
  }

  Future<void> _openCompose() async {
    final partyId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PartyComposeScreen(partyService: widget.partyService),
      ),
    );
    if (partyId == null || !mounted) return;
    _openDetail(partyId);
  }

  @override
  Widget build(BuildContext context) {
    // FAB가 마지막 파티 카드를 가리지 않도록 확장 FAB 높이 + 여백 + 시스템
    // 하단 인셋을 합쳐 리스트 아래 여백을 만든다.
    final listBottomPadding = 84 + MediaQuery.of(context).padding.bottom;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: const ValueKey('party-square-screen'),
        backgroundColor: AppColors.warmCanvas,
        appBar: AppBar(
          backgroundColor: AppColors.warmCanvas,
          surfaceTintColor: AppColors.warmCanvas,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text('파티·스퀘어', style: AppTextStyles.cardTitle),
          bottom: const TabBar(
            labelColor: AppColors.textStrong,
            unselectedLabelColor: AppColors.textMuted,
            indicatorColor: AppColors.brandPrimaryStrong,
            indicatorWeight: 2.5,
            labelStyle: TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
            tabs: [
              Tab(key: ValueKey('party-tab-square'), text: '스퀘어'),
              Tab(key: ValueKey('party-tab-mine'), text: '내 파티'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('party-compose-fab'),
          onPressed: _openCompose,
          backgroundColor: AppColors.brandPrimaryStrong,
          foregroundColor: AppColors.onBrandPrimary,
          elevation: 2,
          highlightElevation: 3,
          icon: const Icon(Icons.add_rounded, size: 20),
          label: const Text(
            '파티 열기',
            style: TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildSquareTab(listBottomPadding),
              _buildMyPartiesTab(listBottomPadding),
            ],
          ),
        ),
      ),
    );
  }

  // ── 스퀘어 ──────────────────────────────────────────────────────────────

  Widget _buildSquareTab(double bottomPadding) {
    final uid = _currentUid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PartyHeader(),
        Expanded(
          child: StreamBuilder<List<CommunityParty>>(
            stream: _squareStream,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const _PartySkeletonList(
                  key: ValueKey('party-square-loading'),
                );
              }
              if (snap.hasError) {
                return _PartyErrorState(
                  message: '파티 목록을 불러오지 못했어요.',
                  retryKey: const ValueKey('party-square-retry'),
                  onRetry: _retrySquare,
                );
              }

              // 차단·지인 피하기 호스트는 표시만 건너뛴다. 본인 파티는 유지한다.
              final parties = (snap.data ?? const <CommunityParty>[])
                  .where(
                    (party) => !_audience.isExcluded(
                      authorUid: party.hostUid,
                      selfUid: uid,
                    ),
                  )
                  .toList();

              if (parties.isEmpty) {
                return const _PartyEmptyState(
                  emptyKey: ValueKey('party-square-empty'),
                  message: '아직 참여할 수 있는 파티가 없어요.',
                );
              }

              return ListView.separated(
                key: const ValueKey('party-square-list'),
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.screenH,
                  AppSpacing.xs,
                  AppSpacing.screenH,
                  bottomPadding,
                ),
                itemCount: parties.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.md),
                itemBuilder: (context, index) {
                  final party = parties[index];
                  return PartyCard(
                    party: party,
                    onTap: () => _openDetail(party.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ── 내 파티 ─────────────────────────────────────────────────────────────

  Widget _buildMyPartiesTab(double bottomPadding) {
    return StreamBuilder<List<CommunityPartyMembership>>(
      stream: _myPartiesStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const _PartySkeletonList(key: ValueKey('party-mine-loading'));
        }
        if (snap.hasError) {
          return const _PartyErrorState(
            errorKey: ValueKey('party-mine-error'),
            message: '내 파티를 불러오지 못했어요.',
          );
        }

        final memberships = snap.data ?? const <CommunityPartyMembership>[];
        if (memberships.isEmpty) {
          return const _PartyEmptyState(
            emptyKey: ValueKey('party-mine-empty'),
            message: '아직 참여 중이거나 만든 파티가 없어요.',
          );
        }

        final hosted = memberships.where((m) => m.isHost).toList();
        final joined = memberships
            .where((m) => !m.isHost && !m.isPending)
            .toList();
        final pending = memberships.where((m) => m.isPending).toList();

        return ListView(
          key: const ValueKey('party-mine-list'),
          padding: EdgeInsets.fromLTRB(
            AppSpacing.screenH,
            AppSpacing.lg,
            AppSpacing.screenH,
            bottomPadding,
          ),
          children: [
            if (hosted.isNotEmpty)
              _MembershipSection(
                sectionKey: 'party-mine-hosted',
                title: '내가 만든 파티',
                memberships: hosted,
                partyService: widget.partyService,
                onTap: _openDetail,
              ),
            if (joined.isNotEmpty)
              _MembershipSection(
                sectionKey: 'party-mine-joined',
                title: '참여 중',
                memberships: joined,
                partyService: widget.partyService,
                onTap: _openDetail,
              ),
            if (pending.isNotEmpty)
              _MembershipSection(
                sectionKey: 'party-mine-pending',
                title: '승인 대기',
                memberships: pending,
                partyService: widget.partyService,
                onTap: _openDetail,
              ),
          ],
        );
      },
    );
  }
}

/// 스퀘어 탭 위 compact header. 사진·가짜 프로필 없이 모임 motif만 얹는다.
class _PartyHeader extends StatelessWidget {
  const _PartyHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.md,
        AppSpacing.screenH,
        AppSpacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '함께 모이는 시간',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.brandPrimaryStrong,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                const Text('어떤 모임에 참여해볼까요?', style: AppTextStyles.sectionTitle),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          const ExcludeSemantics(
            child: IgnorePointer(
              child: SizedBox(width: 60, height: 34, child: _GatheringMotif()),
            ),
          ),
        ],
      ),
    );
  }
}

/// 겹쳐 놓인 세 개의 추상 원 — "사람들이 모인다"는 의미만 형태로 암시한다.
/// 실제 프로필 사진·이름·숫자를 만들지 않는다.
class _GatheringMotif extends StatelessWidget {
  const _GatheringMotif();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned(left: 0, child: _dot(AppColors.brandPrimary, 0.18)),
        Positioned(right: 0, child: _dot(AppColors.expressiveAccent, 0.22)),
        _dot(AppColors.brandPrimary, 0.10, size: 26),
      ],
    );
  }

  Widget _dot(Color color, double alpha, {double size = 22}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: alpha),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
    );
  }
}

/// 목록 자리를 유지하는 skeleton. 이전 목록을 다시 보여주지 않는다.
class _PartySkeletonList extends StatelessWidget {
  const _PartySkeletonList({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.xs,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 3; i++) ...[
          const _PartyCardSkeleton(),
          const SizedBox(height: AppSpacing.md),
        ],
        Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.brandPrimary.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }
}

class _PartyCardSkeleton extends StatelessWidget {
  const _PartyCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SkeletonBox(width: 28, height: 28, radius: 999),
              SizedBox(width: AppSpacing.sm),
              _SkeletonBox(width: 96, height: 12),
              Spacer(),
              _SkeletonBox(width: 52, height: 20, radius: 999),
            ],
          ),
          SizedBox(height: AppSpacing.md),
          _SkeletonBox(height: 15),
          SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _SkeletonBox(width: 84, height: 24, radius: 999),
              SizedBox(width: AppSpacing.sm),
              _SkeletonBox(width: 56, height: 24, radius: 999),
            ],
          ),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const _SkeletonBox({this.width, required this.height, this.radius = 999});

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

/// 아직 파티가 없는 상태. 오류처럼 보이지 않게 모임 motif + 안내만 둔다.
/// 생성 CTA는 FAB가 담당하므로 여기에 버튼을 또 두지 않는다.
class _PartyEmptyState extends StatelessWidget {
  final Key? emptyKey;
  final String message;

  const _PartyEmptyState({this.emptyKey, required this.message});

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: emptyKey,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.xxl,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      children: [
        const ExcludeSemantics(
          child: Center(
            child: SizedBox(width: 96, height: 44, child: _GatheringMotif()),
          ),
        ),
        const SizedBox(height: AppSpacing.lg20),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySecondary,
        ),
      ],
    );
  }
}

/// 목록 오류 안내. raw Firestore 오류는 노출하지 않고 고정 문구만 보여준다.
/// [onRetry]가 있을 때만 다시 시도 버튼을 그린다.
class _PartyErrorState extends StatelessWidget {
  final Key? errorKey;
  final String message;
  final VoidCallback? onRetry;
  final Key? retryKey;

  const _PartyErrorState({
    this.errorKey,
    required this.message,
    this.onRetry,
    this.retryKey,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: errorKey,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.lg,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      children: [
        AppSurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.lg20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.statusDangerSoft,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 22,
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
              if (onRetry != null) ...[
                const SizedBox(height: AppSpacing.lg),
                AppBrandButton(
                  key: retryKey,
                  label: '다시 시도',
                  icon: Icons.refresh_rounded,
                  variant: AppBrandButtonVariant.outline,
                  onPressed: onRetry,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 상태별 내 파티 묶음. partyId 원문은 화면에 표시하지 않는다.
class _MembershipSection extends StatelessWidget {
  final String sectionKey;
  final String title;
  final List<CommunityPartyMembership> memberships;
  final PartyService partyService;
  final ValueChanged<String> onTap;

  const _MembershipSection({
    required this.sectionKey,
    required this.title,
    required this.memberships,
    required this.partyService,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey(sectionKey),
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.label),
          const SizedBox(height: AppSpacing.md),
          for (final membership in memberships) ...[
            _MembershipTile(
              membership: membership,
              partyService: partyService,
              onTap: onTap,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    );
  }
}

/// mirror 문서 하나에 대응하는 파티 카드.
///
/// 파티 본문은 mirror에 복사되지 않으므로 파티 문서를 따로 구독한다. 이미
/// 취소·삭제된 파티는 카드 대신 안내로 바뀐다.
class _MembershipTile extends StatefulWidget {
  final CommunityPartyMembership membership;
  final PartyService partyService;
  final ValueChanged<String> onTap;

  const _MembershipTile({
    required this.membership,
    required this.partyService,
    required this.onTap,
  });

  @override
  State<_MembershipTile> createState() => _MembershipTileState();
}

class _MembershipTileState extends State<_MembershipTile> {
  /// build 안에서 만들면 rebuild마다 재구독된다.
  late final Stream<CommunityParty?> _partyStream = widget.partyService
      .watchParty(widget.membership.partyId);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CommunityParty?>(
      stream: _partyStream,
      builder: (context, snap) {
        final party = snap.hasError ? null : snap.data;
        if (party == null) {
          return const PartyNotice(message: '이 파티는 더 이상 볼 수 없어요.');
        }
        return PartyCard(party: party, onTap: () => widget.onTap(party.id));
      },
    );
  }
}
