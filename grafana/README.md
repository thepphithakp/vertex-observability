# Grafana dashboard ของ Vertex

`vertex-overview.json` ถูกโหลดเข้า Grafana ผ่าน **sidecar** ไม่ได้กดสร้างในหน้าเว็บ

kube-prometheus-stack ติดตั้ง container `grafana-sc-dashboard` มาให้ ซึ่งเฝ้าดู
ConfigMap ที่ติด label `grafana_dashboard=1` **ทุก namespace** แล้วเอาไฟล์ข้างในไปวาง
ให้ Grafana อ่าน — จึงไม่ต้องใช้รหัสผ่าน Grafana และ dashboard อยู่ใน git ได้

```sh
./deploy-dashboard.sh          # สร้าง/อัปเดต ConfigMap จากไฟล์ JSON
```

## แก้ dashboard

แก้ที่ไฟล์ JSON แล้วรันสคริปต์ใหม่ **อย่าแก้ในหน้าเว็บ** เพราะ sidecar จะเขียนทับ
ทุกครั้งที่ ConfigMap เปลี่ยน และของที่แก้ในเว็บจะหายโดยไม่มีใครรู้

ถ้าอยากลองปรับใน Grafana ก่อนให้ใช้ปุ่ม **Export → JSON** แล้วเอามาทับไฟล์นี้
(ลบ field `id` กับ `version` ออกก่อน ไม่งั้นจะชนกับของที่ Grafana จัดการเอง)

## แผงที่สำคัญที่สุดคือแผงบนซ้าย

**"service ที่ Prometheus ดึงได้จริง"** — `up` ของแต่ละ service

`pet-service` เคยขึ้น 0 อยู่นานโดยไม่มีใครรู้ เพราะ `/metrics` ตอบ 500 จาก label
ที่เพี้ยน ขณะที่ ServiceMonitor ยังเขียวและ pod ยัง Ready อยู่ — ไม่มีอะไรฟ้องเลย
นอกจากแผงนี้ ถ้าเห็นสีแดงให้ไปดู `kubectl -n vertex exec` ยิง `/metrics` ตรงๆ ก่อน

## ตัวเลขที่ dashboard นี้พึ่งพา

| metric | มาจาก |
|---|---|
| `http_requests_total` · `http_request_duration_seconds` · `http_requests_in_flight` | ทุก service (ชื่อเดียวกันหมด แยกด้วย label `job`) |
| `graphql_operations_total` · `graphql_operation_duration_seconds` · `graphql_operation_complexity` · `graphql_rejected_total` | `vertex-bff` เท่านั้น |
| `outbox_pending_count` · `outbox_deliveries_total` | `pet-service` เท่านั้น |

**ชื่อ metric ของ HTTP ต้องเหมือนกันทุก service** ถ้า service ใหม่ตั้งชื่อไม่ตรง
แผงในนี้จะไม่เห็นมันเลยโดยไม่มี error อะไร
