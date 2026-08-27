#!/usr/bin/env bash
# =============================================================================
# ติดตั้ง/อัปเดต monitoring stack (Prometheus + Grafana + Alertmanager)
# =============================================================================
# ก่อนหน้านี้ stack นี้ถูกติดตั้งด้วยมือ ค่าที่ใช้จริงจึงอยู่แต่ในคลัสเตอร์
# ไม่มีใครรู้ว่าตั้งอะไรไว้บ้างนอกจากไปงัดดูด้วย helm get values
#
#   INGRESS_HOST=your-domain.example.com ./deploy.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=monitoring
RELEASE=prometheus-grafana
CHART_VERSION=87.16.0   # ตรึงไว้เท่าที่ใช้อยู่จริง อัปเกรดเมื่อจงใจเท่านั้น

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# host จริงไม่อยู่ใน repo เพราะ repo นี้เป็น public
if [ -z "${INGRESS_HOST:-}" ]; then
  echo "FATAL: ต้องตั้ง environment variable INGRESS_HOST ก่อนรัน" >&2
  echo "  ตัวอย่าง: INGRESS_HOST=your-domain.example.com ./deploy.sh" >&2
  exit 1
fi

# รหัสผ่าน Grafana อยู่ใน Secret ไม่ใช่ใน values
#
# ของเดิมฝัง adminPassword เป็น plain text ไว้ใน helm release ซึ่งใครที่อ่าน
# release ได้ก็เห็นหมด และถ้าเอา values ก้อนนั้นขึ้น git ก็หลุดออกสู่สาธารณะทันที
if ! kubectl -n "$NS" get secret grafana-admin >/dev/null 2>&1; then
  echo "FATAL: ยังไม่มี Secret grafana-admin ใน namespace $NS" >&2
  echo "  สร้างด้วย:" >&2
  echo "    kubectl -n $NS create secret generic grafana-admin \\" >&2
  echo "      --from-literal=admin-user=admin \\" >&2
  echo "      --from-literal=admin-password='<รหัสผ่านที่ตั้งเอง>'" >&2
  exit 1
fi

say "เพิ่ม helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update prometheus-community >/dev/null

say "ติดตั้ง/อัปเดต $RELEASE (chart $CHART_VERSION)"
# pipefail อยู่แล้วจาก set -euo — ห้ามต่อ | tee โดยไม่มีมัน
# เพราะ exit code ที่ shell เห็นจะเป็นของ tee ซึ่งสำเร็จเสมอ
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NS" --create-namespace \
  --version "$CHART_VERSION" \
  --values values.yaml \
  --set "grafana.ingress.hosts[0]=$INGRESS_HOST" \
  --set "grafana.grafana\.ini.server.domain=$INGRESS_HOST" \
  --wait --timeout 10m

say "ส่ง alert rule ของ Vertex"
kubectl apply -f rules/

say "ตรวจว่า Prometheus อ่าน rule เข้าไปจริง"
# rule ที่ไม่มี label release=prometheus-grafana จะถูกสร้างแต่ไม่มีใครอ่าน
# และไม่มีอะไรฟ้อง — ตรงนี้คือด่านเดียวที่จับได้
kubectl -n vertex get prometheusrule vertex-alerts \
  -o jsonpath='{.metadata.labels.release}' | grep -q "$RELEASE" \
  || { echo "FATAL: vertex-alerts ไม่มี label release=$RELEASE" >&2; exit 1; }

echo
echo "✅ เสร็จแล้ว — เปิด https://$INGRESS_HOST/grafana/"
echo "   ตรวจ alert ที่ Prometheus UI > Alerts หรือ:"
echo "   kubectl -n vertex get prometheusrule vertex-alerts -o yaml"
