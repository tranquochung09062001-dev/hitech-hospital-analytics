/* =====================================================================
   STAGING: raw.raw_baocaochitiet  ->  staging (dim + fact)
   Kiểu CREATE TABLE ... AS SELECT + CAST (không dùng INSERT INTO)
   Grain fact: 1 dòng = 1 dịch vụ trong 1 lượt khám
   ===================================================================== */
 
CREATE SCHEMA IF NOT EXISTS staging;
 
DROP TABLE IF EXISTS staging.fact_kham            CASCADE;
DROP TABLE IF EXISTS staging.dim_benh_nhan        CASCADE;
DROP TABLE IF EXISTS staging.dim_dia_ly           CASCADE;
DROP TABLE IF EXISTS staging.dim_dich_vu          CASCADE;
DROP TABLE IF EXISTS staging.dim_chan_doan        CASCADE;
DROP TABLE IF EXISTS staging.dim_nguon_gioi_thieu CASCADE;
DROP TABLE IF EXISTS staging.dim_ngay             CASCADE;
 
 
/* 0. Lấy từ raw (đã làm sạch) – chỉ CAST kiểu + sửa điện thoại -------
   - Điện thoại: raw lưu bigint nên mất số 0 đầu -> CAST sang text, thêm '0'
   - COALESCE ở các cột làm khóa dim để dòng NULL vẫn nối được           */
DROP TABLE IF EXISTS tmp_src;
CREATE TEMP TABLE tmp_src AS
SELECT
    CAST("STT"              AS bigint)        AS stt,
    CAST("Mã KCB"           AS bigint)        AS ma_kcb,
    CAST("Mã BN"            AS bigint)        AS ma_bn,
    CAST("Ngày cấp mã"      AS date)          AS ngay_cap_ma,
    CAST(to_timestamp(left(CAST("Ngày đăng ký" AS text), 16),
                      'DD/MM/YYYY HH24:MI') AS timestamp) AS ngay_dang_ky,
    CAST("Họ tên bệnh nhân" AS text)          AS ho_ten,
    CAST("GT"               AS varchar(10))   AS gioi_tinh,
    CAST(CASE
        WHEN "Tuổi" ILIKE '%tuổi%'                           THEN substring("Tuổi" FROM '\d+')
        WHEN "Tuổi" ILIKE '%tháng%' OR "Tuổi" ILIKE '%ngày%' THEN '0'
        ELSE substring(CAST("Tuổi" AS text) FROM '\d+')
    END AS int)                               AS tuoi,
    -- Thêm lại số 0 đầu cho MỌI đầu số (03, 05, 06, 07, 08, 09...):
    --   9 chữ số  -> di động 10 số   (9xxxxxxxx  -> 09xxxxxxxx)
    --   10 chữ số bắt đầu bằng 2 -> cố định 11 số (2438xxxxxx -> 02438xxxxxx)
    CAST(CASE
        WHEN CAST("Điện thoại" AS text) LIKE '0%'                THEN CAST("Điện thoại" AS text)
        WHEN length(CAST("Điện thoại" AS text)) = 9              THEN '0' || CAST("Điện thoại" AS text)
        WHEN length(CAST("Điện thoại" AS text)) = 10
             AND CAST("Điện thoại" AS text) LIKE '2%'             THEN '0' || CAST("Điện thoại" AS text)
        ELSE CAST("Điện thoại" AS text)
    END AS varchar(15))                       AS dien_thoai,
    CAST("Địa chỉ"          AS text)          AS dia_chi,
    CAST(COALESCE("Phường/Xã",        'Không xác định') AS text)        AS phuong_xa,
    CAST(COALESCE("Tỉnh/TP",          'Không xác định') AS text)        AS tinh_tp,
    CAST(COALESCE("Dịch vụ",          'Không xác định') AS text)        AS dich_vu,
    CAST(COALESCE("Mã CD",            'UNK')            AS varchar(10)) AS ma_cd,
    CAST("Tên CD"           AS text)          AS ten_cd,
    CAST(COALESCE("Nguồn giới thiệu", 'Không xác định') AS text)        AS nguon_gioi_thieu,
    CAST(COALESCE("Doanh thu", 0)       AS numeric(18,2)) AS doanh_thu,
    CAST(COALESCE("Giảm giá", 0)        AS numeric(18,2)) AS giam_gia,
    CAST(COALESCE("Doanh thu thuần", 0) AS numeric(18,2)) AS doanh_thu_thuan,
    CAST(COALESCE("Tiền trừ BHYT", 0)   AS numeric(18,2)) AS tien_bhyt,
    CAST(COALESCE("BN chi trả", 0)      AS numeric(18,2)) AS bn_chi_tra,
    CAST("Ghi chú"          AS text)          AS ghi_chu,
    CAST("Tư vấn điều trị"  AS text)          AS tu_van_dieu_tri,
    CAST("Người giới thiệu" AS text)          AS nguoi_gioi_thieu,
    CAST("Ghi chú CD"       AS text)          AS ghi_chu_cd
FROM raw.raw_baocaochitiet;
 
-- Tạo khóa phụ ngay trên bảng nguồn: cùng giá trị -> cùng key
DROP TABLE IF EXISTS tmp_key;
CREATE TEMP TABLE tmp_key AS
SELECT
    s.*,
    CAST(DENSE_RANK() OVER (ORDER BY s.dich_vu)               AS int) AS dich_vu_key,
    CAST(DENSE_RANK() OVER (ORDER BY s.nguon_gioi_thieu)      AS int) AS nguon_key,
    CAST(DENSE_RANK() OVER (ORDER BY s.tinh_tp, s.phuong_xa)  AS int) AS dia_ly_key,
    CAST(to_char(s.ngay_dang_ky, 'YYYYMMDD')                  AS int) AS date_key
FROM tmp_src s;
 
 
/* 1. dim_dia_ly (khóa phụ dia_ly_key) ------------------------------ */
CREATE TABLE staging.dim_dia_ly AS
SELECT DISTINCT dia_ly_key, phuong_xa, tinh_tp
FROM tmp_key;
 
 
/* 2. dim_benh_nhan (khóa ma_bn) – lấy lần đăng ký gần nhất ---------- */
CREATE TABLE staging.dim_benh_nhan AS
SELECT DISTINCT ON (ma_bn)
    ma_bn,
    ho_ten,
    gioi_tinh,
    CAST(EXTRACT(YEAR FROM ngay_dang_ky) AS int) - tuoi AS nam_sinh,
    dien_thoai,
    dia_chi,
    dia_ly_key,
    ngay_cap_ma
FROM tmp_key
WHERE ma_bn IS NOT NULL
ORDER BY ma_bn, ngay_dang_ky DESC NULLS LAST;
 
 
/* 3. dim_dich_vu (khóa phụ dich_vu_key) + nhóm dịch vụ BV mắt -------
   Thứ tự WHEN quan trọng: Phẫu thuật > Thủ thuật > Khúc xạ > CLS > Khám
   ("Thẻ khám tật khúc xạ" có chữ "khám" nhưng phải vào Khúc xạ)        */
CREATE TABLE staging.dim_dich_vu AS
SELECT DISTINCT
    dich_vu_key,
    dich_vu AS ten_dich_vu,
    CAST(CASE
        WHEN dich_vu ILIKE ANY (ARRAY['%phẫu thuật%','%phaco%','%lasik%','%femto%',
                                      '%smile%','%mộng%','%quặm%','%sụp mi%'])
            THEN 'Phẫu thuật'
        WHEN dich_vu ILIKE ANY (ARRAY['%thủ thuật%','%dị vật%','%lệ đạo%','%chắp%',
                                      '%lẹo%','%tiêm%','%laser%'])
            THEN 'Thủ thuật'
        WHEN dich_vu ILIKE ANY (ARRAY['%khúc xạ%','%thử kính%','%đo kính%','%ortho%',
                                      '%cận thị%','%áp tròng%'])
            THEN 'Khúc xạ'
        WHEN dich_vu ILIKE ANY (ARRAY['%OCT%','%siêu âm%','%chụp%','%nhãn áp%',
                                      '%sinh trắc%','%thị trường%','%đo %','%xét nghiệm%'])
            THEN 'Cận lâm sàng'
        WHEN dich_vu ILIKE '%khám%'
            THEN 'Khám'
        ELSE 'Khác'
    END AS text) AS nhom_dich_vu
FROM tmp_key;
 
 
/* 4. dim_chan_doan (khóa ma_cd) – tên xuất hiện nhiều nhất ---------- */
CREATE TABLE staging.dim_chan_doan AS
SELECT DISTINCT ON (ma_cd)
    ma_cd,
    CAST(CASE WHEN ma_cd = 'UNK' THEN 'Không xác định' ELSE ten_cd END AS text) AS ten_cd,
    CAST(CASE WHEN ma_cd = 'UNK' THEN 'UNK' ELSE split_part(ma_cd, '.', 1) END AS varchar(10)) AS nhom_icd
FROM (SELECT ma_cd, ten_cd, COUNT(*) AS n FROM tmp_src GROUP BY ma_cd, ten_cd) x
ORDER BY ma_cd, (ten_cd IS NULL), n DESC;
 
 
/* 5. dim_nguon_gioi_thieu (khóa phụ nguon_key) --------------------- */
CREATE TABLE staging.dim_nguon_gioi_thieu AS
SELECT DISTINCT nguon_key, nguon_gioi_thieu
FROM tmp_key;
 
 
/* 6. dim_ngay (khóa date_key = yyyymmdd) --------------------------- */
CREATE TABLE staging.dim_ngay AS
SELECT
    CAST(to_char(d, 'YYYYMMDD') AS int)            AS date_key,
    CAST(d AS date)                                AS ngay,
    CAST(EXTRACT(DAY     FROM d) AS int)           AS ngay_trong_thang,
    CAST(EXTRACT(MONTH   FROM d) AS int)           AS thang,
    'Tháng ' || CAST(EXTRACT(MONTH FROM d) AS int) AS ten_thang,
    CAST(EXTRACT(QUARTER FROM d) AS int)           AS quy,
    CAST(EXTRACT(YEAR    FROM d) AS int)           AS nam,
    CAST(EXTRACT(ISODOW  FROM d) AS int)           AS thu_trong_tuan,   -- 1 = Thứ 2 ... 7 = CN
    (ARRAY['Thứ 2','Thứ 3','Thứ 4','Thứ 5','Thứ 6','Thứ 7','Chủ nhật'])
        [CAST(EXTRACT(ISODOW FROM d) AS int)]      AS ten_thu,
    EXTRACT(ISODOW FROM d) IN (6, 7)               AS la_cuoi_tuan
FROM generate_series(
        (SELECT date_trunc('year', MIN(LEAST(CAST(ngay_dang_ky AS date), ngay_cap_ma))) FROM tmp_src),
        (SELECT date_trunc('year', MAX(GREATEST(CAST(ngay_dang_ky AS date), ngay_cap_ma)))
                + interval '1 year - 1 day' FROM tmp_src),
        interval '1 day') AS d;
 
 
/* 7. fact_kham – lấy key có sẵn trong tmp_key, KHÔNG join ------------------------ */
CREATE TABLE staging.fact_kham AS
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY s.stt) AS bigint)      AS fact_id,
    s.stt                                                   AS stt_nguon,
    s.ma_kcb,
    s.ma_bn,
    s.date_key,
    s.ngay_dang_ky,
    s.dich_vu_key,
    s.ma_cd,
    s.nguon_key,
    s.dia_ly_key,
    s.tuoi,
    CAST(CASE
        WHEN s.tuoi IS NULL THEN 'Không xác định'
        WHEN s.tuoi < 6   THEN '0-5'
        WHEN s.tuoi < 16  THEN '6-15'
        WHEN s.tuoi < 26  THEN '16-25'
        WHEN s.tuoi < 41  THEN '26-40'
        WHEN s.tuoi < 61  THEN '41-60'
        ELSE '60+'
    END AS varchar(20))                                     AS nhom_tuoi,
    s.doanh_thu, s.giam_gia, s.doanh_thu_thuan, s.tien_bhyt, s.bn_chi_tra,
    s.ghi_chu, s.tu_van_dieu_tri, s.nguoi_gioi_thieu, s.ghi_chu_cd
FROM tmp_key s;
 
 
/* 8. Khóa chính / khóa ngoại (thêm sau khi tạo bảng) --------------- */
ALTER TABLE staging.dim_dia_ly           ADD PRIMARY KEY (dia_ly_key);
ALTER TABLE staging.dim_benh_nhan        ADD PRIMARY KEY (ma_bn);
ALTER TABLE staging.dim_dich_vu          ADD PRIMARY KEY (dich_vu_key);
ALTER TABLE staging.dim_chan_doan        ADD PRIMARY KEY (ma_cd);
ALTER TABLE staging.dim_nguon_gioi_thieu ADD PRIMARY KEY (nguon_key);
ALTER TABLE staging.dim_ngay             ADD PRIMARY KEY (date_key);
ALTER TABLE staging.fact_kham            ADD PRIMARY KEY (fact_id);
 
ALTER TABLE staging.dim_benh_nhan
    ADD FOREIGN KEY (dia_ly_key)  REFERENCES staging.dim_dia_ly (dia_ly_key);
 
ALTER TABLE staging.fact_kham
    ADD FOREIGN KEY (ma_bn)       REFERENCES staging.dim_benh_nhan (ma_bn),
    ADD FOREIGN KEY (date_key)    REFERENCES staging.dim_ngay (date_key),
    ADD FOREIGN KEY (dich_vu_key) REFERENCES staging.dim_dich_vu (dich_vu_key),
    ADD FOREIGN KEY (ma_cd)       REFERENCES staging.dim_chan_doan (ma_cd),
    ADD FOREIGN KEY (nguon_key)   REFERENCES staging.dim_nguon_gioi_thieu (nguon_key),
    ADD FOREIGN KEY (dia_ly_key)  REFERENCES staging.dim_dia_ly (dia_ly_key);
 
 
/* 9. Kiểm tra ------------------------------------------------------ */
SELECT 'raw' AS nguon, COUNT(*) AS so_dong, SUM("Doanh thu thuần") AS dt_thuan FROM raw.raw_baocaochitiet
UNION ALL
SELECT 'fact', COUNT(*), SUM(doanh_thu_thuan) FROM staging.fact_kham;
 
SELECT
    COUNT(*) FILTER (WHERE dich_vu_key IS NULL) AS thieu_dich_vu,
    COUNT(*) FILTER (WHERE nguon_key   IS NULL) AS thieu_nguon,
    COUNT(*) FILTER (WHERE dia_ly_key  IS NULL) AS thieu_dia_ly,
    COUNT(*) FILTER (WHERE date_key    IS NULL) AS thieu_ngay,
    COUNT(*) FILTER (WHERE tuoi        IS NULL) AS khong_doc_duoc_tuoi
FROM staging.fact_kham;
 
-- Rà lại phân nhóm dịch vụ: xem nhóm "Khác" còn những dịch vụ nào
SELECT d.nhom_dich_vu, d.ten_dich_vu,
       COUNT(*) AS so_luot, SUM(f.doanh_thu_thuan) AS doanh_thu
FROM staging.fact_kham f
JOIN staging.dim_dich_vu d ON d.dich_vu_key = f.dich_vu_key
GROUP BY 1, 2
ORDER BY 1, doanh_thu DESC;

-- Thêm cột nếu bảng chưa có
ALTER TABLE staging.dim_dich_vu ADD COLUMN IF NOT EXISTS nhom_dich_vu text;

-- Gán lại nhóm cho tất cả dịch vụ
UPDATE staging.dim_dich_vu
SET nhom_dich_vu = CASE
    WHEN ten_dich_vu ILIKE ANY (ARRAY['%phẫu thuật%','%phaco%','%lasik%','%femto%',
                                      '%smile%','%mộng%','%quặm%','%sụp mi%',
                                      '%phakic%','%icl%','%toric%','%u mỡ%',
                                      '%đại phẫu%','%trung phẫu%','%tiểu phẫu%'])
        THEN 'Phẫu thuật'
    WHEN ten_dich_vu ILIKE ANY (ARRAY['%xét nghiệm%','%máu%','%glucose%','%ure %','ure%',
                                      '%hbsag%','%hiv%','%test nhanh%','%định lượng%',
                                      '%creatinin%','%điện giải%'])
        THEN 'Xét nghiệm'
    WHEN ten_dich_vu ILIKE ANY (ARRAY['%thủ thuật%','%dị vật%','%lệ đạo%','%chắp%',
                                      '%lẹo%','%tiêm%','%laser%','%bờ mi%',
                                      '%chăm sóc mi%','%calci%','%lông siêu%','%giả mạc%',
                                      '%cùng đồ%','%khâu%','%cắt chỉ%'])
        THEN 'Thủ thuật'
    WHEN ten_dich_vu ILIKE ANY (ARRAY['%khúc xạ%','%thử kính%','%đo kính%','%ortho%',
                                      '%cận thị%','%áp tròng%','%làm sạch kính%','%progent%'])
        THEN 'Khúc xạ'
    WHEN ten_dich_vu ILIKE ANY (ARRAY['%OCT%','%siêu âm%','%chụp%','%nhãn áp%',
                                      '%sinh trắc%','%thị trường%','%đo %'])
        THEN 'Cận lâm sàng'
    WHEN ten_dich_vu ILIKE '%khám%'
        THEN 'Khám'
    ELSE 'Khác'
END;

-- Kiểm tra lại
SELECT nhom_dich_vu, COUNT(*) AS so_dich_vu
FROM staging.dim_dich_vu
GROUP BY 1
ORDER BY 2 DESC;
 