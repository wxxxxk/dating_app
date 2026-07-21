import 'dart:typed_data';

/// Feed 작성 화면이 들고 있는 **로컬 초안 이미지**(Phase 4-3).
///
/// 아직 업로드되지 않은 사진 한 장을 나타낸다. bytes는 미리보기와 업로드에만
/// 쓰고 Firestore에는 절대 넣지 않는다. 원본 local file path는 화면·로그
/// 어디에도 노출하지 않는다(경로에 사용자 계정명이 들어갈 수 있다).
class FeedDraftImage {
  /// 미리보기 + 업로드에 함께 쓰는 실제 bytes. picker가 재인코딩한 결과다.
  final Uint8List bytes;

  /// 소문자 확장자(jpg/jpeg/png). 파일명이 아니라 실제 bytes로 판별한다.
  final String extension;

  /// 업로드 대상 content type(image/jpeg | image/png).
  final String contentType;

  /// 같은 사진을 두 번 담지 않기 위한 로컬 식별자. 표시하지 않는다.
  final String fingerprint;

  const FeedDraftImage({
    required this.bytes,
    required this.extension,
    required this.contentType,
    required this.fingerprint,
  });

  int get sizeBytes => bytes.length;

  /// 로그·에러 메시지에 파일 경로가 섞이지 않도록 최소 정보만 노출한다.
  @override
  String toString() => 'FeedDraftImage($extension, $sizeBytes bytes)';
}
