import 'dart:math';

import 'package:firebase_storage/firebase_storage.dart';

import 'profile_photo_processor.dart';

/// Firebase Storage(파일 저장소) 접근을 감싸는 서비스.
///
/// 프로필 사진 업로드/삭제처럼 "파일"을 다루는 책임을 한 곳에 모은다.
final _objectNameRandom = Random();

/// Storage object 이름을 만든다.
///
/// timestamp만으로는 같은 밀리초에 두 장이 올라가면 충돌할 수 있어 nonce를
/// 덧붙인다. 사용자 파일명은 쓰지 않는다.
String buildProfilePhotoObjectName({
  required String role,
  required String extension,
}) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final nonce = _objectNameRandom.nextInt(1 << 32).toRadixString(36);
  return '${role}_${timestamp}_$nonce.$extension';
}

/// 업로드 가능한 상태인지 확인한다.
///
/// GPS·EXIF가 남아 있을 수 있는 파일은 공개 프로필에 올리지 않는다.
/// Storage 호출 전에 막아야 orphan object도 생기지 않는다.
void ensureUploadablePhoto(ProcessedProfilePhoto photo) {
  if (!photo.metadataSanitized) {
    throw StateError('metadata sanitization required before upload');
  }
}

class StorageService {
  StorageService({FirebaseStorage? storage})
    : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  /// 사진 파일 1장을 업로드하고 다운로드 URL을 반환한다.
  ///
  /// 경로 규칙: users/{uid}/profile/{fileName}
  /// uid로 경로를 나누면 Storage 보안 규칙에서 "본인 폴더만 쓰기"를 쉽게 걸 수 있다.
  /// 처리 완료된 사진 1장을 업로드하고 다운로드 URL을 반환한다.
  ///
  /// [photo]는 ProfilePhotoProcessor를 통과한 결과여야 한다. 이 서비스는
  /// 파일을 **다시 resize·compress하지 않고**, 확장자·Content-Type을 임의로
  /// 조립하지도 않는다 — 실제 bytes로 판정된 값을 그대로 쓴다.
  ///
  /// [role]은 'main' 또는 'sub_{index}'처럼 object 이름의 앞부분이다.
  Future<String> uploadProfilePhoto({
    required String uid,
    required String role,
    required ProcessedProfilePhoto photo,
  }) async {
    ensureUploadablePhoto(photo);

    final fileName = buildProfilePhotoObjectName(
      role: role,
      extension: photo.extension,
    );
    final ref = _storage
        .ref()
        .child('users')
        .child(uid)
        .child('profile')
        .child(fileName);

    // object 이름에 timestamp+nonce가 들어가 immutable하므로 길게 캐시해도
    // 새 사진이 옛 이미지에 가려지지 않는다. 교체하면 URL 자체가 바뀐다.
    final metadata = SettableMetadata(
      contentType: photo.contentType,
      cacheControl: 'public, max-age=31536000, immutable',
    );

    final file = photo.file;
    final task = file != null
        ? await ref.putFile(file, metadata)
        : await ref.putData(photo.bytes, metadata);
    return task.ref.getDownloadURL();
  }

  /// 메인 사진 1장 + 일상 사진을 순차 업로드하고 URL 목록을 반환한다.
  ///
  /// 반환 목록: [메인URL, 서브URL1, ...] — 입력 순서를 그대로 보존한다.
  Future<List<String>> uploadMultipleProfilePhotos({
    required String uid,
    required ProcessedProfilePhoto mainPhoto,
    List<ProcessedProfilePhoto> subPhotos = const [],
    void Function(double progress)? onProgress,
  }) async {
    final urls = <String>[];
    final total = 1 + subPhotos.length;
    var done = 0;

    urls.add(
      await uploadProfilePhoto(uid: uid, role: 'main', photo: mainPhoto),
    );
    done++;
    onProgress?.call(done / total);

    // 순서가 중요하므로 병렬이 아닌 순차 처리.
    for (var i = 0; i < subPhotos.length; i++) {
      urls.add(
        await uploadProfilePhoto(uid: uid, role: 'sub_$i', photo: subPhotos[i]),
      );
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
