# Live board

The live board is an optional web page for one home that shows what is waiting on you, what is in flight, heads-up notes, what is queued, and what recently finished, and lets you answer what is waiting on you with a click.
It does not rebuild while nobody is asking for the page or its data, so a board left running with no one looking stays quiet.
Opening it shows the current records without waiting for a background timer.
While the page is open it keeps checking, reuses the last rebuild when the backlog, heads-up notes, secondmate registry, task metadata, and status logs are unchanged, and still fully rebuilds at least once a minute (or once per check, when checks are slower), so worker liveness, secondmate-home questions, and other inputs outside those files can lag up to that long while the page is open.
That age starts when the rebuild starts, so the next check is not early.
The page's update time is that check.
An in-flight card's checked time is the last full rebuild, which can be older when those records have not changed.
Answering always rebuilds after the write, so the page does not keep the question you just answered.
It says so plainly when updates stop (judged by the board's own clock, so a phone whose clock is off does not misreport it), and puts the number of items waiting on you in the browser tab title.
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
   `serve` refuses to start with `config/board-hosts` but no login listed, and without `config/board-logins` the board serves only direct requests from this computer.
3. Run `tailscale serve --bg --https=443 http://127.0.0.1:8795` with the board's port.

Use only the HTTPS proxy.
Never expose the board through Tailscale Funnel, which the board refuses outright, and never through a raw TCP forward, which would let a client forge the identity headers the login allowlist trusts.

## Answering from the board

Every task waiting on you shows answer buttons, Later, and Reply.
Yes and No are the default buttons; when the lead holds a task with `bin/fm-captain-hold.sh hold --option`, its declared choices replace them.
A button or a typed reply of up to 500 characters is recorded as your answer through the same keyed-answer intake that chat answers use, with the live board named as where it came from.
A question that only asked you something is closed with your answer.
Held work goes ahead only on Yes; No, a declared choice, or a typed reply is recorded and the work stays held until the lead acts on it, so declared choices are styled as neutral buttons rather than like Yes.
Until then it leaves Waiting on you for an "Answered - with" list that shows your answer and when you gave it, without buttons; if the lead asks you again, it returns to Waiting on you.
Later asks for a date, records it, and moves the item off the list until that day; it closes nothing.
If that date cannot be set, the card says so and the item waits with the lead under "Answered - with" instead.
If confirming that answer also fails, the request reports a failure rather than success; the work stays held, the already recorded Later does not regain answer buttons, and the lead still gets a note saying the outcome is uncertain.
If that note cannot be written, the response explicitly says the lead was not notified and asks you to mention it in chat.
Every confirmed answer also leaves the lead a captain inbox note, so it acts on your answer at its next turn.

A click is your recorded words and nothing more.
It never merges, starts, steers, or stops work by itself: the lead acts on it under the same approval rules as an answer you give in chat.
The card shows whether your answer is being recorded, was recorded, or was refused and why.
If the question changed after the page loaded, the click is refused and the card shows the new question; a re-ask that arrives while the answer is being written waits for it, so the click never lands on the new question.
If the response is lost, the page refreshes and checks the original click again: a saved confirmation reports the committed result without recording another answer or notifying the lead twice.
If confirmation is still unavailable, it says the answer may have been recorded and offers Refresh, never claims that nothing was recorded.
Confirmations survive a board restart; retrying an old click reports its original result and does not answer a newly asked question.
An old confirmation appears separately as a previous question's result; it never disables a re-asked question's buttons or discards its new reply draft.

Items the lead noted for you, and questions held in a second mate's home, appear without buttons; answer those in chat.
Questions you have left unanswered for two weeks move into a collapsed "Older questions still open" list, where they can still be answered.

## Threat model

The board can record your answers, so its endpoints are guarded against the ways another party could reach them:

- Another web page open in your browser cannot submit an answer: answers are accepted only as `POST` JSON whose `Origin` is the board's own origin, carrying a random token generated at each start and embedded only in the board's own page, and no response is ever readable by another origin.
- DNS rebinding cannot reach the board: every request whose host name is neither a loopback name nor listed in `config/board-hosts` is refused, the page and its data included.
- Other people on your tailnet cannot read or answer: a request needs an allowlisted `Tailscale-User-Login` header from `config/board-logins`, which `tailscale serve` sets and strips from clients, unless it is a direct loopback request carrying no proxy headers at all.
  Without that file every proxied request is refused, and `serve` will not start with extra host names in `config/board-hosts`.
- Nothing typed reaches a shell: request values are passed to the board's scripts only as separate arguments or on standard input, and a reply becomes one line.

Out of scope: anyone who can already run commands as you on this machine, and other accounts on a shared machine, which can reach a loopback port directly.
Run the board only on a machine you do not share.
A raw TCP forward can omit the proxy headers and look like a direct local request, which is why it must never be used.

## Verification

`tests/fm-board.test.sh` covers the rendered view, every request guard above, each answer kind landing through the intake with its wake, a declared choice keeping held work held, a re-ask racing an answer, failed Later recovery including notification failure, the stale and offline indicators against a skewed phone clock, the page handling a lost committed response while a new question is asked, restart-safe retries, an unchanged fleet not rebuilding on the page's check, a request after the full-rebuild bound still rebuilding, a check one interval later rebuilding when that bound matches the check interval, and a home that never starts the board staying untouched.
