# CIFAR-10 Dataset Notes

## 当前状态

`CIFAR-10` 是赛题文档列出的标准测试集示例之一，但 **当前 RTL 版本不适合直接拿它做正式性能或准确率测试**。

原因：

- `CIFAR-10` 输入为 `32x32x3`
- 当前 RTL 的主线验证仍集中在 `C_in=1, C_out=1`
- `FC` 路径未接通
- 多通道卷积并未在系统级完整验证

## 官方来源

- Official page: `https://www.cs.toronto.edu/~kriz/cifar.html`
- 常见下载包：
  - `cifar-10-binary.tar.gz`
  - `cifar-10-python.tar.gz`
  - `cifar-10-matlab.tar.gz`

## 本目录预留内容

- 原始数据包
- RGB 到当前 NPU 输入格式的转换脚本
- 将来用于多通道卷积验证的样例

## 使用建议

当前阶段：

- 可以只把它作为后续目标目录保留
- 不建议据此给出当前 RTL 的正式性能结论

只有在以下能力补齐后，才建议真正上 `CIFAR-10`：

1. 通用 `C_in/C_out` 卷积打通
2. `FC` 路径接通或替换成完整后续分类链路
3. `Pool/ReLU` 系统级验证补全
4. 性能计数口径和 testbench 输出统一
