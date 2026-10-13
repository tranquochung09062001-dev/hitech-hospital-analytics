/* =====================================================================
   01 – LÀM SẠCH raw.raw_baocaochitiet (bản chạy tự động của rawclean.sql)
   - Đã bỏ các câu SELECT khám phá, chỉ giữ các bước biến đổi
   - Chạy NGAY SAU khi Python nạp lại raw (bảng raw bị replace mỗi lần)
   ===================================================================== */

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS dwh;

/* 1. Bỏ dòng không có Mã KCB (dòng tổng / dòng trống) */
DELETE FROM raw.raw_baocaochitiet WHERE "Mã KCB" IS NULL;

/* 2. Giới tính: 1 -> Nam, còn lại -> Nữ */
DO $$
BEGIN
    IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema = 'raw' AND table_name = 'raw_baocaochitiet'
          AND column_name = 'GT') <> 'text' THEN
        ALTER TABLE raw.raw_baocaochitiet
            ALTER COLUMN "GT" TYPE text USING "GT"::int::text;
    END IF;
END $$;

UPDATE raw.raw_baocaochitiet
SET "GT" = CASE WHEN "GT" IN ('1', '1.0', 'Nam') THEN 'Nam' ELSE 'Nữ' END;

/* 3. Tự đổi kiểu cột (số nguyên / số thập phân / ngày) */
DO $$
DECLARE
    r        record;
    col      text;
    n_total  bigint;
    n_bad    bigint;
BEGIN
    FOR r IN
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'raw_baocaochitiet'
          AND data_type IN ('text', 'double precision')
    LOOP
        col := quote_ident(r.column_name);

        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE %s IS NOT NULL AND TRIM(%s::text) <> ''''', col, col)
        INTO n_total;
        CONTINUE WHEN n_total = 0;

        -- 3.1 Số nguyên (không có số 0 ở đầu)
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s::text) <> ''''
                          AND (TRIM(%s::text) !~ ''^-?\d+(\.0+)?$''
                               OR TRIM(%s::text) ~ ''^-?0\d'')', col, col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE bigint
                            USING ROUND(NULLIF(TRIM(%s::text), '''')::numeric)::bigint', col, col);
            CONTINUE;
        END IF;

        CONTINUE WHEN r.data_type <> 'text';

        -- 3.2 Số thập phân
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s) <> '''' AND TRIM(%s) !~ ''^-?\d+(\.\d+)?$''', col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE numeric
                            USING NULLIF(TRIM(%s), '''')::numeric', col, col);
            CONTINUE;
        END IF;

        -- 3.3 Ngày dd/mm/yyyy
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s) <> '''' AND TRIM(%s) !~ ''^\d{1,2}/\d{1,2}/\d{4}$''', col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE date
                            USING TO_DATE(NULLIF(TRIM(%s), ''''), ''DD/MM/YYYY'')', col, col);
            CONTINUE;
        END IF;

        -- 3.4 Ngày yyyy-mm-dd
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s) <> '''' AND TRIM(%s) !~ ''^\d{4}-\d{2}-\d{2}''', col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE date
                            USING NULLIF(TRIM(%s), '''')::date', col, col);
        END IF;
    END LOOP;
END $$;

/* 4. Trim + gộp khoảng trắng mọi cột text, chuỗi rỗng -> NULL */
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'raw' AND table_name = 'raw_baocaochitiet'
          AND data_type = 'text'
    LOOP
        EXECUTE format(
            'UPDATE raw.raw_baocaochitiet
             SET %1$I = NULLIF(TRIM(regexp_replace(%1$I, ''\s+'', '' '', ''g'')), '''')
             WHERE %1$I IS DISTINCT FROM NULLIF(TRIM(regexp_replace(%1$I, ''\s+'', '' '', ''g'')), '''')',
            r.column_name);
    END LOOP;
END $$;

/* 5. Chuẩn hóa tên cột */
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'raw' AND table_name = 'raw_baocaochitiet'
          AND column_name <> TRIM(regexp_replace(column_name, '\s+', ' ', 'g'))
    LOOP
        EXECUTE format('ALTER TABLE raw.raw_baocaochitiet RENAME COLUMN %I TO %I',
                       r.column_name, TRIM(regexp_replace(r.column_name, '\s+', ' ', 'g')));
    END LOOP;
END $$;

/* 6. Tách Tỉnh/TP, Phường/Xã từ Địa chỉ */
ALTER TABLE raw.raw_baocaochitiet
    ADD COLUMN IF NOT EXISTS "Tỉnh/TP"   text,
    ADD COLUMN IF NOT EXISTS "Phường/Xã" text;

UPDATE raw.raw_baocaochitiet
SET "Tỉnh/TP"   = NULLIF(TRIM(regexp_replace(regexp_replace("Địa chỉ", '^.*-', ''),
                                             '^(Thành phố|Tỉnh)\s+', '')), ''),
    "Phường/Xã" = NULLIF(TRIM(substring("Địa chỉ" from '-?([^-]*)-[^-]*$')), '');

/* 7. Tách Mã CD / Tên CD / Ghi chú CD từ "Chẩn đoán" */
ALTER TABLE raw.raw_baocaochitiet
    ADD COLUMN IF NOT EXISTS "Mã CD"      text,
    ADD COLUMN IF NOT EXISTS "Tên CD"     text,
    ADD COLUMN IF NOT EXISTS "Ghi chú CD" text;

UPDATE raw.raw_baocaochitiet
SET "Mã CD"      = substring("Chẩn đoán" from '\[([^\]]+)\]'),
    "Tên CD"     = TRIM(substring("Chẩn đoán" from '\]\s*([^(]*)')),
    "Ghi chú CD" = NULLIF(TRIM(substring("Chẩn đoán" from '\((.*)\)\s*$')), '');

ALTER TABLE raw.raw_baocaochitiet DROP COLUMN IF EXISTS "Chẩn đoán";
