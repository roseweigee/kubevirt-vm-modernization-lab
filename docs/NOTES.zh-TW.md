# VM 上 Kubernetes 與應用現代化 Lab — 操作筆記

情境：銀行有一個還跑在 VM 裡的舊系統。先把它原封不動搬上 Kubernetes（以 VM 的形式），用 Kubernetes 的方式管理它；接著把同一個服務改寫成容器，在**呼叫端完全不用改**的情況下把流量切過去，出問題再一行指令切回 VM。

這個 lab 分兩部分：

| 部分 | 在哪裡跑 | 用途 |
|---|---|---|
| A. 自動化驗證 | GitHub Actions 上的 kind（KubeVirt + CDI） | 每一步都有腳本自動判斷結果 |
| B. 實際操作 | Red Hat Developer Sandbox（OpenShift Virtualization） | 在真正的 OpenShift Virtualization 上親手做一遍 |

KubeVirt 是 OpenShift Virtualization 的上游開源專案；CDI（Containerized Data Importer）負責把 VM 磁碟映像檔匯入成 PVC。

---

## 核心觀念（先懂這個再動手）

- **VM 就是一個 Kubernetes 物件**：`VirtualMachine`（VM 定義，像 Deployment）→ `VirtualMachineInstance`（正在跑的那一次，像 Pod）。
- **VM 跑在 Pod 裡面**：每台 VM 都有一個 `virt-launcher` Pod，裡面是 QEMU/KVM 行程。Pod 會帶著 VM template 的 labels，所以 **Service、NetworkPolicy 對 VM 的用法跟對容器一模一樣**。
- **磁碟就是 PVC**：`DataVolume` 是 CDI 的物件，會自動建立 PVC 並把映像檔匯入（HTTP、registry、從其他 PVC clone）。VM 關機再開機，資料還在。
- **開關機用 runStrategy**：`Always`＝開機並保持運行，`Halted`＝關機。`virtctl start/stop` 也是在改這個欄位。

---

## A. 自動化驗證（GitHub Actions）

每次 push，CI 會：建立 kind 叢集 → 安裝 KubeVirt、CDI、virtctl → 執行 `scripts/verify.sh`。

| Step | 做什麼 | 怎麼驗證 |
|---|---|---|
| 1 匯入磁碟 | `DataVolume` 從網路下載 Ubuntu qcow2 映像檔，匯入成 PVC | DataVolume 狀態 `Succeeded` |
| 2 開機 | `VirtualMachine` 用這顆 PVC 開機，cloud-init 把小網站裝成 systemd 服務 | VMI `Ready`（KubeVirt 對 VM 內部 :8080 做 readiness probe） |
| 3 Service | 一般的 `Service` 選到 VM 的 virt-launcher Pod | 從 client Pod 拿得到「running in a VM」頁面 |
| 4 隔離 | `NetworkPolicy` 只允許 `role=frontend` | frontend 通、other 被擋 |
| 5 關機再開機 | runStrategy `Halted` → `Always` | 關機時連不到；開機後 boot 計數 +1（計數存在 VM 自己的磁碟上，證明資料沒掉） |
| 6 現代化 | 同一個服務改成 2 個副本的 Deployment，切換 Service selector | 同一個 Service 名稱，回應變成「running in a container」；NetworkPolicy 照樣有效 |
| 7 回滾 | selector 切回 `tier: vm` | 流量回到 VM，VM 全程沒動 |

**為什麼 Service 切換能做到呼叫端不用改？** Service 的 selector 是 `app=legacy-app, tier=vm`。容器版本的 label 是 `app=legacy-app, tier=container`，一開始不會收到流量；只改 Service 的 `tier`，呼叫端的網址（`legacy-app.vm-lab.svc`）完全不變。這就是「strangler（絞殺者）」模式：新舊並存、逐步切換、隨時可退。

**NetworkPolicy 為什麼切換後還有效？** Policy 選的是 `app=legacy-app`，VM 和容器版本都有這個 label，所以不管流量在哪一邊，other 都被擋。

### 實測結果（GitHub Actions，KubeVirt v1.10.0、CDI v1.66.1，kind，KVM 硬體加速）

| 檢查 | 結果 |
|---|---|
| Step 1 DataVolume 匯入 | Succeeded |
| Step 2 VM 開機並 Ready | Running、Ready |
| Step 3 frontend、other 經 Service 連到 VM | 都拿到「running in a VM (boot #1)」 |
| Step 4 NetworkPolicy | other 被擋；frontend 照常 |
| Step 5 關機 → 連不到；開機 → 計數變 boot #2 | 通過 |
| Step 6 切到容器 | 拿到「running in a container」；other 照樣被擋 |
| Step 7 切回 VM | 回到「boot #2」 |
| 合計 | **12/12 通過**，整個流程約 6 分鐘 |

### 這次實際踩到的 4 個坑（面試很好講）

| 問題 | 原因 | 解法 |
|---|---|---|
| 安裝 KubeVirt 時 `kubectl apply` 失敗：annotation 超過 262144 bytes | KubeVirt 的 CRD 太大，client-side apply 會把整份內容塞進 `last-applied-configuration` annotation | 改用 `kubectl apply --server-side` |
| 剛裝好就建 VM，webhook `virt-api` connection refused | Operator 回報 Available 時，virt-api 不一定已經能接請求 | 等 virt-api、virt-controller、virt-handler rollout 完成，再加上重試 |
| DataVolume 一直不匯入：`no accessMode specified in StorageProfile` | CDI 不認識 kind 的 local-path StorageClass，不知道要用什麼 access mode | 在 DataVolume 寫明 `accessModes: [ReadWriteOnce]`、`volumeMode: Filesystem`（正式環境則是設定 StorageProfile） |
| 第一次開機正常，關機再開機後服務連不到 | KubeVirt 預設每次開機給 VM 新的隨機 MAC；Ubuntu 第一次開機時 cloud-init 把網路設定綁在舊 MAC 上，網卡沒被設定起來 | 在 VM 的 interface 固定 `macAddress`。從 VMware 遷移時也要注意這點：有些系統的授權或網路設定是綁 MAC 的 |

---

## B. Developer Sandbox 實際操作（OpenShift Virtualization）

### 0. 準備

1. 到 Red Hat Developer Sandbox 登入（免費，有效期內可重複使用）。
2. 右上角你的帳號 → **Copy login command** → 複製 `oc login --token=... --server=...` 貼到 Mac 終端機。
3. 確認：

```bash
oc whoami
oc project          # 會看到你的 project，例如 xxxx-dev
oc get datasource -n openshift-virtualization-os-images   # 看得到 fedora 等開機來源
```

> 裝 `virtctl`：在 OpenShift Console 右上角 **?** → **Command Line Tools**，下載 virtctl（選 Mac ARM）。

### 1. 用 YAML 建立 VM（GitOps 的做法）

```bash
git clone https://github.com/roseweigee/kubevirt-vm-modernization-lab.git
cd kubevirt-vm-modernization-lab
oc apply -f sandbox/legacy-vm-openshift.yaml
```

觀察：

```bash
oc get dv -w                 # DataVolume 從 fedora 開機來源 clone 磁碟，等到 Succeeded
oc get vm,vmi                # VM Running、VMI Ready
oc get pods -l kubevirt.io=virt-launcher -o wide    # VM 跑在這個 Pod 裡
```

📸 截圖：Console → **Virtualization → VirtualMachines**，看到 legacy-app 是 Running。

### 2. 用 Route 從瀏覽器打開 VM 裡的服務

```bash
oc get route legacy-app -o jsonpath='https://{.spec.host}{"\n"}'
curl -s "https://$(oc get route legacy-app -o jsonpath='{.spec.host}')"
# legacy-app running in a VM on OpenShift Virtualization (boot #1)
```

📸 截圖：瀏覽器開這個網址的畫面。

### 3. 進 VM 的 console

```bash
virtctl console legacy-app          # 帳號 fedora / 密碼 kubevirt-lab，離開按 Ctrl+]
```

進去後看一下：

```bash
systemctl status legacy-app
cat /var/lib/legacy/bootcount
```

也可以在 Console 點 VM → **Console** 分頁，直接在網頁上操作。📸 截圖。

### 4. 關機、開機，確認資料還在

```bash
virtctl stop legacy-app
oc get vmi                 # VMI 消失
virtctl start legacy-app
oc wait vmi legacy-app --for=condition=Ready --timeout=10m
curl -s "https://$(oc get route legacy-app -o jsonpath='{.spec.host}')"
# ... (boot #2)   ← 計數存在 VM 的磁碟（PVC）上，所以 +1
```

### 5. 現代化：切到容器版本

```bash
oc apply -f sandbox/container-version-openshift.yaml
oc rollout status deploy/legacy-app-container
oc patch service legacy-app --type=merge -p '{"spec":{"selector":{"app":"legacy-app","tier":"container"}}}'
curl -s "https://$(oc get route legacy-app -o jsonpath='{.spec.host}')"
# legacy-app running in a container on OpenShift
```

Route 和網址都沒變，後面已經從 VM 換成容器。📸 截圖。

### 6. 回滾

```bash
oc patch service legacy-app --type=merge -p '{"spec":{"selector":{"app":"legacy-app","tier":"vm"}}}'
curl -s "https://$(oc get route legacy-app -o jsonpath='{.spec.host}')"
# 又回到 running in a VM
```

### 7. 收尾（Sandbox 資源有限，做完記得清）

```bash
oc delete -f sandbox/container-version-openshift.yaml
oc delete -f sandbox/legacy-vm-openshift.yaml
```

### Sandbox 常見狀況

| 狀況 | 處理 |
|---|---|
| DataVolume 一直 Pending | Sandbox 的儲存配額有限，先刪掉其他不用的 PVC；或把 `storage: 30Gi` 改小一點（不能小於映像檔大小） |
| VMI 一直不是 Ready | readiness probe 在等 VM 裡的服務起來，Fedora 第一次開機要跑 cloud-init，等 2～5 分鐘；用 `virtctl console` 進去看 `systemctl status legacy-app` |
| `fedora` DataSource 找不到 | `oc get datasource -n openshift-virtualization-os-images` 看實際名稱，改 YAML 的 `sourceRef.name` |
| 配額不足（quota exceeded） | Sandbox 同時只能跑少量 VM，先把其他 VM 停掉 |

---

## C. 對應到真實的 VMware 遷移

| 真實專案 | 這個 lab |
|---|---|
| MTV（Migration Toolkit for Virtualization）連到 vCenter，挑要搬的 VM | 沒有 vCenter，這步沒做 |
| MTV 把 VMware 磁碟複製到叢集上的 DataVolume | Step 1：CDI DataVolume 匯入映像檔（同樣的落地方式） |
| 在 OpenShift 上開機、接網路、設 Service/Route | Step 2–3 |
| 用 NetworkPolicy 取代原本的防火牆規則 | Step 4 |
| 之後逐步把 VM 裡的服務改寫成容器 | Step 6–7 |

---

## D. 面試可能被問到的問題

**Q1：OpenShift Virtualization 是什麼？跟 VMware 差在哪？**
它是 OpenShift 內建的 Operator，上游是 KubeVirt，用 KVM 在 Kubernetes 上跑 VM。差別在於 VM 變成 Kubernetes 物件，可以和容器共用同一套 Service、Route、NetworkPolicy、RBAC、GitOps 和監控，不用維護兩套平台。

**Q2：VM 在 Kubernetes 裡實際是怎麼跑的？**
每台 VM 對應一個 virt-launcher Pod，Pod 裡是 libvirt/QEMU 行程，磁碟是 PVC，網路走 Pod 網路（masquerade 模式）。所以 VM 的排程、資源限制、網路政策都沿用 Kubernetes 的機制。

**Q3：VMware 的 VM 怎麼搬過來？**
用 MTV：建立 vSphere provider、對應網路和儲存（network/storage mapping）、建立 migration plan，分 cold（停機搬）和 warm（先同步、短暫停機切換）兩種。磁碟最後落地成 DataVolume/PVC。我在 lab 裡用 CDI 匯入映像檔來練習這個落地步驟，但沒有實際接過 vCenter。

**Q4：VM 搬上來之後，為什麼還要容器化？怎麼做才安全？**
VM 搬上來只是第一步，真正的效益在逐步拆成容器。做法是新舊並存、用 Service selector 切換流量，呼叫端不用改，出問題一行指令切回 VM。這個 lab 的 Step 6–7 就是在演練這件事。

**Q5：你實際做過嗎？**
工作上我在 VMware 的 VM 上建過 OpenShift 節點，但沒有導入過 OpenShift Virtualization。這是我自己做的 lab：在 Developer Sandbox 的 OpenShift Virtualization 上實際建立和操作 VM，並把整個流程用 KubeVirt 放到 GitHub Actions 自動驗證。
