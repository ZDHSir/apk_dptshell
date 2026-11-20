# dpt upstream assets

这个目录集中存放所有来自上游 [dpt](https://github.com/luoyesiqiu/dpt) 的文件。升级 dpt 时只替换这里，构建脚本不需要改。

```
dpt.jar                            # 上游可执行 jar
shell-files/                       # 壳 dex / so / build-key，必须与 dpt.jar 的版本匹配
dpt-exclude-classes-template.rules # 上游的默认排除规则模板
dpt-protect-config-template.json   # 上游的配置模板
VERSION                            # 记录当前上游版本号
```

## 升级步骤

1. 下载新版 dpt 发布包。
2. **同时**替换 `dpt.jar` 和 `shell-files/`。二者通过 `Dpt-Build-Key` 绑定，混用不同版本会导致运行期校验失败。
3. 如果上游更新了规则/配置模板，一并替换 `dpt-exclude-classes-template.rules`、`dpt-protect-config-template.json`。
4. 更新 `VERSION` 文件。
5. 重新生成 native-image 元数据（反射/资源/JCA 会随版本变化）：

   ```bash
   GRAALVM_HOME=/path/to/graalvm-21 scripts/trace-config.sh testapp/fixture.apk
   ```

6. 重新构建并冒烟测试：

   ```bash
   GRAALVM_HOME=/path/to/graalvm-21 scripts/build-native.sh
   ./build/native/goshell -v
   ./build/native/goshell -f testapp/fixture.apk -o /tmp/smoke
   ```

> 注意：dpt 每次运行都会重写 `shell-files/dex/junkcode.dex`。构建时通过 tracing agent 跑 dpt 会修改这个文件，这是上游行为，不是本仓库的改动；goshell 在运行时会把 `shell-files` 复制到私有目录再处理，不会碰这里。
