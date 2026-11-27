// phoenix_kit_entities JS hooks — folded into the host LiveSocket by
// core's :phoenix_kit_js_sources compiler (see PhoenixKit.Module.js_sources/0).
(function () {
  "use strict";

  window.PhoenixKitEntitiesHooks = window.PhoenixKitEntitiesHooks || {};

  // SlugFromTitle — fills the slug field as the title is typed, in the
  // browser, with no server round trip (Max, 2026-08-28: "it's just text
  // that doesn't need a server round trip").
  //
  // The server still derives the slug it will actually store: this is an
  // echo for the eye, not the source of truth. Two rules keep the two
  // from disagreeing on screen:
  //
  //   * It writes only while the server says the slug is still following
  //     the title (`data-slug-auto` on the target, mirrored from the
  //     LiveView's own flag). Once someone types their own slug, this
  //     goes quiet.
  //   * It writes only what it can slugify CONFIDENTLY — ASCII and
  //     accented Latin. Core's rule is locale-aware and romanizes
  //     Cyrillic ("Цвет" -> "tsvet"), which is not something to
  //     re-implement here; for anything this cannot handle it leaves the
  //     field alone and lets the server's value land.
  // Pure, and exported at the bottom of this file so `mix test.js` can
  // pin it: what this refuses to slugify is the whole contract between
  // the hook and core's locale-aware rule.
  function slugifyLatin(text) {
    // Combining marks: "é" -> "e". Anything without a Latin
    // decomposition (Cyrillic, Greek, CJK) survives this untouched.
    var latin = text.normalize("NFD").replace(/[̀-ͯ]/g, "");

    // Bail on ANY leftover non-ASCII, not just on an empty result.
    // Core romanizes ("Цвет Red" -> "tsvet-red"); dropping what this
    // cannot read would show "red" for an instant and then jump to the
    // server's answer. A mixed-script title is exactly where the two
    // disagree, so say nothing and let the server's value land.
    if (/[^\x00-\x7F]/.test(latin)) return "";

    return latin
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
  }

  window.PhoenixKitEntitiesHooks.SlugFromTitle = {
    mounted() {
      this.onInput = () => this.mirror();
      this.el.addEventListener("input", this.onInput);
    },

    destroyed() {
      this.el.removeEventListener("input", this.onInput);
    },

    mirror() {
      // querySelector("") THROWS — an absent data-slug-target would take
      // the whole hook down rather than quietly doing nothing.
      var selector = this.el.dataset.slugTarget;
      if (!selector) return;

      var target = document.querySelector(selector);
      if (!target) return;

      // The server owns "is this still auto-generated?" — never guess it
      // from the field's contents, which lag a keystroke behind.
      if (target.dataset.slugAuto !== "true") return;

      // Don't fight the user if they happen to be in the slug field.
      if (document.activeElement === target) return;

      var slug = slugifyLatin(this.el.value || "");
      if (slug === "") return;

      target.value = slug;
    },

    slugify: slugifyLatin
  };

  // ── Cloudflare Turnstile on the public form ─────────────────────────────
  //
  // The widget is core's (`phx-hook="Turnstile"`), whose hook only starts inside
  // a LiveView. On a controller-rendered page (a Publishing post) nothing would
  // start it and every submit would be refused, so this starts it there, and it
  // keeps a submit that has no token yet from leaving the page (the visitor
  // would lose what they typed to a server refusal). The server decides either
  // way; this is a courtesy.
  //
  // Everything is found by CLASS and by the hidden `_turnstile_sitekey` field,
  // never by `data-*` / `phx-*` / `hidden`: Publishing's page sanitizer strips
  // those from an inline form and keeps only `class`, `id`, `style`, `aria-*`
  // and `input` `type`/`name`/`value`. The messages sit in hidden spans next to
  // the widget so the words stay translated by the server.
  //
  // Unlike core's hook this does not wait for a closed daisyUI modal to open.
  var TURNSTILE_SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
  var SITEKEY_FIELD = 'input[name="_turnstile_sitekey"]';
  var turnstileLoading = null;

  function each(list, fn) {
    Array.prototype.forEach.call(list || [], fn);
  }

  function insideLiveView(el) {
    return !!(el.closest && el.closest("[data-phx-session]"));
  }

  // The form a site-key field belongs to.
  function formOf(field) {
    return field.form || (field.closest && field.closest("form")) || null;
  }

  function tokenMissing(form) {
    var field = form.querySelector('[name="cf-turnstile-response"]');
    return !field || String(field.value || "").trim() === "";
  }

  // Core's hook owns a widget that is in a LiveView and still has its hook
  // attribute. Anywhere else (a controller-rendered page, or markup whose
  // attributes a sanitizer removed) nothing else will start it. A widget is
  // started once.
  function shouldStart(el) {
    if (el.hasAttribute("data-entity-turnstile")) return false;
    return !(el.hasAttribute("phx-hook") && insideLiveView(el));
  }

  // The widgets to start under `doc`, with the site key each form carries.
  function widgetsToStart(doc) {
    var found = [];

    each(doc.querySelectorAll(SITEKEY_FIELD), function (field) {
      var form = formOf(field);
      var el = form && form.querySelector(".entity-turnstile-widget");
      if (el && shouldStart(el)) found.push({ el: el, form: form, sitekey: field.value });
    });

    return found;
  }

  // Puts one of the server-translated texts in the form's live region.
  function say(form, kind) {
    var status = form.querySelector(".entity-turnstile-status");
    var text = form.querySelector(".entity-turnstile-text-" + kind);
    if (status && text) status.textContent = text.textContent;
  }

  function loadTurnstile() {
    if (window.turnstile) return Promise.resolve(window.turnstile);
    if (turnstileLoading) return turnstileLoading;

    turnstileLoading = new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = TURNSTILE_SCRIPT;
      script.async = true;
      script.defer = true;
      script.onload = function () {
        if (window.turnstile) resolve(window.turnstile);
        else { turnstileLoading = null; reject(new Error("Turnstile did not initialise")); }
      };
      script.onerror = function () {
        turnstileLoading = null;
        script.remove();
        reject(new Error("Turnstile could not be loaded"));
      };
      document.head.appendChild(script);
    });

    return turnstileLoading;
  }

  function startWidgets(doc, load) {
    each(widgetsToStart(doc), function (widget) {
      widget.el.setAttribute("data-entity-turnstile", "");

      load().then(
        function (turnstile) {
          try {
            turnstile.render(widget.el, { sitekey: widget.sitekey, theme: "auto", size: "flexible" });
          } catch (_err) {
            // Rendering threw (a site key Cloudflare does not know, say): not a blocked script.
            say(widget.form, "error");
          }
        },
        function () {
          say(widget.form, "blocked");
        }
      );
    });
  }

  function guardSubmit(event) {
    var form = event.target;
    if (!form || !form.querySelector || !form.querySelector(SITEKEY_FIELD)) return;
    if (!tokenMissing(form)) return;

    event.preventDefault();
    var status = form.querySelector(".entity-turnstile-status");
    if (!status || !status.textContent.trim()) say(form, "wait");
  }

  if (typeof document !== "undefined" && document.addEventListener) {
    document.addEventListener("submit", guardSubmit, true);

    var start = function () { startWidgets(document, loadTurnstile); };

    window.addEventListener("phx:page-loading-stop", start);

    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", start);
    } else {
      start();
    }
  }

  if (typeof module === "object" && module.exports) {
    module.exports.slugifyLatin = slugifyLatin;
    module.exports.tokenMissing = tokenMissing;
    module.exports.insideLiveView = insideLiveView;
    module.exports.shouldStart = shouldStart;
    module.exports.widgetsToStart = widgetsToStart;
    module.exports.startWidgets = startWidgets;
    module.exports.guardSubmit = guardSubmit;
  }
})();
