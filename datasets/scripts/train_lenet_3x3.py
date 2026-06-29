#!/usr/bin/env python3
"""Train 3×3 LeNet on MNIST and export INT8 weights as RTL memh files.

No external deps beyond torch (torchvision replaced by manual MNIST parsing).
"""
import torch
import torch.nn as nn
import torch.nn.functional as F
import gzip, struct, os, sys, math

# ── MNIST parser (no torchvision) ───────────────────────────────────
def parse_mnist_images(path):
    with gzip.open(path, 'rb') as f:
        magic, n, rows, cols = struct.unpack('>IIII', f.read(16))
        data = f.read()
    return torch.tensor(list(data), dtype=torch.float32).reshape(n, 1, rows, cols) / 255.0

def parse_mnist_labels(path):
    with gzip.open(path, 'rb') as f:
        magic, n = struct.unpack('>II', f.read(8))
        data = f.read()
    return torch.tensor(list(data), dtype=torch.long)

# ── Model ───────────────────────────────────────────────────────────
class LeNet3x3(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 20, 3, padding=0)
        self.conv2 = nn.Conv2d(20, 50, 3, padding=0)
        self.fc1 = nn.Linear(5*5*50, 500)
        self.fc2 = nn.Linear(500, 10)

    def forward(self, x):
        x = F.relu(self.conv1(x))
        x = F.max_pool2d(x, 2, 2)
        x = F.relu(self.conv2(x))
        x = F.max_pool2d(x, 2, 2)
        x = x.view(-1, 5*5*50)
        x = F.relu(self.fc1(x))
        x = self.fc2(x)
        return x

# ── Weight export ───────────────────────────────────────────────────
def write_memh(all_bytes, path):
    with open(path, 'w') as f:
        for i in range(0, len(all_bytes), 32):
            beat = all_bytes[i:i+32]
            if len(beat) < 32:
                beat = beat + bytes(32 - len(beat))
            f.write(beat.hex() + '\n')

def export_conv(w, name, out_dir):
    """w: torch tensor (C_out, C_in, H, W) → INT8."""
    w = w.cpu()
    mx = w.abs().max().item() or 1.0
    scale = 127.0 / mx
    q = torch.clamp(torch.round(w * scale), -128, 127).to(torch.int8)
    C_out, C_in, H, W = q.shape
    spat = H * W
    # Build: for each in_c: for sp: for out_c
    buf = bytearray()
    for ic in range(C_in):
        for sp in range(spat):
            r, c = sp // W, sp % W
            for oc in range(C_out):
                buf.append(q[oc, ic, r, c].item() & 0xFF)
        # pad to 4B
        per_cin = spat * C_out
        pad = ((per_cin + 3) & ~3) - per_cin
        for _ in range(pad):
            buf.append(0)
    write_memh(buf, os.path.join(out_dir, f"{name}.memh"))
    return len(buf), scale

def export_fc(w, name, out_dir):
    w = w.cpu()
    mx = w.abs().max().item() or 1.0
    scale = 127.0 / mx
    q = torch.clamp(torch.round(w * scale), -128, 127).to(torch.int8)
    On, In = q.shape
    buf = bytearray()
    for o in range(On):
        for i in range(In):
            buf.append(q[o, i].item() & 0xFF)
    write_memh(buf, os.path.join(out_dir, f"{name}.memh"))
    return len(buf), scale

# ── Main ────────────────────────────────────────────────────────────
def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "datasets/mnist/lenet_3x3_weights"
    data_dir = sys.argv[2] if len(sys.argv) > 2 else "datasets/mnist"
    os.makedirs(out_dir, exist_ok=True)

    print("Loading MNIST...")
    train_x = parse_mnist_images(os.path.join(data_dir, 'train-images-idx3-ubyte.gz'))
    train_y = parse_mnist_labels(os.path.join(data_dir, 'train-labels-idx1-ubyte.gz'))
    test_x = parse_mnist_images(os.path.join(data_dir, 't10k-images-idx3-ubyte.gz'))
    test_y = parse_mnist_labels(os.path.join(data_dir, 't10k-labels-idx1-ubyte.gz'))
    print(f"  Train: {train_x.shape}, Test: {test_x.shape}")

    model = LeNet3x3()
    opt = torch.optim.Adam(model.parameters(), lr=0.001)
    crit = nn.CrossEntropyLoss()

    print("Training...")
    for epoch in range(5):
        model.train()
        total_loss, correct = 0, 0
        for start in range(0, len(train_x), 64):
            end = min(start + 64, len(train_x))
            xb, yb = train_x[start:end], train_y[start:end]
            opt.zero_grad()
            out = model(xb)
            loss = crit(out, yb)
            loss.backward()
            opt.step()
            total_loss += loss.item() * (end - start)
            correct += out.argmax(1).eq(yb).sum().item()
        train_acc = 100.0 * correct / len(train_x)
        # Quick test
        model.eval()
        with torch.no_grad():
            t_out = model(test_x[:2000])
            t_acc = 100.0 * t_out.argmax(1).eq(test_y[:2000]).sum().item() / 2000
        print(f"  Epoch {epoch+1}: loss={total_loss/len(train_x):.4f} train={train_acc:.1f}% test2k={t_acc:.1f}%")

    # Full test
    model.eval()
    correct = 0
    with torch.no_grad():
        for start in range(0, len(test_x), 500):
            end = min(start + 500, len(test_x))
            out = model(test_x[start:end])
            correct += out.argmax(1).eq(test_y[start:end]).sum().item()
    acc = 100.0 * correct / len(test_x)
    print(f"\nFinal test accuracy: {acc:.2f}% ({correct}/{len(test_x)})")

    # Export
    print("\nExporting INT8 weights...")
    summary = {"network": "LeNet-3x3", "accuracy": acc}
    for name, tensor, fn in [
        ("conv1_weights", model.conv1.weight.data, export_conv),
        ("conv2_weights", model.conv2.weight.data, export_conv),
        ("fc1_weights", model.fc1.weight.data, export_fc),
        ("fc2_weights", model.fc2.weight.data, export_fc),
    ]:
        nbytes, scale = fn(tensor, name, out_dir)
        summary[name] = f"{nbytes} bytes ({nbytes//32} beats)"
        summary[name.replace("weights","scale")] = float(scale)
        print(f"  {name}: {nbytes} bytes")

    import json
    with open(os.path.join(out_dir, "summary.json"), 'w') as f:
        json.dump(summary, f, indent=2)
    print(f"\nDone → {out_dir}/")

if __name__ == '__main__':
    main()
