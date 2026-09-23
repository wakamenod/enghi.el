# enghi.el

*English · [日本語](README.ja.md)*

An Emacs client for [enghi](https://github.com/wakamenod/enghi), a local-only wiki + GTD
server.

- Open and edit pages in an Emacs buffer, then save with `C-c C-c`
- Search across pages, querying the server on each keystroke
- Send a line to the GTD Inbox from anywhere
- Manage GTD tasks from a dashboard opened in webkit inside Emacs
- Show items selected in Emacs in an already open browser

## Requirements

| | | |
|---|---|---|
| Emacs | 28.1 or later | |
| [enghi](https://github.com/wakamenod/enghi) server | Must be running | |
| `markdown-mode` | Optional | Used in page buffers |
| `consult` | Optional | Used for search on each keystroke |

`markdown-mode` and `consult` are optional. Without them, it falls back to `fundamental-mode` and `completing-read` search respectively.

## Setup

### 1. Start the server

```sh
cd ../enghi
make build
./bin/enghi install-agent -load   # Run continuously with launchd
```

If you just want to try it without running it continuously, `./bin/enghi serve` also works.
By default, it runs at `http://127.0.0.1:7777`.

```sh
curl -s http://127.0.0.1:7777/api/status
# {"db":"...","event_clients":0,"export_dir":"...","ok":true}
```

### 2. Load the package

```elisp
(add-to-list 'load-path "~/Projects/SideProjects/enghi.el")
(require 'enghi)
(enghi-setup)          ; Set up keymap on C-c n
```

With `use-package`:

```elisp
(use-package enghi
  :load-path "~/Projects/SideProjects/enghi.el"
  :commands (enghi-find-page enghi-capture enghi-browse-dashboard enghi-search-command)
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777")
  :config
  (autoload 'enghi-consult-search "enghi-consult" nil t))
```

With `leaf`. Because `:bind-keymap` evaluates the keymap during expansion and fails if it is not loaded yet, add an autoload for the keymap:

```elisp
(leaf enghi
  :load-path "~/Projects/SideProjects/enghi.el"
  :commands (enghi-find-page enghi-new-page enghi-capture enghi-search-command
             enghi-open-in-browser enghi-focus-page enghi-browse-dashboard enghi-status)
  :init
  (autoload 'enghi-command-map "enghi" nil nil 'keymap)
  (autoload 'enghi-consult-search "enghi-consult" nil t)
  :bind (("C-c n" . enghi-command-map))
  :custom ((enghi-server-url . "http://127.0.0.1:7777")))
```

With `straight.el`:

```elisp
(straight-use-package
 '(enghi :type built-in :local-repo "~/Projects/SideProjects/enghi.el" :files ("*.el")))
```

### 3. Check that it works

If `M-x enghi-status` returns the server status, you are connected.
If you changed the port, update `enghi-server-url` to match.

If you try to open the browser while disconnected, Emacs errors before passing the request to the browser (passing it to xwidget would only show a WebKit error page without explaining the cause).

### 4. Write your first page

Press `C-c n n` and enter a title to open a page buffer. Write the body and save with `C-c C-c`.

## Usage

### Keymap (`C-c n`)

| Key | Command | |
|---|---|---|
| `s` | `enghi-search-command` | Search across pages |
| `f` | `enghi-find-page` | Select and open a page |
| `n` | `enghi-new-page` | Create a new page |
| `c` | `enghi-capture` | Send a line to Inbox |
| `o` | `enghi-focus-page` | Focus browser tab on the page |
| `b` | `enghi-open-in-browser` | Open in browser |
| `d` | `enghi-browse-dashboard` | Open dashboard (including GTD) |

### Page buffer

`enghi-page-mode` runs on top of `markdown-mode`. The buffer content is raw Markdown.

| Key | |
|---|---|
| `C-c C-c` | Save |
| `C-c C-r` | Change title |
| `C-c C-t` | Edit tags |
| `C-c C-l` | Select a page and insert `[[link]]` |
| `C-c C-o` | Open in browser |
| `C-c C-k` | Revert to server content |

You can link to pages that do not exist yet, like `[[non-existent page]]`. They are kept as unresolved links and connect automatically once you create a page with that name.

When you change a title, the old title remains as an alias. Links in other pages written as `[[old title]]` continue to work.

## Edit while viewing

When viewing a page in webkit (such as with `C-c n b`), pressing `E` opens that page in the lower window as an Emacs buffer. The top window displays it, and the bottom window edits it.

| Key | | |
|---|---|---|
| `E` | `enghi-xwidget-edit-page` | Edit the displayed page in the lower window |

Available keys **appear in the buffer header line**. They change depending on the current view: for a page, you see options like `E edit`; for the GTD list, options like `n next action` and `d done`.

Because actions in the GTD list are handled by the page itself, keys like `j` `k` `RET` `n` `w` `s` `l` `m` `d` `S` `f` `t` `x` `c` `/` pass straight through to the page (you can press them without entering `xwidget-webkit-edit-mode` via `e`). `e` itself is kept intact, as it is the native xwidget mode for passing keys to the page. `f` goes to the page only in the GTD list; on other screens it keeps its usual webkit meaning (forward). The keys are delivered as JavaScript `keydown` events, so this also works on macOS, where `xwidget-webkit-pass-command-event` does nothing.

When you save with `C-c C-c`, the server broadcasts the update to all connected clients, and any view displaying that page reloads automatically. You do not need to trigger a refresh from Emacs. Your scroll position is preserved.

Updates are sent only when you save. In-progress typing is not sent.

## Save conflicts

If a page was updated through another path while you were editing, `ediff` opens to show the server version and your local version side by side. Your local edits remain in the buffer, so you can compare them and save again.

If you try to rename a page to a title that already exists, it displays the conflicting page and prompts for a different title. The body text is preserved.

## Browser integration

If you keep a browser open on another display, it can follow what you select in Emacs.

```
C-c n o
```

The server broadcasts navigation events to all connected tabs. Even if the server restarts, the browser automatically reconnects.

If you want to view pages inside Emacs, you can change the browse function.

```elisp
(setq enghi-browse-function #'enghi-browse-in-xwidget)  ; Default is #'browse-url
```

`enghi-browse-in-xwidget` opens pages in xwidget webkit and leaves some padding around the view (with `xwidget-webkit-browse-url`, the edges of the page stick directly to the fringes and mode line). You can adjust the padding with `enghi-xwidget-padding`: an integer applies equally to all four sides, while `(horizontal . vertical)` sets left/right and top/bottom separately. Setting it to `0` expands to fill the entire buffer. Padding only applies to buffers opened by `enghi`.

## Configuration

| Variable | Default | |
|---|---|---|
| `enghi-server-url` | `http://127.0.0.1:7777` | Server URL |
| `enghi-request-timeout` | `10` | Request timeout (seconds) |
| `enghi-browse-function` | `#'browse-url` | Function to open in browser |
| `enghi-xwidget-padding` | `(24 . 12)` | Padding for `enghi-browse-in-xwidget`, in `(horizontal . vertical)` pixels |
| `enghi-consult-min-input` | `1` | Number of characters typed before search starts |

There are no passwords or tokens to configure. The server only accepts connections from loopback.

## Development

```sh
make compile    # Byte-compile (warnings treated as errors)
```

Tests run against a live server. Start a test server on a different port.

```sh
cat > /tmp/enghi-test.toml <<'TOML'
port = 7799
db_path = "/tmp/enghi-test/enghi.db"
export_dir = "/tmp/enghi-test/export"
TOML

../enghi/bin/enghi serve --config /tmp/enghi-test.toml &
make test
```

## Structure

| File | |
|---|---|
| `enghi.el` | API client, page editing, capture, keymaps |
| `enghi-consult.el` | Search using consult |
| `enghi-tests.el` | Tests |
