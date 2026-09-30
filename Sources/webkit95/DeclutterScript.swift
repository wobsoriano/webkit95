import WebKit

/// The page side of Declutter. It runs in its own content world, so page scripts cannot see it,
/// replace the DOM methods it calls, or read its saved state. It gathers facts and hides what
/// Swift tells it to; Webkit95Kit decides what is sent, what is protected and what is hidden.
/// Extraction, the selector grammar and the reversible hiding follow kitze/unclutter's lib/dom.ts
/// and lib/page-context.ts (MIT).
@MainActor
enum DeclutterScript {
    static let world = WKContentWorld.world(name: "webkit95-declutter")

    /// Each call ships the whole library, so a page loaded before the first run needs no setup.
    /// State that Undo needs lives on the world's own global object.
    static func call(_ webView: WKWebView, _ expression: String, arguments: [String: Any] = [:]) async throws -> Data {
        let body = library + "\nreturn JSON.stringify(" + expression + ");"
        let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
        guard let text = result as? String else { throw DeclutterScriptError.noResult }
        return Data(text.utf8)
    }

    static let library = #"""
    const S = globalThis.__webkit95Declutter ??= {
      attr: 'data-webkit95-declutter-' + Math.random().toString(36).slice(2, 10),
      saved: new Map(),
      style: null,
    };
    const clutter = /(?:^|[-_\s])(?:ad|ads|advert|advertisement|advertising|sponsor|sponsored|promo|promotion|banner|newsletter|subscribe|subscription|upsell|popup|modal|overlay|share|social|recommendations|related|cookie|consent)(?:$|[-_\s])/i;
    const consentPrefixes = ['sp_message_container_', 'sp_message_iframe_'];
    const grammar = /^[a-z][a-z0-9-]*(?:\[data-(?:testid|component|test|qa)="[\w-]{3,89}"\]|#[\w-]{3,89}|\.[\w-]{3,89})$|^(?:div|iframe)\[id\^="(?:sp_message_container_|sp_message_iframe_)"\]$/;
    const sensitiveInput = 'input[type="password" i],input[autocomplete^="cc-" i],input[name*="cardnumber" i],input[name*="card_number" i],input[name*="card-number" i],input[name*="cvv" i],input[name*="cvc" i],input[id*="cardnumber" i],input[id*="card-number" i],input[id*="cvv" i],input[id*="cvc" i]';
    const paymentInput = 'input[autocomplete^="cc-" i],input[name*="cardnumber" i],input[name*="card_number" i],input[name*="card-number" i],input[name*="cvv" i],input[name*="cvc" i],input[id*="cardnumber" i],input[id*="card-number" i],input[id*="cvv" i],input[id*="cvc" i]';
    const dialogs = 'dialog,[role="dialog"],[role="alertdialog"],[aria-modal="true"]';
    const nav = 'nav,[role="navigation"]';
    const skipText = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'SVG', 'TEXTAREA', 'SELECT', 'OPTION', 'INPUT', 'TEMPLATE']);

    const stable = (v) => v.length >= 3 && v.length < 90 && /^[a-zA-Z_][\w-]*$/.test(v) && !/\d{4}|[a-f0-9]{8}|^(css|sc|jsx)-/i.test(v);
    const identity = (el) => `${el.id} ${el.getAttribute('class') ?? ''} ${el.getAttribute('aria-label') ?? ''} ${el.getAttribute('title') ?? ''} ${el.getAttribute('data-testid') ?? ''} ${el.getAttribute('data-component') ?? ''}`;
    const squash = (t) => t.replace(/\s+/g, ' ').trim();

    // Visible words without form values, scripts or option lists, and without cloning (a cloned
    // img would start loading).
    function textOf(el, limit = Infinity) {
      let out = '';
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode: (n) => n.nodeType === 1 && (skipText.has(n.nodeName.toUpperCase()) || n.isContentEditable)
          ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
      });
      while (walker.nextNode()) {
        const n = walker.currentNode;
        if (n.nodeType === 3) {
          out += n.nodeValue + ' ';
          if (out.length > limit * 2 + 200) break;
        }
      }
      return squash(out).slice(0, limit);
    }

    // Unclutter matches "cookie" anywhere, which also catches a recipe's "chocolate-chip-cookies"
    // headings; a bare cookie word counts only on an overlay or a banner-like container.
    function isCookieNotice(el) {
      if (consentPrefixes.some((p) => el.id.startsWith(p))) return true;
      const name = identity(el);
      if (/consent|onetrust|didomi|cookiebot|usercentrics|truste|quantcast|privacy[-_ ]?(?:manager|modal|dialog|banner)/i.test(name)) return true;
      const overlay = el.matches('dialog,[role="dialog"],[role="alertdialog"],[aria-modal="true"]') || /fixed|sticky/.test(getComputedStyle(el).position);
      if (/cookie/i.test(name) && (overlay || /banner|notice|bar|popup|modal|dialog|overlay|prompt|wall|law/i.test(name))) return true;
      if (!el.matches('[role="dialog"],[aria-modal="true"]')) return false;
      const t = el.textContent ?? '';
      return /cookies|consent|privacy choices/i.test(t) && /accept|reject|agree|manage|preferences/i.test(t);
    }

    function formKind(form) {
      const fields = [...form.querySelectorAll('input,textarea,select,[contenteditable="true"]')]
        .filter((f) => (f.getAttribute('type') ?? '').toLowerCase() !== 'hidden');
      const entry = fields.filter((f) => f.matches('textarea,select,[contenteditable="true"]')
        || !['checkbox', 'radio', 'button', 'submit', 'reset', 'image'].includes((f.getAttribute('type') ?? 'text').toLowerCase()));
      if (!entry.length) return 'choicesOnly';
      if (entry.length === 1 && entry[0].matches('input')) {
        const f = entry[0];
        const words = `${f.name} ${f.id} ${f.getAttribute('placeholder') ?? ''} ${f.getAttribute('autocomplete') ?? ''}`;
        const email = (f.getAttribute('type') ?? '').toLowerCase() === 'email' || /e-?mail/i.test(words);
        if (email && !/user|login|log-in|signin|sign-in|current-password/i.test(words)) return 'subscription';
      }
      return 'ordinary';
    }

    function isSensitiveDialog(d) {
      if (d.querySelector(sensitiveInput)) return true;
      const heading = d.querySelector('h1,h2,h3,legend');
      const label = `${identity(d)} ${heading ? heading.textContent : ''}`;
      return /log[-_ ]?in|sign[-_ ]?in|password|payment|checkout|billing|security|two[-_ ]?factor|2fa|captcha|verify/i.test(label);
    }

    function pageContext() {
      const body = document.body;
      const bodyText = body ? textOf(body).length : 0;
      let largest = null, best = 0, seen = 0;
      for (const el of document.querySelectorAll('p,li,blockquote,pre,td,dd,div,section,article')) {
        if (++seen > 5000) break;
        let own = 0;
        for (const n of el.childNodes) if (n.nodeType === 3) own += n.nodeValue.trim().length;
        if (own > best) { best = own; largest = el; }
      }
      return { bodyText: Math.max(bodyText, 1), largest };
    }

    function facts(el, ctx) {
      const text = textOf(el).length;
      const forms = [...el.querySelectorAll('form')].slice(0, 20);
      const outer = el.closest('form');
      if (outer) forms.push(outer);
      const active = document.activeElement;
      const dialog = el.closest(dialogs);
      const inner = [...el.querySelectorAll(dialogs)].slice(0, 20);
      let longest = 0;
      for (const p of [...el.querySelectorAll('p')].slice(0, 200)) longest = Math.max(longest, (p.textContent ?? '').length);
      if (el.matches('p')) longest = Math.max(longest, (el.textContent ?? '').length);
      const marker = /paywall|sign[-_ ]?in|log[-_ ]?in|captcha|checkout|payment/i.test(identity(el))
        || /sign in to continue|subscribe to (?:read|continue)|verify you are human/i.test(textOf(el, 4000));
      return {
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') ?? '',
        isRoot: el.matches('html,body,main,article,[role="main"]'),
        containsMain: !!el.querySelector('main,article,[role="main"]'),
        isNavigation: el.matches(nav) || !!el.querySelector(nav) || !!el.closest(nav),
        isHeaderWithNav: el.matches('header,[role="banner"]') && !!el.querySelector(nav),
        containsLargestTextBlock: !!ctx.largest && el.contains(ctx.largest),
        textShare: Math.min(1, text / ctx.bodyText),
        textLength: text,
        longestParagraph: longest,
        forms: [...new Set(forms)].map(formKind),
        containsFocus: !!active && active !== document.body && active !== document.documentElement && el.contains(active),
        inSensitiveDialog: (!!dialog && isSensitiveDialog(dialog)) || inner.some(isSensitiveDialog),
        hasPaywallMarker: marker,
        hasSensitiveInput: el.matches(sensitiveInput) || !!el.querySelector(sensitiveInput),
        isCookieNotice: isCookieNotice(el),
      };
    }

    function matches(selector) {
      if (!grammar.test(selector)) return [];
      try { return [...document.querySelectorAll(selector)]; } catch { return []; }
    }

    function selectorFor(el, limit) {
      const tag = el.tagName.toLowerCase();
      const options = [];
      const prefix = consentPrefixes.find((p) => el.id.startsWith(p));
      if (prefix && (tag === 'div' || tag === 'iframe')) options.push(`${tag}[id^="${prefix}"]`);
      for (const a of ['data-testid', 'data-component', 'data-test', 'data-qa']) {
        const v = el.getAttribute(a);
        if (v && stable(v)) options.push(`${tag}[${a}="${v}"]`);
      }
      if (stable(el.id)) options.push(`${tag}#${el.id}`);
      const classes = [...el.classList].filter(stable).sort((a, b) => Number(clutter.test(b)) - Number(clutter.test(a)));
      options.push(...classes.map((c) => `${tag}.${c}`));
      for (const s of options) {
        const found = matches(s);
        if (found.length && found.length <= limit && found.includes(el)) return { selector: s, count: found.length };
      }
      return null;
    }

    function pageSignals() {
      const types = new Set();
      const visit = (item, depth) => {
        if (!item || typeof item !== 'object' || depth > 6) return;
        if (Array.isArray(item)) { for (const c of item.slice(0, 40)) visit(c, depth + 1); return; }
        for (const t of [item['@type']].flat()) if (typeof t === 'string') types.add(t.toLowerCase());
        for (const k of ['@graph', 'mainEntity', 'mainEntityOfPage']) visit(item[k], depth + 1);
      };
      for (const s of [...document.querySelectorAll('script[type="application/ld+json"]')].slice(0, 10)) {
        try { if ((s.textContent ?? '').length < 100000) visit(JSON.parse(s.textContent ?? ''), 0); } catch {}
      }
      const og = document.querySelector('meta[property="og:type"]')?.getAttribute('content') ?? '';
      const list = [...types];
      const main = document.querySelector('main,[role="main"]');
      const anchor = main?.getAttribute('data-component') ?? main?.getAttribute('data-testid') ?? main?.tagName ?? 'body';
      return {
        hasArticle: list.some((t) => /article|blogposting/.test(t)) || og === 'article'
          || !!document.querySelector('main article h1, article [itemprop="articleBody"], [itemtype$="Article"]'),
        isProduct: list.includes('product') || og.startsWith('product'),
        isListing: list.some((t) => /collectionpage|itemlist/.test(t)),
        shell: `${anchor.slice(0, 100)}|${document.querySelector('article') ? 'article' : ''}`,
      };
    }

    function restore() {
      for (const [el, s] of S.saved) {
        el.removeAttribute(S.attr);
        if (el.getAttribute('style') === s.applied) {
          if (s.original === null) el.removeAttribute('style'); else el.setAttribute('style', s.original);
        }
      }
      S.saved.clear();
      S.style?.remove();
      S.style = null;
    }

    function scan(maxRaw, maxMatches) {
      restore();
      const sensitive = document.querySelector('input[type="password" i]') ? 'password'
        : document.querySelector(paymentInput) ? 'payment' : null;
      const signals = pageSignals();
      if (sensitive) return { sensitive, signals, candidates: [] };
      const ctx = pageContext();
      // Consent UI often arrives at the very end of body, after thousands of nodes.
      // Only containers and overlays: a heading's span with "cookie" in its id is article text.
      const priority = [...document.querySelectorAll('[role="dialog"],[aria-modal="true"],[id^="sp_message_"],[id*="cookie" i],[id*="consent" i],#onetrust-banner-sdk,#didomi-host')]
        .filter((el) => el.matches('div,section,aside,iframe,dialog,form,[role="dialog"],[role="alertdialog"],[aria-modal="true"]') || /fixed|sticky/.test(getComputedStyle(el).position))
        .slice(0, 100);
      const elements = [...new Set([...priority, ...[...document.querySelectorAll('aside,section,div,[role="dialog"],iframe')].slice(0, 6000)])];
      const seen = new Set();
      const candidates = [];
      for (const el of elements) {
        if (candidates.length >= maxRaw) break;
        const cookie = isCookieNotice(el);
        const signalsText = `${cookie ? 'Cookie consent overlay. Hide visually only; do not accept or reject consent. ' : ''}${identity(el)} ${el.getAttribute('role') ?? ''}`;
        const position = getComputedStyle(el).position;
        if (!cookie && !clutter.test(signalsText) && !el.matches('aside,[role="dialog"],iframe') && position !== 'fixed' && position !== 'sticky') continue;
        const found = selectorFor(el, maxMatches);
        if (!found || seen.has(found.selector)) continue;
        seen.add(found.selector);
        candidates.push({
          selector: found.selector,
          tag: el.tagName.toLowerCase(),
          signals: squash(signalsText).slice(0, 600),
          text: textOf(el, 600),
          position,
          count: found.count,
          facts: facts(el, ctx),
        });
      }
      return { sensitive, signals, candidates };
    }

    // Every matched element gets an index, and `within` names the nearest matched ancestor, so
    // Swift can count a wrapper and the slot inside it once.
    function measure(selectors) {
      const ctx = pageContext();
      const vw = window.innerWidth, vh = window.innerHeight;
      const found = selectors.map((selector) => ({ selector, elements: matches(selector).slice(0, 100) }));
      const indexOf = new Map();
      for (const rule of found) for (const el of rule.elements) if (!indexOf.has(el)) indexOf.set(el, indexOf.size);
      const within = (el) => {
        for (let n = el.parentElement; n; n = n.parentElement) if (indexOf.has(n)) return indexOf.get(n);
        return null;
      };
      return {
        viewportArea: vw * vh,
        textLength: ctx.bodyText,
        rules: found.map(({ selector, elements }) => ({
          selector,
          elements: elements.map((el) => {
            const r = el.getBoundingClientRect();
            const x = Math.max(r.left, 0), y = Math.max(r.top, 0);
            const w = Math.max(0, Math.min(r.right, vw) - x);
            const h = Math.max(0, Math.min(r.bottom, vh) - y);
            const position = getComputedStyle(el).position;
            return {
              facts: facts(el, ctx), index: indexOf.get(el), within: within(el),
              frame: { x, y, width: w, height: h }, inFlow: position !== 'fixed' && position !== 'sticky',
            };
          }),
        })),
      };
    }

    // Saves each touched element's whole style attribute, so Undo puts back exactly what was there.
    function hide(el, property, value) {
      if (!S.saved.has(el)) S.saved.set(el, { original: el.getAttribute('style'), applied: null });
      el.style.setProperty(property, value, 'important');
      S.saved.get(el).applied = el.getAttribute('style');
    }

    function apply(selectors) {
      restore();
      const targets = new Set();
      for (const s of selectors) for (const el of matches(s)) targets.add(el);
      if (!targets.size) return { hidden: 0 };
      let overlay = false;
      for (const el of targets) {
        overlay ||= isCookieNotice(el) || getComputedStyle(el).position === 'fixed';
        hide(el, 'display', 'none');
        el.setAttribute(S.attr, '');
      }
      // A cookie wall locks scrolling; unlock it unless another visible modal (a login box) is up.
      const otherModal = [...document.querySelectorAll('dialog[open],[aria-modal="true"],[role="dialog"]')].some((d) =>
        ![...targets].some((t) => t === d || t.contains(d)) && getComputedStyle(d).display !== 'none' && !d.hasAttribute('hidden'));
      if (overlay && !otherModal) {
        for (const el of [document.documentElement, document.body]) {
          if (!el) continue;
          const cs = getComputedStyle(el);
          for (const p of ['overflow-x', 'overflow-y']) if (/hidden|clip/.test(cs.getPropertyValue(p))) hide(el, p, 'auto');
        }
      }
      S.style = document.createElement('style');
      S.style.textContent = `[${S.attr}] { display: none !important; min-height: 0 !important; height: 0 !important; margin: 0 !important; padding: 0 !important; }`;
      (document.head ?? document.documentElement).append(S.style);
      const list = [...targets];
      return { hidden: list.filter((el) => !list.some((p) => p !== el && p.contains(el))).length };
    }

    function undo() {
      const had = S.saved.size > 0;
      restore();
      return { undone: had };
    }
    """#
}

enum DeclutterScriptError: Error {
    case noResult
}
