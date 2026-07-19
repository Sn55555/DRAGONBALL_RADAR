# 胶囊雷达固件 OTA 发布与安全合同

更新时间：2026-07-14

## 目标与边界

当前 OTA 链路用于 `esp32-s3-touch-amoled-1.75c`，职责按以下边界拆分：

1. 发布机从 PlatformIO 的 `firmware.bin` 生成带 ECDSA P-256 签名的发布目录。
2. Relay 只公开已通过公钥、大小和 SHA-256 校验的当前发布。
3. 已登录 App 获取 manifest、验证版本和签名，并把同源相对下载地址解析成绝对 HTTP(S) URL；Release 环境强制 HTTPS。
4. App 通过已绑定设备的 BLE 控制通道发起升级；ESP 使用自己的 `device_token` 下载固件。
5. ESP 流式写入非活动 OTA 分区，完成完整性、版本和防降级检查后切换启动分区；启动失败必须回滚。

私钥不得进入 Relay、App、ESP、Git 或发布目录。Relay 只需要公钥；App/ESP 使用内置的受信公钥验证发布身份。OTA 签名公钥与 HTTPS 根 CA 是两类独立信任：前者认证发布内容，后者认证下载服务器。

## 发布身份

当前固定合同：

| 字段 | 值或约束 |
| --- | --- |
| `schema` | `1` |
| `product` | `dragon-radar` |
| `hardware` | `esp32-s3-touch-amoled-1.75c` |
| `version` | 严格数字 `x.y.z`，每段 `0...4294967295`；不接受 prerelease/build metadata |
| `build` | `1...4294967295`、单调递增的整数 |
| `minimum_version` | 允许安装该发布的最低当前固件，格式与数值范围同 `version` |
| `security_counter` | `1...4294967295`、不可回退的安全计数器 |
| `size` | `firmware.bin` 字节数 |
| `sha256` | 小写 64 位十六进制 |
| `signature_algorithm` | `ecdsa-p256-sha256` |
| `key_id` | `local-2026-01` |

`version` 面向用户，`build` 用于同一版本内排序，`security_counter` 是设备端防降级边界。目标 `version` 不得低于 `minimum_version`。紧急回滚不能降低 `security_counter`；应以更高的 counter 发布包含旧功能代码的新 build。

## 签名规范

签名输入使用 UTF-8、无 BOM、LF 分隔、末尾没有 LF。字段顺序不可改变：

```text
dragon-radar-ota-v1
schema=<int>
product=<string>
hardware=<string>
version=<numeric x.y.z>
build=<int>
minimum_version=<numeric x.y.z>
security_counter=<int>
size=<int>
sha256=<lowercase hex>
```

算法是 ECDSA P-256 + SHA-256。manifest 中的 `signature` 是 DER 签名的标准 Base64；`signature_algorithm`、`key_id`、`artifact`、`artifact_url`、`created_at` 不进入签名输入。

`artifact_url` 未签名是有意设计：固件字节由已签名的 `size + sha256` 绑定，但下载 URL 仍可能把 device Bearer 外带。App 只允许把 Relay 返回的根相对路径解析到 manifest 请求的同一 scheme、host 和 effective port；ESP 也必须独立以持久化的 `http_api_url` 做相同源校验，并限制 path 为 `/v1/firmware/artifacts/<safe-basename>`。任一端校验失败都禁止发请求。

## 签名密钥准备

日常发布必须使用与 App/ESP 已内置公钥匹配的现有私钥，不要在发版时重新生成。可以把 supplied 公钥归一为 DER SPKI 并核对指纹：

```sh
openssl pkey \
  -pubin \
  -in .secrets/ota-signing-public.pem \
  -pubout \
  -outform DER | openssl dgst -sha256
```

以下生成命令仅用于产品首次建立信任或受控轮换。生成新 key 后，必须先更新 App、ESP 内置公钥和 build sidecar 指纹，再发布使用新私钥签名的包：

```sh
mkdir -p .secrets
chmod 700 .secrets
openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -pkeyopt ec_param_enc:named_curve \
  -out .secrets/ota-signing-private.pem
openssl pkey \
  -in .secrets/ota-signing-private.pem \
  -pubout \
  -out .secrets/ota-signing-public.pem
chmod 600 .secrets/ota-signing-private.pem
```

`.secrets/` 已被 Git 忽略。复制给 Relay 的只能是 `ota-signing-public.pem`。

当前实现只接受 `key_id=local-2026-01`。build sidecar 记录该 key ID 及内置公钥的 DER SPKI SHA-256；打包工具计算 supplied 公钥的同类指纹并要求精确一致。即使另一组 P-256 私钥/公钥彼此匹配，也不能冒用同一个 key ID 发版。轮换密钥时必须先让 App、ESP 和 Relay 同时信任新 key，再切换签名 key；不能只替换服务端公钥。

## 构建、打包和离线验证

```sh
export DRAGON_RADAR_FIRMWARE_VERSION=1.2.0
export DRAGON_RADAR_FIRMWARE_BUILD=120
export DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER=12
export DRAGON_RADAR_OTA_ROOT_CA_PEM_B64="$(openssl base64 -A -in /path/to/relay-root-ca.pem)"
export PAIRING_HMAC_KEY='<production pairing key>'
export RADAR_RELEASE=1
unset DRAGON_RADAR_OTA_ALLOW_HTTP
tools/build_radar.sh field

python3 tools/package_ota_release.py \
  --version "$DRAGON_RADAR_FIRMWARE_VERSION" \
  --build "$DRAGON_RADAR_FIRMWARE_BUILD" \
  --minimum-version 1.0.0 \
  --security-counter "$DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER" \
  --force

python3 tools/verify_ota_release.py output/ota-current
```

`tools/build_radar.sh` 会把同一组环境变量写成固件编译宏；这些发布 identity/CA/HTTP override 会触发 `radar-custom` 环境，并在 binary 同目录原子生成 `firmware-metadata.json`。sidecar 固定包含 `schema/product/hardware/version/build/security_counter/artifact/size/sha256/environment/release_build`，以及 `ota_key_id/ota_public_key_sha256/ota_allow_http/ota_root_ca_configured/ota_root_ca_sha256`；无 CA 时后者必须是空字符串而不是 `null`。`release_build=true` 只由通过生产 pairing-key preflight 的 `RADAR_RELEASE=1` build 产生。package 默认读取 `.pio/build/radar-custom/firmware.bin` 及其 sidecar，默认输出是 `output/ota-current/`。输出包含：

- `manifest.json`：Relay 返回给 App 的发布清单。
- `<sha256>.bin`：ESP 应用镜像；完整 SHA-256 是 basename，版本/build 仍在签名 manifest 中。只用摘要命名既让 URL 对应的字节不可变，也给单次 BLE 控制写入保留足够长度余量。
- `canonical.txt`：实际签名字节，末尾没有换行。
- `signature.der`：便于离线审计的 DER 签名。
- `build-metadata.json`：package 从已校验 sidecar 中复制的无秘密 allowlist，用于 Relay stable/dev 发布策略门禁。
- `retained/<artifact-basename>/...`：前几版完整、已验签的发布快照，仅用于已经拿到旧 URL 的设备继续下载或 Range 续传；不会改变 stable current manifest。

打包工具强制读取 sidecar，并要求其中的 product、hardware、version、build、security counter 与发布参数完全相同，size/SHA-256 与当前 binary 完全相同，supplied 公钥与 binary 内置公钥指纹相同；缺失或不匹配直接失败。因此不能把编译为 `1.0.0/build1/security1` 的 binary 人工标成另一个版本，也不能拿另一把自洽的 P-256 key 冒充当前 key ID。它还会拒绝非 ESP 镜像、错误曲线、私钥/公钥不匹配、非纯数字 `x.y.z` 版本、非法 hardware、超出 OTA 槽位以及覆盖已有目录但未传 `--force` 的操作。默认大小上限是 8 MiB，可通过 `DRAGON_RADAR_OTA_SLOT_SIZE` 或 `--max-size` 收紧；这个值必须不大于目标设备最小 OTA app 分区。

`--force` 晋升不是删除旧 artifact 后再逐文件覆盖：package 会先离线验证当前版本和既有 retained 快照，用新目录完整构建 current，再原子替换。新发布必须高于所有已保留发布的全局 `build`，`version` 与 `security_counter` 都不得倒退；同一固件摘要的幂等重打包除外。默认保留最近 3 个旧版本，可用 `--retain-releases N` 或 `DRAGON_RADAR_OTA_RETAIN_RELEASES=N` 调整。保留按单调 `build` 排序；超出数量的最旧快照才会在下一次原子晋升时清理。若旧快照验签/metadata 门禁失败、目录名与 artifact 不一致、含 symlink，或同一不可变名称对应不同摘要，晋升会失败且原 current 保持不变。生产保留数必须覆盖最长允许升级窗口和最慢设备的一次完整下载时间；不要设为 `0`，除非已经确认没有在途升级。

### 下载传输门禁

稳定发布必须满足：`release_build=true`、`ota_root_ca_configured=true`、根 CA DER certificate 指纹为小写 SHA-256、`ota_allow_http=false`。因此默认开发 pairing key 或未执行 `RADAR_RELEASE=1` preflight 的 binary 不能被包装成 stable OTA。应嵌入签发 Relay 服务器证书的稳定 CA，而不是短期 leaf 证书。ESP 使用该 CA 调用 `setCACert`；禁止使用 `setInsecure`。

本地真机调试 plain HTTP 时，使用与生产包隔离的开发 build：

```sh
export DRAGON_RADAR_FIRMWARE_VERSION=1.2.0
export DRAGON_RADAR_FIRMWARE_BUILD=120
export DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER=12
export DRAGON_RADAR_OTA_ALLOW_HTTP=1
unset RADAR_RELEASE
unset DRAGON_RADAR_OTA_ROOT_CA_PEM_B64
tools/build_radar.sh field

python3 tools/package_ota_release.py \
  --version "$DRAGON_RADAR_FIRMWARE_VERSION" \
  --build "$DRAGON_RADAR_FIRMWARE_BUILD" \
  --minimum-version 1.0.0 \
  --security-counter "$DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER" \
  --allow-development-http \
  --force
```

两种传输能力都未编译时，package 判定该 binary 不具备 OTA 可用性并拒绝。即使提供 `--allow-development-http`，它也只放行 sidecar 明确记录 `release_build=false` 的开发 HTTP build；稳定发版流程不得使用这个参数。

`build-metadata.json` 的 product/hardware/version/build/counter/size/SHA/key identity 会被 Relay 与已签 manifest、实际 artifact 和配置公钥逐项交叉验证。`release_build/CA/HTTP/environment` policy 本身不在主 manifest canonical signature 内，因此发布目录仍是受信部署边界：目录必须限制写权限，通过离线 verifier 后原子晋升，不能允许 Web 进程或普通用户修改 metadata。

## Relay 配置

Relay 使用以下环境变量：

```sh
export DRAGON_RADAR_FIRMWARE_RELEASE_DIR=/srv/dragon-radar/releases/current
export DRAGON_RADAR_OTA_PUBLIC_KEY=/etc/dragon-radar/ota-signing-public.pem
export DRAGON_RADAR_OTA_KEY_ID=local-2026-01
unset DRAGON_RADAR_ALLOW_DEVELOPMENT_OTA
```

生产发布应在现有 current 目录上运行 `package_ota_release.py --force`（或在 staging 中携带完整 `retained/` 后再晋升），运行 `verify_ota_release.py`，再把整个目录原子切换为 current。不要只上传新 manifest/artifact，也不要新建一个不含旧 `retained/` 的空目录直接替换；这会让已经获得旧 URL 的 ESP 在断线 Range 重试时收到 404。不要逐文件覆盖正在提供服务的目录。

本地需要服务 `--allow-development-http` 产物时，Relay 还必须显式设置 `DRAGON_RADAR_ALLOW_DEVELOPMENT_OTA=1`。生产环境禁止设置该开关；否则 dev binary 会在安装后缺少生产 CA 或生产 pairing 身份。

Relay 会对 current 和每个被请求的 retained 快照分别执行同一套验证；retained 不是绕过 stable 门禁的静态文件目录。Relay 会在 manifest、artifact 或公钥的 stat 指纹变化时重新执行以下检查：

- manifest 类型、字段、硬件、版本和 canonical payload；
- artifact 必须是发布目录中的安全 basename，不能目录穿越；
- artifact 实际大小和 SHA-256；
- P-256 公钥、`key_id` 和 ECDSA 签名。
- `build-metadata.json` 与 manifest/artifact/公钥的全字段绑定；
- stable policy 必须为 `release_build=true`、CA configured、HTTP disabled、`environment=field`。

manifest、build metadata、artifact 和公钥的 inode/mtime/size 都进入 Relay cache fingerprint，任一变化会重新校验。校验失败时不公开半成品，`/healthz.firmware.available` 为 `false`。成功时健康检查只返回 product、hardware、version、build、security counter 和 development 标记，不暴露本机路径或内部错误。

## HTTP API

### Manifest

```http
GET /v1/firmware/manifest?hardware=esp32-s3-touch-amoled-1.75c&channel=stable
Authorization: Bearer <user access token>
```

当前只公开 `stable` channel，且永远只返回 current manifest。成功返回签名字段和根相对 `artifact_url`。App 必须以 HTTP API base URL 解析为绝对 URL，并检查 scheme、host、port 同源。未登录返回 `401 unauthorized`；hardware 或 channel 不匹配返回 `404 firmware_release_not_found`；当前目录无有效发布返回 `503 firmware_release_unavailable`。旧 manifest 不可枚举，也不会再次推荐给新检查更新的设备。

### Artifact

```http
GET /v1/firmware/artifacts/<safe-basename>
Authorization: Bearer <device token>
Range: bytes=<start>-<end>
```

Artifact 的 `GET`、`HEAD` 和 `Range` 使用相同鉴权：ESP 使用当前 `device_token`，App/测试工具也可以使用 user access token。token 不得放在 URL、manifest 或日志里。已解绑设备返回 `403 device_revoked`。

Artifact URL 是包含完整 SHA-256 的不可变地址。Relay 先匹配 current；若名称不同，再只在 `retained/<同名 basename>/` 中查找，并对旧 manifest、签名、artifact、build metadata、公钥与 stable/dev policy 重新验证。安全 basename 之外的路径、未知名称和已清理版本返回 `404`；旧快照损坏或门禁不再成立时拒绝提供，不会回退到同版本的另一份字节。由此，设备在 current 晋升后继续使用原 URL 做 Range 请求时，ETag、总长度和字节内容保持一致。

Relay 支持单段 byte range：

- 完整响应：`200`、`Accept-Ranges: bytes`、SHA-256 ETag。
- 有效范围：`206` 和 `Content-Range`。
- 无效或越界范围：`416` 和 `Content-Range: bytes */<size>`。
- `HEAD` 返回与 `GET` 一致的鉴权、长度和缓存头，但没有 body。

ESP 的首次请求必须得到完整响应 `200`。仅在同一次 Update/SHA 会话中的瞬时断线重试，ESP 才发送 Range；续传必须得到 `206`，且 `Content-Range` 起点与本地已写偏移精确一致，否则立即中止。续传次数受限，完成后仍对整个镜像重新计算 SHA-256；跨重启不复用未完成会话。

## App 与 ESP 状态机

App 在以下条件全部满足后才允许用户触发升级：

- 用户已登录，设备已绑定且 BLE 可连接；
- product/hardware 精确匹配；
- manifest canonical payload 和 P-256 签名有效；
- 当前版本满足 `minimum_version`，目标 build 更新；
- artifact URL 能解析成与 HTTP API 同源的绝对 HTTP(S) URL；Release 环境必须是 HTTPS。

App 的 BLE `server_config` 必须同时下发并让 ESP 持久化 `http_api_url`。存量 NVS 若只有 Relay WSS URL、没有 HTTP API origin，ESP 必须拒绝 OTA；App 需要先重新同步设备配置，不能从 artifact URL 反推或自动信任 origin。

App 不转发固件二进制。BLE OTA 控制特征 `107` 发送 compact JSON：

```json
{"v":1,"a":"start","m":{"s":1,"p":"dragon-radar","h":"esp32-s3-touch-amoled-1.75c","v":"1.2.0","b":120,"min":"1.0.0","c":12,"z":3070336,"sha":"<sha256>","alg":"ecdsa-p256-sha256","kid":"local-2026-01","sig":"<base64 DER>","url":"https://same-origin/...bin"}}
```

同一特征还承载 status/cancel；状态特征 `108` 通过 read/notify 返回 `idle/checking/downloading/verifying/pending/rebooting/success/error/rollback`、进度、已下载字节、目标版本和错误码。App 应持久化升级事务，回到前台后重读状态。重启后版本/build 匹配只表示等待健康确认；只有 BLE `108 stage=success`（ESP 已完成健康检查并 mark-valid）才能判定升级成功。

BLE 连接本身不等于所有者授权。ESP 在每次 central 连接时用 `esp_random()` 轮换 128-bit challenge，并把当前连接的 `owner_auth` 清零。已绑定 App 从服务器持有的 `device_token` 生成 `HMAC-SHA256(device_token, "v1|<challenge>|t|<nonce>")`，通过既有 `pairing_response` 特征 `102` 写入 `dra-auth:v1:t:<nonce>:<proof>`；ESP 常量时间验签成功后，才允许本连接写 `wifi_config`、`local_location`、`server_config` 和 OTA `107`。断连立即撤销授权，proof 不能跨连接重放，token/proof 不进入状态 JSON 或日志。首次未绑定设备仍使用 `dra-pair:v2`；已 paired 但尚未写入 `device_token` 的半配置设备，可让已登录 App 针对本次新 challenge 再取得 v2 response 来恢复当前会话。此层防的是附近但不知道 owner credential 的 central，不替代 BLE 链路加密，也不覆盖已泄露 device token 或已攻陷手机。

ESP 收到升级控制后，必须再次检查目标硬件、大小、SHA-256、签名和 `security_counter`。在附加 `Authorization` 前，ESP 还必须把 absolute artifact URL 与持久化 `http_api_url` 比较 scheme、规范化 host、effective port，并检查固定 artifact path；缺 origin、跨域、userinfo、fragment、query、错误 path 或重定向都拒绝。下载写入非活动分区，不覆盖正在运行的固件。断电或网络失败保留当前可启动分区；新固件只有在启动自检成功后才确认，否则由 bootloader 回滚。

用户可见状态至少区分：检查中、可升级、下载中、写入中、校验中、等待重启、升级成功、失败可重试，以及签名无效/空间不足/版本过旧/设备已解绑等不可重试原因。日志和诊断包不得包含 user token、device token 或完整 Wi-Fi 凭据。

## 所有者凭证恢复与重新绑定

App 发现 ESP 要求所有者会话但当前凭证被拒绝时，必须先遍历当前登录账号下的有效雷达凭证；成功后更新本地活动设备，不能永久停在“正在确认”。若账号下全部凭证均失败，App 要明确显示凭证不匹配，并引导用户在雷达本机完成物理恢复，不能提供纯 BLE 远程解绑。

雷达本机恢复步骤：短按侧键打开系统菜单，滑动到 `RST`，点按进入后在圆屏中央持续按住 4 秒。ESP 随后清除 `radarNet` 中的所有者、Wi-Fi、房间、Relay/HTTP API 配置和 NimBLE bond，重启并回到未绑定状态。取消长按、离开页面或超时均不得清除配置；OTA 写入期间必须拒绝恢复操作。

绑定是一个“服务器临时凭证 → ESP 确认 → App 提交”的事务。App 在 ESP 确认前不得把服务器刚创建的设备设为活动设备；写入失败或确认超时必须调用设备撤销接口回滚临时凭证。否则服务器会留下 ESP 从未接受过的 token，下一次更新就会出现 App 与 ESP 所有者凭证分叉。

## 首次引导与回滚

旧出厂固件若没有双 OTA app 槽位和新的 OTA 控制合同，无法仅靠 OTA 把自己变成 OTA 设备。每块存量板需要一次 USB factory bootstrap：刷入新 partition table、bootloader 和 OTA-capable app，并验证 `otadata + ota_0 + ota_1` 后，后续才走 App OTA。

bootstrap 必须使用与后续 stable release 相同的固件 identity、生产 pairing key 和 Relay 根 CA：

```sh
export DRAGON_RADAR_FIRMWARE_VERSION=1.0.0
export DRAGON_RADAR_FIRMWARE_BUILD=1
export DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER=1
export DRAGON_RADAR_OTA_ROOT_CA_PEM_B64="$(openssl base64 -A -in /path/to/relay-root-ca.pem)"
export PAIRING_HMAC_KEY='<production pairing key>'
export RADAR_RELEASE=1
unset DRAGON_RADAR_OTA_ALLOW_HTTP

RADAR_PORT=/dev/cu.usbmodem101 tools/build_radar.sh field upload
```

PlatformIO upload 会分段写入 `0x0000` bootloader、`0x8000` partition table、`0x19000` `boot_app0.bin`（对应 `otadata`）和 `0x20000` `ota_0` app。项目 board manifest 必须把 `upload.arduino.boot_app0` 固定为 `0x19000`；若退回工具链默认的 `0xe000`，会覆盖 `0x9000..0x18fff` 的 NVS。`tools/verify_ota_contract.py` 会强制检查上传偏移与 partition table 一致。普通 upload 不执行整片擦除，因此会保留现有 NVS；只有显式 erase-flash 才会清除 Wi-Fi、绑定和设备凭证。普通默认 `field`（无 CA 且 HTTP disabled）不是可用的 OTA bootstrap，即使屏幕和房间功能能启动也不能作为出厂基线。

改变 partition table 属于 factory 操作，不应作为普通 OTA 包发布。执行前保留设备绑定/配置的迁移策略；必要时清空 flash 后重新绑定。

## 验证门禁

```sh
tools/verify_project.sh quick
```

`quick` 会生成两组临时 P-256 密钥和 ESP 形状的测试镜像，执行连续两版打包与离线验签，确认 canonical bytes、默认 hardware、纯数字版本/security counter 合同、binary-sidecar 绑定、内置信任 key 绑定、production pairing/稳定 HTTPS/开发 HTTP 门禁、带摘要的不可变 artifact 命名、旧版本 retained 保留、原子替换失败恢复、篡改 artifact 和篡改签名的拒绝路径，再启动 Relay 覆盖：

- manifest user token 鉴权与错误 hardware；
- artifact user/device token 鉴权；
- 已吊销 device token；
- current 与 retained 旧 URL 的完整下载、HEAD、206 Range、416 越界；
- 返回字节的 size 和 SHA-256。

固件合同静态门禁还必须证明：`server_config` 持久化 `http_api_url`；ESP 在发送 device Bearer 前执行独立同源/effective-port/固定 artifact-path 校验；旧 NVS 缺 origin 时明确拒绝，而不是回退到只信 App。

同一静态门禁还检查两个 OTA app 分区各不小于 8 MiB、Arduino `verifyRollbackLater()` 延后确认、健康后 `esp_ota_mark_app_valid_cancel_rollback()`、失败时 `esp_ota_mark_app_invalid_rollback_and_reboot()`，以及 HTTPS 建连前完成可信时钟同步。生产 TLS 不允许用 `setInsecure` 绕过证书或时钟校验。

发布前还应运行 `tools/verify_project.sh full`，并完成真机断网续传、下载中断电、写入中断电、新固件自检失败回滚、重复安装和降级攻击测试。
