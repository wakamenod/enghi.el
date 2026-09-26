# enghi.el

*English · [日本語](README.ja.md)*

An Emacs client for [enghi](https://github.com/wakamenod/enghi), a local-only wiki and GTD server.

- Open pages in an Emacs buffer, edit them, and save with `C-c C-c`
- Search all pages as you type, with each keystroke sent to the server
- Send a one-line item to the GTD Inbox from anywhere
- Manage GTD tasks from a dashboard in Emacs's webkit view
- Have an open browser show what you select in Emacs
- Show the Inbox, today's tasks and upcoming deadlines on the dashboard.el startup screen

## Requirements

| | | |
|---|---|---|
| Emacs | 28.1 or later | |
| [enghi](https://github.com/wakamenod/enghi) server | Must be running | |
| `markdown-mode` | Optional | Used in page buffers |
| `consult` | Optional | Used for search on each keystroke |
| `dashboard` | Optional | For the startup screen section |
| `browse-at-remote` | Optional | Permalinks in code links of the work log |

`markdown-mode` and `consult` are optional. Without them, enghi.el uses `fundamental-mode` and `completing-read` search instead.

## Setup

### 1. Start the server

```sh
cd ../enghi
make build
./bin/enghi install-agent -load   # Run continuously with launchd
```

To try it without keeping it running, use `./bin/enghi serve`.
By default, the server listens on `http://127.0.0.1:7777`.

```sh
curl -s http://127.0.0.1:7777/api/status
# {"db":"...","event_clients":0,"export_dir":"...","ok":true}
```

### 2. Install the package

Install it from GitHub with `use-package`. The `:vc` keyword needs Emacs 30 or later.

```elisp
(use-package enghi
  :vc (:url "https://github.com/wakamenod/enghi.el" :rev :newest)
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777"))
```

`C-c n` loads the package the first time you press it.

On Emacs 29, `use-package` has no `:vc` keyword. Install the package once with `M-x package-vc-install RET https://github.com/wakamenod/enghi.el RET`, then leave `:vc` out:

```elisp
(use-package enghi
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777"))
```

Emacs 28 has no `package-vc-install`, and you need to install `use-package` from MELPA. Clone the repository and load it from there:

```sh
git clone https://github.com/wakamenod/enghi.el ~/.emacs.d/site-lisp/enghi.el
```

```elisp
(use-package enghi
  :load-path "~/.emacs.d/site-lisp/enghi.el"
  :commands (enghi-find-page enghi-capture enghi-browse-dashboard enghi-search-command)
  :bind-keymap ("C-c n" . enghi-command-map)
  :custom
  (enghi-server-url "http://127.0.0.1:7777")
  :config
  (autoload 'enghi-consult-search "enghi-consult" nil t))
```

To update it, run `git pull` in that directory.

### 3. Check that it works

Run `M-x enghi-status`. If it shows the server status, you're connected.
If you changed the port, set `enghi-server-url` to match.

If the server isn't reachable, opening a page in the browser fails in Emacs, before the request reaches the browser. Otherwise xwidget would show only a WebKit error page that doesn't say what went wrong.

### 4. Write your first page

Press `C-c n n` and enter a title to open a page buffer. Write the body, then save with `C-c C-c`.

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
| `l` | `enghi-task-log` | Write in a task's work log |
| `L` | `enghi-task-log-edit` | Edit an entry of a task's work log |
| `t` | `enghi-task-toggle` | Start or pause a task |
| `r` | `enghi-code-link` | Log a link to the code at point or the region |
| `R` | `enghi-code-link-with-comment` | The same, adding a comment first |

### Page buffer

`enghi-page-mode` runs on top of `markdown-mode`. The buffer holds plain Markdown.

| Key | |
|---|---|
| `C-c C-c` | Save |
| `C-c C-r` | Change title |
| `C-c C-t` | Edit tags |
| `C-c C-l` | Select a page and insert `[[link]]` |
| `C-c C-o` | Open in browser |
| `C-c C-k` | Revert to server content |

You can link to a page that doesn't exist yet, such as `[[non-existent page]]`. The link stays unresolved until you create a page with that name, and then connects automatically.

When you rename a page, the old title stays as an alias, so `[[old title]]` links in other pages keep working.

## Edit while viewing

While you view a page in webkit (for example, after `C-c n b`), press `E` to open the same page as an Emacs buffer in the lower window. You read in the top window and edit in the bottom one.

| Key | | |
|---|---|---|
| `E` | `enghi-xwidget-edit-page` | Edit the displayed page in the lower window |

The header line shows the keys you can use. They change with the view: a page shows keys like `E edit`, and a GTD list shows keys like `n next action` and `d done`.

In the GTD lists, `j` and `k` move the page's cursor as before. The keys that move a task ask their questions in the minibuffer instead of the page's modal. Select a row with `j`/`k`, then press:

| Key | Asks for | Result |
|---|---|---|
| `n` | Project (or `(none)`), and a context if contexts are on | Next action |
| `l` | Project (required) | Later |
| `w` | Who or what it waits for | Waiting For |
| `s` | Date (`org-read-date`), repeat rule, optional last date | Scheduled |
| `m` | — | Someday/Maybe |
| `x` | Confirmation | Dropped |
| `d` | — | Done (a recurring task gets its next instance) |
| `S` | — | Skip this instance of a recurring task |
| `t` | New title | Renamed |
| `f` | Page title and tags | Filed as a wiki page, which opens in the lower window |
| `RET` | — | Opens the task's detail page |

Each prompt defaults to the task's current value, and `C-g` cancels without changing anything. The change goes through the JSON API, and then the list reloads with the same row selected. For the repeat rule, pick one that fits the date (`+1w`, `weekly:fri`, `monthly:25`, …) or type any rule the server accepts.

On every enghi screen, `c` and `/` run in Emacs. `c` adds an item to the Inbox from the minibuffer with `enghi-capture`, and reloads the page on GTD screens. `/` searches from Emacs, as you type if consult is installed, and opens the chosen result in this view.

Other keys, such as `j` and `k`, go straight to the page.

The GTD top page (`/gtd`) has its own keys: `i` `n` `w` `s` `m` `p` open Inbox, Next Actions, Waiting For, Scheduled, Someday/Maybe and Projects.

When you save with `C-c C-c`, the server sends the update to every connected client. Any view showing that page reloads by itself and keeps its scroll position, so you don't need to refresh anything from Emacs.

Updates go out only when you save, not while you type.

## Save conflicts

If the page changed elsewhere while you were editing, `ediff` opens with the server version and your version side by side. Your edits stay in the buffer, so you can compare them and save again.

If you rename a page to a title that's already taken, Emacs shows the conflicting page and asks for another title. It keeps the body as is.

## Work log

Each GTD task has a work log: timestamped Markdown entries about what you tried, found and decided, plus start/pause marks. A task is *working* while its latest mark is a start. The server needs to be a version with the work log (after v0.2.0).

Every command below first asks for a task. Only open tasks are offered, working ones first and marked `▶`. The default is the task shown on a Clarify page (`/gtd/clarify/…`) in xwidget, otherwise the only working task.

| Command | |
|---|---|
| `enghi-task-log` | Open a buffer for a new entry |
| `enghi-task-log-edit` | Pick an entry (newest first) and edit it |
| `enghi-task-log-delete` | Pick an entry and delete it, after confirming |
| `enghi-task-start` / `enghi-task-pause` | Mark the task as started or paused. With `C-u`, add a one-line comment |
| `enghi-task-toggle` | Pause a working task, start any other |
| `enghi-code-link` | Log a link to the code at point or the region |
| `enghi-code-link-with-comment` | The same, but in a log buffer so you can add a comment |

Starting a task that's already working (or pausing one that isn't) changes nothing, and Emacs says so. With a comment, the comment is still logged as an entry.

### Log buffer

`enghi-log-mode` runs on top of `markdown-mode`, like a page buffer.

| Key | |
|---|---|
| `C-c C-c` | Send the entry and close the buffer. With `C-u`, then open the entry in the browser |
| `C-c C-k` | Discard (asks first if you wrote something) |
| `C-c C-l` | Select a page and insert `[[link]]` |
| `C-c C-o` | Open the task's page, at the entry when editing |
| `C-c C-d` | Delete the entry being edited |

An unsent entry stays in its buffer: `C-c n l` on the same task brings it back. If the entry was changed elsewhere while you edited it, the server version and yours open in `ediff`, as for pages.

### Code links

`enghi-code-link` replaces org-capture templates that note where you read code. From any file, it appends an entry like this to the task's log:

````markdown
[internal/web/server.go L120-134](https://github.com/you/repo/blob/3f2a…/internal/web/server.go#L120-L134)

```go
func (s *Server) routes() {
	…
}
```
````

- With a region, the link covers the region's lines and the code goes below it, with the common indentation removed. Without one, only the current line is linked.
- The path is relative to the project (or VC) root. The code block language comes from the major mode (`go-ts-mode` → `go`, `emacs-lisp-mode` → `elisp`).
- The URL comes from [browse-at-remote](https://github.com/rmuslimov/browse-at-remote) if it's installed. Set `browse-at-remote-prefer-symbolic` to `nil` to pin it to the commit instead of the branch. Without browse-at-remote, or when the file has no known remote, the path and lines are written as plain text.

Search finds entries of the work log too. They show as `Log` and open on the task's page at the entry.

## Browser integration

If you keep a browser open on another display, it can follow what you select in Emacs.

```
C-c n o
```

The server sends navigation events to every connected tab. If the server restarts, the browser reconnects automatically.

To view pages inside Emacs instead, change the browse function.

```elisp
(setq enghi-browse-function #'enghi-browse-in-xwidget)  ; Default is #'browse-url
```

`enghi-browse-in-xwidget` opens pages in xwidget webkit with some padding around the view. With `xwidget-webkit-browse-url`, the page touches the fringes and the mode line. Set the padding with `enghi-xwidget-padding`: an integer pads all four sides equally, and `(horizontal . vertical)` sets left/right and top/bottom separately. `0` fills the whole buffer. The padding applies only to buffers that `enghi` opens.

## Startup screen (dashboard.el)

`enghi-dashboard.el` adds an enghi section to the [dashboard](https://github.com/emacs-dashboard/emacs-dashboard) startup screen, in place of its agenda:

```
enghi:
    Inbox 3
    2 d. ago:   Pay the invoice
    Today:      Submit the report
    In 4 d.:    Renew passport
    Open the dashboard
```

- The Inbox count, emphasized when it isn't zero
- Today's tasks, with overdue deadlines first and marked
- Deadlines in the coming days (7 by default, `deadline_warning_days` on the server)

`RET` on a task opens it, on the Inbox opens the Inbox, and on the last line opens the web dashboard, all through `enghi-browse-function`. The section takes one request to `/api/dashboard`. If the server is down or doesn't answer within `enghi-dashboard-timeout` seconds, the section shows `enghi is not running` instead, and `RET` on that line tries again. A server older than the upcoming deadlines shows the rest.

```elisp
(use-package enghi-dashboard
  :after dashboard
  :config
  (add-to-list 'dashboard-items '(enghi . 5) t))
```

The number is the most tasks shown in each group. enghi.el itself doesn't need dashboard; only this file does.

## Configuration

| Variable | Default | |
|---|---|---|
| `enghi-server-url` | `http://127.0.0.1:7777` | Server URL |
| `enghi-request-timeout` | `10` | Request timeout (seconds) |
| `enghi-browse-function` | `#'browse-url` | Function to open in browser |
| `enghi-xwidget-padding` | `(24 . 12)` | Padding for `enghi-browse-in-xwidget`, in `(horizontal . vertical)` pixels |
| `enghi-consult-min-input` | `1` | Number of characters typed before search starts |
| `enghi-dashboard-timeout` | `2` | How long the startup screen section waits for the server (seconds) |
| `enghi-code-link-url-function` | `#'enghi--browse-at-remote-url` | Function returning the URL for a code link, or `nil` |

There are no passwords or tokens to set. The server accepts connections from loopback only.

## Development

```sh
make compile    # Byte-compile (warnings treated as errors)
```

Tests run against a live server, so start a test server on another port first.

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
| `enghi-log.el` | Work log of GTD tasks, code links |
| `enghi-consult.el` | Search using consult |
| `enghi-dashboard.el` | Section for the dashboard.el startup screen |
| `enghi-tests.el` | Tests |
