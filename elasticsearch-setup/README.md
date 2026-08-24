# การตั้งค่าฝั่ง Elasticsearch

ไฟล์ในโฟลเดอร์นี้ถูก apply โดย `apply-job.yaml` ซึ่งรันซ้ำได้เสมอ
ทุกคำสั่งเป็น `PUT` จึงไม่มีผลข้างเคียงถ้ารันหลายรอบ

> ไฟล์ JSON ที่นี่**ห้ามมีคอมเมนต์**
> Elasticsearch ปฏิเสธ field ที่ไม่รู้จักใน request body
> คำอธิบายทั้งหมดจึงอยู่ในไฟล์นี้แทน

---

## `ilm-policy.json` — คุมว่า log อยู่นานแค่ไหน

นี่คือ**เพดานจริงของขนาดข้อมูล ไม่ใช่ขนาด PVC**

storageClass `local-path` เป็นแค่ hostPath bind ไม่บังคับ quota ที่ filesystem
ขอ PVC 5 Gi แต่เขียนได้จนเต็ม disk ของ node สิ่งเดียวที่หยุดข้อมูลไม่ให้โต
ไปเรื่อยๆ คือ policy นี้

| phase | เมื่อไหร่ | ทำอะไร |
|---|---|---|
| hot | ครบ 1 วัน **หรือ** shard โต 2 GB | rollover ไป index ใหม่ |
| delete | 7 วันหลัง rollover | ลบทั้ง index |

ข้อมูลจึงอยู่ได้สูงสุดราว **8 วัน** อยู่ในช่วง 7–14 วันที่ต้องการ

**ทำไมต้อง rollover ทุกวัน**
เพราะทำให้การลบเป็นการลบทั้ง index ซึ่งแค่ปลด segment file ทิ้ง เร็วมาก
และคืน disk ทันที ถ้าใช้ `delete_by_query` แทนจะกิน CPU หนัก
แล้ว disk ยังไม่คืนจนกว่าจะ merge เสร็จ

**ไม่มี warm / cold phase**
มี node เดียวและ disk ชนิดเดียว การย้าย tier จึงไม่มีความหมาย
มีแต่จะเพิ่มงานให้ ES เปล่าๆ

---

## `index-template.json` — คุมว่าค้นหาอะไรได้บ้าง

ออกแบบโดยคิดถึงตอนใช้ Discover เป็นหลัก

### `dynamic: "runtime"` — จุดสำคัญที่สุด

ฟิลด์ที่ไม่ได้ประกาศไว้จะกลายเป็น **runtime field** อัตโนมัติ

| ทางเลือก | ผลตอนใช้ Discover | ความเสี่ยง |
|---|---|---|
| `dynamic: true` | ค้นได้ทุกฟิลด์ | 🔴 mapping ระเบิด — service เขียน log ที่มี key แปลกใหม่ทุกครั้ง ES สร้าง field ใหม่ไม่หยุดจน cluster ช้าและ heap เต็ม |
| `dynamic: false` | ฟิลด์ใหม่**กรองไม่ได้** เห็นแต่ใน JSON | เจอตอนต้องใช้จริงว่ากรองไม่ได้ |
| **`dynamic: "runtime"`** | **กรองได้ทันทีโดยไม่ต้องแก้ template** | ช้ากว่าตอน query แต่รับได้กับข้อมูลระดับนี้ |

เลือก `runtime` เพราะได้ความสะดวกตอน debug โดยไม่เสี่ยง mapping ระเบิด
ฟิลด์ที่ใช้บ่อยถูกประกาศไว้แล้วจึง index จริงและเร็ว

`index.mapping.total_fields.limit: 300` เป็นตาข่ายกันอีกชั้น
ถ้าฟิลด์เกินนี้ ES จะปฏิเสธ document แทนที่จะพาตัวเองล่ม

### ทำไมฟิลด์ส่วนใหญ่เป็น `keyword` ไม่ใช่ `text`

`text` จะถูกตัดคำ ใช้ค้นหาข้อความอิสระได้ แต่**กรองแบบตรงตัวไม่ได้**
และทำ aggregation ไม่ได้

ใน Discover การกดที่ค่าแล้วเลือก "filter for value" หรือดู top values
ใน sidebar ต้องใช้ `keyword` ทั้งหมด

`kubernetes.pod.name` จึงเป็น keyword — กดกรอง pod เดียวได้ทันที
ส่วน `message` เป็น `text` เพราะเป็นข้อความอิสระที่ต้องค้นด้วยคำ

### `number_of_replicas: 0`

มี node เดียว replica จะไม่มีที่ไป — shard จะค้างสถานะ unassigned
แล้ว cluster health เป็น **yellow ตลอดเวลา** จนแยกไม่ออกว่าเมื่อไหร่ผิดจริง

ผลคือ**ถ้า disk เสียข้อมูลหาย** ซึ่งยอมรับได้เพราะเป็น log ที่มีอายุ 7 วัน
ไม่ใช่ข้อมูลธุรกิจ ต่างจาก PostgreSQL ที่ต้องมี backup

---

## ลำดับที่ job ทำ

1. รอ Elasticsearch ตอบ `/_cluster/health` ก่อน
2. ตั้งรหัสให้ `kibana_system` — Kibana start ไม่ได้ถ้าไม่มีขั้นนี้
3. สร้าง role `filebeat_writer` ที่**เขียน `logs-*` ได้อย่างเดียว ลบไม่ได้**
4. สร้าง user `filebeat_writer`
5. `PUT` ILM policy
6. `PUT` index template

ขั้นที่ 3 สำคัญเรื่องความปลอดภัย — ถ้าให้ Filebeat ใช้ `elastic`
Filebeat ที่ถูกยึดจะลบ log ทั้งหมดได้ ซึ่งเป็นสิ่งแรกที่ผู้บุกรุกอยากทำ
