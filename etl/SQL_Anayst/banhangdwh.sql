/* =====================================================================
   STAGING BÁN HÀNG: raw."raw_Kinhmat" (quầy kính) + raw."raw_Thuoc" (quầy thuốc)
                     ->  staging.dim_san_pham, staging.dim_kho, staging.fact_ban_hang
   Grain fact: 1 dòng = 1 mặt hàng trong 1 lần mua
   Ghi chú: "Mã KH" trong 2 báo cáo này là mã từng LẦN MUA (cùng 1 người có
   nhiều mã) -> dùng làm mã đơn, không làm dim khách hàng.
   ===================================================================== */

 DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name IN ('raw_Kinhmat', 'raw_Thuoc')
          AND column_name <> trim(regexp_replace(column_name, '\s+', ' ', 'g'))
    LOOP
        EXECUTE format('ALTER TABLE raw.%I RENAME COLUMN %I TO %I',
                       r.table_name, r.column_name,
                       trim(regexp_replace(r.column_name, '\s+', ' ', 'g')));
    END LOOP;
END $$;
CREATE SCHEMA IF NOT EXISTS staging;
 
DROP TABLE IF EXISTS staging.fact_ban_hang CASCADE;
DROP TABLE IF EXISTS staging.dim_san_pham  CASCADE;
DROP TABLE IF EXISTS staging.dim_kho       CASCADE;

 SELECT table_name, ordinal_position, '"' || column_name || '"' AS ten_cot
FROM information_schema.columns
WHERE table_schema = 'raw'
  AND table_name IN ('raw_Kinhmat', 'raw_Thuoc')
ORDER BY table_name, ordinal_position;
 
/* 0. Gộp 2 nguồn + CAST --------------------------------------------- */
DROP TABLE IF EXISTS tmp_bh_src;
CREATE TEMP TABLE tmp_bh_src AS
SELECT
    CAST(x.loai_quay AS varchar(10))                                    AS loai_quay,
    CAST(x."Mã KH"   AS bigint)                                         AS ma_kh,
    CAST(trim(regexp_replace(x."Tên KH",   '\s+', ' ', 'g')) AS text)   AS ten_kh,
    CAST(x."STT"     AS int)                                            AS stt_trong_don,
    CAST(x."Ngày"    AS timestamp)                                      AS ngay,
    CAST(trim(x."Mã hàng") AS varchar(30))                              AS ma_hang,
    CAST(trim(regexp_replace(x."Tên hàng", '\s+', ' ', 'g')) AS text)   AS ten_hang,
    CAST(trim(x."ĐVT") AS varchar(20))                                  AS dvt,
    CAST(COALESCE(x."Số lượng", 0)  AS numeric(18,2))                   AS so_luong,
    CAST(COALESCE(x."Đơn giá", 0)   AS numeric(18,2))                   AS don_gia,
    CAST(COALESCE(x."Tiền bán", 0)  AS numeric(18,2))                   AS tien_ban,
    CAST(COALESCE(x."Tiền giảm", 0) AS numeric(18,2))                   AS tien_giam,
    CAST(COALESCE(x."Tiền thu", 0)  AS numeric(18,2))                   AS tien_thu,
    CAST(COALESCE(x."Tiền VAT", 0)  AS numeric(18,2))                   AS tien_vat,
    CAST(COALESCE(x."Kho", 'Không xác định') AS text)                   AS ten_kho
FROM (
    SELECT 'Kính'  AS loai_quay, "Mã KH", "Tên KH", "STT", "Ngày", "Mã hàng", "Tên hàng", "ĐVT", "Số lượng", "Đơn giá", "Tiền bán", "Tiền giảm", "Tiền thu", "Tiền VAT", "Kho"
    FROM raw."raw_Kinhmat"
    UNION ALL
    SELECT 'Thuốc' AS loai_quay, "Mã KH", "Tên KH", "STT", "Ngày", "Mã hàng", "Tên hàng", "ĐVT", "Số lượng", "Đơn giá", "Tiền bán", "Tiền giảm", "Tiền thu", "Tiền VAT", "Kho"
    FROM raw."raw_Thuoc"
) x;
 
 
/* 1. Tạo key ngay trên bảng nguồn ----------------------------------
   - ma_don: tiền tố K-/T- để 2 quầy không bao giờ trùng mã
   - date_key: yyyymmdd, dùng chung dim_ngay với khám                   */
DROP TABLE IF EXISTS tmp_bh_key;
CREATE TEMP TABLE tmp_bh_key AS
SELECT
    s.*,
    CAST(left(s.loai_quay, 1) || '-' || s.ma_kh AS varchar(40))   AS ma_don,
    CAST(to_char(s.ngay, 'YYYYMMDD') AS int)                      AS date_key,
    CAST(DENSE_RANK() OVER (ORDER BY s.ten_kho) AS int)           AS kho_key
FROM tmp_bh_src s;
 
 
/* 2. dim_san_pham (khóa ma_hang) + nhóm hàng ------------------------
   Thứ tự WHEN quan trọng                                               */
CREATE TABLE staging.dim_san_pham AS
SELECT DISTINCT ON (ma_hang)
    ma_hang,
    ten_hang,
    dvt,
    loai_quay,
    CAST(CASE
        /* ---------- Quầy kính ---------- */
        WHEN loai_quay = 'Kính' AND ma_hang ILIKE 'TAUN%'                  THEN 'Tạm ứng'
        WHEN loai_quay = 'Kính' AND (ma_hang ILIKE 'RATD%'
          OR ten_hang ILIKE ANY (ARRAY['DD %','%dung dịch%','Hidro%','%nước rửa%']))
                                                                           THEN 'Dung dịch kính'
        WHEN loai_quay = 'Kính' AND ma_hang ILIKE 'KATD%'                  THEN 'Kính áp tròng đêm (Ortho-K)'
        WHEN loai_quay = 'Kính' AND (ma_hang ILIKE 'KAT-%' OR ma_hang ILIKE 'KAT0%'
          OR (ten_hang ILIKE '%áp tròng%' AND ten_hang NOT ILIKE 'Gắp%'))  THEN 'Kính áp tròng'
        WHEN loai_quay = 'Kính' AND (ma_hang ~ '^1\.\d{2}-' OR ma_hang ILIKE 'RODE%')
                                                                           THEN 'Tròng kính'
        WHEN loai_quay = 'Kính' AND (ten_hang ILIKE ANY (ARRAY['GK %','Gọng%'])
          OR ma_hang ILIKE 'GANC%')                                        THEN 'Gọng kính'
        WHEN loai_quay = 'Kính' AND ten_hang ILIKE 'Kính %'                THEN 'Kính mát / thời trang'
        WHEN loai_quay = 'Kính' AND ten_hang ILIKE ANY
             (ARRAY['%hộp%','%cao su%','%gắp%','%bịt mắt%','%khăn%'])      THEN 'Phụ kiện kính'
        WHEN loai_quay = 'Kính'                                            THEN 'Phí / Khác'
 
        /* ---------- Quầy thuốc ---------- */
        WHEN ma_hang ILIKE 'TPCN%'
          OR ten_hang ILIKE ANY (ARRAY['Lutein%','Regatonic%','Tam thất%','Ginkgo%',
                                       '%omega%','%vital%','%visio%'])     THEN 'Thực phẩm chức năng'
        WHEN ten_hang ILIKE ANY (ARRAY['%gạc%','%chườm%','%kính%','%bông%'])
                                                                           THEN 'Vật tư y tế'
        WHEN ten_hang ILIKE ANY (ARRAY['%solu medrol%','%tiêm%'])         THEN 'Thuốc tiêm'
        WHEN ten_hang ILIKE ANY (ARRAY['%ophthalmic%','%opthalmic%','%nhỏ mắt%'])
                                                                           THEN 'Thuốc nhỏ mắt'
        WHEN ten_hang ILIKE ANY (ARRAY['%mỡ%','%gel%'])
          OR dvt ILIKE 'Tuýp'                                              THEN 'Thuốc mỡ / gel mắt'
        WHEN dvt ILIKE ANY (ARRAY['Lọ','Tép','Ống'])                       THEN 'Thuốc nhỏ mắt'
        WHEN dvt ILIKE ANY (ARRAY['Viên','Hộp','Gói','Chai'])              THEN 'Thuốc uống'
        ELSE 'Thuốc khác'
    END AS varchar(40))                                                    AS nhom_hang,
    -- Chiết suất tròng kính: "1.67-04" -> 1.67 (thuốc để trống)
    CAST(substring(ma_hang FROM '^(1\.\d{2})-') AS numeric(4,2))           AS chiet_suat
FROM tmp_bh_key
ORDER BY ma_hang, ngay DESC;
 
 
/* 3. dim_kho (khóa phụ kho_key) ------------------------------------- */
CREATE TABLE staging.dim_kho AS
SELECT DISTINCT kho_key, ten_kho, loai_quay
FROM tmp_bh_key;
 
 
/* 4. fact_ban_hang – lấy key có sẵn, không join --------------------- */
CREATE TABLE staging.fact_ban_hang AS
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY ngay, ma_don, stt_trong_don) AS bigint) AS fact_id,
    ma_don,
    ma_kh,
    ten_kh,
    date_key,
    ngay,
    ma_hang,
    kho_key,
    stt_trong_don,
    so_luong,
    don_gia,
    tien_ban,
    tien_giam,
    tien_thu,
    tien_vat
FROM tmp_bh_key;
 
 
/* 5. Khóa chính / khóa ngoại ---------------------------------------- */
ALTER TABLE staging.dim_san_pham  ADD PRIMARY KEY (ma_hang);
ALTER TABLE staging.dim_kho       ADD PRIMARY KEY (kho_key);
ALTER TABLE staging.fact_ban_hang ADD PRIMARY KEY (fact_id);
 
ALTER TABLE staging.fact_ban_hang
    ADD FOREIGN KEY (ma_hang) REFERENCES staging.dim_san_pham (ma_hang),
    ADD FOREIGN KEY (kho_key) REFERENCES staging.dim_kho (kho_key);
 
 
/* 6. Kiểm tra ------------------------------------------------------ */
SELECT 'raw kính' AS nguon, COUNT(*) AS so_dong, SUM("Tiền thu") AS tien_thu FROM raw."raw_Kinhmat"
UNION ALL SELECT 'raw thuốc', COUNT(*), SUM("Tiền thu") FROM raw."raw_Thuoc"
UNION ALL
SELECT 'fact ' || k.loai_quay, COUNT(*), SUM(f.tien_thu)
FROM staging.fact_ban_hang f JOIN staging.dim_kho k ON k.kho_key = f.kho_key
GROUP BY k.loai_quay;
 
-- Doanh thu theo nhóm hàng (rà lại nhóm "Phí / Khác", "Thuốc khác")
SELECT p.loai_quay, p.nhom_hang, COUNT(DISTINCT p.ma_hang) AS so_ma_hang,
       COUNT(*) AS so_dong, SUM(f.tien_thu) AS tien_thu
FROM staging.fact_ban_hang f
JOIN staging.dim_san_pham p ON p.ma_hang = f.ma_hang
GROUP BY 1, 2
ORDER BY 1, tien_thu DESC;
 