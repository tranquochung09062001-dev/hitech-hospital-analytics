"""
PIPELINE TỰ ĐỘNG – Hitech Hospital
  File Excel (D:\\Test\\Data)  ->  raw  ->  staging  ->  dwh  ->  (Power BI Service tự refresh)

Chạy tay:      python run_pipeline.py
Chạy tự động:  Task Scheduler gọi run_pipeline.bat (xem HUONG_DAN_TU_DONG.md)

Mật khẩu DB: đọc từ biến môi trường HITECH_DB_PASSWORD
            (nếu chưa đặt thì tạm lấy trong config.DATABASE_URL và ghi cảnh báo vào log).
"""
import logging
import os
import re
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL, make_url

BASE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE_DIR))
import config  # noqa: E402  (config.py có sẵn của bạn)

DATA_DIR = Path(getattr(config, "FOLDER_PATH", r"D:\Test\Data"))
SQL_USER = BASE_DIR / "SQL_Anayst"      # các file SQL bạn đã viết
SQL_AUTO = BASE_DIR / "sql_pipeline"    # file SQL làm sạch cho chạy tự động
LOG_DIR = BASE_DIR / "logs"

# ---------------------------------------------------------------------------
# 1. File nguồn -> bảng raw. Nhận file theo TỪ KHÓA trong tên (không phân biệt
#    hoa thường / dấu), nên "Thuoc_T10.xlsx" hay "BaoCaoChiTiet 13-10.xlsx" đều nhận.
# ---------------------------------------------------------------------------
SOURCES = [
    {"key": "kham",  "table": "raw_baocaochitiet", "match": ["baocaochitiet", "chitiet", "kham"]},
    {"key": "kinh",  "table": "raw_Kinhmat",       "match": ["kinhmat", "kinh"]},
    {"key": "thuoc", "table": "raw_Thuoc",         "match": ["thuoc"]},
]

# ---------------------------------------------------------------------------
# 2. Các bước SQL, chạy theo thứ tự. "needs": chỉ chạy khi đợt này có file đó.
# ---------------------------------------------------------------------------
STEPS = [
    ("Làm sạch raw khám",          SQL_AUTO / "01_clean_raw_kham.sql", {"kham"}),
    ("raw -> staging (khám)",      SQL_USER / "factkhamstagging.sql",  {"kham"}),
    ("staging -> dwh (khám)",      SQL_USER / "khambenhstagging.sql",  {"kham"}),
    ("raw -> staging (bán hàng)",  SQL_USER / "banhangdwh.sql",        {"kinh", "thuoc"}),
    ("staging -> dwh (bán hàng) + nhóm chi trả + BHYT",
                                   SQL_USER / "khambenhdwh.sql",       {"kham", "kinh", "thuoc"}),
]


# ---------------------------------------------------------------------------
def setup_log():
    LOG_DIR.mkdir(exist_ok=True)
    log_file = LOG_DIR / f"pipeline_{datetime.now():%Y%m%d_%H%M%S}.log"
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-7s %(message)s",
        handlers=[logging.FileHandler(log_file, encoding="utf-8"),
                  logging.StreamHandler(sys.stdout)],
    )
    # giữ 30 file log gần nhất
    for old in sorted(LOG_DIR.glob("pipeline_*.log"))[:-30]:
        old.unlink(missing_ok=True)
    return log_file


def get_engine():
    base = make_url(config.DATABASE_URL)
    pwd = os.environ.get("HITECH_DB_PASSWORD")
    if not pwd:
        logging.warning("Chưa đặt biến môi trường HITECH_DB_PASSWORD -> tạm dùng mật khẩu trong config.py")
        pwd = base.password
    url = URL.create("postgresql+psycopg2", username=base.username, password=pwd,
                     host=base.host or "localhost", port=base.port or 5432,
                     database=base.database)
    return create_engine(url, pool_pre_ping=True)


def norm(s: str) -> str:
    s = unicodedata.normalize("NFD", s.lower().replace("đ", "d"))
    return re.sub(r"[^a-z0-9]", "", "".join(c for c in s if unicodedata.category(c) != "Mn"))


def find_sources():
    """Trả về {key: Path}. Nếu nhiều file cùng loại, lấy file sửa gần nhất."""
    found = {}
    files = [p for p in DATA_DIR.iterdir()
             if p.is_file() and not p.name.startswith("~$")
             and p.suffix.lower() in (".xlsx", ".xls", ".csv")]
    for src in SOURCES:
        hits = [p for p in files if any(m in norm(p.stem) for m in src["match"])
                and p not in found.values()]
        if hits:
            found[src["key"]] = max(hits, key=lambda p: p.stat().st_mtime)
    return found


# ---- đọc file ------------------------------------------------------------
def _to_number(v):
    if pd.isna(v):
        return None
    if isinstance(v, (int, float)):
        return v
    s = str(v).strip().replace(".", "").replace(",", ".")
    return float(s) if s else None


def _transform_sales_export(path: Path) -> pd.DataFrame:
    """File kính/thuốc xuất THẲNG từ phần mềm (có dòng nhóm 'Tên KH - Mã KH')
    -> bảng phẳng giống định dạng raw_Kinhmat / raw_Thuoc."""
    cols = {0: "STT", 1: "Mã hàng", 2: "Ngày", 4: "Tên hàng", 11: "ĐVT", 12: "Số lượng",
            14: "Đơn giá", 16: "Tiền bán", 18: "Tiền giảm", 20: "Tiền thu", 23: "Tiền VAT"}
    money = ["Số lượng", "Đơn giá", "Tiền bán", "Tiền giảm", "Tiền thu", "Tiền VAT"]
    try:
        raw = pd.read_excel(path, header=None, engine="calamine")
    except Exception:
        raw = pd.read_excel(path, header=None)
    kho = re.sub(r"^Kho[^:]*:", "", str(raw.iloc[2, 0])).strip()
    body = raw.iloc[4:][list(cols)].rename(columns=cols)
    is_group = body["Mã hàng"].isna() & body["STT"].astype(str).str.contains(" - ")
    kh = body["STT"].where(is_group).ffill()
    body["Tên KH"] = kh.str.rsplit(" - ", n=1).str[0].str.strip()
    body["Mã KH"] = kh.str.rsplit(" - ", n=1).str[1].str.strip()
    df = body[body["Mã hàng"].notna()].copy()
    for c in money:
        df[c] = df[c].map(_to_number)
    df["STT"] = pd.to_numeric(df["STT"], errors="coerce").astype("Int64")
    df["Ngày"] = pd.to_datetime(df["Ngày"], format="%d/%m/%Y %I:%M:%S %p", errors="coerce")
    df["Kho"] = kho
    order = ["Mã KH", "Tên KH", "STT", "Ngày", "Mã hàng", "Tên hàng", "ĐVT"] + money + ["Kho"]
    return df[order].reset_index(drop=True)


HEADER_KEY = {"kham": "Mã KCB", "kinh": "Mã hàng", "thuoc": "Mã hàng"}


def clean_col(c) -> str:
    """'Ngày đăng ký ' -> 'Ngày đăng ký' (bỏ khoảng trắng thừa, chuẩn Unicode NFC)."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", str(c))).strip()


def _read_excel(path: Path, **kw) -> pd.DataFrame:
    try:
        return pd.read_excel(path, engine="calamine", **kw)
    except Exception:
        return pd.read_excel(path, **kw)


def read_source(key: str, path: Path) -> pd.DataFrame:
    if path.suffix.lower() == ".csv":
        df = pd.read_csv(path)
        df.columns = [clean_col(c) for c in df.columns]
        return df

    # File xuất từ phần mềm có vài dòng tiêu đề (tên BV, tên báo cáo, khoảng ngày)
    # -> tìm dòng chứa tên cột chuẩn (VD "Mã KCB") để làm header
    target = HEADER_KEY[key]
    top = _read_excel(path, header=None, nrows=30)
    header_row = next((i for i in range(len(top))
                       if target in [clean_col(v) for v in top.iloc[i].tolist()]), None)

    if header_row is None:
        if key in ("kinh", "thuoc"):
            logging.info("   %s là file xuất thô từ phần mềm -> chuyển định dạng", path.name)
            return _transform_sales_export(path)
        raise ValueError(f"{path.name}: không tìm thấy dòng tiêu đề có cột '{target}'")

    df = _read_excel(path, header=header_row)
    df.columns = [clean_col(c) for c in df.columns]
    df = df.loc[:, [c for c in df.columns if not c.startswith("Unnamed")]]
    df = df[df[target].notna()]                     # bỏ dòng "Tổng" / dòng trống
    if header_row:
        logging.info("   %s: tiêu đề ở dòng %d", path.name, header_row + 1)
    return df.reset_index(drop=True)


# ---- chạy ----------------------------------------------------------------
def load_raw(engine, found):
    table_of = {s["key"]: s["table"] for s in SOURCES}
    with engine.begin() as conn:
        conn.execute(text("CREATE SCHEMA IF NOT EXISTS raw"))
    for key, path in found.items():
        t0 = time.time()
        df = read_source(key, path)
        if df.empty:
            raise ValueError(f"File {path.name} không có dòng dữ liệu nào")
        df.to_sql(table_of[key], con=engine, schema="raw", if_exists="replace",
                  index=False, chunksize=1000, method="multi")
        logging.info("   %-28s -> raw.%-18s %7d dòng (%.1fs)",
                     path.name, table_of[key], len(df), time.time() - t0)


def run_sql_file(engine, path: Path):
    sql = path.read_text(encoding="utf-8-sig")
    fairy = engine.raw_connection()
    conn = getattr(fairy, "driver_connection", None) or fairy.dbapi_connection  # psycopg2 thật
    try:
        conn.rollback()
        conn.autocommit = True              # file tự quản BEGIN/COMMIT
        with conn.cursor() as cur:
            cur.execute(sql)
    finally:
        conn.autocommit = False
        fairy.close()


def summary(engine):
    q = """
    SELECT 'fact_kham'     AS bang, COUNT(*) AS so_dong, MAX(ngay_dang_ky)::date AS ngay_moi_nhat FROM dwh.fact_kham
    UNION ALL
    SELECT 'fact_ban_hang', COUNT(*), MAX(ngay)::date FROM dwh.fact_ban_hang
    """
    with engine.connect() as conn:
        for r in conn.execute(text(q)):
            logging.info("   dwh.%-14s %8d dòng | ngày mới nhất: %s", r.bang, r.so_dong, r.ngay_moi_nhat)


LOCK_KEY = 90620011


def main():
    lock_conn = None
    log_file = setup_log()
    logging.info("========== BẮT ĐẦU PIPELINE ==========")
    t_all = time.time()
    try:
        engine = get_engine()
        lock_conn = engine.connect()
        logging.info("Kết nối DB OK")
        # Khóa: chỉ 1 lần chạy tại 1 thời điểm (tự nhả khi chạy xong / khi tiến trình bị tắt)
        if not lock_conn.execute(text("SELECT pg_try_advisory_lock(:k)"), {"k": LOCK_KEY}).scalar():
            logging.warning("Đang có 1 lần chạy pipeline khác -> bỏ qua lần này")
            lock_conn.close()
            return 0

        found = find_sources()
        if not found:
            logging.warning("Không thấy file nguồn nào trong %s -> dừng", DATA_DIR)
            return 0
        for k, p in found.items():
            logging.info("Nguồn %-6s: %s (sửa lúc %s)", k, p.name,
                         datetime.fromtimestamp(p.stat().st_mtime).strftime("%d/%m/%Y %H:%M"))
        if "kham" not in found:
            logging.warning("Không thấy file khám (Báo cáo chi tiết) -> bỏ qua phần khám, giữ dữ liệu khám cũ")

        logging.info("[1] Nạp raw")
        load_raw(engine, found)

        for i, (name, path, needs) in enumerate(STEPS, start=2):
            if not (needs & found.keys()):
                logging.info("[%d] %s – bỏ qua (không có file nguồn)", i, name)
                continue
            if not path.exists():
                raise FileNotFoundError(f"Thiếu file SQL: {path}")
            t0 = time.time()
            logging.info("[%d] %s  (%s)", i, name, path.name)
            run_sql_file(engine, path)
            logging.info("    xong (%.1fs)", time.time() - t0)

        summary(engine)
        logging.info("========== HOÀN TẤT sau %.0fs ==========", time.time() - t_all)
        return 0
    except Exception:
        logging.exception("PIPELINE LỖI – bước lỗi không ghi dở dang vào dwh. Xem log: %s", log_file)
        return 1
    finally:
        if lock_conn is not None and not lock_conn.closed:
            try:
                lock_conn.execute(text("SELECT pg_advisory_unlock_all()"))
            finally:
                lock_conn.close()


if __name__ == "__main__":
    sys.exit(main())
