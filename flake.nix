{
  description = "Dashboard Assistant OS — declarative single-purpose Home Assistant kiosk";

  # Public Attic (Nix binary cache on Cloudflare R2) so local builds — notably
  # `just build-rpi4`, whose aarch64 kernel is otherwise compiled under slow
  # binfmt emulation — download the closure instead of rebuilding it. This is the
  # dev-workstation counterpart of modules/core/binary-cache.nix (which bakes the
  # same cache into deployed images). Nix only honours these for a trusted user,
  # so builds pass `--accept-flake-config` (see the justfile) and you must be in
  # nix.settings.trusted-users on your workstation. Keep in sync with
  # modules/core/binary-cache.nix (which bakes the same cache into images).
  nixConfig = {
    extra-substituters = [ "https://nix-cache.dashboardassistant.org/dashboardassistant" ];
    extra-trusted-public-keys = [ "dashboardassistant:qyNbqk1+S/2a2dqe7XcDfCGnSGT6ACBXgPr5/4BNLYU=" ];
  };

  inputs = {
    # The one nixpkgs every board builds from: nixos-unstable, pinned by
    # flake.lock and bumped on purpose about once a month with
    # `nix flake update nixpkgs-unstable` (docs/adr/0008, docs/README.md).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Wired for the future on-disk install path (tmpfs root + ext4 /persist).
    # Scaffolding only so far — see the commented block in modules/core/default.nix.
    impermanence.url = "github:nix-community/impermanence";

    # Declarative btrfs+zstd disk layout + image builder for the on-disk target.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";

    # Board profiles (firmware, GPU, kernel bits) for the Raspberry Pi target.
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs =
    {
      self,
      nixpkgs-unstable,
      impermanence,
      disko,
      nixos-hardware,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs-unstable.legacyPackages.${system};
      lib = nixpkgs-unstable.lib;

      # Release version baked into every image. The daemon reports this to Home
      # Assistant as the "installed" version and compares it against the newest
      # GitHub release tag to advertise updates. release-please bumps this line in
      # the release PR to match the tag it cuts (via the x-release-please-version
      # annotation; tags may carry a leading "v", which the daemon strips) — don't
      # edit it by hand.
      version = "1.3.0"; # x-release-please-version

      # Interpreter for the hardware bench (labgrid/). labgrid and pytest have to
      # share one env: labgrid ships its fixtures as a pytest11 entry point, so a
      # pytest from any other Python simply does not see them and --lg-env becomes
      # an unknown option. Bound here rather than inline in the devShell so the
      # interpreter itself can be exported as LABGRID_PYTHON — other packages in
      # the shell (zensical) drag their own python3 onto PATH, and which one wins
      # is an accident of ordering.
      labgridPython = pkgs.python314.withPackages (ps: [
        ps.labgrid
        ps.pytest

        # The Bench Home Assistant's websocket API (labgrid/bench_ha.py). Its
        # synchronous client, so the suite stays synchronous — labgrid is, and
        # an event loop here would buy nothing but a second way for a hang to
        # present itself.
        ps.websockets

        # Driving the kiosk's browser over the tunnelled debugging port
        # (labgrid/kiosk.py). Playwright speaks a CDP dialect that tracks the
        # Chromium it was released against, so client and browser are a married
        # pair — and taking it from here is what keeps them married: this and
        # the chromium in modules/core/kiosk.nix resolve from the *same*
        # flake.lock entry (docs/adr/0008), so `nix flake update
        # nixpkgs-unstable` moves both in one commit. A pip install or a
        # container image would reintroduce exactly the drift this prevents.
        ps.playwright

        # Reading .github/workflows/*.yml in test_candidate.py, which asserts
        # that no board's image waits on another board's closure. PyYAML
        # arrives with labgrid anyway; named here so the test does not rest on
        # somebody else's dependency.
        ps.pyyaml
      ]);

      # Optional per-build overrides (e.g. a seeded HA URL / debug flags). See
      # modules/local.example.nix. Must be git-tracked to be picked up.
      localModules = lib.optional (builtins.pathExists ./modules/local.nix) ./modules/local.nix;

      # The on-disk x86 system, parameterised by a list of extra modules so we
      # can cut both a release and a dev flavour from the same base.
      mkDiskSystem =
        extraModules:
        lib.nixosSystem {
          inherit system;
          specialArgs = { inherit impermanence version; };
          modules = [
            disko.nixosModules.disko
            ./modules/hardware/generic-x86-disk.nix
            ./modules/core/default.nix
          ]
          ++ localModules
          ++ extraModules;
        };

      # The Pi systems, parameterised by extra modules (so the release and dev
      # flavours cannot drift apart) and by builderPkgs — the *build machine's*
      # pkgs, used only to run disko's image-builder VM at native speed; see
      # dashboardAssistant.diskImage.builderPkgs. Pass the build host's pkgs
      # when cross-building from x86 (it must come from the same nixpkgs as
      # the system, so the VM's kernel and qemu match the disko module
      # instance), or null on a native aarch64 builder, which leaves the VM
      # native and binfmt off. Hardcoding x86_64 here was exactly wrong on an
      # ARM host: it put a foreign qemu and kernel inside the builder VM.
      mkRpi4System =
        builderPkgs: extraModules:
        lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            inherit impermanence version;
            pkgsBuild = builderPkgs;
          };
          modules = [
            disko.nixosModules.disko
            nixos-hardware.nixosModules.raspberry-pi-4
            ./modules/hardware/rpi4.nix
            ./modules/core/default.nix
          ]
          ++ localModules
          ++ extraModules;
        };

      mkRpi5System =
        builderPkgs: extraModules:
        lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            inherit impermanence version;
            pkgsBuild = builderPkgs;
          };
          modules = [
            disko.nixosModules.disko
            nixos-hardware.nixosModules.raspberry-pi-5
            ./modules/hardware/rpi5.nix
            ./modules/core/default.nix
          ]
          ++ localModules
          ++ extraModules;
        };
    in
    {
      nixosConfigurations = {
        # Release image — persistent, boots from a fixed SATA disk, updatable
        # with `nixos-rebuild switch`. A released device is reconfigured only via
        # the USB seed file. Build via `.#disk-image`. (sshd needs no override any
        # more: modules/core/debug.nix only enables it when a root key is declared,
        # which only the *-dev flavours do.)
        dashboard-assistant-x86-disk = mkDiskSystem [ ];

        # Dev flavour of the on-disk system — same base plus modules/dev.nix
        # (root SSH access). Build via `.#disk-image-dev`.
        dashboard-assistant-x86-disk-dev = mkDiskSystem [ ./modules/dev.nix ];

        # Raspberry Pi 4 (aarch64) — SD-card image, for bring-up/testing on a Pi.
        # Build the flashable image via `.#rpi4-image` (aarch64; an x86 host
        # builds it via binfmt emulation, fetching most from the binary cache).
        dashboard-assistant-rpi4 = mkRpi4System pkgs [ ];

        # Raspberry Pi 5 (aarch64) — SD-card image. Build the flashable image
        # via `.#rpi5-image`.
        dashboard-assistant-rpi5 = mkRpi5System pkgs [ ];

        # Dev flavour of the Pi 5 image — same base plus modules/dev.nix, which
        # declares the root SSH keys that turn sshd on (see modules/core/debug.nix;
        # a release image has no sshd at all). This is the image to reach for when
        # a Pi needs debugging: it is reconfigurable in place with
        # `nixos-rebuild switch --flake .#dashboard-assistant-rpi5-dev --target-host`,
        # so iterating no longer means pulling the card and reflashing. Build via
        # `.#rpi5-image-dev` or `just build-rpi5-dev`.
        # Dev flavour of the Pi 5 image — same base plus modules/dev.nix.
        # No compression knob any more: disko emits a single uncompressed
        # .raw for every target, the same as the x86 images, and release
        # artifacts are compressed by the publishing workflow instead.
        dashboard-assistant-rpi5-dev = mkRpi5System pkgs [
          ./modules/dev.nix
        ];
      };

      # Raw btrfs+zstd EFI disk image built by disko: `nix build .#disk-image`
      # (or `just build-disk`), then dd result/dashboard-assistant.raw to the SSD. The
      # layout lives in modules/hardware/disk-layout.nix.
      packages.${system} = {
        disk-image = self.nixosConfigurations.dashboard-assistant-x86-disk.config.system.build.diskoImages;
        disk-image-dev =
          self.nixosConfigurations.dashboard-assistant-x86-disk-dev.config.system.build.diskoImages;

        # vboard (on-screen keyboard) is packaged from source — not in nixpkgs.
        # Exposed here so it can be built/tested standalone (`nix build .#vboard`);
        # the kiosk module pulls it in via callPackage.
        vboard = pkgs.callPackage ./packages/vboard/vboard.nix { };

        # sendspin-cli (multi-room audio player) — likewise packaged from
        # source and exposed for standalone builds (`nix build .#sendspin-cli`);
        # modules/core/sendspin.nix pulls it in via callPackage.
        sendspin-cli = pkgs.callPackage ./packages/sendspin-cpp-cli/sendspin-cpp-cli.nix { };

        # Raspberry Pi SD-card images, cross-built *from this x86 host*: the
        # aarch64 system compiles under binfmt while disko's image-builder VM
        # runs natively on x86 (see dashboardAssistant.diskImage.builderPkgs).
        # This bucket is what an x86 workstation and CI build — `nix build
        # .#rpi5-image` resolves here. The aarch64-linux bucket below carries
        # the same images wired for a *native* aarch64 builder instead.
        rpi4-image = self.nixosConfigurations.dashboard-assistant-rpi4.config.system.build.diskoImages;
        rpi5-image = self.nixosConfigurations.dashboard-assistant-rpi5.config.system.build.diskoImages;
        rpi5-image-dev =
          self.nixosConfigurations.dashboard-assistant-rpi5-dev.config.system.build.diskoImages;
      };

      # The same Pi images for a *native* aarch64 builder (an ARM runner or a
      # developer's ARM machine): builderPkgs stays null, so disko's builder VM
      # is aarch64 itself and no binfmt is involved. All targets emit a raw GPT
      # image from the one layout in modules/hardware/disk-layout.nix and are
      # flashed identically:
      #   sudo dd if=result-rpi5/dashboard-assistant-rpi5.raw of=/dev/sdX ...
      #
      # Kept separate from the x86 bucket above because the right builder VM
      # depends on the machine evaluating the build — these attrs used to be
      # hard-wired to an x86_64 builder VM, which inverted the native-speed
      # trick on exactly the hosts whose system the attr path names.
      packages.aarch64-linux = {
        rpi4-image = (mkRpi4System null [ ]).config.system.build.diskoImages;
        rpi5-image = (mkRpi5System null [ ]).config.system.build.diskoImages;
        # Same image plus root SSH, for debugging on real hardware without
        # reflashing between changes: `nix build .#rpi5-image-dev`.
        rpi5-image-dev = (mkRpi5System null [ ./modules/dev.nix ]).config.system.build.diskoImages;
      };

      # VM tests. `nix flake check`, or `nix build .#checks.x86_64-linux.first-boot`
      # for one. Adding a check here means adding its name to the matrix in
      # .github/workflows/vm-tests.yml too, or it never runs on a PR.
      checks.${system} = {
        first-boot = import ./tests/first-boot.nix { inherit pkgs version; };
        update-keeps-machine-id = import ./tests/update-keeps-machine-id.nix { inherit pkgs version; };
        vnc = import ./tests/vnc.nix { inherit pkgs version; };
        kiosk-bar = import ./tests/kiosk-bar.nix { inherit pkgs version; };
        screensaver-brightness = import ./tests/screensaver-brightness.nix { inherit pkgs version; };
        touch-rotation = import ./tests/touch-rotation.nix { inherit pkgs version; };
        kiosk-reload = import ./tests/kiosk-reload.nix { inherit pkgs version; };
        sendspin = import ./tests/sendspin.nix { inherit pkgs version; };
        audio = import ./tests/audio.nix { inherit pkgs version; };

        # Flash-wear flags on the browser command line. This is an eval-time
        # check rather than an assertion in first-boot.nix because that test
        # force-disables greetd (no GPU — Chromium crash-loops and buries the
        # signals the test is about), so no VM test can ever see the Chromium
        # command line. The flags would therefore be free to disappear, and the
        # only symptom would be customers' SD cards wearing out months later.
        kiosk-flash-flags =
          pkgs.runCommand "kiosk-flash-flags"
            {
              launcher =
                self.nixosConfigurations.dashboard-assistant-x86-disk.config.dashboardAssistant.kiosk.launcher;
            }
            ''
              set -euo pipefail
              # fail= accumulator so every sub-assertion reports before exiting,
              # matching .github/workflows/boards.yml.
              fail=0
              grep -q 'XDG_CACHE_HOME=.*kiosk-cache' "$launcher" || {
                echo "FAIL: the kiosk browser cache is back on flash — Chromium's HTTP and V8 code caches will write to the SD card continuously." >&2
                fail=1
              }
              grep -q -- '--disk-cache-size=' "$launcher" || {
                echo "FAIL: no --disk-cache-size — Chromium sizes its cache from free space, which on a tmpfs is most of RAM, so systemd-oomd will kill the kiosk session in a loop." >&2
                fail=1
              }
              grep -q -- '--disable-gpu-shader-disk-cache' "$launcher" || {
                echo "FAIL: Chromium's GPU shader caches are back in the profile on flash — they are memory-mapped and written back on every cache hit, the largest writer left on an idle device." >&2
                fail=1
              }
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # The kiosk's managed Chromium policies (modules/core/kiosk.nix). Chromium
        # ignores a policy it does not know without a word, so a misspelt name,
        # or one a Chromium bump removed, would quietly turn a feature back on.
        # Two halves: every policy we set must be one the shipped Chromium has
        # compiled in, and the features the kiosk turns off must stay off.
        kiosk-chromium-policies =
          let
            cfg = self.nixosConfigurations.dashboard-assistant-x86-disk;
          in
          pkgs.runCommand "kiosk-chromium-policies"
            {
              policies = pkgs.writeText "policies.json" (builtins.toJSON cfg.config.programs.chromium.extraOpts);
              chromium = "${cfg.pkgs.chromium.browser}/libexec/chromium/chromium";
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              set -euo pipefail
              fail=0
              for name in $(jq -r 'keys[]' "$policies"); do
                grep -q -a -w "$name" "$chromium" || {
                  echo "FAIL: Chromium does not know the policy $name, so it ignores it." >&2
                  fail=1
                }
              done
              # name=value pairs the kiosk depends on: off for AI, spellcheck,
              # translate, metrics, sync, the PDF viewer, passwords, autofill
              # and shopping; the ways out to a normal browser window; permission
              # prompts nobody can answer; background traffic and flash writes;
              # and battery saver.
              for want in \
                GenAiDefaultSettings=2 GenAILocalFoundationalModelSettings=1 BuiltInAIAPIsEnabled=false \
                AIModeSettings=1 GeminiActOnWebSettings=1 GeminiSparkSettings=1 HelpMeWriteSettings=2 \
                TabCompareSettings=2 CreateThemesSettings=2 HistorySearchSettings=2 DevToolsGenAiSettings=2 \
                AutofillPredictionSettings=2 AutomatedPasswordChangeSettings=2 \
                SpellcheckEnabled=false SpellCheckServiceEnabled=false \
                TranslateEnabled=false TranslatorAPIAllowed=false LiveTranslateEnabled=false \
                MetricsReportingEnabled=false UrlKeyedAnonymizedDataCollectionEnabled=false \
                DomainReliabilityAllowed=false FeedbackSurveysEnabled=false UserFeedbackAllowed=false \
                SafeBrowsingSurveysEnabled=false \
                SyncDisabled=true BrowserSignin=0 \
                AlwaysOpenPdfExternally=true \
                PasswordManagerEnabled=false PasswordLeakDetectionEnabled=false PasswordSharingEnabled=false \
                PasswordManagerPasskeysEnabled=false AutofillAddressEnabled=false AutofillCreditCardEnabled=false \
                PaymentMethodQueryEnabled=false ShoppingListEnabled=false \
                VoiceTypingSettings=2 ThirdPartyAiChatSettings=1 SearchContentSharingSettings=1 \
                SmartTabSharingSettings=1 ChromeSuggestionsSettings=1 LiveCaptionEnabled=false \
                AccessibilityImageLabelsEnabled=false \
                DefaultSearchProviderContextMenuAccessAllowed=false BrowserGuestModeEnabled=false \
                BrowserAddPersonEnabled=false EnableMediaRouter=false WebAppInstallByUserEnabled=false \
                TaskManagerEndProcessEnabled=false \
                DefaultNotificationsSetting=2 DefaultGeolocationSetting=2 DefaultSensorsSetting=2 \
                DefaultWebBluetoothGuardSetting=2 DefaultWebUsbGuardSetting=2 DefaultSerialGuardSetting=2 \
                DefaultWebHidGuardSetting=2 DefaultLocalFontsSetting=2 DefaultWindowManagementSetting=2 \
                DefaultIdleDetectionSetting=2 DefaultFileSystemReadGuardSetting=2 \
                DefaultFileSystemWriteGuardSetting=2 'HttpsOnlyMode="disallowed"' \
                SavingBrowserHistoryDisabled=true BrowserNetworkTimeQueriesEnabled=false \
                NetworkPredictionOptions=2 AlternateErrorPagesEnabled=false MediaRecommendationsEnabled=false \
                PromotionsEnabled=false BackgroundModeEnabled=false \
                BatterySaverModeAvailability=0; do
                name=''${want%%=*} value=''${want#*=}
                got=$(jq -c --arg n "$name" '.[$n]' "$policies")
                [ "$got" = "$value" ] || {
                  echo "FAIL: policy $name is $got, want $value." >&2
                  fail=1
                }
              done
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # The kiosk's fallback dashboard URL and the daemon's default page must
        # name the same Home Assistant. They are written in two languages and
        # were already out of step once — Nix said `http://homeassistant:8123/`
        # while Go said `http://homeassistant.local:8123`, so a device the
        # integration paired without pushing a URL loaded a name that only
        # resolves where the LAN hands out a search domain. Eval-time rather
        # than a VM assertion because first-boot.nix disables greetd, so no VM
        # test ever sees the kiosk's fallback branch.
        one-home-assistant-fallback =
          pkgs.runCommand "one-home-assistant-fallback"
            {
              # The fallback lives in the URL resolver every kiosk script sources.
              urls = self.nixosConfigurations.dashboard-assistant-x86-disk.config.dashboardAssistant.kiosk.urls;
              pagesSrc = ./daemon/pages.go;
              expected = "homeassistant.local:8123";
            }
            ''
              set -euo pipefail
              fail=0
              grep -q "$expected" "$urls" || {
                echo "FAIL: the kiosk's fallback dashboard URL is not $expected — see defaultUrl in modules/core/kiosk.nix." >&2
                fail=1
              }
              grep -q "$expected" "$pagesSrc" || {
                echo "FAIL: defaultPages in daemon/pages.go no longer points at $expected, so the page list and the kiosk fallback disagree." >&2
                fail=1
              }
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # The kiosk's two URLs, resolved the way the launcher and the token
        # injector both do it: HA_URL is where Home Assistant lives (sign-in goes
        # only there), FIRST_PAGE the device's home, from the page list Home
        # Assistant sent, or Home Assistant itself before it sent one. Runs the
        # real resolver against the files the seed and the daemon write,
        # including a URL whose `&` would run as shell if the daemon stopped
        # quoting. Eval-time for the same reason as above: first-boot.nix never
        # starts the kiosk session.
        kiosk-urls =
          let
            kiosk = self.nixosConfigurations.dashboard-assistant-x86-disk.config.dashboardAssistant.kiosk;
          in
          pkgs.runCommand "kiosk-urls"
            {
              inherit (kiosk) launcher urls;
            }
            ''
              set -euo pipefail
              fail=0
              resolve() {
                env -i DA_RUNTIME_ENV="$1" DA_PAGES="$2" ${pkgs.runtimeShell} -c \
                  '. "$0"; printf "%s|%s" "$HA_URL" "$FIRST_PAGE"' "$urls"
              }
              expect() {
                got=$(resolve "$2" "$3")
                [ "$got" = "$4" ] || {
                  echo "FAIL: $1: got '$got', want '$4'" >&2
                  fail=1
                }
              }

              expect "nothing yet" /nonexistent /nonexistent \
                "http://homeassistant.local:8123/|http://homeassistant.local:8123/"

              printf 'HA_URL=http://ha.lan:8123\n' > seed.env
              expect "a seeded device starts at Home Assistant" seed.env /nonexistent \
                "http://ha.lan:8123|http://ha.lan:8123"

              printf "HA_URL='http://ha.lan:8123/?a=1&b=2'\n" > paired.env
              printf '[{"name":"Weather","url":"https://example.com/v?a=1&b=2"},{"name":"HA","url":"http://ha.lan:8123"}]\n' > urls.json
              expect "a paired device starts on its first page" paired.env urls.json \
                "http://ha.lan:8123/?a=1&b=2|https://example.com/v?a=1&b=2"

              grep -qF "$urls" "$launcher" || {
                echo "FAIL: the kiosk launcher no longer reads its URLs through the shared resolver." >&2
                fail=1
              }
              grep -qF '"dir":"start"' "$launcher" || {
                echo "FAIL: the kiosk launcher no longer asks the daemon for the first page." >&2
                fail=1
              }
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # The device locale as the kiosk turns it into Chromium's language and the
        # keyboard layout, by running the real snippet against the region.json the
        # daemon writes (daemon/region.go). Sway's layout and vboard's key labels
        # must agree, or the keyboard types other characters than it shows.
        # Eval-time for the same reason as kiosk-urls: no VM test starts the
        # kiosk session.
        kiosk-region =
          let
            kiosk = self.nixosConfigurations.dashboard-assistant-x86-disk.config.dashboardAssistant.kiosk;
          in
          pkgs.runCommand "kiosk-region"
            {
              inherit (kiosk)
                launcher
                region
                languagePrefs
                session
                ;
              nativeBuildInputs = [ pkgs.jq ];
            }
            ''
              set -euo pipefail
              fail=0
              expect() {
                got=$(env -i DA_REGION="$2" ${pkgs.runtimeShell} -c \
                  '. "$0"; printf "%s|%s|%s|%s" "$LOCALE" "$LANGUAGE" "$XKB_DEFAULT_LAYOUT" "$VBOARD_LAYOUT"' "$region")
                [ "$got" = "$3" ] || {
                  echo "FAIL: $1: got '$got', want '$3'" >&2
                  fail=1
                }
              }
              locale() { printf '{"timezone":"UTC","locale":"%s"}\n' "$1" > region.json; }

              expect "nothing set yet" /nonexistent "en-US|en_US|us|en"
              locale de-DE; expect "German" region.json "de-DE|de_DE|de|de"
              locale de-AT; expect "German in Austria" region.json "de-AT|de_AT|de|de"
              locale fr; expect "French" region.json "fr|fr|fr|fr"
              locale sv-SE; expect "Swedish, whose xkb layout is se" region.json "sv-SE|sv_SE|se|sv"
              locale ru-RU; expect "Russian keeps a Latin keyboard" region.json "ru-RU|ru_RU|us|en"
              locale nl-NL; expect "a language vboard has no layout for" region.json "nl-NL|nl_NL|us|en"

              # Chromium regenerates intl.accept_languages from
              # intl.selected_languages at startup, and navigator.language (so
              # Home Assistant's language) follows them: writing only the first
              # leaves Home Assistant in English (seen on the bench).
              echo '{"intl":{"accept_languages":"en-US,en","selected_languages":"en-US,en"},"other":1}' > Preferences
              env -i LOCALE=de-DE "$languagePrefs" Preferences
              got=$(jq -c '[.intl.accept_languages, .intl.selected_languages, .other]' Preferences)
              [ "$got" = '["de-DE","de-DE",1]' ] || {
                echo "FAIL: the profile's languages after a switch to de-DE: got $got" >&2
                fail=1
              }
              env -i LOCALE=de-DE "$languagePrefs" missing || {
                echo "FAIL: a profile Chromium has not created yet must be left alone" >&2
                fail=1
              }
              [ ! -e missing ] || {
                echo "FAIL: a Preferences file was created where Chromium had none" >&2
                fail=1
              }
              grep -qF "$languagePrefs" "$launcher" || {
                echo "FAIL: the kiosk launcher no longer writes the device locale into Chromium's profile." >&2
                fail=1
              }

              grep -qF "$region" "$launcher" || {
                echo "FAIL: the kiosk launcher no longer starts Chromium in the device locale." >&2
                fail=1
              }
              grep -qF "$region" "$session" || {
                echo "FAIL: the kiosk session no longer starts Sway and vboard in the device's keyboard layout." >&2
                fail=1
              }
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # vboard draws labels, but xkb decides what a key types, so the labels of
        # every layout the kiosk pairs with an xkb layout (kiosk.nix, regionEnv;
        # keep the pairs below in step) must match it key for key.
        vboard-layouts =
          pkgs.runCommand "vboard-layouts"
            {
              nativeBuildInputs = [
                pkgs.libxkbcommon
                pkgs.python3
              ];
            }
            ''
              python3 -I ${./packages/vboard/check-layouts.py} \
                ${self.packages.${system}.vboard}/share/vboard/vboard/layouts \
                en=us de=de fr=fr sv=se
              touch "$out"
            '';

        # Every board on one nixpkgs (docs/adr/0008). The VM tests above only
        # ever evaluate x86, so a board quietly put back on another channel —
        # a second nixpkgs input wired into mkRpi4System, say — would pass every
        # other check while reintroducing the two configurations ADR 0008 exists
        # to remove. Compares the nixpkgs revision, not the release number, so
        # two different pins of the same release are caught too. Reading it out
        # of the aarch64 configs costs an eval, not a build.
        #
        # Also pins the x86 kernel to linuxPackages_latest: the channel's default
        # kernel trails mainline, and the newest one is what gives very recent
        # mini-PCs and laptops a working display, Wi-Fi and touch.
        one-nixpkgs =
          let
            x86 = self.nixosConfigurations.dashboard-assistant-x86-disk.config;
            rpi4 = self.nixosConfigurations.dashboard-assistant-rpi4.config;
            rpi5 = self.nixosConfigurations.dashboard-assistant-rpi5.config;
          in
          pkgs.runCommand "one-nixpkgs"
            {
              x86Rev = x86.system.nixos.revision;
              rpi4Rev = rpi4.system.nixos.revision;
              rpi5Rev = rpi5.system.nixos.revision;
              x86Kernel = x86.boot.kernelPackages.kernel.version;
              latestKernel = pkgs.linuxPackages_latest.kernel.version;
            }
            ''
              set -euo pipefail
              # fail= accumulator so every sub-assertion reports before exiting,
              # matching kiosk-flash-flags above.
              fail=0
              echo "x86: nixpkgs $x86Rev, kernel $x86Kernel"
              echo "rpi4: nixpkgs $rpi4Rev"
              echo "rpi5: nixpkgs $rpi5Rev"

              for board in rpi4:$rpi4Rev rpi5:$rpi5Rev; do
                [ "''${board#*:}" = "$x86Rev" ] || {
                  echo "FAIL: ''${board%%:*} is on nixpkgs ''${board#*:}, x86 on $x86Rev — every board must build from the one pinned nixpkgs-unstable (docs/adr/0008)." >&2
                  fail=1
                }
              done

              [ "$x86Kernel" = "$latestKernel" ] || {
                echo "FAIL: the x86 kernel is $x86Kernel, not linuxPackages_latest ($latestKernel) — very recent hardware loses its display, Wi-Fi or touch. See boot.kernelPackages in modules/hardware/generic-x86-disk.nix." >&2
                fail=1
              }

              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # The screenshot handoff path has a writer in Nix (the in-session grim
        # agent) and a reader in Go (the daemon), with nothing coupling them.
        # If they drift, the HA image entity silently serves nothing — and on
        # the old path it silently wore the card instead.
        # Every character the daemon's own pages show must exist in a font the
        # image ships. cleanup.nix trims the font set to save space, and a
        # character none of those fonts has renders as an empty box: the ⓘ
        # device-info button on the sponsor page did, unnoticed, because a dev
        # machine with more fonts draws it fine. Asks fontconfig loaded with the
        # release image's own fonts.packages, so a change on either side counts.
        web-glyphs-have-fonts =
          let
            release = self.nixosConfigurations.dashboard-assistant-x86-disk.config;
          in
          pkgs.runCommand "web-glyphs-have-fonts"
            {
              web = ./daemon/web;
              FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = release.fonts.packages; };
              nativeBuildInputs = [
                pkgs.fontconfig
                pkgs.python3
              ];
            }
            ''
              set -euo pipefail
              export HOME=$TMPDIR
              python3 - <<'PY'
              import os, pathlib, subprocess, sys, unicodedata
              chars = {}
              for f in pathlib.Path(os.environ["web"]).rglob("*.html"):
                  for ch in f.read_text():
                      cp = ord(ch)
                      # ASCII is in every font; variation selectors and joiners
                      # modify a neighbour and have no glyph of their own.
                      if cp < 128 or 0xFE00 <= cp <= 0xFE0F or cp in (0x200D, 0x200C):
                          continue
                      chars.setdefault(ch, set()).add(f.name)
              missing = []
              for ch, files in sorted(chars.items()):
                  out = subprocess.run(["fc-list", f":charset={ord(ch):x}", "family"],
                                       capture_output=True, text=True, check=True).stdout
                  if not out.strip():
                      missing.append(f"U+{ord(ch):04X} {ch} {unicodedata.name(ch, '?')} in {', '.join(sorted(files))}")
              for m in missing:
                  print(f"FAIL: no shipped font has {m}; it renders as an empty box. Use an inline SVG, or a character a shipped font has.", file=sys.stderr)
              sys.exit(1 if missing else 0)
              PY
              touch $out
            '';

        screenshot-path-agreement =
          pkgs.runCommand "screenshot-path-agreement"
            {
              kiosk = ./modules/core/kiosk.nix;
              daemonConfig = ./daemon/config.go;
            }
            ''
              set -euo pipefail
              fail=0
              want=/run/dashboard-assistant/screenshot.jpg
              grep -q "\"$want\"" "$kiosk" || {
                echo "FAIL: the grim agent no longer writes $want — the Home Assistant screenshot entity will time out." >&2
                fail=1
              }
              grep -q 'runtimeDir + "/screenshot.jpg"' "$daemonConfig" || {
                echo "FAIL: the daemon no longer reads the screenshot from the tmpfs runtime dir — frames are back on flash, at a rate a Home Assistant automation controls." >&2
                fail=1
              }
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # What a *release* image must not have, and what no image may have.
        #
        # modules/dev.nix now carries a key that signs with nobody present, so
        # the release gate can log into a dev image and tunnel the kiosk
        # browser's debugging port off the board. That affordance is exactly as
        # dangerous as it is useful, and the two things keeping it safe are not
        # visible in any VM test: whether a *release* image picked the key up,
        # and whether the debugging port is still bound to loopback.
        #
        # Eval-time rather than a boot assertion for the same reason as
        # kiosk-flash-flags: first-boot.nix force-disables greetd, so no VM test
        # can ever see the Chromium command line, and a release image has no
        # shell to ask anything of in the first place. A regression here has no
        # symptom at all until someone puts a dev image on a hostile network.
        release-has-no-unattended-access =
          let
            release = self.nixosConfigurations.dashboard-assistant-x86-disk.config;
            dev = self.nixosConfigurations.dashboard-assistant-x86-disk-dev.config;
            # The Pi is built from a different hardware module and a different
            # image builder, so "x86 is closed" says nothing about it.
            releasePi = self.nixosConfigurations.dashboard-assistant-rpi5.config;
          in
          pkgs.runCommand "release-has-no-unattended-access"
            {
              releaseKeys = toString release.users.users.root.openssh.authorizedKeys.keys;
              releasePiKeys = toString releasePi.users.users.root.openssh.authorizedKeys.keys;
              releaseSshd = lib.boolToString release.services.openssh.enable;
              releasePiSshd = lib.boolToString releasePi.services.openssh.enable;
              releasePassword = toString (release.users.users.root.hashedPassword or "");
              releasePiPassword = toString (releasePi.users.users.root.hashedPassword or "");
              # The dev side is asserted too, so the gate's own key cannot be
              # dropped without this check saying so — a missing key presents as
              # an hour-long lockout, not as "the key is gone" (labgrid/README.md).
              devKeys = toString dev.users.users.root.openssh.authorizedKeys.keys;
              releaseLauncher = release.dashboardAssistant.kiosk.launcher;
              devLauncher = dev.dashboardAssistant.kiosk.launcher;
            }
            ''
              set -euo pipefail
              # fail= accumulator so every sub-assertion reports before exiting,
              # matching kiosk-flash-flags above.
              fail=0

              # Each value is read as a whole line, never as a loop word: a
              # key list is several space-separated base64 blobs, and
              # `for x in $keys` would shred the one message this check exists
              # to print clearly years from now.
              check_empty() {
                [ -z "$3" ] || {
                  echo "FAIL: the $1 release image $2: $3" >&2
                  fail=1
                }
              }

              check_empty x86 "carries root ssh keys" "$releaseKeys"
              check_empty rpi5 "carries root ssh keys" "$releasePiKeys"
              if [ -n "$releaseKeys$releasePiKeys" ]; then
                echo "    A shipped device must have no key that can sign unattended, and no sshd at all. Keys belong in modules/dev.nix." >&2
              fi

              check_empty x86 "sets a root password" "$releasePassword"
              check_empty rpi5 "sets a root password" "$releasePiPassword"

              for image in x86:"$releaseSshd" rpi5:"$releasePiSshd"; do
                [ "''${image#*:}" = false ] || {
                  echo "FAIL: the ''${image%%:*} release image has sshd enabled — see modules/core/debug.nix, which only turns it on when a root key is declared." >&2
                  fail=1
                }
              done

              case "$devKeys" in
                *bench@keepassxc*) ;;
                *)
                  echo "FAIL: the dev image no longer carries the bench key — the release gate cannot log in without a human, and an unsignable key locks the bench host out for an hour (labgrid/README.md)." >&2
                  fail=1
                  ;;
              esac

              # --remote-debugging-port alone binds to 127.0.0.1. Adding
              # --remote-debugging-address is the one line that would put an
              # unauthenticated, permissive-origin CDP endpoint on the network;
              # the gate reaches it through `ssh -L` instead.
              for image in release:"$releaseLauncher" dev:"$devLauncher"; do
                if grep -q -- '--remote-debugging-address' "''${image#*:}"; then
                  echo "FAIL: the ''${image%%:*} kiosk passes --remote-debugging-address — the browser's debugging port is unauthenticated and runs with permissive origins, so this is remote code execution on any network the device sits on. Tunnel it over ssh instead (labgrid/README.md)." >&2
                  fail=1
                fi
                grep -q -- '--remote-debugging-port=9222' "''${image#*:}" || {
                  echo "FAIL: the ''${image%%:*} kiosk no longer opens the debugging port on 9222 — the kiosk's own token auto-login and the gate's dashboard assertion both go through it." >&2
                  fail=1
                }
              done

              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # An update must not need to build anything on the device. A device runs
        # its *own* update script with its *own* nix.conf, so a release cannot
        # repair a broken build setting on the devices updating to it — it can
        # only avoid needing a build at all. NixOS marks the system toplevel
        # `allowSubstitutes = false`, which makes every update build it (and the
        # few dozen small files under it) locally even when the cache has all of
        # it. 1.0.0 and 1.1.x point build-dir at the world-writable /var/tmp,
        # which Nix refuses, so on those devices any local build fails the
        # update. See modules/core/update.nix.
        updates-need-no-local-build =
          let
            boards = {
              x86 = self.nixosConfigurations.dashboard-assistant-x86-disk.config;
              rpi4 = self.nixosConfigurations.dashboard-assistant-rpi4.config;
              rpi5 = self.nixosConfigurations.dashboard-assistant-rpi5.config;
            };
            substitutable = lib.mapAttrs (
              _: c: lib.boolToString (c.system.build.toplevel.drvAttrs.allowSubstitutes or true)
            ) boards;
            buildDir = lib.mapAttrs (_: c: toString (c.nix.settings.build-dir or "")) boards;
          in
          pkgs.runCommand "updates-need-no-local-build"
            {
              substitutable = lib.concatStringsSep " " (lib.mapAttrsToList (b: v: "${b}:${v}") substitutable);
              buildDirs = lib.concatStringsSep " " (lib.mapAttrsToList (b: v: "${b}:${v}") buildDir);
            }
            ''
              set -euo pipefail
              fail=0
              for board in $substitutable; do
                [ "''${board#*:}" = true ] || {
                  echo "FAIL: the ''${board%%:*} system toplevel is not substitutable — every update would build it on the device, and a device on 1.0.0 or 1.1.x cannot build anything. See system.systemBuilderArgs in modules/core/update.nix." >&2
                  fail=1
                }
              done
              for board in $buildDirs; do
                case "''${board#*:}" in
                  /tmp | /tmp/* | /var/tmp | /var/tmp/*)
                    echo "FAIL: the ''${board%%:*} image sets nix build-dir to the world-writable ''${board#*:}, which Nix refuses — every on-device build fails. Leave build-dir at Nix's default (/nix/var/nix/builds)." >&2
                    fail=1
                    ;;
                esac
              done
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # An update finishes with a reboot, not a live switch. A switch kept the
        # old kiosk session running, so whatever a release changed in it did not
        # take effect: after 1.2.0 -> 1.3.0 the Button bar switch failed with an
        # HTTP 500 until the next reboot, because the bar agent it talks to is
        # new in 1.3.0. A new kernel needs the reboot anyway, and the automatic
        # rollback planned in docs/adr/0009 counts boots. So the update script
        # installs with `nixos-rebuild boot` and reboots, on every board that can
        # update itself.
        updates-finish-with-a-reboot =
          let
            installable = lib.filterAttrs (
              _: s: s.config.dashboardAssistant.update.installable
            ) self.nixosConfigurations;
            # Read the script's text at evaluation time rather than building it:
            # the Pi boards' scripts are aarch64 builds an x86 runner cannot do.
            # Commands only: its comments may mention a switch.
            commands =
              s:
              lib.filter (l: !(lib.hasPrefix "#" (lib.trim l))) (
                lib.splitString "\n" s.config.dashboardAssistant.update.script.text
              );
            has = s: needle: lib.any (lib.hasInfix needle) (commands s);
            problems = lib.concatLists (
              lib.mapAttrsToList (
                name: s:
                lib.optional (has s "nixos-rebuild switch") "${name}'s update switches the running system; install with nixos-rebuild boot and reboot instead"
                ++ lib.optional (
                  !(has s "nixos-rebuild boot" && has s "systemctl reboot")
                ) "${name}'s update does not install with nixos-rebuild boot and reboot"
              ) installable
            );
          in
          pkgs.runCommand "updates-finish-with-a-reboot"
            {
              boards = toString (lib.attrNames installable);
              problems = builtins.unsafeDiscardStringContext (lib.concatMapStrings (p: "FAIL: ${p}\n") problems);
            }
            ''
              set -euo pipefail
              [ -n "$boards" ] || { echo "FAIL: no installable board found" >&2; exit 1; }
              if [ -n "$problems" ]; then printf '%s' "$problems" >&2; exit 1; fi
              echo "checked: $boards"
              touch "$out"
            '';

        # /etc/machine-id is the device's identity: the daemon derives its Home
        # Assistant node_id from it. NixOS must never manage that file. A managed
        # /etc file is deleted when a switch goes to a config that does not
        # declare it, and the dev images update to the release config. That
        # deleted the bench board's machine-id mid-update, which broke D-Bus and
        # hung the switch. On a release image, managing it would also give every
        # device the same identity. Dev images pin theirs on the kernel command
        # line instead, which systemd writes into /etc/machine-id as a plain
        # file. tests/update-keeps-machine-id.nix checks the switch itself.
        machine-id-is-not-managed-by-nixos =
          let
            configs = lib.mapAttrs (_: s: s.config) self.nixosConfigurations;
            managed = lib.attrNames (lib.filterAttrs (_: c: c.environment.etc ? "machine-id") configs);
            devUnpinned = lib.attrNames (
              lib.filterAttrs (
                name: c:
                lib.hasSuffix "-dev" name
                && !(lib.any (p: lib.hasPrefix "systemd.machine_id=" p) c.boot.kernelParams)
              ) configs
            );
          in
          pkgs.runCommand "machine-id-is-not-managed-by-nixos"
            {
              managed = lib.concatStringsSep " " managed;
              devUnpinned = lib.concatStringsSep " " devUnpinned;
            }
            ''
              set -euo pipefail
              fail=0
              for config in $managed; do
                echo "FAIL: $config declares environment.etc.\"machine-id\". NixOS deletes a managed /etc file when a switch goes to a config that does not declare it, so an update would wipe the device's identity. Pin a dev image's machine-id with the systemd.machine_id= kernel parameter instead." >&2
                fail=1
              done
              for config in $devUnpinned; do
                echo "FAIL: $config does not pin its machine-id with systemd.machine_id=, so every reflash of a bench board shows up in Home Assistant as a new device. See modules/dev.nix." >&2
                fail=1
              done
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.go
          pkgs.gopls
          pkgs.nixfmt
          # For `just inject-token` (CDP over the :9222 tunnel).
          pkgs.curl
          pkgs.jq
          pkgs.websocat
          # Static site generator for the website in website/ (`just website-serve`).
          pkgs.zensical
          # Conventional Commits: `cz commit` for a guided message, `cz check` to
          # lint one. Matches the integration repo's dev shell.
          pkgs.commitizen
          # Manage the Cloudflare R2 images bucket over its S3 API — notably apply
          # the lifecycle policy in ops/r2-lifecycle.json (`just r2-lifecycle-apply`).
          pkgs.awscli2
          # Declarative secrets: secretspec.toml declares which secrets exist —
          # the R2 credentials the ops recipes need and the Bench Wi-Fi the
          # hardware suite joins — and `secretspec run -- <cmd>` resolves them
          # from the provider configured per machine, injecting them as env vars
          # for that command only. See ops/README.md.
          #
          # No password-manager tooling rides along: the documented provider is
          # `kdbx`, which secretspec implements itself against a KeePassXC
          # database, and the master password comes from the system keyring. The
          # `pass` + `gnupg` pair that used to sit here backed a provider choice
          # nothing had ever actually been stored in.
          pkgs.secretspec
          # Writes the block map that lets the bench flash only the blocks an
          # image uses (labgrid/bench.py, block_mapped_image). The bench host
          # needs its own bmaptool for the copy itself.
          pkgs.bmaptool
          # `just qemu-run` boots the raw disk image, which is UEFI-only (the
          # bootloader lives in an EFI system partition), so QEMU needs firmware.
          pkgs.qemu
          pkgs.OVMF.fd
          # Drive real boards from the host: power, serial console, USB storage.
          # The VM tests cover what a VM can (see tests/), which leaves the
          # hardware-specific failures — U-Boot, firmware, the touchscreen — only
          # reproducible on a Pi or an x86 box sitting on the bench. See labgrid/
          # for the bench wiring and `just hw-test`.
          #
          # Puts pytest, labgrid-client, labgrid-exporter and labgrid-coordinator
          # on PATH. See the labgridPython binding above for why it is one env.
          #
          # Nothing hardware-side is needed here: the bench hangs off the bench
          # host, which exports it through a coordinator, so usbsdmux runs there
          # over ssh and the console comes back over ser2net (`labgrid-client
          # console`, Ctrl-\ to quit).
          labgridPython
          # Inspect a built sd-image's FAT partition without mounting it or
          # needing root: `mdir`/`mtype`/`minfo -i "$img@@$((2048*512))"` reads
          # partition 1 straight out of the .img, `partx` finds its offset, and
          # `fsck.vfat` checks the extracted filesystem. That is how the README
          # and example seed file staged onto the firmware partition get verified
          # (modules/core/configimport.nix), and labgrid/README.md has documented
          # an mcopy invocation this shell could not run until now.
          pkgs.mtools
          pkgs.dosfstools
          pkgs.util-linux

          # Repair the GPT of the scratch disk `just qemu-test` boots. That disk
          # is the image grown to leave first-boot growth something to grow
          # into, and growing a GPT disk leaves its backup header stranded in
          # the middle: Linux then rejects the table outright and the boot dies
          # in the initrd waiting for a root partition that it can no longer
          # see. `sgdisk --move-second-header` is the fix. See
          # labgrid/bench.py's prepare_qemu_disk.
          pkgs.gptfdisk
        ];

        # Unambiguous path to the interpreter that has labgrid, for scripts that
        # need to `import labgrid` rather than run pytest (`just hw-flash`). Bare
        # `python3` in this shell is whichever python landed on PATH first, which
        # is usually not this one.
        LABGRID_PYTHON = "${labgridPython}/bin/python3";

        # OVMF firmware for `just qemu-run`. Exported here rather than looked up
        # in the recipe so the VM boots the same firmware the pinned nixpkgs
        # provides, with no dependency on the flake registry.
        OVMF_FD = "${pkgs.OVMF.fd}/FV/OVMF.fd";

        # Point git at the version-controlled hook (.githooks/commit-msg) so every
        # commit is checked against Conventional Commits locally, not just PRs in
        # CI. Idempotent — safe to re-run on each shell entry.
        shellHook = ''
          if [ -d .git ]; then
            git config core.hooksPath .githooks
          fi
        '';
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
