## Usage

Just pick a color 😺!

## Options

See `pickz -h`

## Dependencies

**Compile-time:**

- `zig` (0.15.x)
- `pkg-config`
- `wayland-protocols`
- `wlr-protocols`
- `libwayland-client` (C headers)

**Runtime:**

- `wl-clipboard` (Optional, required for the `-a` autocopy feature)

## Manual Installation

```sh
git clone https://codeberg.org/miniaoumiae/pickz.git
cd pickz

# You can also use -Doptimize=ReleaseFast for speed instead of size
zig build -Doptimize=ReleaseSmall

sudo install -m 755 zig-out/bin/pickz /usr/local/bin/pickz
```
