/* ==========================================================================
   Language picker: stay on the page
   --------------------------------------------------------------------------
   The picker in the header is the theme's (`extra.alternate` in zensical.toml
   and zensical.de.toml), and each entry links to that language's home page.
   The theme can keep the reader on the page they are on, but only when every
   language lives in its own sub-folder: it matches a link to a language by
   URL prefix, and English at the domain root is a prefix of everything, so
   with our layout it never fires.

   This does that job instead. The two sites mirror each other — every page in
   content/ has a twin at the same path in content-de/, served under /de/ — so
   the counterpart of a page is the same path with or without the /de prefix.
   Each picker link is pointed at that counterpart, after a HEAD request
   confirms it exists; a page with no twin (a news post in one language only)
   keeps the theme's link to the home page.

   `document$` emits on first load and after every instant navigation, which
   is what keeps the links right as the reader moves around. This file is
   loaded via `extra_javascript`, after the theme's bundle, so it is defined.
   ========================================================================== */

(function () {
  "use strict";

  var GERMAN = "/de";

  function counterpart(lang) {
    var path = window.location.pathname;
    var bare = path === GERMAN || path.indexOf(GERMAN + "/") === 0
      ? path.slice(GERMAN.length) || "/"
      : path;
    return (lang === "de" ? GERMAN : "") + bare;
  }

  function update() {
    var links = document.querySelectorAll(".md-select__link[hreflang]");
    Array.prototype.forEach.call(links, function (link) {
      var target = counterpart(link.getAttribute("hreflang"));
      window
        .fetch(target, { method: "HEAD" })
        .then(function (response) {
          if (response.ok) {
            link.setAttribute("href", target);
          }
        })
        .catch(function () {
          /* Offline or blocked: the link to the home page stays. */
        });
    });
  }

  document$.subscribe(update);
})();
