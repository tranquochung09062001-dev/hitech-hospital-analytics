# Hitech Eye Hospital – Revenue & Patient Analytics (End-to-End)

A production analytics system for a 3-location eye hospital. Raw Excel exports from the
hospital information system (HIS) are loaded every morning into a PostgreSQL data warehouse, and
a 7-page Power BI dashboard refreshes automatically on Power BI Service. Nobody has to run
anything by hand.

**Stack:** Python (pandas, SQLAlchemy) · PostgreSQL · SQL · Power BI (DAX, TMDL/PBIP) ·
Power BI Service + On-premises Data Gateway · Windows Task Scheduler

---

## Architecture

```
HIS Excel exports (daily)          PostgreSQL "Hitech Hospital"                       Power BI
┌────────────────────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────────────┐   ┌───────────────────┐
│ Báo cáo chi tiết (exam)│   │   raw    │   │ staging  │   │ dwh (star schema)    │   │ Semantic model    │
│ Kinhmat  (optical)     │──▶│ as-is    │──▶│ cleaned, │──▶│ 2 facts + 8 dims     │──▶│ + 7-page report   │
│ Thuoc    (pharmacy)    │   │ load     │   │ typed    │   │ idempotent upserts   │   │ (Power BI Service)│
└────────────────────────┘   └──────────┘   └──────────┘   └──────────────────────┘   └───────────────────┘
        05:30  Task Scheduler → run_pipeline.py                     06:00  scheduled refresh via gateway
```

## Data model (dwh)

| Table | Grain / content |
|---|---|
| `fact_kham` | 1 row = 1 service in 1 visit (Mã KCB): revenue, discount, insurance (BHYT), patient payment |
| `fact_ban_hang` | 1 row = 1 item in 1 optical / pharmacy order |
| `dim_benh_nhan` | patient (SCD1), birth year, gender, geography, spending tier |
| `dim_dia_ly` | province / ward parsed from free-text addresses |
| `dim_dich_vu` | service + service group (surgery, procedure, refraction, lab, …) |
| `dim_chan_doan` | ICD-10 code + diagnosis |
| `dim_nguon_gioi_thieu` | referral source (Marketing, partners, staff relatives, walk-in, …) |
| `dim_san_pham`, `dim_kho` | products (lens index, product group) and warehouses |
| `dim_ngay` | shared calendar |

## ETL pipeline – `etl/run_pipeline.py`

1. **Extract & load raw:** auto-detects each source file by keyword. It also finds the real header row,
   because HIS exports have 4 title rows above it, and drops the "Total" footer row.
2. **Clean** (`sql_pipeline/01_clean_raw_kham.sql`):
   - Auto type-casting.
   - Restores leading zeros in phone numbers.
   - Parses province/ward from addresses.
   - Splits ICD-10 code, name and note from the diagnosis text.
3. **raw → staging → dwh** (`SQL_Anayst/*.sql`): dimension upserts, plus delete-and-reload of facts
   by visit / order ID. Re-running the same file creates **zero duplicates**.
4. **Enrichment:**
   - Classifies each visit as Health Insurance (BHYT) vs. self-pay, with coverage level 80/95/100%.
   - Assigns each patient a spending tier.
5. **Safety:**
   - A PostgreSQL advisory lock prevents concurrent runs.
   - Every run is logged to `logs/`.
   - The DB password comes from the `HITECH_DB_PASSWORD` environment variable.

Validated against the source: **100% row and revenue reconciliation** on ~17K exam service lines,
30K pharmacy and 7K optical sales rows.

## Dashboard (PBIP – open `powerbi/Hospital.pbip` in Power BI Desktop)

| Page | Highlights |
|---|---|
| Tổng quan (Overview) | KPIs, monthly trend, revenue mix, top services/products |
| Doanh thu khám (Exam revenue) | service groups, inpatient vs. outpatient, BHYT vs. self-pay, promotions |
| Bệnh nhân (Patients) | top 10 customers → click-through surgery/procedure history, age, geography |
| Cộng tác viên (Referral partners) | revenue by source (% of exam revenue), source → referrer matrix |
| Quầy kính (Optical) | product groups, lens index, buyer age, exam vs. walk-in buyers |
| Quầy thuốc (Pharmacy) | drug groups, buyer age, BHYT / self-pay / walk-in split |
| Insights | 12 auto-generated insight cards (dynamic DAX text) |

DAX techniques used:
- Dynamic format strings (million / billion VND).
- Disconnected slicer + `TREATAS` so a slicer filters one visual only.
- `KEEPFILTERS`.
- `ALLSELECTED`-based % of total.
- TopN with click-through drill.

**Key findings:** referral partners drive **29.4%** of exam revenue vs. **8.7%** from Marketing, and
**29.3%** of pharmacy revenue comes from walk-in buyers without an exam.

## Run it

```bash
pip install -r requirements.txt
cp etl/config.example.py etl/config.py      # edit DB URL + data folder
setx HITECH_DB_PASSWORD "<your password>"   # Windows
python etl/run_pipeline.py
```

To schedule it, run `etl/setup_task.bat` once. It creates a daily 05:30 job.
Power BI Service, gateway and scheduled refresh setup is in `docs/HUONG_DAN_TU_DONG.md` (Vietnamese).

> **Data privacy:** this repository contains code and report definitions only. No patient data,
> Excel exports, Power BI data cache or credentials are included.

## Author

**Trần Quốc Hưng**, Data Analyst / Business Analyst · [GitHub](https://github.com/tranquochung09062001-dev)
