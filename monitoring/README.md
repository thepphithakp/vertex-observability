# Monitoring stack — Prometheus + Grafana + Alertmanager

ก่อนหน้านี้ stack นี้ถูกติดตั้งด้วยมือ ค่าที่ใช้จริงอยู่แต่ในคลัสเตอร์ ไม่มีใครรู้ว่า
ตั้งอะไรไว้บ้างนอกจากไปงัดดูด้วย `helm get values` และถ้า node หายก็ประกอบกลับไม่ได้

```
values.yaml            ค่าที่ใช้จริง (ตัดรหัสผ่านกับ hostname ออก)
deploy.sh              ติดตั้ง/อัปเดต — รันซ้ำได้เสมอ
rules/                 alert rule ของ Vertex
```

## ก่อนรันครั้งแรก

รหัสผ่าน Grafana ไม่อยู่ใน git — chart อ่านจาก Secret แทน

```sh
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<ตั้งเอง>'
```

```sh
INGRESS_HOST=your-domain.example.com ./deploy.sh
```

## ⚠️ release ที่รันอยู่ตอนนี้ยังฝังรหัสผ่านเป็น plain text

ค่าที่ดึงมาจากคลัสเตอร์มี `grafana.adminPassword` เป็นข้อความธรรมดาอยู่ใน helm release
ใครที่อ่าน release ได้ก็เห็นรหัสผ่านทันที และถ้าเอา values ก้อนนั้นขึ้น repo public
ก็หลุดสู่สาธารณะ — `values.yaml` ในโฟลเดอร์นี้จึงตัดออกแล้วเปลี่ยนไปใช้ Secret

**รันสคริปต์นี้ครั้งแรกจะเปลี่ยนรหัสผ่าน admin ของ Grafana** ไปเป็นค่าใน Secret
ให้ตั้งรหัสใหม่ไปเลย ไม่ต้องเอาของเดิมมาใส่ เพราะของเดิมถือว่าหลุดแล้ว

## แก้อะไรก็ตาม ให้แก้ที่ไฟล์แล้วรันสคริปต์

อย่าแก้ผ่าน UI หรือ `helm upgrade` มือเปล่า ไม่งั้นของบนคลัสเตอร์กับใน git
จะห่างกันอีกรอบ ซึ่งเป็นปัญหาเดิมที่โฟลเดอร์นี้ตั้งใจแก้

## Alert

`rules/vertex-alerts.yaml` — 9 rule แบ่งเป็นสี่กลุ่ม

| กลุ่ม | จับอะไร |
|---|---|
| `vertex.availability` | scrape ไม่ได้ · ไม่มี pod ที่ Ready · restart วนซ้ำ |
| `vertex.http` | 5xx เกิน 5% · p95 เกิน 2 วินาที |
| `vertex.outbox` | event ค้างเกิน 20 · ส่งล้มเหลวต่อเนื่อง |
| `vertex.graphql` | guardrail ปฏิเสธต่อเนื่อง · ราคา query ใกล้ชนเพดาน |

**`VertexMetricsScrapeDown` คือตัวที่สำคัญที่สุด** — `pet-service` เคยอยู่ในสถานะนี้
เป็นเวลานานโดยไม่มีใครรู้ เพราะ `/metrics` ตอบ 500 ขณะที่ ServiceMonitor เขียว
pod Ready และ CD เขียว ไม่มีสัญญาณอื่นเลยนอกจากค่านี้ (VT-109)

### สองกับดักของ Prometheus Operator ที่เจอมาแล้ว

ทั้ง `ServiceMonitor` และ `PrometheusRule` ต้องติด label **`release: prometheus-grafana`**
ไม่มี label นี้ = ถูกสร้างสำเร็จแต่ไม่มีใครอ่าน และ**ไม่มีอะไรฟ้องเลย**

```sh
kubectl get prometheus -A -o jsonpath='{.items[*].spec.serviceMonitorSelector}'
kubectl get prometheus -A -o jsonpath='{.items[*].spec.ruleSelector}'
```

`deploy.sh` มีขั้นตรวจ label นี้ให้หลัง apply

### alert ถูกส่งเข้า Discord

`rules/alertmanager-discord.yaml` เป็น **AlertmanagerConfig CR** ไม่ใช่การแก้ค่าใน
helm release — Alertmanager ตั้ง `alertmanagerConfigSelector: {}` ซึ่งรับ CR ทุกตัว
ทุก namespace จึงเพิ่ม route ได้โดยไม่ต้อง upgrade ทั้ง stack และไม่ต้อง restart อะไร

URL ของ webhook อยู่ใน Secret เท่านั้น ใครถือ URL ก็โพสต์ลงห้องแชทได้ทันที

```sh
kubectl -n vertex create secret generic discord-alert-webhook \
  --from-literal=url='https://discord.com/api/webhooks/...'
```

| severity | ย้ำซ้ำทุก |
|---|---|
| critical | 1 ชั่วโมง |
| warning | 4 ชั่วโมง |
| info | 24 ชั่วโมง |

ถี่กว่านี้จะกลายเป็นสแปมจนคนเลิกอ่าน ซึ่งอันตรายกว่าไม่มี alert เพราะจะพลาดของจริงไปด้วย

**ส่งตอน alert หายด้วย** (`sendResolved`) ไม่งั้นห้องแชทจะเต็มไปด้วยเรื่องที่จบไปแล้ว
แล้วแยกไม่ออกว่าอันไหนยังค้างอยู่

#### กับดักที่สาม: OnNamespace

operator บังคับ matcher `namespace="vertex"` ให้ route ที่มาจาก CR ในnamespace นี้
**alert ที่เขียน `sum by (job)` เฉยๆ จะไม่มี label `namespace` แล้วหลุดไปหา receiver
"null" เงียบๆ** โดยที่หน้า Alerts ของ Prometheus ยังขึ้นว่า firing ปกติ

ทุก expression ใน `vertex-alerts.yaml` จึงต้องเหลือ label นี้ติดออกมาเสมอ
