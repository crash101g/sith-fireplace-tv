#!/usr/bin/env python3
"""AI-upscale the Sith Fireplace loop with Real-ESRGAN (x4plus).

Reads the small loop that `PREP_UPSCALE=1 ./build.sh` makes (712x400, lossless),
runs every frame through Real-ESRGAN x4plus (-> 2848x1600), resizes to 1920x1080
and writes work chunks, then joins them into sith_upscaled.mp4.

Resumable: finished chunks are kept, so after a Colab disconnect just run it again.

Usage: python upscale.py INPUT OUT_DIR --weights RealESRGAN_x4plus.pth
Needs: torch, numpy, ffmpeg. Uses CUDA (fp16) when available, else CPU (slow).
"""
import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

OUT_W, OUT_H, FPS = 1920, 1080, 30


# --- Real-ESRGAN x4plus network (RRDBNet, same layout as the official weights) ---
class ResidualDenseBlock(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(nf, gc)
        self.rdb2 = ResidualDenseBlock(nf, gc)
        self.rdb3 = ResidualDenseBlock(nf, gc)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, nf=64, nb=23, gc=32):
        super().__init__()
        self.conv_first = nn.Conv2d(3, nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, inplace=True)

    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
         "-show_entries", "stream=width,height,nb_read_frames", "-of", "json", path],
        check=True, capture_output=True, text=True).stdout
    s = json.loads(out)["streams"][0]
    return int(s["width"]), int(s["height"]), int(s["nb_read_frames"])


def upscale_chunk(model, device, dtype, src, w, h, start, end, dst):
    dec = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", src, "-vf",
         f"trim=start_frame={start}:end_frame={end},setpts=PTS-STARTPTS",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    # High-quality intermediate (the final HEVC encode happens in build.sh).
    # Keep the source's colour tags: BT.601 matrix, BT.709 primaries/transfer.
    enc = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
         "-s", f"{OUT_W}x{OUT_H}", "-r", str(FPS), "-i", "-",
         "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p",
         "-colorspace", "smpte170m", "-color_primaries", "bt709", "-color_trc", "bt709",
         "-f", "mp4", dst], stdin=subprocess.PIPE)
    size = w * h * 3
    n = 0
    while True:
        buf = dec.stdout.read(size)
        if len(buf) < size:
            break
        img = torch.from_numpy(np.frombuffer(buf, np.uint8).reshape(h, w, 3).copy())
        x = img.permute(2, 0, 1).unsqueeze(0).to(device, dtype) / 255.0
        with torch.inference_mode():
            y = model(x).float().clamp_(0, 1)
            y = F.interpolate(y, size=(OUT_H, OUT_W), mode="bicubic", antialias=True)
            out = (y.clamp_(0, 1) * 255.0).round_().byte()[0].permute(1, 2, 0).cpu().numpy()
        enc.stdin.write(out.tobytes())
        n += 1
    dec.wait()
    enc.stdin.close()
    enc.wait()
    if dec.returncode or enc.returncode or n != end - start:
        raise RuntimeError(f"chunk {start}-{end}: got {n} frames "
                           f"(decoder {dec.returncode}, encoder {enc.returncode})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("out_dir")
    ap.add_argument("--weights", required=True)
    ap.add_argument("--chunk", type=int, default=150, help="frames per resumable chunk")
    ap.add_argument("--frames", type=int, default=0, help="only do the first N frames (testing)")
    a = ap.parse_args()

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    dtype = torch.float16 if device.type == "cuda" else torch.float32
    print("Device:", torch.cuda.get_device_name(0) if device.type == "cuda" else "CPU (slow!)")

    model = RRDBNet()
    state = torch.load(a.weights, map_location="cpu")
    model.load_state_dict(state.get("params_ema", state.get("params", state)), strict=True)
    model.eval().to(device, dtype)

    w, h, total = probe(a.input)
    if a.frames:
        total = min(total, a.frames)
    print(f"Input {w}x{h}, {total} frames -> {OUT_W}x{OUT_H}")
    os.makedirs(a.out_dir, exist_ok=True)

    chunks = []
    t0, done = time.time(), 0
    for start in range(0, total, a.chunk):
        end = min(start + a.chunk, total)
        path = os.path.join(a.out_dir, f"chunk_{start:05d}_{end:05d}.mp4")
        chunks.append(path)
        if os.path.exists(path):
            print(f"  frames {start}-{end - 1}: already done")
            continue
        upscale_chunk(model, device, dtype, a.input, w, h, start, end, path + ".part")
        os.replace(path + ".part", path)
        done += end - start
        rate = (time.time() - t0) / done
        print(f"  frames {start}-{end - 1}: done ({rate:.2f} s/frame, "
              f"~{rate * (total - end) / 60:.0f} min left)", flush=True)

    final = os.path.join(a.out_dir, "sith_upscaled.mp4")
    lst = os.path.join(a.out_dir, "chunks.txt")
    with open(lst, "w") as f:
        f.writelines(f"file '{os.path.abspath(c)}'\n" for c in chunks)
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", lst,
                    "-c", "copy", "-movflags", "+faststart", final], check=True)
    got = probe(final)[2]
    if got != total:
        sys.exit(f"ERROR: {final} has {got} frames, expected {total}")
    print(f"Finished: {final} ({got} frames, {os.path.getsize(final) / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
