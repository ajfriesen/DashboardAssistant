# Changelog

## [1.1.0-rc.1](https://github.com/ajfriesen/DashboardAssistant/compare/v1.0.0-rc.1...v1.1.0-rc.1) (2026-09-26)


### Features

* **core:** enable seed-file config import by default ([3571490](https://github.com/ajfriesen/DashboardAssistant/commit/357149074b154f8b225d14dd7dbffa749c0af083))
* **core:** make journal files NOCOW on btrfs roots ([1ca1b48](https://github.com/ajfriesen/DashboardAssistant/commit/1ca1b487d74d04b805a6b406e06e570149771fb2))
* **core:** open the TLS API port ([31ee79b](https://github.com/ajfriesen/DashboardAssistant/commit/31ee79bae254d3f873ddf2e16d9b46a72999b07a))
* **core:** scrub btrfs roots monthly ([2689c7a](https://github.com/ajfriesen/DashboardAssistant/commit/2689c7a2cc734a71f49a1a26f97ac944710dcda9))
* **daemon:** report btrfs root filesystem health to HA ([b0898a5](https://github.com/ajfriesen/DashboardAssistant/commit/b0898a5e61ee30532c50d13bfc6c811b49966932))
* **daemon:** serve the Home Assistant API over TLS ([cb5a421](https://github.com/ajfriesen/DashboardAssistant/commit/cb5a421b9ff69dcc1c1a4816657b1083b1f2b189))


### Bug Fixes

* **core:** break the boot-killing journal-flush ordering cycle ([f2eb4f3](https://github.com/ajfriesen/DashboardAssistant/commit/f2eb4f3c701c90433790ff96c2df727d118983e1))
* **core:** declare the version file mode explicitly ([e3b0aef](https://github.com/ajfriesen/DashboardAssistant/commit/e3b0aef1056060b964ea67fb6b1328f6ad9583dc))
* **core:** make journal files NOCOW from the first boot ([1140f19](https://github.com/ajfriesen/DashboardAssistant/commit/1140f196c67bee0284eb9423b661eda91775d6f7))
* **daemon:** filter DMI placeholders out of the model string ([544e274](https://github.com/ajfriesen/DashboardAssistant/commit/544e274b1a101b6b0ddcb32220e577fa441397b2))
* **daemon:** read root mount state from PID 1, not the service sandbox ([e6580f6](https://github.com/ajfriesen/DashboardAssistant/commit/e6580f6f1c2ef9e67a92ae0acc80ea6f50ec823d))
* **daemon:** scope the factory-reset test to its temp state dir ([9c58059](https://github.com/ajfriesen/DashboardAssistant/commit/9c58059f14d07dc61b943edcf286ff84bcdeae6f))
* **kiosk:** drop pam_lastlog2 from the login stack ([ebdd05c](https://github.com/ajfriesen/DashboardAssistant/commit/ebdd05ce3f23370b7470be01e859cb65d4ff6f92))
* **kiosk:** issue swaymsg power on twice so the panel actually wakes ([5eb28f4](https://github.com/ajfriesen/DashboardAssistant/commit/5eb28f4c0dfde0da6554331b6a7c753c4d7f05a0))
* **kiosk:** make the on-screen keyboard fit portrait outputs ([59558ee](https://github.com/ajfriesen/DashboardAssistant/commit/59558eebc9c71ac402f6085968427c7dc8174231))
* **rpi:** drop ZFS support the sd-image profile smuggles in ([186849d](https://github.com/ajfriesen/DashboardAssistant/commit/186849d314ac3693cd3e9d3a757ed2ab4eb4d5ec))
* **rpi:** garbage-collect the Nix store on the Pi targets ([751d201](https://github.com/ajfriesen/DashboardAssistant/commit/751d20183a145acf571dd3e8485210d0316672fd))
* **rpi:** stop shipping build-user-owned filesystems in the btrfs images ([352e565](https://github.com/ajfriesen/DashboardAssistant/commit/352e56568375dd289bb1d638b37d42ea82d280d8))


### Performance

* **kiosk:** replace the animated heart with the static brand mark ([9157932](https://github.com/ajfriesen/DashboardAssistant/commit/9157932e040368a94bae9871255a025a920ba68a))
* **rpi:** skip .img.zst compression for the dev image ([7414b1f](https://github.com/ajfriesen/DashboardAssistant/commit/7414b1f94b059c380c51b7076434ddaf9460285c))
* **sendspin:** bound player memory and rate-limit its log ([61f2e4d](https://github.com/ajfriesen/DashboardAssistant/commit/61f2e4db35a71c204cdac40f2c7dbadf941177c5))


### Reverts

* journal NOCOW handling on btrfs roots ([0fe98d1](https://github.com/ajfriesen/DashboardAssistant/commit/0fe98d15feb283554a52faaaaf2c5a26a82dec93))
* journal NOCOW handling on btrfs roots, again ([e19a49f](https://github.com/ajfriesen/DashboardAssistant/commit/e19a49ffa22d6bc2a41b47252eeabc43fe96bb06))


### Documentation

* add develeoper notes ([63cd970](https://github.com/ajfriesen/DashboardAssistant/commit/63cd9702a6658b32c223d7285ba8cd6def8f4a08))
* add the kiosk performance post-mortem ([e5f1c19](https://github.com/ajfriesen/DashboardAssistant/commit/e5f1c192ead0ab3268f2ea4b1cb7f2afc5150210))
* add the PolyForm Noncommercial license ([c91669c](https://github.com/ajfriesen/DashboardAssistant/commit/c91669c28d44cc53ca24feff508ef673ac1b39ef))
* correct the license statement in the README ([981eab6](https://github.com/ajfriesen/DashboardAssistant/commit/981eab665ee976a954d05f7942ba4387d9607f00))
* **justfile:** correct two stale recipe doc-strings ([619aa55](https://github.com/ajfriesen/DashboardAssistant/commit/619aa559bf74e5612a2158141ba2f7cf8f6c78e9))
* make the seed file the Wi-Fi path ([a9267cc](https://github.com/ajfriesen/DashboardAssistant/commit/a9267cc70f5b3844423071d8e8dea2d325c71b1d))
* publish the license and license FAQ on the site ([52b9cb7](https://github.com/ajfriesen/DashboardAssistant/commit/52b9cb7b2ddc5e60ceab63b446067e7c42deebe1))
* **README.md:** remove roadmap from readme ([30051ce](https://github.com/ajfriesen/DashboardAssistant/commit/30051ce7dddc7b407b6443fe16f07e71dbdf7c5e))
* Rearange docs ([8d78173](https://github.com/ajfriesen/DashboardAssistant/commit/8d78173d788f45fe8eb7e1743ad5f62d0c6be79d))
* reorder navidation ([320c0ea](https://github.com/ajfriesen/DashboardAssistant/commit/320c0ea7898a499c35db50116137e79157c1a93c))
* slim the release notes down to an Images table ([ead1878](https://github.com/ajfriesen/DashboardAssistant/commit/ead187831da26a43fc237e18094e9240303bb1dc))
* update docs ([f32f57d](https://github.com/ajfriesen/DashboardAssistant/commit/f32f57d3ffcc4137d4282937ca5c2bdf11ea107d))
* **x86:** document installing from a live Linux ([0b756b1](https://github.com/ajfriesen/DashboardAssistant/commit/0b756b1a6485c3f30cae31dc7e36ae80b33938ca))

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
