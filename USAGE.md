# goshell 使用说明

`goshell` 是 dpt 的原生打包版本：单文件、不需要安装 Java。

## 快速开始

```bash
chmod +x goshell          # Windows 不需要
./goshell -v              # 2.21.0
./goshell                 # 查看全部参数
```

用内置 debug keystore 试跑（仅验证用，不能覆盖线上安装）：

```bash
./goshell -f app.apk -o out/app
# 输出 out/app/app_signed.apk
```

## 正式加壳（自定义签名）

创建 `app.json`：

```json
{
  "shellPkgName": "<random>",
  "signature": {
    "keystore": "/绝对路径/app.jks",
    "alias": "key0",
    "storepass": "keystore密码",
    "keypass": "key密码"
  }
}
```

执行：

```bash
./goshell -f app.apk -c app.json -o out/app
```

产物为 `out/app/app_signed.apk`。

> - JSON 键必须是 `storepass` / `keypass`。
> - keystore 路径写错时 dpt 会静默使用内置 debug keystore；请确认日志出现 `Use custom key store`。
> - 签名证书必须与线上版本一致，否则无法覆盖升级。

## 两个 app

每个 app 一份配置，分别指定自己的 keystore：

```bash
./goshell -f appA.apk -c appA.json -o out/appA
./goshell -f appB.apk -c appB.json -o out/appB
```

`shellPkgName` 保持 `<random>`，工具会按包名生成 `<包名>.shell`，互不冲突。

## 常用参数

| 参数 | 作用 |
|---|---|
| `-f <apk/aab>` | 输入文件（必填） |
| `-o <目录或.apk>` | 输出目录或输出文件名 |
| `-c <json>` | 签名/壳配置 |
| `-r <rules>` | 不参与加壳的类列表（见下） |
| `-e x86,x86_64` | 排除指定 ABI |
| `-vs` | 运行时签名校验（SHA-256 自动来自配置的 keystore） |
| `-K` | 保留部分类，加快启动（部分 app 不支持） |
| `-S` | 用一点性能换体积 |
| `-x` | 只加壳不签名 |
| `--debug` / `--disable-acf` | 仅调试，不要用于发布 |

## 关于 `-r` 规则文件

同目录附带的 `dpt-exclude-classes-template.rules` 是上游模板，**可选**：

- **不传 `-r`**：使用 dpt 内置的 483 条默认排除规则（推荐）
- **传 `-r`**：文件内容会**整体替换**内置列表，不是追加
- 模板只有 480 条，少了 `Lcom/huawei/hms/.*`、`Lcom/tencent/matrix/.*`、`Lcom/tencent/mmkv/.*`；若使用模板，建议补上
- 格式：一行一个类描述符正则，如 `Lcom/foo/.*`；不支持注释
- 不要排除自家业务包

## 验证与安装

```bash
apksigner verify --print-certs out/app/app_signed.apk
adb install -r out/app/app_signed.apk
```

## 运行时缓存

首次运行会把内嵌的壳资源解到：

- Linux：`~/.cache/goshell`
- macOS：`~/Library/Caches/goshell`
- Windows：`%LOCALAPPDATA%\goshell`

之后自动复用；可用 `GOSHELL_HOME` 指向包含 `shell-files/` 的目录覆盖。

## 注意

- AAB 沿用 dpt 逻辑，但尚未实测，建议先用小包验证
- dpt 上游在部分异常下仍返回 0，请确认输出 APK 存在
- 不要对发布包使用 `--debug` / `--disable-acf`
