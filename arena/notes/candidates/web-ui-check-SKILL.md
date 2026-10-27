---
name: web-ui-check
description: "Use when building or fixing a web page, canvas/WebGL/three.js app, game or other UI in HTML/JS. You cannot see the screen: this is how to verify it with numbers instead of screenshots, and when to stop."
---

# Checking a UI you cannot see

Screenshots do not help you: counting pixels cannot tell you if a page looks or feels right, and it never ends.
Check what text can prove, then hand the look and feel to the user.

## 1. Write the done-list first
Before coding, turn the request into 5-10 checks, each a number or true/false that the page can report, e.g.
`no errors`, `5 bears exist`, `drag head up 200px -> stretch > 0.3`, `2 s after release -> back within 5% of rest`,
`pour -> bear count grows`, `no NaN positions`, `no two bodies overlap`. Things only a person can judge (looks, feel,
colors, smoothness) go on a separate "for the user" list. When every check passes, you are done.

## 2. Make the page report itself
Add a hook that runs only with `?check` in the URL. Keep it in the file; it costs nothing for users.
```js
if (location.search.includes('check')) {
  const errors = [];
  addEventListener('error', e => errors.push(e.message + ' @' + e.lineno));
  addEventListener('unhandledrejection', e => errors.push(String(e.reason)));
  setTimeout(async () => {
    const r = { errors };
    try { /* drive the app: call your own functions or dispatch pointer events, wait, read state */ }
    catch (e) { r.errors.push('check: ' + e.message); }
    const pre = document.createElement('pre'); pre.id = 'check';
    pre.textContent = JSON.stringify(r); document.body.append(pre);
  }, 1500);
}
```
Drive interactions through the same code paths a user hits (the pointer handlers, the button's click()), and step the
simulation with real time or by calling its step function in a loop. Report numbers, not prose.

## 3. Run it headless (works inside awl's sandbox)
```sh
P=$(mktemp -d); timeout 60 chromium --headless=new --no-sandbox --disable-gpu-sandbox --use-gl=angle \
  --use-angle=swiftshader --enable-unsafe-swiftshader --user-data-dir="$P" --window-size=1280,800 \
  --virtual-time-budget=8000 --dump-dom "file://$PWD/index.html?check" 2>"$P/err" | grep -o '<pre id="check">.*</pre>'
grep -E 'Uncaught|Error' "$P/err" | grep -v -E 'dbus|crashpad|gcm|viz' | head
```
A fresh `--user-data-dir` is required (the home folder is read-only). `--virtual-time-budget` fast-forwards timers;
raise it if the check needs more simulated time. CDN scripts need the network (on unless AWL_SANDBOX_NET=off).
If nothing prints, the page threw before the hook ran: look at the err file.

## 4. Pure logic outside the browser
If physics/game logic does not touch the DOM, `node -e` it: run 1000 steps, check energy falls, nothing goes NaN.

## 5. Stop
One screenshot at most, only to rule out a blank page. When the done-list passes, stop polishing. End with: the checks
and their numbers, then the "for the user" list (what to open and look at).
