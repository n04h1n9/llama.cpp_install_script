# n04h1n9的自动翻译脚本

## 简介

这是一个用于安装llama.cpp以及选择部分模型的版本，旨在最大程度的让用户根据自己的设备编译从而最大程度提升性能（牺牲了可移植性，但大不了重新编一次就是了）

## GNU/Linux食用方法

GNU/Linux的部分由我本人来写，.bash结尾的就是

GNU/Linux直接运行
```bash
./llm_install.bash
```
即可

依赖：
- git 用于克隆脚本
- curl 用于下模型
- g++ cmake 编译
- mpv 别管

btw，我还加了个彩蛋，大家踊跃发掘

## Windows食用方法
Windows部分由我的~妈妈~朋友编写，统一位于Windows目录下


- 工具链：MSVC 优先，回退 GCC/G++ (MinGW-w64)
- 后端（10 个，可多选）**：CPU / CUDA / HIP / ZenDNN / SYCL / Metal / CANN / MUSA / Vulkan / OpenVINO
- 生成器：优先 Ninja，不可用时降级到 Visual Studio
- 构建模式：Release / RelWithDebInfo / Debug / MinSizeRel
- 产物位置：`build-<后端>-<工具链>[-<模式>]\bin`

### 用法

```bash
.\Windows\llm_install.cmd                                 # 双击或命令行，交互式
.\Windows\llm_install.ps1 -Backend CPU -Jobs 20
.\Windows\llm_install.ps1 -Toolchain msvc -Backend CUDA   # Windows 上 CUDA 只能配 MSVC
```

要求：Windows 10/11 + CMake ≥ 3.14 + 一个 C++ 工具链。

注，本人喜欢使用硬换行。由于渲染问题，会有一些空格插空。
