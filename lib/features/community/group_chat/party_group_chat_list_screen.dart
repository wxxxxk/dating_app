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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('그룹 채팅'),
      ),
      body: SafeArea(
        child: StreamBuilder<List<CommunityPartyMembership>>(
          stream: _membershipsStream,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(
                key: ValueKey('party-group-chat-list-loading'),
                child: CircularProgressIndicator(),
              );
            }
            if (snap.hasError) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: PartyNotice(
                  key: ValueKey('party-group-chat-list-error'),
                  message: '그룹 채팅 목록을 불러오지 못했어요.',
                ),
              );
            }

            // 승인 대기(pending)는 대화에 들어갈 수 없으므로 제외한다.
            final joined = (snap.data ?? const <CommunityPartyMembership>[])
                .where((membership) => !membership.isPending)
                .toList();

            if (joined.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: PartyNotice(
                  key: ValueKey('party-group-chat-list-empty'),
                  message: '아직 참여 중인 파티가 없어요.\n파티에 참여하면 여기서 대화할 수 있어요.',
                ),
              );
            }

            return ListView.separated(
              key: const ValueKey('party-group-chat-list'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              itemCount: joined.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _ChatEntryTile(
                membership: joined[index],
                partyService: widget.partyService,
                onTap: _openChat,
              ),
            );
          },
        ),
      ),
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
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: InkWell(
            onTap: () => widget.onTap(party.id),
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.groups_outlined,
                        size: 18,
                        color: AppColors.mintDeep,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          party.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (widget.membership.isHost)
                        const PartyMetaChip(
                          icon: Icons.star_rounded,
                          label: '호스트',
                          emphasized: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
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
          ),
        );
      },
    );
  }
}
