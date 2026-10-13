CREATE SCHEMA raw;      -- Bronze layer
CREATE SCHEMA staging;  -- Silver layer
CREATE SCHEMA dwh;      -- Gold layer

Select * from raw.raw_baocaochitiet

SELECT
    kv.key                                              AS column_name,
    COUNT(*) FILTER (WHERE kv.value = 'null'::jsonb)    AS null_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE kv.value = 'null'::jsonb) / COUNT(*), 2) AS null_pct
FROM raw.raw_baocaochitiet t
CROSS JOIN LATERAL jsonb_each(to_jsonb(t)) AS kv
GROUP BY kv.key
ORDER BY null_count DESC;

Select * FROM raw."raw_Kinhmat" where "Tiền VAT" is Null
SELECT
    kv.key                                              AS column_name,
    COUNT(*) FILTER (WHERE kv.value = 'null'::jsonb)    AS null_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE kv.value = 'null'::jsonb) / COUNT(*), 2) AS null_pct
FROM raw."raw_Kinhmat" t
CROSS JOIN LATERAL jsonb_each(to_jsonb(t)) AS kv
GROUP BY kv.key
ORDER BY null_count DESC;

Delete from raw.raw_baocaochitiet where "Mã KCB" IS null

SELECT
    ordinal_position AS stt,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'raw'
  AND table_name   = 'raw_baocaochitiet'
ORDER BY ordinal_position;

alter table raw.raw_baocaochitiet 
alter column "GT" type text Using "GT"::int::text;

update raw.raw_baocaochitiet set "GT"= Case "GT" when '1' then 'Nam' else 'Nữ' END;

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

        -- Bỏ qua cột toàn NULL / rỗng
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE %s IS NOT NULL AND TRIM(%s::text) <> ''''', col, col)
        INTO n_total;
        CONTINUE WHEN n_total = 0;
        -- 1. Số nguyên (không có số 0 ở đầu)
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s::text) <> ''''
                          AND (TRIM(%s::text) !~ ''^-?\d+(\.0+)?$''
                               OR TRIM(%s::text) ~ ''^-?0\d'')', col, col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE bigint
                            USING ROUND(NULLIF(TRIM(%s::text), '''')::numeric)::bigint', col, col);
            RAISE NOTICE '% -> bigint', r.column_name;
            CONTINUE;
        END IF;

        CONTINUE WHEN r.data_type <> 'text';

        -- 2. Số thập phân
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s) <> '''' AND TRIM(%s) !~ ''^-?\d+(\.\d+)?$''', col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE numeric
                            USING NULLIF(TRIM(%s), '''')::numeric', col, col);
            RAISE NOTICE '% -> numeric', r.column_name;
            CONTINUE;
        END IF;

        -- 3. Ngày dd/mm/yyyy
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s) <> '''' AND TRIM(%s) !~ ''^\d{1,2}/\d{1,2}/\d{4}$''', col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE date
                            USING TO_DATE(NULLIF(TRIM(%s), ''''), ''DD/MM/YYYY'')', col, col);
            RAISE NOTICE '% -> date', r.column_name;
            CONTINUE;
        END IF;

        -- 4. Ngày yyyy-mm-dd
        EXECUTE format('SELECT COUNT(*) FROM raw.raw_baocaochitiet
                        WHERE TRIM(%s) <> '''' AND TRIM(%s) !~ ''^\d{4}-\d{2}-\d{2}''', col, col)
        INTO n_bad;
        IF n_bad = 0 THEN
            EXECUTE format('ALTER TABLE raw.raw_baocaochitiet ALTER COLUMN %s TYPE date
                            USING NULLIF(TRIM(%s), '''')::date', col, col);
            RAISE NOTICE '% -> date', r.column_name;
        END IF;
    END LOOP;
END $$;

ALTER TABLE raw.raw_baocaochitiet ADD COLUMN "Tên CD" text;

UPDATE raw.raw_baocaochitiet
SET "Tên CD" = TRIM(regexp_replace(
                 regexp_replace("Chẩn đoán", '^\s*\[[^\]]*\]\s*', ''),
                 '\(\s*\)\s*$', ''));

DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'raw_baocaochitiet'
          AND data_type    = 'text'
    LOOP
        EXECUTE format(
            'UPDATE raw.raw_baocaochitiet
             SET %1$I = NULLIF(TRIM(regexp_replace(%1$I, ''\s+'', '' '', ''g'')), '''')
             WHERE %1$I IS DISTINCT FROM NULLIF(TRIM(regexp_replace(%1$I, ''\s+'', '' '', ''g'')), '''')',
            r.column_name);
        RAISE NOTICE 'Đã trim: %', r.column_name;
    END LOOP;
END $$;

DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'raw_baocaochitiet'
          AND column_name <> TRIM(regexp_replace(column_name, '\s+', ' ', 'g'))
    LOOP
        EXECUTE format('ALTER TABLE raw.raw_baocaochitiet RENAME COLUMN %I TO %I',
                       r.column_name,
                       TRIM(regexp_replace(r.column_name, '\s+', ' ', 'g')));
        RAISE NOTICE 'Đổi tên: "%"', r.column_name;
    END LOOP;
END $$;
CREATE SCHEMA IF NOT EXISTS public
CREATE EXTENSION IF NOT EXISTS unaccent;

SELECT
    lower(unaccent("Tên CD"))             AS nhom,
    array_agg(DISTINCT "Tên CD")          AS cac_cach_viet,
    COUNT(*)                              AS so_dong
FROM raw.raw_baocaochitiet
WHERE "Tên CD" IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT "Tên CD") > 1
ORDER BY so_dong DESC;

SELECT
    lower(unaccent("Nguồn giới thiệu"))      AS nhom,
    array_agg(DISTINCT "Nguồn giới thiệu")   AS cac_cach_viet,
    COUNT(*)                                 AS so_dong
FROM raw.raw_baocaochitiet
WHERE "Nguồn giới thiệu" IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT "Nguồn giới thiệu") > 1
ORDER BY so_dong DESC;

select * from raw.raw_baocaochitiet

ALTER TABLE raw.raw_baocaochitiet
    ADD COLUMN "Tỉnh/TP"   text,
    ADD COLUMN "Phường/Xã" text;

UPDATE raw.raw_baocaochitiet
SET "Tỉnh/TP"   = NULLIF(TRIM(regexp_replace(regexp_replace("Địa chỉ", '^.*-', ''),
                                             '^(Thành phố|Tỉnh)\s+', '')), ''),
    "Phường/Xã" = NULLIF(TRIM(substring("Địa chỉ" from '-?([^-]*)-[^-]*$')), '');
ALTER TABLE raw.raw_baocaochitiet
    ADD COLUMN IF NOT EXISTS "Mã CD"      text,
    ADD COLUMN IF NOT EXISTS "Tên CD"     text,
    ADD COLUMN IF NOT EXISTS "Ghi chú CD" text;

UPDATE raw.raw_baocaochitiet
SET "Mã CD"      = substring("Chẩn đoán" from '\[([^\]]+)\]'),
    "Tên CD"     = TRIM(substring("Chẩn đoán" from '\]\s*([^(]*)')),
    "Ghi chú CD" = NULLIF(TRIM(substring("Chẩn đoán" from '\((.*)\)\s*$')), '');
ALTER TABLE raw.raw_baocaochitiet DROP COLUMN "Chẩn đoán";

SELECT
    COUNT(*)                                    AS tong_dong,
    COUNT(DISTINCT to_jsonb(t) - 'STT')         AS dong_duy_nhat,
    COUNT(*) - COUNT(DISTINCT to_jsonb(t) - 'STT') AS dong_trung
FROM raw.raw_baocaochitiet t;