"""Public ABI metadata for object compilation; never translates or reads a game."""
import argparse
from pathlib import Path
import tomllib

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if (root / "android/generated") in args.out.resolve().parents:
        raise SystemExit("Compile-check metadata must not replace private generated files")
    config = tomllib.loads((root / "config/game.toml").read_text())
    layout = tomllib.loads((args.sdk / "xdk/5849/layout.toml").read_text())
    # This mirrors only the public metadata format documented by codegen_emit.cpp.
    # There is no XBE, function implementation or runnable entry in this fixture.
    lines = ["#pragma once", "#define SHAOLIN_COMPILE_CHECK_METADATA 1"]
    absent = 0
    for name, value in sorted(config["symbols"].items()):
        address = value or (0xFFFF0000 + absent)
        absent += int(not value)
        lines += [f"#define SYM_{name} {address:08X}", f"#define HAS_{name} {int(bool(value))}"]
    for name, value in sorted(config["data"].items()):
        lines += [f"#define SYM_{name} {value:08X}", f"#define HAS_{name} {int(bool(value))}"]
    for name, value in sorted(layout.get("layout", layout).items()):
        lines += [f"#define XDK_{name} 0x{value:X}"]
    rows = ["X(" + name + ", " + ", ".join(locs) + ")" for name, locs in config.get("abi", {}).items()]
    lines += ["#define IMAGE_ABI(X) " + " ".join(rows)]
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "image_symbols.h").write_text("\n".join(lines) + "\n")

if __name__ == "__main__":
    main()
