import 'dart:typed_data';

/// Фото на экране: снимок (`null` — ещё грузится или не загрузился) и признак «ждёт отправки».
class ProblemPhotoView {
  const ProblemPhotoView({
    required this.id,
    this.content,
    this.pending = false,
    this.failed = false,
  });

  final String id;
  final Uint8List? content;

  /// Снят на терминале и ещё не на сервере.
  final bool pending;

  /// Снимок с сервера не загрузился (нет связи).
  final bool failed;
}
