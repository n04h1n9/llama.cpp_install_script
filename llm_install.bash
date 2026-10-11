#!/usr/bin/bash

set -euo pipefail

echo "
░█▀█░▄▀▄░█░█░█░█░▀█░░█▀█░▄▀▄
░█░█░█ █░░▀█░█▀█░░█░░█░█░░▀█
░▀░▀░░▀░░░░▀░▀░▀░▀▀▀░▀░▀░▀▀░

It's n04h1n9's install script of llama.cpp, I typicaly customize it and make it
has high-performance on translation with bilibili's Index-Translation model.

To use this script, you should use GNU/Linux, and install some software as
dependences with your package manager, apt, dnf, pacman, homebrew, etc. These
are below: git (to clone llama.cpp's source code) curl (to install llm) cmake
gcc (to compile llama.cpp)

Let's start? (press enter to continue or ^C to abort)"
read stdin

# for dependency resolution
for i in {git,curl,cmake,gcc,g++}; do
    if [[ ! $(which ${i}) ]]; then
        echo "${i} does not exist, you should install it"
        exit 1
    fi
done

# clone llama.cpp
git clone https://github.com/ggml-org/llama.cpp.git && cd llama.cpp

echo "
Now you will choose something about your hardware to make llama.cpp run
faster on you on device(but it isn't portable),type like 1 2 3 to choose it,
enter to choose none

1.for every cpu
2.for nvidia gpu(CUDA require)
3.for amd gpu(ROCm require)
4.for amd cpu(zen)
5.for intel cpu
6.for macos
7.for 华为昇腾
8.for 摩尔线程
9.for vulkan
10.for intel npu

now, choose for your own device
"
read -ar hardware
for x in ${hardware[@]}; do
    # guess what happen before?
    # if [[ $x = 1 ]]; then
    #     cmake -B build -CMAKE_BUILD_TYPE=Release
    #     cmake -B build -GGML_NATIVE=ON
    # elif [[ $x = 2 ]]; then
    #     cmake -B build -GGML_CUDA=ON
    # elif [[ $x = 3 ]]; then
    #     cmake -B build -GGML_HIP=ON
    # elif [[ $x = 4 ]]; then
    #     cmake -B build -GGML_ZENDNN=ON
    # elif [[ $x = 5 ]]; then
    #     cmake -B build -GGML_SYCL=ON
    # elif [[ $x = 6 ]]; then
    #     cmake -B build -GGML_METAL=ON
    # elif [[ $x = 7 ]]; then
    #     cmake -B build -GGML_CANN=ON
    #     cmake -B build -GGML_CANN=ON
    # elif [[ $x = 8 ]]; then
    #     cmake -B build -GGML_MUSA=ON
    #     cmake -B build -GGML_MUSA_MUDNN_COPY=ON
    # elif [[ $x = 9 ]]; then
    #     cmake -B build -GGML_VULKAN=ON
    # elif [[ $x = 10 ]]; then
    #     cmake -B build -GGML_OPENVINO=ON
    # fi
    case $hardware in
    1)
        cmake -B build -CMAKE_BUILD_TYPE=Release
        cmake -B build -GGML_NATIVE=ON
        ;;
    2) cmake -B build -GGML_CUDA=ON ;;
    3) cmake -B build -GGML_HIP=ON ;;
    4) cmake -B build -GGML_ZENDNN=ON ;;
    5) cmake -B build -GGML_SYCL=ON ;;
    6) cmake -B build -GGML_METAL=ON ;;
    7) cmake -B build -GGML_CANN=ON ;;
    8)
        cmake -B build -GGML_MUSA=ON
        cmake -B build -GGML_MUSA_MUDNN_COPY=ON
        ;;
    9) cmake -B build -GGML_VULKAN=ON ;;
    esac
done
# start to build
echo "choose how much threads to build, default is 4"
jobs=4
read -r jobs
export CMAKE_BUILD_PARALLEL_LEVEL=4
cmake --build build -j "$jobs"
mkdir llm_models
cd llm_models

echo "now choose your models by default
1. qwen3.8 9b(q4km)
2. Index-Translator 9b (q4km, for translation)
3. ministral3 14b(q4km)"

read -ar models

echo "please wait some time to download models,let's listen music"
mpv --really-quiet --no-video ../something/worldExecuteMe.flac

for i in ${models[@]}; do
    case $models in
    1) curl https://hf-mirror.com/empero-ai/Qwen3.8-9B-Distill-GGUF/resolve/main/Qwen3.8-9B-Q4_K_M.gguf ;;
    2) curl https://hf-mirror.com/IndexTeam/Index-Translate-9B-GGUF/resolve/main/Index-Translate-9B.Q4_K_M.gguf ;;
    3) curl https://hf-mirror.com/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/main/Ministral-3-14B-Instruct-2512-Q4_K_M.gguf ;;
    esac
done

echo "complete"
