-- ADHOC-49: откат должностей к ролям employee/admin.
--
-- Роль восстанавливается по праву «пользователи и должности»: у кого оно было, тот управлял
-- системой - admin; остальные - employee. Тонкость прав откат теряет.
ALTER TABLE users ADD COLUMN role text NOT NULL DEFAULT 'employee'
    CHECK (role IN ('employee','admin'));
UPDATE users u SET role = 'admin'
FROM positions p
WHERE p.id = u.position_id AND (p.is_system OR 'users' = ANY (p.rights));

ALTER TABLE users DROP COLUMN position_id;
DROP TABLE positions;
