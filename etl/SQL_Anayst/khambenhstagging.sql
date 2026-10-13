/* =====================================================================
   DWH: staging (khám)  ->  dwh
   - Bảng dwh tạo 1 lần (IF NOT EXISTS), KHÔNG drop -> giữ dữ liệu lâu dài
   - Khóa phụ IDENTITY cố định: giá trị mới được cấp số mới, cũ giữ nguyên
   - Dim: UPSERT (SCD loại 1 – ghi đè thông tin mới nhất)
   - Fact: nạp lại theo Mã KCB (xóa lượt khám có trong đợt nạp rồi chèn lại)
   Chạy SAU staging_baocaochitiet.sql. Chạy lại nhiều lần không bị trùng.
   ===================================================================== */
 
CREATE SCHEMA IF NOT EXISTS dwh;
 
/* =====================================================================
   PHẦN A – TẠO BẢNG (chỉ tạo nếu chưa có)
   ===================================================================== */
 
CREATE TABLE IF NOT EXISTS dwh.dim_dia_ly (
    dia_ly_key   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phuong_xa    text NOT NULL,
    tinh_tp      text NOT NULL,
    load_date    timestamp NOT NULL DEFAULT now(),
    UNIQUE (phuong_xa, tinh_tp)
);
 
CREATE TABLE IF NOT EXISTS dwh.dim_benh_nhan (
    ma_bn        bigint PRIMARY KEY,
    ho_ten       text,
    gioi_tinh    varchar(10),
    nam_sinh     int,
    dien_thoai   varchar(15),
    dia_chi      text,
    dia_ly_key   int REFERENCES dwh.dim_dia_ly (dia_ly_key),
    ngay_cap_ma  date,
    load_date    timestamp NOT NULL DEFAULT now(),
    update_date  timestamp
);
 
CREATE TABLE IF NOT EXISTS dwh.dim_dich_vu (
    dich_vu_key  int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ten_dich_vu  text NOT NULL UNIQUE,
    nhom_dich_vu text,
    load_date    timestamp NOT NULL DEFAULT now(),
    update_date  timestamp
);
 
CREATE TABLE IF NOT EXISTS dwh.dim_chan_doan (
    ma_cd        varchar(10) PRIMARY KEY,
    ten_cd       text,
    nhom_icd     varchar(10),
    load_date    timestamp NOT NULL DEFAULT now(),
    update_date  timestamp
);
 
CREATE TABLE IF NOT EXISTS dwh.dim_nguon_gioi_thieu (
    nguon_key        int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nguon_gioi_thieu text NOT NULL UNIQUE,
    load_date        timestamp NOT NULL DEFAULT now()
);
 
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
 
CREATE TABLE IF NOT EXISTS dwh.fact_kham (
    fact_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ma_kcb           bigint NOT NULL,
    ma_bn            bigint REFERENCES dwh.dim_benh_nhan (ma_bn),
    date_key         int    REFERENCES dwh.dim_ngay (date_key),
    ngay_dang_ky     timestamp,
    dich_vu_key      int    REFERENCES dwh.dim_dich_vu (dich_vu_key),
    ma_cd            varchar(10) REFERENCES dwh.dim_chan_doan (ma_cd),
    nguon_key        int    REFERENCES dwh.dim_nguon_gioi_thieu (nguon_key),
    dia_ly_key       int    REFERENCES dwh.dim_dia_ly (dia_ly_key),
    tuoi             int,
    nhom_tuoi        varchar(20),
    doanh_thu        numeric(18,2),
    giam_gia         numeric(18,2),
    doanh_thu_thuan  numeric(18,2),
    tien_bhyt        numeric(18,2),
    bn_chi_tra       numeric(18,2),
    ghi_chu          text,
    tu_van_dieu_tri  text,
    nguoi_gioi_thieu text,
    ghi_chu_cd       text,
    stt_nguon        bigint,
    load_date        timestamp NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_fact_kham_ma_kcb   ON dwh.fact_kham (ma_kcb);
CREATE INDEX IF NOT EXISTS ix_fact_kham_ma_bn    ON dwh.fact_kham (ma_bn);
CREATE INDEX IF NOT EXISTS ix_fact_kham_date_key ON dwh.fact_kham (date_key);
 
 
/* =====================================================================
   PHẦN B – NẠP DỮ LIỆU (trong 1 transaction: lỗi thì không nạp gì)
   ===================================================================== */
BEGIN;
 
/* B1. dim_ngay: thêm ngày còn thiếu ---------------------------------- */
INSERT INTO dwh.dim_ngay
SELECT s.*
FROM staging.dim_ngay s
WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_ngay d WHERE d.date_key = s.date_key);
 
 
/* B2. dim_dia_ly: thêm địa danh mới ---------------------------------- */
INSERT INTO dwh.dim_dia_ly (phuong_xa, tinh_tp)
SELECT phuong_xa, tinh_tp
FROM staging.dim_dia_ly
ON CONFLICT (phuong_xa, tinh_tp) DO NOTHING;
 
 
/* B3. dim_dich_vu: thêm mới / cập nhật nhóm --------------------------- */
INSERT INTO dwh.dim_dich_vu (ten_dich_vu, nhom_dich_vu)
SELECT ten_dich_vu, nhom_dich_vu
FROM staging.dim_dich_vu
ON CONFLICT (ten_dich_vu) DO UPDATE
SET nhom_dich_vu = EXCLUDED.nhom_dich_vu,
    update_date  = now()
WHERE dwh.dim_dich_vu.nhom_dich_vu IS DISTINCT FROM EXCLUDED.nhom_dich_vu;
 
 
/* B4. dim_chan_doan: thêm mới / cập nhật tên -------------------------- */
INSERT INTO dwh.dim_chan_doan (ma_cd, ten_cd, nhom_icd)
SELECT ma_cd, ten_cd, nhom_icd
FROM staging.dim_chan_doan
ON CONFLICT (ma_cd) DO UPDATE
SET ten_cd      = EXCLUDED.ten_cd,
    nhom_icd    = EXCLUDED.nhom_icd,
    update_date = now()
WHERE (dwh.dim_chan_doan.ten_cd, dwh.dim_chan_doan.nhom_icd)
      IS DISTINCT FROM (EXCLUDED.ten_cd, EXCLUDED.nhom_icd);
 
 
/* B5. dim_nguon_gioi_thieu: thêm nguồn mới ---------------------------- */
INSERT INTO dwh.dim_nguon_gioi_thieu (nguon_gioi_thieu)
SELECT nguon_gioi_thieu
FROM staging.dim_nguon_gioi_thieu
ON CONFLICT (nguon_gioi_thieu) DO NOTHING;
 
 
/* B6. dim_benh_nhan: UPSERT (SCD1) ------------------------------------
   dia_ly_key ở staging đánh số lại mỗi lần -> đổi sang key cố định của dwh */
INSERT INTO dwh.dim_benh_nhan
      (ma_bn, ho_ten, gioi_tinh, nam_sinh, dien_thoai, dia_chi, dia_ly_key, ngay_cap_ma)
SELECT b.ma_bn, b.ho_ten, b.gioi_tinh, b.nam_sinh, b.dien_thoai, b.dia_chi,
       dl.dia_ly_key, b.ngay_cap_ma
FROM staging.dim_benh_nhan b
JOIN staging.dim_dia_ly sdl ON sdl.dia_ly_key = b.dia_ly_key
JOIN dwh.dim_dia_ly     dl  ON dl.phuong_xa = sdl.phuong_xa AND dl.tinh_tp = sdl.tinh_tp
ON CONFLICT (ma_bn) DO UPDATE
SET ho_ten      = EXCLUDED.ho_ten,
    gioi_tinh   = EXCLUDED.gioi_tinh,
    nam_sinh    = EXCLUDED.nam_sinh,
    dien_thoai  = EXCLUDED.dien_thoai,
    dia_chi     = EXCLUDED.dia_chi,
    dia_ly_key  = EXCLUDED.dia_ly_key,
    ngay_cap_ma = EXCLUDED.ngay_cap_ma,
    update_date = now()
WHERE (dwh.dim_benh_nhan.ho_ten, dwh.dim_benh_nhan.gioi_tinh, dwh.dim_benh_nhan.nam_sinh,
       dwh.dim_benh_nhan.dien_thoai, dwh.dim_benh_nhan.dia_chi, dwh.dim_benh_nhan.dia_ly_key)
      IS DISTINCT FROM
      (EXCLUDED.ho_ten, EXCLUDED.gioi_tinh, EXCLUDED.nam_sinh,
       EXCLUDED.dien_thoai, EXCLUDED.dia_chi, EXCLUDED.dia_ly_key);
 
 
/* B7. fact_kham: xóa các lượt khám có trong đợt nạp rồi chèn lại ------
   -> lượt khám mới được thêm, lượt khám đã có được cập nhật, không trùng */
DELETE FROM dwh.fact_kham f
WHERE f.ma_kcb IN (SELECT DISTINCT ma_kcb FROM staging.fact_kham);
 
INSERT INTO dwh.fact_kham (
    ma_kcb, ma_bn, date_key, ngay_dang_ky, dich_vu_key, ma_cd, nguon_key, dia_ly_key,
    tuoi, nhom_tuoi, doanh_thu, giam_gia, doanh_thu_thuan, tien_bhyt, bn_chi_tra,
    ghi_chu, tu_van_dieu_tri, nguoi_gioi_thieu, ghi_chu_cd, stt_nguon)
SELECT
    f.ma_kcb, f.ma_bn, f.date_key, f.ngay_dang_ky,
    ddv.dich_vu_key,                     -- key cố định của dwh
    f.ma_cd,
    dng.nguon_key,                       -- key cố định của dwh
    ddl.dia_ly_key,                      -- key cố định của dwh
    f.tuoi, f.nhom_tuoi,
    f.doanh_thu, f.giam_gia, f.doanh_thu_thuan, f.tien_bhyt, f.bn_chi_tra,
    f.ghi_chu, f.tu_van_dieu_tri, f.nguoi_gioi_thieu, f.ghi_chu_cd, f.stt_nguon
FROM staging.fact_kham f
-- đổi key staging (tạm) -> giá trị gốc -> key dwh (cố định)
JOIN staging.dim_dich_vu          sdv ON sdv.dich_vu_key = f.dich_vu_key
JOIN dwh.dim_dich_vu              ddv ON ddv.ten_dich_vu = sdv.ten_dich_vu
JOIN staging.dim_nguon_gioi_thieu sng ON sng.nguon_key   = f.nguon_key
JOIN dwh.dim_nguon_gioi_thieu     dng ON dng.nguon_gioi_thieu = sng.nguon_gioi_thieu
JOIN staging.dim_dia_ly           sdl ON sdl.dia_ly_key  = f.dia_ly_key
JOIN dwh.dim_dia_ly               ddl ON ddl.phuong_xa = sdl.phuong_xa AND ddl.tinh_tp = sdl.tinh_tp;
 
COMMIT;
 
 
/* =====================================================================
   PHẦN C – KIỂM TRA SAU KHI NẠP
   ===================================================================== */
-- Đợt nạp này: staging phải khớp với dwh (cùng các Mã KCB)
SELECT 'staging' AS nguon, COUNT(*) AS so_dong, SUM(doanh_thu_thuan) AS dt_thuan
FROM staging.fact_kham
UNION ALL
SELECT 'dwh (cùng Mã KCB)', COUNT(*), SUM(doanh_thu_thuan)
FROM dwh.fact_kham
WHERE ma_kcb IN (SELECT ma_kcb FROM staging.fact_kham);
 
-- Tổng quan dwh
SELECT
    (SELECT COUNT(*) FROM dwh.fact_kham)            AS fact_kham,
    (SELECT COUNT(DISTINCT ma_kcb) FROM dwh.fact_kham) AS so_luot_kham,
    (SELECT COUNT(*) FROM dwh.dim_benh_nhan)        AS benh_nhan,
    (SELECT COUNT(*) FROM dwh.dim_dich_vu)          AS dich_vu,
    (SELECT COUNT(*) FROM dwh.dim_chan_doan)        AS chan_doan,
    (SELECT COUNT(*) FROM dwh.dim_nguon_gioi_thieu) AS nguon,
    (SELECT COUNT(*) FROM dwh.dim_dia_ly)           AS dia_ly;