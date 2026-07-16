// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/chat/chat_screen.dart';
import '../auth/auth_service.dart';
import '../chat/chat_service.dart';
import '../database/firestore_service.dart';
import '../fortune/fortune_service.dart';
import '../matches/matches_service.dart';
import '../safety/safety_service.dart';

class NotificationService {
  NotificationService({
    FirebaseMessaging? messaging,
    FirebaseFirestore? firestore,
    required AuthService authService,
    required FirestoreService firestoreService,
    required ChatService chatService,
    required FortuneService fortuneService,
    required MatchesService matchesService,
    required SafetyService safetyService,
    required GlobalKey<NavigatorState> navigatorKey,
    required ValueNotifier<int?> mainTabRequest,
  }) : _messaging = messaging ?? FirebaseMessaging.instance,
       _db = firestore ?? FirebaseFirestore.instance,
       _authService = authService,
       _firestoreService = firestoreService,
       _chatService = chatService,
       _fortuneService = fortuneService,
       _matchesService = matchesService,
       _safetyService = safetyService,
       _navigatorKey = navigatorKey,
       _mainTabRequest = mainTabRequest;

  final FirebaseMessaging _messaging;
  final FirebaseFirestore _db;
  final AuthService _authService;
  final FirestoreService _firestoreService;
  final ChatService _chatService;
  final FortuneService _fortuneService;
  final MatchesService _matchesService;
  final SafetyService _safetyService;
  final GlobalKey<NavigatorState> _navigatorKey;
  final ValueNotifier<int?> _mainTabRequest;

  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _openedSub;
  StreamSubscription<String>? _tokenRefreshSub;
  String? _registeredUid;
  RemoteMessage? _pendingTapMessage;

  Future<void> initialize() async {
    // iOS 실기기 푸시는 Firebase Console에 APNs Auth Key 등록이 별도로 필요하다.
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    _foregroundSub ??= FirebaseMessaging.onMessage.listen(
      _handleForegroundMessage,
    );
    _openedSub ??= FirebaseMessaging.onMessageOpenedApp.listen(
      _handleNotificationTap,
    );

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      unawaited(_handleNotificationTap(initialMessage, retry: true));
    }
  }

  Future<void> registerForUser(String uid) async {
    _registeredUid = uid;
    try {
      await _requestPermission();

      if (Platform.isIOS) {
        final apnsToken = await _messaging.getAPNSToken();
        if (apnsToken == null || apnsToken.isEmpty) {
          _debugLog('[FCM] APNs 토큰 없음, 이번 FCM 토큰 등록 skip uid=$uid');
        } else {
          await _registerCurrentFcmToken(uid);
        }
      } else {
        await _registerCurrentFcmToken(uid);
      }

      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = _messaging.onTokenRefresh.listen(
        (newToken) {
          final currentUid = _registeredUid;
          if (currentUid == null || newToken.isEmpty) return;
          unawaited(_saveToken(currentUid, newToken));
        },
        onError: (Object e) {
          _debugLog('[FCM] 토큰 갱신 수신 실패: $e');
        },
      );
    } catch (e, st) {
      _debugLog('[FCM] 토큰 등록 흐름 실패 uid=$uid error=$e');
      _debugLog('$st');
    }

    final pending = _pendingTapMessage;
    if (pending != null) {
      _pendingTapMessage = null;
      unawaited(_handleNotificationTap(pending));
    }
  }

  Future<void> _registerCurrentFcmToken(String uid) async {
    final token = await _messaging.getToken();
    if (token != null && token.isNotEmpty) {
      await _saveToken(uid, token);
    }
  }

  Future<void> _requestPermission() async {
    try {
      await _messaging.requestPermission(alert: true, badge: true, sound: true);
    } catch (e) {
      _debugLog('[FCM] 알림 권한 요청 실패: $e');
    }
  }

  Future<void> _saveToken(String uid, String token) async {
    try {
      await _db.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _debugLog('[FCM] 토큰 저장 완료 uid=$uid');
    } catch (e) {
      _debugLog('[FCM] 토큰 저장 실패 uid=$uid error=$e');
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;

    final title = message.notification?.title ?? _fallbackTitle(message);
    final body = message.notification?.body ?? _fallbackBody(message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$title\n$body'),
          action: SnackBarAction(
            label: '열기',
            onPressed: () => unawaited(_handleNotificationTap(message)),
          ),
        ),
      );
  }

  String _fallbackTitle(RemoteMessage message) {
    return message.data['type'] == 'match' ? '새로운 매칭!' : '새 메시지';
  }

  String _fallbackBody(RemoteMessage message) {
    return message.data['type'] == 'match'
        ? '서로의 마음이 통했어요.'
        : '상대방이 메시지를 보냈어요.';
  }

  Future<void> _handleNotificationTap(
    RemoteMessage message, {
    bool retry = false,
  }) async {
    final type = message.data['type'];
    if (type == 'match') {
      _openMatchesTab();
      return;
    }
    if (type == 'chat') {
      final opened = await _openChatFromMessage(message);
      if (!opened && retry) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final openedAfterRetry = await _openChatFromMessage(message);
        if (!openedAfterRetry) {
          _pendingTapMessage = message;
        }
      }
    }
  }

  void _openMatchesTab() {
    _mainTabRequest.value = 1;
    final navigator = _navigatorKey.currentState;
    navigator?.popUntil((route) => route.isFirst);
  }

  Future<bool> _openChatFromMessage(RemoteMessage message) async {
    final currentUid = _authService.currentUser?.uid;
    final matchId = message.data['matchId'];
    final senderUid = message.data['senderUid'];
    if (currentUid == null ||
        matchId == null ||
        matchId.isEmpty ||
        senderUid == null ||
        senderUid.isEmpty) {
      return false;
    }

    try {
      final otherProfile = await _firestoreService.getPublicProfile(senderUid);
      final navigator = _navigatorKey.currentState;
      if (otherProfile == null || navigator == null) return false;
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            matchId: matchId,
            otherProfile: otherProfile,
            currentUid: currentUid,
            chatService: _chatService,
            fortuneService: _fortuneService,
            matchesService: _matchesService,
            safetyService: _safetyService,
          ),
        ),
      );
      return true;
    } catch (e) {
      _debugLog('[FCM] 채팅 알림 이동 실패 error=$e');
      return false;
    }
  }

  Future<void> dispose() async {
    await _foregroundSub?.cancel();
    await _openedSub?.cancel();
    await _tokenRefreshSub?.cancel();
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }
}
