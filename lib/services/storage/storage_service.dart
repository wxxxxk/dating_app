import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

/// Firebase Storage(파일 저장소) 접근을 감싸는 서비스.
///
/// 프로필 사진 업로드/삭제처럼 "파일"을 다루는 책임을 한 곳에 모은다.
class StorageService {
  StorageService({FirebaseStorage? storage})
    : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  /// 사진 파일 1장을 업로드하고 다운로드 URL을 반환한다.
  ///
  /// 경로 규칙: users/{uid}/profile/{fileName}
  /// uid로 경로를 나누면 Storage 보안 규칙에서 "본인 폴더만 쓰기"를 쉽게 걸 수 있다.
  /// [contentType]은 ProfilePhotoProcessor가 정한 실제 출력 포맷이다.
  /// 이 서비스는 파일을 **다시 resize·compress하지 않는다** — 처리는
  /// ProfilePhotoProcessor에서 이미 한 번 끝났다.
  Future<String> uploadProfilePhoto({
    required String uid,
    required String fileName,
    required File file,
    String contentType = 'image/jpeg',
  }) async {
    final ref = _storage
        .ref()
        .child('users')
        .child(uid)
        .child('profile')
        .child(fileName);

    // 파일명에 timestamp가 들어가 object가 immutable하므로 길게 캐시해도
    // 새 사진이 옛 이미지에 가려지지 않는다. 교체 시 URL 자체가 바뀐다.
    final task = await ref.putFile(
      file,
      SettableMetadata(
        contentType: contentType,
        cacheControl: 'public, max-age=31536000, immutable',
      ),
    );
    return task.ref.getDownloadURL();
  }

  /// 메인 사진 1장 + 일상 사진 최대 3장을 순차 업로드하고 URL 목록을 반환한다.
  ///
  /// 반환 목록: [메인URL, 서브URL1, 서브URL2, ...]
  /// photoUrls[0]을 메인으로 취급하는 UserProfile 규칙을 여기서도 맞춘다.
  ///
  /// [onProgress]: 0.0 ~ 1.0 진행률 콜백. 업로드 중 UI에 진행 표시를 위해 사용.
  Future<List<String>> uploadMultipleProfilePhotos({
    required String uid,
    required File mainPhoto,
    List<File> subPhotos = const [],
    void Function(double progress)? onProgress,
  }) async {
    final urls = <String>[];
    // 총 파일 수: 진행률 계산에 사용
    final total = 1 + subPhotos.length;
    var done = 0;

    // 1. 메인 사진 업로드
    final mainFileName = 'main_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final mainUrl = await uploadProfilePhoto(
      uid: uid,
      fileName: mainFileName,
      file: mainPhoto,
    );
    urls.add(mainUrl);
    done++;
    onProgress?.call(done / total);

    // 2. 일상 사진 순차 업로드 (순서가 중요하므로 병렬이 아닌 순차 처리)
    for (var i = 0; i < subPhotos.length; i++) {
      final subFileName =
          'sub_${i}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final subUrl = await uploadProfilePhoto(
        uid: uid,
        fileName: subFileName,
        file: subPhotos[i],
      );
      urls.add(subUrl);
      done++;
      onProgress?.call(done / total);
    }

    return urls;
  }

  /// 다운로드 URL로 Storage 파일을 삭제한다.
  Future<void> deleteByUrl(String downloadUrl) async {
    await _storage.refFromURL(downloadUrl).delete();
  }
}
