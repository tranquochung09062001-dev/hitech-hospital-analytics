# Tự động cập nhật dashboard Hitech Hospital

```
05:30  Task Scheduler  ->  run_pipeline.bat
       Excel (D:\Test\Data) -> raw -> staging -> dwh   (PostgreSQL)
06:00  Power BI Service -> gateway -> PostgreSQL -> dashboard mới
```

## 0. Hằng ngày bạn chỉ cần làm 1 việc

Xuất báo cáo từ phần mềm và **chép đè** vào `D:\Test\Data`. Tên file cần có từ khóa:

| Loại | Tên file chứa | Ví dụ |
|---|---|---|
| Khám (Báo cáo chi tiết) | `baocaochitiet`, `chitiet` hoặc `kham` | `BaoCaoChiTiet.xlsx` |
| Kính | `kinh` / `kinhmat` | `Kinhmat.xlsx` |
| Thuốc | `thuoc` | `Thuoc.xlsx` |

- Có thể để file kính/thuốc xuất thẳng từ phần mềm (có dòng "Tên KH - Mã KH"). Pipeline tự chuyển định dạng.
- Thiếu file loại nào thì bước đó được bỏ qua và dữ liệu cũ trong dwh giữ nguyên.
- Nạp trùng không sao: dwh xóa rồi nạp lại theo Mã KCB / mã đơn.

## 1. Các file trong D:\Test\Main

| File | Vai trò |
|---|---|
| `run_pipeline.py` | Chạy toàn bộ: nạp raw và 5 bước SQL theo thứ tự, ghi log |
| `sql_pipeline\01_clean_raw_kham.sql` | Bản chạy tự động của `rawclean.sql`, đã bỏ các SELECT khám phá |
| `SQL_Anayst\*.sql` | Dùng nguyên file của bạn. Sửa logic ở đó là pipeline tự dùng bản mới |
| `run_pipeline.bat` | File để Task Scheduler gọi |
| `setup_task.bat` | Chạy 1 lần để tạo lịch 05:30 và lưu mật khẩu DB |
| `logs\` | Mỗi lần chạy có 1 file log (giữ 30 file gần nhất) |

Thứ tự SQL: `01_clean_raw_kham` → `factkhamstagging` → `khambenhstagging` → `banhangdwh` → `khambenhdwh`.

## 2. Chạy thử bằng tay

```
cd /d D:\Test\Main
python run_pipeline.py
```

Cuối log thấy `HOÀN TẤT` và số dòng `dwh.fact_kham` / `dwh.fact_ban_hang` là đúng. Nếu lỗi, log ghi rõ bước nào và câu SQL nào.

## 3. Lên lịch chạy (Task Scheduler)

1. Nháy đúp `setup_task.bat`, nhập mật khẩu PostgreSQL. Mật khẩu được lưu vào biến môi trường `HITECH_DB_PASSWORD`.
   - Khi đã chạy ổn, xóa mật khẩu khỏi `config.py` và `load.py`.
2. Mở **Task Scheduler** → thư mục *Hitech Hospital* → *ETL hang ngay* → **Properties**:
   - *General*: chọn **Run whether user is logged on or not** để chạy cả khi chưa đăng nhập.
   - *Conditions*: tích **Wake the computer to run this task**, bỏ tích *Start only if on AC power*.
   - *Settings*: tích **Run task as soon as possible after a scheduled start is missed**.

## 4. Đưa lên Power BI Service + refresh tự động

**a. Publish**
- Mở `Hospital.pbip` → **Home → Publish** → chọn workspace (ví dụ *Hitech Hospital*).
- Tài khoản cần là tài khoản công ty/trường (Power BI Pro hoặc PPU). Gmail cá nhân không đăng nhập được.

**b. Cài On‑premises data gateway** (trên chính máy có PostgreSQL)
- Tải tại https://aka.ms/gateway → chọn **Standard mode** (không chọn personal mode).
- Đăng nhập bằng cùng tài khoản Power BI → đặt tên gateway (ví dụ `HITECH-GW`) và recovery key (cất kỹ).

**c. Khai báo nguồn dữ liệu** (app.powerbi.com → ⚙ → **Manage connections and gateways** → **New**)

| Trường | Giá trị |
|---|---|
| Kiểu | On‑premises, gateway `HITECH-GW` |
| Connection type | PostgreSQL |
| Server | `localhost` (phải **giống hệt** trong Power BI Desktop) |
| Database | `Hitech Hospital` |
| Authentication | Basic, user `postgres` + mật khẩu |

- Nếu báo lỗi SSL / encryption: mở *Advanced* và bỏ tích **Encrypted connection**, vì PostgreSQL local thường không bật SSL.

**d. Gắn gateway và đặt lịch** (workspace → semantic model **Hospital** → **Settings**)
- *Gateway and cloud connections*: chọn `HITECH-GW`, map nguồn PostgreSQL vào connection vừa tạo, rồi bấm **Apply**.
- *Refresh*:
  - Bật **Configure a refresh schedule**.
  - Time zone: **(UTC+07:00) Bangkok, Hanoi, Jakarta**.
  - Giờ: **06:00**, có thể thêm 12:00 hoặc 17:00 (Pro cho tối đa 8 lần/ngày).
  - Tích **Send refresh failure notifications** để nhận email khi refresh lỗi.
- Bấm **Refresh now** 1 lần để kiểm tra.

**e. Chia sẻ**
- Dùng **Share** hoặc tạo **App** cho người trong bệnh viện.
- **Không dùng "Publish to web"**, vì report có tên, SĐT và địa chỉ bệnh nhân.

## 5. Lưu ý

- Máy chạy PostgreSQL và gateway phải **bật lúc 05:30–06:15**. Nên tắt Sleep hoặc dùng *Wake the computer*.
- ETL lỗi: dashboard vẫn refresh nhưng hiện số liệu hôm trước. Xem `logs\`.
- Refresh lỗi trên Service: thường do gateway offline, sai mật khẩu, hoặc tên server/database khác với bản Desktop.
- Sau khi sửa model trong Desktop: **Publish lại**. Lịch refresh và gateway được giữ nguyên.
