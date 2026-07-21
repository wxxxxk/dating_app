import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_party.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/party_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: const ValueKey('party-square-screen'),
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          title: const Text('파티·스퀘어'),
          bottom: const TabBar(
            tabs: [
              Tab(key: ValueKey('party-tab-square'), text: '스퀘어'),
              Tab(key: ValueKey('party-tab-mine'), text: '내 파티'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('party-compose-fab'),
          onPressed: _openCompose,
          icon: const Icon(Icons.add_rounded),
          label: const Text('파티 열기'),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [_buildSquareTab(), _buildMyPartiesTab()],
          ),
        ),
      ),
    );
  }

  // ── 스퀘어 ──────────────────────────────────────────────────────────────

  Widget _buildSquareTab() {
    final uid = _currentUid;
    return StreamBuilder<List<CommunityParty>>(
      stream: _squareStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(
            key: ValueKey('party-square-loading'),
            child: CircularProgressIndicator(),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: PartyNotice(
              message: '파티 목록을 불러오지 못했어요.',
              retryKey: const ValueKey('party-square-retry'),
              onRetry: _retrySquare,
            ),
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
          return const Padding(
            padding: EdgeInsets.all(20),
            child: PartyNotice(
              key: ValueKey('party-square-empty'),
              message: '아직 참여할 수 있는 파티가 없어요.',
            ),
          );
        }

        return ListView.separated(
          key: const ValueKey('party-square-list'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
          itemCount: parties.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final party = parties[index];
            return PartyCard(
              party: party,
              onTap: () => _openDetail(party.id),
            );
          },
        );
      },
    );
  }

  // ── 내 파티 ─────────────────────────────────────────────────────────────

  Widget _buildMyPartiesTab() {
    return StreamBuilder<List<CommunityPartyMembership>>(
      stream: _myPartiesStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(
            key: ValueKey('party-mine-loading'),
            child: CircularProgressIndicator(),
          );
        }
        if (snap.hasError) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: PartyNotice(
              key: ValueKey('party-mine-error'),
              message: '내 파티를 불러오지 못했어요.',
            ),
          );
        }

        final memberships =
            snap.data ?? const <CommunityPartyMembership>[];
        if (memberships.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: PartyNotice(
              key: ValueKey('party-mine-empty'),
              message: '아직 참여 중이거나 만든 파티가 없어요.',
            ),
          );
        }

        final hosted = memberships.where((m) => m.isHost).toList();
        final joined = memberships
            .where((m) => !m.isHost && !m.isPending)
            .toList();
        final pending = memberships.where((m) => m.isPending).toList();

        return ListView(
          key: const ValueKey('party-mine-list'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
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
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          for (final membership in memberships) ...[
            _MembershipTile(
              membership: membership,
              partyService: partyService,
              onTap: onTap,
            ),
            const SizedBox(height: 10),
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
