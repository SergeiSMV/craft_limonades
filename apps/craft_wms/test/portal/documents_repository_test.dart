import 'dart:typed_data';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/portal/domain/documents/documents_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_form.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:craft_wms/portal/data/documents_repository_impl.dart';

import '../support/fake_dio_adapter.dart';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  group('listDocuments', () {
    test('успех → парсит документы со статусом', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.documents}': (_) => ResponseBody.fromString(
              '[{"id":"d1","kind":"stock_entry","warehouse_code":"SHB","warehouse_name":"Шабулина",'
              '"created_at":"2026-08-13T21:00:00Z","lines_count":5,'
              '"status":"downloaded","downloaded_at":"2026-08-14T07:00:00Z","done_at":null}]',
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            ),
      });
      final repo = DocumentsRepositoryImpl(dio);

      final res = await repo.listDocuments();
      expect(res.isRight, isTrue);
      final docs = res.right;
      expect(docs, hasLength(1));
      expect(docs.first.id, 'd1');
      expect(docs.first.warehouseCode, 'SHB');
      expect(docs.first.linesCount, 5);
      expect(docs.first.createdAt.isUtc, isTrue);
      expect(docs.first.status, DocStatus.downloaded);
    });

    // P4-10: у «Прихода» своя вкладка - форма фильтруется на сервере, поставщик в строке.
    test('форма уходит параметром kind, поставщик разбирается', () async {
      final adapter = RecordingAdapter({
        'GET ${ApiConst.documents}': (_) => ResponseBody.fromString(
              '[{"id":"r1","kind":"receipt","supplier":"ООО «Голсера»","warehouse_code":"SHB",'
              '"warehouse_name":"Шабулина","created_at":"2026-10-05T09:00:00Z","lines_count":2,'
              '"status":"new","downloaded_at":null,"done_at":null}]',
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            ),
      });
      dio.httpClientAdapter = adapter;

      final res = await DocumentsRepositoryImpl(dio).listDocuments(kind: 'receipt');
      expect(adapter.requests.single.queryParameters, {'kind': 'receipt'});
      expect(res.right.single.kind, 'receipt');
      expect(res.right.single.supplier, 'ООО «Голсера»');
    });

    test('незнакомый статус → показываем как новый, а не прячем в выполненных', () {
      expect(DocStatus.parse('archived'), DocStatus.isNew);
      expect(DocStatus.parse(null), DocStatus.isNew);
      expect(DocStatus.parse('done'), DocStatus.done);
    });

    test('401 → Failure.server(401)', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.documents}': (_) => ResponseBody.fromString('{"error":"x"}', 401, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      });
      final res = await DocumentsRepositoryImpl(dio).listDocuments();
      expect(res.isLeft, isTrue);
      expect(res.left, isA<ServerFailure>());
    });
  });

  group('downloadReport', () {
    test('успех → байты; GET file.xlsx с responseType bytes', () async {
      final xlsx = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04]); // PK..
      final adapter = RecordingAdapter({
        'GET ${ApiConst.documentFile("d1")}': (_) => ResponseBody.fromBytes(xlsx, 200, headers: {
          Headers.contentTypeHeader: ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
          'content-disposition': ['attachment; filename="dvizhenie-SHB-20261009.xlsx"'],
        }),
      });
      dio.httpClientAdapter = adapter;

      final res = await DocumentsRepositoryImpl(dio).downloadReport('d1');
      expect(res.isRight, isTrue);
      expect(res.right.bytes, equals(xlsx));
      // ADHOC-24: имя - то, что прислал сервер, а не зашитое «ввод остатков».
      expect(res.right.filename, 'dvizhenie-SHB-20261009.xlsx');
      final req = adapter.requests.single;
      expect(req.path, ApiConst.documentFile('d1'));
      expect(req.responseType, ResponseType.bytes);
    });
  });

  // ADHOC-24: имя файла из Content-Disposition; без него - имя по умолчанию.
  test('имя файла из Content-Disposition', () {
    expect(filenameFromDisposition('attachment; filename="postuplenie-SHB-20261009.xlsx"'),
        'postuplenie-SHB-20261009.xlsx');
    expect(filenameFromDisposition('attachment; filename=vvod-ostatkov-SHB-20261009.xlsx'),
        'vvod-ostatkov-SHB-20261009.xlsx');
    expect(filenameFromDisposition('attachment'), kDefaultDocFilename);
    expect(filenameFromDisposition(null), kDefaultDocFilename);
  });

  group('markDone', () {
    test('успех → Right; POST на documents/{id}/done', () async {
      final adapter = RecordingAdapter({
        'POST ${ApiConst.documentDone("d1")}': (_) => ResponseBody.fromString('', 204),
      });
      dio.httpClientAdapter = adapter;

      final res = await DocumentsRepositoryImpl(dio).markDone('d1');
      expect(res.isRight, isTrue);
      expect(adapter.requests.single.path, ApiConst.documentDone('d1'));
    });

    test('404 → Failure.server', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'POST ${ApiConst.documentDone("d1")}': (_) => ResponseBody.fromString('{"error":"нет"}', 404, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      });
      final res = await DocumentsRepositoryImpl(dio).markDone('d1');
      expect(res.isLeft, isTrue);
      expect(res.left, isA<ServerFailure>());
    });
  });

  group('events', () {
    test('успех → разбирает журнал; пустой автор остаётся пустым', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.documentEvents("d1")}': (_) => ResponseBody.fromString(
              '[{"event":"created","user_name":"Кладовщик","details":"","created_at":"2026-08-13T21:00:00Z"},'
              '{"event":"downloaded","user_name":"","details":"","created_at":"2026-08-14T07:00:00Z"}]',
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            ),
      });
      final res = await DocumentsRepositoryImpl(dio).events('d1');
      expect(res.isRight, isTrue);
      final events = res.right;
      expect(events, hasLength(2));
      expect(events.first.event, 'created');
      expect(events.first.userName, 'Кладовщик');
      expect(events.last.userName, isEmpty); // автор не сохранился - не выдумываем
    });

    test('404 → Failure.server', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.documentEvents("d1")}': (_) => ResponseBody.fromString('{"error":"нет"}', 404, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      });
      final res = await DocumentsRepositoryImpl(dio).events('d1');
      expect(res.isLeft, isTrue);
      expect(res.left, isA<ServerFailure>());
    });
  });

  test('маршруты документов - без ведущего слэша', () {
    expect(ApiConst.documents, 'documents');
    expect(ApiConst.documentFile('d1'), 'documents/d1/file.xlsx');
    expect(ApiConst.documentDone('d1'), 'documents/d1/done');
    expect(ApiConst.documentEvents('d1'), 'documents/d1/events');
    expect(ApiConst.documentFile('d1').startsWith('/'), isFalse);
    expect(ApiConst.documentDone('d1').startsWith('/'), isFalse);
  });

  // ADHOC-23: документ поставщика «Поступления» разбирается; у других форм его нет.
  test('документ поставщика в строке «Прихода»', () {
    final withDoc = PortalDoc.fromJson({
      'id': 'd1',
      'kind': 'receipt',
      'supplier': 'ИП Березин',
      'doc_number': 'ТН-1042/2',
      'doc_date': '01-10-2026',
      'warehouse_code': 'SHB',
      'warehouse_name': 'Шабулина',
      'created_at': '2026-10-09T10:00:00Z',
      'lines_count': 2,
      'status': 'new',
    });
    expect(withDoc.docNumber, 'ТН-1042/2');
    expect(withDoc.docDate, '01-10-2026');

    final without = PortalDoc.fromJson({
      'id': 'd2',
      'kind': 'stock_entry',
      'created_at': '2026-10-09T10:00:00Z',
    });
    expect(without.docNumber, isEmpty);
  });

  // P5-04: у «Движения» - операция и задание-основание; у других форм их нет.
  test('операция и задание в строке «Движения»', () {
    final movement = PortalDoc.fromJson({
      'id': 'd3',
      'kind': 'movement',
      'operation': 'putaway',
      'task_number': 57,
      'supplier': 'ИП Березин',
      'warehouse_name': 'Шабулина',
      'created_at': '2026-10-09T10:00:00Z',
      'status': 'new',
    });
    expect(movement.operation, 'putaway');
    expect(movement.taskNumber, 57);
    expect(movement.supplier, 'ИП Березин');

    final other = PortalDoc.fromJson({
      'id': 'd4',
      'kind': 'receipt',
      'created_at': '2026-10-09T10:00:00Z',
    });
    expect(other.operation, isEmpty);
    expect(other.taskNumber, 0);
    expect(other.executor, isEmpty);
  });

  // P6-07: перемещение - без задания, с исполнителем.
  test('перемещение в строке «Движения»: операция и исполнитель', () {
    final move = PortalDoc.fromJson({
      'id': 'd5',
      'kind': 'movement',
      'operation': 'move',
      'task_number': 0,
      'executor': 'Иванов Иван',
      'created_at': '2026-10-14T10:00:00Z',
      'status': 'new',
    });
    expect(move.operation, 'move');
    expect(move.taskNumber, 0);
    expect(move.executor, 'Иванов Иван');
  });

  // ADHOC-55: задание по решению «разместить» - основанием в колонке стоит проблема склада.
  test('размещение по проблеме: основание - номер проблемы', () {
    final doc = PortalDoc.fromJson({
      'id': 'd6',
      'kind': 'movement',
      'operation': 'putaway',
      'task_number': 2,
      'problem_number': 1,
      'created_at': '2026-10-29T12:17:00Z',
      'status': 'new',
    });
    expect(doc.problemNumber, 1);
    expect(DocForm.of('movement').party(doc), (
      main: 'Задание ЗД-000002',
      sub: 'Проблема ПБ-000001',
    ));
  });
}
