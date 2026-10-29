UPDATE report_documents SET snapshot = snapshot - 'source_number';

DROP TRIGGER report_documents_set_number ON report_documents;
DROP FUNCTION report_documents_set_number();
ALTER TABLE report_documents DROP COLUMN number;
DROP SEQUENCE report_documents_receipt_number_seq, report_documents_movement_number_seq,
              report_documents_stock_entry_number_seq, report_documents_stocktake_number_seq;

DROP TRIGGER movements_set_number ON movements;
DROP FUNCTION movements_set_number();
ALTER TABLE movements DROP COLUMN number;
DROP SEQUENCE movements_move_number_seq, movements_replenish_number_seq;

ALTER TABLE supplier_return_shipments DROP COLUMN number;
ALTER TABLE stock_entry_sessions DROP COLUMN number;
ALTER TABLE putaways DROP COLUMN number;
ALTER TABLE receipts DROP COLUMN number;
