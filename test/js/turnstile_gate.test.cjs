"use strict";

// Tests for the Turnstile code in the bundle
// (priv/static/assets/phoenix_kit_entities.js): which widgets it starts, what
// it does when loading or rendering fails, and the submit gate.
//
// The runner has no DOM, so the bundle's decisions are plain functions of a
// `document`-like object, and these tests feed them small stand-ins: an
// element has attributes, an ancestor test (`closest`) and children found by
// selector. The browser-only parts (the script tag, `document` listeners) are
// not exercised here.
//
// Run: mix test.js

const test = require("node:test");
const assert = require("node:assert/strict");

global.window = {};
global.document = { querySelector: () => null, activeElement: null };

const {
  tokenMissing,
  insideLiveView,
  shouldStart,
  widgetsToStart,
  startWidgets,
  guardSubmit
} = require("../../priv/static/assets/phoenix_kit_entities.js");

const SITEKEY = 'input[name="_turnstile_sitekey"]';

// A widget element: `attrs` are its attributes, `inLiveView` whether a LiveView
// container is among its ancestors.
function widget({ attrs = [], inLiveView = false } = {}) {
  const set = new Set(attrs);
  return {
    hasAttribute: (name) => set.has(name),
    setAttribute: (name) => set.add(name),
    closest: (selector) => (inLiveView && selector === "[data-phx-session]" ? {} : null)
  };
}

// A form with the site-key field, the widget, a live region and the texts.
function form({ el = widget(), sitekey = "0x4AAA-key", token } = {}) {
  const field = { value: sitekey };
  const tokenField = token === undefined ? null : { value: token };
  const status = { textContent: "" };
  const texts = {
    wait: { textContent: "wait" },
    blocked: { textContent: "blocked" },
    error: { textContent: "error" }
  };

  const f = {
    status,
    widget: el,
    querySelector(selector) {
      if (selector === SITEKEY) return field;
      if (selector === '[name="cf-turnstile-response"]') return tokenField;
      if (selector === ".entity-turnstile-widget") return el;
      if (selector === ".entity-turnstile-status") return status;
      const text = selector.match(/^\.entity-turnstile-text-(\w+)$/);
      return text ? texts[text[1]] : null;
    }
  };
  field.form = f;
  f.field = field;
  return f;
}

const docOf = (...forms) => ({ querySelectorAll: () => forms.map((f) => f.field) });

test("a submit has no token when the field is absent, empty or blank", () => {
  for (const token of [undefined, "", "   "]) {
    assert.equal(tokenMissing(form({ token })), true);
  }
  assert.equal(tokenMissing(form({ token: "0.abc" })), false);
});

test("an element is in a LiveView when a LiveView container is among its ancestors", () => {
  assert.equal(insideLiveView(widget({ inLiveView: true })), true);
  assert.equal(insideLiveView(widget()), false);
  assert.equal(insideLiveView({}), false);
});

test("core's hook owns a widget in a LiveView that still has its hook attribute", () => {
  assert.equal(shouldStart(widget({ attrs: ["phx-hook"], inLiveView: true })), false);
});

test("a controller-rendered page's widget is started, with or without its hook attribute", () => {
  assert.equal(shouldStart(widget({ attrs: ["phx-hook"] })), true);
  // Publishing's sanitizer removes the attribute.
  assert.equal(shouldStart(widget()), true);
});

test("a widget in a LiveView whose hook attribute was stripped is started: nothing else will", () => {
  assert.equal(shouldStart(widget({ inLiveView: true })), true);
});

test("a widget already started is not started twice", () => {
  assert.equal(shouldStart(widget({ attrs: ["data-entity-turnstile"] })), false);
});

test("widgetsToStart pairs each form's widget with the site key that form carries", () => {
  const a = form({ sitekey: "key-a" });
  const b = form({ sitekey: "key-b", el: widget({ attrs: ["phx-hook"], inLiveView: true }) });
  const c = form({ sitekey: "key-c" });

  const found = widgetsToStart(docOf(a, b, c));

  assert.deepEqual(found.map((w) => w.sitekey), ["key-a", "key-c"]);
  assert.equal(found[0].el, a.widget);
});

test("startWidgets renders each started widget once, with its own site key", async () => {
  const rendered = [];
  const turnstile = { render: (el, options) => rendered.push([el, options.sitekey]) };
  const a = form({ sitekey: "key-a" });
  const b = form({ sitekey: "key-b", el: widget({ attrs: ["phx-hook"], inLiveView: true }) });
  const doc = docOf(a, b);
  const load = () => Promise.resolve(turnstile);

  startWidgets(doc, load);
  await Promise.resolve();
  startWidgets(doc, load);
  await Promise.resolve();

  assert.deepEqual(rendered, [[a.widget, "key-a"]]);
});

test("a script that cannot load says so, and is not mistaken for a render error", async () => {
  const f = form();
  startWidgets(docOf(f), () => Promise.reject(new Error("blocked")));
  await new Promise((resolve) => setImmediate(resolve));

  guardSubmit({ target: f, preventDefault() {} });
  assert.equal(f.status.textContent, "blocked");
});

test("a render that throws says so, and is not mistaken for a blocked script", async () => {
  const f = form();
  const turnstile = { render: () => { throw new Error("bad site key"); } };
  startWidgets(docOf(f), () => Promise.resolve(turnstile));
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(f.status.textContent, "error");
});

test("guardSubmit stops a tokenless submit and says why, keeping the page", () => {
  const f = form({ token: "" });
  let prevented = false;

  guardSubmit({ target: f, preventDefault: () => (prevented = true) });

  assert.equal(prevented, true);
  assert.equal(f.status.textContent, "wait");
});

test("guardSubmit lets a submit with a token, or a form that is not a Turnstile form, through", () => {
  let prevented = false;
  const event = (target) => ({ target, preventDefault: () => (prevented = true) });

  guardSubmit(event(form({ token: "0.abc" })));
  guardSubmit(event({ querySelector: () => null }));
  guardSubmit(event({}));
  guardSubmit(event(null));

  assert.equal(prevented, false);
});

test("a sanitized form added by LiveView navigation starts once", async () => {
  const fs = require("node:fs");
  const vm = require("node:vm");
  let forms = [];
  const rendered = [];
  const listeners = {};
  const window = {
    addEventListener(name, callback) { listeners[name] = callback; },
    turnstile: { render(el) { rendered.push(el); } }
  };
  const document = {
    readyState: "complete",
    addEventListener() {},
    querySelectorAll() { return forms.map((f) => f.field); }
  };
  const bundle = require.resolve("../../priv/static/assets/phoenix_kit_entities.js");
  vm.runInNewContext(fs.readFileSync(bundle, "utf8"), { window, document });

  const added = form({ el: widget({ inLiveView: true }) });
  forms = [added];
  listeners["phx:page-loading-stop"]();
  listeners["phx:page-loading-stop"]();
  await Promise.resolve();

  assert.deepEqual(rendered, [added.widget]);
});
