# Эталоны формата батча операций

Тела запроса `POST /api/v1/operations` **в том виде, в каком их шлёт приложение ТСД**. Файлы
сняты с настоящего клиента и служат контрактом между двумя языками.

| Файл                  | Операции                          | Go-тест                           | Dart-тест (`apps/craft_wms`)                            |
|-----------------------|-----------------------------------|-----------------------------------|---------------------------------------------------------|
| `outbox_batch.json`   | привязка и отвязка ШК (P2-08)     | `operations_http_test.go`         | `test/core/wire_contract_test.dart`                     |
| `receipt_submit.json` | приёмка: короб и россыпь (P4-11D) | `receiving_scenario_http_test.go` | `test/features/receipt/receipt_wire_contract_test.dart` |
| `receipt_submit_cz.json` | приёмка с марками ЧЗ: короб ЧЗ с упаковкой и марки россыпью, одна с расхождением (CZ-05) | `receiving_cz_http_test.go` | `test/features/receipt/receipt_cz_wire_contract_test.dart` |
| `stock_entry_checkpoint.json` | **тело** `POST /stock-entry/sessions/{id}/cells`: ячейка ввода остатков — россыпь, свой короб, короб ЧЗ с упаковкой, марки россыпью, одна с расхождением (ADHOC-46) | `stock_entry_http_test.go` | `test/features/stock_entry/stock_entry_wire_contract_test.dart` |
| `putaway_submit.json` | размещение: короб и россыпь (P5-02) | `putaway_scenario_http_test.go` | `test/features/putaway/putaway_cubit_test.dart` |
| `movement_submit.json` | движение: ГЕ целиком и товар между коробами и россыпью (P6-03); Go-тест гоняет его и пополнением (P6-05) | `movement_http_test.go` | `test/features/movement/movement_cubit_test.dart` |
| `movement_submit_cz.json` | движение марками ЧЗ: марки россыпью в короб ЧЗ и марка из короба ЧЗ россыпью (CZ-06) | `movement_http_test.go` | `test/features/movement/movement_cubit_test.dart` |
| `problem_submit.json` | проблема склада: россыпь в «Брак», короб в «Изолятор» (P6-07-1); вместо id складов — коды | `problem_http_test.go` | `test/features/problems/problem_cubit_test.dart` |
| `return_submit.json` | отгрузка возврата поставщику: короб и россыпь одним сеансом (ADHOC-31); вместо id задания — `TASK` | `return_http_test.go` | `test/features/supplier_return/supplier_return_cubit_test.dart` |
| `contents_snapshot.json` | **ответ** `GET /contents/snapshot`: снимок для кэша ТСД (P5-05), с кодом короба ЧЗ и марками (CZ-06) | `contents_http_test.go` | `test/features/contents/contents_repository_test.dart` |
| `problems_resolved.json` | **ответ** `GET /problems/resolved`: лента решённых проблем на ТСД (ADHOC-34), с `photos` (ADHOC-45) | `problem_http_test.go` | `test/features/problems/resolved_problems_test.dart` |
| `cz_scan_mark.json` | **ответ** `POST /cz/scan` по марке: данные ЧЗ, товар, место в WMS (CZ-04) | `cz_scan_http_test.go` | `test/features/cz/cz_scan_repository_test.dart` |
| `cz_scan_box.json` | **ответ** `POST /cz/scan` по коробу: ГЕ и состав по товару и партии (CZ-04), упаковка каждой единицы (CZ-05) | `cz_scan_http_test.go` | `test/features/cz/cz_scan_repository_test.dart` |

Go-тест скармливает файл настоящему роутеру и проверяет, что операции применяются. Эталоны
ответа (`contents_snapshot.json`, `problems_resolved.json`, `cz_scan_*.json`) работают наоборот: Go-тест требует, чтобы настоящий роутер
отдал ровно его (кроме значений, которые выдаёт сервер: моменты времени, id партий и
внутреннего склада), а Dart-тест разбирает его так же, как ответ сервера. Dart-тест
проверяет, что клиент действительно шлёт именно это: батч снимается с настоящего пути отправки
(cubit → очередь → движок синхронизации), а не собирается в тесте руками.

Зачем так. До появления файла формат утверждался дважды независимо: в Dart-тесте руками написан
ожидаемый JSON, в Go-тесте руками написаны структуры. Разойдись имя поля — обе стороны остались
бы зелёными, а терминал молча перестал бы синхронизироваться. Теперь расхождение роняет тест.

Меняете формат — правьте файл, и обе стороны сразу скажут, кто из них отстал.
