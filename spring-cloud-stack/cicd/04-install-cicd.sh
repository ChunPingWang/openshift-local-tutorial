#!/bin/bash
# ============================================================
# CI/CD 一鍵安裝與驗證腳本（Tekton + ArgoCD）
# 用法：./04-install-cicd.sh
# 前置：已登入 kubeadmin，CRC 至少 6 CPU / 16GB RAM（見 README 資源建議）
# ============================================================
set -e
export PATH="$HOME/.crc/bin/oc:$PATH"
CICD_DIR="$(dirname "$0")"

echo "═══════════════════════════════════════════════════════"
echo " 步驟 1：安裝 OpenShift Pipelines (Tekton) Operator"
echo "═══════════════════════════════════════════════════════"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "等待 Tekton CRD 就緒..."
until [ "$(oc get crd 2>/dev/null | grep -c tekton.dev)" -ge 5 ]; do sleep 10; done
echo "✅ Tekton CRD 就緒"

echo "═══════════════════════════════════════════════════════"
echo " 步驟 2：安裝 OpenShift GitOps (ArgoCD) Operator"
echo "═══════════════════════════════════════════════════════"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "等待 ArgoCD CRD 就緒..."
until [ "$(oc get crd 2>/dev/null | grep -c argoproj.io)" -ge 3 ]; do sleep 10; done
echo "✅ ArgoCD CRD 就緒"

echo "═══════════════════════════════════════════════════════"
echo " 步驟 3：準備 petclinic project 與 BuildConfig"
echo "═══════════════════════════════════════════════════════"
oc get project petclinic &>/dev/null || oc new-project petclinic
oc apply -f "$CICD_DIR/../../petclinic/02-imagestreams.yaml" -n petclinic

# 建立 binary S2I BuildConfig（3 個業務服務）
for svc in customers-service vets-service visits-service; do
  oc get buildconfig "$svc" -n petclinic &>/dev/null || \
    oc new-build --name="$svc" --binary --strategy=source \
      --image-stream=openshift/java:openjdk-17-ubi8 -n petclinic
done

echo "═══════════════════════════════════════════════════════"
echo " 步驟 4：授予 pipeline ServiceAccount 權限"
echo "═══════════════════════════════════════════════════════"
oc policy add-role-to-user edit -z pipeline -n petclinic
oc adm policy add-scc-to-user privileged -z pipeline -n petclinic

echo "═══════════════════════════════════════════════════════"
echo " 步驟 5：套用 Tekton Pipeline + ArgoCD Application"
echo "═══════════════════════════════════════════════════════"
oc apply -f "$CICD_DIR/01-tekton-pipeline.yaml" -n petclinic
oc apply -f "$CICD_DIR/03-argocd-gitops.yaml"

echo "═══════════════════════════════════════════════════════"
echo " 步驟 6：觸發一次 PipelineRun（CI 驗證）"
echo "═══════════════════════════════════════════════════════"
oc create -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: petclinic-cicd-run-
  namespace: petclinic
spec:
  pipelineRef:
    name: petclinic-cicd
  workspaces:
  - name: shared-workspace
    persistentVolumeClaim:
      claimName: petclinic-source-pvc
  taskRunTemplate:
    serviceAccountName: pipeline
EOF

echo ""
echo "✅ 安裝完成。驗證指令："
echo "   oc get pipelinerun -n petclinic        # Pipeline 執行狀態"
echo "   oc get applications -n openshift-gitops # ArgoCD 同步狀態"
echo "   oc get route -n openshift-gitops        # ArgoCD UI 網址"
