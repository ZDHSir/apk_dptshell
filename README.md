# goshell

把 [dpt](https://github.com/luoyesiqiu/dpt) 2.21.0 打包成**不依赖 Java 环境**的原生命令行工具，便于分发给同事或在 CI 里使用。

- 单文件可执行程序（Linux x64 实测 49MB），目标机器不需要安装 JRE
- 命令、参数、行为与 `java -jar dpt.jar` 一致；APK 路径已完整实测，AAB 沿用同一套逻辑但尚未实测
- 内嵌 `shell-files/`（壳 dex、各 ABI 的 so、build-key），首次运行时解压到用户缓存目录
- 支持 APK 加壳、自定义签名、`-vs` 运行时验签、`-r` 规则文件、`-e` 排除 ABI 等全部原有参数

> 实现方式：GraalVM `native-image` 直接把 `dpt.jar` 编译成原生二进制，不修改 dpt 的 Java 源码。只有两处通过 native-image substitution 适配：
> - `FileUtils.getExecutablePath()`：原生镜像没有 jar 路径，改为返回本次运行专用的运行时目录
> - `Dpt.getVersion()`：原生镜像里 `Package.getImplementationVersion()` 为 null，改为读取内嵌版本号
>
> 另外，dpt 每次运行都会改写 `shell-files/dex/junkcode.dex`，所以工具会为每个进程复制一份独立的 `shell-files`，运行结束自动删除，避免并发运行互相干扰或污染 `GOSHELL_HOME`。

## 目录结构

```
libs/dpt/                     # 上游 dpt 依赖（升级时只换这个目录）
  dpt.jar                     #   上游 dpt 2.21.0
  shell-files/                #   壳资产，必须与 dpt.jar 的 build-key 匹配
  dpt-exclude-classes-template.rules
  dpt-protect-config-template.json
  VERSION
native/src/                   # native-image substitution + 运行时解压/复制逻辑
native/config/                # 由 scripts/trace-config.sh 生成的反射/资源/JCA 配置
native/config-extra/          # 手工补充的反射配置（fastjson2 setter 反射调用）
scripts/build-native.sh       # 构建当前平台的原生二进制
scripts/trace-config.sh       # 重新生成 native-image 配置
scripts/package-local.sh      # 构建并打包当前平台
scripts/package-all.sh        # 触发 GitHub Actions 构建四平台并下载产物
testapp/fixture.apk           # 1.4KB 的最小 APK，用于构建后冒烟测试
USAGE.md                      # 给最终用户的使用说明（打包时一并附带）
.github/workflows/release.yml # 四平台构建（native-image 不支持交叉编译）
```

构建产物为 `build/native/goshell`（Windows 为 `goshell.exe`）。

## 构建

### 依赖

- GraalVM 21（带 `native-image`），Community 或 Oracle 版均可
- 无需额外安装 `unzip`：脚本使用 JDK 自带的 `jar` / `jmod` 工具

```bash
# 方式一：sdkman
sdk install java 21.0.2-graalce

# 方式二：手动解压 GraalVM 后指定
export GRAALVM_HOME=/path/to/graalvm-21
```

### 构建

```bash
scripts/build-native.sh
# 产物：build/native/goshell
```

脚本会：

1. 把 `libs/dpt/shell-files/` 复制到构建 classpath，生成本次构建的资源清单和内容哈希
2. 从 GraalVM 的 jmod（或旧版 `svm.jar`）中提取 `@TargetClass` / `@Substitute` 注解，编译 `native/src/`
3. 通过 `java -jar libs/dpt/dpt.jar -v` 读取版本号
4. 调用 `native-image`，把 `assets/`、`shell-files/`、`META-INF/MANIFEST.MF` 都嵌入二进制

**native-image 不支持交叉编译**，Windows/macOS 的二进制必须在对应系统上构建。仓库里的 GitHub Actions 工作流用矩阵分别构建四个平台，推送 `v*` tag 或手动触发即可下载产物。

GitHub Actions 使用 **GraalVM Community** 构建，产物可自由分发；如果本地用 Oracle GraalVM 构建，请自行确认其许可条款。两种发行版生成的二进制行为一致。

Linux 产物依赖 glibc ≥ 2.34（本次在 Debian 13 上构建，只额外依赖 `libz`）；更老的发行版请在目标系统或容器中构建。

### 打包

```bash
# 当前平台：构建 + 打包到 dist/goshell-<os>-<arch>.tar.gz
scripts/package-local.sh

# 全平台：推送当前分支，触发 GitHub Actions 的四平台矩阵，下载到 dist/
scripts/package-all.sh
```

`package-all.sh` 依赖 `gh`（GitHub CLI）并已 `gh auth login`，同时要求工作区干净、已配置 `origin` 远程。native-image 本身不支持交叉编译，所以全平台构建只能走 CI。

每个平台的包内含：`goshell`（Windows 为 `goshell.exe`）、规则模板、配置模板、`README.md`、`USAGE.md`，以及对应的 `.sha256`。

### 更新 dpt 版本

所有上游文件都在 `libs/dpt/`，升级步骤见 [libs/dpt/README.md](libs/dpt/README.md)。核心三步：

```bash
# 1. 同时替换 libs/dpt/dpt.jar 和 libs/dpt/shell-files/（build-key 必须匹配）
# 2. 重新生成反射/资源/JCA 元数据
GRAALVM_HOME=/path/to/graalvm-21 scripts/trace-config.sh testapp/fixture.apk
# 3. 重新构建
GRAALVM_HOME=/path/to/graalvm-21 scripts/build-native.sh
```

## 使用

参数与 dpt 完全一致，把 `java -jar dpt.jar` 换成 `goshell` 即可。下面的示例中 `./goshell` 指构建产物 `build/native/goshell`（CI 下载后可以自行重命名）。

```bash
# 查看帮助
./goshell

# 最简：使用内置 debug keystore
./goshell -f app.apk -o out/app

# 发布包：指定签名、排除 x86
./goshell -f app.apk \
  -c app-protect.json \
  -e x86,x86_64 \
  -o out/app

# AAB（沿用 dpt 原始逻辑；本仓库尚未实测，建议先用小包验证）
./goshell -f app.aab -c app-protect.json -o out/aab
```

输出文件名为 `<原文件名>_signed.apk`。

### 两个 app 批量加壳

工具一次处理一个包，两个 app 跑两遍即可。每个 app 用自己的签名配置：

```bash
./goshell -f appA.apk -c appA-protect.json -o out/appA
./goshell -f appB.apk -c appB-protect.json -o out/appB
```

配置模板：

```json
{
  "shellPkgName": "<random>",
  "signature": {
    "keystore": "/path/to/appA.jks",
    "alias": "key0",
    "storepass": "your-store-password",
    "keypass": "your-key-password"
  }
}
```

> `shellPkgName` 保持 `<random>`，工具会按各自 app 的包名生成 `<包名>.shell`，两个 app 天然不冲突。
> keystore 路径写错时 dpt 会静默回退到内置 debug keystore，发布前请确认日志里是 `Use custom key store`。

### 关于 `-r` 规则文件（可选）

`-r/--rules-file` 指向一个"**不参与加壳**的类"列表。被匹配到的类会跳过 dpt 的 dex 改写（字符串加密、反射 clinit 注入等），用于兼容那些加固后会异常的三方 SDK。

- **不传 `-r`**：使用 dpt 内置的 483 条默认规则（Android 框架、Google/广告/推送/SDK 等）
- **传 `-r`**：整个列表会被文件内容**替换**，不是合并。所以自定义文件要以完整默认列表为基础追加，不能只写自己那几行
- [libs/dpt/dpt-exclude-classes-template.rules](libs/dpt/dpt-exclude-classes-template.rules) 是上游模板（480 条），比内置列表少 3 条：`Lcom/huawei/hms/.*`、`Lcom/tencent/matrix/.*`、`Lcom/tencent/mmkv/.*`。如果直接拿它当自定义文件，记得补上这 3 行
- 格式：一行一个 Java 类描述符正则，例如 `Lcom/foo/.*`；不支持注释，不要留空行
- 不要把自家业务包排除掉，否则那部分代码不会加壳

没有三方 SDK 兼容问题时，**不传 `-r` 是最稳的**。

### 运行时资源位置

首次运行会把内嵌的 `shell-files/` 解压到：

| 平台 | 缓存根目录 |
|---|---|
| Linux | `$XDG_CACHE_HOME/goshell` 或 `~/.cache/goshell` |
| macOS | `~/Library/Caches/goshell` |
| Windows | `%LOCALAPPDATA%\goshell` |

根目录下：

- `runtime-<version>-<build-id>/shell-files/`：只读的原始副本，不会在运行中被修改。`build-id` 是内嵌 shell-files 的内容哈希，重新构建后不会误用旧缓存
- `run-<random>/shell-files/`：当前进程的私有副本，dpt 会改写其中的 `junkcode.dex`；进程退出时自动删除

以下两种方式可以覆盖壳资产来源：

1. 设置 `GOSHELL_HOME` 环境变量，指向包含 `shell-files/` 的目录
2. 把 `shell-files/` 放在可执行文件旁边（优先于缓存）

```bash
GOSHELL_HOME=/opt/goshell ./goshell -f app.apk -o out/app
```

> 只读的 `GOSHELL_HOME` 也可以使用：工具会先复制到可写的 `run-*` 目录再处理。

## 验证

```bash
./goshell -v
apksigner verify --print-certs out/app/app_signed.apk
```

> dpt 上游的 `main` 会捕获异常后仍然以退出码 0 结束。脚本里除了看退出码，请同时检查输出 APK 是否存在，或像 CI 的 smoke test 一样断言输出文件。

已实测（Linux x64，GraalVM 21.0.12）：

- 内置 debug keystore 加壳
- 自定义 keystore + `-vs`（证书 SHA-256 与日志一致）
- 两个 app 并发加壳（各自生成 `<包名>.shell`）
- 只读 `GOSHELL_HOME`、可执行文件旁的 `shell-files/`
- `-r` 规则文件、`-e` 排除 ABI
- `apksigner verify` 通过

## 许可

`dpt.jar`、`shell-files/` 及其打包的第三方库（smali/dexlib2、apksig、fastjson2、zip4j 等）遵循各自的开源许可，本仓库只做原生化打包。分发二进制前请确认符合上游许可。
