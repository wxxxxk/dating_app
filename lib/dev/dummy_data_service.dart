// 개발용 — 출시 전 제거
//
// 시뮬레이터에서 디스커버리 스와이프 + 매칭 테스트를 위한 더미 유저 10명을 생성한다.
// DiscoveryScreen의 AppBar에 '더미 생성' 버튼으로만 호출된다 (kDebugMode 조건).
//
// 사진: i.pravatar.cc (얼굴 아바타), picsum.photos (서브 사진)
// UID: dummy_001 ~ dummy_010 (고정) — 중복 생성 방지를 위해 dummy_001 존재 여부로 확인.
//
// M4 역방향 스와이프:
//   dummy_001, dummy_003, dummy_006 세 명이 현재 유저를 이미 like한 상태로 초기화.
//   → 이 세 더미에게 like를 보내면 즉시 매칭이 성사된다.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
import '../services/database/firestore_service.dart';

class DummyDataService {
  DummyDataService({required this.firestoreService});

  final FirestoreService firestoreService;

  /// 더미 유저 10명을 Firestore에 생성한다.
  ///
  /// dummy_001이 이미 존재하면 중복 생성을 막기 위해 바로 반환한다.
  /// [currentUid]: 로그인된 실제 유저의 UID.
  ///   일부 더미가 이 유저를 이미 like한 역방향 스와이프를 함께 생성한다.
  Future<int> generateDummies({required String currentUid}) async {
    final existing = await firestoreService.getUserProfile('dummy_001');
    if (existing != null) return 0;

    final profiles = _buildProfiles();
    for (final p in profiles) {
      await firestoreService.createUserProfile(p);
    }

    // dummy_001, dummy_003, dummy_006이 현재 유저에게 like/superlike한 상태.
    // 이 세 더미에게 like하면 즉시 Cloud Function이 match를 생성한다.
    //
    // 필요 규칙: users/{dummy_*}/swipes/{targetUid} 쓰기 허용
    //   (firestore.rules의 dummy_* swipes 예외 규칙 + 콘솔 배포 필요)
    // 규칙 미배포 시 쓰기가 실패해도 예외를 삼키고 프로필 생성은 성공으로 처리한다.
    final db = FirebaseFirestore.instance;
    const likerDummies = {
      'dummy_001': 'like',
      'dummy_003': 'superlike',
      'dummy_006': 'like',
    };
    int reverseSwipeSuccessCount = 0;
    for (final entry in likerDummies.entries) {
      final dummyUid = entry.key;
      final action = entry.value;
      try {
        await db
            .collection('users')
            .doc(dummyUid)
            .collection('swipes')
            .doc(currentUid)
            .set({
              'action': action,
              'targetUid': currentUid,
              'actorUid': dummyUid,
              'timestamp': FieldValue.serverTimestamp(),
            });
        reverseSwipeSuccessCount++;
      } catch (e) {
        // 역방향 스와이프 실패 시 주요 원인:
        //   firestore.rules의 dummy_* swipes 예외 규칙이 콘솔에 미배포된 경우.
        //   firebase deploy --only firestore:rules 를 실행해 규칙을 배포할 것.
        debugPrint('[DummyData] 역방향 스와이프 실패 ($dummyUid → $currentUid): $e');
      }
    }
    debugPrint(
      '[DummyData] 역방향 스와이프 $reverseSwipeSuccessCount/${likerDummies.length} 성공',
    );

    return profiles.length;
  }

  List<UserProfile> _buildProfiles() {
    // today = 2026-07-01 기준 생년월일 계산
    final now = DateTime(2026, 7, 1);

    DateTime bd(int age) => DateTime(now.year - age, 3, 15);
    final base = DateTime(2026, 1, 1);
    final dummyLocations = [
      UserLocation(lat: 37.5665, lng: 126.9780, updatedAt: base), // 시청
      UserLocation(lat: 37.5700, lng: 126.9920, updatedAt: base), // 종로
      UserLocation(lat: 37.5172, lng: 127.0473, updatedAt: base), // 강남
      UserLocation(lat: 37.5446, lng: 127.0558, updatedAt: base), // 성수
      UserLocation(lat: 37.5563, lng: 126.9236, updatedAt: base), // 홍대
      UserLocation(lat: 37.5347, lng: 126.9946, updatedAt: base), // 이태원
      UserLocation(lat: 37.6543, lng: 127.0568, updatedAt: base), // 노원
      UserLocation(lat: 37.4850, lng: 126.9014, updatedAt: base), // 구로
      UserLocation(lat: 37.3943, lng: 127.1112, updatedAt: base), // 판교
      UserLocation(lat: 37.7380, lng: 127.0338, updatedAt: base), // 의정부
    ];

    return [
      // ── 여성 (1~5) ────────────────────────────────────────────────────────
      UserProfile(
        uid: 'dummy_001',
        displayName: '김서연',
        birthDate: bd(25),
        gender: 'female',
        bio: '🍳 요리와 베이킹을 좋아해요. 조용하고 따뜻한 시간을 즐기는 편이에요.',
        photoUrls: [
          'https://i.pravatar.cc/400?img=1',
          'https://picsum.photos/seed/d001b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 163,
        religion: 'none',
        smoking: 'non_smoker',
        drinking: 'rarely',
        jobCategory: 'education',
        jobTitle: '초등학교 교사',
        education: 'university',
        mbti: 'INFJ',
        interests: ['cooking', 'baking', 'plants', 'home_cafe'],
        personalityTags: ['calm', 'diligent', 'sensitive', 'polite'],
        idealTags: ['easy_to_talk', 'dependable', 'mature'],
        relationshipGoal: 'serious_relationship',
        location: dummyLocations[0],
        verifications: const VerificationStatus(email: true),
      ),
      UserProfile(
        uid: 'dummy_002',
        displayName: '이지민',
        birthDate: bd(23),
        gender: 'female',
        bio: '📸 사진 찍는 걸 좋아해요. 맛있는 거 먹으러 다니는 게 취미!',
        photoUrls: [
          'https://i.pravatar.cc/400?img=5',
          'https://picsum.photos/seed/d002b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 168,
        religion: 'none',
        smoking: 'non_smoker',
        drinking: 'occasionally',
        jobCategory: 'student',
        jobTitle: '대학원생',
        education: 'graduate',
        mbti: 'ENFP',
        interests: ['photography', 'netflix', 'saju_tarot', 'traveling'],
        personalityTags: ['cheerful', 'spontaneous', 'witty'],
        idealTags: ['cheerful', 'same_hobby', 'easy_to_talk'],
        relationshipGoal: 'light_romance',
        location: dummyLocations[1],
      ),
      UserProfile(
        uid: 'dummy_003',
        displayName: '박하은',
        birthDate: bd(27),
        gender: 'female',
        bio: '💻 백엔드 개발자. 야근보다 운동을 더 좋아해요 🏃‍♀️',
        photoUrls: [
          'https://i.pravatar.cc/400?img=7',
          'https://picsum.photos/seed/d003b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 167,
        religion: 'none',
        smoking: 'non_smoker',
        drinking: 'socially',
        jobCategory: 'it',
        jobTitle: '백엔드 개발자',
        education: 'university',
        mbti: 'ISTJ',
        interests: ['stocks', 'webtoon', 'drawing', 'netflix'],
        personalityTags: [
          'logical',
          'diligent',
          'detail_oriented',
          'responsible',
        ],
        idealTags: ['humble', 'intellectual', 'easy_to_talk'],
        relationshipGoal: 'open_to_anything',
        location: dummyLocations[2],
        verifications: const VerificationStatus(email: true),
      ),
      UserProfile(
        uid: 'dummy_004',
        displayName: '최수아',
        birthDate: bd(26),
        gender: 'female',
        bio: '🩺 간호사예요. 힘든 날에는 발레로 스트레스를 풀어요 🩰',
        photoUrls: [
          'https://i.pravatar.cc/400?img=9',
          'https://picsum.photos/seed/d004b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 162,
        religion: 'protestant',
        smoking: 'non_smoker',
        drinking: 'rarely',
        jobCategory: 'medical',
        jobTitle: '간호사',
        education: 'university',
        mbti: 'ESFJ',
        interests: ['ballet', 'makeup', 'home_cafe', 'cooking'],
        personalityTags: [
          'affectionate',
          'cheerful',
          'polite',
          'good_listener',
        ],
        idealTags: ['dependable', 'polite', 'no_swearing'],
        relationshipGoal: 'serious_relationship',
        location: dummyLocations[3],
      ),
      UserProfile(
        uid: 'dummy_005',
        displayName: '정유진',
        birthDate: bd(24),
        gender: 'female',
        bio: '🔬 연구소 연구원. 카페에서 논문 읽는 게 일상이에요.',
        photoUrls: [
          'https://i.pravatar.cc/400?img=12',
          'https://picsum.photos/seed/d005b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 165,
        religion: 'none',
        smoking: 'non_smoker',
        drinking: 'non_drinker',
        jobCategory: 'research',
        jobTitle: '연구원',
        education: 'graduate',
        mbti: 'ENFJ',
        interests: ['music_instrument', 'cooking', 'interior', 'plants'],
        personalityTags: [
          'intellectual',
          'passionate',
          'calm',
          'detail_oriented',
        ],
        idealTags: ['intellectual', 'serious', 'easy_to_talk'],
        relationshipGoal: 'serious_relationship',
        location: dummyLocations[4],
        verifications: const VerificationStatus(email: true),
      ),

      // ── 남성 (6~10) ───────────────────────────────────────────────────────
      UserProfile(
        uid: 'dummy_006',
        displayName: '이준호',
        birthDate: bd(28),
        gender: 'male',
        bio: '🍎 iOS 개발자. 코드와 커피를 사랑해요. 주말엔 등산.',
        photoUrls: [
          'https://i.pravatar.cc/400?img=14',
          'https://picsum.photos/seed/d006b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 180,
        religion: 'none',
        smoking: 'non_smoker',
        drinking: 'occasionally',
        jobCategory: 'it',
        jobTitle: 'iOS 개발자',
        education: 'university',
        mbti: 'INTJ',
        interests: ['stocks', 'anime', 'photography', 'home_cafe'],
        personalityTags: [
          'logical',
          'confident',
          'intellectual',
          'responsible',
        ],
        idealTags: ['calm', 'easy_to_talk', 'diligent'],
        relationshipGoal: 'serious_relationship',
        location: dummyLocations[5],
        verifications: const VerificationStatus(email: true),
      ),
      UserProfile(
        uid: 'dummy_007',
        displayName: '김민준',
        birthDate: bd(26),
        gender: 'male',
        bio: '🚀 스타트업 창업자. 뭐든 즐겁게 하는 편이에요!',
        photoUrls: [
          'https://i.pravatar.cc/400?img=17',
          'https://picsum.photos/seed/d007b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 178,
        religion: 'none',
        smoking: 'vaping',
        drinking: 'socially',
        jobCategory: 'business_owner',
        jobTitle: '스타트업 창업자',
        education: 'university',
        mbti: 'ESTP',
        interests: ['chatting', 'dancing', 'sneaker_collect', 'bitcoin'],
        personalityTags: ['active', 'spontaneous', 'confident', 'cheerful'],
        idealTags: ['active', 'cheerful', 'same_hobby'],
        relationshipGoal: 'open_to_anything',
        location: dummyLocations[6],
      ),
      UserProfile(
        uid: 'dummy_008',
        displayName: '박도현',
        birthDate: bd(30),
        gender: 'male',
        bio: '👨‍⚕️ 의사지만 집에서 요리하는 걸 더 좋아해요. 집밥 파트너 구해요 😄',
        photoUrls: [
          'https://i.pravatar.cc/400?img=21',
          'https://picsum.photos/seed/d008b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 176,
        religion: 'catholic',
        smoking: 'non_smoker',
        drinking: 'rarely',
        jobCategory: 'medical',
        jobTitle: '내과 전문의',
        education: 'graduate',
        mbti: 'ISFP',
        interests: ['cooking', 'home_cafe', 'plants', 'movie'],
        personalityTags: ['calm', 'mature', 'humble', 'loyal'],
        idealTags: ['affectionate', 'calm', 'polite'],
        relationshipGoal: 'serious_relationship',
        location: dummyLocations[7],
        verifications: const VerificationStatus(email: true),
      ),
      UserProfile(
        uid: 'dummy_009',
        displayName: '최지훈',
        birthDate: bd(29),
        gender: 'male',
        bio: '📈 금융권에서 일해요. 토론하는 거 좋아하고 새로운 아이디어를 환영해요.',
        photoUrls: [
          'https://i.pravatar.cc/400?img=25',
          'https://picsum.photos/seed/d009b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 182,
        religion: 'none',
        smoking: 'non_smoker',
        drinking: 'frequently',
        jobCategory: 'finance',
        jobTitle: '펀드매니저',
        education: 'graduate',
        mbti: 'ENTP',
        interests: ['bitcoin', 'stocks', 'movie', 'webtoon'],
        personalityTags: ['witty', 'confident', 'logical', 'spontaneous'],
        idealTags: ['intellectual', 'easy_to_talk', 'confident'],
        relationshipGoal: 'light_romance',
        location: dummyLocations[8],
      ),
      UserProfile(
        uid: 'dummy_010',
        displayName: '윤서준',
        birthDate: bd(24),
        gender: 'male',
        bio: '🎨 그래픽 디자이너. 예쁜 것들에 관심이 많아요. 미술관 자주 가요.',
        photoUrls: [
          'https://i.pravatar.cc/400?img=31',
          'https://picsum.photos/seed/d010b/400/600',
        ],
        createdAt: base,
        updatedAt: base,
        height: 174,
        religion: 'none',
        smoking: 'non_smoker',
        drinking: 'occasionally',
        jobCategory: 'freelancer',
        jobTitle: '그래픽 디자이너',
        education: 'university',
        mbti: 'INFP',
        interests: ['drawing', 'photography', 'interior', 'netflix'],
        personalityTags: ['emotional', 'sensitive', 'free_spirited', 'quiet'],
        idealTags: ['easy_to_talk', 'cheerful', 'same_hobby'],
        relationshipGoal: 'open_to_anything',
        location: dummyLocations[9],
        verifications: const VerificationStatus(email: true),
      ),
    ];
  }
}
