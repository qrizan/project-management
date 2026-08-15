-- User demo untuk verifikasi login dan uji restore. `data/SQL.txt` hanya memuat
-- Category dan Project, tidak memuat User sama sekali.
--
-- Hash bcrypt di bawah adalah hash dari password `password`, disalin dari user
-- yang sudah terbukti bisa login. Ditulis apa adanya, bukan di-generate saat
-- deploy, supaya hasil seed sama persis di setiap kali dijalankan.
--
-- Ini kredensial demo. Jangan dipakai di lingkungan yang terjangkau publik.
INSERT INTO "User" ("name", "email", "password", "role")
VALUES (
    'John Doe',
    'johndoe@mail.com',
    '$2b$10$4hvkqYkeBFXUP8LEQr3e1.8A4rvmfKQhT5rkOexrvYQTi6RhDtUMy',
    'ADMINISTRATOR'
)
ON CONFLICT ("email") DO NOTHING;
