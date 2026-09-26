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
  $CLI status          # "configured applied" — "applied" is verified
                       # against the live shell process; the marker file
                       # is only the fallback when no shell is running
  $CLI set gpu         # or: set software | toggle
  omarchy restart shell
  ```

- **`shell-render-launch`** — launcher wrapper (`bin/shell-render-launch`)
  that reads the setting and starts the shell on the right backend.
- **Self-maintained shim** — the `quickshell` PATH shim that routes shell
  starts through the wrapper is re-asserted by the plugin (bar widget on
  load and every 60s, launcher at every start), so mise's shims
  regeneration cannot silently drop it.

## How it works

| File | Written by | Meaning |
|---|---|---|
| `~/.config/omarchy/shell-render.conf` | the UI / `shell-render set` | `render=software` or `render=gpu` (the setting) |
| `~/.config/omarchy/shell-render.applied` | `shell-render-launch` at start-up | what the last wrapper start used; `status` prefers the live-process check (nvidia/DRM fds in `/proc/<pid>/fd`, `LIBGL_ALWAYS_SOFTWARE` in `/proc/<pid>/environ`) and only falls back to this file when no shell process is running |

`shell-render-launch` records the backend it is about to use in the applied
marker, and in `software` mode exports:

- `GALLIUM_DRIVER=llvmpipe`
- `LIBGL_ALWAYS_SOFTWARE=1`
- `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`
  (first of a few standard locations that exists) so `eglInitialize` never
  picks a hardware driver.

## Wiring it in

On a stock Omarchy install, everything that starts the shell — session
start, `omarchy restart shell`, and the launcher's crash-respawn loop —
runs the bare `quickshell`, which resolves through PATH to a `quickshell`
shim in mise's shims dir (the first user-writable PATH slot ahead of
`/usr/bin`). The shim delegates to `shell-render-launch`, so the saved
backend applies at every start; it falls back to the stock binary so the
shell always boots if the plugin is removed:

```sh
#!/bin/sh
# ~/.local/share/mise/shims/quickshell  (generated — see below)
L="$HOME/.config/omarchy/plugins/ric.shell-render/bin/shell-render-launch"
if [ -x "$L" ]; then
  exec "$L" /usr/bin/quickshell "$@"
fi
exec /usr/bin/quickshell "$@"
```

**The shim is re-asserted, not maintained by hand.** mise regenerates its
shims dir on tool changes and drops hand-added entries, so a static file
there is not upgrade-durable: it disappears at the next mise tool update
and later shell starts silently lose the wrapper, reverting to the GPU
backend while the marker file still claims software. The plugin therefore
owns the shim's lifecycle:

- the bar widget re-asserts it on load and every 60 seconds,
- `shell-render-launch` re-asserts it at every start it performs,
- `shell-render shim` repairs it from a terminal (`--remove` deletes it).

`status` also verifies the running shell process (nvidia/DRM fds in
`/proc/<pid>/fd`, `LIBGL_ALWAYS_SOFTWARE` in `/proc/<pid>/environ`), so a
start that misses the shim is reported as `gpu` instead of being hidden
by the stale marker. On other composers, run e.g.
`shell-render-launch quickshell` from your session launcher instead.

## Uninstall

```sh
~/.config/omarchy/plugins/ric.shell-render/bin/shell-render shim --remove
rm -rf ~/.config/omarchy/plugins/ric.shell-render
rm -f ~/.config/omarchy/shell-render.conf ~/.config/omarchy/shell-render.applied
omarchy restart shell
```