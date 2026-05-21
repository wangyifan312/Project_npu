# MNIST Dataset Notes

## 推荐用途

当前版本最适合先用 `MNIST` 做测试。

原因：

- 赛题文档明确把 `MNIST` 作为标准测试集示例之一
- `MNIST` 是 `28x28` 单通道灰度图
- 与当前 RTL 已验证的 `Conv` 子集更匹配

## 官方来源

- Official page: `https://yann.lecun.org/exdb/mnist/index.html`
- 典型文件：
  - `train-images-idx3-ubyte.gz`
  - `train-labels-idx1-ubyte.gz`
  - `t10k-images-idx3-ubyte.gz`
  - `t10k-labels-idx1-ubyte.gz`

## 本目录预留内容

- 原始数据文件
- 转换后的样例图片/标签
- 量化后的内存镜像
- 适配 testbench 的 preload 文件

## 当前建议测试方式

优先做：

1. 选取少量 `MNIST` 测试图片
2. 转成 `INT8` 单通道输入
3. 先驱动 `Conv-only` 路径
4. 验证输出 feature map 和软件黄金结果一致

暂不建议直接做：

- 完整 `LeNet` 分类准确率
- 带 `FC` 的端到端推理

因为当前 RTL 的 `FC` 路径仍是禁用状态。
