# vertex-observability

Manifest ของระบบเก็บ log สำหรับ Vertex — Elasticsearch + Kibana + Filebeat
รันบน k3s node เดียว เก็บ log ของ pod ใน namespace `vertex`

> แยกจาก repo ของ service ธุรกิจโดยตั้งใจ
> การอัปเดต Elasticsearch ไม่ควรต้องแตะโค้ดของ pet-service
> และการเปลี่ยน retention ไม่ควร trigger CI ของ service

---

## เริ่มยังไง

```bash
export INGRESS_HOST=your-domain.example.com
./deploy.sh
```

สคริปต์รันซ้ำได้เสมอ ถ้าเครื่องหลับหรือหลุดกลางทางให้รันใหม่ได้เลย

### ต้องทำครั้งเดียวก่อนเริ่ม

**`INGRESS_HOST`** — repo นี้เป็น public จึง**ไม่ hardcode hostname จริง**
ของ cluster ไว้ในไฟล์ที่ commit (`ingress/00-kibana-ingress.yaml` และ
`kibana/02-deployment.yaml` มีแค่ placeholder `__INGRESS_HOST__`)

ต้อง `export INGRESS_HOST=...` ก่อนรัน `./deploy.sh` ทุกครั้ง — สคริปต์
จะ fail ทันทีถ้าลืมตั้ง ไม่ใช่ apply ด้วยค่าว่างหรือ hostname ผิด

ตัวแปรนี้อยู่ในเครื่องผู้ใช้เท่านั้น ไม่ได้เก็บไว้ในไฟล์ไหนของ repo

Elasticsearch ต้องการ `vm.max_map_count` อย่างน้อย 262144 ไม่งั้น**ไม่ start เลย**

```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
sudo sysctl --system
```

ตั้งที่ host ไม่ใช่ผ่าน initContainer ที่รัน privileged
เพราะ privileged container ที่รันทุกครั้งที่ ES restart เป็นช่องโหว่ถาวร
เพื่อแลกกับการตั้งค่าที่ทำครั้งเดียวก็จบ

---

## เปิด Kibana

ผ่าน ingress (แนะนำ)

```
http://$INGRESS_HOST/kibana
```

(hostname จริงคือค่าที่ตั้งไว้ใน `INGRESS_HOST` ตอน deploy)

หรือผ่าน port-forward ถ้าไม่อยากพึ่ง ingress

```bash
kubectl port-forward -n observability svc/kibana 5601:5601
```

แล้วเปิด http://localhost:5601 · login ด้วย user `elastic`

> **ยอมรับความเสี่ยงเดียวกับ Jenkins/Grafana โดยตั้งใจ** (2026-08-24)
> host นี้ชี้ไป IP สาธารณะจริงและ ingress เปิดแค่ port 80 ไม่มี TLS
> รหัสผ่านจึงวิ่งเป็น plain text — เหมือนกับ admin tool ตัวอื่นที่เปิดอยู่แล้ว
> บนโดเมนเดียวกัน ไม่ได้เพิ่มชั้นป้องกันที่ ingress เพื่อให้สอดคล้องกับของเดิม
> ดูรายละเอียดที่ `ingress/00-kibana-ingress.yaml`

```bash
kubectl get secret es-credentials -n observability \
  -o jsonpath='{.data.ELASTIC_PASSWORD}' | base64 -d; echo
```

Kibana เข้าถึงได้ทั้งผ่าน ingress และ port-forward

---

## โครงสร้าง

```
namespace/            เพดานทรัพยากร — apply ก่อนอะไรทั้งหมด
cicd/                 ServiceAccount สำหรับ pipeline
elasticsearch/        StatefulSet + Service + ตัวอย่าง Secret
elasticsearch-setup/  ILM policy · index template · user  (มี README แยก)
filebeat/             RBAC · config · DaemonSet
kibana/               Deployment + Service + saved objects + import job
ingress/              เปิด Kibana ผ่าน ingress-nginx ที่ /kibana
deploy.sh             ติดตั้งทั้งหมดตามลำดับที่ถูกต้อง
```

---

## การตัดสินใจที่สำคัญ

### เพดานทรัพยากรต้องมาก่อนของ

`ResourceQuota` ถูก apply เป็นอันดับแรกเสมอ เพราะ k8s บังคับใช้ตอน schedule
ไม่ใช่ตอนรัน ELK จึงโตเกินเพดานไม่ได้เลยแม้จะตั้ง limit ผิดหรือมี pod งอกมา

ทดสอบได้ว่าเพดานทำงานจริง

```bash
kubectl run quota-test -n observability --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox",
    "resources":{"requests":{"memory":"3Gi"},"limits":{"memory":"3Gi"}}}]}}' \
  --command -- sleep 10
# ต้องได้ Error ... exceeded quota
```

### กรอง namespace ที่ต้นทาง ไม่ใช่ปลายทาง

Filebeat กรองด้วย `templates[].condition` ที่ตัว autodiscover provider
จึง**ไม่แม้แต่จะเปิดไฟล์** log ของ namespace ที่ไม่อยู่ใน list ประหยัด
ทั้ง CPU และ disk I/O

ผลพลอยได้ที่สำคัญ: Filebeat อยู่ใน namespace `observability`
ซึ่งไม่เคยอยู่ใน list ที่อนุญาต จึงอ่าน log ตัวเองไม่ได้ ไม่มีทางเกิด
ลูป log-เก็บ-log-ตัวเอง ไม่ว่าจะเพิ่ม namespace ไหนเข้าไปในอนาคต

### เพิ่ม namespace ใหม่

manifest รองรับหลาย namespace โดยโครงสร้าง — ชื่อ data stream และ
index pattern อ่านค่า `kubernetes.namespace` จริง ไม่ได้ hardcode "vertex"
การเพิ่มทำแค่แก้ `filebeat/02-configmap.yaml` จุดเดียว

```yaml
condition:
  or:
    - equals: {kubernetes.namespace: vertex}
    - equals: {kubernetes.namespace: <namespace ใหม่>}
```

แล้วรัน `./deploy.sh` ใหม่ ไม่ต้องแก้ index template, ILM policy หรือ
Kibana data view เลย (`logs-*-prod` ครอบทุก namespace อยู่แล้ว)

**แต่ต้องเช็คก่อนเสมอ** — ResourceQuota ที่ 1,700Mi/2,800Mi ตั้งไว้พอดี
กับปริมาณ log ของ `vertex` เท่านั้น เพิ่ม namespace คือเพิ่ม disk และ
heap ของ Elasticsearch ตามจริง อาจต้องขยายเพดานก่อน (ดู VT-62)

### `local-path` ไม่บังคับขนาด PVC — ILM คือเพดานจริง

storageClass ที่ k3s ให้มาเป็นแค่ hostPath bind ขอ PVC 5 Gi แต่เขียนได้จนเต็ม disk

สิ่งเดียวที่หยุดข้อมูลไม่ให้โตไปเรื่อยๆ คือ **ILM policy ที่ลบ log อายุเกิน 7 วัน**
และตั้ง disk watermark ให้ Elasticsearch หยุดเขียนตั้งแต่ disk เต็ม 85%
เพื่อเหลือที่ให้ PostgreSQL ที่ใช้ disk ก้อนเดียวกัน

### เปิด authentication แต่ปิด TLS ภายในคลัสเตอร์

traffic ทั้งหมดอยู่ในคลัสเตอร์และ Service เป็น ClusterIP เหมือน PostgreSQL
ซึ่งก็ไม่ได้ใช้ TLS อยู่แล้ว การเปิด TLS จะเพิ่มงานจัดการ cert
โดยไม่ได้เพิ่มความปลอดภัยที่มีความหมายในบริบทนี้

แต่ **authentication เปิด** และแยก user ตามหน้าที่

| user | ใช้ที่ไหน | ทำอะไรได้ |
|---|---|---|
| `elastic` | งานดูแล · setup job | ทุกอย่าง |
| `kibana_system` | Kibana | เท่าที่ Kibana ต้องใช้ |
| `filebeat_writer` | Filebeat | เขียน `logs-*` เท่านั้น · **ลบไม่ได้** |

`filebeat_writer` ลบไม่ได้โดยตั้งใจ — ถ้า Filebeat ถูกยึด
สิ่งแรกที่ผู้บุกรุกอยากทำคือลบ log เพื่อกลบร่องรอย

---

## ถ้า node memory ตึง

ปิด Kibana ได้โดยไม่เสีย log

```bash
kubectl scale deploy/kibana -n observability --replicas=0
```

คืน memory 800 Mi ทันที · Filebeat กับ Elasticsearch ยังเก็บ log ต่อตามปกติ
เปิดกลับมาตอนจะดูข้อมูลก็ได้ ข้อมูลไม่หาย

---

## ยังไม่ได้ทำ

**ไม่มีการแจ้งเตือนเมื่อ pipeline หยุดทำงาน**

ถ้า Filebeat ตายหรือ Elasticsearch ปฏิเสธ document log จะหายเงียบๆ
แล้วมารู้ตอนที่ต้องใช้

cluster นี้มี kube-prometheus-stack อยู่แล้วใน namespace `monitoring`
จึงต่อยอดได้ด้วยการทำ ServiceMonitor ให้ Filebeat แล้วตั้ง alert
บันทึกไว้เป็นงานที่รู้ตัวว่ายังขาด ไม่ใช่ปล่อยให้เข้าใจผิดว่าครบแล้ว

---

## ความปลอดภัย

`.gitignore` กัน `kubeconfig*` `*-secret.yaml` `*.key` `*.pem` `.env` ไว้แล้ว
**ตรวจไฟล์ด้วยตาก่อน commit ทุกครั้ง** — เคยมี private key หลุดขึ้น
public repository มาแล้วในโปรเจกต์นี้ (VT-12)

ไฟล์ `elasticsearch/00-secret.example.yaml` มีแต่ค่า `REPLACE_ME`
รหัสจริงถูกสร้างโดย `deploy.sh` และอยู่ใน k8s Secret เท่านั้น ไม่เคยลงไฟล์

## Grafana dashboard

`grafana/vertex-overview.json` + `./deploy-dashboard.sh` — โหลดผ่าน sidecar ของ
kube-prometheus-stack ไม่ต้องใช้รหัสผ่าน Grafana และ dashboard อยู่ใน git ได้

รายละเอียดอยู่ใน `grafana/README.md`

## Monitoring stack (Prometheus + Grafana + Alertmanager)

`monitoring/` — ค่าที่ใช้จริงของ kube-prometheus-stack พร้อม alert rule ของ Vertex

เดิม stack นี้ถูกติดตั้งด้วยมือ ค่าอยู่แต่ในคลัสเตอร์ ตอนนี้ดึงลงมาไว้ใน git แล้ว
รายละเอียดอยู่ใน `monitoring/README.md`
