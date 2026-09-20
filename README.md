# RegionBlur

一个原生 macOS 菜单栏小工具，用来在屏幕上放置多个实时毛玻璃区域。

## 使用

```bash
./scripts/build-app.sh
open outputs/RegionBlur.app
```

点击菜单栏中的 `◫`，或按 `⌥⌘B`，然后拖出一个矩形即可创建模糊区域。菜单可以显示或隐藏全部区域。区域默认鼠标穿透，不会挡住下方窗口。

配置保存在本机 Application Support 目录。应用不截取、不上传屏幕内容；模糊层是否出现在录屏或屏幕共享中取决于对应工具。

当前版本支持 Apple Silicon，最低 macOS 14。需要完整 Xcode 时，可直接用 Swift Package 打开项目；命令行构建只需要 macOS Command Line Tools。
