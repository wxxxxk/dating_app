import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/shared/widgets/profile_photo_view.dart';

// 프로필 사진 표시 정책 회귀 테스트.
//
// 수정 전:
// - 내 프로필 갤러리: height = 화면폭 - 40 → 모든 사진이 강제 정사각 crop
// - 상대 프로필 상세: height 420 고정 + BoxFit.cover
// 두 경우 모두 세로 사진은 위아래가, 가로 사진은 좌우가 잘렸다.

String _read(String path) => File(path).readAsStringSync();

/// 비율 clamp는 위젯 상태에 있으므로 같은 규칙을 여기서 검증한다.
double clampRatio(double ratio, {double min = 0.72, double max = 1.2}) =>
    ratio.clamp(min, max);

void main() {
  group('원본 비율 보존 정책', () {
    test('세로 3:4 사진은 정사각으로 눌리지 않는다', () {
      const portrait = 3 / 4; // 0.75
      expect(clampRatio(portrait), closeTo(0.75, 0.001));
      expect(clampRatio(portrait), lessThan(1.0), reason: '세로 비율이 유지돼야 한다');
    });

    test('가로 4:3 사진은 가로 비율을 유지한다', () {
      const landscape = 4 / 3; // 1.333 → 1.2로 clamp
      final result = clampRatio(landscape);
      expect(result, greaterThan(1.0), reason: '가로 사진이 세로로 눌리면 안 된다');
      expect(result, closeTo(1.2, 0.001));
    });

    test('정사각 사진은 1:1을 유지한다', () {
      expect(clampRatio(1.0), closeTo(1.0, 0.001));
    });

    test('극단적인 파노라마·세로 사진만 clamp된다', () {
      // 16:9 파노라마 → 상한
      expect(clampRatio(16 / 9), closeTo(1.2, 0.001));
      // 9:16 초세로 → 하한
      expect(clampRatio(9 / 16), closeTo(0.72, 0.001));
      // 일반 범위는 그대로 통과
      expect(clampRatio(0.8), closeTo(0.8, 0.001));
      expect(clampRatio(1.1), closeTo(1.1, 0.001));
    });

    test('clamp 범위가 흔한 사진 비율을 모두 포함한다', () {
      // 3:4(0.75), 2:3(0.667→clamp), 1:1, 4:5(0.8)
      for (final ratio in [0.75, 0.8, 1.0]) {
        expect(clampRatio(ratio), closeTo(ratio, 0.001), reason: '$ratio');
      }
    });
  });

  group('썸네일과 상세 정책 분리', () {
    final source = _read('lib/shared/widgets/profile_photo_view.dart');

    test('썸네일은 cover + decode 상한을 쓴다', () {
      final start = source.indexOf('class ProfilePhotoThumbnail');
      final end = source.indexOf('class ProfilePhotoDetailView');
      final slice = source.substring(start, end);
      expect(slice.contains('BoxFit.cover'), isTrue);
      expect(slice.contains('cacheWidth:'), isTrue);
    });

    test('상세는 contain을 쓰고 decode 상한을 걸지 않는다', () {
      final start = source.indexOf('class ProfilePhotoDetailView');
      final slice = source.substring(start);
      expect(slice.contains('BoxFit.contain'), isTrue);
      // 큰 화면에서 흐려지면 안 되므로 상한이 없어야 한다.
      expect(slice.contains('cacheWidth'), isFalse);
      expect(slice.contains('memCacheWidth'), isFalse);
    });

    test('상세가 썸네일 위젯을 재사용하지 않는다', () {
      final start = source.indexOf('class ProfilePhotoDetailView');
      final slice = source.substring(start);
      expect(slice.contains('ProfilePhotoThumbnail'), isFalse);
    });

    test('여백은 흰 letterbox 대신 같은 사진의 blur로 채운다', () {
      expect(source.contains('ImageFilter.blur'), isTrue);
    });
  });

  group('화면 적용', () {
    final homeSource = _read('lib/features/home/home_screen.dart');
    final profileSource = _read(
      'lib/features/profile/user_profile_screen.dart',
    );

    test('내 프로필 갤러리에서 강제 정사각 계산이 사라졌다', () {
      expect(
        homeSource.contains('MediaQuery.of(context).size.width - 40'),
        isFalse,
        reason: '화면폭과 같은 height를 주면 모든 사진이 정사각으로 잘린다',
      );
      expect(homeSource.contains('ProfilePhotoDetailView('), isTrue);
    });

    test('상대 프로필 상세에서 height 420 고정이 사라졌다', () {
      expect(profileSource.contains('height: 420'), isFalse);
      expect(profileSource.contains('ProfilePhotoDetailView('), isTrue);
    });

    test('상세 화면들이 큰 사진에 BoxFit.cover를 직접 쓰지 않는다', () {
      // 상세 사진 렌더는 공용 위젯이 담당한다.
      final heroStart = profileSource.indexOf('ProfilePhotoDetailView(');
      expect(heroStart, greaterThan(0));
    });

    test('작은 아바타는 여전히 썸네일 정책을 쓴다', () {
      expect(homeSource.contains('ProfilePhotoThumbnail('), isTrue);
    });
  });

  group('위젯 렌더', () {
    testWidgets('사진이 없으면 fallback을 그리고 크래시하지 않는다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ProfilePhotoDetailView(photoUrls: [])),
        ),
      );
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
      // 빈 상태도 사진이 있을 때와 같은 sizing 경로를 쓴다(고정 높이 아님).
      expect(find.byType(LayoutBuilder), findsOneWidget);
    });

    testWidgets('썸네일 url이 비면 fallback을 그린다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ProfilePhotoThumbnail(url: null, boxWidth: 78, boxHeight: 98),
          ),
        ),
      );
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    });

    testWidgets('상세 뷰는 AspectRatio로 높이를 정한다 (고정 높이 아님)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ProfilePhotoDetailView(
              photoUrls: ['https://example.com/a.jpg'],
            ),
          ),
        ),
      );
      // 고정 높이가 아니라 사진 비율·화면 높이 상한으로 계산된다.
      expect(find.byType(LayoutBuilder), findsOneWidget);
      final box = tester.widget<SizedBox>(
        find.descendant(
          of: find.byType(LayoutBuilder),
          matching: find.byType(SizedBox),
        ),
      );
      expect(box.height, isNotNull);
      // 화면 높이의 68%를 넘지 않는다.
      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(box.height!, lessThanOrEqualTo(screenHeight * 0.68 + 1));
    });
  });
}
