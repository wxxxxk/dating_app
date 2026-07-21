import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/community/community_post.dart';
import '../../models/community/feed_draft_image.dart';

/// Feed 이미지 처리 실패. 사용자에게는 [message]만 노출하고 raw 경로·uid·
/// 내부 오류는 감춘다.
class CommunityMediaError implements Exception {
  final String message;
  const CommunityMediaError(this.message);

  @override
  String toString() => 'CommunityMediaError: $message';
}

/// Feed 사진 선택·검증·업로드·표시 서비스(Phase 4-3).
///
/// 개인정보 원칙:
/// - **download URL을 만들지 않는다.** 업로드 결과는 내부 storagePath뿐이고,
///   표시할 때만 인증된 사용자가 bytes를 직접 읽는다. 게시물이 삭제되면
///   Storage Rules가 곧바로 read를 막는다.
/// - 원본 local file path·파일명은 반환값·로그·화면 어디에도 남기지 않는다.
/// - 파일명을 믿지 않고 실제 bytes(magic number)로 형식을 판별한다.
class CommunityMediaService {
  CommunityMediaService({FirebaseStorage? storage, ImagePicker? imagePicker})
    : _storageOverride = storage,
      _imagePickerOverride = imagePicker;

  final FirebaseStorage? _storageOverride;
  final ImagePicker? _imagePickerOverride;

  /// 실제 호출 시점에만 plugin instance를 잡는다 — 화면·테스트에서 서비스를
  /// 만드는 것만으로 Firebase 초기화를 요구하지 않기 위해서다.
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;
  ImagePicker get _imagePicker => _imagePickerOverride ?? ImagePicker();

  /// 이미지 1장 최대 크기.
  static const int maxImageBytes = 5 * 1024 * 1024;

  /// 게시물 1건의 이미지 총합 최대 크기.
  static const int maxTotalBytes = 20 * 1024 * 1024;

  static const int maxImages = CommunityPost.maxFeedImages;

  /// picker 재인코딩 옵션. 원본 그대로 올리지 않아 용량과 metadata를 줄인다.
  static const int pickerImageQuality = 82;
  static const double pickerMaxWidth = 1600;

  static const String jpegContentType = 'image/jpeg';
  static const String pngContentType = 'image/png';

  static const String genericErrorMessage = '사진을 처리하지 못했어요. 다시 시도해주세요.';
  static const String unsupportedFormatMessage =
      'jpg 또는 png 사진만 올릴 수 있어요. (HEIC 형식은 지원하지 않아요)';
  static const String tooLargeMessage = '사진 한 장은 5MB까지 올릴 수 있어요.';
  static const String tooLargeTotalMessage = '사진 전체 용량은 20MB까지 올릴 수 있어요.';
  static const String emptyFileMessage = '사진을 읽지 못했어요. 다시 선택해주세요.';
  static const String uploadFailedMessage = '사진을 올리지 못했어요. 잠시 후 다시 시도해주세요.';

  // ── 선택 ────────────────────────────────────────────────────────────────

  /// 카메라로 1장 촬영한다. 사용자가 취소하면 null.
  Future<XFile?> pickFeedImageFromCamera() {
    return _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: pickerImageQuality,
      maxWidth: pickerMaxWidth,
    );
  }

  /// 갤러리에서 여러 장 선택한다. 남은 슬롯 수까지만 돌려준다.
  Future<List<XFile>> pickFeedImagesFromGallery({
    int remainingSlots = maxImages,
  }) async {
    if (remainingSlots <= 0) return const <XFile>[];
    final picked = await _imagePicker.pickMultiImage(
      imageQuality: pickerImageQuality,
      maxWidth: pickerMaxWidth,
    );
    if (picked.length <= remainingSlots) return picked;
    return picked.sublist(0, remainingSlots);
  }

  // ── 검증 ────────────────────────────────────────────────────────────────

  /// 선택한 파일을 읽어 형식·용량을 검증한 초안 이미지로 만든다.
  ///
  /// 실패하면 [CommunityMediaError]의 고정 문구만 던진다.
  Future<FeedDraftImage> prepareFeedImage(XFile file) async {
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const CommunityMediaError(emptyFileMessage);
    }
    return buildDraftImage(bytes);
  }

  /// bytes → 초안 이미지(순수 함수, 테스트에서 직접 쓴다).
  static FeedDraftImage buildDraftImage(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const CommunityMediaError(emptyFileMessage);
    }
    if (bytes.length > maxImageBytes) {
      throw const CommunityMediaError(tooLargeMessage);
    }

    final extension = detectImageExtension(bytes);
    if (extension == null) {
      throw const CommunityMediaError(unsupportedFormatMessage);
    }

    return FeedDraftImage(
      bytes: bytes,
      extension: extension,
      contentType: extension == 'png' ? pngContentType : jpegContentType,
      fingerprint: sha256.convert(bytes).toString(),
    );
  }

  /// 실제 bytes의 magic number로 형식을 판별한다(순수 함수).
  ///
  /// 파일명 확장자는 믿지 않는다 — 확장자만 바꾼 HEIC가 그대로 올라가면
  /// 기기에 따라 표시되지 않기 때문이다. 지원하지 않는 형식은 null.
  static String? detectImageExtension(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'png';
    }
    return null;
  }

  /// 총합 용량 확인(순수 함수). 초과하면 [CommunityMediaError].
  static void assertTotalWithinLimit(List<FeedDraftImage> images) {
    var total = 0;
    for (final image in images) {
      total += image.sizeBytes;
    }
    if (total > maxTotalBytes) {
      throw const CommunityMediaError(tooLargeTotalMessage);
    }
  }

  // ── 업로드 ──────────────────────────────────────────────────────────────

  /// 초안 이미지를 순서대로 업로드하고 **storagePath 목록만** 돌려준다.
  ///
  /// download URL은 요청하지 않는다. 실패하면 이미 올라간 파일 경로를 담아
  /// [CommunityMediaUploadFailure]로 던져, 호출부가 서버 정리에 넘길 수 있게
  /// 한다.
  Future<List<String>> uploadFeedImages({
    required String uid,
    required String postId,
    required List<FeedDraftImage> images,
    Random? random,
  }) async {
    if (uid.isEmpty || postId.isEmpty || images.isEmpty) {
      throw const CommunityMediaError(genericErrorMessage);
    }
    if (images.length > maxImages) {
      throw const CommunityMediaError(genericErrorMessage);
    }
    assertTotalWithinLimit(images);

    final uploaded = <String>[];
    for (final image in images) {
      final path = buildFeedImagePath(
        uid: uid,
        postId: postId,
        imageId: generateImageId(random: random),
        extension: image.extension,
      );
      try {
        await _storage
            .ref(path)
            .putData(
              image.bytes,
              // customMetadata에는 postId만 넣는다(uid·본문·파일명 금지).
              SettableMetadata(
                contentType: image.contentType,
                customMetadata: {'postId': postId},
              ),
            );
      } catch (_) {
        throw CommunityMediaUploadFailure(uploadedPaths: uploaded);
      }
      uploaded.add(path);
    }
    return List<String>.unmodifiable(uploaded);
  }

  /// Storage 경로(순수 함수). storage.rules·서버 검증과 1:1 대응한다.
  static String buildFeedImagePath({
    required String uid,
    required String postId,
    required String imageId,
    required String extension,
  }) {
    final prefix = CommunityPost.feedImagePathPrefix(
      authorUid: uid,
      postId: postId,
    );
    return '$prefix$imageId.$extension';
  }

  /// 충돌 가능성이 낮은 imageId(새 dependency 없이 난수만 사용).
  /// 촬영 시각·파일명·사용자 정보는 넣지 않는다.
  static String generateImageId({Random? random}) {
    final rnd = random ?? Random.secure();
    return List.generate(
      20,
      (_) => _idAlphabet[rnd.nextInt(_idAlphabet.length)],
    ).join();
  }

  static const String _idAlphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  // ── 표시 ────────────────────────────────────────────────────────────────

  /// storagePath에서 이미지 bytes를 읽는다.
  ///
  /// download URL을 만들지 않으므로 게시물이 삭제되면 Storage Rules가 즉시
  /// 이 호출을 막는다. 실패는 null로 돌려주고(중립 placeholder 표시),
  /// 원인·경로는 로그에 남기지 않는다.
  Future<Uint8List?> loadFeedImageBytes({
    required String storagePath,
    int maxBytes = maxImageBytes,
  }) async {
    if (storagePath.isEmpty) return null;
    try {
      return await _storage.ref(storagePath).getData(maxBytes);
    } catch (_) {
      return null;
    }
  }
}

/// 업로드 도중 실패. 이미 올라간 경로를 서버 정리에 넘기기 위해 들고 있다.
class CommunityMediaUploadFailure implements Exception {
  final List<String> uploadedPaths;
  final String message;

  CommunityMediaUploadFailure({
    required List<String> uploadedPaths,
    this.message = CommunityMediaService.uploadFailedMessage,
  }) : uploadedPaths = List<String>.unmodifiable(uploadedPaths);

  @override
  String toString() => 'CommunityMediaUploadFailure: $message';
}
