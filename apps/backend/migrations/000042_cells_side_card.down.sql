-- ADHOC-57: откат признака «на карточке» у ячейки — признак возвращается стеллажу: карточка
-- у стеллажа, где была хоть одна ячейка с галочкой.
ALTER TABLE racks
    ADD COLUMN side_card boolean NOT NULL DEFAULT false;  -- печатать карточку на стойку

UPDATE racks r SET side_card = true
FROM (SELECT rack_id FROM cells WHERE rack_id IS NOT NULL GROUP BY rack_id HAVING bool_or(side_card)) c
WHERE c.rack_id = r.id;

ALTER TABLE cells DROP COLUMN IF EXISTS side_card;
