#!/usr/bin/env bash
# =============================================================================
# ส่ง Grafana dashboard ขึ้นคลัสเตอร์ — รันซ้ำได้เสมอ
# =============================================================================
# Grafana ไม่ได้ถูกแก้ตรงๆ เราแค่สร้าง ConfigMap ที่ติด label ที่ sidecar เฝ้าดูอยู่
# แล้ว sidecar จะไปวางไฟล์ให้เอง — ไม่ต้องใช้รหัสผ่าน Grafana เลย
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# namespace ไหนก็ได้ที่ sidecar มองเห็น (ตั้ง NAMESPACE=ALL ไว้)
# วางไว้ที่ vertex เพื่อให้อยู่ใกล้ service ที่มันวัด และลบพร้อมกันได้ถ้าเลิกใช้
NS="${DASHBOARD_NAMESPACE:-vertex}"

kubectl create configmap vertex-grafana-dashboards \
  --namespace "$NS" \
  --from-file=vertex-overview.json=grafana/vertex-overview.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -

echo "✅ ส่ง dashboard ขึ้น namespace $NS แล้ว"
echo "   sidecar ใช้เวลาสักครู่กว่าจะเห็น — เปิด Grafana แล้วหา 'Vertex — ภาพรวมทั้งระบบ'"
