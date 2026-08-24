#!/usr/bin/env bash
# =============================================================================
# ติดตั้ง observability stack — รันซ้ำได้เสมอ
# =============================================================================
# ทุกขั้นเป็น declarative ถ้าเครื่องหลับหรือหลุดกลางทาง ให้รันสคริปต์นี้ใหม่
# ได้เลย ของที่ทำไปแล้วจะไม่ถูกทำซ้ำแบบเสียหาย
#
#   ./deploy.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=observability
say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# --- ตรวจสิ่งที่ต้องมีก่อน ---------------------------------------------------
say "ตรวจ vm.max_map_count บน node"
# Elasticsearch ต้องการอย่างน้อย 262144 ไม่งั้นจะไม่ start เลย
# ต้องตั้งบน host ไม่ใช่ใน container — ดู README หัวข้อ "ก่อนเริ่ม"
echo "    ข้ามการตรวจอัตโนมัติ (ต้องเช็คบน host เอง): sysctl vm.max_map_count"

# --- ชั้นเพดาน ต้องมาก่อนเสมอ ------------------------------------------------
say "namespace + ResourceQuota + LimitRange"
# เพดานต้องมีก่อนของจะเข้า ไม่งั้น pod แรกที่ขึ้นมาจะยังไม่ถูกจำกัด
kubectl apply -f namespace/

say "RBAC ของ CI/CD"
kubectl apply -f cicd/01-deploy-rbac.yaml

# --- ความลับ -----------------------------------------------------------------
say "ตรวจ Secret"
if ! kubectl get secret es-credentials -n "$NS" >/dev/null 2>&1; then
  echo "    ยังไม่มี es-credentials — สร้างใหม่ด้วยรหัสสุ่ม"
  kubectl create secret generic es-credentials -n "$NS" \
    --from-literal=ELASTIC_PASSWORD="$(openssl rand -hex 24)" \
    --from-literal=KIBANA_SYSTEM_PASSWORD="$(openssl rand -hex 24)" \
    --from-literal=FILEBEAT_PASSWORD="$(openssl rand -hex 24)"
  # ใช้ -hex ไม่ใช่ -base64 เพราะ base64 มี / + = ที่ต้องระวังเรื่อง escape
  # ตอนส่งเป็น JSON ให้ Elasticsearch — hex ปลอดภัยกว่าโดยไม่ต้องคิด
else
  echo "    มีอยู่แล้ว ไม่แตะ"
fi

# --- Elasticsearch -----------------------------------------------------------
say "Elasticsearch"
kubectl apply -f elasticsearch/01-service.yaml
kubectl apply -f elasticsearch/02-statefulset.yaml
echo "    รอให้พร้อม (ครั้งแรกอาจนานหลายนาทีเพราะต้อง pull image 1.3 GB)"
kubectl rollout status statefulset/elasticsearch -n "$NS" --timeout=15m

# --- ตั้งค่าใน Elasticsearch -------------------------------------------------
say "ILM policy + index template + user"
kubectl create configmap es-setup-files -n "$NS" \
  --from-file=elasticsearch-setup/ilm-policy.json \
  --from-file=elasticsearch-setup/index-template.json \
  --dry-run=client -o yaml | kubectl apply -f -
# Job แก้ไม่ได้หลังสร้าง ต้องลบก่อนถึงจะรันใหม่ได้
kubectl delete job es-setup -n "$NS" --ignore-not-found
kubectl apply -f elasticsearch-setup/apply-job.yaml
kubectl wait --for=condition=complete job/es-setup -n "$NS" --timeout=10m
kubectl logs job/es-setup -n "$NS"

# --- Filebeat ----------------------------------------------------------------
say "Filebeat"
kubectl apply -f filebeat/01-rbac.yaml
kubectl apply -f filebeat/02-configmap.yaml
# ผูก checksum ของ config เข้ากับ pod template
# ไม่มีขั้นนี้ การแก้ filebeat.yml จะไม่มีผลจนกว่าจะ restart เอง
CKSUM=$(kubectl get configmap filebeat-config -n "$NS" \
          -o jsonpath='{.data.filebeat\.yml}' | shasum -a 256 | cut -c1-16)
sed "s/REPLACED_BY_DEPLOY_SCRIPT/$CKSUM/" filebeat/03-daemonset.yaml \
  | kubectl apply -f -
kubectl rollout status daemonset/filebeat -n "$NS" --timeout=5m

# --- Kibana ------------------------------------------------------------------
say "Kibana"
kubectl apply -f kibana/01-service.yaml
kubectl apply -f kibana/02-deployment.yaml
kubectl rollout status deployment/kibana -n "$NS" --timeout=10m

say "data view + saved search ของ Kibana"
# ตั้งค่าเหล่านี้อยู่ใน git ไม่ใช่กดเอาในหน้าจอ
# ตั้ง cluster ใหม่แล้วได้ Discover ที่ใช้งานได้ทันทีโดยไม่ต้องจำว่าเคยตั้งอะไร
kubectl create configmap kibana-saved-objects -n "$NS" \
  --from-file=kibana/saved-objects.ndjson \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job kibana-import -n "$NS" --ignore-not-found
kubectl apply -f kibana/03-import-job.yaml
kubectl wait --for=condition=complete job/kibana-import -n "$NS" --timeout=10m
kubectl logs job/kibana-import -n "$NS"

# --- สรุป --------------------------------------------------------------------
say "เรียบร้อย"
kubectl get pods -n "$NS" -o wide
cat <<'EOT'

เปิด Kibana:
  kubectl port-forward -n observability svc/kibana 5601:5601
  แล้วเปิด http://localhost:5601

รหัสผ่านสำหรับ login (user: elastic):
  kubectl get secret es-credentials -n observability \
    -o jsonpath='{.data.ELASTIC_PASSWORD}' | base64 -d; echo

EOT
