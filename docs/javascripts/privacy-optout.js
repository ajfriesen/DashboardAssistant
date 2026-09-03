/* ==========================================================================
   Analytics opt-out control (docs/legal/datenschutz.md)
   --------------------------------------------------------------------------
   Renders the Art. 21 GDPR objection as a button instead of asking visitors to
   paste a snippet into their developer console.

   Umami reads `localStorage['umami.disabled']` inside its send() on every
   event, so opting OUT takes effect immediately. It wires up auto-tracking
   only once at load, gated on the same flag, so opting back IN does not take
   effect until the next page load. The copy below says so rather than
   pretending measurement resumed.

   The site runs with `navigation.instant`, which swaps page content over XHR
   instead of reloading. `document$` is the theme's ReplaySubject(1): it emits
   on first load and again on every instant navigation, which is what keeps
   this control alive when the page is reached from the footer link. It fires
   repeatedly, so render() must be idempotent — it replaces each mount's
   contents outright and binds a listener to a freshly created button.

   This file is loaded via `extra_javascript`, which Zensical emits at the end
   of <body> AFTER its own bundle. That ordering is why `document$` exists by
   the time this runs; an inline <script> in the page body would run before the
   bundle on a cold load and find it undefined.
   ========================================================================== */

(function () {
  "use strict";

  var KEY = "umami.disabled";

  var TEXT = {
    de: {
      active: "Die Reichweitenmessung ist für diesen Browser aktiv.",
      disabled: "Die Reichweitenmessung ist für diesen Browser deaktiviert.",
      justDisabled: "Deaktiviert. Es werden ab sofort keine Daten mehr erfasst.",
      justEnabled: "Wieder aktiviert. Wirksam ab dem nächsten Seitenaufruf.",
      disable: "Deaktivieren",
      enable: "Wieder aktivieren",
      dnt: "Ihr Browser sendet „Do Not Track“. Es findet keine Reichweitenmessung statt.",
      unavailable:
        "Ihr Browser lässt keinen Zugriff auf den lokalen Speicher zu. Führen Sie in der " +
        "Entwicklerkonsole localStorage.setItem('umami.disabled', '1') aus, um zu widersprechen.",
    },
    en: {
      active: "Audience measurement is active for this browser.",
      disabled: "Audience measurement is disabled for this browser.",
      justDisabled: "Disabled. No further data is collected.",
      justEnabled: "Re-enabled. Takes effect from the next page load.",
      disable: "Disable",
      enable: "Re-enable",
      dnt: "Your browser sends Do Not Track. No audience measurement takes place.",
      unavailable:
        "Your browser does not allow access to local storage. Run " +
        "localStorage.setItem('umami.disabled', '1') in the developer console to object.",
    },
  };

  /* Mirrors Umami's own hasDoNotTrack(): window/navigator/msDoNotTrack, where
     1, "1" and "yes" all count as set. While DNT is on, the flag below changes
     nothing, so the control must not offer a toggle. */
  function doNotTrackEnabled() {
    var dnt =
      window.doNotTrack ||
      window.navigator.doNotTrack ||
      window.navigator.msDoNotTrack;
    return dnt === 1 || dnt === "1" || dnt === "yes";
  }

  /* Every localStorage access is guarded: in private modes and with site data
     blocked the accessor itself throws, not just the read. */
  function isDisabled() {
    return !!window.localStorage.getItem(KEY);
  }

  function setDisabled(disabled) {
    if (disabled) {
      window.localStorage.setItem(KEY, "1");
    } else {
      window.localStorage.removeItem(KEY);
    }
  }

  function render(mount, note) {
    var t = TEXT[mount.getAttribute("data-lang") === "de" ? "de" : "en"];

    mount.textContent = "";

    if (doNotTrackEnabled()) {
      mount.appendChild(status(t.dnt));
      return;
    }

    var disabled;
    try {
      disabled = isDisabled();
    } catch (e) {
      mount.appendChild(status(t.unavailable));
      return;
    }

    mount.appendChild(status(note || (disabled ? t.disabled : t.active)));

    var button = document.createElement("button");
    button.type = "button";
    button.className = "da-btn da-btn--ghost";
    button.textContent = disabled ? t.enable : t.disable;
    button.addEventListener("click", function () {
      try {
        setDisabled(!disabled);
      } catch (e) {
        /* The read succeeded but the write did not (storage full, or site data
           blocked mid-session). Drop the button rather than re-offering one
           that would fail the same way, and fall back to the console. */
        mount.textContent = "";
        mount.appendChild(status(t.unavailable));
        return;
      }
      render(mount, disabled ? t.justEnabled : t.justDisabled);
      /* Both language halves of the page carry a control backed by the same
         flag. Re-render the others so the page never shows two contradictory
         states at once. */
      syncOthers(mount);
    });

    mount.appendChild(button);
  }

  function status(text) {
    var p = document.createElement("p");
    p.className = "da-privacy-optout__status";
    p.textContent = text;
    return p;
  }

  function mountAll(except) {
    var mounts = document.querySelectorAll(".da-privacy-optout");
    for (var i = 0; i < mounts.length; i++) {
      if (mounts[i] !== except) {
        render(mounts[i]);
      }
    }
  }

  function syncOthers(mount) {
    mountAll(mount);
  }

  if (window.document$ && typeof window.document$.subscribe === "function") {
    window.document$.subscribe(mountAll);
  } else {
    /* No instant navigation (or the theme bundle changed shape) — the control
       still works on a normal page load. */
    mountAll();
  }
})();
