import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_party.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/party_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../party/party_widgets.dart';
import 'party_group_chat_screen.dart';

/// 파티 그룹 채팅 목록(Phase 4-5).
///
/// users/{uid}/partyMemberships에서 **active인 host/member 파티만** 보여준다.
/// 승인 대기(pending)는 아직 대화에 들어갈 수 없으므로 목록에 넣지 않는다.
/// 취소되거나 사라진 파티도 표시하지 않는다.
class PartyGroupChatListScreen extends StatefulWidget {
  final AuthService authService;
  final PartyService partyService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const PartyGroupChatListScreen({
    super.key,
    required this.authService,
    required this.partyService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<PartyGroupChatListScreen> createState() =>
      _PartyGroupChatListScreenState();
}

class _PartyGroupChatListScreenState extends State<PartyGroupChatListScreen> {
  /// build 안에서 만들면 rebuild마다 재구독된다.
  late final Stream<List<CommunityPartyMembership>> _membershipsStream = widget
      .partyService
      .watchMyMemberships(uid: _currentUid ?? '');

  String? get _currentUid => widget.authService.currentUser?.uid;

  void _openChat(String partyId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartyGroupChatScreen(
          partyId: partyId,
          authService: widget.authService,
          partyService: widget.partyService,
          safetyService: widget.safetyService,
          contactAvoidanceService: widget.contactAvoidanceService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('party-group-chat-list-screen'),
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('그룹 채팅', style: AppTextStyles.cardTitle),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ChatListHeader(),
            Expanded(
              child: StreamBuilder<List<CommunityPartyMembership>>(
                stream: _membershipsStream,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const _ChatListLoading(
                      key: ValueKey('party-group-chat-list-loading'),
                    );
                  }
                  if (snap.hasError) {
                    return const _ChatListError(
                      errorKey: ValueKey('party-group-chat-list-error'),
                      message: '그룹 채팅 목록을 불러오지 못했어요.',
                    );
                  }

                  // 승인 대기(pending)는 대화에 들어갈 수 없으므로 제외한다.
                  final joined =
                      (snap.data ?? const <CommunityPartyMembership>[])
                          .where((membership) => !membership.isPending)
                          .toList();

                  if (joined.isEmpty) {
                    return const _ChatListEmpty(
                      emptyKey: ValueKey('party-group-chat-list-empty'),
                      message: '아직 참여 중인 파티가 없어요.\n파티에 참여하면 여기서 대화할 수 있어요.',
                    );
                  }

                  return ListView.separated(
                    key: const ValueKey('party-group-chat-list'),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screenH,
                      AppSpacing.xs,
                      AppSpacing.screenH,
                      AppSpacing.xxl,
                    ),
                    itemCount: joined.length,
                    separatorBuilder: (_, _) => const _ChatDivider(),
                    itemBuilder: (context, index) => _ChatEntryTile(
                      membership: joined[index],
                      partyService: widget.partyService,
                      onTap: _openChat,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 목록 위 compact header. 실제 프로필 사진 없이 대화 말풍선 motif만 얹는다.
class _ChatListHeader extends StatelessWidget {
  const _ChatListHeader();

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
                  '함께 이어가는 대화',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.brandPrimaryStrong,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  '참여 중인 모임의 이야기를 확인해요',
                  style: AppTextStyles.sectionTitle,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          const ExcludeSemantics(
            child: IgnorePointer(
              child: SizedBox(
                width: 58,
                height: 36,
                child: _GroupBubblesMotif(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 겹쳐 놓인 두 말풍선 — "모임의 대화"라는 의미만 형태로 암시한다.
class _GroupBubblesMotif extends StatelessWidget {
  const _GroupBubblesMotif();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          bottom: 0,
          child: _bubble(
            AppColors.surfaceMintSoft,
            AppColors.brandPrimary.withValues(alpha: 0.35),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: _bubble(
            AppColors.expressiveAccentSoft,
            AppColors.expressiveAccent.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }

  Widget _bubble(Color fill, Color border) {
    return Container(
      width: 34,
      height: 26,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: border),
      ),
    );
  }
}

/// 항목 사이 subtle divider. avatar 폭만큼 들여써서 대화 목록처럼 보이게 한다.
class _ChatDivider extends StatelessWidget {
  const _ChatDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 60),
      child: Divider(height: 1, thickness: 1, color: AppColors.borderSubtle),
    );
  }
}

/// mirror 하나에 대응하는 채팅방 항목.
///
/// 파티 제목·일시·지역은 mirror에 복사되지 않으므로 파티 문서를 따로 구독한다.
/// 취소·삭제된 파티는 아무것도 그리지 않는다(목록에서 자연스럽게 사라진다).
class _ChatEntryTile extends StatefulWidget {
  final CommunityPartyMembership membership;
  final PartyService partyService;
  final ValueChanged<String> onTap;

  const _ChatEntryTile({
    required this.membership,
    required this.partyService,
    required this.onTap,
  });

  @override
  State<_ChatEntryTile> createState() => _ChatEntryTileState();
}

class _ChatEntryTileState extends State<_ChatEntryTile> {
  late final Stream<CommunityParty?> _partyStream = widget.partyService
      .watchParty(widget.membership.partyId);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CommunityParty?>(
      stream: _partyStream,
      builder: (context, snap) {
        final party = snap.hasError ? null : snap.data;
        if (party == null) return const SizedBox.shrink();

        return Material(
          key: ValueKey('party-group-chat-${party.id}'),
          color: Colors.transparent,
          child: InkWell(
            onTap: () => widget.onTap(party.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 실제 사진이 아니라 그룹을 뜻하는 추상 avatar.
                  const _GroupAvatar(),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                party.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyles.cardTitle.copyWith(
                                  fontSize: 15.5,
                                ),
                              ),
                            ),
                            if (widget.membership.isHost) ...[
                              const SizedBox(width: AppSpacing.sm),
                              const PartyMetaChip(
                                icon: Icons.star_rounded,
                                label: '호스트',
                                emphasized: true,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            PartyMetaChip(
                              icon: Icons.schedule_rounded,
                              label: formatPartyStartAt(party.startAt),
                            ),
                            PartyMetaChip(
                              icon: Icons.place_outlined,
                              label: party.areaLabel,
                            ),
                            PartyMetaChip(
                              icon: Icons.group_outlined,
                              label: formatPartyParticipants(party),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 그룹 대화를 뜻하는 추상 avatar. 실제 프로필 사진·참여자 얼굴은 쓰지 않는다.
class _GroupAvatar extends StatelessWidget {
  const _GroupAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.surfaceMintSoft,
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.brandPrimary.withValues(alpha: 0.2),
        ),
      ),
      child: const Icon(
        Icons.groups_rounded,
        size: 24,
        color: AppColors.brandPrimaryStrong,
      ),
    );
  }
}

/// 목록 자리를 유지하는 skeleton. 이전 목록을 다시 보여주지 않는다.
class _ChatListLoading extends StatelessWidget {
  const _ChatListLoading({super.key});

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
          const _ChatTileSkeleton(),
          if (i < 2) const _ChatDivider(),
        ],
        const SizedBox(height: AppSpacing.lg),
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

class _ChatTileSkeleton extends StatelessWidget {
  const _ChatTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SkeletonBox(width: 48, height: 48, radius: 999),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBox(width: 160, height: 15),
                SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    _SkeletonBox(width: 84, height: 22, radius: 999),
                    SizedBox(width: AppSpacing.sm),
                    _SkeletonBox(width: 56, height: 22, radius: 999),
                  ],
                ),
              ],
            ),
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

/// 아직 대화가 없는 상태. 오류처럼 보이지 않게 말풍선 motif + 안내만 둔다.
class _ChatListEmpty extends StatelessWidget {
  final Key? emptyKey;
  final String message;

  const _ChatListEmpty({this.emptyKey, required this.message});

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
            child: SizedBox(width: 96, height: 56, child: _GroupBubblesMotif()),
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
class _ChatListError extends StatelessWidget {
  final Key? errorKey;
  final String message;

  const _ChatListError({this.errorKey, required this.message});

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
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.lg20),
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.surface),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            children: [
              Container(
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
              const SizedBox(height: AppSpacing.lg),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
