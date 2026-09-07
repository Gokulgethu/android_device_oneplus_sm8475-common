#!/usr/bin/env python3
"""Recursively read a raw ext4 image into a directory (no root required).

Used as a fallback when debugfs/7z are unavailable.
Requires: pip install ext4
Usage: ext4_dump.py <image.img> <out_dir>
"""
import os
import sys

try:
    import ext4
except ImportError:
    sys.exit("ext4 module not installed:  pip install ext4")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: ext4_dump.py <image> <out_dir>")
    image, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    vol = ext4.Volume(open(image, "rb"))

    def walk(inode_path, out_path):
        inode = vol.root if inode_path == "/" else vol.get_inode(inode_path.lstrip("/"))
        for name, f_inode, f_path in inode.open_dir():
            if name in (".", ".."):
                continue
            target = os.path.join(out_path, name)
            mode = f_inode.inode.i_mode
            from stat import S_ISDIR, S_ISLNK, S_ISREG
            if S_ISDIR(mode):
                os.makedirs(target, exist_ok=True)
                walk("/" + f_path, target)
            elif S_ISREG(mode):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as o:
                    with f_inode.open_read() as r:
                        while True:
                            b = r.read(1 << 20)
                            if not b:
                                break
                            o.write(b)
            elif S_ISLNK(mode):
                try:
                    link = f_inode.open_read().read().decode()
                    os.symlink(link, target)
                except OSError:
                    pass

    walk("/", outdir)
    print(f"ext4 dump -> {outdir}")


if __name__ == "__main__":
    main()
