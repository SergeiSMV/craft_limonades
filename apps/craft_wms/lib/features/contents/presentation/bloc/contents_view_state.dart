import '../../../../core/error/failure.dart';
import '../../domain/contents_entities.dart';

/// Состояние экрана содержимого — общее у «Ячейки» и «Короба» (P5-05).
sealed class ContentsViewState<T> {
  const ContentsViewState();
}

/// Идёт загрузка.
final class ContentsViewLoading<T> extends ContentsViewState<T> {
  const ContentsViewLoading();
}

/// Данные получены: [data] несёт и само содержимое, и откуда оно.
final class ContentsViewLoaded<T> extends ContentsViewState<T> {
  const ContentsViewLoaded(this.data);

  final Viewed<T> data;
}

/// Показать нечего: нет связи и нет снимка, либо сбой сервера.
final class ContentsViewFailed<T> extends ContentsViewState<T> {
  const ContentsViewFailed(this.failure);

  final Failure failure;
}
