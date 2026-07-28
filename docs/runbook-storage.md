# Runbook — storage layout: reclaim, extend, isolate

The 200GB boot volume has only ~50GB partitioned; the remaining **165GB has
never been handed to LVM**, so `lvextend` fails with `Insufficient free space`
even though the disk is three-quarters empty. This runbook reclaims what is
wasted, gives LVM the missing 165GB, and moves the two container image stores
onto their own volume so the thing that historically ate the disk can no longer
take the root filesystem — and the cluster — down with it.

*200GB 開機磁碟只切了約 50GB,剩下 **165GB 從來沒交給 LVM**,所以即使磁碟空了
四分之三,`lvextend` 還是報 `Insufficient free space`。本 runbook 先回收浪費掉
的空間,把缺的 165GB 交給 LVM,再把兩個容器 image 儲存區搬到獨立的卷 —— 歷史上
把磁碟吃光的就是它,不該再有能力連根目錄和叢集一起拖垮。*

Steps 1 and 2 are online. Step 3 needs k3s down for roughly ten minutes; all
four sites are unreachable during it. Do steps 1–2 whenever; schedule step 3.

*步驟 1、2 全程線上。步驟 3 需要停 k3s 約十分鐘,期間四個站台都連不上。1、2 隨時
可做;步驟 3 要排時間。*

## Precondition — snapshot the boot volume first

**Goal / 目標:** take an OCI boot-volume backup before step 2. It covers the
whole procedure, not just the partition step.

*動步驟 2 之前先在 OCI 主控台做一次 boot volume 備份。它保護的是整套流程,不是
只有分割區那一步。*

The `oci` CLI is not installed on this node, so this is a console procedure.
Region is **eu-frankfurt-1**; the instance is **louis2**.

*節點上沒裝 `oci` CLI,所以走主控台。地區 **eu-frankfurt-1**,instance 是 **louis2**。*

1. Open the navigation menu (the **three-line icon** at the top left, next to
   the Oracle Cloud logo) → **Compute** → **Instances** → **louis2**.
2. In the **Resources** panel on the left of the instance page, click **Boot
   volume**, then click the volume's name to open its own page.
3. **Create Boot Volume Backup** → name it for the occasion (e.g.
   `louis2-pre-storage-runbook-<date>`) → type **Full** → Create.
4. Wait for the state to go `CREATING` → **`AVAILABLE`**. Do not start step 2
   before it is `AVAILABLE`.

*1. 點左上角**三條橫線的圖示**(在 Oracle Cloud 標誌旁邊)展開導覽選單 → Compute
→ Instances → louis2。2. 在 instance 頁面左側的 Resources 面板點 Boot volume,
再點卷名進到它自己的頁面。3. Create Boot Volume Backup → 命名帶日期用途 → 選
Full → Create。4. 等狀態從 `CREATING` 變成 **`AVAILABLE`**,沒到 AVAILABLE 不要
開始步驟 2。*

A backup taken while the instance runs is crash-consistent — equivalent to
pulling the power. XFS journals, so a restore replays and comes up clean; that
is adequate here. Restoring is not in-place: it is **backup → Create Boot Volume
→ stop the instance → detach the old boot volume → attach the new one → boot**.
Know that path before you need it. Backups bill as backup storage (small at
~17GB used, but not necessarily covered on an Always Free tenancy) — delete the
backup once the runbook has completed and the node has been stable for a few
days.

*運行中做的備份是 crash-consistent,等同斷電;XFS 有 journal,還原時會 replay,
這個用途夠用。還原不是就地覆蓋:**備份 → Create Boot Volume → 停 instance → 卸離
舊 boot volume → 掛上新的 → 開機**,先知道這條路再說。備份以備份儲存計費(17GB
用量金額很小,但 Always Free 租戶不一定涵蓋)—— runbook 跑完、節點穩定幾天後把
備份刪掉。*

Worth knowing which commands here actually bite, because it is not the obvious
ones. `mkfs.xfs` refuses on a mounted device (`contains a mounted filesystem`,
exit 1) and refuses again if it detects any existing filesystem or partition
table, needing `-f` to proceed — every `mkfs` below targets a brand-new empty
LV, so no `-f` appears anywhere, which means a mistyped target stops rather than
destroys. `pvcreate` likewise refuses a device already in a volume group without
`-ff`. Both were verified on this node.

*值得知道這裡哪些指令真的會咬人 —— 不是看起來最兇的那些。`mkfs.xfs` 對已掛載的
裝置會拒絕(`contains a mounted filesystem`,exit 1),偵測到既有檔案系統或分割表
也會拒絕,要 `-f` 才過;下面每個 `mkfs` 的對象都是全新的空 LV,所以整份文件沒有
任何 `-f`,打錯目標的結果是停下來而不是毀掉。`pvcreate` 同樣拒絕已屬於某個 VG 的
裝置,除非給 `-ff`。兩者都在本節點實測過。*

What has no guard at all is step 4's `rm -rf`, aimed at a path one character
away from the live one. After that come the two writes that no tool can sanity-
check for you: `parted` rewriting the partition table, and the `/etc/fstab`
edit, where a line that is syntactically fine but names the wrong device drops
the next boot into emergency mode. This is a single-node cluster with no HA —
restoring the backup is the only recovery path there is.

*完全沒有防護的是步驟 4 的 `rm -rf`,它的目標跟正在用的那份只差一個字。其次是兩個
沒有工具能替你把關的寫入:`parted` 改寫分割表,以及 `/etc/fstab` 的編輯 —— 語法
正確但裝置寫錯的那一行,會讓下次開機掉進 emergency mode。這是單節點、沒有 HA 的
叢集,還原備份是唯一的復原路徑。*

Choosing to create a new `sda4` instead of growing `sda3` does not change this.
It removes exactly one failure mode — the existing partition's boundary is never
rewritten — and touches none of the three above.

*改成切一個新的 `sda4` 而不是延伸 `sda3`,並不會改變這件事。它只排除掉一種失敗
模式(既有分割區的邊界不被改寫),對上面那三項一點幫助也沒有。*

## Starting state (2026-07-28)

```
/dev/sda 200G
├─ sda1  100M  /boot/efi
├─ sda2    2G  /boot
├─ sda3 47.8G  PV → VG ocivolume (44.50g, VFree 0)
│               ├─ LV root 29.5G → /            17G used, 13G avail (57%)
│               └─ LV oled 15.0G → /var/oled   143M used — kdump target, DO NOT reclaim
└─ 165G        unallocated — no partition, no PV, invisible to LVM
```

`/var/oled` looks like 15GB wasted on 143MB of data. It is not: `/etc/kdump.conf`
points `path /var/oled/crash` at it, kdump is enabled and operational, and a
vmcore is sized against the 10GB of RAM. It is deliberately a separate volume so
a crash dump cannot fill `/`. Leave it alone.

*`/var/oled` 看起來是 15GB 只裝了 143MB。不是浪費:`/etc/kdump.conf` 的
`path /var/oled/crash` 指著它,kdump 是 enabled 且 operational,vmcore 的大小是
按 10GB RAM 抓的。它獨立成一個卷就是為了讓 crash dump 填不滿 `/`。不要動它。*

---

## Step 1 — reclaim ~2GB of dead cache (online, no partition change)

**Goal / 目標:** delete two dead caches — the only two reclaimable items of any
size on this node.

*刪掉兩個死掉的快取 —— 這台機器上唯二有份量、又能安全回收的東西。*

Check the orphan's path before deleting rather than trusting a glob: the point
of naming it explicitly is that `rm -rf` is the one command here with no safety
net of its own.

*刪之前先確認孤兒目錄的實際路徑,不要靠萬用字元:寫死路徑的理由是 `rm -rf` 是這裡
唯一沒有自帶安全網的指令。*

```bash
sudo ls -d /var/tmp/dnf-*                             # 確認確實只有那一個孤兒目錄
sudo du -sh /var/cache/dnf /var/tmp/dnf-*             # 確認大小符合預期（約 848M / 842M）
```

```bash
sudo dnf clean all                                    # dnf 中繼資料與套件快取,下次 dnf 會自己重抓
sudo rm -rf /var/tmp/dnf-opc-xvk7qa63                 # 某次 opc 跑 dnf 中斷留下的孤兒交易目錄；用上一步確認的實際路徑
df -h /                                               # 看回收結果
```

**Expect / 預期:** `/` goes from 17G used to about 15G, available 13G → 15G
(57% → 51%).

*預期:`/` 用量從 17G 降到約 15G,可用 13G → 15G(57% → 51%)。*

**問題 / Problem:** the journal looks like a third growth source — 214M and no
`SystemMaxUse` set, which would normally mean it grows to 10% of `/`.
**解法 / Fix:** it is not. `/var/log/journal` does not exist on this node, so
journald's default `Storage=auto` falls back to `/run/log/journal`, and `/run`
is a 2.2G tmpfs — the journal costs RAM, not disk. `SystemMaxUse` governs the
persistent path only; the volatile one is `RuntimeMaxUse`. Leave it alone.

*問題:journal 看起來像第三個成長來源 —— 214M 且沒設 `SystemMaxUse`,照理會長到
`/` 的 10%。解法:並沒有。本節點沒有 `/var/log/journal`,所以 journald 預設的
`Storage=auto` 會退回 `/run/log/journal`,而 `/run` 是 2.2G 的 tmpfs —— journal
吃的是記憶體不是磁碟。`SystemMaxUse` 只管持久化那條路徑,volatile 的對應設定是
`RuntimeMaxUse`。不用動它。*

Optional, from `docs/security-posture-audit.md`: this node runs no NFS, so
`rpcbind` is listening on `0.0.0.0:111` for nothing.

*選配,出自 `docs/security-posture-audit.md`:本節點沒有 NFS,`rpcbind` 白白監聽
`0.0.0.0:111`。*

```bash
sudo systemctl disable --now rpcbind.socket rpcbind   # 關掉未使用的 RPC 端口對應服務
sudo ss -lntup | grep 111 || echo "111 no longer listening"   # 確認不再監聽
```

Do **not** touch `iscsid` — OCI attaches block volumes over iSCSI.

***不要**動 `iscsid` —— OCI 的區塊卷是走 iSCSI 掛上來的。*

---

## Step 2 — hand the missing 165GB to LVM (online, no unmount, no reboot)

**Goal / 目標:** cut the free tail into a new `sda4`, make it a PV, and add it
to the volume group so there are finally extents to allocate.

*把磁碟尾端的未分配空間切成新的 `sda4`,做成 PV,加進 VG,才有 extent 可配。*

A new partition rather than `growpart`-ing `sda3`, for one reason: **it is
cleanly reversible.** `sda3`'s entry in the partition table is never rewritten,
and backing out is `vgreduce` + `pvremove` + `parted rm 4`, which returns the
disk exactly to its current state. Growing `sda3` is effectively one-way —
undoing it means shrinking a PV that the root filesystem sits on, which is
considerably more dangerous than the extension was. On a single-node cluster
with no HA, a retreat path is worth one extra partition and one extra PV.

*用新分割區而不是 `growpart` 延伸 `sda3`,理由只有一個:**可以乾淨地退回去**。
`sda3` 在分割表裡那筆完全不被改寫,退場就是 `vgreduce` + `pvremove` +
`parted rm 4`,磁碟回到跟現在一模一樣。延伸 `sda3` 實務上是單向的 —— 要退回去得
縮一個根檔案系統所在的 PV,比擴充危險得多。單節點又沒有 HA 的機器上,一條退路值得
多一個分割區和多一個 PV。*

The boot-volume backup from the precondition above must already exist and be
`AVAILABLE`.

*上面前置條件的 boot volume 備份必須已經做好,而且狀態是 `AVAILABLE`。*

```bash
sudo parted /dev/sda unit s print free                # 記下未分配區段的起訖磁區
sudo sfdisk --verify /dev/sda                         # 先驗分割表本身是否健康
```

**問題 / Problem:** `parted` prompts *"Not all of the space available to
/dev/sda appears to be used, you can fix the GPT to use all of the space"*, and
`sfdisk --verify` reports **`The backup GPT table is not on the end of the
device`** plus a PMBR size mismatch.
**解法 / Fix:** the OCI boot volume was expanded past the size the image's GPT
was written for, so the backup header still sits where the old disk ended. Move
it before creating anything, or the new partition has nowhere valid to live.
Back the table up to a file first — it restores in seconds, unlike the volume
backup.

*問題:`parted` 跳出「磁碟空間沒有用完,要修正 GPT 嗎」的提示,`sfdisk --verify` 報
**備份 GPT 表不在磁碟末端**加上 PMBR 大小不符。解法:OCI boot volume 被擴充到超過
映像檔當初寫 GPT 時的大小,備份標頭還停在舊磁碟的末端。要先把它搬過去,新分割區
才有合法的位置。動手前先把分割表備份成檔案 —— 它比卷備份快得多,幾秒就還原。*

```bash
sudo sgdisk --backup=/root/sda-gpt-$(date +%Y%m%d).bin /dev/sda   # 分割表備份成檔案
sudo sh -c 'ls -l /root/sda-gpt-*.bin'                # 確認檔案真的建立（glob 要在 root shell 裡展開）
sudo sgdisk -e /dev/sda                               # 把 GPT 備份標頭搬到磁碟末端
sudo sfdisk --verify /dev/sda                         # 應不再有 error
sudo partprobe /dev/sda                               # 讓核心重讀分割表
```

**Expect / 預期:** `sfdisk --verify` stops reporting errors and the `parted`
prompt is gone. Only the GPT headers were rewritten; no partition changed.
Restore path if needed: `sgdisk --load-backup=/root/sda-gpt-<date>.bin /dev/sda`.

*預期:`sfdisk --verify` 不再報錯,`parted` 的提示消失。只改寫了 GPT 標頭,沒有任何
分割區被更動。要還原:`sgdisk --load-backup=/root/sda-gpt-<日期>.bin /dev/sda`。*

Use the exact start sector from `print free`, not a rounded `50.0GB` — and check
it is a multiple of 2048 (1MiB) so the partition lands aligned.

*用 `print free` 印出的精確起始磁區,不要用四捨五入的 `50.0GB` —— 並確認它是 2048
(1MiB)的整數倍,分割區才會對齊。*

```bash
sudo parted -s -a optimal /dev/sda unit s mkpart lvm <起始磁區>s <結束磁區>s   # 精確到磁區
sudo parted -s /dev/sda set 4 lvm on                  # 標記為 LVM 用途
sudo partprobe /dev/sda                               # 讓核心看見 sda4
sudo parted /dev/sda align-check optimal 4            # 預期輸出「4 aligned」
lsblk /dev/sda                                        # 確認 sda4 出現
sudo parted /dev/sda unit s print                     # 對照 sda1–sda3 的起訖磁區沒有變動
```

**Expect / 預期:** `align-check` prints `4 aligned`; `lsblk` shows a new `sda4`
of **153.4 GiB** — the same space as the "165GB" quoted elsewhere in this
document, which is decimal GB. `sda1`–`sda3` keep the exact start and end
sectors they had; nothing is mounted or unmounted.

*預期:`align-check` 印出 `4 aligned`;`lsblk` 出現 **153.4 GiB** 的 `sda4` ——
跟本文件其他地方講的「165GB」是同一塊空間,那是十進位 GB。`sda1`–`sda3` 的起訖磁區
與動手前完全相同,沒有任何掛載或卸載。*

```bash
sudo pvcreate /dev/sda4                               # 把新分割區做成 PV
sudo vgextend ocivolume /dev/sda4                     # 加進池子
sudo pvs                                              # 現在應該有兩行：sda3(滿) 與 sda4(空)
sudo vgs ocivolume                                    # VFree 從 0 變成約 165g
```

**Expect / 預期:** `pvs` lists two PVs — `/dev/sda3` with `PFree 0` and
`/dev/sda4` with `PFree` around 153.4g; `vgs` shows `VSize` ~197.9g and `VFree`
~153.4g, `#PV 2`. `df` is
unchanged at this point, which is correct — no filesystem has been touched.

*預期:`pvs` 兩行 —— `/dev/sda3` 的 `PFree` 是 0,`/dev/sda4` 約 153.4g;`vgs` 的 `VSize` 約 197.9g、`VFree` 約 153.4g、`#PV 2`。此時 `df` 不會變,這是對的,還沒有動到任何檔案系統。*

**Rollback / 回退:** clean, as long as no LV has been given extents on `sda4`
yet — which is true until step 3 runs.

*只要還沒有 LV 在 `sda4` 上配到 extent(步驟 3 之前都成立),退場就是乾淨的。*

```bash
sudo vgreduce ocivolume /dev/sda4                     # 從池子移除
sudo pvremove /dev/sda4                               # 取消 PV 身分
sudo parted /dev/sda rm 4                             # 刪掉分割區 → 完全回到原點
```

---

## Step 3 — move the image stores onto their own volumes (k3s down ~10 min)

**Goal / 目標:** give `/var/lib/rancher` and `/var/lib/containers` a filesystem
each, so a runaway build or a failed prune fills that volume instead of `/`.

*讓 `/var/lib/rancher` 與 `/var/lib/containers` 各有自己的檔案系統,失控的 build
或壞掉的 prune 撐爆的是那顆卷,不是 `/`。*

`/var/lib/rancher` is 4.2G today: containerd images (3.9G), the k3s data dir
(235M), and the `local-path` PVC holding Postgres (84M). Moving it moves the
database too — which is the point, since PVC growth also stops threatening `/`.

*`/var/lib/rancher` 目前 4.2G:containerd image(3.9G)、k3s data(235M),以及
`local-path` 那顆裝 Postgres 的 PVC(84M)。搬它等於連資料庫一起搬 —— 這正是目的,
PVC 的成長也不再威脅 `/`。*

The trailing `/dev/sda4` on each `lvcreate` is not decoration: without it LVM
may satisfy the request from whichever PV it likes, straddling both. An LV with
extents on `sda3` would have to be `pvmove`d before `sda4` could ever be
removed, which throws away the retreat path step 2 was chosen for.

*每個 `lvcreate` 結尾的 `/dev/sda4` 不是裝飾:不指定的話 LVM 會自己挑 PV,可能跨
兩顆。只要有 extent 落在 `sda3`,將來要移除 `sda4` 就得先 `pvmove` —— 那等於丟掉
步驟 2 特地換來的退路。*

Size them small and leave the rest unallocated. XFS grows online but **cannot
shrink**, so under-allocating is reversible and over-allocating is not. 80G and
20G are roughly 19x and 35x current usage, which is ample headroom for stores
that a daily prune already bounds.

*配小一點,其餘留在池子裡。XFS 能線上長大但**不能縮小**,所以配少了可以補、配多了
回不來。80G 與 20G 約是目前用量的 19 倍與 35 倍,對已經有每日 prune 頂著的儲存區
綽綽有餘。*

```bash
sudo lvcreate -L 80G -n k3s    ocivolume /dev/sda4   # k3s 執行期與資料:image、kine db、PVC；只用 sda4
sudo lvcreate -L 20G -n podman ocivolume /dev/sda4   # podman build 快取；同樣釘在 sda4
sudo lvs -o lv_name,lv_size,devices ocivolume        # 確認兩個新 LV 的 Devices 欄都是 /dev/sda4
sudo mkfs.xfs /dev/ocivolume/k3s                     # 格式化（全新 LV,不需要也不該加 -f）
sudo mkfs.xfs /dev/ocivolume/podman
sudo blkid /dev/ocivolume/k3s /dev/ocivolume/podman  # 確認兩個都有 xfs 簽章
sudo vgs ocivolume                                   # 刻意留約 53G 沒配出去,之後要加給誰都行
```

**Expect / 預期:** two new LVs, both showing `/dev/sda4(...)` in the `Devices`
column — neither straddles `sda3`, so step 2's retreat path survives. `VFree`
around 53g. Leaving slack unallocated is the whole advantage of LVM — allocate
it when you know who needs it.

*預期:兩個新 LV,`Devices` 欄都是 `/dev/sda4(...)` —— 都沒跨到 `sda3`,步驟 2 的
退路保住了。`VFree` 約 53g。刻意留白正是 LVM 的好處 —— 等知道誰要用再配。*

Now stop the cluster. A plain `systemctl stop k3s` leaves containerd's overlay
mounts behind (27 of them today) and the copy would then miss data.

*接著停叢集。單純 `systemctl stop k3s` 會留下 containerd 的 overlay 掛載(現在有
27 個),那樣複製會漏資料。*

```bash
sudo /usr/local/bin/k3s-killall.sh                   # 停 k3s 並卸載它建立的所有 overlay/bind 掛載
sudo systemctl stop k3s                              # 確保 unit 不會自己被拉起來
mount | grep -c rancher                              # 預期 0
```

**Expect / 預期:** the count is `0`. If it is not, do not proceed — copying a
live overlay produces a corrupt image store.

*預期:數字是 `0`。不是 0 就不要往下做 —— 複製運行中的 overlay 會得到壞掉的 image 儲存區。*

```bash
sudo mkdir -p /mnt/new-k3s /mnt/new-podman                            # 暫時掛載點
sudo mount /dev/ocivolume/k3s    /mnt/new-k3s                         # 掛上新卷
sudo mount /dev/ocivolume/podman /mnt/new-podman
sudo rsync -aHAX --numeric-ids /var/lib/rancher/    /mnt/new-k3s/     # -X 保留 SELinux 標籤,少了它 k3s 起不來
sudo rsync -aHAX --numeric-ids /var/lib/containers/ /mnt/new-podman/
```

`-X` is not optional: without the extended attributes every file lands with the
wrong SELinux label and k3s fails to start in a way that reads like a
permissions bug. Verify with rsync itself rather than with sizes.

*`-X` 不是可選的:少了擴充屬性,每個檔案都會帶錯 SELinux 標籤,k3s 會以看起來像
權限問題的方式起不來。驗證要用 rsync 本身,不要用大小。*

```bash
sudo rsync -aHAXn --delete --itemize-changes /var/lib/rancher/    /mnt/new-k3s/      # 空輸出＝完全一致
sudo rsync -aHAXn --delete --itemize-changes /var/lib/containers/ /mnt/new-podman/
echo "rancher    舊 $(sudo find /var/lib/rancher -type f | wc -l)  新 $(sudo find /mnt/new-k3s -type f | wc -l)"
echo "containers 舊 $(sudo find /var/lib/containers -type f | wc -l)  新 $(sudo find /mnt/new-podman -type f | wc -l)"
```

**Expect / 預期:** both dry-runs print nothing (or only `.d..t......` lines,
which are directory timestamps and harmless), and the file counts match exactly.

*預期:兩個 dry-run 都沒有輸出(或只有 `.d..t......` 開頭的目錄時間戳,無害),
檔案數完全相同。*

**問題 / Problem:** `du -sb` shows the two sides differing by tens of KB.
**解法 / Fix:** not data loss — XFS directory inodes grow as entries are added
and never shrink, so a long-lived directory reports larger than a freshly
written copy of the same content. `du` is the wrong instrument here; the rsync
dry-run above is the authoritative one.

*問題:`du -sb` 顯示兩邊差幾十 KB。解法:不是資料遺失 —— XFS 的目錄 inode 會隨著
項目增加而膨脹且不會縮回,所以用了很久的目錄會比同樣內容的全新副本大。`du` 在這裡
是錯的量尺,上面的 rsync dry-run 才是權威。*

```bash
sudo umount /mnt/new-k3s /mnt/new-podman                     # 卸下暫時掛載點
sudo mv /var/lib/rancher    /var/lib/rancher.old             # 保留舊副本 —— 這一步不刪任何東西
sudo mv /var/lib/containers /var/lib/containers.old
sudo mkdir /var/lib/rancher /var/lib/containers              # 建空目錄當正式掛載點
sudo cp /etc/fstab /etc/fstab.bak                            # fstab 寫壞會導致開機失敗,先備份
```

```bash
printf '/dev/mapper/ocivolume-k3s     /var/lib/rancher     xfs  defaults  0 0\n/dev/mapper/ocivolume-podman  /var/lib/containers  xfs  defaults  0 0\n' | sudo tee -a /etc/fstab
sudo mount -a                                                # 依 fstab 掛載;語法有錯這裡就會擋下
sudo restorecon -R /var/lib/rancher /var/lib/containers      # 掛載點是新建目錄,重貼 SELinux 標籤
findmnt /var/lib/rancher /var/lib/containers                 # 確認兩個都掛上了
```

**Expect / 預期:** `findmnt` lists both on their new devices. `mount -a` must
exit 0 — a bad fstab line here means the next reboot drops to emergency mode.

*預期:`findmnt` 兩個都列出來,裝置是新的 LV。`mount -a` 必須 exit 0 —— fstab 寫
錯的話下次開機會掉進 emergency mode。*

```bash
sudo systemctl start k3s                                     # 起 k3s
kubectl get nodes                                            # 節點 Ready
kubectl get pods -A                                          # 全部 Running
sudo podman images                                           # podman 仍看得到原本的 image
df -h / /var/lib/rancher /var/lib/containers                 # / 的用量應下降約 4.8G
```

```bash
for u in https://lans-h.cc https://gelp.lans-h.cc https://transigen.lans-h.cc; do
  curl -s -o /dev/null -w "$u %{http_code}\n" --max-time 15 "$u"   # 從外部確認三個站台
done
```

**Expect / 預期:** `200`, `302` (gelp's auth redirect), `200`. Snoopy has no
ingress — check it in Discord.

*預期:`200`、`302`(gelp 的登入導向)、`200`。snoopy 沒有 ingress,去 Discord 看。*

**Rollback / 回退:** while the `.old` directories still exist, reverting is
mechanical.

*只要 `.old` 目錄還在,回退就是機械式的。*

```bash
sudo /usr/local/bin/k3s-killall.sh                           # 停叢集
sudo umount /var/lib/rancher /var/lib/containers             # 卸下新卷
sudo rmdir  /var/lib/rancher /var/lib/containers             # 移除空掛載點
sudo mv /var/lib/rancher.old    /var/lib/rancher             # 還原舊副本
sudo mv /var/lib/containers.old /var/lib/containers
sudo cp /etc/fstab.bak /etc/fstab                            # 還原 fstab
sudo systemctl start k3s
```

---

## Step 4 — delete the old copies (only after a few days of normal operation)

**Goal / 目標:** reclaim the 4.8GB the `.old` directories still hold on `/`.
Deliberately last: keep the rollback path until the new layout has survived a
deploy and a reboot.

*回收 `.old` 目錄還佔著 `/` 的 4.8GB。刻意放最後:等新佈局撐過一次部署和一次重開機,
再放棄回退路徑。*

This is the one command in the runbook with no safety net of its own — `mkfs`
and `pvcreate` refuse a wrong target, `rm -rf` does not. Check before, not after.

*這是整份 runbook 唯一沒有自帶安全網的指令 —— `mkfs` 和 `pvcreate` 打錯會拒絕,
`rm -rf` 不會。檢查要放在前面,不是後面。*

```bash
findmnt /var/lib/rancher /var/lib/containers                 # 兩個都必須掛在新 LV 上;沒輸出就停手
findmnt /var/lib/rancher.old || echo "ok: .old 是普通目錄,不是掛載點"   # 確認不會刪到掛載中的東西
sudo du -sh /var/lib/rancher.old /var/lib/containers.old     # 確認大小是預期的 4.2G / 572M
```

**Expect / 預期:** the first command lists both on `ocivolume-k3s` and
`ocivolume-podman`; the second prints the `ok:` line. If either is not true,
stop — the live data may still be in the `.old` paths.

*預期:第一行列出兩個都掛在新 LV 上;第二行印出 `ok:`。任何一項不符就停手 ——
正在用的資料可能還在 `.old` 裡。*

```bash
sudo rm -rf /var/lib/rancher.old /var/lib/containers.old     # 舊副本
sudo rmdir /mnt/new-k3s /mnt/new-podman                      # 暫時掛載點
df -h /                                                      # 最終結果
```

**Expect / 預期:** `/` settles around 11G used of 30G — 17G today, less the 4.8G
of stores that moved out and the 1.7G reclaimed in step 1. Comfortable without
ever growing the root volume, which is the point of doing it this way.

*預期:`/` 落在 30G 中用掉約 11G —— 今天是 17G,扣掉搬走的 4.8G 儲存區與步驟 1
回收的 1.7G。根本不用擴 root 就很寬裕,這就是選這條路的理由。*

---

## Alternative — just grow root (simpler, no isolation)

If the isolation is not wanted, step 2 plus two commands makes `/` about 190GB
and skips step 3 entirely. Fully online.

*不想要隔離的話,步驟 2 之後兩行就能把 `/` 撐到約 190GB,完全跳過步驟 3,全程線上。*

```bash
sudo lvextend -l +100%FREE /dev/ocivolume/root       # 把 VG 剩下的全配給 root
sudo xfs_growfs /                                    # 檔案系統跟著長;XFS 支援線上擴充
```

This raises the ceiling but keeps one failure domain: a runaway image store
still fills the same filesystem the OS, etcd and Postgres live on. It also
forfeits step 2's retreat path — once `root` holds extents on `sda4`, removing
that PV needs a `pvmove`, and XFS cannot shrink, so the filesystem side of it is
one-way regardless.

*這只是把天花板推高,失敗域仍然只有一個:失控的 image 儲存區照樣填滿作業系統、
etcd 和 Postgres 所在的那個檔案系統。它也放棄了步驟 2 換來的退路 —— 一旦 `root`
在 `sda4` 上配到 extent,要移除那顆 PV 就得 `pvmove`;而且 XFS 不能縮,檔案系統這
一側無論如何都是單向的。*

---

## Related

- `node/prune-images.sh` — the daily prune that keeps the image stores bounded
  in the first place; this runbook is the second line of defence, not a
  replacement for it.
- `docs/security-posture-audit.md` — where the `rpcbind` finding comes from.

*`node/prune-images.sh` 是讓 image 儲存區有上限的第一道防線,本 runbook 是第二道,
不是它的替代品。`rpcbind` 那條出自 `docs/security-posture-audit.md`。*
