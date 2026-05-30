# 安裝與驗證指令總記錄

> 本檔記錄整個 PoC 從零到完整技術棧的所有安裝、部署、驗證指令。
> 每段都附帶預期輸出，方便重現與排查。

## 目錄

1. [OpenShift Local (CRC) 安裝](#1-openshift-local-crc-安裝)
2. [基礎章節驗證（demo-app）](#2-基礎章節驗證-demo-app)
3. [PetClinic 微服務（Spring Cloud）](#3-petclinic-微服務-spring-cloud)
4. [可觀測性技術棧](#4-可觀測性技術棧)
5. [安全技術棧（Keycloak + cert-manager）](#5-安全技術棧)
6. [CI/CD（Tekton + ArgoCD）](#6-cicd-tekton--argocd)
7. [資源清理指令](#7-資源清理指令)

---

## 1. OpenShift Local (CRC) 安裝

```bash
# 解壓並安裝
tar -xJf crc-linux-amd64.tar.xz
sudo cp crc-linux-*/crc /usr/local/bin/

# 啟用 KVM
sudo systemctl enable --now libvirtd

# 設定資源（重要！見 README 資源建議）
crc config set cpus 6
crc config set memory 18432       # 18 GB
crc config set disk-size 80

# 系統檢查與啟動
crc setup
crc start --pull-secret-file pull-secret.txt

# 設定 oc 環境
eval $(crc oc-env)

# 登入
oc login -u kubeadmin -p <密碼> https://api.crc.testing:6443
crc console --credentials      # 取得登入資訊
```

**驗證：**
```bash
crc status                     # 預期 OpenShift: Running
oc get nodes                   # 預期 crc Ready
oc get co                      # ClusterOperators 全部 Available
```

---

## 2. 基礎章節驗證 (demo-app)

```bash
oc new-project demo-app

# 第 8 章：部署（注意 SCC — 必須用 rootless 映像）
oc create deployment nginx --image=nginxinc/nginx-unprivileged:1.25 --replicas=2
oc create deployment hello-world --image=docker.io/openshift/hello-openshift:latest --replicas=2
oc expose deployment nginx --port=80 --target-port=8080
oc expose deployment hello-world --port=8080
oc expose service nginx
oc expose service hello-world

# 第 9 章：S2I 建置
oc new-app nodejs~https://github.com/openshift/nodejs-ex.git --name=nodejs-sample
oc logs -f buildconfig/nodejs-sample      # 追蹤建置
oc expose service/nodejs-sample

# 第 10 章：ConfigMap + Secret
oc create configmap app-config \
  --from-literal=DATABASE_HOST=postgres \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info
oc create secret generic db-secret \
  --from-literal=username=admin --from-literal=password=S3cur3P@ssw0rd

# 第 11 章：PVC
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: my-data }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF

# 第 12 章：HPA
oc set resources deployment/hello-world --requests=cpu=50m,memory=64Mi --limits=cpu=200m,memory=128Mi
oc autoscale deployment/hello-world --min=2 --max=5 --cpu-percent=70
```

**驗證（全部應 HTTP 200）：**
```bash
curl -s -o /dev/null -w "%{http_code}" http://nginx-demo-app.apps-crc.testing
curl http://hello-world-demo-app.apps-crc.testing       # Hello OpenShift!
oc get pvc my-data                                       # 預期 Bound
oc get hpa hello-world                                   # min=2 max=5

# 第 13 章：日誌 / port-forward / events
oc logs <pod> ; oc port-forward deployment/nginx 18080:8080
oc get events --sort-by='.lastTimestamp'

# 第 14 章：Pod 間通訊 / DNS
NGINX_POD=$(oc get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')
oc exec $NGINX_POD -- curl -s -o /dev/null -w "%{http_code}" \
  http://hello-world.demo-app.svc.cluster.local:8080     # 預期 200
```

---

## 3. PetClinic 微服務 (Spring Cloud)

```bash
oc new-project petclinic
oc adm policy add-scc-to-user anyuid -z default -n petclinic

# 套用 ImageStream + BuildConfig（7 個服務）
oc apply -f petclinic/02-imagestreams.yaml
oc apply -f petclinic/01-buildconfigs.yaml

# S2I 建置（依序，config-server 先）
oc start-build config-server --follow
for svc in discovery-server customers-service vets-service \
           visits-service api-gateway admin-server; do
  oc start-build $svc &
done; wait

# 設定 Deployment 映像並部署
oc apply -f petclinic/03-deployments.yaml
REG="image-registry.openshift-image-registry.svc:5000/petclinic"
for svc in config-server discovery-server customers-service \
           vets-service visits-service api-gateway admin-server; do
  oc set image deployment/$svc ${svc}=${REG}/${svc}:latest -n petclinic
done
oc apply -f petclinic/04-services-routes.yaml
```

**驗證：**
```bash
oc get pods -n petclinic                                 # 7 個服務 1/1 Running
curl http://petclinic.apps-crc.testing/api/vet/vets      # 6 位獸醫 JSON
curl -H "Accept: application/json" \
  http://petclinic-discovery.apps-crc.testing/eureka/apps  # Eureka 註冊清單
```

---

## 4. 可觀測性技術棧

```bash
oc apply -f spring-cloud-stack/observability/01-namespace.yaml
for ns in observability security; do
  oc adm policy add-scc-to-group anyuid system:serviceaccounts:$ns
done

# Prometheus + AlertManager + Grafana
oc apply -f spring-cloud-stack/observability/02-prometheus-stack.yaml
# OTel Collector + Zipkin
oc apply -f spring-cloud-stack/observability/03-otel-zipkin.yaml
# Loki + Promtail
oc apply -f spring-cloud-stack/observability/04-loki-stack.yaml
# EFK（正式環境，CRC 資源不足時跳過）
# oc apply -f spring-cloud-stack/observability/05-efk-stack.yaml
```

**驗證（全部 HTTP 200）：**
```bash
for u in prometheus alertmanager grafana zipkin; do
  curl -s -o /dev/null -w "$u: %{http_code}\n" http://$u.apps-crc.testing
done
oc get pods -n observability            # 6 個服務 Running
```

---

## 5. 安全技術棧

```bash
# cert-manager（mTLS）
oc apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
oc apply -f spring-cloud-stack/security/01-cert-manager.yaml

# Keycloak（OAuth2/OIDC）
oc apply -f spring-cloud-stack/security/02-keycloak.yaml

# 流量管控（NetworkPolicy + Route 速率限制）
oc apply -f spring-cloud-stack/security/03-traffic-control.yaml
```

**驗證 — JWT 流程：**
```bash
# 若 user 報 "Account is not fully set up"，需補 firstName/lastName（見下方排查）
TOKEN=$(curl -s -X POST \
  http://keycloak.apps-crc.testing/realms/petclinic/protocol/openid-connect/token \
  -d "grant_type=password&client_id=petclinic-gateway&client_secret=petclinic-gateway-secret" \
  -d "username=alice&password=alice123" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# 解碼 JWT 確認 roles claim
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | grep roles
# 預期：alice→['user'] bob→['vet'] admin→['vet','admin','user']
```

**排查：Keycloak "Account is not fully set up"**
```bash
# 原因：匯入的 user 缺 firstName/lastName，VERIFY_PROFILE 阻擋登入
KC=http://keycloak.apps-crc.testing
ADMIN=$(curl -s -X POST $KC/realms/master/protocol/openid-connect/token \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin123" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
# 透過 admin API 補 firstName/lastName/emailVerified（見對話記錄的 Python 片段）
```

---

## 6. CI/CD (Tekton + ArgoCD)

```bash
# 一鍵安裝（含 Operator 安裝、Pipeline、ArgoCD Application、觸發 PipelineRun）
./spring-cloud-stack/cicd/04-install-cicd.sh
```

**或手動分步（見 `04-install-cicd.sh` 內容）：**
```bash
# 安裝 Operators
oc apply -f - <<< "<Pipelines Subscription>"   # openshift-pipelines-operator-rh
oc apply -f - <<< "<GitOps Subscription>"       # openshift-gitops-operator

# 等待 CRD
until [ "$(oc get crd | grep -c tekton.dev)" -ge 5 ]; do sleep 10; done
until [ "$(oc get crd | grep -c argoproj.io)" -ge 3 ]; do sleep 10; done

# binary S2I BuildConfig
for svc in customers-service vets-service visits-service; do
  oc new-build --name=$svc --binary --strategy=source \
    --image-stream=openshift/java:openjdk-17-ubi8 -n petclinic
done

# pipeline SA 權限
oc policy add-role-to-user edit -z pipeline -n petclinic
oc adm policy add-scc-to-user privileged -z pipeline -n petclinic

# 套用 Pipeline + Triggers + ArgoCD
oc apply -f spring-cloud-stack/cicd/01-tekton-pipeline.yaml -n petclinic
oc apply -f spring-cloud-stack/cicd/02-tekton-triggers.yaml -n petclinic
oc apply -f spring-cloud-stack/cicd/03-argocd-gitops.yaml
```

**驗證：**
```bash
# Tekton：PipelineRun 應 fetch-source + build-* Succeeded
oc get pipelinerun -n petclinic
oc get taskrun -n petclinic
oc get imagestreamtag -n petclinic | grep -E "customers|vets"  # 映像已建置

# ArgoCD：Application 已建立，server Running
oc get applications -n openshift-gitops
oc get route openshift-gitops-server -n openshift-gitops       # ArgoCD UI

# ArgoCD admin 密碼
oc get secret openshift-gitops-cluster -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d
```

---

## 7. 資源清理指令

```bash
# 刪除使用者 namespace
oc delete project demo-app petclinic observability security

# 移除 Operators（釋放最多資源）
oc delete subscription openshift-pipelines-operator-rh -n openshift-operators
oc delete subscription openshift-gitops-operator -n openshift-operators
oc delete csv -n openshift-operators -l operators.coreos.com/openshift-pipelines-operator-rh
oc delete csv -n openshift-operators -l operators.coreos.com/openshift-gitops-operator

# 清理殘留 namespace（Tekton/GitOps 自建的）
oc delete project openshift-pipelines openshift-gitops

# 強制清除卡住的 namespace finalizer（如 Kasten stale API）
oc delete apiservice <stale-apiservice>

# 清理已完成的 build/pipeline pods
oc delete pods --field-selector=status.phase=Succeeded -n <namespace>

# 完整重置 CRC
crc stop && crc delete
crc start --pull-secret-file pull-secret.txt
```

---

## 排查紀錄（實際遇到的問題）

| 問題 | 原因 | 解法 |
|------|------|------|
| nginx CrashLoopBackOff | SCC 禁止 root | 改用 `nginxinc/nginx-unprivileged` |
| quay.io 映像 401 | 需認證 | 改用 docker.io 公開映像 |
| Pod Pending: Insufficient memory/cpu | CRC 資源不足 | 縮減 requests 或停用非必要服務 |
| PVC Pending | `WaitForFirstConsumer` | 部署使用 PVC 的 Pod 觸發綁定 |
| DiskPressure taint | CRC 磁碟滿 | 清理已完成 build pods / prune 映像 |
| namespace 卡 Terminating | Kasten stale API | 刪除 stale apiservice |
| Istio sidecar Init:CrashLoop | RHCOS iptables 限制 | 用 Istio CNI / Service Mesh Operator |
| Keycloak "Account not fully set up" | user 缺 firstName/lastName | admin API 補完 profile |
| ArgoCD controller Pending | CRC CPU 天花板 | 提高 CRC CPU 配置（見資源建議） |
