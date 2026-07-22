import 'dart:typed_data';

/// 이미지 bytes에서 **개인정보 metadata만** 제거하는 순수 Dart 유틸.
///
/// 픽셀을 다시 인코딩하지 않는다. JPEG의 APP segment, PNG/WebP의 metadata
/// chunk만 잘라내는 무손실 처리라 화질 손실이 없다.
///
/// 새 dependency 없이 구현할 수 있는 범위로 한정했다. 안전하게 다룰 수 없는
/// 포맷(HEIC/HEIF 등)은 sanitize하지 않고 거부한다 — "아마 제거됐을 것"으로
/// 넘기면 GPS 좌표가 공개 프로필에 그대로 올라갈 수 있다.

/// magic bytes로 판정한 이미지 포맷.
enum DetectedImageFormat { jpeg, png, webp, heic, unknown }

extension DetectedImageFormatX on DetectedImageFormat {
  String? get contentType => switch (this) {
    DetectedImageFormat.jpeg => 'image/jpeg',
    DetectedImageFormat.png => 'image/png',
    DetectedImageFormat.webp => 'image/webp',
    DetectedImageFormat.heic => 'image/heic',
    DetectedImageFormat.unknown => null,
  };

  String? get extension => switch (this) {
    DetectedImageFormat.jpeg => 'jpg',
    DetectedImageFormat.png => 'png',
    DetectedImageFormat.webp => 'webp',
    DetectedImageFormat.heic => 'heic',
    DetectedImageFormat.unknown => null,
  };
}

/// 파일 경로 확장자나 호출자가 준 문자열을 믿지 않고 **내용으로** 판정한다.
DetectedImageFormat detectImageFormat(Uint8List bytes) {
  if (bytes.length < 12) return DetectedImageFormat.unknown;

  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return DetectedImageFormat.jpeg;
  }

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  const pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  var isPng = true;
  for (var i = 0; i < pngSignature.length; i += 1) {
    if (bytes[i] != pngSignature[i]) {
      isPng = false;
      break;
    }
  }
  if (isPng) return DetectedImageFormat.png;

  // WebP: 'RIFF' ....(size).... 'WEBP'
  if (_matchesAscii(bytes, 0, 'RIFF') && _matchesAscii(bytes, 8, 'WEBP')) {
    return DetectedImageFormat.webp;
  }

  // HEIC/HEIF: ISO BMFF — 4바이트 box size 뒤에 'ftyp' + brand
  if (_matchesAscii(bytes, 4, 'ftyp')) {
    const heicBrands = ['heic', 'heix', 'hevc', 'heim', 'heis', 'mif1', 'msf1'];
    for (final brand in heicBrands) {
      if (_matchesAscii(bytes, 8, brand)) return DetectedImageFormat.heic;
    }
  }

  return DetectedImageFormat.unknown;
}

bool _matchesAscii(Uint8List bytes, int offset, String value) {
  if (offset + value.length > bytes.length) return false;
  for (var i = 0; i < value.length; i += 1) {
    if (bytes[offset + i] != value.codeUnitAt(i)) return false;
  }
  return true;
}

/// sanitize 결과. 대상 metadata가 하나도 남지 않았을 때만 [sanitized]가 true다.
class SanitizedImage {
  final Uint8List bytes;
  final DetectedImageFormat format;
  final bool sanitized;

  const SanitizedImage({
    required this.bytes,
    required this.format,
    required this.sanitized,
  });
}

/// 포맷별로 개인정보 metadata를 제거한다.
///
/// 지원하지 않는 포맷이면 null을 돌려준다 — 호출자가 거부해야 한다.
SanitizedImage? sanitizeImageMetadata(Uint8List bytes) {
  final format = detectImageFormat(bytes);
  final cleaned = switch (format) {
    DetectedImageFormat.jpeg => _stripJpegMetadata(bytes),
    DetectedImageFormat.png => _stripPngMetadata(bytes),
    DetectedImageFormat.webp => _stripWebpMetadata(bytes),
    // HEIC은 무손실로 안전하게 벗겨낼 방법이 없다. 거부한다.
    DetectedImageFormat.heic => null,
    DetectedImageFormat.unknown => null,
  };
  if (cleaned == null) return null;
  return SanitizedImage(
    bytes: cleaned,
    format: format,
    sanitized: !hasPrivacyMetadata(cleaned),
  );
}

/// 정리 후 검증용. 대상 metadata가 남아 있으면 true.
bool hasPrivacyMetadata(Uint8List bytes) {
  return switch (detectImageFormat(bytes)) {
    DetectedImageFormat.jpeg => _jpegHasMetadata(bytes),
    DetectedImageFormat.png => _pngHasMetadata(bytes),
    DetectedImageFormat.webp => _webpHasMetadata(bytes),
    // 검사할 수 없는 포맷은 "없다"고 단정하지 않는다.
    DetectedImageFormat.heic => true,
    DetectedImageFormat.unknown => true,
  };
}

// ── JPEG ────────────────────────────────────────────────────────────────────
//
// JPEG은 SOI(FFD8) 뒤에 마커 segment가 이어지고, SOS(FFDA) 이후는 압축된
// 픽셀 데이터다. EXIF·GPS는 APP1, XMP도 APP1, 카메라 정보는 APPn·COM에 있다.
// APP0(JFIF)만 남기고 나머지 APPn과 COM을 버린다. SOS부터는 그대로 복사한다.

Uint8List? _stripJpegMetadata(Uint8List bytes) {
  if (bytes.length < 4) return null;
  final out = BytesBuilder(copy: false);
  out.add([0xFF, 0xD8]); // SOI

  var i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return null; // 마커 정렬이 깨졌다 → 손상 파일
    final marker = bytes[i + 1];

    if (marker == 0xD9) {
      out.add([0xFF, 0xD9]); // EOI
      i += 2;
      break;
    }
    if (marker == 0xDA) {
      // SOS: 여기서부터 끝까지 픽셀 데이터. 그대로 복사한다.
      out.add(Uint8List.sublistView(bytes, i));
      i = bytes.length;
      break;
    }

    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2 || i + 2 + length > bytes.length) return null;

    final isAppSegment = marker >= 0xE0 && marker <= 0xEF;
    final isComment = marker == 0xFE;
    // APP0(JFIF)은 표시 호환성을 위해 남긴다. 개인정보를 담지 않는다.
    final keep = !(isComment || (isAppSegment && marker != 0xE0));
    if (keep) {
      out.add(Uint8List.sublistView(bytes, i, i + 2 + length));
    }
    i += 2 + length;
  }

  final result = out.toBytes();
  // SOI만 남았거나 SOS를 못 만났으면 유효한 JPEG이 아니다.
  return result.length > 4 ? result : null;
}

bool _jpegHasMetadata(Uint8List bytes) {
  var i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return true; // 해석 불가 → 안전하게 "있다"로 본다
    final marker = bytes[i + 1];
    if (marker == 0xDA || marker == 0xD9) return false;
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2 || i + 2 + length > bytes.length) return true;
    if (marker == 0xFE) return true; // COM
    if (marker >= 0xE1 && marker <= 0xEF) return true; // APP1~APP15
    i += 2 + length;
  }
  return false;
}

// ── PNG ─────────────────────────────────────────────────────────────────────
//
// PNG은 signature 뒤에 chunk(length[4] type[4] data crc[4])가 이어진다.
// 개인정보가 들어갈 수 있는 ancillary chunk를 버린다. 색상 정확도에 필요한
// gAMA·cHRM·sRGB·iCCP는 남긴다.

const _pngDropChunks = {'tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME'};

Uint8List? _stripPngMetadata(Uint8List bytes) {
  const headerLength = 8;
  if (bytes.length < headerLength + 12) return null;
  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(bytes, 0, headerLength));

  var i = headerLength;
  var sawEnd = false;
  while (i + 8 <= bytes.length) {
    final length = _readUint32(bytes, i);
    final type = String.fromCharCodes(bytes, i + 4, i + 8);
    final total = 12 + length;
    if (length < 0 || i + total > bytes.length) return null;

    if (!_pngDropChunks.contains(type)) {
      out.add(Uint8List.sublistView(bytes, i, i + total));
    }
    i += total;
    if (type == 'IEND') {
      sawEnd = true;
      break;
    }
  }
  return sawEnd ? out.toBytes() : null;
}

bool _pngHasMetadata(Uint8List bytes) {
  var i = 8;
  while (i + 8 <= bytes.length) {
    final length = _readUint32(bytes, i);
    final type = String.fromCharCodes(bytes, i + 4, i + 8);
    if (length < 0 || i + 12 + length > bytes.length) return true;
    if (_pngDropChunks.contains(type)) return true;
    if (type == 'IEND') return false;
    i += 12 + length;
  }
  return false;
}

// ── WebP ────────────────────────────────────────────────────────────────────
//
// RIFF 컨테이너다. 'EXIF'/'XMP ' chunk를 버리고 RIFF 크기를 다시 쓴다.
// VP8X chunk의 flag에서 EXIF/XMP 존재 비트도 내린다.

const _webpDropChunks = {'EXIF', 'XMP '};

Uint8List? _stripWebpMetadata(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final body = BytesBuilder(copy: false);
  body.add(Uint8List.sublistView(bytes, 8, 12)); // 'WEBP'

  var i = 12;
  while (i + 8 <= bytes.length) {
    final fourcc = String.fromCharCodes(bytes, i, i + 4);
    final size = _readUint32Le(bytes, i + 4);
    if (size < 0) return null;
    final padded = size + (size.isOdd ? 1 : 0);
    final end = i + 8 + padded;
    if (end > bytes.length) return null;

    if (!_webpDropChunks.contains(fourcc)) {
      final chunk = Uint8List.fromList(Uint8List.sublistView(bytes, i, end));
      if (fourcc == 'VP8X' && chunk.length >= 9) {
        // flags byte: bit3 = EXIF, bit2 = XMP. 둘 다 내린다.
        chunk[8] = chunk[8] & ~0x0C;
      }
      body.add(chunk);
    }
    i = end;
  }

  final bodyBytes = body.toBytes();
  final out = BytesBuilder(copy: false);
  out.add([0x52, 0x49, 0x46, 0x46]); // 'RIFF'
  out.add(_uint32Le(bodyBytes.length));
  out.add(bodyBytes);
  return out.toBytes();
}

bool _webpHasMetadata(Uint8List bytes) {
  var i = 12;
  while (i + 8 <= bytes.length) {
    final fourcc = String.fromCharCodes(bytes, i, i + 4);
    final size = _readUint32Le(bytes, i + 4);
    if (size < 0) return true;
    if (_webpDropChunks.contains(fourcc)) return true;
    final padded = size + (size.isOdd ? 1 : 0);
    i += 8 + padded;
  }
  return false;
}

// ── 공용 ────────────────────────────────────────────────────────────────────

int _readUint32(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return -1;
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

int _readUint32Le(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return -1;
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

Uint8List _uint32Le(int value) {
  return Uint8List.fromList([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
}
