# Declutter

Declutter hides ads, cookie banners, newsletter boxes, promotions and share buttons on the page in
the window. TypeSafe's Jev model labels short descriptions of page elements, and webkit95 hides the
ones labeled as clutter with high confidence. The design follows kitze/unclutter (MIT, see
THIRD_PARTY_NOTICES.md).

Declutter hides clutter cosmetically after the page loads. It does not block or cancel ad or
tracker requests, and hiding a cookie banner does not accept or reject anything.

## Using it

All three commands are in the View menu, in the drawn menu bar and the macOS menu bar.

- **Declutter Page** (Cmd+Shift+D) declutters the page once. The status bar shows
  "Decluttering..." with the progress panel, then "Decluttered: hid N elements" or "Nothing to
  hide". A result from a saved template ends in "(saved template)".
- **Undo Declutter** shows everything again and removes every trace from the page.
- **Auto Declutter This Site** is a check item. While it is on for a host, every page from that
  host is decluttered after it finishes loading.

The first Declutter shows a message box that says what is sent and to whom. OK saves the consent
and continues. Cancel, the default button, does nothing. Auto Declutter never asks. It runs only on
hosts turned on after consent.

Declutter skips a page and says so in the status bar when the page is a webkit95 page, about:blank
or anything but http and https, when the page has any password input (a login page), or when it
has a payment form (card number or CVC fields). A skipped page sends nothing.

## What is sent, and to whom

One `POST https://api.typesafe.ai/v1/systemone` per page template, with `model: "jev-latest"`.
The body holds, for up to 60 elements:

- `id`: `c` plus a hash of the element's local selector. The selector itself is not sent.
- `tag`: the element's tag name, for example `div` or `aside`.
- `signals`: the element's id, class names, aria-label, title, data-testid and data-component, at
  most 300 characters.
- `text`: the element's visible text, at most 450 characters. Form fields, option lists, scripts
  and editable areas are left out.
- `position`: its CSS position, for example `static` or `fixed`.
- `count`: how many elements share its selector.
- `pageType`: home, article, product, search, listing or page.

It also holds one choice question per element, with Unclutter's instructions and the seven labels
keep, ad, promotion, newsletter, social, cookie and uncertain.

It never sends the page address, query string, title, the main article text, form values, cookies
or raw HTML. In element text and signals, URLs become `[URL]`, email addresses `[email]` and runs of
eight or more digits `[number]`. That is redaction of the obvious, not a promise of anonymity:
short snippets of page text do leave the machine.

Protected elements are never sent at all (see Protections), so the article body, the navigation,
forms and login boxes stay local.

## The key

- The key is read from `TYPESAFE_API_KEY`, else `JEV_KEY`, in the app's environment.
- If neither is set, webkit95 runs your login shell once per launch (`zsh -lic`, 4 second limit,
  output between random markers, profile noise ignored), the same way it finds fx on your PATH,
  and reads the variable from there. Apps started from the Dock or Finder do not get your shell's
  variables, so this is how they find the key.
- The key stays in memory. It is never written to disk, never logged, never shown in a message
  and never passed to the page.
- It is sent only as `Authorization: Bearer <key>` to `https://api.typesafe.ai`. The request uses
  an ephemeral URLSession without cookies, cache or stored credentials, and redirects are refused,
  so the header never follows a redirect to another host. A reply from any other host is an error.
- Without a key, Declutter shows "Set TYPESAFE_API_KEY in your shell profile and relaunch."

Debug builds accept `WEBKIT95_JEV_URL` to point at a local fake server
(`scripts/fakejev.py`), but only on a loopback host, and while it is set the login shell probe is
off, so the real key in your profile cannot reach the fake. `WEBKIT95_JEV_TIMEOUT` (debug only)
shortens the 20 second request timeout for tests. Release builds ignore both and always use
`https://api.typesafe.ai/v1/systemone`.

## How decisions become hidden elements

1. The extractor runs in its own WebKit content world (`webkit95-declutter`), so page scripts
   cannot see it, change the DOM methods it calls, or read its saved state. It proposes elements
   the way Unclutter does: dialogs and cookie or consent containers first, then `aside`, `section`,
   `div` and `iframe` elements whose identity matches a clutter word (ad, sponsor, promo, banner,
   newsletter, subscribe, popup, modal, overlay, share, social, related, cookie, consent and so on),
   asides, dialogs, iframes and fixed or sticky elements.
2. For each it derives a stable selector from attributes that survive a reload: `tag[data-testid]`
   (also data-component, data-test, data-qa), `tag#id`, `tag.class`, or a consent vendor prefix
   like `div[id^="sp_message_container_"]`. Values with 4 digit runs, 8 hex characters or CSS in JS
   prefixes are not stable. A selector must match the element and at most 20 elements.
3. It records facts about each element: whether it is or contains the main content, navigation,
   a site header, the largest text block, most of the page's text, a form and its kind, focus, a
   login, payment or security dialog, paywall markers or sensitive inputs.
4. Swift (`Webkit95Kit/Declutter.swift`) drops protected elements, bounds and redacts the fields,
   and keeps at most 60.
5. Jev answers with a label, the probability of each label and a confidence per element. An
   element is hidden only for ad, promotion, newsletter, social or cookie, and only when both the
   chosen label's probability and the confidence are at least 0.9. An unknown label reads as
   uncertain, a missing or out of range number keeps the element, and answers for ids that were not
   asked or that appear twice are ignored.
6. The model's output is only ever a label on an id webkit95 chose. It never picks a selector and
   nothing it says is executed, so page text that tries to steer the model can at most change a
   label on one of the proposed elements.
7. Before hiding, the extractor measures every element each rule matches on the live page (its
   frame inside the window, its position, its facts, and which other matched element contains it).
   The guard then judges each rule on its own: a rule is dropped if it matches nothing, more than
   20 elements, or any protected element, and skipped as too large if one of its in flow elements
   alone covers more than 40 percent of the window. An ad labeled element with at most 50
   characters of text is exempt from that limit: an empty or reserved ad slot is not content
   however big its box is (bbc.com's top billboard is 42 percent of a 1088 by 652 window). Fixed
   and sticky elements are overlays that cover the content rather than being it, so they are
   exempt too, whatever their label; the protections still apply to them.
8. Then the backstop on the rules that remain: if together they would hide more than half of the
   window, counting the union of their in flow frames so that a wrapper and the slot inside it
   count once, or more than 35 percent of the page's text (an element inside another hidden
   element is not counted again), nothing is hidden and the status bar says so. Otherwise the
   status bar reports what happened, for example "Decluttered: hid 9 elements (skipped 1 too
   large)".
9. Hiding marks each element with a random `data-webkit95-declutter-*` attribute, adds one owned
   style element, and sets `display: none !important` inline. When the hidden elements include a
   cookie wall or another fixed overlay and no other visible dialog (a login box) is open, the
   `overflow: hidden` scroll lock on `html` and `body` is released the same way.
10. Undo removes the attribute and the style element and puts back each touched element's style
    attribute exactly as it was (or removes it if there was none). Every run starts with that undo,
    so running Declutter twice on a page gives the same result as running it once.

### The debug table

In a debug build, `WEBKIT95_DECLUTTER_DEBUG=1` makes every run log the guard's reasoning, one line
per rule, and adds the page measurement to the control socket's `state` (`declutter.last.measure`
and `declutter.last.table`). A line looks like

```
div[data-testid="ad-unit"] ad p0.97 c0.93 -> hide [flow 41.9% t14, flow 0.0% t0, ...]
section.promo-hero promotion -> skipped, too large (45.0%) [flow 45.0% t210]
union 42.3% of the window, 0.3% of the text -> hide 9 rules, skipped 1
```

with the selector, the label, Jev's probability and confidence when the run called Jev, the
verdict, and per element whether it is in flow or an overlay, its share of the window, its text
length, the index of the matched element containing it and any protection reason. Page text never
appears. Release builds ignore the variable, and the control socket does not exist in them. The
verdicts alone (`declutter.last.verdicts`) are always in the state.

## Protections

Never hidden and never sent: `html`, `body`, `main`, `article` and `role=main` elements and
anything containing them; navigation and anything inside it; a header that holds the site
navigation; the element with the largest block of text and anything containing it; an element
holding more than half of the page's text, more than 2000 characters, or a paragraph over 600
characters; ordinary forms (search, comments, login, checkout, settings: anything but a single
email signup field or, inside a cookie notice, checkboxes only); the focused element; dialogs about
login, payment or security; paywall, sign in, captcha, checkout and payment markers; and password
or card inputs.

## The template cache

Decisions are saved per page template in `declutter-templates.json` in the support directory
(`~/Library/Application Support/webkit95`, or `WEBKIT95_SUPPORT_DIR`). The key combines:

- the exact origin (scheme, host and an explicit port),
- the policy version,
- the page kind (home, article, product, search, listing, page),
- the route family: numeric and long hex path segments become `:id`; for articles and products,
  date segments go and the last segment becomes `:detail`; for other pages a last segment of four
  or more dash separated words becomes `:detail`; query values are ignored, and the names of
  query parameters count except tracking ones (`utm_*`, `fbclid`, `gclid` and similar),
- a main shell marker: the main element's data-component, data-testid or tag, and whether the page
  has an article.

So `/news/2026/09/30/city-council-approves-new-park.html` and
`/news/2026/09/29/library-extends-weekend-hours.html` on the same site share `/news/:detail`, and
the second one is decluttered from the cache without an API call. Results with nothing to hide are
cached too. The cache is versioned, written atomically, holds at most 500 templates (least recently
used first out), and a corrupt or unknown file starts fresh. Saved selectors are checked against the
selector grammar when the file is read and again against the live page before hiding.

The cache stores origins and route families, which is a partial browsing history. It stays on this
Mac, like the typed address list.

## Errors

Each is a Windows 95 message box. Nothing is hidden, and the app never hangs: the request times out
after 20 seconds.

| Cause | Message |
| --- | --- |
| No key | webkit95 found no TypeSafe API key, so it cannot declutter this page. Set TYPESAFE_API_KEY in your shell profile and relaunch. |
| 401 or 403 | TypeSafe rejected the API key (HTTP 401). Nothing was hidden. Check TYPESAFE_API_KEY in your shell profile and relaunch. |
| 429 or 529 | TypeSafe is busy right now (HTTP 429). Nothing was hidden. Try again in a moment. |
| Other HTTP errors | api.typesafe.ai answered with an error (HTTP 500). Nothing was hidden. |
| Redirect or another host | api.typesafe.ai tried to send webkit95 somewhere else. webkit95 did not follow, and nothing was hidden. |
| Network | webkit95 could not reach api.typesafe.ai. Nothing was hidden. (and the system's reason) |
| Timeout | api.typesafe.ai did not answer in time. Nothing was hidden. |
| Unreadable body | api.typesafe.ai sent an answer webkit95 could not read. Nothing was hidden. |
| Body over 1 MB | api.typesafe.ai sent an answer that was too large. Nothing was hidden. |

## The wire, as observed

The request and answer shapes in Unclutter's README and lib/jev.ts and in TypeSafe's API reference
(docs.typesafe.ai/api.md) matched the real API on 2026-09-30, so nothing had to change. Answers
came from `jev-1.13.0` (what `jev-latest` points to) with `answers.<id>.{type, choice,
probabilities, confidence}` and `usage.{input_tokens, output_tokens}`. There is no cost field.
TypeSafe's models page lists Jev 1.13 at 0.042 USD per million input tokens, with output tokens
free.

## Real evaluation, 2026-09-30

Ten real calls in total, on synthetic pages served from loopback and three public pages, through
`scripts/declutter-eval.py`. The app ran without the key in its environment, so each run found it
through the login shell probe. Protected lost counts visible `main`, `article`, `nav`, `header`,
`h1`, ordinary forms, `textarea`, search and password inputs and the largest paragraph before and
after, and it was zero on every page.

| Page | Candidates | Result | Protected lost | Visible text | Latency | Request / answer | Tokens in / out |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Synthetic news article (ads, cookie banner, newsletter popup, share bar, promo, sign in box, comments) | 7 | hid 6: newsletter, cookie, social, ad, promotion, sidebar ad; mixed sidebar uncertain and kept | 0 | 2532 to 2040 | 0.33 to 0.38 s | 11.2 KB / 1.3 KB | 3117 / 493 |
| Synthetic ad heavy deals page | 9 | hid 6 blocks (8 rules); an "outbrain" widget at 0.78 kept | 0 | 1320 to 1038 | 0.28 s | 14.0 KB / 1.7 KB | 3869 / 629 |
| Synthetic clean blog post | 1 | nothing to hide (pull quote: keep 0.99) | 0 | unchanged | 0.34 s | 1.7 KB / 0.3 KB | 681 / 73 |
| Synthetic cookie wall (fixed overlay, scroll lock) | 2 | first run refused by the text guard (57 percent); after the fix, hid 1 and released the scroll lock | 0 | 991 to 700 | 0.22 to 0.26 s | 3.8 KB / 0.4 KB | 1182 / 144 |
| Synthetic login page (password field) | 0 | skipped, no call | 0 | unchanged | none | none | none |
| allrecipes.com recipe | 60 | hid 13 blocks (17 rules): OneTrust banner, leaderboard and native ads, video ad layers, newsletter and promo toasts, share and rating bars | 0 | 17489 to 17412 | 0.52 to 0.65 s | 95 KB / 10.9 KB | 24950 to 25344 / 4180 |
| bbc.com/news/technology | 14 | 12 rules: seven dotcom ad slots, ad unit, advertisement block, two social follow widgets, a fixed backdrop labeled cookie | 0 | 7594 to 7579 | 0.33 s | 21.5 KB / 2.5 KB | 5944 / 977 |
| en.wikipedia.org/wiki/Web_browser | 3 | nothing to hide (best guess 0.83, under the threshold) | 0 | unchanged | 0.26 s | 4.7 KB / 0.6 KB | 1461 / 209 |

All ten calls used about 71,000 input tokens, about 0.003 USD at the listed price.

What the real run changed:

- The text guard now counts only in flow elements, like the area guard. A cookie wall's text
  outweighed the short article under it, so the guard refused to hide it.
- Unclutter's cookie test matches "cookie" anywhere, so allrecipes' "chocolate-chip-cookies"
  heading spans were sent as "Cookie consent overlay" candidates (Jev kept them). A cookie notice
  now needs a consent vendor word, or "cookie" on an overlay or a banner-like container, and the
  priority candidates are containers and overlays only. The smoke checks that such a span is never
  sent.

Judgment calls worth a look: allrecipes' "rate this recipe" bar was labeled social and hidden, and
a BBC drawer backdrop was labeled cookie (0.91) and hidden. Neither is protected content.

## The bbc.com refusal, fixed 2026-09-30

A user pressed Declutter on bbc.com and got "Declutter stopped: it would hide 68% of the window, so
nothing was hidden". Reproduced with the shipped build and one real call, at 1100 by 800 the same
page refused at 128 percent. The page world measurement of the 17 rules showed one box: the top
billboard ad container, 41.9 percent of the window, matched by `div[data-testid="ad-unit"]`,
`div[data-testid="dotcom-top"]` and `div.dotcom-ad-inner`, nested three deep, plus
`div.dotcom-ad-text-wrapper` at 3.5 percent inside it. The guard summed every matched element, so
one ad counted three times: 41.9 x 3 + 3.5 = 128.6. At the user's larger window the same ad is
about 23 percent, and 3 x 22.7 is the 68 they saw. Every other match was off screen or empty, and
nothing protected or main content was involved. Jev's labels were right.

The guard now judges each rule on its own and counts the union (steps 7 and 8 above). The proposed
blind per element limit was checked against the real data before it was adopted: the genuine
billboard is 41.9 percent of a small window on the home page and 44.1 percent on the news section,
so a plain 40 percent skip would have left the biggest ad on the page visible. The limit therefore
exempts ad labeled elements with almost no text (the slot says "Advertisement", 13 characters), which
is what Jev is told to label ad even when empty. A big block with text is still skipped on its own,
and the aggregate backstop still refuses when the remainder is too large.

| Page | Before (shipped build) | After (fixed build) | Union | Old sum | Calls |
| --- | --- | --- | --- | --- | --- |
| bbc.com home, first variant | refused at 128% | hid 14 elements (rerun from the saved template) | 17.7% | 55.7% | 1 then 0 |
| bbc.com home, second variant | | hid 14 elements: 15 ad rules, 2 social follow widgets | 17.7% | 55.7% | 1 |
| bbc.com/news | | hid 6 elements: 8 ad rules, 2 social follow widgets | 44.1% | 133.1% | 1 |
| bbc.com/news/technology (redirects to /technology, same template as /news) | | hid 9 elements (saved template) | 8.8% | 27.1% | 0 |

Protected lost was zero on every page (main, article, nav, header, h1, forms, largest paragraph), and
the screenshots (`build/shots/bbc-*-before-1x.png` and `-after-1x.png`) show the billboard gone
with the header, the navigation and every headline in place. The "BBC subscribers" bar at the
bottom stays on every page because Jev labels it keep (0.95 to 0.97); the two drawer backdrops
were labeled cookie under the threshold (0.19 to 0.88) and stay too. Three real calls in all.

The three runs that called Jev are regression fixtures in `Tests/Webkit95KitTests/Resources/declutter`
(public structure only: selectors, tags, class and test id tokens cut to 80 characters, the answers,
and the measurement with no text), replayed by `ReplayTests` through the parser, the rules and the
guard. Each asserts the guard hides the ads and social widgets, hides nothing protected, stays under
the backstop, and that the old sum would have refused. `scripts/declutter-fixture.py` writes one from
a control socket state dump or an eval row (`WEBKIT95_DECLUTTER_DEBUG=1` for the measurement).

Known weakness left in place: the fractions are shares of the window, so the same billboard is 18
to 44 percent depending on the creative served and the window size. In a window short enough for
one empty slot to pass half the height, the backstop still refuses the whole page.

## Limits

- Cosmetic only: ad and tracker requests still happen. A network level blocker is a separate item
  in docs/STATUS.md.
- Main frame only. Cross origin iframes and shadow DOM are not looked into (an iframe element can
  still be hidden as a whole).
- Late loaded clutter is not rechecked. Unclutter watches the DOM; webkit95 runs once after load
  (Auto) or when asked.
- A saved template is reused until the policy version changes. There is no re-analyze command yet,
  so a site redesign can leave stale rules (they are revalidated, so the risk is hiding too little,
  not hiding the wrong thing).
- Pages with a hidden login modal (a password input in the DOM) are skipped.
- Single page apps that change the address without a load keep the previous page's hiding.
- The guard's fractions are shares of the window, so a small window makes one billboard ad a
  large share; the backstop can still refuse a page whose one empty slot passes half the window.

## Where the code is

- `Sources/Webkit95Kit/Declutter.swift`: policy, labels, stable selectors, element facts and
  protections, candidates, the request body, the response parser, hide rules, the hide guard (per
  rule verdicts, the union of frames, the review and the debug table), template keys, the cache,
  sites and consent, failures and status texts, the endpoint, the key and the client over a
  transport protocol. Tested in `Tests/Webkit95KitTests/DeclutterTests.swift`, with the real page
  fixtures in `Tests/Webkit95KitTests/Resources/declutter`.
- `scripts/declutter-eval.py`: the real evaluation (`DECLUTTER_REAL=1`), with a kept support dir,
  screenshots and the debug table; `scripts/declutter-fixture.py` turns a run into a fixture.
- `Sources/webkit95/DeclutterScript.swift`: the extractor, measurer, applier and undo, run with
  `callAsyncJavaScript` in the `webkit95-declutter` content world.
- `Sources/webkit95/Declutter.swift`: the URLSession transport, the app wide service (key, cache,
  sites, consent) and each window's runner.
- `scripts/fakejev.py`: a fake System One endpoint for the smoke checks and screenshots.
- `scripts/smoke-declutter.sh`: the declutter smoke checks (`SMOKE_ONLY=declutter scripts/smoke.sh`).
