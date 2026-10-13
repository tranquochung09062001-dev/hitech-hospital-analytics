/* =====================================================================
   DWH BÁN HÀNG (kính + thuốc): staging  ->  dwh
   - Dùng CHUNG dwh.dim_ngay với khám
   - Bảng tạo 1 lần, không drop; key cố định; dim UPSERT (SCD1)
   - Fact: xóa các đơn (ma_don) có trong đợt nạp rồi chèn lại -> không trùng
   Chạy SAU staging_ban_hang.sql
   ===================================================================== */
 
CREATE SCHEMA IF NOT EXISTS dwh;
 
/* =====================================================================
   PHẦN A – TẠO BẢNG (chỉ tạo nếu chưa có)
   ===================================================================== */
 
-- dim_ngay dùng chung với khám (đã có nếu chạy dwh_kham.sql trước)
CREATE TABLE IF NOT EXISTS dwh.dim_ngay (
    date_key          int PRIMARY KEY,
    ngay              date NOT NULL UNIQUE,
    ngay_trong_thang  int,
    thang             int,
    ten_thang         text,
    quy               int,
    nam               int,
    thu_trong_tuan    int,
    ten_thu           text,
    la_cuoi_tuan      boolean
);
 
CREATE TABLE IF NOT EXISTS dwh.dim_san_pham (
    ma_hang      varchar(30) PRIMARY KEY,
    ten_hang     text,
    dvt          varchar(20),
    loai_quay    varchar(10),
    nhom_hang    varchar(40),
    chiet_suat   numeric(4,2),
    load_date    timestamp NOT NULL DEFAULT now(),
    update_date  timestamp
);
 
CREATE TABLE IF NOT EXISTS dwh.dim_kho (
    kho_key      int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ten_kho      text NOT NULL UNIQUE,
    loai_quay    varchar(10),
    load_date    timestamp NOT NULL DEFAULT now()
);
 
CREATE TABLE IF NOT EXISTS dwh.fact_ban_hang (
    fact_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ma_don         varchar(40) NOT NULL,
    ma_kh          bigint,
    ten_kh         text,
    date_key       int         REFERENCES dwh.dim_ngay (date_key),
    ngay           timestamp,
    ma_hang        varchar(30) REFERENCES dwh.dim_san_pham (ma_hang),
    kho_key        int         REFERENCES dwh.dim_kho (kho_key),
    stt_trong_don  int,
    so_luong       numeric(18,2),
    don_gia        numeric(18,2),
    tien_ban       numeric(18,2),
    tien_giam      numeric(18,2),
    tien_thu       numeric(18,2),
    tien_vat       numeric(18,2),
    load_date      timestamp NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_fact_ban_hang_ma_don   ON dwh.fact_ban_hang (ma_don);
CREATE INDEX IF NOT EXISTS ix_fact_ban_hang_date_key ON dwh.fact_ban_hang (date_key);
CREATE INDEX IF NOT EXISTS ix_fact_ban_hang_ma_hang  ON dwh.fact_ban_hang (ma_hang);
CREATE INDEX IF NOT EXISTS ix_fact_ban_hang_kho_key  ON dwh.fact_ban_hang (kho_key);
 
 
/* =====================================================================
   PHẦN B – NẠP DỮ LIỆU
   ===================================================================== */
BEGIN;
 
/* B1. dim_ngay: thêm các ngày còn thiếu ------------------------------ */
INSERT INTO dwh.dim_ngay
SELECT
    CAST(to_char(d, 'YYYYMMDD') AS int),
    CAST(d AS date),
    CAST(EXTRACT(DAY     FROM d) AS int),
    CAST(EXTRACT(MONTH   FROM d) AS int),
    'Tháng ' || CAST(EXTRACT(MONTH FROM d) AS int),
    CAST(EXTRACT(QUARTER FROM d) AS int),
    CAST(EXTRACT(YEAR    FROM d) AS int),
    CAST(EXTRACT(ISODOW  FROM d) AS int),
    (ARRAY['Thứ 2','Thứ 3','Thứ 4','Thứ 5','Thứ 6','Thứ 7','Chủ nhật'])
        [CAST(EXTRACT(ISODOW FROM d) AS int)],
    EXTRACT(ISODOW FROM d) IN (6, 7)
FROM generate_series(
        (SELECT date_trunc('year', MIN(ngay)) FROM staging.fact_ban_hang),
        (SELECT date_trunc('year', MAX(ngay)) + interval '1 year - 1 day' FROM staging.fact_ban_hang),
        interval '1 day') AS d
ON CONFLICT (date_key) DO NOTHING;
 
 
/* B2. dim_san_pham: thêm mới / cập nhật ------------------------------ */
INSERT INTO dwh.dim_san_pham (ma_hang, ten_hang, dvt, loai_quay, nhom_hang, chiet_suat)
SELECT ma_hang, ten_hang, dvt, loai_quay, nhom_hang, chiet_suat
FROM staging.dim_san_pham
ON CONFLICT (ma_hang) DO UPDATE
SET ten_hang    = EXCLUDED.ten_hang,
    dvt         = EXCLUDED.dvt,
    loai_quay   = EXCLUDED.loai_quay,
    nhom_hang   = EXCLUDED.nhom_hang,
    chiet_suat  = EXCLUDED.chiet_suat,
    update_date = now()
WHERE (dwh.dim_san_pham.ten_hang, dwh.dim_san_pham.dvt, dwh.dim_san_pham.loai_quay,
       dwh.dim_san_pham.nhom_hang, dwh.dim_san_pham.chiet_suat)
      IS DISTINCT FROM
      (EXCLUDED.ten_hang, EXCLUDED.dvt, EXCLUDED.loai_quay,
       EXCLUDED.nhom_hang, EXCLUDED.chiet_suat);
 
 
/* B3. dim_kho: thêm kho mới ----------------------------------------- */
INSERT INTO dwh.dim_kho (ten_kho, loai_quay)
SELECT ten_kho, loai_quay FROM staging.dim_kho
ON CONFLICT (ten_kho) DO NOTHING;
 
 
/* B4. fact_ban_hang: xóa đơn có trong đợt nạp rồi chèn lại ----------- */
DELETE FROM dwh.fact_ban_hang
WHERE ma_don IN (SELECT DISTINCT ma_don FROM staging.fact_ban_hang);
 
INSERT INTO dwh.fact_ban_hang (
    ma_don, ma_kh, ten_kh, date_key, ngay, ma_hang, kho_key, stt_trong_don,
    so_luong, don_gia, tien_ban, tien_giam, tien_thu, tien_vat)
SELECT
    f.ma_don, f.ma_kh, f.ten_kh, f.date_key, f.ngay, f.ma_hang,
    dk.kho_key,                                   -- key cố định của dwh
    f.stt_trong_don,
    f.so_luong, f.don_gia, f.tien_ban, f.tien_giam, f.tien_thu, f.tien_vat
FROM staging.fact_ban_hang f
-- kho_key staging (tạm) -> tên kho -> kho_key dwh (cố định)
JOIN staging.dim_kho sk ON sk.kho_key = f.kho_key
JOIN dwh.dim_kho     dk ON dk.ten_kho = sk.ten_kho;
 
COMMIT;
 
 
/* =====================================================================
   PHẦN C – KIỂM TRA
   ===================================================================== */
SELECT 'staging' AS nguon, COUNT(*) AS so_dong, SUM(tien_thu) AS tien_thu
FROM staging.fact_ban_hang
UNION ALL
SELECT 'dwh (cùng đơn)', COUNT(*), SUM(tien_thu)
FROM dwh.fact_ban_hang
WHERE ma_don IN (SELECT ma_don FROM staging.fact_ban_hang);
 
SELECT k.loai_quay,
       COUNT(*)               AS so_dong,
       COUNT(DISTINCT ma_don) AS so_don,
       SUM(tien_thu)          AS tien_thu
FROM dwh.fact_ban_hang f
JOIN dwh.dim_kho k ON k.kho_key = f.kho_key
GROUP BY k.loai_quay;

ALTER TABLE dwh.dim_benh_nhan ADD COLUMN IF NOT EXISTS nhom_chi_tra varchar(30);
 
UPDATE dwh.dim_benh_nhan b
SET nhom_chi_tra = CASE
        WHEN t.tong >= 50000000 THEN 'Từ 50 triệu trở lên'
        WHEN t.tong >= 20000000 THEN '20 - 50 triệu'
        WHEN t.tong >= 10000000 THEN '10 - 20 triệu'
        WHEN t.tong >=  5000000 THEN '5 - 10 triệu'
        WHEN t.tong >=  1000000 THEN '1 - 5 triệu'
        ELSE                         'Dưới 1 triệu'
    END
FROM (
    SELECT ma_bn, COALESCE(SUM(bn_chi_tra), 0) AS tong
    FROM dwh.fact_kham
    GROUP BY ma_bn
) t
WHERE t.ma_bn = b.ma_bn;
 
-- Kiểm tra
SELECT nhom_chi_tra, COUNT(*) AS so_benh_nhan
FROM dwh.dim_benh_nhan
GROUP BY 1
ORDER BY 2 DESC;

/* =====================================================================
   Nhận biết lượt khám có BHYT
   - Dấu hiệu 1: tien_bhyt > 0 (cột "Tiền trừ BHYT")
   - Dấu hiệu 2: ghi_chu có chữ "BHYT" (VD "BHYT80%+GG", "bhyt 100% + ggbv")
   - Gán theo LƯỢT KHÁM (ma_kcb): chỉ cần 1 dịch vụ trong lượt có BHYT
     là cả lượt tính là BHYT (dịch vụ ngoài danh mục BH vẫn có tien_bhyt = 0)
   - Mức hưởng (80 / 95 / 100%) lấy từ ghi chú
   ===================================================================== */
 
ALTER TABLE dwh.fact_kham ADD COLUMN IF NOT EXISTS doi_tuong      varchar(10);
ALTER TABLE dwh.fact_kham ADD COLUMN IF NOT EXISTS muc_huong_bhyt int;
 
UPDATE dwh.fact_kham f
SET doi_tuong      = CASE WHEN l.co_bhyt THEN 'BHYT' ELSE 'Dịch vụ' END,
    muc_huong_bhyt = l.muc_huong
FROM (
    SELECT
        ma_kcb,
        bool_or(COALESCE(tien_bhyt, 0) > 0 OR ghi_chu ILIKE '%bhyt%')            AS co_bhyt,
        MAX(CAST(substring(ghi_chu FROM '(?i)bhyt\s*(\d{2,3})\s*%') AS int))      AS muc_huong
    FROM dwh.fact_kham
    GROUP BY ma_kcb
) l
WHERE l.ma_kcb = f.ma_kcb;
 
-- Kiểm tra
SELECT doi_tuong, muc_huong_bhyt,
       COUNT(DISTINCT ma_kcb)  AS so_luot,
       SUM(tien_bhyt)          AS tien_bhyt,
       SUM(bn_chi_tra)         AS bn_chi_tra
FROM dwh.fact_kham
GROUP BY 1, 2
ORDER BY 1, 2;