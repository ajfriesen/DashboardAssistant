/* ==========================================================================
   Click-to-play videos
   --------------------------------------------------------------------------
   The privacy policy (legal/datenschutz.md) promises that opening a page
   loads nothing from third parties. A YouTube player would break that the
   moment the page opens: it talks to Google and stores data in the browser.

   So a video is shown as our own copy of its thumbnail with a play button,
   and the player is created only when the reader clicks it:

     <div class="da-video" data-youtube="VIDEO_ID">
       <button type="button" class="da-video__play" aria-label="Play …">
         <img src="/img/media/….jpg" alt="">
       </button>
       <p class="da-video__note">… <a href="https://www.youtube.com/watch?v=…">…</a></p>
     </div>

   The player comes from youtube-nocookie.com, YouTube's privacy-enhanced
   mode. Without JavaScript the button does nothing and the link in the note
   still leads to the video.

   `document$` emits on first load and after every instant navigation; this
   file is loaded via `extra_javascript`, after the theme's bundle.
   ========================================================================== */

(function () {
  "use strict";

  function play(video) {
    var id = video.getAttribute("data-youtube");
    var button = video.querySelector(".da-video__play");
    if (!id || !button) { return; }
    var frame = document.createElement("iframe");
    frame.src = "https://www.youtube-nocookie.com/embed/" + encodeURIComponent(id) + "?autoplay=1";
    frame.title = button.getAttribute("aria-label") || "YouTube video";
    frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
    frame.allowFullscreen = true;
    frame.referrerPolicy = "strict-origin-when-cross-origin";
    button.replaceWith(frame);
  }

  document$.subscribe(function () {
    var videos = document.querySelectorAll(".da-video[data-youtube]");
    Array.prototype.forEach.call(videos, function (video) {
      var button = video.querySelector(".da-video__play");
      if (!button || button.dataset.bound) { return; }
      button.dataset.bound = "1";
      button.addEventListener("click", function () { play(video); });
    });
  });
})();
