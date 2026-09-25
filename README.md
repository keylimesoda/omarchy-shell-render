# omarchy-shell-render

An [Omarchy](https://omarchy.dev) bar widget + panel that switches the shell
(bar and menu) between **GPU** and **CPU (Mesa/llvmpipe)** rasterizers — plus
the CLI and launcher wrapper that make the switch work.

## Why

When a GPU is pinned at high utilization (e.g. by a local inference server),
the nvidia-open driver can exhaust its internal resource pool and start
corrupting the GL state of display-client processes. On a workstation running
local LLM inference this took down the Omarchy shell's bar and menu
(`EGL 0x3003` / `NV_ERR_NO_MEMORY` in `mapping_reuse.c`). Rendering the shell
on the CPU via llvmpipe makes it immune while the GPU keeps serving the
compositor, the browser, and the workload.

## What you get

- **Bar button** (`right` section by default) that always shows the
  *configured* backend — `GPU` or `CPU`. Tooltip flags a pending restart.
- **Panel** — click the button: hero shows the live state (`NOW GPU` or
  `GPU → CPU · RESTART PENDING`), two chips (GPU / CPU (llvmpipe)), and the
  state-file location. Fully keyboard-navigable (j/k/h/l, Enter, Esc, r
  refreshes).
- **Restart offer** — picking a backend persists it immediately and opens a
  dialog explaining the switch applies on the next shell start, with
  *Restart now* / *Later*. No surprise bar blip: the restart only happens
  when you confirm.
- **`shell-render` CLI** — ships inside the plugin (`bin/shell-render`),
  also usable from a terminal:

  ```sh
  CLI=~/.config/omarchy/plugins/ric.shell-render/bin/shell-render
  $CLI                 # print configured backend (gpu|software)
  $CLI status          # "configured applied"
  $CLI set gpu         # or: set software | toggle
  omarchy restart shell
  ```

- **`shell-render-launch`** — launcher wrapper (`bin/shell-render-launch`)
  that reads the setting and starts the shell on the right backend.

## How it works

| File | Written by | Meaning |
|---|---|---|
| `~/.config/omarchy/shell-render.conf` | the UI / `shell-render set` | `render=software` or `render=gpu` (the setting) |
| `~/.config/omarchy/shell-render.applied` | `shell-render-launch` at start-up | what this running shell was launched with (drives the "restart pending" indicator) |

`shell-render-launch` records the backend it is about to use in the applied
marker, and in `software` mode exports:

- `GALLIUM_DRIVER=llvmpipe`
- `LIBGL_ALWAYS_SOFTWARE=1`
- `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`
  (first of a few standard locations that exists) so `eglInitialize` never
  picks a hardware driver.

## Wiring it in

Point whatever starts your shell at the wrapper instead of at the shell
binary. On a stock Omarchy install the shell is started by
`omarchy-launch-shell`, which execs `quickshell`; the least-invasive
user-level hook is a `quickshell` shim ahead of `/usr/bin` on PATH:

```sh
#!/bin/bash
# ~/.local/share/mise/shims/quickshell (or any PATH position ahead of /usr/bin)
L="$HOME/.config/omarchy/plugins/ric.shell-render/bin/shell-render-launch"
if [[ -x $L ]]; then
  exec "$L" /usr/bin/quickshell "$@"
fi
exec /usr/bin/quickshell "$@"
```

The fallback keeps the shell bootable if the plugin is ever removed. On other
composers, run e.g. `shell-render-launch quickshell` from your session
launcher instead.

## Uninstall

```sh
rm -rf ~/.config/omarchy/plugins/ric.shell-render
# drop the launcher hook / shim if you added one
rm -f ~/.config/omarchy/shell-render.conf ~/.config/omarchy/shell-render.applied
omarchy restart shell
```