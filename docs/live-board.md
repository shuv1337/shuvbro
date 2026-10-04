# Live board

The live board is an optional web page for one home that shows what is waiting on you, what is in flight, heads-up notes, what is queued, and what recently finished, and lets you answer what is waiting on you with a click.
It rebuilds itself every few seconds, says so plainly when updates stop, and puts the number of items waiting on you in the browser tab title.
A home that never starts it behaves exactly as before.

## Start it

`bin/fm-board.sh serve` runs the board for the active `FM_HOME` in the foreground at `http://127.0.0.1:8795/`.
It listens on the loopback interface only, never on a network address.
Each home on one host needs its own port, set in `config/board-port` or `FM_BOARD_PORT`.
`bin/fm-board.sh status` says whether this home's board is answering, and `serve` refuses to start a second board for a home that already has one.
`bin/fm-board.sh unit` prints a systemd user unit that keeps the board running; save it under `~/.config/systemd/user/` and enable it yourself.
The board needs `node` and `jq` beyond the usual toolbelt, and it adds no npm dependency.
[Configuration](configuration.md#live-board-configboard-port-configboard-hosts-configboard-logins-databoard-notesjson) owns the schema of every file named here.

The page is rendered only from `bin/fm-fleet-snapshot.sh --json` and the lead's curated `data/board-notes.json`, so it shows exactly what the fleet records say and never reads state files of its own.
A worker's own latest note stays behind a "Latest note from the worker" disclosure because it is raw.

## Reach it from your phone

Expose it over your tailnet with Tailscale's HTTPS proxy:

1. Write this machine's tailnet name, for example `host.example.ts.net`, into `config/board-hosts`, so the board accepts requests addressed to it.
2. Write your own Tailscale login into `config/board-logins`, so nobody else on your tailnet can read or answer.
3. Run `tailscale serve --bg --https=443 http://127.0.0.1:8795` with the board's port.

Use only the HTTPS proxy.
Never expose the board through Tailscale Funnel, which the board refuses outright, and never through a raw TCP forward, which would let a client forge the identity headers the login allowlist trusts.

## Answering from the board

Every task waiting on you shows answer buttons, Later, and Reply.
Yes and No are the default buttons; when the lead holds a task with `bin/fm-captain-hold.sh hold --option`, its declared choices replace them.
A button or a typed reply of up to 500 characters is recorded as your answer through the same keyed-answer intake that chat answers use, with the live board named as where it came from.
A question that only asked you something is closed with your answer.
Held work goes ahead only on Yes or one of its declared choices; No or a typed reply is recorded and the work stays held until the lead acts on it.
Later asks for a date, records it, and moves the item off the list until that day; it closes nothing.
Every recorded answer also leaves the lead a captain inbox note, so it acts on your answer at its next turn.

A click is your recorded words and nothing more.
It never merges, starts, steers, or stops work by itself: the lead acts on it under the same approval rules as an answer you give in chat.
The card shows whether your answer is being recorded, was recorded, or was refused and why.
If the question changed after the page loaded, the click is refused and the card shows the new question.

Items the lead noted for you, and questions held in a second mate's home, appear without buttons; answer those in chat.
Questions you have left unanswered for two weeks move into a collapsed "Older questions still open" list, where they can still be answered.

## Threat model

The board can record your answers, so its endpoints are guarded against the ways another party could reach them:

- Another web page open in your browser cannot submit an answer: answers are accepted only as `POST` JSON whose `Origin` is the board's own origin, carrying a random token generated at each start and embedded only in the board's own page, and no response is ever readable by another origin.
- DNS rebinding cannot reach the board: every request whose host name is neither a loopback name nor listed in `config/board-hosts` is refused, the page and its data included.
- Other people on your tailnet cannot read or answer once `config/board-logins` lists your login: a request needs that `Tailscale-User-Login` header, which `tailscale serve` sets and strips from clients, unless it is a direct loopback request carrying no proxy headers at all.
- Nothing typed reaches a shell: request values are passed to the board's scripts only as separate arguments or on standard input, and a reply becomes one line.

Out of scope: anyone who can already run commands as you on this machine, and other accounts on a shared machine, which can reach a loopback port directly.
Run the board only on a machine you do not share.
Without `config/board-logins`, everyone your tailnet shares this machine with can read the board and answer from it.

## Verification

`tests/fm-board.test.sh` covers the rendered view, every request guard above, each answer kind landing through the intake with its wake, and a home that never starts the board staying untouched.
