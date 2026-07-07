String stripEmoji(String value) {
  return value
      .replaceAll(
        RegExp(r'[\u{1F300}-\u{1FFFF}\u{2600}-\u{27BF}]', unicode: true),
        '',
      )
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
}
