# Changelog

## [1.0.0-rc.1](https://github.com/ajfriesen/DashboardAssistant/compare/v0.3.0-rc.1...v1.0.0-rc.1) (2026-09-11)


### ⚠ BREAKING CHANGES

* **rpi:** the Pi 4/5 SD images now build a btrfs root with zstd compression (the Nix store roughly halves), and U-Boot is rebuilt with btrfs read support. Devices flashed from earlier ext4 images cannot take this release in place — the update preflight guard (shipped in 0.3.0-rc.1) refuses the switch with a reflash-required message on the HA update entity. Reflash the SD card with this release's image; settings re-seed from dashboard-assistant.yaml on first boot.

### Features

* **daemon:** add check_updates endpoint to re-poll releases on demand ([f9e585e](https://github.com/ajfriesen/DashboardAssistant/commit/f9e585e742fb94e7b2816bea0bec72e4973888c2))
* **rpi:** ship btrfs+zstd root SD images ([173d369](https://github.com/ajfriesen/DashboardAssistant/commit/173d3696bc308bca0da77eb646f063a9792f2b58))

## [0.3.0-rc.1](https://github.com/ajfriesen/DashboardAssistant/compare/v0.2.1-rc.1...v0.3.0-rc.1) (2026-09-11)


### Features

* **daemon:** surface the update failure reason on the HA entity ([d5bdc96](https://github.com/ajfriesen/DashboardAssistant/commit/d5bdc96adc60014b9da1ecb0e557cfda4af3393a))
* **update:** refuse in-place updates onto a mismatched root filesystem ([23d9698](https://github.com/ajfriesen/DashboardAssistant/commit/23d9698bbe529c946d8bd4d05e1491e2cd20693d))


### Bug Fixes

* **docs:** centre the icons in the feature card tiles ([ff11887](https://github.com/ajfriesen/DashboardAssistant/commit/ff118878135cec7793afb68306bf98b025c96f8b))


### Documentation

* add Impressum and Datenschutzerklärung ([9c37881](https://github.com/ajfriesen/DashboardAssistant/commit/9c37881482882587a2915a59058486b4ea9b22f5))
* add the brand assets the site loads ([00e6344](https://github.com/ajfriesen/DashboardAssistant/commit/00e6344ceea0bb81e43e53de8794bc39acac2207))
* add the Discord invite to the footer ([9c2814d](https://github.com/ajfriesen/DashboardAssistant/commit/9c2814d15fbc04a80d38c0ebd9b8480b6c9aa646))
* add the multi-room audio card to the home page ([ceb6bb1](https://github.com/ajfriesen/DashboardAssistant/commit/ceb6bb1ddafbdf1838789f178c832e87b2a453c1))
* adopt the brand copy on the site ([0692e8a](https://github.com/ajfriesen/DashboardAssistant/commit/0692e8ad9bf609331638eb6256064f43da7b4b18))
* aim the business page at hardware manufacturers ([f84b1d4](https://github.com/ajfriesen/DashboardAssistant/commit/f84b1d4af7348bfc36ba3d6bf0933f976aef9bad))
* render the site in the brand palette ([9b8e92f](https://github.com/ajfriesen/DashboardAssistant/commit/9b8e92f2184ba62f1ad3a9fbb5d72a6e16f3d338))
* replace the site's emoji with lucide icons ([d073014](https://github.com/ajfriesen/DashboardAssistant/commit/d0730145c6c8056aa626a81c99470de492f31240))
* say what the front page is like to live with ([032b571](https://github.com/ajfriesen/DashboardAssistant/commit/032b571aec7fafe6097407da6955c4373be94b0b))
* stop the hero eyebrow repeating the headline ([ef3539b](https://github.com/ajfriesen/DashboardAssistant/commit/ef3539b17257576ffba068efb005cc32850c2290))

## [0.2.1-rc.1](https://github.com/ajfriesen/DashboardAssistant/compare/v0.2.0-rc.1...v0.2.1-rc.1) (2026-08-30)


### Documentation

* add the HACS install guide and sync pages with today's behaviour ([e00972f](https://github.com/ajfriesen/DashboardAssistant/commit/e00972f082d4a3fb0f47612b0d3fd9cf4f3d9a95))
* add the HACS install guide and sync pages with today's behaviour ([3e88caa](https://github.com/ajfriesen/DashboardAssistant/commit/3e88caa986503d7e7f95a2e5a897e2579bd3564c))

## [0.2.0-rc.1](https://github.com/ajfriesen/DashboardAssistant/compare/v0.1.0-rc.3...v0.2.0-rc.1) (2026-08-30)


### Features

* **audio:** add Sendspin multi-room audio player ([b92c0ea](https://github.com/ajfriesen/DashboardAssistant/commit/b92c0ea29b1c4be3b1c324867475a6ebf480ea87))
* **rpi5:** add a dev image with root SSH and deploy it without reflashing ([96fa83f](https://github.com/ajfriesen/DashboardAssistant/commit/96fa83f2b91bc5d292b9eb1b7e1e8bf2f844d8e8))
* **security:** move recovery off the tablet screen onto a LAN admin page ([acbabeb](https://github.com/ajfriesen/DashboardAssistant/commit/acbabeb14fb5ed1a58d509473a408bfc5f8d74c3))
* Wi-Fi onboarding, LAN admin page, and R2 image publishing ([2a95fd4](https://github.com/ajfriesen/DashboardAssistant/commit/2a95fd4722448b5364caee1d2c377139c82fe2b3))
* **wifi:** onboard a stranded device over its own access point ([e7e6d4e](https://github.com/ajfriesen/DashboardAssistant/commit/e7e6d4ef611bbc81dd79e7a31bf51628e23bfbf8))


### Bug Fixes

* **daemon:** resolve the Wi-Fi device lazily, not once at startup ([6af00d0](https://github.com/ajfriesen/DashboardAssistant/commit/6af00d0e78e2d071912af84820b5ed47d7a5f8fe))
* **kiosk:** drop DeveloperToolsAvailability, it silently kills CDP ([0531475](https://github.com/ajfriesen/DashboardAssistant/commit/05314758b9f9c7e64b413ba11b35617646a7a7db))
* **kiosk:** make auto-login wait for its preconditions, not race them ([8b81d50](https://github.com/ajfriesen/DashboardAssistant/commit/8b81d504c79534b27076134e2e2ae014db446fb2))
* **kiosk:** restore the backlight after powering the display on ([a01eb20](https://github.com/ajfriesen/DashboardAssistant/commit/a01eb203504c94934d0e6583f7a4d25347797bc2))
* **network:** let NetworkManager run wpa_supplicant ([c5ffc82](https://github.com/ajfriesen/DashboardAssistant/commit/c5ffc821998500fe293bc855c0420bf18690af81))
* **pairing:** let a preconfigured device pair with Home Assistant ([373ee53](https://github.com/ajfriesen/DashboardAssistant/commit/373ee5303847c01e572646871f298be4c3020d1e))


### Documentation

* document the Music Assistant page and the Sendspin switch ([64a45f0](https://github.com/ajfriesen/DashboardAssistant/commit/64a45f053d526d60fcb770ead92ba16d17c7b685))


### Miscellaneous

* release 0.2.0-rc.1 ([01bbb80](https://github.com/ajfriesen/DashboardAssistant/commit/01bbb807790c5070f73236f2b403205172094681))

## [0.1.0-rc.3](https://github.com/ajfriesen/DashboardAssistant/compare/v0.1.0-rc.2...v0.1.0-rc.3) (2026-08-08)


### Features

* **kiosk:** add sponsor heart button to the on-device bar ([2fb2234](https://github.com/ajfriesen/DashboardAssistant/commit/2fb223462250a7147dec2743230383363a6560a3))
* **kiosk:** orientation-aware waybar + steady heart button ([cf2a6a8](https://github.com/ajfriesen/DashboardAssistant/commit/cf2a6a807d18bcaad7cca719eef08d30098581eb))
* **pages:** default a fresh device to a homeassistant.local page ([d8b4691](https://github.com/ajfriesen/DashboardAssistant/commit/d8b469119dcca7ff549f334c166d0e30131c1dde))
* **screenshot:** capture the whole screen, not just Chromium ([181f035](https://github.com/ajfriesen/DashboardAssistant/commit/181f0357baea4257dfb04c8de997c0d92502a5f1))
* **update:** expose generation labels to Home Assistant ([c72a48e](https://github.com/ajfriesen/DashboardAssistant/commit/c72a48ea48328bb30136e35a594e060e1e59bc16))
* **update:** install any OS release from Home Assistant ([ba6364e](https://github.com/ajfriesen/DashboardAssistant/commit/ba6364e2b9707192328ca7e0ce479b093b2257a1))
* **update:** tag NixOS generations with the release version ([0e7a8db](https://github.com/ajfriesen/DashboardAssistant/commit/0e7a8dbc7064bb084b7a23339a4293f3a64ab804))


### Bug Fixes

* **daemon:** update vendorHash after dropping gorilla/websocket ([52e80a3](https://github.com/ajfriesen/DashboardAssistant/commit/52e80a317e442aceab15cdabbec3428878f339d8))


### Documentation

* add "Why" page to the About section ([fdc569f](https://github.com/ajfriesen/DashboardAssistant/commit/fdc569f8f020e38bddfb7ab9207ec904914dec04))
* add beating-heart animation to the Sponsor nav link ([d76a104](https://github.com/ajfriesen/DashboardAssistant/commit/d76a104011ea36d1c53482488e84fb970d9bc21a))
* add business & getting-started pages, split hardware support ([f9a4807](https://github.com/ajfriesen/DashboardAssistant/commit/f9a48076b871951c4ec86820a750b009a46355c1))
* add comparison + sponsor pages, drop manual token page, rename repo ([da09bbe](https://github.com/ajfriesen/DashboardAssistant/commit/da09bbec6ddc398640061a825dd9c987c3c44028))
* add landing page with tablet mockup slideshow ([42a3a1a](https://github.com/ajfriesen/DashboardAssistant/commit/42a3a1a1cde7381678d56253ae74966fbeed29d0))
* add portrait screenshot and note display rotation ([02ad111](https://github.com/ajfriesen/DashboardAssistant/commit/02ad1115531638f50251adef20ec966b32b1fc86))
* add umami analytics tracking to site ([f0a6ad6](https://github.com/ajfriesen/DashboardAssistant/commit/f0a6ad6471d663c651d651154fa8ba2376a98ce2))
* correct landing setup framing to download/flash/boot ([b8081d8](https://github.com/ajfriesen/DashboardAssistant/commit/b8081d85f0b8c8d110ed4f637a8fc62740e804c6))
* correct rollback claims to manual on-device recovery ([0e2c35e](https://github.com/ajfriesen/DashboardAssistant/commit/0e2c35eee488d84bd670b1771356a7cd0dd93657))
* fix home-page slideshow and tablet bezel ([7492e88](https://github.com/ajfriesen/DashboardAssistant/commit/7492e88d3f3b725fef17bc1bfe0b390d492eabce))
* fix unreadable primary button labels on landing page ([3468cab](https://github.com/ajfriesen/DashboardAssistant/commit/3468cab58b075a2061cfe78592462f9666566251))
* refine hero headline/lead wording and trim Why page ([a721b62](https://github.com/ajfriesen/DashboardAssistant/commit/a721b621677ef24174e278d991e70940114e09d5))
* reframe landing for users, draft installer, drop add-user steps ([a2d6546](https://github.com/ajfriesen/DashboardAssistant/commit/a2d65467fcd5c60b3c5709a4a71caae63e1060b8))
* remove How It Compares page ([3a8e829](https://github.com/ajfriesen/DashboardAssistant/commit/3a8e829d5347be97f898e2f2ff05f32c2478d673))
* repoint In Action gallery at the renamed screenshots ([b089a54](https://github.com/ajfriesen/DashboardAssistant/commit/b089a54665d012d1380d3c4a7c69d77cd52f793c))
* revise sponsor page copy ([481e43d](https://github.com/ajfriesen/DashboardAssistant/commit/481e43dfad5b83e7ef70499f6250e79e2c93ae71))
* wrap In Action screenshots in the tablet frame ([394cc7d](https://github.com/ajfriesen/DashboardAssistant/commit/394cc7d607e8c1054b4eeb742e7760592282eab6))


### Miscellaneous

* release 0.1.0-rc.3 ([46ab60d](https://github.com/ajfriesen/DashboardAssistant/commit/46ab60d403825621588d231b77dd961700f65e9b))

## [0.1.0-rc.2](https://github.com/ajfriesen/DashboardAssistant/compare/v0.1.0-rc.1...v0.1.0-rc.2) (2026-08-04)


### Miscellaneous

* release 0.1.0-rc.2 ([54648d1](https://github.com/ajfriesen/DashboardAssistant/commit/54648d1ced23f50e59870e7427ca2c087338019f))

## 0.1.0-rc.1 (2026-08-04)


### Miscellaneous

* reset version baseline and release 0.1.0-rc.1 ([9c35b2f](https://github.com/ajfriesen/DashboardAssistant/commit/9c35b2f084af76375339760a98c79f8732e9af33))

## Changelog

This file is generated from [Conventional Commit](https://www.conventionalcommits.org/)
messages by [release-please](https://github.com/googleapis/release-please). New
versions are added above automatically when a release PR is merged — write clear
commit messages rather than editing released sections by hand.

Changes are grouped by commit type (Features, Bug Fixes, …). The hardware target
is the commit **scope**, so a board's changes read as e.g. `feat(rpi5):` /
`fix(x86):`; use `daemon`/`core` (or no scope) for changes that apply everywhere.

No public release has been cut yet; the first is `0.1.0`, reached via
`0.1.0-rc.x` prereleases.
