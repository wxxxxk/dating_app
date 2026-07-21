// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/privacy/contact_avoidance_service.dart';
import '../../services/safety/safety_service.dart';

/// 커뮤니티 화면 공통 관계 필터(Phase 4-2).
///
/// 차단(양방향)과 지인 피하기 uid를 각각 들고 union으로 쓴다 — 한쪽 관계가
/// 풀리면 그 작성자만 다시 보이게 하기 위해서다. **문서를 지우거나 카운트를
/// 바꾸지 않는다.** 목록/상세에서 표시만 건너뛴다.
///
/// 조회 실패가 커뮤니티 화면 전체를 막지 않도록 오류는 조용히 무시한다.
class CommunityAudienceFilter {
  CommunityAudienceFilter({
    required SafetyService safetyService,
    required ContactAvoidanceService contactAvoidanceService,
  }) : _safetyService = safetyService,
       _contactAvoidanceService = contactAvoidanceService;

  final SafetyService _safetyService;
  final ContactAvoidanceService _contactAvoidanceService;

  StreamSubscription<Set<String>>? _avoidedSub;
  Set<String> _blockedUids = const {};
  Set<String> _avoidedUids = const {};

  Set<String> get excludedUids => {..._blockedUids, ..._avoidedUids};

  /// 관계 구독을 시작한다. 값이 실제로 바뀔 때만 [onChanged]를 부른다.
  void start({required String? uid, required VoidCallback onChanged}) {
    if (uid == null || uid.isEmpty) return;
    _loadBlocked(uid, onChanged);
    _avoidedSub = _contactAvoidanceService
        .watchAvoidedUids(uid)
        .listen(
          (avoided) {
            if (setEquals(avoided, _avoidedUids)) return;
            _avoidedUids = avoided;
            onChanged();
          },
          onError: (Object e) {
            // 구독 오류가 화면을 영구 종료시키지 않는다.
            _debugLog('[Community] 지인 피하기 구독 실패 code=${e.runtimeType}');
          },
        );
  }

  Future<void> _loadBlocked(String uid, VoidCallback onChanged) async {
    try {
      final blocked = await _safetyService.getBlockedRelationshipUids(uid);
      if (setEquals(blocked, _blockedUids)) return;
      _blockedUids = blocked;
      onChanged();
    } catch (e) {
      _debugLog('[Community] 차단 목록 조회 실패 code=${e.runtimeType}');
    }
  }

  /// 차단 직후처럼 즉시 반영이 필요한 경우 다시 읽는다.
  Future<void> refreshBlocked({
    required String? uid,
    required VoidCallback onChanged,
  }) async {
    if (uid == null || uid.isEmpty) return;
    await _loadBlocked(uid, onChanged);
  }

  /// 본인 콘텐츠는 어떤 관계에서도 숨기지 않는다.
  bool isExcluded({required String authorUid, required String? selfUid}) {
    if (authorUid.isEmpty) return false;
    if (selfUid != null && authorUid == selfUid) return false;
    return _blockedUids.contains(authorUid) || _avoidedUids.contains(authorUid);
  }

  void dispose() {
    _avoidedSub?.cancel();
    _avoidedSub = null;
  }

  void _debugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
